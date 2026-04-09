#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "============================================"
echo "  FIX v10 — Group reminders, Fix Edit, Fix History"
echo "============================================"

# 1. scheduler.py — полная перегруппировка
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
        logger.info("Reminder scheduler started (Moscow)")
        self._task = asyncio.create_task(self._run())

    async def stop(self):
        if self._task:
            self._task.cancel()
            try: await self._task
            except: pass
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

        try:
            schedules = await self.backend.get_active_schedules_with_details(hh, mm)
        except Exception as e:
            logger.error(f"Schedules: {e}"); schedules = []

        # Группируем по (telegram_id, medicine_name) — все schedules в одну группу
        groups = defaultdict(list)
        for info in schedules:
            key = (info["telegram_id"], info["medicine_name"])
            groups[key].append(info)

        for (tid, med_name), infos in groups.items():
            count = len(infos)
            primary = infos[0]
            st = now.strftime("%Y-%m-%dT%H:%M:%S")
            try:
                # Создаём ОДИН intake на всю группу
                intake = await self.backend.create_pending_intake(
                    user_id=primary["user_id"],
                    schedule_id=primary["schedule_id"],
                    medicine_name=med_name,
                    scheduled_time=st,
                )
                if intake:
                    self._sent.add(intake["id"])
                    await self._send(intake, tid, med_name, count)
            except Exception as e:
                logger.error(f"New: {e}")

        # Rescheduled intakes
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
        logger.info(f"Sent to {tid}: {name}{qty} (#{intake['id']})")
SCHEDULER_EOF

# 2. medicine.py — ИСПРАВЛЕННЫЙ Edit/Delete с надёжным парсингом
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
    if not user: await message.answer("Please register first with /start"); return
    await state.set_state(AddMedicineState.waiting_for_name)
    await message.answer("What is the name of the medicine?\n(e.g., Aspirin, Metformin)", reply_markup=_with_cancel())

async def handle_medicine_name(message: Message, state: FSMContext, backend: BackendClient):
    await state.update_data(medicine_name=message.text.strip())
    await state.set_state(AddMedicineState.waiting_for_dosage)
    await message.answer("What is the dosage?\n(e.g., 1 tablet, 5ml, 250mg)", reply_markup=_with_cancel())

async def handle_medicine_dosage(message: Message, state: FSMContext, backend: BackendClient):
    data = await state.get_data()
    name = data["medicine_name"]
    dosage = message.text.strip()
    user = await backend.get_user(message.from_user.id)
    medicine = await backend.add_medicine(user["id"], name, dosage)
    await state.clear()
    await message.answer(f"Medicine added!\n\nName: {medicine['name']}\nDosage: {medicine['dosage']}", reply_markup=_menu_buttons())

async def cmd_list_medicines(message: Message, backend: BackendClient):
    user = await backend.get_user(message.from_user.id)
    if not user: await message.answer("Please register first with /start"); return
    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        b = InlineKeyboardBuilder()
        b.button(text="Add medicine", callback_data="menu:add"); b.adjust(1)
        await message.answer("No medicines yet.", reply_markup=b.as_markup())
        return
    text = "Your Medicines:\n\n"
    for med in medicines:
        sc = await backend.list_schedules(med["id"])
        ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
        text += f"- {med['name']} ({med['dosage']}) - {ts}\n"
    text += "\nWhat would you like to do?"
    b = InlineKeyboardBuilder()
    b.button(text="Set reminder", callback_data="menu:schedule")
    b.button(text="Edit / Delete", callback_data="menu:edit")
    b.button(text="Back to menu", callback_data="menu:main")
    b.adjust(1)
    await message.answer(text, reply_markup=b.as_markup())

async def cmd_edit_medicine(message: Message, state: FSMContext, backend: BackendClient):
    user = await backend.get_user(message.from_user.id)
    if not user: await message.answer("Please register first with /start"); return
    medicines = await backend.list_medicines(user["id"])
    if not medicines: await message.answer("No medicines to edit. Use /add first."); return
    builder = InlineKeyboardBuilder()
    for med in medicines:
        builder.button(text=med["name"], callback_data=f"med:select:{med['id']}")
    builder.button(text="Back", callback_data="menu:main")
    builder.adjust(1)
    await state.set_state(EditMedicineState.selecting_medicine)
    await message.answer("Select medicine:", reply_markup=builder.as_markup())

