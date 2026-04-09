#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "============================================"
echo "  FIX v8 — Timezone, Cancel, Delete Medicine"
echo "============================================"

# 1. scheduler.py — московское время UTC+3
cat > bot/app/services/scheduler.py << 'SCHEDULER_EOF'
import asyncio, logging
from datetime import datetime, timezone, timedelta
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
        try: schedules = await self.backend.get_active_schedules_with_details(hh, mm)
        except Exception as e: logger.error(f"Schedules: {e}"); schedules = []

        for info in schedules:
            try:
                tid = info["telegram_id"]
                st = now.strftime("%Y-%m-%dT%H:%M:%S")
                intake = await self.backend.create_pending_intake(user_id=info["user_id"], schedule_id=info["schedule_id"], medicine_name=info["medicine_name"], scheduled_time=st)
                if intake:
                    self._sent.add(intake["id"])
                    await self._send(intake, tid, info["medicine_name"])
            except Exception as e: logger.error(f"New: {e}")

        try: pending = await self.backend.get_pending_due()
        except Exception as e: logger.error(f"Pending: {e}"); pending = []

        for intake in pending:
            if intake["id"] not in self._sent:
                try:
                    tid = await self._get_tid(intake["user_id"])
                    if tid:
                        self._sent.add(intake["id"])
                        await self._send(intake, tid, intake.get("medicine_name","Unknown"))
                except Exception as e: logger.error(f"Resched: {e}")

    async def _get_tid(self, uid):
        try:
            c = await self.backend._get_client()
            r = await c.get(f"/users/id/{uid}")
            if r.status_code == 200: return r.json()["telegram_id"]
        except: pass
        return None

    async def _send(self, intake, tid, name):
        now = datetime.now(MOSCOW_TZ)
        msg = f"Medicine Reminder\n\nMedicine: {name}\nTime: {now.strftime('%H:%M')}\n\nHave you taken your medicine?"
        kb = build_intake_keyboard(intake["id"])
        await self.bot.send_message(chat_id=tid, text=msg, reply_markup=kb.as_markup())
        logger.info(f"Sent to {tid}: {name} (#{intake['id']})")
SCHEDULER_EOF

# 2. medicine.py — добавить Delete Medicine + Cancel при Add
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
    confirming_delete = State()

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
    builder.button(text="Delete Medicine", callback_data=f"med:delete_full:{medicine_id}")
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

