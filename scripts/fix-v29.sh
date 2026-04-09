#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v29 — Debug AI handler ==="

# 1. Add debug logging to ai.py
cat > bot/app/handlers/ai.py << 'AI_EOF'
"""Full AI Agent with debug logging."""
import logging
from aiogram.types import Message
from aiogram.fsm.context import FSMContext
from app.services.gigachat import GigaChatClient
from app.services.backend_client import BackendClient
from app.handlers.start import build_main_menu
from app.handlers.intake import cmd_history
from app.handlers.schedule import cmd_today_schedule

logger = logging.getLogger(__name__)
giga = GigaChatClient()

HEALTH_KEYWORDS = ["medicine","medication","drug","pill","tablet","aspirin","ibuprofen","paracetamol",
    "vitamin","dose","dosage","side effect","symptom","treatment","pain","headache","fever","cold",
    "flu","antibiotic","prescription","disease","health","sick","ill","infection","diabetes",
    "blood pressure","heart","liver","kidney","stomach","cough","sneeze","runny nose",
    "allergy","rash","swelling","nausea","dizzy","fatigue","insomnia","depression","anxiety",
    "supplement","herbal","remedy","therapy","surgery","doctor","hospital","diagnosis",
    "blood test","x-ray","vaccine","injection","ointment","cream","drops","syrup",
    "change","reminder","remind","add","delete","edit","list","schedule","history"]

async def handle_smart_message(message: Message, state: FSMContext, backend: BackendClient):
    text = message.text.strip()
    logger.info("=== AI HANDLER CALLED: %s ===", text)
    
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start"); return
    logger.info("User: %s (id=%s)", user.get("first_name",""), user["id"])

    medicines = await backend.list_medicines_with_schedules(user["id"])
    logger.info("Medicines: %d", len(medicines))
    
    intent = await giga.parse_intent(text, medicines)
    action = intent.get("action", "question")
    logger.info("Intent: %s", action)
    await state.clear()

    if action == "add": await _do_add(message, intent, backend, user)
    elif action == "change_time": await _do_change_time(message, intent, backend, user, medicines)
    elif action == "delete_reminder": await _do_delete_reminder(message, intent, backend, user, medicines)
    elif action == "edit_name": await _do_edit_name(message, intent, backend, user, medicines)
    elif action == "edit_dosage": await _do_edit_dosage(message, intent, backend, user, medicines)
    elif action == "delete_medicine": await _do_delete_medicine(message, intent, backend, user, medicines)
    elif action == "list_medicines": await _do_list(message, medicines)
    elif action == "today_schedule": await cmd_today_schedule(message, backend)
    elif action == "intake_history": await cmd_history(message, backend)
    elif action == "question": await _do_question(message, text)
    else: await _do_question(message, text)

async def _do_add(message, intent, backend, user):
    thinking = await message.answer("Adding...")
    added = []; errors = []
    for med in intent.get("medicines", []):
        try:
            name = med.get("name",""); dosage = med.get("dosage","as prescribed"); times = med.get("times",[])
            if not name: errors.append("No name"); continue
            m = await backend.add_medicine(user["id"], name, dosage)
            for t in times:
                try: await backend.add_schedule(m["id"], t)
                except: errors.append("Could not set {} for {}".format(t, name))
            item = "{} {}".format(name, dosage)
            if times: item += " at " + ", ".join(times)
            added.append(item)
        except Exception as e: errors.append("Error adding {}: {}".format(med.get("name",""), str(e)))
    try: await thinking.delete()
    except: pass
    response = ""
    if added: response += "Added:\n" + "\n".join("- " + a for a in added)
    if errors:
        if response: response += "\n\n"
        response += "Issues:\n" + "\n".join("- " + e for e in errors)
    if not response: response = "Nothing was added."
    await message.answer(response, reply_markup=build_main_menu())

