"""Handlers for reminder schedule management."""

import re
import logging

from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import Message, CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder

from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)


class ScheduleState(StatesGroup):
    selecting_medicine = State()
    waiting_for_time = State()


async def cmd_schedule(message: Message, state: FSMContext, backend: BackendClient):
    """Start the add schedule flow."""
    await state.clear()

    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("⚠️ Please register first with /start")
        return

    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        await message.answer("📋 You don't have any medicines yet. Use /add first.")
        return

    builder = InlineKeyboardBuilder()
    for med in medicines:
        builder.button(text=f"💊 {med['name']}", callback_data=f"sched:add:{med['id']}")
    builder.adjust(1)

    await state.set_state(ScheduleState.selecting_medicine)
    await state.update_data(user_id=user["id"])
    await message.answer("Select the medicine to set a reminder for:", reply_markup=builder.as_markup())


async def handle_medicine_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    """Handle medicine selection for scheduling."""
    medicine_id = int(callback.data.split(":")[2])
    await state.update_data(medicine_id=medicine_id)

    await state.set_state(ScheduleState.waiting_for_time)
    await callback.message.edit_text(
        "⏰ Enter the reminder time in <b>HH:MM</b> format (24-hour).\n"
        "<i>Examples: 08:00, 14:30, 21:00</i>\n\n"
        "💡 You can add multiple reminders per medicine."
    )
    await callback.answer()


async def handle_time_input(message: Message, state: FSMContext, backend: BackendClient):
    """Handle time input, validate, and create schedule."""
    time_str = message.text.strip()

    # Validate HH:MM format
    if not re.match(r"^([01]?\d|2[0-3]):[0-5]\d$", time_str):
        await message.answer(
            "❌ Invalid format. Please enter time as <b>HH:MM</b> (24-hour).\n"
            "<i>Examples: 08:00, 14:30, 21:00</i>"
        )
        return

    data = await state.get_data()
    medicine_id = data["medicine_id"]

    # Get medicine name for confirmation
    med_info = await backend.get_medicine(medicine_id, data["user_id"])
    if not med_info:
        await message.answer("❌ Medicine not found.")
        await state.clear()
        return

    schedule = await backend.add_schedule(medicine_id, time_str)

    await state.clear()
    await message.answer(
        f"✅ <b>Reminder set!</b>\n\n"
        f"💊 {med_info['medicine']['name']}\n"
        f"⏰ Time: {time_str}\n\n"
        "I'll remind you at this time every day.\n"
        "Use /schedule to add another reminder time."
    )
    logger.info(f"Schedule created: medicine {medicine_id} at {time_str}")


async def cmd_today_schedule(message: Message, backend: BackendClient):
    """Show today's schedule for the user."""
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("⚠️ Please register first with /start")
        return

    try:
        today_data = await backend.get_today_intakes(user["id"])
    except Exception:
        await message.answer("📋 No scheduled reminders for today.")
        return

    items = today_data.get("items", [])
    if not items:
        await message.answer(
            "📅 <b>Today's Schedule</b>\n\n"
            "No medicines scheduled for today. Add medicines and reminder times to get started!"
        )
        return

    text = "📅 <b>Today's Schedule</b>\n\n"
    for item in items:
        time_str = item["scheduled_time"][11:16]  # Extract HH:MM from datetime
        status_emoji = {
            "pending": "⏳",
            "taken": "✅",
            "missed": "❌",
        }.get(item["status"], "❓")

        text += f"{status_emoji} <b>{time_str}</b> - {item['medicine_name']} ({item['dosage']})\n"
        text += f"   Status: {item['status'].upper()}\n\n"

    await message.answer(text)


async def cb_schedule_action(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    """Route schedule callback queries."""
    parts = callback.data.split(":")
    action = parts[1] if len(parts) > 1 else ""

    if action == "add":
        await handle_medicine_select(callback, state, backend)


async def handle_time_input_handler(message: Message, state: FSMContext, backend: BackendClient):
    """Handler for time input in schedule flow - exported for router registration."""
    await handle_time_input(message, state, backend)