async def handle_medicine_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    # Parse: med:select:123
    med_id_str = callback.data.split(":", 2)[2]
    medicine_id = int(med_id_str)
    await state.update_data(medicine_id=medicine_id)
    user_id = callback.from_user.id

    # Получаем список лекарств пользователя
    medicines = await backend.list_medicines(user_id)
    med_name = "Unknown"
    med_dosage = ""
    for m in medicines:
        if str(m["id"]) == str(medicine_id):
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
    action = callback.data.split(":")[2]
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
    med_id_str = callback.data.split(":", 2)[2]
    medicine_id = int(med_id_str)
    await state.update_data(medicine_id=medicine_id)
    user_id = callback.from_user.id
    medicines = await backend.list_medicines(user_id)
    med_name = "Unknown"
    for m in medicines:
        if str(m["id"]) == str(medicine_id):
            med_name = m["name"]
            break
    builder = InlineKeyboardBuilder()
    builder.button(text="Yes, Delete", callback_data=f"med:confirm_delete_full:{medicine_id}")
    builder.button(text="Cancel", callback_data="menu:main")
    builder.adjust(1)
    await state.set_state(EditMedicineState.confirming_delete)
    await callback.message.edit_text(
        f"Delete \"{med_name}\"?\nThis will remove all reminders and history.",
        reply_markup=builder.as_markup(),
    )
    await callback.answer()

