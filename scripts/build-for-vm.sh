#!/bin/bash
# build-for-vm.sh - Build images for AMD64 VM from ARM64 Mac
set -e

PROJECT_DIR="/Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon"
cd "$PROJECT_DIR"

echo "========================================="
echo "  Building AMD64 images for VM (from ARM Mac)"
echo "========================================="

echo ""
echo "[1/2] Building backend (linux/amd64)..."
docker build --platform linux/amd64 -t medreminder-backend:amd64 ./backend/

echo ""
echo "[2/2] Building bot (linux/amd64)..."
docker build --platform linux/amd64 -t medreminder-bot:amd64 ./bot/

echo ""
echo "=== Saving images ==="
docker tag medreminder-backend:amd64 medreminder-backend:latest
docker tag medreminder-bot:amd64 medreminder-bot:latest

docker save medreminder-backend:latest -o ./backend-image.tar
docker save medreminder-bot:latest -o ./bot-image.tar

echo ""
echo "Backend: $(du -h ./backend-image.tar | cut -f1)"
echo "Bot:     $(du -h ./bot-image.tar | cut -f1)"
echo ""
echo "=== DONE ==="
echo "Now run: bash scripts/deploy-to-vm.sh"
