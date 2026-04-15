#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v34 — Intake history dosage fix (direct container write) ==="

# 1. Write services.py directly INTO backend container
docker exec medreminder-backend sh -c "cat > /app/app/services/services.py << 'SVCEOF'
from datetime import datetime, date, time
from typing import Optional
from sqlalchemy import select, and_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload
from app.models.models import User, Medicine, ReminderSchedule, IntakeHistory, IntakeStatus
from app.schemas.schemas import (UserCreate, MedicineCreate, MedicineUpdate, ReminderScheduleCreate,
    MedicineResponse, ReminderScheduleResponse, IntakeHistoryResponse, MedicineWithSchedules,
    TodayScheduleItem, TodayScheduleResponse)

async def get_or_create_user(db, data):
    r = await db.execute(select(User).where(User.telegram_id == data.telegram_id))
    u = r.scalar_one_or_none()
    if not u:
        u = User(telegram_id=data.telegram_id, username=data.username, first_name=data.first_name)
        db.add(u); await db.flush(); await db.refresh(u)
    return u

async def get_user_by_telegram_id(db, tid):
    r = await db.execute(select(User).where(User.telegram_id == tid))
    return r.scalar_one_or_none()

async def create_medicine(db, uid, data):
    m = Medicine(user_id=uid, name=data.name.strip(), dosage=data.dosage.strip())
    db.add(m); await db.flush(); await db.refresh(m); return m

async def get_user_medicines(db, uid):
    r = await db.execute(select(Medicine).where(Medicine.user_id == uid).order_by(Medicine.name))
    return list(r.scalars().all())

async def get_medicine_by_id(db, mid, uid):
    r = await db.execute(select(Medicine).where(and_(Medicine.id == mid, Medicine.user_id == uid)))
    return r.scalar_one_or_none()

async def update_medicine(db, m, data):
    if data.name: m.name = data.name.strip()
    if data.dosage: m.dosage = data.dosage.strip()
    await db.flush(); await db.refresh(m); return m

async def delete_medicine(db, m):
    await db.delete(m); await db.flush()

async def create_reminder_schedule(db, mid, rt):
    s = ReminderSchedule(medicine_id=mid, reminder_time=rt, is_active=True)
    db.add(s); await db.flush(); await db.refresh(s); return s

async def get_medicine_schedules(db, mid):
    r = await db.execute(select(ReminderSchedule).where(ReminderSchedule.medicine_id == mid).order_by(ReminderSchedule.reminder_time))
    return list(r.scalars().all())

async def get_active_schedules_for_time(db, tt):
    r = await db.execute(select(ReminderSchedule).where(and_(ReminderSchedule.reminder_time == tt, ReminderSchedule.is_active == True)).options(selectinload(ReminderSchedule.medicine).selectinload(Medicine.user)))
    return list(r.scalars().all())

async def get_active_schedules_with_details_for_time(db, tt):
    schedules = await get_active_schedules_for_time(db, tt)
    out = []
    for s in schedules:
        m = s.medicine; u = m.user
        out.append({'schedule_id': s.id, 'medicine_id': m.id, 'medicine_name': m.name, 'dosage': m.dosage, 'reminder_time': str(s.reminder_time), 'user_id': u.id, 'telegram_id': u.telegram_id})
    return out

async def delete_reminder_schedule(db, s):
    await db.delete(s); await db.flush()

async def create_pending_intake(db, uid, sid, mn, st):
    i = IntakeHistory(user_id=uid, schedule_id=sid, medicine_name=mn, scheduled_time=st, status=IntakeStatus.PENDING)
    db.add(i); await db.flush(); await db.refresh(i); return i

async def check_duplicate_intake(db, sid, st):
    r = await db.execute(select(IntakeHistory).where(and_(IntakeHistory.schedule_id == sid, IntakeHistory.scheduled_time == st)))
    return r.scalar_one_or_none()

async def update_intake_status(db, iid, status):
    r = await db.execute(select(IntakeHistory).where(IntakeHistory.id == iid))
    i = r.scalar_one_or_none()
    if i:
        i.status = status; i.responded_at = datetime.utcnow()
        await db.flush(); await db.refresh(i)
    return i

async def get_user_intake_history(db, uid, limit=30):
    r = await db.execute(
        select(IntakeHistory, Medicine.dosage)
        .outerjoin(ReminderSchedule, ReminderSchedule.id == IntakeHistory.schedule_id)
        .outerjoin(Medicine, Medicine.id == ReminderSchedule.medicine_id)
        .where(IntakeHistory.user_id == uid)
        .order_by(IntakeHistory.scheduled_time.desc())
        .limit(limit)
    )
    out = []
    for intake, dosage in r.all():
        st = intake.status
        sv = st.value if hasattr(st, 'value') else str(st)
        out.append({'id': intake.id, 'user_id': intake.user_id, 'schedule_id': intake.schedule_id,
            'medicine_name': intake.medicine_name, 'scheduled_time': intake.scheduled_time,
            'status': sv, 'responded_at': intake.responded_at, 'dosage': dosage or 'N/A'})
    return out

async def get_today_intakes(db, uid, today):
    sod = datetime(today.year, today.month, today.day, 0, 0, 0)
    eod = datetime(today.year, today.month, today.day, 23, 59, 59)
    r = await db.execute(select(IntakeHistory).where(and_(IntakeHistory.user_id == uid, IntakeHistory.scheduled_time >= sod, IntakeHistory.scheduled_time <= eod)).order_by(IntakeHistory.scheduled_time))
    return list(r.scalars().all())

