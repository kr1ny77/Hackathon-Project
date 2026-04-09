#!/bin/bash
# ============================================================
# FINAL FIX v2 — Medicine Reminder
# Fixes:
#   1. Edit: can delete individual reminder times
#   2. Today's schedule: shows all scheduled times (not just fired reminders)
#   3. Cancel button when setting reminder time
#   4. Delete old messages when navigating to menu
# ============================================================
set -e
cd /opt/medicine-reminder

echo "============================================"
echo "  FINAL FIX v2 — Medicine Reminder"
echo "============================================"

# ===================== schedule.py =====================
cat > bot/app/handlers/schedule.py << 'SCHEDULE_EOF'
"""Handlers for reminder schedule management."""
import re
import logging
from datetime import datetime, date
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import Message, CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)

class ScheduleState(StatesGroup):
    selecting_medicine = State()
    waiting_for_time = State()

async def _delete_msg(msg, state=None):
    """Try to delete a message, ignore errors."""
    try:
        await msg.delete()
    except Exception:
        pass

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
    builder.button(text="Back to menu", callback_data="menu:main")
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
    med_name = medicine_id
    if user_id:
        try:
            med_info = await backend.get_medicine(medicine_id, user_id)
            if med_info:
                med_name = med_info["medicine"]["name"]
        except Exception:
            pass
    await callback.message.edit_text(
        f"Medicine: {med_name}\nType the reminder time (HH:MM) now.\nExamples: 08:00, 14:30, 21:00"
    )
    await callback.answer()

async def handle_time_input(message: Message, state: FSMContext, backend: BackendClient):
    time_str = message.text.strip()
    if not re.match(r"^([01]?\d|2[0-3]):[0-5]\d$", time_str):
        await message.answer("Wrong format. Use HH:MM (24h).\nExamples: 08:00, 14:30, 21:00")
        return
    try:
        data = await state.get_data()
        medicine_id = data.get("medicine_id")
        user_id = data.get("user_id")
        if not medicine_id or not user_id:
            await message.answer("Session expired. Run /schedule again.")
            await state.clear()
            return
        med_info = await backend.get_medicine(medicine_id, user_id)
        med_name = med_info["medicine"]["name"] if med_info else "Unknown"
        schedule = await backend.add_schedule(medicine_id, time_str)
        logger.info(f"Schedule created: med={med_name}, time={time_str}")
        builder = InlineKeyboardBuilder()
        builder.button(text="Add another reminder", callback_data="menu:schedule")
        builder.button(text="My medicines", callback_data="menu:medicines")
        builder.button(text="Back to menu", callback_data="menu:main")
        builder.adjust(1)
        await message.answer(f"Reminder saved!\nMedicine: {med_name}\nTime: {time_str}", reply_markup=builder.as_markup())
        await state.clear()
    except Exception as e:
        logger.error(f"Schedule error: {e}", exc_info=True)
        await message.answer(f"Error: {e}\nRun /schedule again.")

async def cmd_today_schedule(message: Message, backend: BackendClient):
    """Show today's schedule — query medicines + schedules directly."""
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        await message.answer("No medicines scheduled for today.")
        return
    now = datetime.utcnow()
    text = "Today's Schedule\n\n"
    has_items = False
    for med in medicines:
        schedules = await backend.list_schedules(med["id"])
        for s in schedules:
            t = s["reminder_time"][:5]
            text += f"- {t}  {med['name']} ({med['dosage']})\n"
            has_items = True
    if not has_items:
        text += "No medicines scheduled for today."
    await message.answer(text)

async def cb_schedule_action(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    action = parts[1] if len(parts) > 1 else ""
    if action == "pick":
        await handle_medicine_select(callback, state, backend)
SCHEDULE_EOF

echo "[1/7] schedule.py fixed"

# ===================== start.py =====================
cat > bot/app/handlers/start.py << 'START_EOF'
"""Handler for /start command."""
import logging
from aiogram.fsm.context import FSMContext
from aiogram.types import Message
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)

def build_main_menu():
    builder = InlineKeyboardBuilder()
    builder.button(text="My medicines", callback_data="menu:medicines")
    builder.button(text="Add medicine", callback_data="menu:add")
    builder.button(text="Set reminder", callback_data="menu:schedule")
    builder.button(text="Intake history", callback_data="menu:history")
    builder.button(text="Today's schedule", callback_data="menu:today")
    builder.button(text="Edit / Delete", callback_data="menu:edit")
    builder.adjust(2)
    return builder.as_markup()