async def handle_confirm_delete_medicine(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    medicine_id = int(parts[2])
    await state.update_data(medicine_id=medicine_id)
    user_id = callback.from_user.id
    medicines = await backend.list_medicines(user_id)
    med_name = "Unknown"
    for m in medicines:
        if m["id"] == medicine_id:
            med_name = m["name"]
            break
    builder = InlineKeyboardBuilder()
    builder.button(text="Yes, Delete", callback_data=f"med:confirm_delete_full:{medicine_id}")
    builder.button(text="Cancel", callback_data="menu:main")
    builder.adjust(1)
    await state.set_state(EditMedicineState.confirming_delete)
    await callback.message.edit_text(
        f"⚠️ Delete \"{med_name}\"?\nThis will remove all reminders and history.",
        reply_markup=builder.as_markup(),
    )
    await callback.answer()

async def handle_execute_delete_medicine(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    medicine_id = int(parts[3])
    user = await backend.get_user(callback.from_user.id)
    success = await backend.delete_medicine(medicine_id, user["id"])
    await state.clear()
    msg = "Medicine deleted." if success else "Could not delete."
    await callback.message.edit_text(msg, reply_markup=_menu_buttons())
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
    elif action == "delete_full":
        await handle_confirm_delete_medicine(callback, state, backend)
    elif action == "confirm_delete_full":
        await handle_execute_delete_medicine(callback, state, backend)
    elif action == "cancel":
        await state.clear()
        await callback.message.edit_text("Cancelled.", reply_markup=_menu_buttons())
        await callback.answer()
MEDICINE_EOF

# 3. schedule.py — Cancel при вводе времени
cat > bot/app/handlers/schedule.py << 'SCHEDULE_EOF'
import re, logging
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
    from datetime import timezone, timedelta
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
    items.sort()
    text = "Today's Schedule\n\n"
    for _, t, n, d in items: text += f"- {t}  {n} ({d})\n"
    await message.answer(text)

async def cb_schedule_action(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    action = parts[1] if len(parts) > 1 else ""
    if action == "pick": await handle_medicine_select(callback, state, backend)
SCHEDULE_EOF

# 4. start.py — Cancel при Add
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
    if not user: await message.answer("Please register first with /start"); return
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

# 5. router.py — Cancel при Add, Delete Medicine
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
)
from app.handlers.schedule import (
    ScheduleState, handle_time_input, cmd_schedule, cb_schedule_action,
    cmd_today_schedule as handle_today,
)
from app.handlers.start import cmd_start, show_menu
from app.handlers.intake import cb_intake_taken, cb_intake_reschedule, cmd_history
from aiogram.utils.keyboard import InlineKeyboardBuilder

router = Router()
settings = get_bot_settings()
backend = BackendClient()

# === TEXT COMMANDS ===
@router.message(Command("start"))
async def handle_start(message: Message, state: FSMContext): await cmd_start(message, state, backend)
@router.message(Command("add"))
async def handle_add(message: Message, state: FSMContext): await cmd_add_medicine(message, state, backend)
@router.message(AddMedicineState.waiting_for_name)
async def proc_name(message: Message, state: FSMContext): await handle_medicine_name(message, state, backend)
@router.message(AddMedicineState.waiting_for_dosage)
async def proc_dosage(message: Message, state: FSMContext): await handle_medicine_dosage(message, state, backend)
@router.message(Command("medicines"))
async def handle_list(message: Message): await cmd_list_medicines(message, backend)
@router.message(Command("edit"))
async def handle_edit_cmd(message: Message, state: FSMContext): await cmd_edit_medicine(message, state, backend)
@router.message(EditMedicineState.waiting_for_value)
async def proc_edit(message: Message, state: FSMContext): await handle_edit_value(message, state, backend)
@router.message(Command("delete"))
async def handle_del_cmd(message: Message, state: FSMContext): await cmd_delete_medicine(message, state, backend)
@router.message(Command("schedule"))
async def handle_sched_cmd(message: Message, state: FSMContext): await cmd_schedule(message, state, backend)
@router.message(ScheduleState.waiting_for_time)
async def proc_time(message: Message, state: FSMContext): await handle_time_input(message, state, backend)
@router.message(Command("today"))
async def handle_today_cmd(message: Message): await handle_today(message, backend)
@router.message(Command("history"))
async def handle_hist_cmd(message: Message): await cmd_history(message, backend)
@router.message(Command("help"))
async def handle_help(message: Message):
    await message.answer("Medicine Reminder Bot\n\n/start - Register\n/add - Add medicine\n/medicines - List\n/edit - Edit\n/delete - Delete\n/schedule - Set reminder\n/today - Schedule\n/history - Intake\n/help - Help")

# === INLINE CALLBACKS ===
async def _user(callback): return await backend.get_user(callback.from_user.id)
def _menu_buttons():
    b = InlineKeyboardBuilder()
    for txt, cb in [("My medicines","menu:medicines"),("Add medicine","menu:add"),("Set reminder","menu:schedule"),("Intake history","menu:history"),("Today's schedule","menu:today"),("Edit / Delete","menu:edit")]:
        b.button(text=txt, callback_data=cb)
    b.adjust(2)
    return b.as_markup()
def _with_cancel():
    b = InlineKeyboardBuilder()
    b.button(text="Cancel", callback_data="action:cancel")
    b.adjust(1)
    return b.as_markup()
async def _navigate(callback):
    try: await callback.message.delete()
    except: pass

@router.callback_query(F.data == "menu:main")
async def cb_main(callback: CallbackQuery): await _navigate(callback); await show_menu(callback.message, backend, callback.from_user.id); await callback.answer()

@router.callback_query(F.data == "menu:medicines")
async def cb_medicines(callback: CallbackQuery):
    await _navigate(callback)
    user = await _user(callback)
    if not user: await callback.message.answer("Please register first with /start")
    else:
        meds = await backend.list_medicines(user["id"])
        if not meds: await callback.message.answer("No medicines yet.", reply_markup=_menu_buttons())
        else:
            txt = "Your Medicines:\n\n"
            for m in meds:
                sc = await backend.list_schedules(m["id"])
                ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
                txt += f"- {m['name']} ({m['dosage']}) - {ts}\n"
            b = InlineKeyboardBuilder(); b.button(text="Set reminder", callback_data="menu:schedule"); b.button(text="Back", callback_data="menu:main"); b.adjust(1)
            await callback.message.answer(txt, reply_markup=b.as_markup())
    await callback.answer()

@router.callback_query(F.data == "menu:add")
async def cb_add(callback: CallbackQuery, state: FSMContext):
    await _navigate(callback); await state.clear()
    user = await _user(callback)
    if not user: await callback.message.answer("Please register first with /start"); await callback.answer(); return
    await state.set_state(AddMedicineState.waiting_for_name)
    await callback.message.answer("What is the name of the medicine?\n(e.g., Aspirin, Metformin)", reply_markup=_with_cancel())
    await callback.answer()

@router.callback_query(F.data == "menu:schedule")
async def cb_schedule(callback: CallbackQuery, state: FSMContext):
    await _navigate(callback); await state.clear()
    user = await _user(callback)
    if not user: await callback.message.answer("Please register first with /start"); await callback.answer(); return
    meds = await backend.list_medicines(user["id"])
    if not meds: await callback.message.answer("No medicines yet. Use /add first."); await callback.answer(); return
    builder = InlineKeyboardBuilder()
    for m in meds:
        sc = await backend.list_schedules(m["id"])
        ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
        builder.button(text=f"{m['name']} ({ts})", callback_data=f"sched:pick:{m['id']}")
    builder.adjust(1)
    builder.button(text="Cancel", callback_data="action:cancel")
    builder.adjust(1)
    await state.set_state(ScheduleState.selecting_medicine)
    await state.update_data(user_id=user["id"])
    await callback.message.answer("Choose a medicine, then type time (HH:MM).", reply_markup=builder.as_markup())
    await callback.answer()

@router.callback_query(F.data == "menu:history")
async def cb_history(callback: CallbackQuery):
    await _navigate(callback)
    user = await _user(callback)
    if not user: await callback.message.answer("Please register first with /start")
    else:
        hist = await backend.get_intake_history(user["id"], limit=20)
        if not hist: await callback.message.answer("No intake history yet.", reply_markup=_menu_buttons())
        else:
            txt = "Intake History (last 20)\n\n"
            for e in hist[:20]:
                emo = {"pending":"pending","taken":"taken","missed":"missed"}.get(e["status"],"?")
                dt = e["scheduled_time"][:16].replace("T"," ")
                txt += f"{emo} {dt} - {e['medicine_name']}\n"
            await callback.message.answer(txt, reply_markup=_menu_buttons())
    await callback.answer()

@router.callback_query(F.data == "menu:today")
async def cb_today(callback: CallbackQuery):
    await _navigate(callback)
    user = await _user(callback)
    if not user: await callback.message.answer("Please register first with /start")
    else:
        from datetime import datetime, timezone, timedelta
        meds = await backend.list_medicines(user["id"])
        if not meds: await callback.message.answer("No medicines scheduled for today.", reply_markup=_menu_buttons())
        else:
            now = datetime.now(timezone(timedelta(hours=3))); cur = now.hour*60 + now.minute; items = []
            for med in meds:
                for s in await backend.list_schedules(med["id"]):
                    t = s["reminder_time"][:5]; p = t.split(":"); sm = int(p[0])*60 + int(p[1])
                    if sm >= cur: items.append((sm, t, med["name"], med["dosage"]))
            if not items: await callback.message.answer("No more medicines scheduled for today.", reply_markup=_menu_buttons())
            else:
                items.sort(); txt = "Today's Schedule\n\n"
                for _, t, n, d in items: txt += f"- {t}  {n} ({d})\n"
                await callback.message.answer(txt, reply_markup=_menu_buttons())
    await callback.answer()

@router.callback_query(F.data == "menu:edit")
async def cb_edit(callback: CallbackQuery, state: FSMContext):
    await _navigate(callback); await state.clear()
    user = await _user(callback)
    if not user: await callback.message.answer("Please register first with /start"); await callback.answer(); return
    meds = await backend.list_medicines(user["id"])
    if not meds: await callback.message.answer("No medicines to edit. Use /add first."); await callback.answer(); return
    builder = InlineKeyboardBuilder()
    for m in meds: builder.button(text=m["name"], callback_data=f"med:select:{m['id']}")
    builder.button(text="Back", callback_data="menu:main"); builder.adjust(1)
    await state.set_state(EditMedicineState.selecting_medicine)
    await callback.message.answer("Select medicine:", reply_markup=builder.as_markup())
    await callback.answer()

# === SPECIFIC CALLBACKS ===
@router.callback_query(F.data == "action:cancel")
async def cb_cancel(callback: CallbackQuery, state: FSMContext):
    await state.clear()
    await callback.message.edit_text("Cancelled.", reply_markup=_menu_buttons())
    await callback.answer()

@router.callback_query(F.data.startswith("sched:delete:"))
async def cb_sched_delete(callback: CallbackQuery, state: FSMContext): await handle_delete_schedule(callback, backend, state)

@router.callback_query(F.data.startswith("sched:pick:"))
async def cb_sched_pick(callback: CallbackQuery, state: FSMContext): await cb_schedule_action(callback, state, backend)

@router.callback_query(F.data.startswith("med:"))
async def cb_med(callback: CallbackQuery, state: FSMContext): await cb_medicine_action(callback, state, backend)

@router.callback_query(F.data.startswith("intake:taken:"))
async def cb_taken(callback: CallbackQuery): await cb_intake_taken(callback, backend)

@router.callback_query(F.data.startswith("intake:reschedule:"))
async def cb_reschedule(callback: CallbackQuery): await cb_intake_reschedule(callback, backend)
ROUTER_EOF

# 6. intake.py — московское время
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
    history = await backend.get_intake_history(user["id"], limit=20)
    if not history: await message.answer("No intake history yet."); return
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

# 7. Copy & Restart
echo "=== Copying into container ==="
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py
docker cp bot/app/handlers/schedule.py medreminder-bot:/app/app/handlers/schedule.py
docker cp bot/app/handlers/medicine.py medreminder-bot:/app/app/handlers/medicine.py
docker cp bot/app/handlers/intake.py medreminder-bot:/app/app/handlers/intake.py
docker cp bot/app/handlers/start.py medreminder-bot:/app/app/handlers/start.py
docker cp bot/app/services/scheduler.py medreminder-bot:/app/app/services/scheduler.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 8

echo ""
echo "=== Bot Logs ==="
docker compose logs --tail 8 bot

echo ""
echo "============================================"
echo "  FIX v8 APPLIED!"
echo "============================================"
echo ""
echo "  1. Timezone: Moscow (UTC+3) — reminders on time"
echo "  2. Cancel button: appears during Add medicine"
echo "  3. Edit/Delete: new 'Delete Medicine' button"
echo ""
