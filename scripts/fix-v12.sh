#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v12 — Full rebuild ==="

# Write all files
cat > bot/app/handlers/router.py << 'EOF'
from aiogram import Router, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import Message, CallbackQuery
from datetime import datetime, timezone, timedelta
from collections import Counter
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
async def handle_start(m: Message, s: FSMContext):
    await cmd_start(m, s, backend)

@router.message(Command("add"))
async def handle_add(m: Message, s: FSMContext):
    await cmd_add_medicine(m, s, backend)

@router.message(AddMedicineState.waiting_for_name)
async def proc_name(m: Message, s: FSMContext):
    await handle_medicine_name(m, s, backend)

@router.message(AddMedicineState.waiting_for_dosage)
async def proc_dosage(m: Message, s: FSMContext):
    await handle_medicine_dosage(m, s, backend)

@router.message(Command("medicines"))
async def handle_list(m: Message):
    await cmd_list_medicines(m, backend)

@router.message(Command("edit"))
async def handle_edit_cmd(m: Message, s: FSMContext):
    await cmd_edit_medicine(m, s, backend)

@router.message(EditMedicineState.waiting_for_value)
async def proc_edit(m: Message, s: FSMContext):
    await handle_edit_value(m, s, backend)

@router.message(Command("delete"))
async def handle_del_cmd(m: Message, s: FSMContext):
    await cmd_delete_medicine(m, s, backend)

@router.message(Command("schedule"))
async def handle_sched_cmd(m: Message, s: FSMContext):
    await cmd_schedule(m, s, backend)

@router.message(ScheduleState.waiting_for_time)
async def proc_time(m: Message, s: FSMContext):
    await handle_time_input(m, s, backend)

@router.message(Command("today"))
async def handle_today_cmd(m: Message):
    await handle_today(m, backend)

@router.message(Command("history"))
async def handle_hist_cmd(m: Message):
    await cmd_history(m, backend)

@router.message(Command("help"))
async def handle_help(m: Message):
    await m.answer("Commands:\n/start\n/add\n/medicines\n/edit\n/delete\n/schedule\n/today\n/history\n/help")

async def _user(cb):
    return await backend.get_user(cb.from_user.id)

def _menu():
    b = InlineKeyboardBuilder()
    b.button(text="My medicines", callback_data="menu:medicines")
    b.button(text="Add medicine", callback_data="menu:add")
    b.button(text="Set reminder", callback_data="menu:schedule")
    b.button(text="Intake history", callback_data="menu:history")
    b.button(text="Today's schedule", callback_data="menu:today")
    b.button(text="Edit / Delete", callback_data="menu:edit")
    b.adjust(2)
    return b.as_markup()

def _cancel():
    b = InlineKeyboardBuilder()
    b.button(text="Cancel", callback_data="action:cancel")
    b.adjust(1)
    return b.as_markup()

async def _nav(cb):
    try:
        await cb.message.delete()
    except Exception:
        pass

@router.callback_query(F.data == "menu:main")
async def cb_main(cb: CallbackQuery):
    await _nav(cb)
    await show_menu(cb.message, backend, cb.from_user.id)
    await cb.answer()

@router.callback_query(F.data == "menu:medicines")
async def cb_medicines(cb: CallbackQuery):
    await _nav(cb)
    u = await _user(cb)
    if not u:
        await cb.message.answer("Please register first with /start")
    else:
        meds = await backend.list_medicines(u["id"])
        if not meds:
            await cb.message.answer("No medicines yet.", reply_markup=_menu())
        else:
            txt = "Your Medicines:\n\n"
            for m in meds:
                sc = await backend.list_schedules(m["id"])
                ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
                txt += "- {} ({}) - {}\n".format(m["name"], m["dosage"], ts)
            b = InlineKeyboardBuilder()
            b.button(text="Set reminder", callback_data="menu:schedule")
            b.button(text="Back", callback_data="menu:main")
            b.adjust(1)
            await cb.message.answer(txt, reply_markup=b.as_markup())
    await cb.answer()

@router.callback_query(F.data == "menu:add")
async def cb_add(cb: CallbackQuery, s: FSMContext):
    await _nav(cb)
    await s.clear()
    u = await _user(cb)
    if not u:
        await cb.message.answer("Please register first with /start")
        await cb.answer()
        return
    await s.set_state(AddMedicineState.waiting_for_name)
    await cb.message.answer("What is the name of the medicine?\n(e.g., Aspirin, Metformin)", reply_markup=_cancel())
    await cb.answer()

@router.callback_query(F.data == "menu:schedule")
async def cb_sched(cb: CallbackQuery, s: FSMContext):
    await _nav(cb)
    await s.clear()
    u = await _user(cb)
    if not u:
        await cb.message.answer("Please register first with /start")
        await cb.answer()
        return
    meds = await backend.list_medicines(u["id"])
    if not meds:
        await cb.message.answer("No medicines yet.")
        await cb.answer()
        return
    builder = InlineKeyboardBuilder()
    for m in meds:
        sc = await backend.list_schedules(m["id"])
        ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
        builder.button(text="{} ({})".format(m["name"], ts), callback_data="sched:pick:{}".format(m["id"]))
    builder.adjust(1)
    builder.button(text="Cancel", callback_data="action:cancel")
    builder.adjust(1)
    await s.set_state(ScheduleState.selecting_medicine)
    await s.update_data(user_id=u["id"])
    await cb.message.answer("Choose a medicine, then type time (HH:MM).", reply_markup=builder.as_markup())
    await cb.answer()