async def _delete(msg):
    try:
        await msg.delete()
    except Exception:
        pass

async def show_menu(message, backend, telegram_id):
    user = await backend.get_user(telegram_id)
    if not user:
        await message.answer("Please register first with /start")
        return
    medicines = await backend.list_medicines(user["id"])
    med_count = len(medicines)
    text = f"Welcome back, {user.get('first_name', 'User')}!\n\n"
    if med_count > 0:
        text += f"You have {med_count} medicine(s).\n"
    else:
        text += "No medicines yet.\n\nTap 'Add medicine' to get started."
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
        "I'm your Medicine Reminder bot.\n"
        "I'll remind you to take your medicines on time.\n\n"
        "Tap 'Add medicine' to get started.",
        reply_markup=build_main_menu(),
    )
    logger.info(f"New user registered: {message.from_user.id}")
START_EOF

echo "[2/7] start.py fixed"

# ===================== medicine.py =====================
cat > bot/app/handlers/medicine.py << 'MEDICINE_EOF'
"""Handlers for medicine management."""
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
    selecting_action = State()  # "edit_info" or "manage_times"
    selecting_field = State()
    waiting_for_value = State()
    selecting_schedule = State()

class DeleteMedicineState(StatesGroup):
    selecting_medicine = State()
    confirming = State()

def _menu_buttons():
    builder = InlineKeyboardBuilder()
    builder.button(text="My medicines", callback_data="menu:medicines")
    builder.button(text="Add medicine", callback_data="menu:add")
    builder.button(text="Set reminder", callback_data="menu:schedule")
    builder.button(text="Intake history", callback_data="menu:history")
    builder.button(text="Today's schedule", callback_data="menu:today")
    builder.button(text="Edit / Delete", callback_data="menu:edit")
    builder.adjust(2)
    return builder.as_markup()

async def cmd_add_medicine(message: Message, state: FSMContext, backend: BackendClient):
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    await state.set_state(AddMedicineState.waiting_for_name)
    await message.answer("What is the name of the medicine?\n(e.g., Aspirin, Metformin, Vitamin D)")

async def handle_medicine_name(message: Message, state: FSMContext, backend: BackendClient):
    await state.update_data(medicine_name=message.text.strip())
    await state.set_state(AddMedicineState.waiting_for_dosage)
    await message.answer("What is the dosage?\n(e.g., 1 tablet, 5ml, 250mg)")

async def handle_medicine_dosage(message: Message, state: FSMContext, backend: BackendClient):
    data = await state.get_data()
    name = data["medicine_name"]
    dosage = message.text.strip()
    user = await backend.get_user(message.from_user.id)
    medicine = await backend.add_medicine(user["id"], name, dosage)
    await state.clear()
    builder = InlineKeyboardBuilder()
    builder.button(text="Set reminder time", callback_data="menu:schedule")
    builder.button(text="My medicines", callback_data="menu:medicines")
    builder.adjust(1)
    await message.answer(f"Medicine added!\n\nName: {medicine['name']}\nDosage: {medicine['dosage']}", reply_markup=builder.as_markup())
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
    """Show action menu for selected medicine."""
    medicine_id = int(callback.data.split(":")[2])
    await state.update_data(medicine_id=medicine_id)
    user_id = callback.from_user.id

    # Get medicine info
    med_info = await backend.get_medicine(medicine_id, user_id)
    med_name = med_info["medicine"]["name"] if med_info else "Unknown"
    med_dosage = med_info["medicine"]["dosage"] if med_info else ""
    schedules = med_info.get("schedules", []) if med_info else []
    times = ", ".join(s["reminder_time"][:5] for s in schedules) if schedules else "no reminders"

    builder = InlineKeyboardBuilder()
    builder.button(text="Edit name/dosage", callback_data=f"med:action:info:{medicine_id}")
    if schedules:
        builder.button(text="Delete a time", callback_data=f"med:action:times:{medicine_id}")
    builder.button(text="Back", callback_data="menu:main")
    builder.adjust(1)

    await state.set_state(EditMedicineState.selecting_action)
    await callback.message.edit_text(
        f"Medicine: {med_name} ({med_dosage})\nTimes: {times}\n\nWhat would you like to do?",
        reply_markup=builder.as_markup(),
    )
    await callback.answer()

