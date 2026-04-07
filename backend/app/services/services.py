"""Business logic services for the Medicine Reminder backend."""

from datetime import datetime, date, time
from typing import Optional

from sqlalchemy import select, and_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.models import (
    User, Medicine, ReminderSchedule, IntakeHistory, IntakeStatus
)
from app.schemas.schemas import (
    UserCreate, MedicineCreate, MedicineUpdate, ReminderScheduleCreate,
    MedicineResponse, ReminderScheduleResponse, IntakeHistoryResponse,
    MedicineWithSchedules, TodayScheduleItem, TodayScheduleResponse,
)


# --- User Services ---

async def get_or_create_user(db: AsyncSession, data: UserCreate) -> User:
    """Get existing user or create a new one based on telegram_id."""
    result = await db.execute(
        select(User).where(User.telegram_id == data.telegram_id)
    )
    user = result.scalar_one_or_none()

    if user is None:
        user = User(
            telegram_id=data.telegram_id,
            username=data.username,
            first_name=data.first_name,
        )
        db.add(user)
        await db.flush()
        await db.refresh(user)

    return user


async def get_user_by_telegram_id(db: AsyncSession, telegram_id: int) -> Optional[User]:
    """Find user by Telegram ID."""
    result = await db.execute(
        select(User).where(User.telegram_id == telegram_id)
    )
    return result.scalar_one_or_none()


# --- Medicine Services ---

async def create_medicine(db: AsyncSession, user_id: int, data: MedicineCreate) -> Medicine:
    """Create a new medicine for a user."""
    medicine = Medicine(
        user_id=user_id,
        name=data.name.strip(),
        dosage=data.dosage.strip(),
    )
    db.add(medicine)
    await db.flush()
    await db.refresh(medicine)
    return medicine


async def get_user_medicines(db: AsyncSession, user_id: int) -> list[Medicine]:
    """Get all medicines for a user."""
    result = await db.execute(
        select(Medicine)
        .where(Medicine.user_id == user_id)
        .order_by(Medicine.name)
    )
    return list(result.scalars().all())


async def get_medicine_by_id(db: AsyncSession, medicine_id: int, user_id: int) -> Optional[Medicine]:
    """Get a specific medicine belonging to a user."""
    result = await db.execute(
        select(Medicine).where(
            and_(Medicine.id == medicine_id, Medicine.user_id == user_id)
        )
    )
    return result.scalar_one_or_none()


async def update_medicine(
    db: AsyncSession, medicine: Medicine, data: MedicineUpdate
) -> Medicine:
    """Update medicine name and/or dosage."""
    if data.name is not None:
        medicine.name = data.name.strip()
    if data.dosage is not None:
        medicine.dosage = data.dosage.strip()
    await db.flush()
    await db.refresh(medicine)
    return medicine


async def delete_medicine(db: AsyncSession, medicine: Medicine) -> None:
    """Delete a medicine and all its schedules/intake history (cascade)."""
    await db.delete(medicine)
    await db.flush()


# --- Reminder Schedule Services ---

async def create_reminder_schedule(
    db: AsyncSession, medicine_id: int, reminder_time: time
) -> ReminderSchedule:
    """Create a new reminder schedule for a medicine."""
    schedule = ReminderSchedule(
        medicine_id=medicine_id,
        reminder_time=reminder_time,
        is_active=True,
    )
    db.add(schedule)
    await db.flush()
    await db.refresh(schedule)
    return schedule


async def get_medicine_schedules(
    db: AsyncSession, medicine_id: int
) -> list[ReminderSchedule]:
    """Get all reminder schedules for a medicine."""
    result = await db.execute(
        select(ReminderSchedule)
        .where(ReminderSchedule.medicine_id == medicine_id)
        .order_by(ReminderSchedule.reminder_time)
    )
    return list(result.scalars().all())


async def get_active_schedules_for_time(
    db: AsyncSession, target_time: time
) -> list[ReminderSchedule]:
    """Get all active schedules matching a specific time."""
    result = await db.execute(
        select(ReminderSchedule)
        .where(
            and_(
                ReminderSchedule.reminder_time == target_time,
                ReminderSchedule.is_active == True,
            )
        )
        .options(
            selectinload(ReminderSchedule.medicine).selectinload(Medicine.user)
        )
    )
    return list(result.scalars().all())


async def get_active_schedules_with_details_for_time(
    db: AsyncSession, target_time: time
) -> list[dict]:
    """Get active schedules with full medicine and user details for scheduler."""
    schedules = await get_active_schedules_for_time(db, target_time)

    result_list = []
    for schedule in schedules:
        medicine = schedule.medicine
        user = medicine.user

        result_list.append({
            "schedule_id": schedule.id,
            "medicine_id": medicine.id,
            "medicine_name": medicine.name,
            "dosage": medicine.dosage,
            "user_id": user.id,
            "telegram_id": user.telegram_id,
        })

    return result_list


