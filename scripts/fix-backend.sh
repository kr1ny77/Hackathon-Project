#!/bin/bash
set -e
cd /opt/medicine-reminder

echo "=== [1] Stopping ==="
docker compose stop backend 2>&1 || true
sleep 2

echo "=== [2] Writing docker-compose.yml ==="
cat > docker-compose.yml << 'EOF'
services:
  db:
    image: postgres:16-alpine
    container_name: medreminder-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-medreminder}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-medreminder_pass}
      POSTGRES_DB: ${POSTGRES_DB:-medreminder}
    ports:
      - "${POSTGRES_PORT:-5432}:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-medreminder} -d ${POSTGRES_DB:-medreminder}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    networks:
      - medreminder-net

  backend:
    image: medreminder-backend:latest
    container_name: medreminder-backend
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-medreminder}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-medreminder_pass}
      POSTGRES_DB: ${POSTGRES_DB:-medreminder}
      POSTGRES_HOST: db
      POSTGRES_PORT: 5432
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN}
    ports:
      - "${BACKEND_PORT:-8000}:8000"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - medreminder-net
    command: ["sh", "-c", "export PYTHONPATH=/app && python -c \"import asyncio; from app.models.models import Base; from app.db.session import engine; async def init():\n    async with engine.begin() as conn:\n        await conn.run_sync(Base.metadata.create_all)\n    await engine.dispose()\nasyncio.run(init()); print('Tables created')\" && uvicorn app.main:app --host 0.0.0.0 --port 8000"]

  bot:
    image: medreminder-bot:latest
    container_name: medreminder-bot
    restart: unless-stopped
    environment:
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN}
      BACKEND_URL: http://backend:8000/api
      REMINDER_CHECK_INTERVAL: ${REMINDER_CHECK_INTERVAL:-30}
    depends_on:
      - backend
    networks:
      - medreminder-net

volumes:
  postgres_data:

networks:
  medreminder-net:
    driver: bridge
EOF

echo "=== [3] Starting ==="
docker compose up -d 2>&1

echo "=== [4] Waiting ==="
for i in $(seq 1 20); do
    HC=$(curl -s --max-time 3 http://localhost:8000/api/health 2>&1)
    if echo "$HC" | grep -q "ok"; then
        echo "  ✅ Backend healthy: $HC"
        break
    fi
    echo "  ⏳ ($i/20) ..."
    sleep 3
done

echo ""
echo "=== [5] Status ==="
docker compose ps

echo ""
echo "=== [6] Backend logs ==="
docker compose logs --tail=15 backend

echo ""
echo "=== [7] Bot logs ==="
docker compose logs --tail=5 bot

echo ""
echo "=== DONE ==="