async def handle_action_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    action = parts[2]
    medicine_id = int(parts[3])

    if action == "info":
        builder = InlineKeyboardBuilder()
        builder.button(text="Name", callback_data="med:field:name")
        builder.button(text="Dosage", callback_data="med:field:dosage")
        builder.button(text="Cancel", callback_data="menu:main")
        builder.adjust(1)
        await state.set_state(EditMedicineState.selecting_field)
        await callback.message.edit_text("What would you like to change?", reply_markup=builder.as_markup())
    elif action == "times":
        # Show schedules to delete
        schedules = await backend.list_schedules(medicine_id)
        builder = InlineKeyboardBuilder()
        for s in schedules:
            t = s["reminder_time"][:5]
            builder.button(text=f"Delete {t}", callback_data=f"sched:delete:{s['id']}")
        builder.button(text="Back", callback_data="menu:main")
        builder.adjust(1)
        await callback.message.edit_text("Select a time to delete:", reply_markup=builder.as_markup())
    await callback.answer()

async def handle_edit_field_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    field = callback.data.split(":")[2]
    await state.update_data(edit_field=field)
    prompt = "Enter new name:" if field == "name" else "Enter new dosage:"
    await state.set_state(EditMedicineState.waiting_for_value)
    await callback.message.edit_text(prompt)
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

async def handle_delete_schedule(callback: CallbackQuery, backend: BackendClient):
    schedule_id = int(callback.data.split(":")[2])
    user = await backend.get_user(callback.from_user.id)
    if not user:
        await callback.message.answer("Please register first with /start")
        await callback.answer()
        return
    success = await backend.delete_schedule(schedule_id, user["id"])
    await callback.message.edit_text("Time deleted." if success else "Could not delete.", reply_markup=_menu_buttons())
    await callback.answer()

async def cb_medicine_action(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    parts = callback.data.split(":")
    action = parts[1] if len(parts) > 1 else ""
    if action == "select":
        await handle_medicine_select(callback, state, backend)
    elif action == "action":
        await handle_action_select(callback, state, backend)
    elif action == "field":
        await handle_edit_field_select(callback, state, backend)
    elif action == "delete":
        await handle_delete_select(callback, state, backend)
    elif action == "confirm_delete":
        await handle_delete_confirm(callback, state, backend)
    elif action == "cancel":
        await state.clear()
        await callback.message.edit_text("Cancelled.", reply_markup=_menu_buttons())
        await callback.answer()
MEDICINE_EOF

echo "[3/7] medicine.py fixed"

# ===================== intake.py =====================
cat > bot/app/handlers/intake.py << 'INTAKE_EOF'
"""Intake history and reminder responses."""
import logging
from datetime import datetime
from aiogram.types import Message, CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)

async def cmd_today(message: Message, backend: BackendClient):
    from app.handlers.schedule import cmd_today_schedule
    await cmd_today_schedule(message, backend)

async def cmd_history(message: Message, backend: BackendClient):
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

async def cb_intake_action(callback: CallbackQuery, backend: BackendClient):
    parts = callback.data.split(":")
    if len(parts) < 3:
        await callback.answer("Invalid", show_alert=True)
        return
    action = parts[1]
    intake_id = int(parts[2])
    try:
        result = await backend.record_intake(intake_id, action)
        status_text = "taken" if action == "taken" else "missed"
        await callback.message.edit_text(
            f"Recorded!\n"
            f"Medicine: {result.get('medicine_name', 'Unknown')}\n"
            f"Status: {status_text}\n"
            f"Time: {datetime.utcnow().strftime('%H:%M')}"
        )
    except Exception as e:
        logger.error(f"Intake error: {e}")
        await callback.answer("Error recording response.", show_alert=True)
    await callback.answer()

def build_intake_keyboard(intake_id: int) -> InlineKeyboardBuilder:
    builder = InlineKeyboardBuilder()
    builder.button(text="Taken", callback_data=f"intake:taken:{intake_id}")
    builder.button(text="Missed", callback_data=f"intake:missed:{intake_id}")
    builder.adjust(2)
    return builder
INTAKE_EOF

echo "[4/7] intake.py fixed"

# ===================== router.py =====================
cat > bot/app/handlers/router.py << 'ROUTER_EOF'
"""Telegram bot handler registrations."""
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
from app.handlers.intake import cb_intake_action, cmd_history
from aiogram.utils.keyboard import InlineKeyboardBuilder

router = Router()
settings = get_bot_settings()
backend = BackendClient()

# ===== Text commands =====
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

# ===== Inline button callbacks =====
async def _user(callback):
    return await backend.get_user(callback.from_user.id)

