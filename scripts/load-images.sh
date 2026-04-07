#!/bin/bash
# load-images.sh - Load pre-built Docker images on VM and start services
# Run this on the VM after copying .tar files

set -e

cd /opt/medicine-reminder

echo "========================================="
echo "  Loading Docker images on VM"
echo "========================================="

echo "[1/3] Loading backend image..."
docker load -i backend-image.tar

echo "[2/3] Loading bot image..."
docker load -i bot-image.tar

echo "[3/3] Starting services..."
docker compose up -d

echo ""
echo "Waiting for services..."
for i in $(seq 1 15); do
    if curl -s http://localhost:8000/api/health > /dev/null 2>&1; then
        echo "✅ Backend is healthy!"
        break
    fi
    echo "⏳ waiting... ($i/15)"
    sleep 3
done

echo ""
echo "=== Container Status ==="
docker compose ps

echo ""
echo "=== Health Check ==="
curl -s http://localhost:8000/api/health

echo ""
echo "=== Backend Logs ==="
docker compose logs --tail=10 backend

echo ""
echo "=== Bot Logs ==="
docker compose logs --tail=10 bot

echo ""
echo "========================================="
echo "  DEPLOY COMPLETE!"
echo "========================================="
echo "Open Telegram and send /start to your bot"
