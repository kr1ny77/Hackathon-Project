#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "============================================"
echo "  FIX v9 — Group reminders, show count"
echo "============================================"

# 1. scheduler.py — группировка по лекарству + времени
cat > bot/app/services/scheduler.py << 'SCHEDULER_EOF'
import asyncio, logging
from datetime import datetime, timezone, timedelta
from collections import defaultdict
from aiogram import Bot
from app.config import get_bot_settings
from app.services.backend_client import BackendClient
from app.handlers.intake import build_intake_keyboard

logger = logging.getLogger(__name__)

MOSCOW_TZ = timezone(timedelta(hours=3))

class ReminderScheduler:
    def __init__(self, bot: Bot):
        self.bot = bot
        self.settings = get_bot_settings()
        self.backend = BackendClient()
        self._task = None
        self._sent = set()

    async def start(self):
        logger.info("Reminder scheduler started (Moscow time)")
        self._task = asyncio.create_task(self._run())

    async def stop(self):
        if self._task:
            self._task.cancel()
            try: await self._task
            except asyncio.CancelledError: pass
        await self.backend.close()
        logger.info("Reminder scheduler stopped")

    async def _run(self):
        while True:
            try: await self._check()
            except Exception as e: logger.error(f"Scheduler: {e}")
            await asyncio.sleep(self.settings.REMINDER_CHECK_INTERVAL)

    async def _check(self):
        now = datetime.now(MOSCOW_TZ)
        hh, mm = now.hour, now.minute

        # 1) Группируем новые расписания по (telegram_id, medicine_name)
        try:
            schedules = await self.backend.get_active_schedules_with_details(hh, mm)
        except Exception as e:
            logger.error(f"Schedules: {e}"); schedules = []

        groups = defaultdict(list)
        for info in schedules:
            key = (info["telegram_id"], info["medicine_name"])
            groups[key].append(info)

        for (tid, med_name), infos in groups.items():
            count = len(infos)
            info = infos[0]
            try:
                st = now.strftime("%Y-%m-%dT%H:%M:%S")
                intake = await self.backend.create_pending_intake(
                    user_id=info["user_id"], schedule_id=info["schedule_id"],
                    medicine_name=med_name, scheduled_time=st,
                )
                if intake:
                    self._sent.add(intake["id"])
                    await self._send(intake, tid, med_name, count)
            except Exception as e: logger.error(f"New: {e}")

        # 2) Rescheduled
        try: pending = await self.backend.get_pending_due()
        except Exception as e: logger.error(f"Pending: {e}"); pending = []

        for intake in pending:
            if intake["id"] not in self._sent:
                try:
                    tid = await self._get_tid(intake["user_id"])
                    if tid:
                        self._sent.add(intake["id"])
                        await self._send(intake, tid, intake.get("medicine_name","Unknown"), 1)
                except Exception as e: logger.error(f"Resched: {e}")

    async def _get_tid(self, uid):
        try:
            c = await self.backend._get_client()
            r = await c.get(f"/users/id/{uid}")
            if r.status_code == 200: return r.json()["telegram_id"]
        except: pass
        return None

    async def _send(self, intake, tid, name, count):
        now = datetime.now(MOSCOW_TZ)
        qty = f" x{count}" if count > 1 else ""
        msg = f"Medicine Reminder\n\nMedicine: {name}{qty}\nTime: {now.strftime('%H:%M')}\n\nHave you taken your medicine?"
        kb = build_intake_keyboard(intake["id"])
        await self.bot.send_message(chat_id=tid, text=msg, reply_markup=kb.as_markup())
        logger.info(f"Sent to {tid}: {name} x{count} (#{intake['id']})")
SCHEDULER_EOF

# 2. intake.py — показывать количество в истории
cat > bot/app/handlers/intake.py << 'INTAKE_EOF'
import logging
from datetime import datetime, timezone, timedelta
from aiogram.types import CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)

async def cmd_today(message, backend):
    from app.handlers.schedule import cmd_today_schedule
    await cmd_today_schedule(message, backend)

