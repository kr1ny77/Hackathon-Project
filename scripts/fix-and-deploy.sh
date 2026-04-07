#!/bin/bash
# fix-and-deploy.sh - Fix Dockerfiles and redeploy to VM
set -e

cd /Users/kr1ny77/Desktop/software-engineering-toolkit/se-toolkit-hackathon

echo "=== Committing Dockerfile fixes ==="
git add bot/Dockerfile backend/Dockerfile docker-compose.yml scripts/
git commit -m "fix: remove gcc from Dockerfiles, remove deprecated version from compose

- asyncpg has pre-built ARM64 wheels, no C compiler needed
- faster builds on ARM64 VMs
- removed deprecated docker-compose version attribute" 2>&1

echo ""
echo "=== Pushing to GitHub ==="
git push 2>&1

echo ""
echo "=== Copying fixed files to VM ==="
rsync -avz --exclude='.git' --exclude='__pycache__' -e "ssh" \
    ./ root@10.93.24.132:/opt/medicine-reminder/

echo ""
echo "=== Stopping old containers on VM ==="
ssh root@10.93.24.132 "cd /opt/medicine-reminder && docker compose down --remove-orphans 2>&1"

echo ""
echo "=== Rebuilding on VM (should be fast now - no gcc!) ==="
ssh root@10.93.24.132 "
    cd /opt/medicine-reminder
    docker compose up -d --build 2>&1
"

echo ""
echo "=== Waiting for services... ==="
sleep 20

echo ""
echo "=== Checking status ==="
ssh root@10.93.24.132 "
    cd /opt/medicine-reminder
    echo '--- Container Status ---'
    docker compose ps
    echo ''
    echo '--- Health Check ---'
    curl -s --max-time 5 http://localhost:8000/api/health || echo 'Backend not ready yet'
    echo ''
    echo '--- Backend Logs ---'
    docker compose logs --tail=15 backend
    echo ''
    echo '--- Bot Logs ---'
    docker compose logs --tail=15 bot
"

echo ""
echo "=== Done ==="
