"""FastAPI route definitions for the Medicine Reminder API."""

from datetime import datetime, date, time
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_db
from app.models.models import IntakeStatus
from app.schemas.schemas import (
    UserCreate, UserResponse,
    MedicineCreate, MedicineResponse, MedicineUpdate,
    ReminderScheduleCreate, ReminderScheduleResponse,
    IntakeHistoryResponse, IntakeRecord,
    MedicineWithSchedules, TodayScheduleResponse,
    PendingIntakeCreate,
)
from app.services import services


router = APIRouter()


# --- Health Check ---

@router.get("/health", tags=["health"])
async def health_check():
    """Health check endpoint for Docker and monitoring."""
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat()}


# --- User Endpoints ---

@router.post("/users", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
async def register_user(data: UserCreate, db: AsyncSession = Depends(get_db)):
    """Register or get existing user by Telegram ID."""
    user = await services.get_or_create_user(db, data)
    return user


@router.get("/users/telegram/{telegram_id}", response_model=UserResponse)
async def get_user(telegram_id: int, db: AsyncSession = Depends(get_db)):
    """Get user by Telegram ID."""
    user = await services.get_user_by_telegram_id(db, telegram_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user


# --- Medicine Endpoints ---

@router.post("/medicines", response_model=MedicineResponse, status_code=status.HTTP_201_CREATED)
async def add_medicine(
    user_id: int,
    data: MedicineCreate,
    db: AsyncSession = Depends(get_db),
):
    """Add a new medicine for a user."""
    medicine = await services.create_medicine(db, user_id, data)
    return medicine


@router.get("/medicines/user/{user_id}", response_model=list[MedicineResponse])
async def list_medicines(user_id: int, db: AsyncSession = Depends(get_db)):
    """List all medicines for a user."""
    return await services.get_user_medicines(db, user_id)


@router.get("/medicines/{medicine_id}", response_model=MedicineWithSchedules)
async def get_medicine(
    medicine_id: int,
    user_id: int,
    db: AsyncSession = Depends(get_db),
):
    """Get a medicine with its schedules."""
    result = await services.get_medicine_with_schedules(db, medicine_id, user_id)
    if not result:
        raise HTTPException(status_code=404, detail="Medicine not found")
    return result


@router.patch("/medicines/{medicine_id}", response_model=MedicineResponse)
async def update_medicine(
    medicine_id: int,
    user_id: int,
    data: MedicineUpdate,
    db: AsyncSession = Depends(get_db),
):
    """Update medicine name or dosage."""
    medicine = await services.get_medicine_by_id(db, medicine_id, user_id)
    if not medicine:
        raise HTTPException(status_code=404, detail="Medicine not found")
    return await services.update_medicine(db, medicine, data)


@router.delete("/medicines/{medicine_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_medicine(
    medicine_id: int,
    user_id: int,
    db: AsyncSession = Depends(get_db),
):
    """Delete a medicine and all its schedules."""
    medicine = await services.get_medicine_by_id(db, medicine_id, user_id)
    if not medicine:
        raise HTTPException(status_code=404, detail="Medicine not found")
    await services.delete_medicine(db, medicine)
    return None


# --- Reminder Schedule Endpoints ---

@router.post(
    "/schedules", response_model=ReminderScheduleResponse, status_code=status.HTTP_201_CREATED
)
async def add_schedule(
    data: ReminderScheduleCreate,
    db: AsyncSession = Depends(get_db),
):
    """Add a reminder time for a medicine."""
    # Verify medicine exists
    result = await db.execute(
        select(services.Medicine).where(services.Medicine.id == data.medicine_id)
    )
    medicine = result.scalar_one_or_none()
    if not medicine:
        raise HTTPException(status_code=404, detail="Medicine not found")

    schedule = await services.create_reminder_schedule(db, data.medicine_id, data.reminder_time)
    return schedule


@router.get("/schedules/medicine/{medicine_id}", response_model=list[ReminderScheduleResponse])
async def list_schedules(medicine_id: int, db: AsyncSession = Depends(get_db)):
    """List all schedules for a medicine."""
    return await services.get_medicine_schedules(db, medicine_id)


@router.delete("/schedules/{schedule_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_schedule(
    schedule_id: int,
    user_id: int,
    db: AsyncSession = Depends(get_db),
):
    """Delete a reminder schedule (with user ownership check)."""
    from sqlalchemy import select as sa_select
    from app.models.models import Medicine

    result = await db.execute(
        sa_select(services.ReminderSchedule)
        .join(Medicine, Medicine.id == services.ReminderSchedule.medicine_id)
        .where(
            services.ReminderSchedule.id == schedule_id,
            Medicine.user_id == user_id,
        )
    )
    schedule = result.scalar_one_or_none()
    if not schedule:
        raise HTTPException(status_code=404, detail="Schedule not found")
    await services.delete_reminder_schedule(db, schedule)
    return None


# --- Intake History Endpoints ---

@router.post("/intakes", response_model=IntakeHistoryResponse)
async def record_intake(
    data: IntakeRecord,
    db: AsyncSession = Depends(get_db),
):
    """Record that a user took or missed a dose."""
    intake = await services.update_intake_status(db, data.intake_id, data.status)
    if not intake:
        raise HTTPException(status_code=404, detail="Intake record not found")
    return intake


@router.get("/intakes/user/{user_id}", response_model=list[IntakeHistoryResponse])
async def get_intake_history(
    user_id: int,
    limit: int = 30,
    db: AsyncSession = Depends(get_db),
):
    """Get intake history for a user."""
    return await services.get_user_intake_history(db, user_id, limit)


@router.get("/intakes/today/{user_id}", response_model=TodayScheduleResponse)
async def get_today_intakes(
    user_id: int,
    db: AsyncSession = Depends(get_db),
):
    """Get today's intake schedule for a user."""
    today = date.today()
    return await services.get_today_schedule_response(db, user_id, today)


@router.post("/intakes/pending", response_model=IntakeHistoryResponse, status_code=status.HTTP_201_CREATED)
async def create_pending_intake(
    data: PendingIntakeCreate,
    db: AsyncSession = Depends(get_db),
):
    """Create a pending intake record when a reminder fires. Used by the scheduler."""
    # Check for duplicate
    existing = await services.check_duplicate_intake(db, data.schedule_id, data.scheduled_time)
    if existing:
        return existing

    intake = await services.create_pending_intake(
        db, data.user_id, data.schedule_id, data.medicine_name, data.scheduled_time
    )
    return intake


# --- Reminder Scheduler Internal Endpoint ---

@router.get("/schedules/active/{hour}/{minute}", response_model=list[ReminderScheduleResponse])
async def get_active_schedules_for_time(
    hour: int,
    minute: int,
    db: AsyncSession = Depends(get_db),
):
    """Get all active schedules for a given time (used by scheduler)."""
    target_time = time(hour=hour, minute=minute)
    schedules = await services.get_active_schedules_for_time(db, target_time)
    return [ReminderScheduleResponse.model_validate(s) for s in schedules]


@router.get("/schedules/active-details/{hour}/{minute}")
async def get_active_schedules_with_details(
    hour: int,
    minute: int,
    db: AsyncSession = Depends(get_db),
):
    """Get active schedules with full medicine+user info (for bot scheduler)."""
    target_time = time(hour=hour, minute=minute)
    return await services.get_active_schedules_with_details_for_time(db, target_time)
