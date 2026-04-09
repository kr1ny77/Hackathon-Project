#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v24 — Full AI Agent (all button actions) ==="

# 1. Update GigaChat with unified intent parser
cat > bot/app/services/gigachat.py << 'GIGA_EOF'
"""GigaChat AI Agent — unified intent parser."""
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
                return self._access_token
        except Exception as e:
            logger.error("GigaChat token error: {}".format(e)); return ""

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
        """Unified intent parser. Returns dict with action type and params."""
        med_list = ""
        if user_medicines:
            med_list = "\nUser's current medicines:\n"
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
            "If the message is a general question not about the user's specific medicines, use 'question' action. "
            "If adding medicine and no dosage, use 'as prescribed'. If no time, omit 'times'. "
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

# 2. Add list_medicines_with_schedules helper
python3 << 'PYEOF'
path = "/opt/medicine-reminder/bot/app/services/backend_client.py"
with open(path) as f:
    content = f.read()

if "async def list_medicines_with_schedules" not in content:
    old = "    async def list_medicines(self, user_id: int) -> list:"
    new = """    async def list_medicines_with_schedules(self, user_id: int) -> list:
        """ + '"""Get medicines with their schedule times for AI context."""' + """
        meds = await self.list_medicines(user_id)
        for m in meds:
            sc = await self.list_schedules(m["id"])
            m["schedules"] = ", ".join(s["reminder_time"][:5] for s in sc)
        return meds

    async def update_schedule(self, schedule_id, reminder_time):
        """ + '"""Update a reminder time."""' + """
        c = await self._get_client()
        r = await c.patch(f"/schedules/{schedule_id}", params={"reminder_time": reminder_time})
        r.raise_for_status()
        return r.json()

    async def delete_reminder_time(self, schedule_id, user_id):
        """ + '"""Delete a single reminder time."""' + """
        c = await self._get_client()
        r = await c.delete(f"/schedules/{schedule_id}?user_id={user_id}")
        return r.status_code == 204

    async def list_medicines(self, user_id: int) -> list:"""
    content = content.replace(old, new)
    with open(path, "w") as f: f.write(content)
    print("  Patched backend_client.py with helper methods.")
else:
    print("  Helpers already exist.")
PYEOF

# 3. Rewrite AI handler to use unified intent parser
cat > bot/app/handlers/ai.py << 'AI_EOF'
"""Full AI Agent — handles all actions via natural language."""
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

async def handle_smart_message(message: Message, state: FSMContext, backend: BackendClient):
    text = message.text.strip()
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start"); return

    # Get medicines for context + intent parsing
    medicines = await backend.list_medicines_with_schedules(user["id"])
    intent = await giga.parse_intent(text, medicines)
    action = intent.get("action", "question")

    await state.clear()

    if action == "add":
        await _do_add(message, intent, backend, user)
    elif action == "change_time":
        await _do_change_time(message, intent, backend, user, medicines)
    elif action == "delete_reminder":
        await _do_delete_reminder(message, intent, backend, user, medicines)
    elif action == "edit_name":
        await _do_edit_name(message, intent, backend, user, medicines)
    elif action == "edit_dosage":
        await _do_edit_dosage(message, intent, backend, user, medicines)
    elif action == "delete_medicine":
        await _do_delete_medicine(message, intent, backend, user, medicines)
    elif action == "list_medicines":
        await _do_list(message, medicines)
    elif action == "today_schedule":
        await cmd_today_schedule(message, backend)
    elif action == "intake_history":
        await cmd_history(message, backend)
    elif action == "question":
        await _do_question(message, text)
    else:
        await _do_question(message, text)

async def _do_add(message, intent, backend, user):
    thinking = await message.answer("Adding...")
    added = []; errors = []
    for med in intent.get("medicines", []):
        try:
            name = med.get("name",""); dosage = med.get("dosage","as prescribed"); times = med.get("times",[])
            if not name: errors.append("No name provided"); continue
            m = await backend.add_medicine(user["id"], name, dosage)
            for t in times:
                try: await backend.add_schedule(m["id"], t)
                except: errors.append("Could not set {} for {}".format(t, name))
            item = "{} {}".format(name, dosage)
            if times: item += " at " + ", ".join(times)
            added.append(item)
        except Exception as e: errors.append("Could not add {}: {}".format(med.get("name",""), str(e)))
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
    if not found:
        await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    sc = await backend.list_schedules(found["id"]); sched = None
    for s in sc:
        if s["reminder_time"].startswith(old_t): sched = s; break
    if not sched:
        await message.answer("No reminder at {} for {}.".format(old_t, found["name"]), reply_markup=build_main_menu()); return
    try:
        await backend.update_schedule(sched["id"], new_t)
        await message.answer("Changed {} from {} to {}.".format(found["name"], old_t, new_t), reply_markup=build_main_menu())
    except Exception as e:
        await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_delete_reminder(message, intent, backend, user, medicines):
    med_name = intent.get("medicine","").lower(); t = intent.get("time","").strip()
    found = None
    for m in medicines:
        if m["name"].lower() == med_name: found = m; break
    if not found:
        await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    sc = await backend.list_schedules(found["id"]); sched = None
    for s in sc:
        if s["reminder_time"].startswith(t): sched = s; break
    if not sched:
        await message.answer("No reminder at {} for {}.".format(t, found["name"]), reply_markup=build_main_menu()); return
    try:
        await backend.delete_reminder_time(sched["id"], user["id"])
        await message.answer("Deleted {} reminder at {} for {}.".format(found["name"], t, found["name"]), reply_markup=build_main_menu())
    except Exception as e:
        await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_edit_name(message, intent, backend, user, medicines):
    med_name = intent.get("medicine","").lower(); new_name = intent.get("new_name","")
    found = None
    for m in medicines:
        if m["name"].lower() == med_name: found = m; break
    if not found:
        await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    try:
        await backend.update_medicine(found["id"], user["id"], name=new_name)
        await message.answer("Renamed to '{}'.".format(new_name), reply_markup=build_main_menu())
    except Exception as e:
        await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_edit_dosage(message, intent, backend, user, medicines):
    med_name = intent.get("medicine","").lower(); new_dosage = intent.get("new_dosage","")
    found = None
    for m in medicines:
        if m["name"].lower() == med_name: found = m; break
    if not found:
        await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    try:
        await backend.update_medicine(found["id"], user["id"], dosage=new_dosage)
        await message.answer("Dosage for {} changed to '{}'.".format(found["name"], new_dosage), reply_markup=build_main_menu())
    except Exception as e:
        await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_delete_medicine(message, intent, backend, user, medicines):
    med_name = intent.get("medicine","").lower()
    found = None
    for m in medicines:
        if m["name"].lower() == med_name: found = m; break
    if not found:
        await message.answer("Could not find '{}'.".format(intent.get("medicine")), reply_markup=build_main_menu()); return
    try:
        await backend.delete_medicine(found["id"], user["id"])
        await message.answer("Deleted {}.".format(found["name"]), reply_markup=build_main_menu())
    except Exception as e:
        await message.answer("Error: {}".format(str(e)), reply_markup=build_main_menu())

