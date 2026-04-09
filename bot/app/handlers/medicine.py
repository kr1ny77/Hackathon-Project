"""Handlers for medicine management: add, list, edit, delete."""

import logging

from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import Message, CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder

from app.services.backend_client import BackendClient

logger = logging.getLogger(__name__)


class AddMedicineState(StatesGroup):
    waiting_for_name = State()
    waiting_for_dosage = State()


class EditMedicineState(StatesGroup):
    selecting_medicine = State()
    selecting_field = State()
    waiting_for_value = State()


class DeleteMedicineState(StatesGroup):
    selecting_medicine = State()
    confirming = State()


# --- Add Medicine ---

async def cmd_add_medicine(message: Message, state: FSMContext, backend: BackendClient):
    """Start the add medicine flow."""
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("⚠️ Please register first with /start")
        return

    await state.set_state(AddMedicineState.waiting_for_name)
    await message.answer(
        "💊 <b>Add Medicine</b>\n\n"
        "What is the <b>name</b> of the medicine?\n"
        "(e.g., Aspirin, Metformin, Vitamin D)",
        parse_mode="HTML",
    )


async def handle_medicine_name(message: Message, state: FSMContext, backend: BackendClient):
    """Handle medicine name input."""
    await state.update_data(medicine_name=message.text.strip())
    await state.set_state(AddMedicineState.waiting_for_dosage)
    await message.answer(
        "📏 What is the <b>dosage</b>?\n"
        "(e.g., 1 tablet, 5ml, 250mg)",
        parse_mode="HTML",
    )


async def handle_medicine_dosage(message: Message, state: FSMContext, backend: BackendClient):
    """Handle medicine dosage input and create medicine."""
    data = await state.get_data()
    name = data["medicine_name"]
    dosage = message.text.strip()

    user = await backend.get_user(message.from_user.id)
    medicine = await backend.add_medicine(user["id"], name, dosage)

    await state.clear()
    await message.answer(
        f"✅ <b>Medicine added!</b>\n\n"
        f"💊 {medicine['name']}\n"
        f"📏 Dosage: {medicine['dosage']}\n\n"
        "Now set reminder times with /schedule",
        parse_mode="HTML",
    )
    logger.info(f"Medicine added: {name} for user {user['id']}")


# --- List Medicines ---

async def cmd_list_medicines(message: Message, backend: BackendClient):
    """List all medicines for the user."""
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("⚠️ Please register first with /start")
        return

    medicines = await backend.list_medicines(user["id"])

    if not medicines:
        await message.answer("📋 You don't have any medicines yet. Use /add to add one.")
        return

    text = "📋 <b>Your Medicines:</b>\n\n"
    for med in medicines:
        schedules = await backend.list_schedules(med["id"])
        times = ", ".join(s["reminder_time"][:5] for s in schedules) if schedules else "No reminders set"

        text += f"💊 <b>{med['name']}</b> - {med['dosage']}\n"
        text += f"   ⏰ Reminders: {times}\n\n"

    await message.answer(text, parse_mode="HTML")


# --- Edit Medicine ---

async def cmd_edit_medicine(message: Message, state: FSMContext, backend: BackendClient):
    """Start the edit medicine flow."""
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("⚠️ Please register first with /start")
        return

    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        await message.answer("📋 You don't have any medicines to edit. Use /add first.")
        return

    builder = InlineKeyboardBuilder()
    for med in medicines:
        builder.button(text=f"✏️ {med['name']}", callback_data=f"med:edit:{med['id']}")
    builder.adjust(1)

    await state.set_state(EditMedicineState.selecting_medicine)
    await message.answer("Select the medicine to edit:", reply_markup=builder.as_markup())