@router.callback_query(F.data == "menu:history")
async def cb_history(cb: CallbackQuery):
    await _nav(cb)
    u = await _user(cb)
    if not u:
        await cb.message.answer("Please register first with /start")
    else:
        h = await backend.get_intake_history(u["id"], limit=20)
        if not h:
            await cb.message.answer("No intake history yet.", reply_markup=_menu())
        else:
            counts = Counter()
            for e in h:
                dt = e["scheduled_time"][:16].replace("T", " ")
                key = (e["medicine_name"], dt)
                counts[key] = counts.get(key, 0) + 1
            txt = "Intake History (last 20)\n\n"
            seen = set()
            for e in h[:20]:
                dt = e["scheduled_time"][:16].replace("T", " ")
                key = (e["medicine_name"], dt)
                if key in seen:
                    continue
                seen.add(key)
                emo = {"pending": "pending", "taken": "taken", "missed": "missed"}.get(e["status"], "?")
                qty = " x{}".format(counts[key]) if counts[key] > 1 else ""
                txt += "{} {} - {}{}\n".format(emo, dt, e["medicine_name"], qty)
            await cb.message.answer(txt, reply_markup=_menu())
    await cb.answer()

@router.callback_query(F.data == "menu:today")
async def cb_today(cb: CallbackQuery):
    await _nav(cb)
    u = await _user(cb)
    if not u:
        await cb.message.answer("Please register first with /start")
    else:
        meds = await backend.list_medicines(u["id"])
        if not meds:
            await cb.message.answer("No medicines scheduled.", reply_markup=_menu())
        else:
            now = datetime.now(timezone(timedelta(hours=3)))
            cur = now.hour * 60 + now.minute
            items = []
            for med in meds:
                for s in await backend.list_schedules(med["id"]):
                    t = s["reminder_time"][:5]
                    p = t.split(":")
                    sm = int(p[0]) * 60 + int(p[1])
                    if sm >= cur:
                        items.append((sm, t, med["name"], med["dosage"]))
            if not items:
                await cb.message.answer("No more medicines scheduled.", reply_markup=_menu())
            else:
                counts = Counter((t, n, d) for _, t, n, d in items)
                seen = set()
                items.sort()
                txt = "Today's Schedule\n\n"
                for _, t, n, d in items:
                    key = (t, n, d)
                    if key in seen:
                        continue
                    seen.add(key)
                    qty = " x{}".format(counts[key]) if counts[key] > 1 else ""
                    txt += "- {}  {}{} ({})\n".format(t, n, qty, d)
                await cb.message.answer(txt, reply_markup=_menu())
    await cb.answer()

@router.callback_query(F.data == "menu:edit")
async def cb_edit(cb: CallbackQuery, s: FSMContext):
    await _nav(cb)
    await s.clear()
    u = await _user(cb)
    if not u:
        await cb.message.answer("Please register first with /start")
        await cb.answer()
        return
    meds = await backend.list_medicines(u["id"])
    if not meds:
        await cb.message.answer("No medicines to edit.")
        await cb.answer()
        return
    b = InlineKeyboardBuilder()
    for m in meds:
        b.button(text=m["name"], callback_data="med:select:{}".format(m["id"]))
    b.button(text="Back", callback_data="menu:main")
    b.adjust(1)
    await s.set_state(EditMedicineState.selecting_medicine)
    await cb.message.answer("Select medicine:", reply_markup=b.as_markup())
    await cb.answer()

@router.callback_query(F.data == "action:cancel")
async def cb_cancel(cb: CallbackQuery, s: FSMContext):
    await s.clear()
    await cb.message.edit_text("Cancelled.", reply_markup=_menu())
    await cb.answer()

@router.callback_query(F.data.startswith("sched:delete:"))
async def cb_sched_del(cb: CallbackQuery, s: FSMContext):
    await handle_delete_schedule(cb, backend, s)

@router.callback_query(F.data.startswith("sched:pick:"))
async def cb_sched_pick(cb: CallbackQuery, s: FSMContext):
    await cb_schedule_action(cb, s, backend)

@router.callback_query(F.data.startswith("med:"))
async def cb_med(cb: CallbackQuery, s: FSMContext):
    await cb_medicine_action(cb, s, backend)

@router.callback_query(F.data.startswith("intake:taken:"))
async def cb_taken(cb: CallbackQuery):
    await cb_intake_taken(cb, backend)

@router.callback_query(F.data.startswith("intake:reschedule:"))
async def cb_resched(cb: CallbackQuery):
    await cb_intake_reschedule(cb, backend)
EOF

echo "=== Copying files ==="
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py
docker cp bot/app/services/scheduler.py medreminder-bot:/app/app/services/scheduler.py
docker cp bot/app/handlers/intake.py medreminder-bot:/app/app/handlers/intake.py
docker cp bot/app/handlers/schedule.py medreminder-bot:/app/app/handlers/schedule.py
docker cp bot/app/handlers/medicine.py medreminder-bot:/app/app/handlers/medicine.py
docker cp bot/app/handlers/start.py medreminder-bot:/app/app/handlers/start.py

echo "=== Restarting ==="
docker compose restart bot
sleep 6
docker compose logs --tail 5 bot
echo "=== DONE v12 ==="
