#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v22 — Buttons work, Back deletes message ==="

cat > bot/app/handlers/router.py << 'ROUTER_EOF'
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
from app.handlers.ai import handle_smart_message
from aiogram.utils.keyboard import InlineKeyboardBuilder

router = Router()
settings = get_bot_settings()
backend = BackendClient()

# === TEXT COMMANDS ===
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
    await message.answer("Commands: /start /add /medicines /edit /delete /schedule /today /history /help")

# === HELPERS ===
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

async def _delete_msg(cb):
    """Delete message — used only for Back/Cancel buttons."""
    try:
        await cb.message.delete()
    except Exception:
        pass

# === MENU BUTTONS ===

@router.callback_query(F.data == "menu:main")
async def cb_main(cb: CallbackQuery):
    # Back to main menu — delete old message
    await _delete_msg(cb)
    await show_menu(cb.message, backend, cb.from_user.id)
    await cb.answer()

@router.callback_query(F.data == "menu:medicines")
async def cb_medicines(cb: CallbackQuery):
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
async def cb_add(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    u = await _user(cb)
    if not u:
        await cb.message.answer("Please register first with /start")
        await cb.answer()
        return
    await state.set_state(AddMedicineState.waiting_for_name)
    await cb.message.answer("What is the name of the medicine?\n(e.g., Aspirin, Metformin)", reply_markup=_cancel())
    await cb.answer()

@router.callback_query(F.data == "menu:schedule")
async def cb_sched(cb: CallbackQuery, state: FSMContext):
    await state.clear()
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
    await state.set_state(ScheduleState.selecting_medicine)
    await state.update_data(user_id=u["id"])
    await cb.message.answer("Choose a medicine, then type time (HH:MM).", reply_markup=builder.as_markup())
    await cb.answer()

@router.callback_query(F.data == "menu:history")
async def cb_history(cb: CallbackQuery):
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
                counts[(e["medicine_name"], dt)] = counts.get((e["medicine_name"], dt), 0) + 1
            txt = "Intake History (last 20)\n\n"; seen = set()
            for e in h[:20]:
                dt = e["scheduled_time"][:16].replace("T", " ")
                key = (e["medicine_name"], dt)
                if key in seen: continue
                seen.add(key)
                emo = {"pending":"pending","taken":"taken","missed":"missed"}.get(e["status"],"?")
                qty = " x{}".format(counts[key]) if counts[key] > 1 else ""
                txt += "{} {} - {}{}\n".format(emo, dt, e["medicine_name"], qty)
            await cb.message.answer(txt, reply_markup=_menu())
    await cb.answer()

@router.callback_query(F.data == "menu:today")
async def cb_today(cb: CallbackQuery):
    u = await _user(cb)
    if not u:
        await cb.message.answer("Please register first with /start")
    else:
        meds = await backend.list_medicines(u["id"])
        if not meds:
            await cb.message.answer("No medicines scheduled.", reply_markup=_menu())
        else:
            now = datetime.now(timezone(timedelta(hours=3)))
            cur = now.hour * 60 + now.minute; items = []
            for med in meds:
                for s in await backend.list_schedules(med["id"]):
                    t = s["reminder_time"][:5]; p = t.split(":"); sm = int(p[0])*60 + int(p[1])
                    if sm >= cur: items.append((sm, t, med["name"], med["dosage"]))
            if not items:
                await cb.message.answer("No more medicines scheduled.", reply_markup=_menu())
            else:
                counts = Counter((t,n,d) for _,t,n,d in items)
                seen = set(); items.sort()
                txt = "Today's Schedule\n\n"
                for _,t,n,d in items:
                    key = (t,n,d)
                    if key in seen: continue
                    seen.add(key); qty = " x{}".format(counts[key]) if counts[key] > 1 else ""
                    txt += "- {}  {}{} ({})\n".format(t, n, qty, d)
                await cb.message.answer(txt, reply_markup=_menu())
    await cb.answer()

@router.callback_query(F.data == "menu:edit")
async def cb_edit(cb: CallbackQuery, state: FSMContext):
    await state.clear()
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
    for m in meds: b.button(text=m["name"], callback_data="med:select:{}".format(m["id"]))
    b.button(text="Back", callback_data="menu:main"); b.adjust(1)
    await state.set_state(EditMedicineState.selecting_medicine)
    await cb.message.answer("Select medicine:", reply_markup=b.as_markup())
    await cb.answer()

# === BACK / CANCEL — delete old message ===

@router.callback_query(F.data == "action:cancel")
async def cb_cancel(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    await _delete_msg(cb)
    await cb.message.answer("Cancelled.", reply_markup=_menu())
    await cb.answer()

# === ACTION CALLBACKS — do NOT delete, just respond ===

@router.callback_query(F.data.startswith("sched:delete:"))
async def cb_sched_del(cb: CallbackQuery, state: FSMContext):
    await handle_delete_schedule(cb, backend, state)

@router.callback_query(F.data.startswith("sched:pick:"))
async def cb_sched_pick(cb: CallbackQuery, state: FSMContext):
    await cb_schedule_action(cb, state, backend)

@router.callback_query(F.data.startswith("med:"))
async def cb_med(cb: CallbackQuery, state: FSMContext):
    await cb_medicine_action(cb, state, backend)

@router.callback_query(F.data.startswith("intake:taken:"))
async def cb_taken(cb: CallbackQuery):
    await cb_intake_taken(cb, backend)

@router.callback_query(F.data.startswith("intake:reschedule:"))
async def cb_resched(cb: CallbackQuery):
    await cb_intake_reschedule(cb, backend)

# === SMART HANDLER — CATCHES ALL TEXT MESSAGES ===
@router.message(F.text)
async def handle_smart(message: Message, state: FSMContext):
    await handle_smart_message(message, state, backend)
ROUTER_EOF

echo "=== Copying to container ==="
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Bot Logs ==="
docker compose logs --tail 5 bot

echo ""
echo "============================================"
echo "  FIX v22 APPLIED"
echo "============================================"
echo ""
echo "  How buttons work now:"
echo "  - Regular buttons (My medicines, Add, etc.):"
echo "    Respond with new message below (no delete)"
echo "  - Back / Cancel buttons:"
echo "    Delete old message and show menu"
echo "  - Taken / Remind in 5 min:"
echo "    Edit the reminder message in place"
