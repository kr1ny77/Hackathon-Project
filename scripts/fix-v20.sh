#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v20 — GigaChat AI Agent ==="

# 1. Add GigaChat client service
cat > bot/app/services/gigachat.py << 'GIGA_EOF'
"""GigaChat AI Agent service."""
import httpx
import logging
import base64
import re
import json

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
                r = await client.post(CHAT_URL, json=payload, headers=headers)
                r.raise_for_status()
                data = r.json()
                reply = data.get("choices", [{}])[0].get("message", {}).get("content", "Sorry, I could not process your request.")
                return reply
        except Exception as e:
            logger.error("GigaChat error: {}".format(e))
            return "Sorry, AI service is temporarily unavailable."

    async def parse_medicine_request(self, text: str) -> dict:
        """Parse natural language request for adding medicines."""
        system_prompt = (
            "You are a medicine parser. Extract medicine names and reminder times from user text. "
            "Return ONLY a JSON object with this structure: "
            '{"medicines": [{"name": "name", "dosage": "dosage", "times": ["HH:MM", "HH:MM"]}]} '
            "If no time is specified, use '18:00' as default for evening. "
            "If no dosage is specified, use 'as prescribed'. "
            "Return ONLY the JSON, no explanation."
        )
        response = await self.ask(text, system_prompt)
        try:
            # Extract JSON from response
            match = re.search(r'\{.*\}', response, re.DOTALL)
            if match:
                return json.loads(match.group())
        except:
            pass
        return None
GIGA_EOF

# 2. Add GigaChat handlers
cat > bot/app/handlers/ai.py << 'AI_EOF'
"""AI handler for GigaChat integration."""
import logging
from aiogram.types import Message
from aiogram.fsm.context import FSMContext
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.gigachat import GigaChatClient
from app.services.backend_client import BackendClient
from app.handlers.start import build_main_menu

logger = logging.getLogger(__name__)
giga = GigaChatClient()

async def cmd_ask(message: Message, backend: BackendClient):
    """Ask AI about medicine."""
    text = message.text.replace("/ask", "").strip()
    if not text:
        await message.answer("Ask me about any medicine. For example:\n/ask What is Aspirin?\n/ask What are side effects of Paracetamol?")
        return
    await message.answer("Thinking...")
    reply = await giga.ask("What is {}? Answer in 2-3 sentences.".format(text))
    # Delete "Thinking..." message and send reply
    await message.answer(reply)

async def cmd_auto(message: Message, state: FSMContext, backend: BackendClient):
    """Auto-parse medicine request using AI."""
    text = message.text.replace("/auto", "").strip()
    if not text:
        await message.answer("Tell me what medicines to add and when.\nExample: /auto Add Aspirin at 08:00 and Ibuprofen at 20:00")
        return
    
    # Check if user is registered
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("Please register first with /start")
        return
    
    await message.answer("Processing your request...")
    
    # Parse request using GigaChat
    result = await giga.parse_medicine_request(text)
    if not result or "medicines" not in result:
        await message.answer("Sorry, I could not understand your request. Please try a different format.\nExample: Add Aspirin at 08:00 and Ibuprofen at 20:00")
        return
    
    added = []
    errors = []
    
    for med in result["medicines"]:
        try:
            name = med.get("name", "")
            dosage = med.get("dosage", "as prescribed")
            times = med.get("times", [])
            
            if not name:
                errors.append("Skipped: no medicine name provided")
                continue
            
            # Add medicine
            medicine = await backend.add_medicine(user["id"], name, dosage)
            
            # Add schedules
            for t in times:
                try:
                    await backend.add_schedule(medicine["id"], t)
                except Exception as e:
                    errors.append("Could not set reminder at {} for {}".format(t, name))
            
            added.append("{} ({})".format(name, dosage))
            if times:
                added[-1] += " at " + ", ".join(times)
        except Exception as e:
            errors.append("Could not add {}: {}".format(med.get("name", "unknown"), str(e)))
    
    # Build response
    response = ""
    if added:
        response += "Added:\n" + "\n".join("- " + a for a in added)
    if errors:
        if response:
            response += "\n\n"
        response += "Issues:\n" + "\n".join("- " + e for e in errors)
    
    if not response:
        response = "Nothing was added. Please try again."
    
    await message.answer(response, reply_markup=build_main_menu())
AI_EOF

# 3. Update router.py to add /ask and /auto commands
python3 << 'PYEOF'
path = "/opt/medicine-reminder/bot/app/handlers/router.py"
with open(path) as f:
    content = f.read()

# Add import
if "from app.handlers.ai import cmd_ask, cmd_auto" not in content:
    content = content.replace(
        "from app.handlers.intake import cb_intake_taken, cb_intake_reschedule, cmd_history",
        "from app.handlers.intake import cb_intake_taken, cb_intake_reschedule, cmd_history\nfrom app.handlers.ai import cmd_ask, cmd_auto"
    )

# Add /ask and /auto handlers
if 'Command("ask")' not in content:
    # Insert after /help handler
    help_end = content.find('await message.answer("Commands:')
    if help_end != -1:
        # Find the end of the help handler
        line_start = content.find('\n@router', help_end + 100)
        if line_start == -1:
            line_start = content.find('\nasync def _user', help_end)
        help_code = content.find('await message.answer("Commands:', help_end)
        # Find next @router after help
        next_handler = content.find('\n@router', help_code + 100)
        if next_handler == -1:
            next_handler = content.find('\nasync def _user(cb)', help_code)
        
        new_handlers = """
@router.message(Command("ask"))
async def handle_ask(message: Message):
    await cmd_ask(message, backend)

@router.message(Command("auto"))
async def handle_auto(message: Message, state: FSMContext):
    await cmd_auto(message, state, backend)

"""
        if next_handler != -1:
            content = content[:next_handler] + new_handlers + content[next_handler:]
        else:
            content += new_handlers
    
    with open(path, "w") as f:
        f.write(content)
    print("  Added /ask and /auto commands to router.py")
else:
    print("  /ask and /auto already in router.py")
PYEOF

# 4. Update requirements.txt
cat >> bot/requirements.txt << 'REQS'
# GigaChat dependencies
httpx>=0.27.0
REQS

echo "=== Copying to container ==="
docker cp bot/app/services/gigachat.py medreminder-bot:/app/app/services/gigachat.py
docker cp bot/app/handlers/ai.py medreminder-bot:/app/app/handlers/ai.py
docker cp bot/app/handlers/router.py medreminder-bot:/app/app/handlers/router.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
echo ""
echo "============================================"
echo "  FIX v20 APPLIED — GigaChat AI Agent"
echo "============================================"
echo "  New commands:"
echo "  /ask <question>  - Ask about any medicine"
echo "  /auto <request>  - Auto-add medicines by text"
echo ""
echo "  Examples:"
echo "  /ask What is Aspirin?"
echo "  /auto Add Aspirin at 08:00 and Ibuprofen at 20:00"
