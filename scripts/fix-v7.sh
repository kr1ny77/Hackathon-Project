Сохрани этот код в файл fix-v7.sh на Mac, затем загрузи и запусти на VM.

#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "============================================"
echo "  FIX v7 — Callback Routing & Scheduler"
echo "============================================"

# 1. router.py
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
    await callback.message.answer("What is the name of the medicine?\n(e.g., Aspirin, Metformin)")
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
        from datetime import datetime
        meds = await backend.list_medicines(user["id"])
        if not meds: await callback.message.answer("No medicines scheduled for today.", reply_markup=_menu_buttons())
        else:
            now = datetime.utcnow(); cur = now.hour*60 + now.minute; items = []
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

# === SPECIFIC CALLBACKS (ORDER MATTERS) ===
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

# 2. scheduler.py
cat > bot/app/services/scheduler.py << 'SCHEDULER_EOF'
import asyncio, logging
from datetime import datetime
from aiogram import Bot
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
        self._sent = set()

    async def start(self):
        logger.info("Reminder scheduler started")
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
        now = datetime.utcnow()
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
        msg = f"Medicine Reminder\n\nMedicine: {name}\nTime: {datetime.utcnow().strftime('%H:%M')}\n\nHave you taken your medicine?"
        kb = build_intake_keyboard(intake["id"])
        await self.bot.send_message(chat_id=tid, text=msg, reply_markup=kb.as_markup())
        logger.info(f"Sent to {tid}: {name} (#{intake['id']})")
SCHEDULER_EOF

# 3. Copy & Restart
echo "=== Copying to container ==="
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py
docker cp bot/app/services/scheduler.py medreminder-bot:/app/app/services/scheduler.py
docker cp bot/app/main.py medreminder-bot:/app/app/main.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Bot Logs ==="
docker compose logs --tail 8 bot
echo ""
echo "============================================"
echo "  FIX v7 APPLIED. TEST IN TELEGRAM."
echo "============================================"
