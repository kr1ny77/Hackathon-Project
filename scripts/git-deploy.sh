#!/bin/bash
# git-deploy.sh - Commit and push to GitHub
set -e

REPO_DIR="/Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon"
REMOTE_URL="https://github.com/kr1ny77/Hackathon-Project.git"
LOG_FILE="/tmp/git-deploy.log"

cd "$REPO_DIR"

{
echo "=== Git Deploy Log ==="
echo "Date: $(date)"
echo ""

# Check remote
echo "--- Current remote ---"
git remote -v 2>&1 || echo "No remote configured"
echo ""

# Set remote
echo "--- Setting remote ---"
git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE_URL"
git remote -v
echo ""

# Add all files
echo "--- Adding files ---"
git add -A
git status
echo ""

# Commit
echo "--- Committing ---"
git commit -m "feat: Medicine Reminder - complete V2 implementation

- Telegram bot with aiogram (add/edit/delete medicines, schedules)
- FastAPI backend with PostgreSQL + SQLAlchemy + async ORM
- Reminder scheduler with Taken/Missed inline buttons
- Intake history, today's schedule, duplicate prevention
- Docker Compose with all services (db, backend, bot)
- Full documentation and deployment scripts
- MIT License, .env with bot token preconfigured

Tech stack: FastAPI, aiogram, PostgreSQL, SQLAlchemy, Docker

Repository: se-toolkit-hackathon" 2>&1 || echo "Nothing to commit or already up to date"
echo ""

# Push
echo "--- Pushing to GitHub ---"
git branch -M main 2>/dev/null || true
git push -u origin main 2>&1
echo ""

echo "=== Deploy complete ==="
} > "$LOG_FILE" 2>&1

cat "$LOG_FILE"
