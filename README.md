# Medicine Reminder 💊⏰

> A Telegram bot-based service that helps users remember to take medicines on time, track intake history, and manage medication schedules.

## Demo

![Demo placeholder - bot interaction screenshot](https://via.placeholder.com/600x400/4CAF50/ffffff?text=Medicine+Reminder+Bot+Demo)

> _Screenshot: User adds a medicine, sets a reminder time, and receives a reminder with Taken/Missed buttons._

## Product Context

### End Users
People who need simple, timely medicine reminders and want to track whether they took or missed their doses.

### Problem Solved
Users forget to take medicines on time and have no simple way to track whether a dose was taken or missed.

### Solution
A Telegram bot that sends timely reminders, lets users confirm intake with one tap, and stores all data in a database for later review.

### Project Idea (One Sentence)
A Telegram bot-based medicine reminder system with dose tracking and intake history.

### Core Feature
The bot sends reminders at scheduled times and allows users to press "Taken" or "Missed" buttons, while the backend stores schedules and history in PostgreSQL.

---

## Versioning / Implementation Plan

### Version 1 — Core Feature
- User starts bot with `/start` and gets registered
- Add a medicine with name and dosage
- Set one or more reminder times per medicine
- Bot sends reminders at scheduled times via polling
- Inline buttons: **Taken** / **Missed**
- Intake history saved to PostgreSQL
- Backend API + database + bot running via Docker Compose

### Version 2 — Polish & Production (Current)
- **Edit** medicine name/dosage
- **Delete** medicine (with cascade cleanup)
- **List** all medicines with their reminder times
- **Today's schedule** view
- **Intake history** command
- **Duplicate prevention** for same scheduled dose
- **Validation** and error handling improvements
- All services **dockerized**
- Full **documentation** and **deployment guide**
- Pushed to GitHub as `se-toolkit-hackathon`

---

## Features

### Implemented ✅
| Feature | Command |
|---------|---------|
| User registration | `/start` |
| Add medicine | `/add` |
| List medicines | `/medicines` |
| Edit medicine | `/edit` |
| Delete medicine | `/delete` |
| Set reminder time | `/schedule` |
| Today's schedule | `/today` |
| Intake history | `/history` |
| Help | `/help` |
| Timely reminder messages | Automatic |
| Taken/Missed inline buttons | Automatic |
| Persistent storage | PostgreSQL |
| Health check endpoint | `GET /api/health` |

### Not Yet Implemented 📋
- Multiple medicines in one message
- Snooze reminder functionality
- Statistics / adherence reports
- Web admin dashboard
- Webhook mode (currently uses polling)

---

## Architecture Overview

```
┌──────────────┐        ┌──────────────┐        ┌──────────────┐
│   Telegram   │  HTTP   │   FastAPI    │  SQL   │  PostgreSQL  │
│     Bot      │◄──────►│   Backend    │◄──────►│  Database    │
│  (aiogram)   │  API   │  (Python)    │  ORM   │              │
└──────────────┘        └──────────────┘        └──────────────┘
       │                        │
       │  Polls every 30s       │
       │  for due reminders     │
       ▼                        │
┌──────────────┐                │
│  Scheduler   │────────────────┘
│  (inside bot)│  Creates intake records,
│              │  sends messages to users
└──────────────┘
```

### Components

- **Bot (aiogram)**: Telegram-facing client. Handles user commands, displays inline keyboards, and runs a background scheduler that polls for due reminders every 30 seconds.
- **Backend (FastAPI)**: Owns all business logic and database access. Exposes REST API endpoints for users, medicines, schedules, and intake history.
- **Database (PostgreSQL)**: Stores users, medicines, reminder schedules, and intake history with proper foreign key relationships and cascade deletes.
- **Scheduler**: Runs inside the bot process. Every 30 seconds, queries the backend for active schedules matching the current minute, creates pending intake records, and sends reminder messages.

### Design Decisions
- **Polling over Webhook**: Chosen for simplicity. Works behind NAT/firewalls, easier to debug, sufficient for a student project with 30-second check intervals.
- **Separate bot and backend containers**: Clean separation of concerns. Bot handles Telegram communication, backend owns business logic and data.
- **SQLAlchemy ORM**: Type-safe queries, async support, easy migrations with Alembic.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Bot Framework | aiogram 3.x (Python) |
| Backend API | FastAPI (Python) |
| Database | PostgreSQL 16 |
| ORM | SQLAlchemy 2.x (async) |
| Migrations | Alembic |
| Scheduling | Custom polling loop (asyncio) |
| Containerization | Docker + Docker Compose |
| Server | Ubuntu 24.04 VM |

---

## Database Model

```
┌─────────┐       ┌───────────┐       ┌────────────────────┐       ┌───────────────┐
│  users  │───────│ medicines │───────│ reminder_schedules │───────│ intake_history│
├─────────┤       ├───────────┤       ├────────────────────┤       ├───────────────┤
│ id      │       │ id        │       │ id                 │       │ id            │
│ tg_id   │  1:N  │ user_id   │  1:N  │ medicine_id        │  1:N  │ user_id       │
│ username│       │ name      │       │ reminder_time      │       │ schedule_id   │
│ f_name  │       │ dosage    │       │ is_active          │       │ medicine_name │
│ reg_at  │       │ created_at│       │                    │       │ scheduled_time│
└─────────┘       └───────────┘       └────────────────────┘       │ status        │
                                                                    │ responded_at  │
                                                                    └───────────────┘
```

**Key relationships:**
- A `user` has many `medicines` (cascade delete)
- A `medicine` has many `reminder_schedules` (cascade delete)
- A `reminder_schedule` has many `intake_history` records
- `intake_history.status` enum: `pending`, `taken`, `missed`

---

## API Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/health` | Health check |
| `POST` | `/api/users` | Register/get user |
| `GET` | `/api/users/telegram/{id}` | Get user by Telegram ID |
| `POST` | `/api/medicines?user_id=N` | Add medicine |
| `GET` | `/api/medicines/user/{id}` | List user medicines |
| `GET` | `/api/medicines/{id}?user_id=N` | Get medicine with schedules |
| `PATCH` | `/api/medicines/{id}?user_id=N` | Update medicine |
| `DELETE` | `/api/medicines/{id}?user_id=N` | Delete medicine |
| `POST` | `/api/schedules` | Add reminder time |
| `GET` | `/api/schedules/medicine/{id}` | List schedules |
| `DELETE` | `/api/schedules/{id}?user_id=N` | Delete schedule |
| `GET` | `/api/schedules/active/{h}/{m}` | Get active schedules (scheduler) |
| `GET` | `/api/schedules/active-details/{h}/{m}` | Get active schedules with user+medicine info |
| `POST` | `/api/intakes` | Record taken/missed |
| `POST` | `/api/intakes/pending` | Create pending intake (scheduler) |
| `GET` | `/api/intakes/user/{id}` | Get intake history |
| `GET` | `/api/intakes/today/{id}` | Get today's intakes |

---

## Bot Commands

| Command | Description |
|---------|-------------|
| `/start` | Register with the bot |
| `/add` | Add a new medicine (interactive flow) |
| `/medicines` | List all your medicines with reminder times |
| `/edit` | Edit medicine name or dosage |
| `/delete` | Delete a medicine and its reminders |
| `/schedule` | Add a reminder time for a medicine |
| `/today` | Show today's medicine schedule |
| `/history` | View recent intake history |
| `/help` | Show help message |

---

## Usage — Step by Step

1. **Start the bot**: Open Telegram, find your bot, send `/start`
2. **Add a medicine**: Send `/add`, then type the medicine name, then the dosage
3. **Set a reminder**: Send `/schedule`, select the medicine, then type the time (e.g., `08:00`)
4. **Receive reminders**: At the scheduled time, the bot sends a message with Taken/Missed buttons
5. **Record intake**: Tap ✅ **Taken** or ❌ **Missed**
6. **View history**: Send `/history` to see your recent records
7. **Manage medicines**: Use `/medicines`, `/edit`, `/delete` to manage your list

---

## Deployment

### Target OS
Ubuntu 24.04 VM

### Prerequisites
```bash
# Install Docker and Docker Compose
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable docker
sudo systemctl start docker

# Verify
docker --version
docker compose version
```

### Quick Deploy (One Command)

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/se-toolkit-hackathon.git
cd se-toolkit-hackathon

# .env is already configured with the bot token
# Build and start all services
docker compose up -d --build

# Check status
docker compose ps

# Verify backend is running
curl http://localhost:8000/api/health
```

### Environment Variables

All settings are in `.env`. The default values work out of the box:

```env
TELEGRAM_BOT_TOKEN=8797131965:AAEDqh2vpfGM83cPSObIDRsikWTgQhTABTY

POSTGRES_USER=medreminder
POSTGRES_PASSWORD=medreminder_pass
POSTGRES_DB=medreminder
POSTGRES_PORT=5432

BACKEND_PORT=8000

REMINDER_CHECK_INTERVAL=30
```

### Build and Run

```bash
# Start all services
docker compose up -d --build

# View logs
docker compose logs -f

# View specific service logs
docker compose logs -f bot
docker compose logs -f backend
docker compose logs -f db
```

### Database Migrations

Migrations run automatically on startup via the backend container's entrypoint:
```bash
alembic upgrade head
```

To run migrations manually:
```bash
docker compose exec backend alembic upgrade head
```

To create a new migration after model changes:
```bash
docker compose exec backend alembic revision --autogenerate -m "description"
docker compose exec backend alembic upgrade head
```

### Restart

```bash
# Restart all services
docker compose restart

# Restart a specific service
docker compose restart bot

# Full rebuild
docker compose down
docker compose up -d --build
```

### Stop

```bash
docker compose down
```

---

## ⚠️ Important: Telegram Bot on University VMs

**Problem**: Telegram bot traffic (polling or webhooks) is often **blocked on university VMs** due to network restrictions or firewalls.

**Solutions**:

### Option A: Deploy on a Non-University VM (Recommended)
Use a personal cloud VM (e.g., DigitalOcean, Hetzner, AWS, Oracle Cloud Free Tier):
1. Create a VM on any cloud provider
2. Follow the deployment steps above
3. The bot will work without restrictions

### Option B: Use the Provided VM
The project is configured to deploy to `10.93.24.132`. If Telegram polling works on this VM, the bot will function normally. If not, use Option A.

### Option C: Local Development + Remote Backend
- Run the **backend + database** on the VM
- Run the **bot** locally on your machine (where Telegram is not blocked)
- Update the bot's `BACKEND_URL` in `.env` to point to the VM's IP

**This project uses polling mode** (not webhook) because:
- No DNS or SSL certificate needed
- Works behind NAT/firewalls
- Simpler to set up and debug
- 30-second polling interval is responsive enough for medicine reminders

---

## Repository Structure

```
se-toolkit-hackathon/
├── .env                        # Environment variables (with bot token)
├── .env.example                # Template for environment variables
├── .gitignore                  # Git ignore rules
├── docker-compose.yml          # Docker Compose configuration
├── LICENSE                     # MIT License
├── README.md                   # This file
├── backend/
│   ├── Dockerfile              # Backend container definition
│   ├── requirements.txt        # Python dependencies
│   ├── alembic.ini             # Alembic migration config
│   └── app/
│       ├── main.py             # FastAPI application entry point
│       ├── core/
│       │   └── config.py       # Application settings
│       ├── db/
│       │   └── session.py      # Database session management
│       ├── models/
│       │   └── models.py       # SQLAlchemy ORM models
│       ├── schemas/
│       │   └── schemas.py      # Pydantic request/response schemas
│       ├── services/
│       │   └── services.py     # Business logic layer
│       └── api/
│           └── endpoints.py    # REST API route definitions
│       └── alembic/
│           ├── env.py          # Alembic environment config
│           └── versions/
│               └── 001_initial_schema.py  # Initial migration
├── bot/
│   ├── Dockerfile              # Bot container definition
│   ├── requirements.txt        # Python dependencies
│   └── app/
│       ├── main.py             # Bot entry point
│       ├── config.py           # Bot settings
│       ├── handlers/
│       │   ├── router.py       # Handler registrations & routing
│       │   ├── start.py        # /start command handler
│       │   ├── medicine.py     # Add/edit/list/delete medicine
│       │   ├── schedule.py     # Set reminder times
│       │   └── intake.py       # Intake history & button callbacks
│       └── services/
│           ├── backend_client.py  # HTTP client for backend API
│           └── scheduler.py       # Reminder polling scheduler
├── scripts/
│   ├── deploy.sh               # VM deployment script
│   └── run-local.sh            # Local development startup
└── deploy/                     # Additional deployment files (if needed)
```

---

## Future Improvements

- [ ] Snooze reminder (remind again in 10 minutes)
- [ ] Medicine adherence statistics and charts
- [ ] Export intake history as CSV
- [ ] Webhook mode for production-scale deployments
- [ ] Multi-language support
- [ ] Medicine interaction warnings
- [ ] Refill reminders (when supply runs low)
- [ ] Caregiver mode (monitor someone else's medicines)

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

- [aiogram](https://docs.aiogram.dev/) — Async Telegram Bot API framework
- [FastAPI](https://fastapi.tiangolo.com/) — Modern Python web framework
- [SQLAlchemy](https://www.sqlalchemy.org/) — Python SQL toolkit and ORM
- [PostgreSQL](https://www.postgresql.org/) — Advanced open-source relational database
