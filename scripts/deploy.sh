#!/bin/bash
# deploy.sh - Deploy Medicine Reminder to Ubuntu 24.04 VM
# Usage: ./scripts/deploy.sh root@10.93.24.132

set -e

VM_HOST="${1:-root@10.93.24.132}"
PROJECT_DIR="/opt/medicine-reminder"

echo "========================================="
echo " Medicine Reminder - VM Deployment Script"
echo "========================================="
echo ""
echo "Target: $VM_HOST"
echo ""

# Step 1: Test SSH connection
echo "[1/7] Testing SSH connection..."
ssh -o ConnectTimeout=10 "$VM_HOST" "echo 'SSH connection OK'" || {
    echo "ERROR: Cannot connect to VM at $VM_HOST"
    echo "Make sure you can SSH into the VM first."
    exit 1
}

# Step 2: Install prerequisites on VM
echo "[2/7] Installing prerequisites on VM..."
ssh "$VM_HOST" "
    apt-get update && apt-get install -y docker.io docker-compose-v2 git
    systemctl enable docker
    systemctl start docker
"

# Step 3: Create project directory
echo "[3/7] Creating project directory on VM..."
ssh "$VM_HOST" "
    mkdir -p $PROJECT_DIR
"

# Step 4: Copy project files to VM
echo "[4/7] Copying project files to VM..."
rsync -avz --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
    --exclude='postgres_data' \
    "$(dirname "$0")/../" "$VM_HOST:$PROJECT_DIR/"

# Step 5: Deploy with Docker Compose
echo "[5/7] Building and starting services..."
ssh "$VM_HOST" "
    cd $PROJECT_DIR
    docker compose down 2>/dev/null || true
    docker compose up -d --build
"

# Step 6: Wait for services to be healthy
echo "[6/7] Waiting for services to start..."
sleep 15

# Step 7: Verify deployment
echo "[7/7] Verifying deployment..."
ssh "$VM_HOST" "
    cd $PROJECT_DIR
    docker compose ps
    echo ''
    echo '--- Health Check ---'
    curl -s http://localhost:8000/api/health || echo 'Backend not responding yet'
"

echo ""
echo "========================================="
echo " Deployment complete!"
echo "========================================="
echo ""
echo "To check logs:"
echo "  ssh $VM_HOST 'cd $PROJECT_DIR && docker compose logs -f'"
echo ""
echo "To restart:"
echo "  ssh $VM_HOST 'cd $PROJECT_DIR && docker compose restart'"
echo ""
echo "To stop:"
echo "  ssh $VM_HOST 'cd $PROJECT_DIR && docker compose down'"
