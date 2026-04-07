"""Application configuration loaded from environment variables."""

from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    """Core application settings."""

    # Database
    POSTGRES_USER: str = "medreminder"
    POSTGRES_PASSWORD: str = "medreminder_pass"
    POSTGRES_DB: str = "medreminder"
    POSTGRES_HOST: str = "db"
    POSTGRES_PORT: int = 5432

    # Backend API
    BACKEND_HOST: str = "0.0.0.0"
    BACKEND_PORT: int = 8000

    # Telegram Bot
    TELEGRAM_BOT_TOKEN: str = ""

    @property
    def database_url(self) -> str:
        """Build async SQLAlchemy database URL."""
        return (
            f"postgresql+asyncpg://{self.POSTGRES_USER}:{self.POSTGRES_PASSWORD}"
            f"@{self.POSTGRES_HOST}:{self.POSTGRES_PORT}/{self.POSTGRES_DB}"
        )

    @property
    def sync_database_url(self) -> str:
        """Build synchronous database URL (for Alembic migrations)."""
        return (
            f"postgresql://{self.POSTGRES_USER}:{self.POSTGRES_PASSWORD}"
            f"@{self.POSTGRES_HOST}:{self.POSTGRES_PORT}/{self.POSTGRES_DB}"
        )

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8", "extra": "ignore"}


@lru_cache
def get_settings() -> Settings:
    """Return cached settings instance."""
    return Settings()
