"""Database initialization — creates tables using async engine."""

import asyncio
from sqlalchemy.ext.asyncio import create_async_engine
from app.core.config import get_settings
from app.models.models import Base


async def init_db():
    """Create all tables if they don't exist."""
    settings = get_settings()
    engine = create_async_engine(settings.database_url)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    await engine.dispose()
    print("Database tables created successfully")


if __name__ == "__main__":
    asyncio.run(init_db())
