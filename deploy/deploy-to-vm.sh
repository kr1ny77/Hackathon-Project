#!/bin/bash
# deploy-to-vm.sh - One-command deployment to the VM
# Usage: bash deploy/deploy-to-vm.sh
# Or copy-paste these commands manually

set -e

VM="root@10.93.24.132"
REMOTE_DIR="/opt/medicine-reminder"

echo "============================================"
echo "  Medicine Reminder - Deploy to VM"
echo "============================================"
echo ""
echo "Target: $VM"
echo "Remote: $REMOTE_DIR"
echo ""

# Test connection
echo "[1/5] Testing SSH connection..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$VM" "echo '  SSH OK'" || {
    echo "  ERROR: Cannot connect to VM"
    exit 1
}

# Install prerequisites
echo "[2/5] Installing Docker on VM..."
ssh "$VM" "
    apt-get update -qq
    apt-get install -y -qq docker.io docker-compose-v2 > /dev/null 2>&1
    systemctl enable docker --quiet
    systemctl start docker
    echo '  Docker installed'
"

# Create directory
echo "[3/5] Creating remote directory..."
ssh "$VM" "mkdir -p $REMOTE_DIR"

# Copy files
echo "[4/5] Copying project files..."
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
rsync -avz --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
    --exclude='*.pyc' --exclude='.DS_Store' \
    "$SCRIPT_DIR/" "$VM:$REMOTE_DIR/"

# Deploy
echo "[5/5] Starting services..."
ssh "$VM" "
    cd $REMOTE_DIR
    docker compose down 2>/dev/null || true
    docker compose up -d --build
    sleep 10
    echo ''
    echo '=== Service Status ==='
    docker compose ps
    echo ''
    echo '=== Health Check ==='
    curl -s http://localhost:8000/api/health || echo '  Backend not ready yet, wait 30s and try again'
"

echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "Test the bot: Open Telegram -> find your bot -> /start"
echo ""
echo "Useful commands:"
echo "  ssh $VM 'cd $REMOTE_DIR && docker compose logs -f'"
echo "  ssh $VM 'cd $REMOTE_DIR && docker compose restart'"
echo "  ssh $VM 'cd $REMOTE_DIR && docker compose down'"
