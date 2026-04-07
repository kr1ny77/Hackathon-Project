"""Reminder scheduler - periodically checks for due reminders and sends them."""

import asyncio
import logging
from datetime import datetime, timedelta

from aiogram import Bot
from aiogram.utils.keyboard import InlineKeyboardBuilder

from app.config import get_bot_settings
from app.services.backend_client import BackendClient
from app.handlers.intake import build_intake_keyboard

logger = logging.getLogger(__name__)


class ReminderScheduler:
    """
    Polling-based reminder scheduler.

    Every REMINDER_CHECK_INTERVAL seconds, checks the backend for active
    schedules matching the current time, creates intake records, and sends
    reminder messages to users via Telegram.

    Uses polling (not webhook) because:
    - Simpler to set up and debug
    - Works behind NAT/firewalls
    - Sufficient for a student project
    - The check interval is small enough (30s) to be responsive
    """

    def __init__(self, bot: Bot):
        self.bot = bot
        self.settings = get_bot_settings()
        self.backend = BackendClient()
        self._task: asyncio.Task | None = None
        self._last_check: set = set()  # Track sent reminders to avoid duplicates

    async def start(self):
        """Start the reminder scheduler loop."""
        logger.info("Reminder scheduler started")
        self._task = asyncio.create_task(self._run())

    async def stop(self):
        """Stop the reminder scheduler."""
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            logger.info("Reminder scheduler stopped")
        await self.backend.close()

    async def _run(self):
        """Main loop: check for due reminders periodically."""
        while True:
            try:
                await self._check_reminders()
            except Exception as e:
                logger.error(f"Error checking reminders: {e}")

            # Clear old entries from last_check every hour
            now = datetime.utcnow()
            if now.minute == 0 and now.second < 30:
                self._last_check.clear()

            await asyncio.sleep(self.settings.REMINDER_CHECK_INTERVAL)

    async def _check_reminders(self):
        """Check for reminders at the current time and send them."""
        now = datetime.utcnow()
        current_hour = now.hour
        current_minute = now.minute

        # Create a key to avoid duplicate checks for the same minute
        check_key = f"{current_hour:02d}:{current_minute:02d}"
        if check_key in self._last_check:
            return
        self._last_check.add(check_key)

        # Get active schedules for this time
        schedules = await self.backend.get_active_schedules(current_hour, current_minute)

        if not schedules:
            return

        logger.info(f"Found {len(schedules)} active schedules for {check_key}")

        for schedule in schedules:
            try:
                await self._send_reminder(schedule, now)
            except Exception as e:
                medicine_name = schedule.get("medicine_id", "unknown")
                logger.error(f"Error sending reminder for schedule {schedule['id']}: {e}")

    async def _send_reminder(self, schedule: dict, now: datetime):
        """Send a reminder message to the user."""
        schedule_id = schedule["id"]
        medicine_id = schedule["medicine_id"]

        # Get medicine details (need user_id for the ownership check)
        # We need to find the user - get medicine info from backend
        # The schedule endpoint doesn't include medicine details, so we need another approach
        # Let's get all medicines for all users and find the matching one
        # Better: the backend should return medicine info with the schedule
        # For now, let's use a direct approach

        # Get medicine with schedules to find user info
        # We need to iterate through users - this is not ideal
        # Let's improve the backend endpoint to include medicine info

        # Simpler approach: create pending intake via backend with what we know
        # We need: user_id, medicine_name
        # Let's fetch this from a dedicated endpoint

        # For now, let's use the backend's medicine endpoint
        # We need to know the user_id - let's get it from the schedule
        # The schedule has medicine_id, we can query the backend

        # Actually, let's add a helper endpoint or improve existing one
        # For simplicity, let's just query via medicine_id with a known user
        # This is a design issue - let's fix it by having the backend return
        # more info with the schedule

        # WORKAROUND: We'll need to call the backend differently
        # Let's create a pending intake with minimal info and let the backend handle it
        # The backend needs user_id, so we need to get it somehow

        # Simplest fix: add an endpoint that returns schedule with full medicine+user info
        # For now, let's assume the backend returns what we need in the schedule response
        # We'll need to modify the endpoint

        # TODO: Improve backend to return medicine name + user telegram_id with schedules
        # For now, skip this schedule if we can't get the info
        logger.warning(f"Skipping schedule {schedule_id} - need improved backend endpoint")
        return


class ReminderSchedulerV2(ReminderScheduler):
    """
    Improved scheduler that fetches full medicine+user info.

    This version calls a dedicated backend endpoint that returns schedules
    with medicine names and user telegram IDs.
    """

    async def _check_reminders(self):
        """Check for due reminders with full context."""
        now = datetime.utcnow()
        current_hour = now.hour
        current_minute = now.minute

        check_key = f"{current_hour:02d}:{current_minute:02d}"
        if check_key in self._last_check:
            return
        self._last_check.add(check_key)

        # Use the improved endpoint
        schedules = await self.backend.get_active_schedules_with_details(current_hour, current_minute)

        if not schedules:
            return

        logger.info(f"Found {len(schedules)} active schedules for {check_key}")

        for schedule in schedules:
            try:
                await self._send_reminder_v2(schedule, now)
            except Exception as e:
                logger.error(f"Error sending reminder for schedule {schedule.get('schedule_id')}: {e}")

    async def _send_reminder_v2(self, info: dict, now: datetime):
        """Send reminder with full medicine and user info."""
        telegram_id = info["telegram_id"]
        medicine_name = info["medicine_name"]
        dosage = info["dosage"]
        schedule_id = info["schedule_id"]
        user_id = info["user_id"]

        # Create pending intake record
        scheduled_time = now.strftime("%Y-%m-%dT%H:%M:%S")
        intake = await self.backend.create_pending_intake(
            user_id=user_id,
            schedule_id=schedule_id,
            medicine_name=medicine_name,
            scheduled_time=scheduled_time,
        )

        if not intake:
            logger.warning(f"Duplicate intake skipped for schedule {schedule_id}")
            return

        intake_id = intake["id"]

        # Build message
        message = (
            f"⏰ <b>Medicine Reminder</b>\n\n"
            f"💊 <b>{medicine_name}</b>\n"
            f"📏 Dosage: {dosage}\n"
            f"🕐 Time: {now.strftime('%H:%M')}\n\n"
            f"Have you taken your medicine?"
        )

        # Send with inline buttons
        keyboard = build_intake_keyboard(intake_id)
        await self.bot.send_message(
            chat_id=telegram_id,
            text=message,
            reply_markup=keyboard.as_markup(),
            parse_mode="HTML",
        )

        logger.info(f"Reminder sent to {telegram_id} for {medicine_name} (intake #{intake_id})")
