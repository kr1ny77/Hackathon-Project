#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v30 — Add missing method on VM ==="

# Check if method already exists
if grep -q "list_medicines_with_schedules" bot/app/services/backend_client.py; then
    echo "Method already exists."
else
    echo "Adding list_medicines_with_schedules method..."
    cat >> bot/app/services/backend_client.py << 'METHOD'

    async def list_medicines_with_schedules(self, user_id: int) -> list:
        meds = await self.list_medicines(user_id)
        for m in meds:
            sc = await self.list_schedules(m["id"])
            m["schedules"] = ", ".join(s["reminder_time"][:5] for s in sc)
        return meds
METHOD
    echo "Method added."
fi

# Copy to container
echo "Copying to container..."
docker cp bot/app/services/backend_client.py medreminder-bot:/app/app/services/backend_client.py

# Restart bot
echo "Restarting bot..."
docker compose restart bot
sleep 6

# Show logs
echo ""
echo "=== Bot Logs ==="
docker compose logs --tail 10 bot
echo ""
echo "=== DONE v30 ==="