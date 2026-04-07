"""Pydantic schemas for API request/response validation."""

from datetime import datetime, time, date
from typing import Optional
from pydantic import BaseModel
from app.models.models import IntakeStatus


# --- User Schemas ---

class UserCreate(BaseModel):
    telegram_id: int
    username: Optional[str] = None
    first_name: Optional[str] = None


class UserResponse(BaseModel):
    id: int
    telegram_id: int
    username: Optional[str]
    first_name: Optional[str]
    registered_at: datetime

    model_config = {"from_attributes": True}


# --- Medicine Schemas ---

class MedicineCreate(BaseModel):
    name: str
    dosage: str


class MedicineResponse(BaseModel):
    id: int
    user_id: int
    name: str
    dosage: str
    created_at: datetime

    model_config = {"from_attributes": True}


class MedicineUpdate(BaseModel):
    name: Optional[str] = None
    dosage: Optional[str] = None


# --- Reminder Schedule Schemas ---

class ReminderScheduleCreate(BaseModel):
    medicine_id: int
    reminder_time: time  # HH:MM format


class ReminderScheduleResponse(BaseModel):
    id: int
    medicine_id: int
    reminder_time: time
    is_active: bool

    model_config = {"from_attributes": True}


# --- Intake History Schemas ---

class IntakeHistoryResponse(BaseModel):
    id: int
    user_id: int
    schedule_id: int
    medicine_name: str
    scheduled_time: datetime
    status: IntakeStatus
    responded_at: Optional[datetime] = None

    model_config = {"from_attributes": True}


class IntakeRecord(BaseModel):
    """For recording a user's response to a reminder."""
    intake_id: int
    status: IntakeStatus  # "taken" or "missed"


# --- Combined Schemas for Bot Convenience ---

class MedicineWithSchedules(BaseModel):
    """Medicine with its reminder times."""
    medicine: MedicineResponse
    schedules: list[ReminderScheduleResponse]


class TodayScheduleItem(BaseModel):
    """A single item in today's schedule."""
    intake_id: int
    medicine_name: str
    dosage: str
    scheduled_time: datetime
    status: IntakeStatus


class TodayScheduleResponse(BaseModel):
    date: date
    items: list[TodayScheduleItem]


class PendingIntakeCreate(BaseModel):
    """For creating a pending intake when a reminder fires."""
    user_id: int
    schedule_id: int
    medicine_name: str
    scheduled_time: datetime