async def handle_edit_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    """Handle medicine selection for editing."""
    medicine_id = int(callback.data.split(":")[2])
    await state.update_data(medicine_id=medicine_id)

    builder = InlineKeyboardBuilder()
    builder.button(text="✏️ Name", callback_data="med:field:name")
    builder.button(text="✏️ Dosage", callback_data="med:field:dosage")
    builder.button(text="❌ Cancel", callback_data="med:cancel")
    builder.adjust(1)

    await state.set_state(EditMedicineState.selecting_field)
    await callback.message.edit_text("What would you like to change?", reply_markup=builder.as_markup())
    await callback.answer()


async def handle_edit_field_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    """Handle field selection for editing."""
    field = callback.data.split(":")[2]
    await state.update_data(edit_field=field)

    if field == "name":
        prompt = "Enter the new <b>name</b> for this medicine:"
    else:
        prompt = "Enter the new <b>dosage</b>:"

    await state.set_state(EditMedicineState.waiting_for_value)
    await callback.message.edit_text(prompt, parse_mode="HTML")
    await callback.answer()


async def handle_edit_value(message: Message, state: FSMContext, backend: BackendClient):
    """Handle new value input and update medicine."""
    data = await state.get_data()
    medicine_id = data["medicine_id"]
    field = data["edit_field"]
    user = await backend.get_user(message.from_user.id)

    payload = {field: message.text.strip()}
    updated = await backend.update_medicine(medicine_id, user["id"], **payload)

    await state.clear()
    await message.answer(
        f"✅ <b>Updated!</b>\n\n"
        f"💊 {updated['name']} - {updated['dosage']}",
        parse_mode="HTML",
    )


# --- Delete Medicine ---

async def cmd_delete_medicine(message: Message, state: FSMContext, backend: BackendClient):
    """Start the delete medicine flow."""
    user = await backend.get_user(message.from_user.id)
    if not user:
        await message.answer("⚠️ Please register first with /start")
        return

    medicines = await backend.list_medicines(user["id"])
    if not medicines:
        await message.answer("📋 You don't have any medicines to delete.")
        return

    builder = InlineKeyboardBuilder()
    for med in medicines:
        builder.button(text=f"🗑 {med['name']}", callback_data=f"med:delete:{med['id']}")
    builder.adjust(1)

    await state.set_state(DeleteMedicineState.selecting_medicine)
    await message.answer("Select the medicine to delete:", reply_markup=builder.as_markup())


async def handle_delete_select(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    """Handle medicine selection for deletion."""
    medicine_id = int(callback.data.split(":")[2])
    await state.update_data(medicine_id=medicine_id)

    builder = InlineKeyboardBuilder()
    builder.button(text="⚠️ Yes, Delete", callback_data=f"med:confirm_delete:{medicine_id}")
    builder.button(text="❌ Cancel", callback_data="med:cancel")
    builder.adjust(1)

    await state.set_state(DeleteMedicineState.confirming)
    await callback.message.edit_text(
        "⚠️ This will delete the medicine and all its reminder schedules.\n"
        "Are you sure?",
        reply_markup=builder.as_markup(),
    )
    await callback.answer()


async def handle_delete_confirm(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    """Handle delete confirmation."""
    medicine_id = int(callback.data.split(":")[2])
    user = await backend.get_user(callback.from_user.id)

    success = await backend.delete_medicine(medicine_id, user["id"])

    await state.clear()
    if success:
        await callback.message.edit_text("✅ Medicine deleted successfully.")
    else:
        await callback.message.edit_text("❌ Could not delete medicine.")
    await callback.answer()


# --- Medicine Callback Router ---

async def cb_medicine_action(callback: CallbackQuery, state: FSMContext, backend: BackendClient):
    """Route medicine callback queries."""
    parts = callback.data.split(":")
    action = parts[1] if len(parts) > 1 else ""

    if action == "edit":
        await handle_edit_select(callback, state, backend)
    elif action == "field":
        await handle_edit_field_select(callback, state, backend)
    elif action == "delete":
        await handle_delete_select(callback, state, backend)
    elif action == "confirm_delete":
        await handle_delete_confirm(callback, state, backend)
    elif action == "cancel":
        await state.clear()
        await callback.message.edit_text("❌ Cancelled.")
        await callback.answer()
