# Medicine Reminder 💊⏰

> A Telegram bot-based service that helps users remember to take medicines on time, with an AI assistant powered by GigaChat for medicine questions and natural-language requests.

---

## Demo

> _Open Telegram, find @InnoMedicineReminder_bot and send `/start`_

- Add medicines with name and dosage
- Set reminder times (multiple per medicine)
- Receive grouped reminders with **Taken** / **Remind in 5 min** buttons
- Ask about any medicine: *"What is Aspirin?"*
- Add medicines naturally: *"Add Aspirin at 08:00 and Ibuprofen at 19:00"*

---

## Product Context

### End Users
People who need simple, timely medicine reminders and want to track whether they took or missed their doses.

### Problem Solved
Users forget to take medicines on time and have no simple way to track whether a dose was taken or missed.

### Solution
A Telegram bot that sends timely reminders, lets users confirm intake with one tap, stores all data in PostgreSQL, and includes an AI assistant for medicine questions and natural-language requests.

### Project Idea (One Sentence)
A Telegram bot-based medicine reminder system with AI-powered assistant, dose tracking, and intake history.

### Core Feature
The bot sends grouped reminders at scheduled times and allows users to press **Taken** or **Missed** buttons, while the backend stores schedules and history in PostgreSQL.

---

## Versioning / Implementation Plan

### Version 1 — Core Feature
- User starts bot with `/start` and gets registered
- Add a medicine with name and dosage
- Set one or more reminder times per medicine
- Bot sends grouped reminders at scheduled times via polling
- Inline buttons: **Taken** / **Remind in 5 min**
- Intake history saved to PostgreSQL
- Backend API + database + bot running via Docker Compose

### Version 2 — Polish & AI (Current)
- **Edit** medicine name/dosage
- **Delete** medicine (with cascade cleanup)
- **List** all medicines with their reminder times
- **Today's schedule** view (ascending order, hides past times)
- **Intake history** with grouped counts
- **Duplicate prevention** for same scheduled dose
- **Moscow timezone** (UTC+3) support
- **GigaChat AI** agent: answers medicine questions & parses natural-language requests
- All services **dockerized**
- Full **documentation** and **deployment guide**
- Pushed to GitHub as `se-toolkit-hackathon`

---

## Features

### Implemented ✅

| Feature | Command / Action |
|---------|-----------------|
| User registration | `/start` or any message |
| Add medicine | `/add` or type naturally |
| List medicines | `/medicines` or "My medicines" button |
| Edit medicine | `/edit` or "Edit / Delete" button |
| Delete medicine | Edit menu → Delete Medicine |
| Set reminder time | `/schedule` or "Set reminder" button |
| Delete reminder time | Edit menu → Delete Reminder → select time |
| Today's schedule | `/today` or "Today's schedule" button |
| Intake history | `/history` or "Intake history" button |
| Help | `/help` |
| Timely reminder messages | Automatic (Moscow time UTC+3) |
| Grouped reminders | One message per medicine (with count) |
| Taken / Remind in 5 min buttons | Inline keyboard |
| Persistent storage | PostgreSQL |
| Health check endpoint | `GET /api/health` |
| **AI assistant (GigaChat)** | Type any question or request |

### Not Yet Implemented 📋
- Snooze reminder functionality
- Statistics / adherence reports
- Web admin dashboard
- Webhook mode (currently uses polling)
- Multi-language support

---

## Architecture Overview

```
┌──────────────┐        ┌──────────────┐        ┌──────────────┐
│   Telegram   │  HTTP   │   FastAPI    │  SQL   │  PostgreSQL  │
│     Bot      │◄──────►│   Backend    │◄──────►│  Database    │
│  (aiogram)   │  API   │  (Python)    │  ORM   │              │
└──────┬───────┘        └──────────────┘        └──────────────┘
       │  Polls every 30s  ▲
       │  for reminders    │
       ├───────────────────┤
       │  GigaChat AI API  │
       │  (questions &     │
       │   natural parse)  │
       └───────────────────┘
```

### Components

- **Bot (aiogram)**: Telegram-facing client. Handles user messages, displays inline keyboards, runs a background scheduler (every 30s), and routes natural-language messages to GigaChat AI.
- **Backend (FastAPI)**: Owns all business logic and database access. Exposes REST API endpoints for users, medicines, schedules, intake history, and AI scheduling.
- **Database (PostgreSQL)**: Stores users, medicines, reminder schedules, and intake history with proper foreign key relationships and cascade deletes.
- **Scheduler**: Runs inside the bot process. Every 30 seconds, queries the backend for active schedules matching the current minute (Moscow time), creates pending intake records, and sends grouped reminder messages.
- **GigaChat AI Agent**: Parses natural-language medicine requests ("Add Aspirin at 08:00") and answers medicine-related questions.