async def handle_execute_delete_medicine(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    med_id_str = callback.data.split(":", 3)[3]
    medicine_id = int(med_id_str)
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
    if not user: await message.answer("Please register first with /start"); return
    medicines = await backend.list_medicines(user["id"])
    if not medicines: await message.answer("No medicines to delete."); return
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
    if not user: await callback.message.answer("Please register first with /start"); await callback.answer(); return
    success = await backend.delete_schedule(schedule_id, user["id"])
    medicines = await backend.list_medicines(user["id"])
    builder = InlineKeyboardBuilder()
    for m in medicines:
        sc = await backend.list_schedules(m["id"])
        times = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no times"
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
    parts = callback.data.split(":", 2)
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

# 3. intake.py — группировка истории
cat > bot/app/handlers/intake.py << 'INTAKE_EOF'
import logging
from datetime import datetime, timezone, timedelta
from collections import Counter
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

    # Группируем: ключ = (medicine_name, первые 16 символов времени)
    counts = Counter()
    for e in history:
        dt = e["scheduled_time"][:16].replace("T", " ")
        counts[(e["medicine_name"], dt)] += 1

    text = "Intake History (last 30)\n\n"
    seen = set()
    for e in history[:30]:
        dt = e["scheduled_time"][:16].replace("T", " ")
        key = (e["medicine_name"], dt)
        if key in seen: continue
        seen.add(key)
        emoji = {"pending":"pending","taken":"taken","missed":"missed"}.get(e["status"],"?")
        cnt = counts[key]
        qty = f" x{cnt}" if cnt > 1 else ""
        text += f"{emoji} {dt} - {e['medicine_name']}{qty}\n"
    await message.answer(text)

async def cb_intake_taken(callback: CallbackQuery, backend: BackendClient):
    intake_id = int(callback.data.split(":")[2])
    try:
        result = await backend.record_intake(intake_id, "taken")
        now = datetime.now(timezone(timedelta(hours=3)))
        await callback.message.edit_text(f"Great! Recorded as taken.\nMedicine: {result.get('medicine_name', 'Unknown')}\nTime: {now.strftime('%H:%M')}")
    except Exception as e:
        logger.error(f"Taken: {e}")
        await callback.answer("Error.", show_alert=True)
    await callback.answer()

async def cb_intake_reschedule(callback: CallbackQuery, backend: BackendClient):
    intake_id = int(callback.data.split(":")[2])
    try:
        result = await backend.reschedule_intake(intake_id)
        new_time = result["scheduled_time"][11:16]
        await callback.message.edit_text(f"Reminder set for {new_time}.\nMedicine: {result.get('medicine_name', 'Unknown')}")
    except Exception as e:
        logger.error(f"Resched: {e}")
        await callback.answer("Error.", show_alert=True)
    await callback.answer()

def build_intake_keyboard(intake_id: int) -> InlineKeyboardBuilder:
    b = InlineKeyboardBuilder()
    b.button(text="Taken", callback_data=f"intake:taken:{intake_id}")
    b.button(text="Remind in 5 min", callback_data=f"intake:reschedule:{intake_id}")
    b.adjust(2)
    return b
INTAKE_EOF

# 4. schedule.py — сегодня тоже с группировкой
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
        sc = await backend.list_schedules(med["id"])
        ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
        builder.button(text=f"{med['name']} ({ts})", callback_data=f"sched:pick:{med['id']}")
    builder.adjust(1)
    builder.button(text="Cancel", callback_data="action:cancel")
    builder.adjust(1)
    await state.set_state(ScheduleState.selecting_medicine)
    await state.update_data(user_id=user["id"])
    await message.answer("Choose a medicine, then type time (HH:MM).", reply_markup=builder.as_markup())

async def handle_medicine_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    medicine_id = int(callback.data.split(":", 2)[2])
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
        await message.answer("Wrong format. Use HH:MM (24h).", reply_markup=_with_cancel()); return
    try:
        data = await state.get_data()
        medicine_id, user_id = data.get("medicine_id"), data.get("user_id")
        if not medicine_id or not user_id: await message.answer("Session expired."); await state.clear(); return
        med_name = "Unknown"
        for m in await backend.list_medicines(user_id):
            if m["id"] == medicine_id: med_name = m["name"]; break
        await backend.add_schedule(medicine_id, time_str)
        await message.answer(f"Reminder saved!\nMedicine: {med_name}\nTime: {time_str}", reply_markup=_menu_buttons())
        await state.clear()
    except Exception as e:
        logger.error(f"Schedule: {e}", exc_info=True)
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
    cur = now.hour * 60 + now.minute
    items = []
    for med in medicines:
        for s in await backend.list_schedules(med["id"]):
            t = s["reminder_time"][:5]; p = t.split(":"); sm = int(p[0])*60 + int(p[1])
            if sm >= cur: items.append((sm, t, med["name"], med["dosage"]))
    if not items: await message.answer("No more medicines scheduled for today."); return
    counts = Counter((t, n, d) for _, t, n, d in items)
    seen, items = set(), sorted(items)
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
    if callback.data.split(":")[1] == "pick":
        await handle_medicine_select(callback, state, backend)
SCHEDULE_EOF

# 5. start.py — с Cancel при Add
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
    text += f"You have {len(meds)} medicine(s).\n" if meds else "No medicines yet.\nTap 'Add medicine'.\n"
    await message.answer(text, reply_markup=build_main_menu())

async def cmd_start(message: Message, state: FSMContext, backend: BackendClient):
    await state.clear()
    existing = await backend.get_user(message.from_user.id)
    if existing: await show_menu(message, backend, message.from_user.id); return
    await backend.register_user(telegram_id=message.from_user.id, username=message.from_user.username, first_name=message.from_user.first_name)
    await message.answer(f"Welcome, {message.from_user.first_name or 'User'}!\n\nI'm your Medicine Reminder bot.\nTap 'Add medicine' to get started.", reply_markup=build_main_menu())
START_EOF

# 6. router.py — правильный порядок
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

@router.message(Command("start"))
async def handle_start(m: Message, s: FSMContext): await cmd_start(m, s, backend)
@router.message(Command("add"))
async def handle_add(m: Message, s: FSMContext): await cmd_add_medicine(m, s, backend)
@router.message(AddMedicineState.waiting_for_name)
async def proc_name(m: Message, s: FSMContext): await handle_medicine_name(m, s, backend)
@router.message(AddMedicineState.waiting_for_dosage)
async def proc_dosage(m: Message, s: FSMContext): await handle_medicine_dosage(m, s, backend)
@router.message(Command("medicines"))
async def handle_list(m: Message): await cmd_list_medicines(m, backend)
@router.message(Command("edit"))
async def handle_edit_cmd(m: Message, s: FSMContext): await cmd_edit_medicine(m, s, backend)
@router.message(EditMedicineState.waiting_for_value)
async def proc_edit(m: Message, s: FSMContext): await handle_edit_value(m, s, backend)
@router.message(Command("delete"))
async def handle_del_cmd(m: Message, s: FSMContext): await cmd_delete_medicine(m, s, backend)
@router.message(Command("schedule"))
async def handle_sched_cmd(m: Message, s: FSMContext): await cmd_schedule(m, s, backend)
@router.message(ScheduleState.waiting_for_time)
async def proc_time(m: Message, s: FSMContext): await handle_time_input(m, s, backend)
@router.message(Command("today"))
async def handle_today_cmd(m: Message): await handle_today(m, backend)
@router.message(Command("history"))
async def handle_hist_cmd(m: Message): await cmd_history(m, backend)
@router.message(Command("help"))
async def handle_help(m: Message):
    await m.answer("Medicine Reminder Bot\n\n/start - Register\n/add - Add\n/medicines - List\n/edit - Edit\n/delete - Delete\n/schedule - Set\n/today - Schedule\n/history - Intake\n/help - Help")

async def _user(cb): return await backend.get_user(cb.from_user.id)
def _menu():
    b = InlineKeyboardBuilder()
    for t,c in [("My medicines","menu:medicines"),("Add medicine","menu:add"),("Set reminder","menu:schedule"),("Intake history","menu:history"),("Today's schedule","menu:today"),("Edit / Delete","menu:edit")]:
        b.button(text=t, callback_data=c)
    b.adjust(2); return b.as_markup()
def _cancel():
    b = InlineKeyboardBuilder(); b.button(text="Cancel", callback_data="action:cancel"); b.adjust(1); return b.as_markup()
async def _nav(cb):
    try: await cb.message.delete()
    except: pass

@router.callback_query(F.data == "menu:main")
async def cb_main(cb: CallbackQuery): await _nav(cb); await show_menu(cb.message, backend, cb.from_user.id); await cb.answer()

@router.callback_query(F.data == "menu:medicines")
async def cb_medicines(cb: CallbackQuery):
    await _nav(cb); u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start")
    else:
        meds = await backend.list_medicines(u["id"])
        if not meds: await cb.message.answer("No medicines yet.", reply_markup=_menu())
        else:
            txt = "Your Medicines:\n\n"
            for m in meds:
                sc = await backend.list_schedules(m["id"]); ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
                txt += f"- {m['name']} ({m['dosage']}) - {ts}\n"
            b = InlineKeyboardBuilder(); b.button(text="Set reminder", callback_data="menu:schedule"); b.button(text="Back", callback_data="menu:main"); b.adjust(1)
            await cb.message.answer(txt, reply_markup=b.as_markup())
    await cb.answer()

@router.callback_query(F.data == "menu:add")
async def cb_add(cb: CallbackQuery, s: FSMContext):
    await _nav(cb); await s.clear(); u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start"); await cb.answer(); return
    await s.set_state(AddMedicineState.waiting_for_name)
    await cb.message.answer("What is the name of the medicine?\n(e.g., Aspirin, Metformin)", reply_markup=_cancel())
    await cb.answer()

@router.callback_query(F.data == "menu:schedule")
async def cb_sched(cb: CallbackQuery, s: FSMContext):
    await _nav(cb); await s.clear(); u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start"); await cb.answer(); return
    meds = await backend.list_medicines(u["id"])
    if not meds: await cb.message.answer("No medicines yet."); await cb.answer(); return
    builder = InlineKeyboardBuilder()
    for m in meds:
        sc = await backend.list_schedules(m["id"]); ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
        builder.button(text=f"{m['name']} ({ts})", callback_data=f"sched:pick:{m['id']}")
    builder.adjust(1); builder.button(text="Cancel", callback_data="action:cancel"); builder.adjust(1)
    await s.set_state(ScheduleState.selecting_medicine); await s.update_data(user_id=u["id"])
    await cb.message.answer("Choose a medicine, then type time (HH:MM).", reply_markup=builder.as_markup())
    await cb.answer()

@router.callback_query(F.data == "menu:history")
async def cb_history(cb: CallbackQuery):
    await _nav(cb); u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start")
    else:
        h = await backend.get_intake_history(u["id"], limit=20)
        if not h: await cb.message.answer("No intake history yet.", reply_markup=_menu())
        else:
            from collections import Counter
            counts = Counter(); [counts.__setitem__((e["medicine_name"], e["scheduled_time"][:16].replace("T"," ")), counts.get((e["medicine_name"], e["scheduled_time"][:16].replace("T"," ")), 0)+1) for e in h]
            txt = "Intake History (last 20)\n\n"; seen = set()
            for e in h[:20]:
                dt = e["scheduled_time"][:16].replace("T"," "); key = (e["medicine_name"], dt)
                if key in seen: continue
                seen.add(key); emo = {"pending":"pending","taken":"taken","missed":"missed"}.get(e["status"],"?")
                qty = f" x{counts[key]}" if counts[key] > 1 else ""
                txt += f"{emo} {dt} - {e['medicine_name']}{qty}\n"
            await cb.message.answer(txt, reply_markup=_menu())
    await cb.answer()

@router.callback_query(F.data == "menu:today")
async def cb_today(cb: CallbackQuery):
    await _nav(cb); u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start")
    else:
        meds = await backend.list_medicines(u["id"])
        if not meds: await cb.message.answer("No medicines scheduled.", reply_markup=_menu())
        else:
            from datetime import datetime
            now = datetime.now(timezone(timedelta(hours=3))); cur = now.hour*60 + now.minute; items = []
            for med in meds:
                for s in await backend.list_schedules(med["id"]):
                    t = s["reminder_time"][:5]; p = t.split(":"); sm = int(p[0])*60 + int(p[1])
                    if sm >= cur: items.append((sm, t, med["name"], med["dosage"]))
            if not items: await cb.message.answer("No more medicines scheduled.", reply_markup=_menu())
            else:
                from collections import Counter
                counts = Counter((t,n,d) for _,t,n,d in items); seen = set(); items.sort()
                txt = "Today's Schedule\n\n"
                for _,t,n,d in items:
                    key = (t,n,d)
                    if key in seen: continue
                    seen.add(key); qty = f" x{counts[key]}" if counts[key] > 1 else ""
                    txt += f"- {t}  {n}{qty} ({d})\n"
                await cb.message.answer(txt, reply_markup=_menu())
    await cb.answer()

@router.callback_query(F.data == "menu:edit")
async def cb_edit(cb: CallbackQuery, s: FSMContext):
    await _nav(cb); await s.clear(); u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start"); await cb.answer(); return
    meds = await backend.list_medicines(u["id"])
    if not meds: await cb.message.answer("No medicines to edit."); await cb.answer(); return
    b = InlineKeyboardBuilder()
    for m in meds: b.button(text=m["name"], callback_data=f"med:select:{m['id']}")
    b.button(text="Back", callback_data="menu:main"); b.adjust(1)
    await s.set_state(EditMedicineState.selecting_medicine)
    await cb.message.answer("Select medicine:", reply_markup=b.as_markup())
    await cb.answer()

@router.callback_query(F.data == "action:cancel")
async def cb_cancel(cb: CallbackQuery, s: FSMContext):
    await s.clear()
    await cb.message.edit_text("Cancelled.", reply_markup=_menu())
    await cb.answer()

@router.callback_query(F.data.startswith("sched:delete:"))
async def cb_sched_del(cb: CallbackQuery, s: FSMContext): await handle_delete_schedule(cb, backend, s)

@router.callback_query(F.data.startswith("sched:pick:"))
async def cb_sched_pick(cb: CallbackQuery, s: FSMContext): await cb_schedule_action(cb, s, backend)

@router.callback_query(F.data.startswith("med:"))
async def cb_med(cb: CallbackQuery, s: FSMContext): await cb_medicine_action(cb, s, backend)

@router.callback_query(F.data.startswith("intake:taken:"))
async def cb_taken(cb: CallbackQuery): await cb_intake_taken(cb, backend)

@router.callback_query(F.data.startswith("intake:reschedule:"))
async def cb_resched(cb: CallbackQuery): await cb_intake_reschedule(cb, backend)
ROUTER_EOF

# COPY & RESTART
echo "=== Copying into container ==="
docker cp bot/app/services/scheduler.py medreminder-bot:/app/app/services/scheduler.py
docker cp bot/app/handlers/intake.py medreminder-bot:/app/app/handlers/intake.py
docker cp bot/app/handlers/schedule.py medreminder-bot:/app/app/handlers/schedule.py
docker cp bot/app/handlers/medicine.py medreminder-bot:/app/app/handlers/medicine.py
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py
docker cp bot/app/handlers/start.py medreminder-bot:/app/app/handlers/start.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 8

echo ""
echo "=== Bot Logs ==="
docker compose logs --tail 8 bot
echo ""
echo "============================================"
echo "  FIX v10 APPLIED!"
echo "============================================"
echo "  1. Grouped reminders: one message per medicine"
echo "  2. Edit shows correct medicine name"
echo "  3. Intake history grouped with count"
echo "  4. Today's schedule grouped with count"
