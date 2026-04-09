#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v17 — Scheduler deduplication & Menu after Taken ==="

python3 << 'PYEOF'
import os

# 1. Fix scheduler.py to use stable scheduled_time for deduplication
path = "/opt/medicine-reminder/bot/app/services/scheduler.py"
with open(path) as f:
    content = f.read()

# Replace the block that creates intakes
old_block = """            st = now.strftime("%Y-%m-%dT%H:%M:%S")
            try:
                intake = await self.backend.create_pending_intake(user_id=primary["user_id"], schedule_id=primary["schedule_id"], medicine_name=med_name, scheduled_time=st)
                if intake:
                    self._sent.add(intake["id"])
                    await self._send(intake, tid, med_name, count)"""

new_block = """            # Use the scheduled reminder time, not current time, so duplicates are caught
            reminder_time = primary.get("reminder_time", "00:00:00")[:8]
            st = now.strftime("%Y-%m-%d") + "T" + reminder_time
            try:
                intake = await self.backend.create_pending_intake(user_id=primary["user_id"], schedule_id=primary["schedule_id"], medicine_name=med_name, scheduled_time=st)
                if intake and intake["id"] not in self._sent:
                    self._sent.add(intake["id"])
                    await self._send(intake, tid, med_name, count)"""

if old_block in content:
    content = content.replace(old_block, new_block)
    with open(path, "w") as f:
        f.write(content)
    print("  Patched scheduler.py to use reminder_time for deduplication.")
else:
    print("  WARNING: Scheduler pattern not found. Manual check required.")

# 2. Fix intake.py to show menu after "Taken"
path = "/opt/medicine-reminder/bot/app/handlers/intake.py"
with open(path) as f:
    content = f.read()

old_taken = """    await callback.message.edit_text("Great! Recorded as taken.\\nMedicine: {}\\nTime: {}".format(result.get("medicine_name", "Unknown"), now.strftime("%H:%M")))"""
new_taken = """    from app.handlers.start import build_main_menu
    await callback.message.edit_text("Great! Recorded as taken.\\nMedicine: {}\\nTime: {}".format(result.get("medicine_name", "Unknown"), now.strftime("%H:%M")), reply_markup=build_main_menu())"""

if old_taken in content:
    content = content.replace(old_taken, new_taken)
    with open(path, "w") as f:
        f.write(content)
    print("  Patched intake.py to show menu after 'Taken'.")
else:
    print("  WARNING: Intake pattern not found. Manual check required.")

# 3. Ensure medicine.py has the delete fix
path = "/opt/medicine-reminder/bot/app/handlers/medicine.py"
with open(path) as f:
    content = f.read()

# Fix delete parsing
if 'med_id = int(callback.data.split(":", 3)[3])' in content:
    content = content.replace('med_id = int(callback.data.split(":", 3)[3])', 'med_id = int(callback.data.split(":", 2)[2])')
    with open(path, "w") as f:
        f.write(content)
    print("  Patched medicine.py delete callback.")

# Fix user ID in edit/delete
if 'user_id = callback.from_user.id\n    medicines = await backend.list_medicines(user_id)' in content:
    content = content.replace(
        'user_id = callback.from_user.id\n    medicines = await backend.list_medicines(user_id)',
        'user = await backend.get_user(callback.from_user.id)\n    medicines = await backend.list_medicines(user["id"])'
    )
    with open(path, "w") as f:
        f.write(content)
    print("  Patched medicine.py user ID fix.")
PYEOF

echo "=== Copying to container ==="
docker cp bot/app/services/scheduler.py medreminder-bot:/app/app/services/scheduler.py
docker cp bot/app/handlers/intake.py medreminder-bot:/app/app/handlers/intake.py
docker cp bot/app/handlers/medicine.py medreminder-bot:/app/app/handlers/medicine.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
echo ""
echo "============================================"
echo "  FIX v17 APPLIED"
echo "============================================"
echo "  1. Scheduler uses reminder_time (stable) to prevent duplicates"
echo "  2. 'Taken' button shows main menu"
echo "  3. Delete medicine fix included"
