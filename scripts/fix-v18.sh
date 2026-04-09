#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v18 — Fix SyntaxError in intake.py ==="

cat > bot/app/handlers/intake.py << 'INTAKE_EOF'
import logging
from datetime import datetime, timezone, timedelta
from collections import Counter
from aiogram.types import CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient
from app.handlers.start import build_main_menu

logger = logging.getLogger(__name__)

async def cmd_today(message, backend):
    from app.handlers.schedule import cmd_today_schedule
    await cmd_today_schedule(message, backend)

async def cmd_history(message, backend):
    user = await backend.get_user(message.from_user.id)
    if not user: await message.answer("Please register first with /start"); return
    history = await backend.get_intake_history(user["id"], limit=30)
    if not history: await message.answer("No intake history yet."); return
    counts = Counter()
    for e in history:
        dt = e["scheduled_time"][:16].replace("T", " ")
        counts[(e["medicine_name"], dt)] = counts.get((e["medicine_name"], dt), 0) + 1
    text = "Intake History (last 30)\n\n"; seen = set()
    for e in history[:30]:
        dt = e["scheduled_time"][:16].replace("T", " ")
        key = (e["medicine_name"], dt)
        if key in seen: continue
        seen.add(key)
        emoji = {"pending":"pending","taken":"taken","missed":"missed"}.get(e["status"],"?")
        qty = " x{}".format(counts[key]) if counts[key] > 1 else ""
        text += "{} {} - {}{}\n".format(emoji, dt, e["medicine_name"], qty)
    await message.answer(text)

async def cb_intake_taken(callback: CallbackQuery, backend: BackendClient):
    intake_id = int(callback.data.split(":")[2])
    try:
        result = await backend.record_intake(intake_id, "taken")
        now = datetime.now(timezone(timedelta(hours=3)))
        await callback.message.edit_text(
            "Great! Recorded as taken.\nMedicine: {}\nTime: {}".format(
                result.get("medicine_name", "Unknown"), now.strftime("%H:%M")
            ),
            reply_markup=build_main_menu()
        )
    except Exception as e:
        logger.error("Taken: {}".format(e))
        await callback.answer("Error.", show_alert=True)
    await callback.answer()

async def cb_intake_reschedule(callback: CallbackQuery, backend: BackendClient):
    intake_id = int(callback.data.split(":")[2])
    try:
        result = await backend.reschedule_intake(intake_id)
        new_time = result["scheduled_time"][11:16]
        await callback.message.edit_text("Reminder set for {}.\nMedicine: {}".format(new_time, result.get("medicine_name", "Unknown")))
    except Exception as e:
        logger.error("Resched: {}".format(e))
        await callback.answer("Error.", show_alert=True)
    await callback.answer()

def build_intake_keyboard(intake_id: int) -> InlineKeyboardBuilder:
    b = InlineKeyboardBuilder()
    b.button(text="Taken", callback_data="intake:taken:{}".format(intake_id))
    b.button(text="Remind in 5 min", callback_data="intake:reschedule:{}".format(intake_id))
    b.adjust(2)
    return b
INTAKE_EOF

echo "=== Copying to container ==="
docker cp bot/app/handlers/intake.py medreminder-bot:/app/app/handlers/intake.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
echo ""
echo "============================================"
echo "  FIX v18 APPLIED"
echo "============================================"
echo "  1. intake.py fixed (SyntaxError resolved)"
echo "  2. Menu shows after 'Taken'"
