"""Telegram bot entry point."""

import asyncio
import logging

from aiogram import Bot, Dispatcher
from aiogram.fsm.storage.memory import MemoryStorage

from app.config import get_bot_settings
from app.handlers.router import router
from app.services.scheduler import ReminderSchedulerV2

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


async def main():
    """Main bot entry point."""
    settings = get_bot_settings()

    if not settings.TELEGRAM_BOT_TOKEN:
        logger.error("TELEGRAM_BOT_TOKEN is not set!")
        return

    # Initialize bot and dispatcher
    bot = Bot(token=settings.TELEGRAM_BOT_TOKEN)
    dp = Dispatcher(storage=MemoryStorage())

    # Include router
    dp.include_router(router)

    # Initialize reminder scheduler
    scheduler = ReminderSchedulerV2(bot)

    try:
        # Start scheduler
        await scheduler.start()

        # Start polling
        logger.info("Bot started in polling mode")
        await bot.delete_webhook(drop_pending_updates=True)
        await dp.start_polling(bot)
    except asyncio.CancelledError:
        logger.info("Bot shutting down...")
    finally:
        await scheduler.stop()
        await bot.session.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        logger.info("Bot stopped")
