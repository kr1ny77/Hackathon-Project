"""FastAPI application entry point."""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api.endpoints import router
from app.core.config import get_settings
from app.db.session import engine

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: startup and shutdown events."""
    logger.info("Starting Medicine Reminder Backend API...")
    # Verify DB connection
    try:
        async with engine.begin() as conn:
            await conn.run_sync(lambda _: None)  # Simple connection test
        logger.info("Database connection verified")
    except Exception as e:
        logger.error(f"Database connection failed: {e}")
    yield
    logger.info("Shutting down Medicine Reminder Backend API...")
    await engine.dispose()


settings = get_settings()

app = FastAPI(
    title="Medicine Reminder API",
    description="Backend API for the Medicine Reminder Telegram bot service",
    version="2.0.0",
    lifespan=lifespan,
)

# Register routes
app.include_router(router, prefix="/api")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "app.main:app",
        host=settings.BACKEND_HOST,
        port=settings.BACKEND_PORT,
        reload=True,
    )