async def _do_list(message, medicines):
    if not medicines:
        await message.answer("No medicines yet.", reply_markup=build_main_menu()); return
    txt = "Your Medicines:\n\n"
    for m in medicines:
        sc = m.get("schedules","") or "no reminders"
        txt += "- {} ({}) - {}\n".format(m["name"], m["dosage"], sc)
    await message.answer(txt, reply_markup=build_main_menu())

async def _do_question(message, text):
    thinking = await message.answer("Thinking...")
    lower = text.lower()
    med_words = ["medicine","drug","pill","tablet","aspirin","ibuprofen","paracetamol","vitamin","dose","side effect","take","swallow","prescription","medication","treatment","pain","headache","fever"]
    if any(w in lower for w in med_words):
        sp = "You are a medical assistant. Answer briefly (2-3 sentences). Suggest consulting a doctor."
    else:
        sp = "You are a helpful assistant for a medicine reminder bot. Answer briefly."
    reply = await giga.ask(text, sp)
    try: await thinking.delete()
    except: pass
    await message.answer(reply, reply_markup=build_main_menu())
AI_EOF

# 4. Add PATCH endpoint to backend
python3 << 'PYEOF'
path = "/opt/medicine-reminder/backend/app/api/endpoints.py"
with open(path) as f:
    content = f.read()
if "update_schedule_endpoint" not in content:
    patch_code = '''

@router.patch("/schedules/{schedule_id}", response_model=ReminderScheduleResponse)
async def update_schedule_endpoint(schedule_id: int, reminder_time: str, db: AsyncSession = Depends(get_db)):
    """Update a reminder time."""
    from app.models.models import ReminderSchedule
    result = await db.execute(select(ReminderSchedule).where(ReminderSchedule.id == schedule_id))
    schedule = result.scalar_one_or_none()
    if not schedule:
        raise HTTPException(status_code=404, detail="Schedule not found")
    h, m = reminder_time.split(":")
    schedule.reminder_time = time(int(h), int(m))
    await db.flush()
    await db.refresh(schedule)
    return ReminderScheduleResponse.model_validate(schedule)
'''
    content = content.rstrip() + patch_code
    with open(path, "w") as f: f.write(content)
    print("  Added PATCH /schedules/{schedule_id}.")
else:
    print("  PATCH endpoint exists.")
PYEOF

echo "=== Copying to containers ==="
docker cp bot/app/services/gigachat.py medreminder-bot:/app/app/services/gigachat.py
docker cp bot/app/services/backend_client.py medreminder-bot:/app/app/services/backend_client.py
docker cp bot/app/handlers/ai.py medreminder-bot:/app/app/handlers/ai.py
docker cp backend/app/api/endpoints.py medreminder-backend:/app/app/api/endpoints.py

echo "=== Restarting ==="
docker compose restart bot backend
sleep 10

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
docker compose logs --tail 5 backend
echo ""
echo "============================================"
echo "  FIX v24 APPLIED — Full AI Agent"
echo "============================================"
echo ""
echo "  The AI now handles ALL button actions via text:"
echo ""
echo "  Action                  | Example"
echo "  ------------------------|------------------------------------------"
echo "  Add medicine            | Add Aspirin at 08:00 and Vitamin D at 19:00"
echo "  Change reminder         | Change Aspirin from 08:00 to 09:00"
echo "  Delete reminder time    | Delete the 08:00 reminder for Aspirin"
echo "  Edit name               | Rename Aspirin to Acetylsalicylic acid"
echo "  Edit dosage             | Change Aspirin dosage to 500mg"
echo "  Delete medicine         | Delete Ibuprofen"
echo "  List medicines          | What medicines do I have?"
echo "  Today's schedule        | What's my schedule for today?"
echo "  Intake history          | Show my intake history"
echo "  Medicine question       | What is Paracetamol?"
echo "  General chat            | Tell me a joke"
