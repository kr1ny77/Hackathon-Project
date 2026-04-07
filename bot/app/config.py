"""Bot configuration."""

from pydantic_settings import BaseSettings
from functools import lru_cache


class BotSettings(BaseSettings):
    """Bot-specific settings."""

    TELEGRAM_BOT_TOKEN: str = ""
    BACKEND_URL: str = "http://backend:8000/api"

    # Reminder polling interval in seconds (how often to check for due reminders)
    REMINDER_CHECK_INTERVAL: int = 30

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8", "extra": "ignore"}


@lru_cache
def get_bot_settings() -> BotSettings:
    """Return cached bot settings."""
    return BotSettings()