async def get_pending_intake_for_schedule(db, sid):
    r = await db.execute(select(IntakeHistory).where(and_(IntakeHistory.schedule_id == sid, IntakeHistory.status == IntakeStatus.PENDING)).order_by(IntakeHistory.scheduled_time.desc()))
    return r.scalars().first()

async def get_medicine_with_schedules(db, mid, uid):
    m = await get_medicine_by_id(db, mid, uid)
    if not m: return None
    ss = await get_medicine_schedules(db, mid)
    return MedicineWithSchedules(medicine=MedicineResponse.model_validate(m), schedules=[ReminderScheduleResponse.model_validate(s) for s in ss])

async def get_today_schedule_response(db, uid, today):
    intakes = await get_today_intakes(db, uid, today)
    items = []
    for i in intakes:
        r = await db.execute(select(Medicine).join(ReminderSchedule, Medicine.id == ReminderSchedule.medicine_id).where(ReminderSchedule.id == i.schedule_id))
        m = r.scalar_one_or_none()
        d = m.dosage if m else 'Unknown'
        items.append(TodayScheduleItem(intake_id=i.id, medicine_name=i.medicine_name, dosage=d, scheduled_time=i.scheduled_time, status=i.status))
    return TodayScheduleResponse(date=today, items=items)
SVCEOF
"
echo "  services.py written into backend container"

# 2. Write intake.py directly INTO bot container
docker exec medreminder-bot sh -c "cat > /app/app/handlers/intake.py << 'INEOF'
import logging
from datetime import datetime, timezone, timedelta
from collections import Counter
from aiogram.types import CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder
from app.services.backend_client import BackendClient
from app.handlers.start import build_main_menu

logger = logging.getLogger(__name__)

async def cmd_today(message, backend):
    from app.handlers.schedule import cmd_today_schedule
    await cmd_today_schedule(message, backend)

async def cmd_history(message, backend):
    user = await backend.get_user(message.from_user.id)
    if not user: await message.answer('Please register first with /start'); return
    history = await backend.get_intake_history(user['id'], limit=30)
    if not history: await message.answer('No intake history yet.'); return
    counts = Counter()
    for e in history:
        dt = e['scheduled_time'][:16].replace('T', ' ')
        name = e.get('medicine_name', 'Unknown')
        dosage = e.get('dosage', 'N/A')
        key = (name, dosage, dt)
        counts[key] = counts.get(key, 0) + 1
    text = 'Intake History (last 30)\n\n'; seen = set()
    for e in history[:30]:
        dt = e['scheduled_time'][:16].replace('T', ' ')
        name = e.get('medicine_name', 'Unknown')
        dosage = e.get('dosage', 'N/A')
        key = (name, dosage, dt)
        if key in seen: continue
        seen.add(key)
        emo = {'pending':'pending','taken':'taken','missed':'missed'}.get(e.get('status',''),'?')
        qty = ' x{}'.format(counts[key]) if counts[key] > 1 else ''
        text += '{} {} - {} ({}){}\n'.format(emo, dt, name, dosage, qty)
    await message.answer(text)

async def cb_intake_taken(callback: CallbackQuery, backend: BackendClient):
    iid = int(callback.data.split(':')[2])
    try:
        r = await backend.record_intake(iid, 'taken')
        now = datetime.now(timezone(timedelta(hours=3)))
        await callback.message.edit_text('Great! Recorded as taken.\nMedicine: {}\nTime: {}'.format(r.get('medicine_name','Unknown'), now.strftime('%H:%M')), reply_markup=build_main_menu())
    except Exception as e:
        logger.error('Taken: {}'.format(e)); await callback.answer('Error.', show_alert=True)
    await callback.answer()

async def cb_intake_reschedule(callback: CallbackQuery, backend: BackendClient):
    iid = int(callback.data.split(':')[2])
    try:
        r = await backend.reschedule_intake(iid)
        nt = r['scheduled_time'][11:16]
        await callback.message.edit_text('Reminder set for {}.\nMedicine: {}'.format(nt, r.get('medicine_name','Unknown')))
    except Exception as e:
        logger.error('Resched: {}'.format(e)); await callback.answer('Error.', show_alert=True)
    await callback.answer()

def build_intake_keyboard(iid):
    b = InlineKeyboardBuilder()
    b.button(text='Taken', callback_data='intake:taken:{}'.format(iid))
    b.button(text='Remind in 5 min', callback_data='intake:reschedule:{}'.format(iid))
    b.adjust(2)
    return b
INEOF
"
echo "  intake.py written into bot container"

# 3. Restart both
echo ""
echo "=== Restarting backend and bot ==="
docker compose restart backend bot
sleep 8

echo ""
echo "=== Backend Logs ==="
docker compose logs --tail 3 backend
echo ""
echo "=== Bot Logs ==="
docker compose logs --tail 3 bot
echo ""
echo "=== Test: click 'Intake history' button in Telegram ==="
echo "=== Should show: taken 2026-04-09 14:54 - Aspirin (1 tablet) ==="
echo ""
echo "============================================"
echo "  FIX v34 APPLIED"
echo "============================================"
