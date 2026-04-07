"""HTTP client for communicating with the backend API."""

import logging
from typing import Optional

import httpx

from app.config import get_bot_settings

logger = logging.getLogger(__name__)


class BackendClient:
    """Async HTTP client for the backend API."""

    def __init__(self):
        self.settings = get_bot_settings()
        self.base_url = self.settings.BACKEND_URL.rstrip("/")
        self._client: Optional[httpx.AsyncClient] = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(base_url=self.base_url, timeout=10.0)
        return self._client

    async def close(self):
        if self._client and not self._client.is_closed:
            await self._client.aclose()

    # --- User API ---

    async def register_user(self, telegram_id: int, username: str = None, first_name: str = None) -> dict:
        """Register or get existing user."""
        client = await self._get_client()
        resp = await client.post("/users", json={
            "telegram_id": telegram_id,
            "username": username,
            "first_name": first_name,
        })
        resp.raise_for_status()
        return resp.json()

    async def get_user(self, telegram_id: int) -> Optional[dict]:
        """Get user by Telegram ID."""
        client = await self._get_client()
        resp = await client.get(f"/users/telegram/{telegram_id}")
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        return resp.json()

    # --- Medicine API ---

    async def add_medicine(self, user_id: int, name: str, dosage: str) -> dict:
        """Add a new medicine."""
        client = await self._get_client()
        resp = await client.post(f"/medicines?user_id={user_id}", json={
            "name": name,
            "dosage": dosage,
        })
        resp.raise_for_status()
        return resp.json()

    async def list_medicines(self, user_id: int) -> list[dict]:
        """List all medicines for a user."""
        client = await self._get_client()
        resp = await client.get(f"/medicines/user/{user_id}")
        resp.raise_for_status()
        return resp.json()

    async def update_medicine(self, medicine_id: int, user_id: int, name: str = None, dosage: str = None) -> dict:
        """Update medicine."""
        client = await self._get_client()
        payload = {}
        if name:
            payload["name"] = name
        if dosage:
            payload["dosage"] = dosage
        resp = await client.patch(f"/medicines/{medicine_id}?user_id={user_id}", json=payload)
        resp.raise_for_status()
        return resp.json()

    async def delete_medicine(self, medicine_id: int, user_id: int) -> bool:
        """Delete a medicine."""
        client = await self._get_client()
        resp = await client.delete(f"/medicines/{medicine_id}?user_id={user_id}")
        if resp.status_code == 404:
            return False
        resp.raise_for_status()
        return True

    async def get_medicine(self, medicine_id: int, user_id: int) -> Optional[dict]:
        """Get medicine with schedules."""
        client = await self._get_client()
        resp = await client.get(f"/medicines/{medicine_id}?user_id={user_id}")
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        return resp.json()

    # --- Schedule API ---

    async def add_schedule(self, medicine_id: int, reminder_time: str) -> dict:
        """Add a reminder schedule (reminder_time in HH:MM format)."""
        client = await self._get_client()
        resp = await client.post("/schedules", json={
            "medicine_id": medicine_id,
            "reminder_time": reminder_time,
        })
        resp.raise_for_status()
        return resp.json()

    async def list_schedules(self, medicine_id: int) -> list[dict]:
        """List schedules for a medicine."""
        client = await self._get_client()
        resp = await client.get(f"/schedules/medicine/{medicine_id}")
        resp.raise_for_status()
        return resp.json()

    async def delete_schedule(self, schedule_id: int, user_id: int) -> bool:
        """Delete a schedule."""
        client = await self._get_client()
        resp = await client.delete(f"/schedules/{schedule_id}?user_id={user_id}")
        if resp.status_code == 404:
            return False
        resp.raise_for_status()
        return True

    async def get_active_schedules(self, hour: int, minute: int) -> list[dict]:
        """Get active schedules for a specific time."""
        client = await self._get_client()
        resp = await client.get(f"/schedules/active/{hour}/{minute}")
        resp.raise_for_status()
        return resp.json()

    async def get_active_schedules_with_details(self, hour: int, minute: int) -> list[dict]:
        """Get active schedules with full medicine+user info."""
        client = await self._get_client()
        resp = await client.get(f"/schedules/active-details/{hour}/{minute}")
        resp.raise_for_status()
        return resp.json()

    # --- Intake API ---

    async def record_intake(self, intake_id: int, status: str) -> dict:
        """Record taken/missed status."""
        client = await self._get_client()
        resp = await client.post("/intakes", json={
            "intake_id": intake_id,
            "status": status,
        })
        resp.raise_for_status()
        return resp.json()

    async def get_today_intakes(self, user_id: int) -> dict:
        """Get today's intakes for a user."""
        client = await self._get_client()
        resp = await client.get(f"/intakes/today/{user_id}")
        resp.raise_for_status()
        return resp.json()

    async def get_intake_history(self, user_id: int, limit: int = 30) -> list[dict]:
        """Get intake history for a user."""
        client = await self._get_client()
        resp = await client.get(f"/intakes/user/{user_id}?limit={limit}")
        resp.raise_for_status()
        return resp.json()

    async def create_pending_intake(self, user_id: int, schedule_id: int, medicine_name: str, scheduled_time: str) -> Optional[dict]:
        """Create a pending intake record when a reminder fires."""
        client = await self._get_client()
        # We need to use the schedule endpoint to get medicine info, then create intake
        # Instead, let's create via a direct approach using the schedule info
        # The backend needs to create this from the scheduler side
        # Let's use a simpler approach: the bot creates intake via a dedicated endpoint
        # For now, we'll create intake records via the backend when reminders fire
        # We'll add a new endpoint for this
        resp = await client.post("/intakes/pending", json={
            "user_id": user_id,
            "schedule_id": schedule_id,
            "medicine_name": medicine_name,
            "scheduled_time": scheduled_time,
        })
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        return resp.json()
