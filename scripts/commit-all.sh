#!/bin/bash
set -e
cd /Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon

echo "=== Git: Stage, Commit, Push ==="

git add -A

git status

git commit -m "feat: GigaChat AI integration, scheduler deduplication, dosage in reminders

- GigaChat AI agent: answers medicine questions via any chat message
- Natural language medicine addition: 'Add Aspirin at 08:00'
- Smart message handler: auto-detects medicine requests vs questions
- Scheduler deduplication: uses reminder_time for stable scheduled_time
- Dosage shown in reminder messages (without brackets)
- Menu shown after 'Taken' button press
- Edit/Delete: fixed user ID mapping and callback parsing
- Cancel button during Add medicine flow
- Today's schedule: ascending order, hides past times
- Intake history: grouped with count
- Full README update with AI features
- Moscow timezone (UTC+3) support

Repository: se-toolkit-hackathon
Tech stack: FastAPI, aiogram, PostgreSQL, SQLAlchemy, GigaChat, Docker"

git push
echo "✅ Pushed to GitHub!"