async def _do_change_time(message, intent, backend, user, medicines):
    med_name = intent.get("medicine","").lower(); old_t = intent.get("old_time","").strip(); new_t = intent.get("new_time","").strip()
    found = None
    for m in medicines:
        if m["name"].lower() == med_name: found = m; break
    if not found: await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    sc = await backend.list_schedules(found["id"]); sched = None
    for s in sc:
        if s["reminder_time"].startswith(old_t): sched = s; break
    if not sched: await message.answer("No reminder at {} for {}.".format(old_t, found["name"]), reply_markup=build_main_menu()); return
    try:
        await backend.update_schedule(sched["id"], new_t)
        await message.answer("Changed {} from {} to {}.".format(found["name"], old_t, new_t), reply_markup=build_main_menu())
    except Exception as e: await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_delete_reminder(message, intent, backend, user, medicines):
    med_name = intent.get("medicine","").lower(); t = intent.get("time","").strip()
    found = None
    for m in medicines:
        if m["name"].lower() == med_name: found = m; break
    if not found: await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    sc = await backend.list_schedules(found["id"]); sched = None
    for s in sc:
        if s["reminder_time"].startswith(t): sched = s; break
    if not sched: await message.answer("No reminder at {} for {}.".format(t, found["name"]), reply_markup=build_main_menu()); return
    try:
        await backend.delete_reminder_time(sched["id"], user["id"])
        await message.answer("Deleted {} reminder at {}.".format(found["name"], t), reply_markup=build_main_menu())
    except Exception as e: await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_edit_name(message, intent, backend, user, medicines):
    med_name = intent.get("medicine","").lower(); new_name = intent.get("new_name","")
    found = None
    for m in medicines:
        if m["name"].lower() == med_name: found = m; break
    if not found: await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    try:
        await backend.update_medicine(found["id"], user["id"], name=new_name)
        await message.answer("Renamed to '{}'.".format(new_name), reply_markup=build_main_menu())
    except Exception as e: await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_edit_dosage(message, intent, backend, user, medicines):
    med_name = intent.get("medicine","").lower(); new_dosage = intent.get("new_dosage","")
    found = None
    for m in medicines:
        if m["name"].lower() == med_name: found = m; break
    if not found: await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    try:
        await backend.update_medicine(found["id"], user["id"], dosage=new_dosage)
        await message.answer("Dosage for {} changed to '{}'.".format(found["name"], new_dosage), reply_markup=build_main_menu())
    except Exception as e: await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_delete_medicine(message, intent, backend, user, medicines):
    med_name = intent.get("medicine","").lower()
    found = None
    for m in medicines:
        if m["name"].lower() == med_name: found = m; break
    if not found: await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    try:
        await backend.delete_medicine(found["id"], user["id"])
        await message.answer("Deleted {}.".format(found["name"]), reply_markup=build_main_menu())
    except Exception as e: await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_list(message, medicines):
    if not medicines: await message.answer("No medicines yet.", reply_markup=build_main_menu()); return
    txt = "Your Medicines:\n\n"
    for m in medicines:
        sc = m.get("schedules","") or "no reminders"
        txt += "- {} ({}) - {}\n".format(m["name"], m["dosage"], sc)
    await message.answer(txt, reply_markup=build_main_menu())

async def _do_question(message, text):
    lower = text.lower()
    if not any(kw in lower for kw in HEALTH_KEYWORDS):
        await message.answer("I can only help with medicine and health-related questions.", reply_markup=build_main_menu())
        return
    thinking = await message.answer("Thinking...")
    sp = "You are a medical assistant. Answer briefly (2-3 sentences). Suggest consulting a doctor."
    reply = await giga.ask(text, sp)
    try: await thinking.delete()
    except: pass
    await message.answer(reply, reply_markup=build_main_menu())
AI_EOF

# 2. Router — use @router.message() without F.text, and add debug
cat > bot/app/handlers/router.py << 'ROUTER_EOF'
from aiogram import Router, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import Message, CallbackQuery
from datetime import datetime, timezone, timedelta
from collections import Counter
import logging
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

logger = logging.getLogger(__name__)

router = Router()
settings = get_bot_settings()
backend = BackendClient()

# === 1. TEXT COMMANDS ===
@router.message(Command("start"))
async def handle_start(message: Message, state: FSMContext):
    logger.info("Command: /start from %s", message.from_user.id)
    await cmd_start(message, state, backend)

@router.message(Command("add"))
async def handle_add(message: Message, state: FSMContext):
    await cmd_add_medicine(message, state, backend)

@router.message(Command("medicines"))
async def handle_list(message: Message):
    await cmd_list_medicines(message, backend)

@router.message(Command("edit"))
async def handle_edit_cmd(message: Message, state: FSMContext):
    await cmd_edit_medicine(message, state, backend)

@router.message(Command("delete"))
async def handle_del_cmd(message: Message, state: FSMContext):
    await cmd_delete_medicine(message, state, backend)

@router.message(Command("schedule"))
async def handle_sched_cmd(message: Message, state: FSMContext):
    await cmd_schedule(message, state, backend)

@router.message(Command("today"))
async def handle_today_cmd(message: Message):
    await handle_today(message, backend)

@router.message(Command("history"))
async def handle_hist_cmd(message: Message):
    await cmd_history(message, backend)

@router.message(Command("help"))
async def handle_help(message: Message):
    await message.answer("Commands: /start /add /medicines /edit /delete /schedule /today /history /help")

# === 2. FSM STATE HANDLERS ===
@router.message(AddMedicineState.waiting_for_name)
async def proc_name(message: Message, state: FSMContext):
    await handle_medicine_name(message, state, backend)

@router.message(AddMedicineState.waiting_for_dosage)
async def proc_dosage(message: Message, state: FSMContext):
    await handle_medicine_dosage(message, state, backend)

@router.message(EditMedicineState.waiting_for_value)
async def proc_edit(message: Message, state: FSMContext):
    await handle_edit_value(message, state, backend)

@router.message(ScheduleState.waiting_for_time)
async def proc_time(message: Message, state: FSMContext):
    await handle_time_input(message, state, backend)