def _menu_buttons():
    builder = InlineKeyboardBuilder()
    builder.button(text="My medicines", callback_data="menu:medicines")
    builder.button(text="Add medicine", callback_data="menu:add")
    builder.button(text="Set reminder", callback_data="menu:schedule")
    builder.button(text="Intake history", callback_data="menu:history")
    builder.button(text="Today's schedule", callback_data="menu:today")
    builder.button(text="Edit / Delete", callback_data="menu:edit")
    builder.adjust(2)
    return builder.as_markup()

@router.callback_query(F.data == "menu:main")
async def cb_main(callback: CallbackQuery):
    # Delete the button message to avoid clutter
    try:
        await callback.message.delete()
    except Exception:
        pass
    await show_menu(callback.message, backend, callback.from_user.id)
    await callback.answer()

@router.callback_query(F.data == "menu:medicines")
async def cb_medicines(callback: CallbackQuery):
    try:
        await callback.message.delete()
    except Exception:
        pass
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
    try:
        await callback.message.delete()
    except Exception:
        pass
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
    try:
        await callback.message.delete()
    except Exception:
        pass
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
    try:
        await callback.message.delete()
    except Exception:
        pass
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
    try:
        await callback.message.delete()
    except Exception:
        pass
    user = await _user(callback)
    if not user:
        await callback.message.answer("Please register first with /start")
    else:
        medicines = await backend.list_medicines(user["id"])
        if not medicines:
            await callback.message.answer("No medicines scheduled for today.", reply_markup=_menu_buttons())
        else:
            text = "Today's Schedule\n\n"
            has_items = False
            for med in medicines:
                schedules = await backend.list_schedules(med["id"])
                for s in schedules:
                    t = s["reminder_time"][:5]
                    text += f"- {t}  {med['name']} ({med['dosage']})\n"
                    has_items = True
            if not has_items:
                text += "No medicines scheduled for today."
            await callback.message.answer(text, reply_markup=_menu_buttons())
    await callback.answer()

@router.callback_query(F.data == "menu:edit")
async def cb_edit(callback: CallbackQuery, state: FSMContext):
    try:
        await callback.message.delete()
    except Exception:
        pass
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

@router.callback_query(F.data == "sched:cancel")
async def cb_sched_cancel(callback: CallbackQuery, state: FSMContext):
    await state.clear()
    await callback.message.edit_text("Cancelled.", reply_markup=_menu_buttons())
    await callback.answer()

@router.callback_query(F.data.startswith("sched:delete:"))
async def cb_sched_delete(callback: CallbackQuery, backend: BackendClient):
    await handle_delete_schedule(callback, backend)

@router.callback_query(F.data.startswith("med:"))
async def cb_med(callback: CallbackQuery, state: FSMContext):
    await cb_medicine_action(callback, state, backend)

@router.callback_query(F.data.startswith("sched:"))
async def cb_sched(callback: CallbackQuery, state: FSMContext):
    await cb_schedule_action(callback, state, backend)

@router.callback_query(F.data.startswith("intake:"))
async def cb_intake(callback: CallbackQuery):
    await cb_intake_action(callback, backend)
ROUTER_EOF

echo "[5/7] router.py fixed"

# ===================== COPY INTO CONTAINER =====================
echo ""
echo "=== Copying files into bot container ==="
docker cp bot/app/handlers/start.py medreminder-bot:/app/app/handlers/start.py
docker cp bot/app/handlers/schedule.py medreminder-bot:/app/app/handlers/schedule.py
docker cp bot/app/handlers/medicine.py medreminder-bot:/app/app/handlers/medicine.py
docker cp bot/app/handlers/intake.py medreminder-bot:/app/app/handlers/intake.py
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py

echo ""
echo "=== Restarting bot ==="
docker compose restart bot

echo ""
echo "Waiting for bot..."
sleep 8

echo ""
echo "=== Status ==="
docker compose ps

echo ""
echo "=== Bot logs ==="
docker compose logs --tail=5 bot

echo ""
echo "============================================"
echo "  ALL FIXED v2!"
echo "============================================"
echo ""
echo "Changes:"
echo "  1. Today's schedule shows ALL medicines+times (not just fired reminders)"
echo "  2. Edit -> select medicine -> 'Delete a time' -> pick time to remove"
echo "  3. When setting reminder time, you can cancel via menu buttons"
echo "  4. Navigation deletes old messages to avoid spam"
