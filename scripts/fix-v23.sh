#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v23 — AI Agent can change reminder times ==="

# 1. Update GigaChat service to parse change requests
cat > bot/app/services/gigachat.py << 'GIGA_EOF'
"""GigaChat AI Agent service."""
import httpx
import logging
import json
import re

logger = logging.getLogger(__name__)

CLIENT_ID = "019d71c5-fcf6-7a40-9c60-f5a1f934f9ca"
AUTH_KEY = "MDE5ZDcxYzUtZmNmNi03YTQwLTljNjAtZjVhMWY5MzRmOWNhOmE2ZDkzMjQyLTUwODgtNDM3Yy04ZmVmLTEwNTViNWUwYzE0NA=="
TOKEN_URL = "https://ngw.devices.sberbank.ru:9443/api/v2/oauth"
CHAT_URL = "https://gigachat.devices.sberbank.ru/api/v1/chat/completions"

class GigaChatClient:
    def __init__(self):
        self._access_token = None

    async def _get_token(self) -> str:
        if self._access_token:
            return self._access_token
        try:
            async with httpx.AsyncClient(verify=False) as client:
                headers = {
                    "Authorization": "Basic {}".format(AUTH_KEY),
                    "RqUID": CLIENT_ID,
                    "Content-Type": "application/x-www-form-urlencoded",
                }
                r = await client.post(TOKEN_URL, data={"scope": "GIGACHAT_API_PERS"}, headers=headers)
                r.raise_for_status()
                data = r.json()
                self._access_token = data.get("access_token", "")
                logger.info("GigaChat token obtained")
                return self._access_token
        except Exception as e:
            logger.error("Failed to get GigaChat token: {}".format(e))
            return ""

    async def ask(self, prompt: str, system_prompt: str = "") -> str:
        token = await self._get_token()
        if not token:
            return "Sorry, AI service is temporarily unavailable."
        try:
            headers = {
                "Authorization": "Bearer {}".format(token),
                "Content-Type": "application/json",
            }
            messages = []
            if system_prompt:
                messages.append({"role": "system", "content": system_prompt})
            messages.append({"role": "user", "content": prompt})
            payload = {
                "model": "GigaChat",
                "messages": messages,
                "temperature": 0.7,
                "max_tokens": 500,
            }
            async with httpx.AsyncClient(verify=False) as client:
                r = await client.post(CHAT_URL, json=payload, headers=headers, timeout=30.0)
                r.raise_for_status()
                data = r.json()
                reply = data.get("choices", [{}])[0].get("message", {}).get("content", "Sorry, I could not process your request.")
                return reply
        except Exception as e:
            logger.error("GigaChat error: {}".format(e))
            return "Sorry, AI service is temporarily unavailable."

    async def parse_medicine_request(self, text: str) -> dict:
        system_prompt = (
            "You are a medicine request parser. Analyze the user's message. "
            "If the message is about adding a medicine with a reminder time, return ONLY a JSON object: "
            '{"medicines": [{"name": "name", "dosage": "dosage", "times": ["HH:MM"]}]}'
            "If no time is specified, do not include times. If no dosage, use 'as prescribed'. "
            "If the message is NOT about adding medicines, return ONLY the word: NOT_A_REQUEST"
            "Return ONLY JSON or NOT_A_REQUEST, no explanation."
        )
        response = await self.ask(text, system_prompt)
        if response.strip() == "NOT_A_REQUEST":
            return None
        try:
            match = re.search(r'\{.*\}', response, re.DOTALL)
            if match:
                return json.loads(match.group())
        except:
            pass
        return None

    async def parse_change_reminder_request(self, text: str) -> dict:
        system_prompt = (
            "You are a reminder change parser. "
            "If the user wants to change a reminder time, return ONLY JSON: "
            '{"medicine": "name", "old_time": "HH:MM", "new_time": "HH:MM"}'
            "If not a change reminder request, return ONLY the word: NOT_A_REQUEST"
            "Examples: 'Change Aspirin from 08:00 to 09:00', 'Remind me to take Ibuprofen at 19:30 instead of 18:00'"
            "Return ONLY JSON or NOT_A_REQUEST, no explanation."
        )
        response = await self.ask(text, system_prompt)
        if "NOT_A_REQUEST" in response:
            return None
        try:
            match = re.search(r'\{.*\}', response, re.DOTALL)
            if match:
                return json.loads(match.group())
        except:
            pass
        return None
GIGA_EOF

# 2. Update backend client to support schedule updates
python3 << 'PYEOF'
path = "/opt/medicine-reminder/bot/app/services/backend_client.py"
with open(path) as f:
    content = f.read()

if "async def update_schedule" not in content:
    # Add method before get_pending_due
    old = "    async def get_pending_due(self):"
    new = """    async def update_schedule(self, schedule_id: int, reminder_time: str) -> dict:
        c = await self._get_client()
        r = await c.patch(f"/schedules/{schedule_id}", params={"reminder_time": reminder_time})
        r.raise_for_status()
        return r.json()

    async def get_pending_due(self):"""
    content = content.replace(old, new)
    with open(path, "w") as f:
        f.write(content)
    print("  Patched backend_client.py with update_schedule method.")
else:
    print("  update_schedule method already exists.")
PYEOF

# 3. Add update endpoint to backend
python3 << 'PYEOF'
path = "/opt/medicine-reminder/backend/app/api/endpoints.py"
with open(path) as f:
    content = f.read()

