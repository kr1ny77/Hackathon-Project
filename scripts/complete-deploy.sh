#!/bin/bash
# complete-deploy.sh — Deploy everything to VM
# Runs on Mac: bash scripts/complete-deploy.sh
set -e

PROJECT_DIR="/Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon"
VM="root@10.93.24.132"
REMOTE="/opt/medicine-reminder"
cd "$PROJECT_DIR"

echo "=== [1/5] Building fixed backend image (AMD64) ==="
docker build --platform linux/amd64 -t medreminder-backend:latest ./backend/
docker save medreminder-backend:latest -o backend-image-v3.tar
echo "Backend image ready: $(du -h backend-image-v3.tar | cut -f1)"

echo ""
echo "=== [2/5] Copying image and files to VM ==="
scp backend-image-v3.tar "$VM:$REMOTE/backend-image-v3.tar"
scp docker-compose.yml "$VM:$REMOTE/docker-compose.yml"
scp backend/app/db/init_db.py "$VM:$REMOTE/backend/app/db/init_db.py"

echo ""
echo "=== [3/5] Running setup on VM ==="
ssh "$VM" "
    cd $REMOTE

    echo '--- Loading backend image ---'
    docker rmi medreminder-backend 2>/dev/null || true
    docker load -i backend-image-v3.tar

    echo '--- Cleaning old data ---'
    docker compose down -v 2>/dev/null || true

    echo '--- Starting services ---'
    docker compose up -d

    echo '--- Waiting for DB and backend ---'
    sleep 10

    echo '--- Initializing database ---'
    docker exec medreminder-backend sh -c 'export PYTHONPATH=/app && python app/db/init_db.py'

    echo '--- Restarting backend (to re-init tables) ---'
    docker compose restart backend

    echo '--- Waiting for backend ---'
    for i in \$(seq 1 15); do
        HC=\$(curl -s --max-time 3 http://localhost:8000/api/health 2>&1)
        if echo \"\$HC\" | grep -q 'ok'; then
            echo \"  ✅ Backend healthy: \$HC\"
            break
        fi
        echo \"  ⏳ (\$i/15)\"
        sleep 3
    done

    echo ''
    echo '=== CONTAINER STATUS ==='
    docker compose ps

    echo ''
    echo '=== HEALTH CHECK ==='
    curl -s http://localhost:8000/api/health

    echo ''
    echo '=== BACKEND LOGS ==='
    docker compose logs --tail=10 backend

    echo ''
    echo '=== BOT LOGS ==='
    docker compose logs --tail=5 bot

    echo ''
    echo '=== DEPLOY COMPLETE ==='
"
