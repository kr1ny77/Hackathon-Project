#!/bin/bash
# Final deploy - copy AMD64 images to VM, load, and start
set -e

cd /Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon
VM="root@10.93.24.132"
REMOTE="/opt/medicine-reminder"

echo "=== [1/3] Copying AMD64 images to VM ==="
scp backend-image-amd64.tar bot-image-amd64.tar "$VM:$REMOTE/"

echo ""
echo "=== [2/3] Copying project files ==="
rsync -avz --exclude='.git' --exclude='__pycache__' --exclude='*.tar' -e "ssh" \
    ./ "$VM:$REMOTE/"

echo ""
echo "=== [3/3] Loading images and starting on VM ==="
ssh "$VM" "
    cd $REMOTE

    echo 'Stopping old containers...'
    docker compose down --remove-orphans --timeout 10 2>/dev/null || true

    echo 'Removing old amd64 images...'
    docker rmi medreminder-backend medreminder-bot 2>/dev/null || true

    echo 'Loading backend image...'
    docker load -i backend-image-amd64.tar

    echo 'Loading bot image...'
    docker load -i bot-image-amd64.tar

    echo 'Removing version from docker-compose.yml...'
    grep -v '^version:' docker-compose.yml > /tmp/dc.yml 2>/dev/null && mv /tmp/dc.yml docker-compose.yml

    echo 'Starting services...'
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
    echo '=== STATUS ==='
    docker compose ps
    echo ''
    echo '=== HEALTH ==='
    curl -s http://localhost:8000/api/health
    echo ''
    echo '=== BACKEND LOGS ==='
    docker compose logs --tail=10 backend
    echo ''
    echo '=== BOT LOGS ==='
    docker compose logs --tail=10 bot
    echo ''
    echo '=== DONE ==='
    echo 'Open Telegram and send /start to your bot'
"
