"""Initial schema - create all tables

Revision ID: 001
Revises:
Create Date: 2025-01-01

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

# revision identifiers
revision: str = "001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Enum type for intake status
    intake_status = sa.Enum("pending", "taken", "missed", name="intakestatus")
    intake_status.create(op.get_bind())

    # Users table
    op.create_table(
        "users",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("telegram_id", sa.BigInteger(), nullable=False, unique=True),
        sa.Column("username", sa.String(100), nullable=True),
        sa.Column("first_name", sa.String(100), nullable=True),
        sa.Column("registered_at", sa.DateTime(), server_default=sa.func.now()),
    )
    op.create_index("ix_users_telegram_id", "users", ["telegram_id"])

    # Medicines table
    op.create_table(
        "medicines",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("dosage", sa.String(100), nullable=False),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.now()),
    )
    op.create_index("ix_medicines_user_id", "medicines", ["user_id"])

    # Reminder schedules table
    op.create_table(
        "reminder_schedules",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("medicine_id", sa.Integer(), sa.ForeignKey("medicines.id"), nullable=False),
        sa.Column("reminder_time", sa.Time(), nullable=False),
        sa.Column("is_active", sa.Boolean(), server_default="true"),
    )
    op.create_index("ix_reminder_schedules_medicine_id", "reminder_schedules", ["medicine_id"])

    # Intake history table
    op.create_table(
        "intake_history",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("schedule_id", sa.Integer(), sa.ForeignKey("reminder_schedules.id"), nullable=False),
        sa.Column("medicine_name", sa.String(200), nullable=False),
        sa.Column("scheduled_time", sa.DateTime(), nullable=False),
        sa.Column("status", intake_status, server_default="pending"),
        sa.Column("responded_at", sa.DateTime(), nullable=True),
    )
    op.create_index("ix_intake_history_user_id", "intake_history", ["user_id"])
    op.create_index("ix_intake_history_schedule_id", "intake_history", ["schedule_id"])


def downgrade() -> None:
    op.drop_table("intake_history")
    op.drop_table("reminder_schedules")
    op.drop_table("medicines")
    op.drop_table("users")
    op.execute("DROP TYPE intakestatus")
