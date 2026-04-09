"""Handlers for intake history and reminder responses."""

import logging
from datetime import datetime

from aiogram.types import Message, CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder

from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)


async def cmd_today(message: Message, backend: BackendClient):
    """Show today's schedule (alias for /today)."""
    from app.handlers.schedule import cmd_today_schedule
    await cmd_today_schedule(message, backend)


async def cmd_history(message: Message, backend: BackendClient):
    """Show recent intake history."""
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("⚠️ Please register first with /start")
        return

    history = await backend.get_intake_history(user["id"], limit=20)

    if not history:
        await message.answer("📋 No intake history yet. Your records will appear here after you respond to reminders.")
        return

    text = "📊 <b>Intake History</b> (last 20)\n\n"
    for entry in history[:20]:
        status_emoji = {
            "pending": "⏳",
            "taken": "✅",
            "missed": "❌",
        }.get(entry["status"], "❓")

        dt = entry["scheduled_time"][:16].replace("T", " ")
        text += f"{status_emoji} <b>{dt}</b> - {entry['medicine_name']}\n"

    await message.answer(text, parse_mode="HTML")


async def cb_intake_action(callback: CallbackQuery, backend: BackendClient):
    """Handle Taken/Missed button presses from reminders."""
    parts = callback.data.split(":")
    if len(parts) < 3:
        await callback.answer("Invalid action", show_alert=True)
        return

    action = parts[1]  # "taken" or "missed"
    intake_id = int(parts[2])

    try:
        result = await backend.record_intake(intake_id, action)
        status_emoji = "✅" if action == "taken" else "❌"
        status_text = "taken" if action == "taken" else "missed"

        await callback.message.edit_text(
            f"{status_emoji} <b>Recorded!</b>\n\n"
            f"Medicine: {result.get('medicine_name', 'Unknown')}\n"
            f"Status: {status_text.upper()}\n"
            f"Time: {datetime.utcnow().strftime('%H:%M')}\n\n"
            f"{'Keep it up!' if action == 'taken' else 'Try to take your medicine on time next time.'}",
            parse_mode="HTML",
        )
        logger.info(f"Intake {intake_id} recorded as {action}")
    except Exception as e:
        logger.error(f"Error recording intake {intake_id}: {e}")
        await callback.answer("Could not record response. Try again.", show_alert=True)

    await callback.answer()


def build_intake_keyboard(intake_id: int) -> InlineKeyboardBuilder:
    """Build inline keyboard for Taken/Missed buttons."""
    builder = InlineKeyboardBuilder()
    builder.button(text="✅ Taken", callback_data=f"intake:taken:{intake_id}")
    builder.button(text="❌ Missed", callback_data=f"intake:missed:{intake_id}")
    builder.adjust(2)
    return builder