# === 3. CALLBACK QUERIES ===
async def _user(cb): return await backend.get_user(cb.from_user.id)

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

@router.callback_query(F.data == "menu:main")
async def cb_main(cb: CallbackQuery):
    await show_menu(cb.message, backend, cb.from_user.id)
    await cb.answer()

@router.callback_query(F.data == "menu:medicines")
async def cb_medicines(cb: CallbackQuery):
    u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start")
    else:
        meds = await backend.list_medicines(u["id"])
        if not meds: await cb.message.answer("No medicines yet.", reply_markup=_menu())
        else:
            txt = "Your Medicines:\n\n"
            for m in meds:
                sc = await backend.list_schedules(m["id"])
                ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
                txt += "- {} ({}) - {}\n".format(m["name"], m["dosage"], ts)
            b = InlineKeyboardBuilder()
            b.button(text="Set reminder", callback_data="menu:schedule")
            b.button(text="Back", callback_data="menu:main"); b.adjust(1)
            await cb.message.answer(txt, reply_markup=b.as_markup())
    await cb.answer()

@router.callback_query(F.data == "menu:add")
async def cb_add(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start"); await cb.answer(); return
    await state.set_state(AddMedicineState.waiting_for_name)
    await cb.message.answer("What is the name of the medicine?\n(e.g., Aspirin, Metformin)", reply_markup=_cancel())
    await cb.answer()

@router.callback_query(F.data == "menu:schedule")
async def cb_sched(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start"); await cb.answer(); return
    meds = await backend.list_medicines(u["id"])
    if not meds: await cb.message.answer("No medicines yet."); await cb.answer(); return
    builder = InlineKeyboardBuilder()
    for m in meds:
        sc = await backend.list_schedules(m["id"])
        ts = ", ".join(s["reminder_time"][:5] for s in sc) if sc else "no reminders"
        builder.button(text="{} ({})".format(m["name"], ts), callback_data="sched:pick:{}".format(m["id"]))
    builder.adjust(1)
    builder.button(text="Cancel", callback_data="action:cancel"); builder.adjust(1)
    await state.set_state(ScheduleState.selecting_medicine)
    await state.update_data(user_id=u["id"])
    await cb.message.answer("Choose a medicine, then type time (HH:MM).", reply_markup=builder.as_markup())
    await cb.answer()

@router.callback_query(F.data == "menu:history")
async def cb_history(cb: CallbackQuery):
    u = await _user(cb)
    if not u: await cb.message.answer("Please register first with /start")
    else:
        h = await backend.get_intake_history(u["id"], limit=20)
        if not h: await cb.message.answer("No intake history yet.", reply_markup=_menu())
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
    if not u: await cb.message.answer("Please register first with /start")
    else:
        meds = await backend.list_medicines(u["id"])
        if not meds: await cb.message.answer("No medicines scheduled.", reply_markup=_menu())
        else:
            now = datetime.now(timezone(timedelta(hours=3)))
            cur = now.hour * 60 + now.minute; items = []
            for med in meds:
                for s in await backend.list_schedules(med["id"]):
                    t = s["reminder_time"][:5]; p = t.split(":"); sm = int(p[0])*60 + int(p[1])
                    if sm >= cur: items.append((sm, t, med["name"], med["dosage"]))
            if not items: await cb.message.answer("No more medicines scheduled.", reply_markup=_menu())
            else:
                counts = Counter((t,n,d) for _,t,n,d in items); seen = set(); items.sort()
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
    if not u: await cb.message.answer("Please register first with /start"); await cb.answer(); return
    meds = await backend.list_medicines(u["id"])
    if not meds: await cb.message.answer("No medicines to edit."); await cb.answer(); return
    b = InlineKeyboardBuilder()
    for m in meds: b.button(text=m["name"], callback_data="med:select:{}".format(m["id"]))
    b.button(text="Back", callback_data="menu:main"); b.adjust(1)
    await state.set_state(EditMedicineState.selecting_medicine)
    await cb.message.answer("Select medicine:", reply_markup=b.as_markup())
    await cb.answer()

@router.callback_query(F.data == "action:cancel")
async def cb_cancel(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    await cb.message.edit_text("Cancelled.", reply_markup=_menu())
    await cb.answer()

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

# === 4. CATCH-ALL TEXT HANDLER — MUST BE LAST ===
@router.message()
async def handle_ai(message: Message, state: FSMContext):
    # This catches ALL messages not handled above
    if message.text:
        logger.info("CATCH-ALL message from %s: %s", message.from_user.id, message.text[:100])
        await handle_smart_message(message, state, backend)
ROUTER_EOF

echo "=== Copying to container ==="
docker cp bot/app/handlers/ai.py medreminder-bot:/app/app/handlers/ai.py
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Bot Logs ==="
docker compose logs --tail 8 bot
echo ""
echo "============================================"
echo "  FIX v29 APPLIED"
echo "============================================"
echo "  Changed: @router.message() without F.text filter"
echo "  Added: debug logging to trace message flow"
