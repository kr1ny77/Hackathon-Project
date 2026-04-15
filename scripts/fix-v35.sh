#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v35 — Fix GigaChat token expiry ==="

# Patch gigachat.py to handle token expiry
python3 << 'PYEOF'
path = "/opt/medicine-reminder/bot/app/services/gigachat.py"
with open(path) as f:
    content = f.read()

if "_token_expires" not in content:
    old_init = "    def __init__(self):\n        self._access_token = None"
    new_init = "    def __init__(self):\n        self._access_token = None\n        self._token_expires = 0"
    content = content.replace(old_init, new_init)

    old_get_token = "    async def _get_token(self):\n        if self._access_token: return self._access_token"
    new_get_token = "    async def _get_token(self):\n        import time\n        if self._access_token and time.time() < self._token_expires:\n            return self._access_token"
    content = content.replace(old_get_token, new_get_token)

    old_set = """                self._access_token = r.json().get("access_token","")"""
    new_set = """                data = r.json()
                self._access_token = data.get("access_token","")
                self._token_expires = time.time() + (data.get("expires_in", 1800) - 60)"""
    content = content.replace(old_set, new_set)

    with open(path, "w") as f:
        f.write(content)
    print("  Added token expiry handling.")
else:
    print("  Token expiry already handled.")
PYEOF

echo "=== Copying to container ==="
docker cp bot/app/services/gigachat.py medreminder-bot:/app/app/services/gigachat.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 8

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
echo ""
echo "============================================"
echo "  FIX v35 APPLIED"
echo "============================================"
echo "  GigaChat token now auto-refreshes every 30 min"
