#!/bin/bash
# STEP 1: Run on Mac — copy files to VM
# bash /Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon/scripts/copy-to-vm.sh

set -e
PROJECT_DIR="/Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon"
VM="root@10.93.24.132"
REMOTE="/opt/medicine-reminder"

echo "Copying corrected files to VM..."
# Copy only small files, NOT the large image
scp "$PROJECT_DIR/docker-compose.yml" "$VM:$REMOTE/docker-compose.yml"
scp "$PROJECT_DIR/backend/app/db/init_db.py" "$VM:$REMOTE/backend/app/db/init_db.py"
scp "$PROJECT_DIR/backend/app/models/models.py" "$VM:$REMOTE/backend/app/models/models.py"

echo "Files copied. Now run on VM:"
echo "  bash $REMOTE/scripts/deploy-final.sh"