endpoint_code = '''

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

if "update_schedule_endpoint" not in content:
    content = content.rstrip() + endpoint_code
    with open(path, "w") as f:
        f.write(content)
    print("  Added PATCH /schedules/{schedule_id} endpoint.")
else:
    print("  Update schedule endpoint already exists.")
PYEOF

# 4. Update AI handler to process change requests
cat > bot/app/handlers/ai.py << 'AI_EOF'
"""Smart AI handler — auto-detects medicine requests, change requests, and answers questions."""
import logging
from aiogram.types import Message
from aiogram.fsm.context import FSMContext
from app.services.gigachat import GigaChatClient
from app.services.backend_client import BackendClient
from app.handlers.start import build_main_menu

logger = logging.getLogger(__name__)
giga = GigaChatClient()

async def handle_smart_message(message: Message, state: FSMContext, backend: BackendClient):
    """Process any user message."""
    text = message.text.strip()
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    
    # 1. Try to parse as CHANGE reminder request
    change_req = await giga.parse_change_reminder_request(text)
    if change_req:
        await _handle_change_reminder(message, change_req, backend)
        return

    # 2. Try to parse as ADD medicine request
    add_req = await giga.parse_medicine_request(text)
    if add_req and "medicines" in add_req and add_req["medicines"]:
        await _handle_addition(message, add_req, backend)
        return
    
    # 3. General AI question/answer
    thinking = await message.answer("Thinking...")
    lower_text = text.lower()
    medicine_words = ["medicine", "drug", "pill", "tablet", "aspirin", "ibuprofen", "paracetamol", 
                      "vitamin", "dose", "side effect", "take", "swallow", "prescription",
                      "medication", "treatment", "pain", "headache", "fever", "cold", "flu"]
    if any(w in lower_text for w in medicine_words):
        system_prompt = (
            "You are a medical assistant for a medicine reminder bot. "
            "Answer briefly (2-3 sentences). Be helpful but do not give medical advice. "
            "Always suggest consulting a doctor."
        )
    else:
        system_prompt = "You are a helpful assistant for a medicine reminder bot. Answer briefly."
    
    reply = await giga.ask(text, system_prompt)
    try:
        await thinking.delete()
    except:
        pass
    await message.answer(reply, reply_markup=build_main_menu())

async def _handle_addition(message, request, backend):
    user = await backend.get_user(message.from_user.id)
    if not user: return
    thinking = await message.answer("Adding medicines...")
    added = []; errors = []
    for med in request["medicines"]:
        try:
            name = med.get("name", ""); dosage = med.get("dosage", "as prescribed"); times = med.get("times", [])
            if not name: errors.append("Skipped: no name"); continue
            medicine = await backend.add_medicine(user["id"], name, dosage)
            for t in times:
                try: await backend.add_schedule(medicine["id"], t)
                except: errors.append("Could not set reminder at {} for {}".format(t, name))
            item = "{} {}".format(name, dosage)
            if times: item += " at " + ", ".join(times)
            added.append(item)
        except Exception as e: errors.append("Could not add {}: {}".format(med.get("name", "unknown"), str(e)))
    try: await thinking.delete()
    except: pass
    response = ""
    if added: response += "Added:\n" + "\n".join("- " + a for a in added)
    if errors:
        if response: response += "\n\n"
        response += "Issues:\n" + "\n".join("- " + e for e in errors)
    if not response: response = "Nothing was added."
    await message.answer(response, reply_markup=build_main_menu())

async def _handle_change_reminder(message, request, backend):
    user = await backend.get_user(message.from_user.id)
    if not user: return
    thinking = await message.answer("Changing reminder...")
    medicines = await backend.list_medicines(user["id"])
    med_name = request.get("medicine", "").lower()
    old_time = request.get("old_time", "").strip()
    new_time = request.get("new_time", "").strip()
    found_med = None
    for m in medicines:
        if m["name"].lower() == med_name:
            found_med = m; break
    if not found_med:
        try: await thinking.delete()
        except: pass
        await message.answer("Could not find medicine named '{}'.".format(request.get("medicine")), reply_markup=build_main_menu())
        return

    schedules = await backend.list_schedules(found_med["id"])
    found_sched = None
    for s in schedules:
        if s["reminder_time"].startswith(old_time):
            found_sched = s; break
    if not found_sched:
        try: await thinking.delete()
        except: pass
        await message.answer("Could not find a reminder at {} for {}.".format(old_time, found_med["name"]), reply_markup=build_main_menu())
        return

    try:
        await backend.update_schedule(found_sched["id"], new_time)
        try: await thinking.delete()
        except: pass
        await message.answer("Reminder for {} changed from {} to {}.".format(found_med["name"], old_time, new_time), reply_markup=build_main_menu())
    except Exception as e:
        try: await thinking.delete()
        except: pass
        await message.answer("Error updating reminder: {}".format(str(e)), reply_markup=build_main_menu())
AI_EOF

# 5. Copy everything to container
echo "=== Copying to container ==="
docker cp bot/app/services/gigachat.py medreminder-bot:/app/app/services/gigachat.py
docker cp bot/app/services/backend_client.py medreminder-bot:/app/app/services/backend_client.py
docker cp backend/app/api/endpoints.py medreminder-backend:/app/app/api/endpoints.py
docker cp bot/app/handlers/ai.py medreminder-bot:/app/app/handlers/ai.py

echo "=== Restarting services ==="
docker compose restart bot backend
sleep 10

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
docker compose logs --tail 5 backend
echo ""
echo "============================================"
echo "  FIX v23 APPLIED"
echo "============================================"
echo "  AI Agent can now change reminders:"
echo "  'Change Aspirin from 19:00 to 19:30'"
echo "  'Remind me to take Ibuprofen at 08:00 instead of 07:00'"