async def cmd_history(message, backend):
    user = await backend.get_user(message.from_user.id)
    if not user: await message.answer("Please register first with /start"); return
    history = await backend.get_intake_history(user["id"], limit=30)
    if not history: await message.answer("No intake history yet."); return

    # Группируем по (medicine_name + scheduled_time) и считаем количество
    from collections import Counter
    counts = Counter()
    for entry in history:
        key = (entry["medicine_name"], entry["scheduled_time"][:16].replace("T"," "))
        counts[key] += 1

    text = "Intake History (last 30)\n\n"
    seen = set()
    for entry in history[:30]:
        key = (entry["medicine_name"], entry["scheduled_time"][:16].replace("T"," "))
        if key in seen: continue
        seen.add(key)
        emoji = {"pending":"pending","taken":"taken","missed":"missed"}.get(entry["status"],"?")
        dt = entry["scheduled_time"][:16].replace("T"," ")
        cnt = counts[key]
        qty = f" x{cnt}" if cnt > 1 else ""
        text += f"{emoji} {dt} - {entry['medicine_name']}{qty}\n"
    await message.answer(text)

async def cb_intake_taken(callback: CallbackQuery, backend: BackendClient):
    parts = callback.data.split(":")
    intake_id = int(parts[2])
    try:
        result = await backend.record_intake(intake_id, "taken")
        now = datetime.now(timezone(timedelta(hours=3)))
        await callback.message.edit_text(f"Great! Recorded as taken.\nMedicine: {result.get('medicine_name', 'Unknown')}\nTime: {now.strftime('%H:%M')}")
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
        await callback.message.edit_text(f"Reminder set for {new_time}.\nMedicine: {result.get('medicine_name', 'Unknown')}")
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

# 3. schedule.py — сегодня тоже с группировкой
cat > bot/app/handlers/schedule.py << 'SCHEDULE_EOF'
import re, logging
from datetime import datetime, timezone, timedelta
from collections import Counter
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
    if not user: await message.answer("Please register first with /start"); return
    medicines = await backend.list_medicines(user["id"])
    if not medicines: await message.answer("No medicines yet. Use /add first."); return
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
    await message.answer("Choose a medicine, then type time (HH:MM).", reply_markup=builder.as_markup())

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
                if m["id"] == medicine_id: med_name = m["name"]
        except: pass
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
            await state.clear(); return
        med_name = "Unknown"
        for m in await backend.list_medicines(user_id):
            if m["id"] == medicine_id: med_name = m["name"]; break
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
    if not user: await message.answer("Please register first with /start"); return
    medicines = await backend.list_medicines(user["id"])
    if not medicines: await message.answer("No medicines scheduled for today."); return
    now = datetime.now(timezone(timedelta(hours=3)))
    cur_min = now.hour * 60 + now.minute
    items = []
    for med in medicines:
        for s in await backend.list_schedules(med["id"]):
            ts = s["reminder_time"][:5]
            p = ts.split(":")
            sm = int(p[0]) * 60 + int(p[1])
            if sm >= cur_min: items.append((sm, ts, med["name"], med["dosage"]))
    if not items: await message.answer("No more medicines scheduled for today."); return

    # Группируем и считаем количество
    counts = Counter((t, n, d) for _, t, n, d in items)
    seen = set()
    items.sort()
    text = "Today's Schedule\n\n"
    for _, t, n, d in items:
        key = (t, n, d)
        if key in seen: continue
        seen.add(key)
        cnt = counts[key]
        qty = f" x{cnt}" if cnt > 1 else ""
        text += f"- {t}  {n}{qty} ({d})\n"
    await message.answer(text)

async def cb_schedule_action(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    action = parts[1] if len(parts) > 1 else ""
    if action == "pick": await handle_medicine_select(callback, state, backend)
SCHEDULE_EOF

# 4. Copy & Restart
echo "=== Copying into container ==="
docker cp bot/app/services/scheduler.py medreminder-bot:/app/app/services/scheduler.py
docker cp bot/app/handlers/intake.py medreminder-bot:/app/app/handlers/intake.py
docker cp bot/app/handlers/schedule.py medreminder-bot:/app/app/handlers/schedule.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 8

echo ""
echo "=== Bot Logs ==="
docker compose logs --tail 8 bot

echo ""
echo "============================================"
echo "  FIX v9 APPLIED!"
echo "============================================"
echo ""
echo "  1. Reminders grouped: one message per medicine + time"
echo "  2. Count shown: 'Aspirin x2' instead of 2 messages"
echo "  3. Today's schedule: grouped with count"
echo "  4. Intake history: grouped with count"
