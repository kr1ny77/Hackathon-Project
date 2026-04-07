#!/bin/bash
# full-fix.sh - Complete fix and deploy on VM
set -e

PROJECT_DIR="/opt/medicine-reminder"

echo "========================================="
echo "  Medicine Reminder - Full Fix & Deploy"
echo "========================================="

cd "$PROJECT_DIR"

# Step 1: Force stop everything
echo "[1/8] Stopping all containers..."
docker compose down --remove-orphans --timeout 10 2>&1 || true

# Step 2: Remove old images to force rebuild
echo "[2/8] Cleaning old images..."
docker rmi medicine-reminder-backend medicine-reminder-bot 2>/dev/null || true

# Step 3: Fix docker-compose.yml - remove version line
echo "[3/8] Fixing docker-compose.yml..."
sed -i '/^version:/d' docker-compose.yml

# Step 4: Fix bot Dockerfile - remove gcc
echo "[4/8] Fixing bot/Dockerfile..."
cat > bot/Dockerfile << 'DOCKERFILE'
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "-m", "app.main"]
DOCKERFILE

# Step 5: Fix backend Dockerfile - remove gcc
echo "[5/8] Fixing backend/Dockerfile..."
cat > backend/Dockerfile << 'DOCKERFILE'
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/api/health')" || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
DOCKERFILE

# Step 6: Build and start
echo "[6/8] Building and starting services..."
docker compose up -d --build 2>&1

# Step 7: Wait for health
echo "[7/8] Waiting for services to start..."
for i in $(seq 1 20); do
    if curl -s http://localhost:8000/api/health > /dev/null 2>&1; then
        echo "  Backend is healthy!"
        break
    fi
    echo "  Waiting... ($i/20)"
    sleep 3
done

# Step 8: Verify
echo "[8/8] Verification:"
echo ""
echo "=== Container Status ==="
docker compose ps

echo ""
echo "=== Health Check ==="
curl -s http://localhost:8000/api/health

echo ""
echo "=== Backend Logs ==="
docker compose logs --tail=20 backend

echo ""
echo "=== Bot Logs ==="
docker compose logs --tail=20 bot

echo ""
echo "========================================="
echo "  DEPLOY COMPLETE!"
echo "========================================="
echo ""
echo "Test the bot on Telegram: open your bot and send /start"
echo ""
echo "Useful commands:"
echo "  docker compose logs -f        # View all logs"
echo "  docker compose logs -f bot    # Bot logs only"
echo "  docker compose restart bot    # Restart bot"
echo "  docker compose down           # Stop everything"
