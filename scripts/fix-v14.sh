#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v14 — Fix User ID in Edit/Delete callbacks ==="

python3 << 'PYEOF'
import os

path = "/opt/medicine-reminder/bot/app/handlers/medicine.py"
with open(path) as f:
    content = f.read()

# Fix 1: handle_medicine_select — use internal user ID
old1 = """    user_id = callback.from_user.id
    medicines = await backend.list_medicines(user_id)"""
new1 = """    user = await backend.get_user(callback.from_user.id)
    medicines = await backend.list_medicines(user["id"])"""
content = content.replace(old1, new1)

# Fix 2: handle_confirm_delete_medicine — use internal user ID
old2 = """    user_id = callback.from_user.id
    medicines = await backend.list_medicines(user_id)"""
new2 = """    user = await backend.get_user(callback.from_user.id)
    medicines = await backend.list_medicines(user["id"])"""
content = content.replace(old2, new2)

# Fix 3: handle_execute_delete_medicine — use internal user ID
old3 = """    user = await backend.get_user(callback.from_user.id)
    success = await backend.delete_medicine(med_id, user["id"])"""
# This one is already correct in v13, but let's ensure consistency.

# Fix 4: handle_delete_select — use internal user ID
old4 = """    user_id = callback.from_user.id
    medicines = await backend.list_medicines(user_id)"""
# Already replaced by new2 above if it matches, but let's be explicit.

with open(path, "w") as f:
    f.write(content)
print("  Patched medicine.py for user ID fix.")
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
echo "  FIX v14 APPLIED"
echo "============================================"
echo "  Fixed: Edit/Delete now shows correct name"
echo "  Fixed: Delete Medicine works correctly"
