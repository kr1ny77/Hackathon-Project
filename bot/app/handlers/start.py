"""Handler for /start command."""

import logging

from aiogram.fsm.context import FSMContext
from aiogram.types import Message

from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)


async def cmd_start(message: Message, state: FSMContext, backend: BackendClient):
    """Handle /start command - register user."""
    await state.clear()

    existing = await backend.get_user(message.from_user.id)

    if existing:
        welcome = (
            f"👋 Welcome back, {existing.get('first_name', 'User')}!\n\n"
            "Your medicines are ready. Use the commands below to manage them.\n\n"
            "Type /help to see all available commands."
        )
        await message.answer(welcome)
        return

    user_data = await backend.register_user(
        telegram_id=message.from_user.id,
        username=message.from_user.username,
        first_name=message.from_user.first_name,
    )

    welcome = (
        f"👋 Welcome, {message.from_user.first_name or 'User'}!\n\n"
        "I'm your <b>Medicine Reminder</b> bot. I'll help you remember to take your medicines on time.\n\n"
        "📌 <b>Quick start:</b>\n"
        "1️⃣ Use /add to add your first medicine\n"
        "2️⃣ Use /schedule to set reminder times\n"
        "3️⃣ I'll remind you when it's time!\n\n"
        "Type /help to see all available commands."
    )
    await message.answer(welcome, parse_mode="HTML")
    logger.info(f"New user registered: {message.from_user.id}")
