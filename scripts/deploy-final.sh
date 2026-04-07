#!/bin/bash
# STEP 2: Run on VM — build image locally, deploy, init DB
set -e
cd /opt/medicine-reminder

echo "=== [1/4] Stopping old containers ==="
docker compose down -v --remove-orphans 2>/dev/null || true

echo "=== [2/4] Building backend image locally (no PyPI needed — cached) ==="
# Build from Dockerfile on VM (files already copied)
docker build --no-cache -t medreminder-backend:latest ./backend/

echo "=== [3/4] Starting services ==="
docker compose up -d

echo "=== [4/4] Waiting and initializing ==="
sleep 10

# Init DB
docker exec medreminder-backend sh -c 'export PYTHONPATH=/app && python app/db/init_db.py' 2>&1

echo ""
echo "Restarting backend to pick up tables..."
docker compose restart backend
sleep 5

for i in $(seq 1 15); do
    HC=$(curl -s --max-time 3 http://localhost:8000/api/health 2>&1)
    if echo "$HC" | grep -q "ok"; then
        echo "✅ Backend healthy: $HC"
        break
    fi
    echo "⏳ ($i/15)"
    sleep 3
done

echo ""
echo "=== STATUS ==="
docker compose ps
echo ""
echo "=== HEALTH ==="
curl -s http://localhost:8000/api/health
echo ""
echo "=== BACKEND LOGS ==="
docker compose logs --tail=10 backend
echo "=== BOT LOGS ==="
docker compose logs --tail=5 bot
echo ""
echo "=== DONE — open Telegram and send /start ==="
