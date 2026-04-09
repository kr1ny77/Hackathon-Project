#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v19 — Add dosage to reminders (No brackets) ==="

# Overwrite scheduler.py with the corrected version
cat > bot/app/services/scheduler.py << 'SCHEDULER_EOF'
import asyncio, logging
from datetime import datetime, timezone, timedelta
from collections import defaultdict
from aiogram import Bot
from app.config import get_bot_settings
from app.services.backend_client import BackendClient
from app.handlers.intake import build_intake_keyboard

logger = logging.getLogger(__name__)
MOSCOW_TZ = timezone(timedelta(hours=3))

class ReminderScheduler:
    def __init__(self, bot: Bot):
        self.bot = bot
        self.settings = get_bot_settings()
        self.backend = BackendClient()
        self._task = None
        self._sent = set()

    async def start(self):
        logger.info("Reminder scheduler started (Moscow)")
        self._task = asyncio.create_task(self._run())

    async def stop(self):
        if self._task:
            self._task.cancel()
            try: await self._task
            except: pass
        await self.backend.close()
        logger.info("Reminder scheduler stopped")

    async def _run(self):
        while True:
            try: await self._check()
            except Exception as e: logger.error("Scheduler: {}".format(e))
            await asyncio.sleep(self.settings.REMINDER_CHECK_INTERVAL)

    async def _check(self):
        now = datetime.now(MOSCOW_TZ)
        hh, mm = now.hour, now.minute
        try: schedules = await self.backend.get_active_schedules_with_details(hh, mm)
        except Exception as e: logger.error("Schedules: {}".format(e)); schedules = []
        
        groups = defaultdict(list)
        for info in schedules:
            groups[(info["telegram_id"], info["medicine_name"])].append(info)
        
        for (tid, med_name), infos in groups.items():
            count = len(infos); primary = infos[0]
            reminder_time = primary.get("reminder_time", "00:00:00")[:8]
            st = now.strftime("%Y-%m-%d") + "T" + reminder_time
            dosage = primary.get("dosage", "")
            try:
                intake = await self.backend.create_pending_intake(user_id=primary["user_id"], schedule_id=primary["schedule_id"], medicine_name=med_name, scheduled_time=st)
                if intake and intake["id"] not in self._sent:
                    self._sent.add(intake["id"])
                    await self._send(intake, tid, med_name, dosage, count)
            except Exception as e: logger.error("New: {}".format(e))
        
        try: pending = await self.backend.get_pending_due()
        except Exception as e: logger.error("Pending: {}".format(e)); pending = []
        for intake in pending:
            if intake["id"] not in self._sent:
                try:
                    tid = await self._get_tid(intake["user_id"])
                    if tid:
                        self._sent.add(intake["id"])
                        await self._send(intake, tid, intake.get("medicine_name","Unknown"), "", 1)
                except Exception as e: logger.error("Resched: {}".format(e))

    async def _get_tid(self, uid):
        try:
            c = await self.backend._get_client()
            r = await c.get("/users/id/{}".format(uid))
            if r.status_code == 200: return r.json()["telegram_id"]
        except: pass
        return None

    async def _send(self, intake, tid, name, dosage, count):
        now = datetime.now(MOSCOW_TZ)
        qty = " x{}".format(count) if count > 1 else ""
        doz = " {}".format(dosage) if dosage else ""
        msg = "Medicine Reminder\n\nMedicine: {}{}\nDosage:{}\nTime: {}\n\nHave you taken your medicine?".format(name, qty, doz, now.strftime("%H:%M"))
        kb = build_intake_keyboard(intake["id"])
        await self.bot.send_message(chat_id=tid, text=msg, reply_markup=kb.as_markup())
        logger.info("Sent to {}: {}{} (#{})".format(tid, name, qty, intake["id"]))
SCHEDULER_EOF

echo "=== Copying to container ==="
docker cp bot/app/services/scheduler.py medreminder-bot:/app/app/services/scheduler.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
echo ""
echo "============================================"
echo "  FIX v19 APPLIED"
echo "============================================"
echo "  Reminders now show dosage WITHOUT brackets"
