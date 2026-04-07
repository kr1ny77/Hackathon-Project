"""Telegram bot handler registrations with state handling."""

from aiogram import Router, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import Message, CallbackQuery

from app.config import get_bot_settings
from app.services.backend_client import BackendClient
from app.handlers.medicine import (
    AddMedicineState, EditMedicineState, DeleteMedicineState,
    handle_medicine_name, handle_medicine_dosage, handle_edit_value,
)
from app.handlers.schedule import (
    ScheduleState, handle_time_input,
)
from app.handlers.start import cmd_start
from app.handlers.medicine import (
    cmd_add_medicine, cb_medicine_action,
    cmd_list_medicines, cmd_delete_medicine, cmd_edit_medicine,
)
from app.handlers.schedule import (
    cmd_schedule, cb_schedule_action, cmd_today_schedule,
)
from app.handlers.intake import (
    cb_intake_action, cmd_history, cmd_today,
)

router = Router()
settings = get_bot_settings()
backend = BackendClient()


# --- Start Command ---
@router.message(Command("start"))
async def handle_start(message: Message, state: FSMContext):
    await cmd_start(message, state, backend)


# --- Add Medicine Flow ---
@router.message(Command("add"))
async def handle_add_medicine(message: Message, state: FSMContext):
    await cmd_add_medicine(message, state, backend)


@router.message(AddMedicineState.waiting_for_name)
async def process_medicine_name(message: Message, state: FSMContext):
    await handle_medicine_name(message, state, backend)


@router.message(AddMedicineState.waiting_for_dosage)
async def process_medicine_dosage(message: Message, state: FSMContext):
    await handle_medicine_dosage(message, state, backend)


# --- List Medicines ---
@router.message(Command("medicines"))
async def handle_list_medicines(message: Message):
    await cmd_list_medicines(message, backend)


# --- Edit Medicine Flow ---
@router.message(Command("edit"))
async def handle_edit_medicine(message: Message, state: FSMContext):
    await cmd_edit_medicine(message, state, backend)


@router.message(EditMedicineState.waiting_for_value)
async def process_edit_value(message: Message, state: FSMContext):
    await handle_edit_value(message, state, backend)


# --- Delete Medicine Flow ---
@router.message(Command("delete"))
async def handle_delete_medicine(message: Message, state: FSMContext):
    await cmd_delete_medicine(message, state, backend)


# --- Schedule Flow ---
@router.message(Command("schedule"))
async def handle_schedule(message: Message, state: FSMContext):
    await cmd_schedule(message, state, backend)


@router.message(ScheduleState.waiting_for_time)
async def process_schedule_time(message: Message, state: FSMContext):
    await handle_time_input(message, state, backend)


# --- Today's Schedule ---
@router.message(Command("today"))
async def handle_today_schedule(message: Message):
    await cmd_today_schedule(message, backend)


# --- Intake History ---
@router.message(Command("history"))
async def handle_history_cmd(message: Message):
    await cmd_history(message, backend)


# --- Help ---
@router.message(Command("help"))
async def handle_help(message: Message):
    help_text = (
        "📋 <b>Medicine Reminder Bot - Help</b>\n\n"
        "<b>Commands:</b>\n"
        "/start - Register with the bot\n"
        "/add - Add a new medicine\n"
        "/medicines - List all your medicines\n"
        "/edit - Edit a medicine\n"
        "/delete - Delete a medicine\n"
        "/schedule - Add reminder time for a medicine\n"
        "/today - Show today's schedule\n"
        "/history - View intake history\n"
        "/help - Show this help message\n\n"
        "💡 <i>You'll receive reminders at your scheduled times.\n"
        "Use the Taken/Missed buttons to record your response.</i>"
    )
    await message.answer(help_text)


# --- Callback Query Handlers ---
@router.callback_query(F.data.startswith("med:"))
async def handle_medicine_callback(callback: CallbackQuery, state: FSMContext):
    await cb_medicine_action(callback, state, backend)


@router.callback_query(F.data.startswith("sched:"))
async def handle_schedule_callback(callback: CallbackQuery, state: FSMContext):
    await cb_schedule_action(callback, state, backend)


@router.callback_query(F.data.startswith("intake:"))
async def handle_intake_callback(callback: CallbackQuery):
    await cb_intake_action(callback, backend)
