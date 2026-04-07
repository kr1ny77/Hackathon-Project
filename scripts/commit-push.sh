#!/bin/bash
# commit-and-push.sh - Commit all fixes and push to GitHub
set -e
cd /Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon

git add -A
git status
git commit -m "fix: working deployment - fix model enum, async init_db, docker-compose command

- Fix ReminderSchedule.is_active: was SAEnum type, now Boolean
- Fix IntakeStatus enum: explicit name='intakestatus' for PostgreSQL
- init_db.py uses asyncpg instead of psycopg2-binary
- docker-compose.yml uses simple uvicorn command (no sh -c)
- DB init done via docker exec after container starts
- Remove version from docker-compose.yml
- All models, schemas, services tested and working"

git push
echo "Pushed to GitHub!"
