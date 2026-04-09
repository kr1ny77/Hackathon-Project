#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v27 — Add list_medicines_with_schedules method ==="

python3 << 'PYEOF'
path = "/opt/medicine-reminder/bot/app/services/backend_client.py"
with open(path) as f:
    content = f.read()

if "list_medicines_with_schedules" not in content:
    # Add method right after list_medicines
    old = """    async def list_medicines(self, user_id: int) -> list:
        c = await self._get_client()
        r = await c.get(f"/medicines/user/{user_id}")
        r.raise_for_status()
        return r.json()"""
    new = """    async def list_medicines(self, user_id: int) -> list:
        c = await self._get_client()
        r = await c.get(f"/medicines/user/{user_id}")
        r.raise_for_status()
        return r.json()

    async def list_medicines_with_schedules(self, user_id: int) -> list:
        meds = await self.list_medicines(user_id)
        for m in meds:
            sc = await self.list_schedules(m["id"])
            m["schedules"] = ", ".join(s["reminder_time"][:5] for s in sc)
        return meds"""
    content = content.replace(old, new)
    with open(path, "w") as f: f.write(content)
    print("  Added list_medicines_with_schedules method.")
else:
    print("  Method already exists.")
PYEOF

echo "=== Copying to container ==="
docker cp bot/app/services/backend_client.py medreminder-bot:/app/app/services/backend_client.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
echo ""
echo "============================================"
echo "  FIX v27 APPLIED"
echo "============================================"
