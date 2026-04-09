#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v26 — AI Agent Fixed (keyword filtering) ==="

# 1. gigachat.py — clean, simple, unified intent parser
cat > bot/app/services/gigachat.py << 'GIGA_EOF'
"""GigaChat AI Agent."""
import httpx, logging, json, re

logger = logging.getLogger(__name__)
CLIENT_ID = "019d71c5-fcf6-7a40-9c60-f5a1f934f9ca"
AUTH_KEY = "MDE5ZDcxYzUtZmNmNi03YTQwLTljNjAtZjVhMWY5MzRmOWNhOmE2ZDkzMjQyLTUwODgtNDM3Yy04ZmVmLTEwNTViNWUwYzE0NA=="
TOKEN_URL = "https://ngw.devices.sberbank.ru:9443/api/v2/oauth"
CHAT_URL = "https://gigachat.devices.sberbank.ru/api/v1/chat/completions"

class GigaChatClient:
    def __init__(self):
        self._access_token = None

    async def _get_token(self):
        if self._access_token: return self._access_token
        try:
            async with httpx.AsyncClient(verify=False) as c:
                r = await c.post(TOKEN_URL, data={"scope":"GIGACHAT_API_PERS"},
                    headers={"Authorization":"Basic {}".format(AUTH_KEY),"RqUID":CLIENT_ID,"Content-Type":"application/x-www-form-urlencoded"})
                r.raise_for_status()
                self._access_token = r.json().get("access_token","")
                logger.info("GigaChat token obtained")
                return self._access_token
        except Exception as e:
            logger.error("Token error: {}".format(e)); return ""

    async def ask(self, prompt, system_prompt=""):
        token = await self._get_token()
        if not token: return "Sorry, AI service is unavailable."
        try:
            msgs = []
            if system_prompt: msgs.append({"role":"system","content":system_prompt})
            msgs.append({"role":"user","content":prompt})
            async with httpx.AsyncClient(verify=False) as c:
                r = await c.post(CHAT_URL, json={"model":"GigaChat","messages":msgs,"temperature":0.7,"max_tokens":500},
                    headers={"Authorization":"Bearer {}".format(token),"Content-Type":"application/json"}, timeout=30.0)
                r.raise_for_status()
                return r.json().get("choices",[{}])[0].get("message",{}).get("content","")
        except Exception as e:
            logger.error("GigaChat error: {}".format(e)); return "Sorry, AI service is unavailable."

    async def parse_intent(self, text, user_medicines=None):
        med_list = ""
        if user_medicines:
            med_list = "\nCurrent medicines:\n"
            for m in user_medicines:
                med_list += "- {} ({}): {}\n".format(m["name"], m["dosage"], m.get("schedules",""))
        system = (
            "You are a medicine assistant intent parser. Analyze the user message and return ONLY JSON. "
            "Possible actions:\n"
            '{"action":"add","medicines":[{"name":"name","dosage":"dosage","times":["HH:MM"]}]}\n'
            '{"action":"change_time","medicine":"name","old_time":"HH:MM","new_time":"HH:MM"}\n'
            '{"action":"delete_reminder","medicine":"name","time":"HH:MM"}\n'
            '{"action":"edit_name","medicine":"name","new_name":"new"}\n'
            '{"action":"edit_dosage","medicine":"name","new_dosage":"new"}\n'
            '{"action":"delete_medicine","medicine":"name"}\n'
            '{"action":"list_medicines"}\n'
            '{"action":"today_schedule"}\n'
            '{"action":"intake_history"}\n'
            '{"action":"question","text":"original user text"}'
            "If about medicine/health questions, use 'question'. "
            "{}"
            "Return ONLY JSON, no explanation."
        ).format(med_list if med_list else "")
        response = await self.ask(text, system)
        try:
            match = re.search(r'\{.*\}', response, re.DOTALL)
            if match: return json.loads(match.group())
        except: pass
        return {"action":"question","text":text}
GIGA_EOF

# 2. ai.py — keyword-based filtering, no extra GigaChat calls
cat > bot/app/handlers/ai.py << 'AI_EOF'
"""Full AI Agent."""
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
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start"); return

    medicines = await backend.list_medicines_with_schedules(user["id"])
    intent = await giga.parse_intent(text, medicines)
    action = intent.get("action", "question")
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

echo "=== Copying to container ==="
docker cp bot/app/services/gigachat.py medreminder-bot:/app/app/services/gigachat.py
docker cp bot/app/handlers/ai.py medreminder-bot:/app/app/handlers/ai.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 8

echo ""
echo "=== Bot Logs ==="
docker compose logs --tail 8 bot
echo ""
echo "============================================"
echo "  FIX v26 APPLIED"
echo "============================================"
echo "  AI Agent is back online!"
echo "  - Keyword filtering (no extra GigaChat calls)"
echo "  - All button actions via text"
echo "  - Health topics only"
