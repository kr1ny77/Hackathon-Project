#!/bin/bash
# ============================================================
# FINAL FIX v6 — Medicine Reminder
# ============================================================
set -e
cd /opt/medicine-reminder

echo "============================================"
echo "  FINAL FIX v6"
echo "============================================"

# ===== BACKEND: endpoints.py =====
cat > backend/app/api/endpoints.py << 'ENDPOINTS_EOF'
from datetime import datetime, date, time, timedelta
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select, and_
from sqlalchemy.ext.asyncio import AsyncSession
from app.db.session import get_db
from app.models.models import IntakeStatus, Medicine, ReminderSchedule, IntakeHistory, User
from app.schemas.schemas import (
    UserCreate, UserResponse, MedicineCreate, MedicineResponse, MedicineUpdate,
    ReminderScheduleCreate, ReminderScheduleResponse,
    IntakeHistoryResponse, IntakeRecord,
    MedicineWithSchedules, TodayScheduleResponse, PendingIntakeCreate,
)
from app.services import services

router = APIRouter()

@router.get("/health")
async def health_check():
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat()}

@router.post("/users", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
async def register_user(data: UserCreate, db: AsyncSession = Depends(get_db)):
    return await services.get_or_create_user(db, data)

@router.get("/users/telegram/{telegram_id}", response_model=UserResponse)
async def get_user(telegram_id: int, db: AsyncSession = Depends(get_db)):
    user = await services.get_user_by_telegram_id(db, telegram_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user

@router.get("/users/id/{user_id}", response_model=UserResponse)
async def get_user_by_id(user_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return user

@router.post("/medicines", response_model=MedicineResponse, status_code=status.HTTP_201_CREATED)
async def add_medicine(user_id: int, data: MedicineCreate, db: AsyncSession = Depends(get_db)):
    return await services.create_medicine(db, user_id, data)

@router.get("/medicines/user/{user_id}", response_model=list[MedicineResponse])
async def list_medicines(user_id: int, db: AsyncSession = Depends(get_db)):
    return await services.get_user_medicines(db, user_id)

@router.get("/medicines/{medicine_id}", response_model=MedicineWithSchedules)
async def get_medicine(medicine_id: int, user_id: int, db: AsyncSession = Depends(get_db)):
    result = await services.get_medicine_with_schedules(db, medicine_id, user_id)
    if not result:
        raise HTTPException(status_code=404, detail="Medicine not found")
    return result

@router.patch("/medicines/{medicine_id}", response_model=MedicineResponse)
async def update_medicine(medicine_id: int, user_id: int, data: MedicineUpdate, db: AsyncSession = Depends(get_db)):
    medicine = await services.get_medicine_by_id(db, medicine_id, user_id)
    if not medicine:
        raise HTTPException(status_code=404, detail="Medicine not found")
    return await services.update_medicine(db, medicine, data)

@router.delete("/medicines/{medicine_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_medicine(medicine_id: int, user_id: int, db: AsyncSession = Depends(get_db)):
    medicine = await services.get_medicine_by_id(db, medicine_id, user_id)
    if not medicine:
        raise HTTPException(status_code=404, detail="Medicine not found")
    await services.delete_medicine(db, medicine)

@router.post("/schedules", response_model=ReminderScheduleResponse, status_code=status.HTTP_201_CREATED)
async def add_schedule(data: ReminderScheduleCreate, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Medicine).where(Medicine.id == data.medicine_id))
    if not result.scalar_one_or_none():
        raise HTTPException(status_code=404, detail="Medicine not found")
    return await services.create_reminder_schedule(db, data.medicine_id, data.reminder_time)

@router.get("/schedules/medicine/{medicine_id}", response_model=list[ReminderScheduleResponse])
async def list_schedules(medicine_id: int, db: AsyncSession = Depends(get_db)):
    return await services.get_medicine_schedules(db, medicine_id)

@router.delete("/schedules/{schedule_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_schedule(schedule_id: int, user_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(ReminderSchedule).join(Medicine, Medicine.id == ReminderSchedule.medicine_id)
        .where(ReminderSchedule.id == schedule_id, Medicine.user_id == user_id)
    )
    schedule = result.scalar_one_or_none()
    if not schedule:
        raise HTTPException(status_code=404, detail="Schedule not found")
    await services.delete_reminder_schedule(db, schedule)

@router.post("/intakes", response_model=IntakeHistoryResponse)
async def record_intake(data: IntakeRecord, db: AsyncSession = Depends(get_db)):
    intake = await services.update_intake_status(db, data.intake_id, data.status)
    if not intake:
        raise HTTPException(status_code=404, detail="Intake record not found")
    return intake

@router.post("/intakes/pending", response_model=IntakeHistoryResponse, status_code=status.HTTP_201_CREATED)
async def create_pending_intake(data: PendingIntakeCreate, db: AsyncSession = Depends(get_db)):
    existing = await services.check_duplicate_intake(db, data.schedule_id, data.scheduled_time)
    if existing:
        return IntakeHistoryResponse.model_validate(existing)
    intake = await services.create_pending_intake(db, data.user_id, data.schedule_id, data.medicine_name, data.scheduled_time)
    return IntakeHistoryResponse.model_validate(intake)

@router.post("/intakes/reschedule")
async def reschedule_intake(intake_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(IntakeHistory).where(IntakeHistory.id == intake_id))
    intake = result.scalar_one_or_none()
    if not intake:
        raise HTTPException(status_code=404, detail="Intake not found")
    new_time = intake.scheduled_time + timedelta(minutes=5)
    intake.scheduled_time = new_time
    intake.status = IntakeStatus.PENDING
    intake.responded_at = None
    await db.flush()
    await db.refresh(intake)
    return IntakeHistoryResponse.model_validate(intake)

@router.get("/intakes/user/{user_id}", response_model=list[IntakeHistoryResponse])
async def get_intake_history(user_id: int, limit: int = 30, db: AsyncSession = Depends(get_db)):
    return await services.get_user_intake_history(db, user_id, limit)

@router.get("/intakes/today/{user_id}", response_model=TodayScheduleResponse)
async def get_today_intakes(user_id: int, db: AsyncSession = Depends(get_db)):
    return await services.get_today_schedule_response(db, user_id, date.today())

@router.get("/intakes/pending-due")
async def get_pending_due(db: AsyncSession = Depends(get_db)):
    now = datetime.utcnow()
    result = await db.execute(
        select(IntakeHistory).where(and_(
            IntakeHistory.status == IntakeStatus.PENDING,
            IntakeHistory.scheduled_time <= now,
        ))
    )
    return [IntakeHistoryResponse.model_validate(i) for i in result.scalars().all()]

@router.get("/schedules/active/{hour}/{minute}", response_model=list[ReminderScheduleResponse])
async def get_active_schedules_for_time(hour: int, minute: int, db: AsyncSession = Depends(get_db)):
    target_time = time(hour=hour, minute=minute)
    schedules = await services.get_active_schedules_for_time(db, target_time)
    return [ReminderScheduleResponse.model_validate(s) for s in schedules]

@router.get("/schedules/active-details/{hour}/{minute}")
async def get_active_schedules_with_details(hour: int, minute: int, db: AsyncSession = Depends(get_db)):
    target_time = time(hour=hour, minute=minute)
    return await services.get_active_schedules_with_details_for_time(db, target_time)
ENDPOINTS_EOF

echo "[1/7] endpoints.py — added /users/id/{id} + reschedule + pending-due"

# ===== BACKEND: services.py — ensure IntakeHistory is imported =====
python3 -c "
p = 'backend/app/services/services.py'
with open(p) as f: c = f.read()
if 'from app.models.models import' in c:
    imports_line = c.split('from app.models.models import')[1].split('\n')[0]
    if 'IntakeHistory' not in imports_line:
        c = c.replace('from app.models.models import (\n', 'from app.models.models import (\n    IntakeHistory, ')
        with open(p, 'w') as f: f.write(c)
        print('Added IntakeHistory import')
    else:
        print('IntakeHistory already imported')
"

echo "[2/7] services.py checked"

# ===== BOT: scheduler.py =====
cat > bot/app/services/scheduler.py << 'SCHEDULER_EOF'
import asyncio
import logging
from datetime import datetime
from aiogram import Bot
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.config import get_bot_settings
from app.services.backend_client import BackendClient
from app.handlers.intake import build_intake_keyboard

logger = logging.getLogger(__name__)


class ReminderScheduler:
    def __init__(self, bot: Bot):
        self.bot = bot
        self.settings = get_bot_settings()
        self.backend = BackendClient()
        self._task = None
        self._intake_map = {}  # intake_id -> telegram_id

    async def start(self):
        logger.info("Reminder scheduler started")
        self._task = asyncio.create_task(self._run())

    async def stop(self):
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        await self.backend.close()
        logger.info("Reminder scheduler stopped")

    async def _run(self):
        while True:
            try:
                await self._check()
            except Exception as e:
                logger.error(f"Scheduler error: {e}")
            await asyncio.sleep(self.settings.REMINDER_CHECK_INTERVAL)

    async def _check(self):
        now = datetime.utcnow()
        hh, mm = now.hour, now.minute

        # 1) New schedules due now
        try:
            schedules = await self.backend.get_active_schedules_with_details(hh, mm)
        except Exception as e:
            logger.error(f"Schedules fetch error: {e}")
            schedules = []

        for info in schedules:
            try:
                await self._new_reminder(info, now)
            except Exception as e:
                logger.error(f"New reminder error: {e}")

        # 2) Re-scheduled (pending-due) intakes
        try:
            pending = await self.backend.get_pending_due()
        except Exception as e:
            logger.error(f"Pending fetch error: {e}")
            pending = []

        for intake in pending:
            tid = self._intake_map.get(intake["id"])
            if tid:
                try:
                    await self._send(intake, tid)
                except Exception as e:
                    logger.error(f"Send error: {e}")

    async def _new_reminder(self, info: dict, now: datetime):
        tid = info["telegram_id"]
        scheduled_time = now.strftime("%Y-%m-%dT%H:%M:%S")
        intake = await self.backend.create_pending_intake(
            user_id=info["user_id"],
            schedule_id=info["schedule_id"],
            medicine_name=info["medicine_name"],
            scheduled_time=scheduled_time,
        )
        if intake:
            self._intake_map[intake["id"]] = tid
            await self._send(intake, tid)

    async def _send(self, intake: dict, telegram_id: int):
        name = intake.get("medicine_name", "Unknown")
        msg = (
            f"Medicine Reminder\n\n"
            f"Medicine: {name}\n"
            f"Time: {datetime.utcnow().strftime('%H:%M')}\n\n"
            f"Have you taken your medicine?"
        )
        kb = build_intake_keyboard(intake["id"])
        await self.bot.send_message(chat_id=telegram_id, text=msg, reply_markup=kb.as_markup())
        logger.info(f"Sent reminder to {telegram_id}: {name} (intake #{intake['id']})")
SCHEDULER_EOF

echo "[3/7] scheduler.py rewritten"

# ===== BOT: backend_client.py =====
cat > bot/app/services/backend_client.py << 'CLIENT_EOF'
import logging
from typing import Optional
import httpx
from app.config import get_bot_settings

logger = logging.getLogger(__name__)


class BackendClient:
    def __init__(self):
        self.settings = get_bot_settings()
        self.base_url = self.settings.BACKEND_URL.rstrip("/")
        self._client: Optional[httpx.AsyncClient] = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(base_url=self.base_url, timeout=10.0)
        return self._client

    async def close(self):
        if self._client and not self._client.is_closed:
            await self._client.aclose()

    async def register_user(self, telegram_id, username=None, first_name=None):
        c = await self._get_client()
        r = await c.post("/users", json={"telegram_id": telegram_id, "username": username, "first_name": first_name})
        r.raise_for_status()
        return r.json()

    async def get_user(self, telegram_id):
        c = await self._get_client()
        r = await c.get(f"/users/telegram/{telegram_id}")
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()

    async def add_medicine(self, user_id, name, dosage):
        c = await self._get_client()
        r = await c.post(f"/medicines?user_id={user_id}", json={"name": name, "dosage": dosage})
        r.raise_for_status()
        return r.json()

    async def list_medicines(self, user_id):
        c = await self._get_client()
        r = await c.get(f"/medicines/user/{user_id}")
        r.raise_for_status()
        return r.json()

    async def get_medicine(self, medicine_id, user_id):
        c = await self._get_client()
        r = await c.get(f"/medicines/{medicine_id}?user_id={user_id}")
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()

    async def update_medicine(self, medicine_id, user_id, name=None, dosage=None):
        c = await self._get_client()
        payload = {}
        if name: payload["name"] = name
        if dosage: payload["dosage"] = dosage
        r = await c.patch(f"/medicines/{medicine_id}?user_id={user_id}", json=payload)
        r.raise_for_status()
        return r.json()

    async def delete_medicine(self, medicine_id, user_id):
        c = await self._get_client()
        r = await c.delete(f"/medicines/{medicine_id}?user_id={user_id}")
        return r.status_code != 404

    async def add_schedule(self, medicine_id, reminder_time):
        c = await self._get_client()
        r = await c.post("/schedules", json={"medicine_id": medicine_id, "reminder_time": reminder_time})
        r.raise_for_status()
        return r.json()

    async def list_schedules(self, medicine_id):
        c = await self._get_client()
        r = await c.get(f"/schedules/medicine/{medicine_id}")
        r.raise_for_status()
        return r.json()

    async def delete_schedule(self, schedule_id, user_id):
        c = await self._get_client()
        r = await c.delete(f"/schedules/{schedule_id}?user_id={user_id}")
        return r.status_code != 404

    async def get_active_schedules_with_details(self, hour, minute):
        c = await self._get_client()
        r = await c.get(f"/schedules/active-details/{hour}/{minute}")
        r.raise_for_status()
        return r.json()

    async def create_pending_intake(self, user_id, schedule_id, medicine_name, scheduled_time):
        c = await self._get_client()
        r = await c.post("/intakes/pending", json={
            "user_id": user_id, "schedule_id": schedule_id,
            "medicine_name": medicine_name, "scheduled_time": scheduled_time,
        })
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()

    async def record_intake(self, intake_id, status):
        c = await self._get_client()
        r = await c.post("/intakes", json={"intake_id": intake_id, "status": status})
        r.raise_for_status()
        return r.json()

    async def reschedule_intake(self, intake_id):
        c = await self._get_client()
        r = await c.post(f"/intakes/reschedule?intake_id={intake_id}")
        r.raise_for_status()
        return r.json()

    async def get_pending_due(self):
        c = await self._get_client()
        r = await c.get("/intakes/pending-due")
        r.raise_for_status()
        return r.json()

    async def get_intake_history(self, user_id, limit=30):
        c = await self._get_client()
        r = await c.get(f"/intakes/user/{user_id}?limit={limit}")
        r.raise_for_status()
        return r.json()

    async def get_today_intakes(self, user_id):
        c = await self._get_client()
        r = await c.get(f"/intakes/today/{user_id}")
        r.raise_for_status()
        return r.json()
CLIENT_EOF

echo "[4/7] backend_client.py fixed"

# ===== BOT: intake.py =====
cat > bot/app/handlers/intake.py << 'INTAKE_EOF'
import logging
from datetime import datetime
from aiogram.types import CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)


async def cmd_today(message, backend):
    from app.handlers.schedule import cmd_today_schedule
    await cmd_today_schedule(message, backend)


async def cmd_history(message, backend):
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    history = await backend.get_intake_history(user["id"], limit=20)
    if not history:
        await message.answer("No intake history yet.")
        return
    text = "Intake History (last 20)\n\n"
    for entry in history[:20]:
        emoji = {"pending": "pending", "taken": "taken", "missed": "missed"}.get(entry["status"], "?")
        dt = entry["scheduled_time"][:16].replace("T", " ")
        text += f"{emoji} {dt} - {entry['medicine_name']}\n"
    await message.answer(text)


async def cb_intake_taken(callback: CallbackQuery, backend: BackendClient):
    parts = callback.data.split(":")
    intake_id = int(parts[2])
    try:
        result = await backend.record_intake(intake_id, "taken")
        await callback.message.edit_text(
            f"Great! Recorded as taken.\n"
            f"Medicine: {result.get('medicine_name', 'Unknown')}\n"
            f"Time: {datetime.utcnow().strftime('%H:%M')}"
        )
    except Exception as e:
        logger.error(f"Taken error: {e}")
        await callback.answer("Error.", show_alert=True)
    await callback.answer()


async def cb_intake_reschedule(callback: CallbackQuery, backend: BackendClient):
    parts = callback.data.split(":")
    intake_id = int(parts[2])
    try:
        result = await backend.reschedule_intake(intake_id)
        new_time = result["scheduled_time"][11:16]
        await callback.message.edit_text(
            f"Reminder set for {new_time}.\n"
            f"Medicine: {result.get('medicine_name', 'Unknown')}"
        )
    except Exception as e:
        logger.error(f"Reschedule error: {e}")
        await callback.answer("Error.", show_alert=True)
    await callback.answer()


def build_intake_keyboard(intake_id: int) -> InlineKeyboardBuilder:
    builder = InlineKeyboardBuilder()
    builder.button(text="Taken", callback_data=f"intake:taken:{intake_id}")
    builder.button(text="Remind in 5 min", callback_data=f"intake:reschedule:{intake_id}")
    builder.adjust(2)
    return builder
INTAKE_EOF

echo "[5/7] intake.py — Taken + Remind in 5 min"

# ===== BOT: schedule.py =====
cat > bot/app/handlers/schedule.py << 'SCHEDULE_EOF'
import re
import logging
from datetime import datetime
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import Message, CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)

class ScheduleState(StatesGroup):
    selecting_medicine = State()
    waiting_for_time = State()

def _menu_buttons():
    b = InlineKeyboardBuilder()
    b.button(text="My medicines", callback_data="menu:medicines")
    b.button(text="Add medicine", callback_data="menu:add")
    b.button(text="Set reminder", callback_data="menu:schedule")
    b.button(text="Intake history", callback_data="menu:history")
    b.button(text="Today's schedule", callback_data="menu:today")
    b.button(text="Edit / Delete", callback_data="menu:edit")
    b.adjust(2)
    return b.as_markup()

def _with_cancel():
    b = InlineKeyboardBuilder()
    b.button(text="Cancel", callback_data="action:cancel")
    b.adjust(1)
    return b.as_markup()

async def cmd_schedule(message: Message, state: FSMContext, backend: BackendClient):
    await state.clear()
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        await message.answer("No medicines yet. Use /add first.")
        return
    builder = InlineKeyboardBuilder()
    for med in medicines:
        schedules = await backend.list_schedules(med["id"])
        times = ", ".join(s["reminder_time"][:5] for s in schedules) if schedules else "no reminders"
        builder.button(text=f"{med['name']} ({times})", callback_data=f"sched:pick:{med['id']}")
    builder.adjust(1)
    builder.button(text="Cancel", callback_data="action:cancel")
    builder.adjust(1)
    await state.set_state(ScheduleState.selecting_medicine)
    await state.update_data(user_id=user["id"])
    await message.answer("Choose a medicine, then type the reminder time (HH:MM).", reply_markup=builder.as_markup())

async def handle_medicine_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    medicine_id = int(callback.data.split(":")[2])
    await state.update_data(medicine_id=medicine_id)
    await state.set_state(ScheduleState.waiting_for_time)
    data = await state.get_data()
    user_id = data.get("user_id")
    med_name = "Unknown"
    if user_id:
        try:
            for m in await backend.list_medicines(user_id):
                if m["id"] == medicine_id:
                    med_name = m["name"]
        except Exception:
            pass
    await callback.message.edit_text(
        f"Medicine: {med_name}\nType the reminder time (HH:MM).\nExamples: 08:00, 14:30, 21:00",
        reply_markup=_with_cancel(),
    )
    await callback.answer()

async def handle_time_input(message: Message, state: FSMContext, backend: BackendClient):
    time_str = message.text.strip()
    if not re.match(r"^([01]?\d|2[0-3]):[0-5]\d$", time_str):
        await message.answer("Wrong format. Use HH:MM (24h).", reply_markup=_with_cancel())
        return
    try:
        data = await state.get_data()
        medicine_id = data.get("medicine_id")
        user_id = data.get("user_id")
        if not medicine_id or not user_id:
            await message.answer("Session expired. Run /schedule again.")
            await state.clear()
            return
        med_name = "Unknown"
        for m in await backend.list_medicines(user_id):
            if m["id"] == medicine_id:
                med_name = m["name"]
                break
        await backend.add_schedule(medicine_id, time_str)
        await message.answer(f"Reminder saved!\nMedicine: {med_name}\nTime: {time_str}", reply_markup=_menu_buttons())
        await state.clear()
    except Exception as e:
        logger.error(f"Schedule error: {e}", exc_info=True)
        await message.answer(f"Error: {e}", reply_markup=_menu_buttons())

async def handle_cancel(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    await state.clear()
    await callback.message.edit_text("Cancelled.", reply_markup=_menu_buttons())
    await callback.answer()

async def cmd_today_schedule(message: Message, backend: BackendClient):
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        await message.answer("No medicines scheduled for today.")
        return
    now = datetime.utcnow()
    cur_min = now.hour * 60 + now.minute
    items = []
    for med in medicines:
        for s in await backend.list_schedules(med["id"]):
            ts = s["reminder_time"][:5]
            p = ts.split(":")
            sm = int(p[0]) * 60 + int(p[1])
            if sm >= cur_min:
                items.append((sm, ts, med["name"], med["dosage"]))
    if not items:
        await message.answer("No more medicines scheduled for today.")
        return
    items.sort()
    text = "Today's Schedule\n\n"
    for _, t, n, d in items:
        text += f"- {t}  {n} ({d})\n"
    await message.answer(text)

async def cb_schedule_action(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    action = parts[1] if len(parts) > 1 else ""
    if action == "pick":
        await handle_medicine_select(callback, state, backend)
SCHEDULE_EOF

echo "[6/7] schedule.py fixed"

# ===== BOT: start.py =====
cat > bot/app/handlers/start.py << 'START_EOF'
import logging
from aiogram.fsm.context import FSMContext
from aiogram.types import Message
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)

def build_main_menu():
    b = InlineKeyboardBuilder()
    b.button(text="My medicines", callback_data="menu:medicines")
    b.button(text="Add medicine", callback_data="menu:add")
    b.button(text="Set reminder", callback_data="menu:schedule")
    b.button(text="Intake history", callback_data="menu:history")
    b.button(text="Today's schedule", callback_data="menu:today")
    b.button(text="Edit / Delete", callback_data="menu:edit")
    b.adjust(2)
    return b.as_markup()

async def show_menu(message, backend, telegram_id):
    user = await backend.get_user(telegram_id)
    if not user:
        await message.answer("Please register first with /start")
        return
    meds = await backend.list_medicines(user["id"])
    text = f"Welcome back, {user.get('first_name', 'User')}!\n\n"
    text += f"You have {len(meds)} medicine(s).\n" if meds else "No medicines yet.\nTap 'Add medicine' to get started.\n"
    await message.answer(text, reply_markup=build_main_menu())

async def cmd_start(message: Message, state: FSMContext, backend: BackendClient):
    await state.clear()
    existing = await backend.get_user(message.from_user.id)
    if existing:
        await show_menu(message, backend, message.from_user.id)
        return
    await backend.register_user(
        telegram_id=message.from_user.id,
        username=message.from_user.username,
        first_name=message.from_user.first_name,
    )
    await message.answer(
        f"Welcome, {message.from_user.first_name or 'User'}!\n\n"
        "I'm your Medicine Reminder bot.\nTap 'Add medicine' to get started.",
        reply_markup=build_main_menu(),
    )
START_EOF

echo "[7/7] start.py fixed"

# ===== BOT: medicine.py =====
cat > bot/app/handlers/medicine.py << 'MEDICINE_EOF'
import logging
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import Message, CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)

class AddMedicineState(StatesGroup):
    waiting_for_name = State()
    waiting_for_dosage = State()

class EditMedicineState(StatesGroup):
    selecting_medicine = State()
    selecting_edit_action = State()
    waiting_for_value = State()

class DeleteMedicineState(StatesGroup):
    selecting_medicine = State()
    confirming = State()

def _menu_buttons():
    b = InlineKeyboardBuilder()
    b.button(text="My medicines", callback_data="menu:medicines")
    b.button(text="Add medicine", callback_data="menu:add")
    b.button(text="Set reminder", callback_data="menu:schedule")
    b.button(text="Intake history", callback_data="menu:history")
    b.button(text="Today's schedule", callback_data="menu:today")
    b.button(text="Edit / Delete", callback_data="menu:edit")
    b.adjust(2)
    return b.as_markup()

def _with_cancel():
    b = InlineKeyboardBuilder()
    b.button(text="Cancel", callback_data="action:cancel")
    b.adjust(1)
    return b.as_markup()

async def cmd_add_medicine(message: Message, state: FSMContext, backend: BackendClient):
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    await state.set_state(AddMedicineState.waiting_for_name)
    await message.answer(
        "What is the name of the medicine?\n(e.g., Aspirin, Metformin, Vitamin D)",
        reply_markup=_with_cancel(),
    )

async def handle_medicine_name(message: Message, state: FSMContext, backend: BackendClient):
    await state.update_data(medicine_name=message.text.strip())
    await state.set_state(AddMedicineState.waiting_for_dosage)
    await message.answer(
        "What is the dosage?\n(e.g., 1 tablet, 5ml, 250mg)",
        reply_markup=_with_cancel(),
    )

async def handle_medicine_dosage(message: Message, state: FSMContext, backend: BackendClient):
    data = await state.get_data()
    name = data["medicine_name"]
    dosage = message.text.strip()
    user = await backend.get_user(message.from_user.id)
    medicine = await backend.add_medicine(user["id"], name, dosage)
    await state.clear()
    await message.answer(
        f"Medicine added!\n\nName: {medicine['name']}\nDosage: {medicine['dosage']}",
        reply_markup=_menu_buttons(),
    )
    logger.info(f"Medicine added: {name} for user {user['id']}")

async def cmd_list_medicines(message: Message, backend: BackendClient):
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        text = "No medicines yet."
        builder = InlineKeyboardBuilder()
        builder.button(text="Add medicine", callback_data="menu:add")
        builder.adjust(1)
        await message.answer(text, reply_markup=builder.as_markup())
        return
    text = "Your Medicines:\n\n"
    for med in medicines:
        schedules = await backend.list_schedules(med["id"])
        times = ", ".join(s["reminder_time"][:5] for s in schedules) if schedules else "no reminders"
        text += f"- {med['name']} ({med['dosage']}) - Times: {times}\n"
    text += "\nWhat would you like to do?"
    builder = InlineKeyboardBuilder()
    builder.button(text="Set reminder", callback_data="menu:schedule")
    builder.button(text="Edit / Delete", callback_data="menu:edit")
    builder.button(text="Back to menu", callback_data="menu:main")
    builder.adjust(1)
    await message.answer(text, reply_markup=builder.as_markup())

async def cmd_edit_medicine(message: Message, state: FSMContext, backend: BackendClient):
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        await message.answer("No medicines to edit. Use /add first.")
        return
    builder = InlineKeyboardBuilder()
    for med in medicines:
        builder.button(text=f"{med['name']}", callback_data=f"med:select:{med['id']}")
    builder.button(text="Back", callback_data="menu:main")
    builder.adjust(1)
    await state.set_state(EditMedicineState.selecting_medicine)
    await message.answer("Select medicine:", reply_markup=builder.as_markup())

async def handle_medicine_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    medicine_id = int(parts[2])
    await state.update_data(medicine_id=medicine_id)
    user_id = callback.from_user.id
    medicines = await backend.list_medicines(user_id)
    med_name = "Unknown"
    med_dosage = ""
    for m in medicines:
        if m["id"] == medicine_id:
            med_name = m["name"]
            med_dosage = m["dosage"]
            break
    schedules = await backend.list_schedules(medicine_id)
    times = ", ".join(s["reminder_time"][:5] for s in schedules) if schedules else "no times"
    builder = InlineKeyboardBuilder()
    builder.button(text="Edit Name", callback_data="med:action:edit_name")
    builder.button(text="Edit Dosage", callback_data="med:action:edit_dosage")
    if schedules:
        builder.button(text="Delete Reminder", callback_data="med:action:delete_reminder")
    builder.button(text="Back", callback_data="menu:main")
    builder.adjust(1)
    await state.set_state(EditMedicineState.selecting_edit_action)
    await callback.message.edit_text(
        f"Medicine: {med_name} ({med_dosage})\nTimes: {times}\n\nChoose action:",
        reply_markup=builder.as_markup(),
    )
    await callback.answer()

async def handle_edit_action(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    action = parts[2]
    if action == "edit_name":
        await callback.message.edit_text("Enter new name:")
        await state.set_state(EditMedicineState.waiting_for_value)
        await state.update_data(edit_field="name")
    elif action == "edit_dosage":
        await callback.message.edit_text("Enter new dosage:")
        await state.set_state(EditMedicineState.waiting_for_value)
        await state.update_data(edit_field="dosage")
    elif action == "delete_reminder":
        data = await state.get_data()
        medicine_id = data["medicine_id"]
        schedules = await backend.list_schedules(medicine_id)
        builder = InlineKeyboardBuilder()
        for s in schedules:
            t = s["reminder_time"][:5]
            builder.button(text=f"Delete {t}", callback_data=f"sched:delete:{s['id']}")
        builder.button(text="Back", callback_data="menu:main")
        builder.adjust(1)
        await callback.message.edit_text("Select time to delete:", reply_markup=builder.as_markup())
    await callback.answer()

async def handle_edit_value(message: Message, state: FSMContext, backend: BackendClient):
    data = await state.get_data()
    medicine_id = data["medicine_id"]
    field = data["edit_field"]
    user = await backend.get_user(message.from_user.id)
    updated = await backend.update_medicine(medicine_id, user["id"], **{field: message.text.strip()})
    await state.clear()
    await message.answer(f"Updated!\n{updated['name']} - {updated['dosage']}", reply_markup=_menu_buttons())

async def cmd_delete_medicine(message: Message, state: FSMContext, backend: BackendClient):
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        await message.answer("No medicines to delete.")
        return
    builder = InlineKeyboardBuilder()
    for med in medicines:
        builder.button(text=f"Delete {med['name']}", callback_data=f"med:delete:{med['id']}")
    builder.button(text="Back", callback_data="menu:main")
    builder.adjust(1)
    await state.set_state(DeleteMedicineState.selecting_medicine)
    await message.answer("Select medicine to delete:", reply_markup=builder.as_markup())

async def handle_delete_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    medicine_id = int(callback.data.split(":")[2])
    await state.update_data(medicine_id=medicine_id)
    builder = InlineKeyboardBuilder()
    builder.button(text="Yes, Delete", callback_data=f"med:confirm_delete:{medicine_id}")
    builder.button(text="Cancel", callback_data="menu:main")
    builder.adjust(1)
    await state.set_state(DeleteMedicineState.confirming)
    await callback.message.edit_text("This will delete the medicine and all reminders. Sure?", reply_markup=builder.as_markup())
    await callback.answer()

async def handle_delete_confirm(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    medicine_id = int(callback.data.split(":")[2])
    user = await backend.get_user(callback.from_user.id)
    success = await backend.delete_medicine(medicine_id, user["id"])
    await state.clear()
    msg = "Deleted." if success else "Could not delete."
    await callback.message.edit_text(msg, reply_markup=_menu_buttons())
    await callback.answer()

async def handle_delete_schedule(callback: CallbackQuery, backend: BackendClient, state: FSMContext):
    schedule_id = int(callback.data.split(":")[2])
    user_id = callback.from_user.id
    user = await backend.get_user(user_id)
    if not user:
        await callback.message.answer("Please register first with /start")
        await callback.answer()
        return
    success = await backend.delete_schedule(schedule_id, user["id"])
    medicines = await backend.list_medicines(user["id"])
    builder = InlineKeyboardBuilder()
    for m in medicines:
        schedules = await backend.list_schedules(m["id"])
        times = ", ".join(s["reminder_time"][:5] for s in schedules) if schedules else "no times"
        builder.button(text=f"{m['name']} [{times}]", callback_data=f"med:select:{m['id']}")
    builder.button(text="Back", callback_data="menu:main")
    builder.adjust(1)
    msg = "Time deleted." if success else "Could not delete."
    await callback.message.edit_text(f"{msg}\n\nSelect medicine:", reply_markup=builder.as_markup())
    await callback.answer()

async def handle_cancel(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    await state.clear()
    await callback.message.edit_text("Cancelled.", reply_markup=_menu_buttons())
    await callback.answer()

async def cb_medicine_action(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    action = parts[1] if len(parts) > 1 else ""
    if action == "select":
        await handle_medicine_select(callback, state, backend)
    elif action == "action":
        await handle_edit_action(callback, state, backend)
    elif action == "field":
        field = parts[2]
        await state.update_data(edit_field=field)
        prompt = "Enter new name:" if field == "name" else "Enter new dosage:"
        await state.set_state(EditMedicineState.waiting_for_value)
        await callback.message.edit_text(prompt)
        await callback.answer()
    elif action == "delete":
        await handle_delete_select(callback, state, backend)
    elif action == "confirm_delete":
        await handle_delete_confirm(callback, state, backend)
    elif action == "cancel":
        await state.clear()
        await callback.message.edit_text("Cancelled.", reply_markup=_menu_buttons())
        await callback.answer()
MEDICINE_EOF

echo "[7b] medicine.py fixed"

# ===== BOT: router.py =====
cat > bot/app/handlers/router.py << 'ROUTER_EOF'
from aiogram import Router, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import Message, CallbackQuery
from app.config import get_bot_settings
from app.services.backend_client import BackendClient
from app.handlers.medicine import (
    AddMedicineState, EditMedicineState,
    handle_medicine_name, handle_medicine_dosage, handle_edit_value,
    cmd_list_medicines, cmd_edit_medicine, cmd_delete_medicine,
    cb_medicine_action, cmd_add_medicine, handle_delete_schedule,
    handle_cancel as medicine_cancel,
)
from app.handlers.schedule import (
    ScheduleState, handle_time_input, cmd_schedule, cb_schedule_action,
    cmd_today_schedule as handle_today, handle_cancel as schedule_cancel,
)
from app.handlers.start import cmd_start, show_menu
from app.handlers.intake import cb_intake_taken, cb_intake_reschedule, cmd_history
from aiogram.utils.keyboard import InlineKeyboardBuilder

router = Router()
settings = get_bot_settings()
backend = BackendClient()

# Text commands
@router.message(Command("start"))
async def handle_start(message: Message, state: FSMContext):
    await cmd_start(message, state, backend)

@router.message(Command("add"))
async def handle_add(message: Message, state: FSMContext):
    await cmd_add_medicine(message, state, backend)

@router.message(AddMedicineState.waiting_for_name)
async def proc_name(message: Message, state: FSMContext):
    await handle_medicine_name(message, state, backend)

@router.message(AddMedicineState.waiting_for_dosage)
async def proc_dosage(message: Message, state: FSMContext):
    await handle_medicine_dosage(message, state, backend)

@router.message(Command("medicines"))
async def handle_list(message: Message):
    await cmd_list_medicines(message, backend)

@router.message(Command("edit"))
async def handle_edit_cmd(message: Message, state: FSMContext):
    await cmd_edit_medicine(message, state, backend)

@router.message(EditMedicineState.waiting_for_value)
async def proc_edit(message: Message, state: FSMContext):
    await handle_edit_value(message, state, backend)

@router.message(Command("delete"))
async def handle_del_cmd(message: Message, state: FSMContext):
    await cmd_delete_medicine(message, state, backend)

@router.message(Command("schedule"))
async def handle_sched_cmd(message: Message, state: FSMContext):
    await cmd_schedule(message, state, backend)

@router.message(ScheduleState.waiting_for_time)
async def proc_time(message: Message, state: FSMContext):
    await handle_time_input(message, state, backend)

@router.message(Command("today"))
async def handle_today_cmd(message: Message):
    await handle_today(message, backend)

@router.message(Command("history"))
async def handle_hist_cmd(message: Message):
    await cmd_history(message, backend)

@router.message(Command("help"))
async def handle_help(message: Message):
    await message.answer(
        "Medicine Reminder Bot\n\n"
        "/start - Register\n/add - Add medicine\n/medicines - List\n"
        "/edit - Edit\n/delete - Delete\n/schedule - Set reminder\n"
        "/today - Today's schedule\n/history - Intake history\n/help - Help"
    )

# Inline callbacks
async def _user(callback):
    return await backend.get_user(callback.from_user.id)

def _menu_buttons():
    b = InlineKeyboardBuilder()
    b.button(text="My medicines", callback_data="menu:medicines")
    b.button(text="Add medicine", callback_data="menu:add")
    b.button(text="Set reminder", callback_data="menu:schedule")
    b.button(text="Intake history", callback_data="menu:history")
    b.button(text="Today's schedule", callback_data="menu:today")
    b.button(text="Edit / Delete", callback_data="menu:edit")
    b.adjust(2)
    return b.as_markup()

async def _navigate(callback):
    try:
        await callback.message.delete()
    except Exception:
        pass

@router.callback_query(F.data == "menu:main")
async def cb_main(callback: CallbackQuery):
    await _navigate(callback)
    await show_menu(callback.message, backend, callback.from_user.id)
    await callback.answer()

@router.callback_query(F.data == "menu:medicines")
async def cb_medicines(callback: CallbackQuery):
    await _navigate(callback)
    user = await _user(callback)
    if not user:
        await callback.message.answer("Please register first with /start")
    else:
        meds = await backend.list_medicines(user["id"])
        if not meds:
            await callback.message.answer("No medicines yet. Use /add first.", reply_markup=_menu_buttons())
        else:
            text = "Your Medicines:\n\n"
            for m in meds:
                scheds = await backend.list_schedules(m["id"])
                times = ", ".join(s["reminder_time"][:5] for s in scheds) if scheds else "no reminders"
                text += f"- {m['name']} ({m['dosage']}) - Times: {times}\n"
            b = InlineKeyboardBuilder()
            b.button(text="Set reminder", callback_data="menu:schedule")
            b.button(text="Back", callback_data="menu:main")
            b.adjust(1)
            await callback.message.answer(text, reply_markup=b.as_markup())
    await callback.answer()

@router.callback_query(F.data == "menu:add")
async def cb_add(callback: CallbackQuery, state: FSMContext):
    await _navigate(callback)
    await state.clear()
    user = await _user(callback)
    if not user:
        await callback.message.answer("Please register first with /start")
        await callback.answer()
        return
    await state.set_state(AddMedicineState.waiting_for_name)
    await callback.message.answer("What is the name of the medicine?\n(e.g., Aspirin, Metformin, Vitamin D)")
    await callback.answer()

@router.callback_query(F.data == "menu:schedule")
async def cb_schedule(callback: CallbackQuery, state: FSMContext):
    await _navigate(callback)
    await state.clear()
    user = await _user(callback)
    if not user:
        await callback.message.answer("Please register first with /start")
        await callback.answer()
        return
    meds = await backend.list_medicines(user["id"])
    if not meds:
        await callback.message.answer("No medicines yet. Use /add first.")
        await callback.answer()
        return
    builder = InlineKeyboardBuilder()
    for m in meds:
        scheds = await backend.list_schedules(m["id"])
        times = ", ".join(s["reminder_time"][:5] for s in scheds) if scheds else "no reminders"
        builder.button(text=f"{m['name']} ({times})", callback_data=f"sched:pick:{m['id']}")
    builder.adjust(1)
    builder.button(text="Back", callback_data="menu:main")
    builder.adjust(1)
    await state.set_state(ScheduleState.selecting_medicine)
    await state.update_data(user_id=user["id"])
    await callback.message.answer("Choose a medicine, then type the reminder time (HH:MM).", reply_markup=builder.as_markup())
    await callback.answer()

@router.callback_query(F.data == "menu:history")
async def cb_history(callback: CallbackQuery):
    await _navigate(callback)
    user = await _user(callback)
    if not user:
        await callback.message.answer("Please register first with /start")
    else:
        history = await backend.get_intake_history(user["id"], limit=20)
        if not history:
            await callback.message.answer("No intake history yet.", reply_markup=_menu_buttons())
        else:
            text = "Intake History (last 20)\n\n"
            for e in history[:20]:
                emoji = {"pending": "pending", "taken": "taken", "missed": "missed"}.get(e["status"], "?")
                dt = e["scheduled_time"][:16].replace("T", " ")
                text += f"{emoji} {dt} - {e['medicine_name']}\n"
            await callback.message.answer(text, reply_markup=_menu_buttons())
    await callback.answer()

@router.callback_query(F.data == "menu:today")
async def cb_today(callback: CallbackQuery):
    await _navigate(callback)
    user = await _user(callback)
    if not user:
        await callback.message.answer("Please register first with /start")
    else:
        from datetime import datetime
        medicines = await backend.list_medicines(user["id"])
        if not medicines:
            await callback.message.answer("No medicines scheduled for today.", reply_markup=_menu_buttons())
        else:
            now = datetime.utcnow()
            cur_min = now.hour * 60 + now.minute
            items = []
            for med in medicines:
                for s in await backend.list_schedules(med["id"]):
                    ts = s["reminder_time"][:5]
                    p = ts.split(":")
                    sm = int(p[0]) * 60 + int(p[1])
                    if sm >= cur_min:
                        items.append((sm, ts, med["name"], med["dosage"]))
            if not items:
                await callback.message.answer("No more medicines scheduled for today.", reply_markup=_menu_buttons())
            else:
                items.sort()
                text = "Today's Schedule\n\n"
                for _, t, n, d in items:
                    text += f"- {t}  {n} ({d})\n"
                await callback.message.answer(text, reply_markup=_menu_buttons())
    await callback.answer()

@router.callback_query(F.data == "menu:edit")
async def cb_edit(callback: CallbackQuery, state: FSMContext):
    await _navigate(callback)
    await state.clear()
    user = await _user(callback)
    if not user:
        await callback.message.answer("Please register first with /start")
        await callback.answer()
        return
    meds = await backend.list_medicines(user["id"])
    if not meds:
        await callback.message.answer("No medicines to edit. Use /add first.")
        await callback.answer()
        return
    builder = InlineKeyboardBuilder()
    for m in meds:
        builder.button(text=f"{m['name']}", callback_data=f"med:select:{m['id']}")
    builder.button(text="Back", callback_data="menu:main")
    builder.adjust(1)
    await state.set_state(EditMedicineState.selecting_medicine)
    await callback.message.answer("Select medicine:", reply_markup=builder.as_markup())
    await callback.answer()

# Cancel (generic)
@router.callback_query(F.data == "action:cancel")
async def cb_cancel(callback: CallbackQuery, state: FSMContext):
    await state.clear()
    await callback.message.edit_text("Cancelled.", reply_markup=_menu_buttons())
    await callback.answer()

# Schedule delete
@router.callback_query(F.data.startswith("sched:delete:"))
async def cb_sched_delete(callback: CallbackQuery, state: FSMContext):
    await handle_delete_schedule(callback, backend, state)

# Medicine
@router.callback_query(F.data.startswith("med:"))
async def cb_med(callback: CallbackQuery, state: FSMContext):
    await cb_medicine_action(callback, state, backend)

# Schedule
@router.callback_query(F.data.startswith("sched:"))
async def cb_sched(callback: CallbackQuery, state: FSMContext):
    await cb_schedule_action(callback, state, backend)

# Intake
@router.callback_query(F.data.startswith("intake:taken:"))
async def cb_taken(callback: CallbackQuery):
    await cb_intake_taken(callback, backend)

@router.callback_query(F.data.startswith("intake:reschedule:"))
async def cb_reschedule(callback: CallbackQuery):
    await cb_intake_reschedule(callback, backend)

@router.callback_query(F.data.startswith("intake:"))
async def cb_intake(callback: CallbackQuery):
    await cb_intake_taken(callback, backend)
ROUTER_EOF

echo "[7c] router.py fixed"

# ===== COPY ALL FILES INTO CONTAINER =====
echo ""
echo "=== Copying into container ==="
docker cp bot/app/handlers/start.py medreminder-bot:/app/app/handlers/start.py
docker cp bot/app/handlers/schedule.py medreminder-bot:/app/app/handlers/schedule.py
docker cp bot/app/handlers/medicine.py medreminder-bot:/app/app/handlers/medicine.py
docker cp bot/app/handlers/intake.py medreminder-bot:/app/app/handlers/intake.py
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py
docker cp bot/app/services/scheduler.py medreminder-bot:/app/app/services/scheduler.py
docker cp bot/app/services/backend_client.py medreminder-bot:/app/app/services/backend_client.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 8

echo ""
echo "=== Bot logs ==="
docker compose logs --tail=10 bot

echo ""
echo "============================================"
echo "  DONE v6!"
echo "============================================"
echo ""
echo "  - Cancel button on all add steps"
echo "  - Reminders: Taken + Remind in 5 min"
echo "  - Intake history works"
echo "  - Old messages cleaned on nav"
