"""SQLAlchemy ORM models for the Medicine Reminder application."""

from datetime import datetime
from sqlalchemy import (
    Column, Integer, BigInteger, String, Boolean, DateTime, Time, ForeignKey, Enum as SAEnum
)
from sqlalchemy.orm import DeclarativeBase, relationship
import enum


class Base(DeclarativeBase):
    pass


class IntakeStatus(str, enum.Enum):
    PENDING = "pending"
    TAKEN = "taken"
    MISSED = "missed"


class User(Base):
    """Represents a registered Telegram user."""
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    telegram_id = Column(BigInteger, unique=True, nullable=False, index=True)
    username = Column(String(100), nullable=True)
    first_name = Column(String(100), nullable=True)
    registered_at = Column(DateTime, default=datetime.utcnow)

    medicines = relationship("Medicine", back_populates="user", cascade="all, delete-orphan")
    intakes = relationship("IntakeHistory", back_populates="user", cascade="all, delete-orphan")


class Medicine(Base):
    """Represents a medicine registered by a user."""
    __tablename__ = "medicines"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    name = Column(String(200), nullable=False)
    dosage = Column(String(100), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    user = relationship("User", back_populates="medicines")
    schedules = relationship("ReminderSchedule", back_populates="medicine", cascade="all, delete-orphan")


class ReminderSchedule(Base):
    """Stores reminder times for a specific medicine."""
    __tablename__ = "reminder_schedules"

    id = Column(Integer, primary_key=True, autoincrement=True)
    medicine_id = Column(Integer, ForeignKey("medicines.id"), nullable=False, index=True)
    reminder_time = Column(Time, nullable=False)
    is_active = Column(Boolean, default=True)

    medicine = relationship("Medicine", back_populates="schedules")
    intakes = relationship("IntakeHistory", back_populates="schedule", cascade="all, delete-orphan")


class IntakeHistory(Base):
    """Records whether a user took or missed a specific scheduled dose."""
    __tablename__ = "intake_history"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    schedule_id = Column(Integer, ForeignKey("reminder_schedules.id"), nullable=False, index=True)
    medicine_name = Column(String(200), nullable=False)
    scheduled_time = Column(DateTime, nullable=False)
    status = Column(SAEnum(IntakeStatus, name="intakestatus"), default=IntakeStatus.PENDING)
    responded_at = Column(DateTime, nullable=True)

    user = relationship("User", back_populates="intakes")
    schedule = relationship("ReminderSchedule", back_populates="intakes")