async def delete_reminder_schedule(db: AsyncSession, schedule: ReminderSchedule) -> None:
    """Delete a reminder schedule."""
    await db.delete(schedule)
    await db.flush()


# --- Intake History Services ---

async def create_pending_intake(
    db: AsyncSession,
    user_id: int,
    schedule_id: int,
    medicine_name: str,
    scheduled_time: datetime,
) -> IntakeHistory:
    """Create a pending intake record when a reminder fires."""
    intake = IntakeHistory(
        user_id=user_id,
        schedule_id=schedule_id,
        medicine_name=medicine_name,
        scheduled_time=scheduled_time,
        status=IntakeStatus.PENDING,
    )
    db.add(intake)
    await db.flush()
    await db.refresh(intake)
    return intake


async def check_duplicate_intake(
    db: AsyncSession, schedule_id: int, scheduled_time: datetime
) -> Optional[IntakeHistory]:
    """Check if an intake record already exists for this schedule+time combo."""
    result = await db.execute(
        select(IntakeHistory).where(
            and_(
                IntakeHistory.schedule_id == schedule_id,
                IntakeHistory.scheduled_time == scheduled_time,
            )
        )
    )
    return result.scalar_one_or_none()


async def update_intake_status(
    db: AsyncSession, intake_id: int, status: IntakeStatus
) -> Optional[IntakeHistory]:
    """Update the status of an intake record (taken/missed)."""
    result = await db.execute(
        select(IntakeHistory).where(IntakeHistory.id == intake_id)
    )
    intake = result.scalar_one_or_none()
    if intake:
        intake.status = status
        intake.responded_at = datetime.utcnow()
        await db.flush()
        await db.refresh(intake)
    return intake


async def get_user_intake_history(
    db: AsyncSession, user_id: int, limit: int = 30
) -> list[IntakeHistory]:
    """Get recent intake history for a user."""
    result = await db.execute(
        select(IntakeHistory)
        .where(IntakeHistory.user_id == user_id)
        .order_by(IntakeHistory.scheduled_time.desc())
        .limit(limit)
    )
    return list(result.scalars().all())


async def get_today_intakes(
    db: AsyncSession, user_id: int, today: date
) -> list[IntakeHistory]:
    """Get all intakes scheduled for today."""
    from sqlalchemy import func

    start_of_day = datetime(today.year, today.month, today.day, 0, 0, 0)
    end_of_day = datetime(today.year, today.month, today.day, 23, 59, 59)

    result = await db.execute(
        select(IntakeHistory)
        .where(
            and_(
                IntakeHistory.user_id == user_id,
                IntakeHistory.scheduled_time >= start_of_day,
                IntakeHistory.scheduled_time <= end_of_day,
            )
        )
        .order_by(IntakeHistory.scheduled_time)
    )
    return list(result.scalars().all())


async def get_pending_intake_for_schedule(
    db: AsyncSession, schedule_id: int
) -> Optional[IntakeHistory]:
    """Get the most recent pending intake for a schedule."""
    result = await db.execute(
        select(IntakeHistory)
        .where(
            and_(
                IntakeHistory.schedule_id == schedule_id,
                IntakeHistory.status == IntakeStatus.PENDING,
            )
        )
        .order_by(IntakeHistory.scheduled_time.desc())
    )
    return result.scalars().first()


# --- Combined Query Services ---

async def get_medicine_with_schedules(
    db: AsyncSession, medicine_id: int, user_id: int
) -> Optional[MedicineWithSchedules]:
    """Get a medicine with all its schedules."""
    medicine = await get_medicine_by_id(db, medicine_id, user_id)
    if not medicine:
        return None

    schedules = await get_medicine_schedules(db, medicine_id)

    return MedicineWithSchedules(
        medicine=MedicineResponse.model_validate(medicine),
        schedules=[ReminderScheduleResponse.model_validate(s) for s in schedules],
    )


async def get_today_schedule_response(
    db: AsyncSession, user_id: int, today: date
) -> TodayScheduleResponse:
    """Get today's full schedule with medicine details."""
    intakes = await get_today_intakes(db, user_id, today)

    items = []
    for intake in intakes:
        # Get dosage from the medicine
        result = await db.execute(
            select(Medicine.dosage).where(Medicine.id == intake.schedule_id)
        )
        # Join through schedule -> medicine
        result = await db.execute(
            select(Medicine)
            .join(ReminderSchedule, Medicine.id == ReminderSchedule.medicine_id)
            .where(ReminderSchedule.id == intake.schedule_id)
        )
        medicine = result.scalar_one_or_none()
        dosage = medicine.dosage if medicine else "Unknown"

        items.append(
            TodayScheduleItem(
                intake_id=intake.id,
                medicine_name=intake.medicine_name,
                dosage=dosage,
                scheduled_time=intake.scheduled_time,
                status=intake.status,
            )
        )

    return TodayScheduleResponse(date=today, items=items)
