#!/bin/bash
# fix-vm.sh - Copy fix files to VM and restart services
set -e

PROJECT_DIR="/Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon"
VM="root@10.93.24.132"
REMOTE="/opt/medicine-reminder"

echo "=== Copying fixed files to VM ==="
scp "$PROJECT_DIR/docker-compose.yml" "$VM:$REMOTE/docker-compose.yml"
scp "$PROJECT_DIR/backend/app/db/init_db.py" "$VM:$REMOTE/backend/app/db/init_db.py"

echo "=== Restarting services on VM ==="
ssh "$VM" "
    cd $REMOTE
    docker compose down 2>/dev/null || true
    docker compose up -d
    echo 'Waiting...'
    sleep 15
    docker compose ps
    echo '---'
    curl -s http://localhost:8000/api/health || echo 'NOT READY'
    echo '---'
    docker compose logs --tail=15 backend
    echo '---'
    docker compose logs --tail=5 bot
"
