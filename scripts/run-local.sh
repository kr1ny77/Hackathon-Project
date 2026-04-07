#!/bin/bash
# run-local.sh - Run Medicine Reminder locally for development
# Usage: ./scripts/run-local.sh

set -e

echo "========================================="
echo " Medicine Reminder - Local Development"
echo "========================================="
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "[!] .env file not found. Copying from .env.example..."
    cp .env.example .env
    echo "[!] Please edit .env and set your TELEGRAM_BOT_TOKEN"
    echo ""
fi

# Start all services with Docker Compose
echo "Starting services..."
docker compose up -d --build

echo ""
echo "Waiting for services to start..."
sleep 10

# Show status
echo ""
echo "Service status:"
docker compose ps

echo ""
echo "========================================="
echo " Services started!"
echo "========================================="
echo ""
echo "Backend API: http://localhost:8000"
echo "Health check: curl http://localhost:8000/api/health"
echo "API Docs:    http://localhost:8000/docs"
echo ""
echo "View logs:"
echo "  docker compose logs -f"
echo ""
echo "View bot logs:"
echo "  docker compose logs -f bot"
echo ""
echo "Stop services:"
echo "  docker compose down"
