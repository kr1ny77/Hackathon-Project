#!/bin/bash
# quick-check.sh - Quick status check on VM
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@10.93.24.132 '
echo "=== Docker Compose Status ==="
cd /opt/medicine-reminder && docker compose ps 2>&1

echo ""
echo "=== Docker Images ==="
docker images 2>&1

echo ""
echo "=== Backend Health ==="
curl -s --max-time 5 http://localhost:8000/api/health 2>&1 || echo "Backend not responding"

echo ""
echo "=== Container Logs (last 20 lines) ==="
cd /opt/medicine-reminder && docker compose logs --tail=20 2>&1
'
