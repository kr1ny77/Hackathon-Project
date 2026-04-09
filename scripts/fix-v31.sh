#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v31 — Fix .format() KeyError in gigachat.py ==="

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
            '{{"action":"add","medicines":[{{"name":"name","dosage":"dosage","times":["HH:MM"]}}]}}\n'
            '{{"action":"change_time","medicine":"name","old_time":"HH:MM","new_time":"HH:MM"}}\n'
            '{{"action":"delete_reminder","medicine":"name","time":"HH:MM"}}\n'
            '{{"action":"edit_name","medicine":"name","new_name":"new"}}\n'
            '{{"action":"edit_dosage","medicine":"name","new_dosage":"new"}}\n'
            '{{"action":"delete_medicine","medicine":"name"}}\n'
            '{{"action":"list_medicines"}}\n'
            '{{"action":"today_schedule"}}\n'
            '{{"action":"intake_history"}}\n'
            '{{"action":"question","text":"original user text"}}'
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

echo "=== Copying to container ==="
docker cp bot/app/services/gigachat.py medreminder-bot:/app/app/services/gigachat.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
echo ""
echo "=== DONE v31 ==="
