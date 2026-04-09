#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v15 — Fix delete medicine callback parsing ==="

python3 << 'PYEOF'
import os

path = "/opt/medicine-reminder/bot/app/handlers/medicine.py"
with open(path) as f:
    content = f.read()

# Fix split index in handle_execute_delete_medicine
# Was: callback.data.split(":", 3)[3] — WRONG (only 3 parts: med:confirm_delete_full:ID)
# Fix: callback.data.split(":", 2)[2] — CORRECT
old = 'med_id = int(callback.data.split(":", 3)[3])'
new = 'med_id = int(callback.data.split(":", 2)[2])'
content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)
print("  Patched handle_execute_delete_medicine callback parsing.")
PYEOF

echo "=== Copying to container ==="
docker cp bot/app/handlers/medicine.py medreminder-bot:/app/app/handlers/medicine.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
echo ""
echo "============================================"
echo "  FIX v15 APPLIED"
echo "============================================"
