# Medicine Reminder - Deployment Guide for VM
# ==========================================

# STEP 1: SSH into the VM
# ssh root@10.93.24.132
# Password: Qwe350069

# STEP 2: Install Docker and Docker Compose
apt-get update
apt-get install -y docker.io docker-compose-v2 git
systemctl enable docker
systemctl start docker

# Verify:
docker --version
docker compose version

# STEP 3: Clone or copy project to VM
# Option A - Clone from GitHub (after you push):
# git clone https://github.com/YOUR_USERNAME/se-toolkit-hackathon.git
# cd se-toolkit-hackathon

# Option B - Copy files via rsync from your machine:
# On your LOCAL machine, run:
# rsync -avz --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
#   -e "ssh" /path/to/se-toolkit-hackathon/ root@10.93.24.132:/opt/medicine-reminder/

# STEP 4: Create project directory on VM
mkdir -p /opt/medicine-reminder

# STEP 5: Copy files (run this from your LOCAL machine)
# rsync -avz --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
#   -e "ssh" ./ root@10.93.24.132:/opt/medicine-reminder/

# STEP 6: SSH into VM and deploy
ssh root@10.93.24.132
cd /opt/medicine-reminder

# STEP 7: Start services
docker compose up -d --build

# STEP 8: Check status
docker compose ps

# STEP 9: Test health endpoint
curl http://localhost:8000/api/health

# STEP 10: Test the bot on Telegram
# Open Telegram, find your bot, send /start

# --- Common Commands ---

# View logs:
docker compose logs -f
docker compose logs -f bot
docker compose logs -f backend

# Restart:
docker compose restart
docker compose restart bot

# Stop:
docker compose down

# Rebuild after code changes:
docker compose down
docker compose up -d --build

# Run migrations manually:
docker compose exec backend alembic upgrade head
