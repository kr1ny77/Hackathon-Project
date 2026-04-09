#!/bin/bash
set -e
cd /opt/medicine-reminder
echo "=== FIX v25 — AI only answers medicine/health questions ==="

# Add a topic filter to the GigaChat client
python3 << 'PYEOF'
path = "/opt/medicine-reminder/bot/app/services/gigachat.py"
with open(path) as f:
    content = f.read()

# Add is_health_related method
if "is_health_related" not in content:
    check_code = '''
    async def is_health_related(self, text):
        """Check if user message is about medicine/health. Returns (bool, reason)."""
        sys = (
            "You are a topic classifier. Determine if the user message is about medicine, health, drugs, "
            "treatment, symptoms, diseases, vitamins, supplements, or medical conditions. "
            "Return ONLY YES or NO, no explanation."
        )
        response = await self.ask(text, sys)
        return response.strip().upper() == "YES"
'''
    # Insert before last method or at the end
    last_method = content.rfind("    async def ")
    if last_method != -1:
        content = content[:last_method] + check_code + "\n" + content[last_method:]
    else:
        content = content.rstrip() + "\n" + check_code + "\n"
    with open(path, "w") as f:
        f.write(content)
    print("  Added is_health_related method to gigachat.py")
else:
    print("  is_health_related already exists.")
PYEOF

# Update AI handler to filter non-health topics
python3 << 'PYEOF'
path = "/opt/medicine-reminder/bot/app/handlers/ai.py"
with open(path) as f:
    content = f.read()

# Replace _do_question with filtered version
old_q = '''async def _do_question(message, text):
    thinking = await message.answer("Thinking...")
    lower = text.lower()
    med_words = ["medicine","drug","pill","tablet","aspirin","ibuprofen","paracetamol","vitamin","dose","side effect","take","swallow","prescription","medication","treatment","pain","headache","fever"]
    if any(w in lower for w in med_words):
        sp = "You are a medical assistant. Answer briefly (2-3 sentences). Suggest consulting a doctor."
    else:
        sp = "You are a helpful assistant for a medicine reminder bot. Answer briefly."
    reply = await giga.ask(text, sp)
    try: await thinking.delete()
    except: pass
    await message.answer(reply, reply_markup=build_main_menu())'''

new_q = '''async def _do_question(message, text):
    # Check if topic is about health/medicine
    is_health = await giga.is_health_related(text)
    if not is_health:
        await message.answer("I can only help with medicine and health-related questions. Please ask about medicines, symptoms, treatments, or health topics.", reply_markup=build_main_menu())
        return
    thinking = await message.answer("Thinking...")
    sp = "You are a medical assistant for a medicine reminder bot. Answer briefly (2-3 sentences). Be helpful but do not give specific medical advice. Always suggest consulting a doctor."
    reply = await giga.ask(text, sp)
    try: await thinking.delete()
    except: pass
    await message.answer(reply, reply_markup=build_main_menu())'''

if old_q in content:
    content = content.replace(old_q, new_q)
    with open(path, "w") as f:
        f.write(content)
    print("  Updated _do_question to filter non-health topics.")
else:
    print("  WARNING: Could not find _do_question. Manual check required.")
PYEOF

echo "=== Copying to container ==="
docker cp bot/app/services/gigachat.py medreminder-bot:/app/app/services/gigachat.py
docker cp bot/app/handlers/ai.py medreminder-bot:/app/app/handlers/ai.py

echo "=== Restarting bot ==="
docker compose restart bot
sleep 6

echo ""
echo "=== Logs ==="
docker compose logs --tail 5 bot
echo ""
echo "============================================"
echo "  FIX v25 APPLIED"
echo "============================================"
echo ""
echo "  AI now only answers health/medicine questions."
echo "  For other topics: 'I can only help with medicine and health-related questions.'"
