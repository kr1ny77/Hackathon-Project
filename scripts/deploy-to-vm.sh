#!/bin/bash
# deploy-to-vm.sh — One command to deploy everything to VM
# Run this from your Mac terminal

set -e

PROJECT_DIR="/Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon"
VM="root@10.93.24.132"
REMOTE="/opt/medicine-reminder"

cd "$PROJECT_DIR"

echo "=== Step 1: Copying tar images to VM ==="
scp backend-image.tar bot-image.tar "$VM:$REMOTE/"

echo ""
echo "=== Step 2: Copying project files ==="
rsync -avz --exclude='.git' --exclude='__pycache__' --exclude='*.tar' -e "ssh" \
    ./ "$VM:$REMOTE/"

echo ""
echo "=== Step 3: Loading images and starting services on VM ==="
ssh "$VM" "
    cd $REMOTE

    echo '[1/4] Loading backend image...'
    docker load -i backend-image.tar

    echo '[2/4] Loading bot image...'
    docker load -i bot-image.tar

    echo '[3/4] Removing version line from docker-compose.yml...'
    grep -v '^version:' docker-compose.yml > /tmp/dc.yml 2>/dev/null && mv /tmp/dc.yml docker-compose.yml

    echo '[4/4] Starting services...'
    docker compose down --remove-orphans --timeout 10 2>/dev/null || true
    docker compose up -d

    echo ''
    echo 'Waiting for backend...'
    for i in \$(seq 1 15); do
        if curl -s http://localhost:8000/api/health > /dev/null 2>&1; then
            echo '  ✅ Backend healthy!'
            break
        fi
        echo \"  ⏳ (\$i/15)\"
        sleep 3
    done

    echo ''
    echo '=== Container Status ==='
    docker compose ps

    echo ''
    echo '=== Health Check ==='
    curl -s http://localhost:8000/api/health

    echo ''
    echo '=== Backend Logs (last 10) ==='
    docker compose logs --tail=10 backend

    echo ''
    echo '=== Bot Logs (last 10) ==='
    docker compose logs --tail=10 bot

    echo ''
    echo '============================================'
    echo '  DEPLOY COMPLETE!'
    echo '============================================'
    echo 'Open Telegram and send /start to your bot'
"
