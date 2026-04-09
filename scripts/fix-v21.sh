#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v21 — Smart AI Chat (no commands needed) ==="

# 1. Add GigaChat client service
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
        """Parse natural language request for adding medicines. Returns None if not a medicine request."""
        system_prompt = (
            "You are a medicine request parser. Analyze the user's message. "
            "If the message is about adding a medicine with a reminder time, return ONLY a JSON object: "
            '{"medicines": [{"name": "name", "dosage": "dosage", "times": ["HH:MM"]}]}'
            "If no time is specified, do not include times. If no dosage, use 'as prescribed'. "
            "If the message is NOT about adding medicines, return ONLY the word: NOT_A_REQUEST"
            "Examples of requests: 'Add Aspirin at 08:00', 'I need to take Ibuprofen every day at 19:00', 'Remind me to drink water at 7pm'"
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
GIGA_EOF

# 2. Smart AI handler
cat > bot/app/handlers/ai.py << 'AI_EOF'
"""Smart AI handler — auto-detects medicine requests and answers questions."""
import logging
from aiogram.types import Message
from aiogram.fsm.context import FSMContext
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.gigachat import GigaChatClient
from app.services.backend_client import BackendClient
from app.handlers.start import build_main_menu

logger = logging.getLogger(__name__)
giga = GigaChatClient()

async def handle_smart_message(message: Message, state: FSMContext, backend: BackendClient):
    """Process any user message: try to parse as medicine request, otherwise answer with AI."""
    text = message.text.strip()
    
    # Check if user is registered
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    
    # Step 1: Try to parse as medicine request
    request = await giga.parse_medicine_request(text)
    if request and "medicines" in request and request["medicines"]:
        await _handle_addition(message, request, backend)
        return
    
    # Step 2: It's a question or general message — answer with AI
    thinking = await message.answer("Thinking...")
    
    # Check if it looks like a medicine question
    lower_text = text.lower()
    medicine_words = ["medicine", "drug", "pill", "tablet", "aspirin", "ibuprofen", "paracetamol", 
                      "vitamin", "dose", "side effect", "take", "swallow", "prescription",
                      "medication", "treatment", "pain", "headache", "fever", "cold", "flu"]
    
    if any(w in lower_text for w in medicine_words):
        system_prompt = (
            "You are a medical assistant for a medicine reminder bot. "
            "Answer briefly (2-3 sentences) about the medicine or health topic. "
            "Be helpful but do not give medical advice. Always suggest consulting a doctor."
        )
    else:
        system_prompt = (
            "You are a helpful assistant for a medicine reminder bot. "
            "Answer briefly and helpfully. You can tell jokes about medicines if asked."
        )
    
    reply = await giga.ask(text, system_prompt)
    try:
        await thinking.delete()
    except:
        pass
    await message.answer(reply, reply_markup=build_main_menu())

async def _handle_addition(message, request, backend):
    """Add medicines from parsed request."""
    user = await backend.get_user(message.from_user.id)
    if not user: return
    
    thinking = await message.answer("Adding medicines...")
    added = []
    errors = []
    
    for med in request["medicines"]:
        try:
            name = med.get("name", "")
            dosage = med.get("dosage", "as prescribed")
            times = med.get("times", [])
            
            if not name:
                errors.append("Skipped: no medicine name")
                continue
            
            medicine = await backend.add_medicine(user["id"], name, dosage)
            
            for t in times:
                try:
                    await backend.add_schedule(medicine["id"], t)
                except Exception:
                    errors.append("Could not set reminder at {} for {}".format(t, name))
            
            item = "{} {}".format(name, dosage)
            if times:
                item += " at " + ", ".join(times)
            added.append(item)
        except Exception as e:
            errors.append("Could not add {}: {}".format(med.get("name", "unknown"), str(e)))
    
    try:
        await thinking.delete()
    except:
        pass
    
    response = ""
    if added:
        response += "Added:\n" + "\n".join("- " + a for a in added)
    if errors:
        if response: response += "\n\n"
        response += "Issues:\n" + "\n".join("- " + e for e in errors)
    if not response:
        response = "Nothing was added. Please try again."
    
    await message.answer(response, reply_markup=build_main_menu())
AI_EOF

# 3. Update router.py — replace /ask and /auto with smart handler
python3 << 'PYEOF'
path = "/opt/medicine-reminder/bot/app/handlers/router.py"
with open(path) as f:
    content = f.read()

# Remove old /ask and /auto imports if present
content = content.replace("from app.handlers.ai import cmd_ask, cmd_auto", "from app.handlers.ai import handle_smart_message")
content = content.replace("from app.handlers.ai import cmd_ask, cmd_auto\n", "")

# Remove old /ask and /auto handlers
import re
content = re.sub(r'\n@router\.message\(Command\("ask"\)\).*?async def handle_ask.*?\n', '\n', content, flags=re.DOTALL)
content = re.sub(r'\n@router\.message\(Command\("auto"\)\).*?async def handle_auto.*?\n', '\n', content, flags=re.DOTALL)

# Add smart message handler at the end (before the last line)
smart_handler = """
# Smart handler — catches all non-command messages
@router.message(F.text)
async def handle_smart(message: Message, state: FSMContext):
    await handle_smart_message(message, state, backend)
"""

if "handle_smart_message" not in content or "@router.message(F.text)" not in content:
    # Find last callback_query handler and add after it
    content = content.rstrip() + "\n" + smart_handler + "\n"
    with open(path, "w") as f:
        f.write(content)
    print("  Added smart message handler to router.py")
else:
    print("  Smart handler already in router.py")
PYEOF

echo "=== Copying to container ==="
docker cp bot/app/services/gigachat.py medreminder-bot:/app/app/services/gigachat.py
docker cp bot/app/handlers/ai.py medreminder-bot:/app/app/handlers/ai.py
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 8

echo ""
echo "=== Logs ==="
docker compose logs --tail 8 bot
echo ""
echo "============================================"
echo "  FIX v21 APPLIED — Smart AI Chat"
echo "============================================"
echo ""
echo "  Just type in the chat — no commands needed!"
echo ""
echo "  Examples:"
echo "  Add Aspirin today at 7pm"
echo "  What is Ibuprofen?"
echo "  Remind me to take Vitamin D at 19:00"
echo "  Can I drink coffee with antibiotics?"
