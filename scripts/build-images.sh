#!/bin/bash
# build-images.sh - Build Docker images locally and save for VM deployment
# Run on Mac, then copy .tar files to VM and load with docker load

set -e

PROJECT_DIR="/Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon"
cd "$PROJECT_DIR"

echo "========================================="
echo "  Building images locally on Mac"
echo "========================================="

# Build backend
echo ""
echo "[1/2] Building backend image..."
docker build -t medreminder-backend ./backend/

# Build bot
echo ""
echo "[2/2] Building bot image..."
docker build -t medreminder-bot ./bot/

echo ""
echo "========================================="
echo "  Saving images to .tar files"
echo "========================================="

docker save medreminder-backend -o ./backend-image.tar
docker save medreminder-bot -o ./bot-image.tar

echo ""
echo "Backend image: $(du -h ./backend-image.tar | cut -f1)"
echo "Bot image:     $(du -h ./bot-image.tar | cut -f1)"

echo ""
echo "========================================="
echo "  IMAGES READY!"
echo "========================================="
echo ""
echo "Copy to VM:"
echo "  scp backend-image.tar bot-image.tar root@10.93.24.132:/opt/medicine-reminder/"
echo ""
echo "Then on VM run:"
echo "  cd /opt/medicine-reminder"
echo "  bash load-images.sh"
echo "  docker compose up -d"