### Design Decisions
- **Polling over Webhook**: Simpler setup, works behind NAT/firewalls, sufficient for a student project with 30-second check intervals.
- **Separate bot and backend containers**: Clean separation of concerns. Bot handles Telegram + AI, backend owns business logic and data.
- **SQLAlchemy ORM**: Type-safe queries, async support.
- **Moscow timezone (UTC+3)**: All reminders use Moscow time.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Bot Framework | aiogram 3.x (Python) |
| Backend API | FastAPI (Python) |
| Database | PostgreSQL 16 |
| ORM | SQLAlchemy 2.x (async) |
| AI Agent | GigaChat (Sber) |
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
│ f_name  │       │ dosage    │       │ is_active (bool)   │       │ medicine_name │
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
| `POST` | `/api/intakes/reschedule` | Reschedule intake (+5 min) |
| `GET` | `/api/intakes/pending-due` | Get due pending intakes |
| `GET` | `/api/intakes/user/{id}` | Get intake history |
| `GET` | `/api/intakes/today/{id}` | Get today's intakes |

---

## Bot Commands

| Command | Description |
|---------|-------------|
| `/start` | Register with the bot / show main menu |
| `/add` | Add a new medicine (interactive flow) |
| `/medicines` | List all medicines with reminder times |
| `/edit` | Edit medicine name or dosage |
| `/delete` | Delete a medicine and its reminders |
| `/schedule` | Add a reminder time for a medicine |
| `/today` | Show today's medicine schedule |
| `/history` | View recent intake history |
| `/help` | Show help message |
| *(any text)* | AI assistant — asks questions or adds medicines |

---

## AI Assistant (GigaChat)

The bot integrates **GigaChat** (Sber's LLM) for two purposes:

### 1. Medicine Questions
Type any question about medicines:
- *"What is Aspirin?"*
- *"What are the side effects of Ibuprofen?"*
- *"Can I take Paracetamol with coffee?"*

### 2. Natural-Language Medicine Addition
Describe what you need in plain text:
- *"Add Aspirin at 08:00 and Ibuprofen at 19:00"*
- *"I need to take Vitamin D 500mg every day at 7pm"*
- *"Remind me to drink water at 10:00"*

The AI parses the request, extracts medicine names, dosages, and times, then adds them automatically.

---

## Usage — Step by Step

1. **Start the bot**: Open Telegram, find your bot, send `/start`
2. **Add a medicine**: Tap "Add medicine" or type naturally: *"Add Aspirin at 08:00"*
3. **Set a reminder**: Tap "Set reminder" → select medicine → type time (e.g., `08:00`)
4. **Receive reminders**: At the scheduled time (Moscow time), the bot sends a grouped message
5. **Record intake**: Tap ✅ **Taken** or ⏰ **Remind in 5 min**
6. **View history**: Tap "Intake history" to see your recent records
7. **Ask questions**: Type anything like *"What is Vitamin D?"*

---

## Deployment

### Target OS
Ubuntu 24.04 VM

### Prerequisites
```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable docker
sudo systemctl start docker
```

### Quick Deploy

```bash
git clone https://github.com/YOUR_USERNAME/se-toolkit-hackathon.git
cd se-toolkit-hackathon

# .env is already configured with the bot token
docker compose up -d --build

# Verify
docker compose ps
curl http://localhost:8000/api/health
```

### Environment Variables

All settings are in `.env`:

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
docker compose up -d --build
docker compose logs -f
docker compose logs -f bot
docker compose logs -f backend
```

### Database Migrations

Tables are created automatically on first startup via the backend's `init_db.py` script.

### Restart

```bash
docker compose restart
docker compose restart bot
docker compose down
docker compose up -d --build
```

---

## ⚠️ Telegram Bot on University VMs

**Problem**: Telegram bot traffic is often **blocked on university VMs**.

**Solutions**:

### Option A: Deploy on a Non-University VM (Recommended)
Use a personal cloud VM (DigitalOcean, Hetzner, AWS, Oracle Cloud Free Tier).

### Option B: Local Bot + Remote Backend
- Run the **backend + database** on the VM
- Run the **bot** locally on your machine
- Update the bot's `BACKEND_URL` in `.env` to point to the VM's IP

---

## Repository Structure

```
se-toolkit-hackathon/
├── .env                        # Environment variables
├── .env.example                # Template
├── .gitignore
├── docker-compose.yml          # All 3 services: db, backend, bot
├── LICENSE                     # MIT
├── README.md                   # This file
│
├── backend/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/
│       ├── main.py             # FastAPI entry point
│       ├── core/config.py      # Application settings
│       ├── db/session.py       # Database session
│       ├── db/init_db.py       # Database initialization
│       ├── models/models.py    # SQLAlchemy ORM models
│       ├── schemas/schemas.py  # Pydantic schemas
│       ├── services/services.py # Business logic
│       └── api/endpoints.py    # REST API routes
│
├── bot/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/
│       ├── main.py             # Bot entry point
│       ├── config.py           # Bot settings
│       ├── handlers/
│       │   ├── router.py       # Command/callback routing
│       │   ├── start.py        # /start + main menu
│       │   ├── medicine.py     # Add/edit/list/delete
│       │   ├── schedule.py     # Set reminder times
│       │   ├── intake.py       # Intake history + buttons
│       │   └── ai.py           # GigaChat AI handler
│       └── services/
│           ├── backend_client.py  # HTTP client → backend API
│           ├── scheduler.py       # Reminder polling scheduler
│           └── gigachat.py        # GigaChat AI client
│
└── scripts/
    └── (deployment scripts)
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
- [GigaChat](https://developers.sber.ru/portal/products/gigachat-api) — Sber's large language model
