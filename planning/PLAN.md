# FinAlly — AI Trading Workstation

## Project Specification

## 1. Vision

FinAlly (Finance Ally) is a visually stunning AI-powered trading workstation that streams live market data, lets users trade a simulated portfolio, and integrates an LLM chat assistant that can analyze positions and execute trades on the user's behalf. It looks and feels like a modern Bloomberg terminal with an AI copilot.

This is the capstone project for an agentic AI coding course. It is built entirely by Coding Agents demonstrating how orchestrated AI agents can produce a production-quality full-stack application. Agents interact through files in `planning/`.

## 2. User Experience

### First Launch

The user runs a single start script. It brings up both services, pulls the chat
model on first run — about 1GB, a few minutes on a normal connection, and a
no-op on every run after that — waits until the app and the model both answer,
and then opens a browser to `http://localhost:8000`. The browser opens when
chat works, not before: the user never sees a half-working terminal. No login,
no signup. They immediately see:

- A watchlist of 10 default tickers with live-updating prices in a grid
- $10,000 in virtual cash
- A dark, data-rich trading terminal aesthetic
- An AI chat panel ready to assist

### What the User Can Do

- **Watch prices stream** — prices flash green (uptick) or red (downtick) with subtle CSS animations that fade
- **View sparkline mini-charts** — price action beside each ticker in the watchlist, accumulated on the frontend from the SSE stream since page load (sparklines fill in progressively)
- **Click a ticker** to see a larger detailed chart in the main chart area
- **Buy and sell shares** — market orders only, instant fill at current price, no fees, no confirmation dialog
- **Monitor their portfolio** — a heatmap (treemap) showing positions sized by weight and colored by P&L, plus a P&L chart tracking total portfolio value over time
- **View a positions table** — ticker, quantity, average cost, current price, unrealized P&L, % change
- **Chat with the AI assistant** — ask about their portfolio, get analysis, and have the AI execute trades and manage the watchlist through natural language
- **Manage the watchlist** — add/remove tickers manually or via the AI chat

### Visual Design

- **Dark theme**: backgrounds around `#141414` or `#0d0d0d`, muted gray borders, no pure black
- **Price flash animations**: brief green/red background highlight on price change, fading over ~500ms via CSS transitions
- **Connection status indicator**: a small colored dot (green = connected, yellow = reconnecting, red = disconnected) visible in the header
- **Professional, data-dense layout**: inspired by Bloomberg/trading terminals — every pixel earns its place
- **Responsive but desktop-first**: optimized for wide screens, functional on tablet

### Color Scheme

The Egyptian flag: red, white, black, and the gold of the Eagle of Saladin.

- Red Primary: `#ce1126` (primary accent, active states, submit buttons)
- Gold Accent: `#c09300` (highlights, selected ticker, chart lines)
- White: `#ffffff` (primary text; muted grays for secondary text)
- Black Base: `#0d0d0d` panels on a `#141414` page background, muted gray borders — the flag's black band as a dark terminal, not pure black

## 3. Architecture Overview

### Two Services, One Port

The user faces a single port. Behind it are two containers, brought up together
by `docker compose`: the app, and Ollama from its official image.

```
docker compose
┌─────────────────────────────────────────────────┐
│  app (port 8000, published)                     │
│                                                 │
│  FastAPI (Python/uv)                            │
│  ├── /api/*          REST endpoints             │
│  ├── /api/stream/*   SSE streaming              │
│  └── /*              Static file serving         │
│                      (Next.js export)            │
│                                                 │
│  SQLite database (volume-mounted)               │
│  Background task: market data polling/sim        │
└──────────────────────┬──────────────────────────┘
                       │ http://ollama:11434
┌──────────────────────┴──────────────────────────┐
│  ollama (port 11434, published for host dev)    │
│  qwen2.5:1.5b in a named volume                 │
└─────────────────────────────────────────────────┘
```

Only the app is built from this repo; Ollama is pulled. The `11434` mapping is
published solely so the backend can also be run on the host with `uv run`
against the same model — nothing in the browser talks to Ollama directly.

- **Frontend**: Next.js with TypeScript, built as a static export (`output: 'export'`), served by FastAPI as static files
- **Backend**: FastAPI (Python), managed as a `uv` project
- **Database**: SQLite, single file at `db/finally.db`, volume-mounted for persistence
- **Real-time data**: Server-Sent Events (SSE) — simpler than WebSockets, one-way server→client push, works everywhere
- **AI integration**: Ollama running locally as a service in the stack, with structured outputs for trade execution
- **Market data**: Environment-variable driven — simulator by default, real data via Massive API if key provided

### Why These Choices

| Decision | Rationale |
|---|---|
| SSE over WebSockets | One-way push is all we need; simpler, no bidirectional complexity, universal browser support |
| Static Next.js export | Single origin, no CORS issues, one port, one app container, simple deployment |
| SQLite over Postgres | No auth = no multi-user = no need for a database server; self-contained, zero config |
| Two compose services | The app is one container; Ollama is the second, unmodified from its official image. Students still run one command — the start script wraps `docker compose up -d` |
| uv for Python | Fast, modern Python project management; reproducible lockfile; what students should learn |
| Market orders only | Eliminates order book, limit order logic, partial fills — dramatically simpler portfolio math |

---

## 4. Directory Structure

```
finally/
├── frontend/                 # Next.js TypeScript project (static export)
├── backend/                  # FastAPI uv project (Python)
│   └── db/                   # Schema definitions, seed data, migration logic
├── planning/                 # Project-wide documentation for agents
│   ├── PLAN.md               # This document
│   └── ...                   # Additional agent reference docs
├── scripts/
│   ├── start_mac.sh          # Bring up the stack (macOS/Linux)
│   └── start_windows.ps1     # Bring up the stack (Windows PowerShell)
├── test/                     # Playwright E2E tests + docker-compose.test.yml
├── db/                       # Volume mount target (SQLite file lives here at runtime)
│   └── .gitkeep              # Directory exists in repo; finally.db is gitignored
├── Dockerfile                # Multi-stage build (Node → Python) for the app service
├── docker-compose.yml        # The two services (app + ollama) — the entry point
├── .env                      # Environment variables (gitignored, .env.example committed)
└── .gitignore
```

### Key Boundaries

- **`frontend/`** is a self-contained Next.js project. It knows nothing about Python. It talks to the backend via `/api/*` endpoints and `/api/stream/*` SSE endpoints. Internal structure is up to the Frontend Engineer agent.
- **`backend/`** is a self-contained uv project with its own `pyproject.toml`. It owns all server logic including database initialization, schema, seed data, API routes, SSE streaming, market data, and LLM integration. Internal structure is up to the Backend/Market Data agents.
- **`backend/db/`** contains schema SQL definitions and seed logic. The backend lazily initializes the database on first request — creating tables and seeding default data if the SQLite file doesn't exist or is empty.
- **`db/`** at the top level is the runtime volume mount point. The SQLite file (`db/finally.db`) is created here by the backend and persists across container restarts via Docker volume.
- **`planning/`** contains project-wide documentation, including this plan. All agents reference files here as the shared contract.
- **`test/`** contains Playwright E2E tests and supporting infrastructure (e.g., `docker-compose.test.yml`). Unit tests live within `frontend/` and `backend/` respectively, following each framework's conventions.
- **`scripts/`** contains the start scripts — thin wrappers around `docker compose up -d`, the model pull, and a readiness wait. Stopping is `docker compose down`, documented in the README; there are no stop scripts to keep in sync.

---

## 5. Environment Variables

```bash
# Optional: Ollama address. Defaults to the compose service name; set to
# http://localhost:11434 when running the backend directly with uv run
OLLAMA_URL=http://ollama:11434

# Optional: the local model used for chat
OLLAMA_MODEL=qwen2.5:1.5b

# Optional: host port published for the Ollama container. Only needed to avoid
# a clash with an Ollama already running on the host
OLLAMA_PORT=11434

# Optional: Massive (Polygon.io) API key for real market data
# If not set, the built-in market simulator is used (recommended for most users)
MASSIVE_API_KEY=

# Optional: Set to "true" for deterministic mock LLM responses (testing)
LLM_MOCK=false
```

No API key is required. The LLM runs locally in Ollama, brought up as part of
the stack by `scripts/start_mac.sh`.

### Behavior

- If `MASSIVE_API_KEY` is set and non-empty → backend uses Massive REST API for market data
- If `MASSIVE_API_KEY` is absent or empty → backend uses the built-in market simulator
- If `LLM_MOCK=true` → backend returns deterministic mock LLM responses (for E2E tests)
- The backend reads `.env` from the project root (mounted into the container or read via docker `--env-file`)

---

## 6. Market Data

### Two Implementations, One Interface

Both the simulator and the Massive client implement the same abstract interface. The backend selects which to use based on the environment variable. All downstream code (SSE streaming, price cache, frontend) is agnostic to the source.

### Simulator (Default)

- Generates prices using geometric Brownian motion (GBM) with configurable drift and volatility per ticker
- Updates at ~500ms intervals
- Correlated moves across tickers (e.g., tech stocks move together)
- Occasional random "events" — sudden 2-5% moves on a ticker for drama
- Starts from realistic seed prices (e.g., AAPL ~$190, GOOGL ~$175, etc.)
- Runs as an in-process background task — no external dependencies

### Ticker Universe

Only tickers in a static allowlist can be watched or traded. The allowlist is
exactly the set of symbols with seed prices in the market module — currently
ten, to be expanded to roughly forty well-known US large caps. Anything else is
rejected at the API boundary with a 400.

This is load-bearing, not tidiness. The simulator will happily invent a price
for any string handed to it, so without an allowlist `BANANA` becomes a
tradable stock with a plausible chart — and the LLM's `watch_add` puts that one
hallucinated symbol away from a real position, in a flow that executes without
confirmation. The allowlist also makes the two data sources behave the same
way: unknown symbols are refused identically whether the simulator or Massive
is running, instead of one inventing a price and the other returning an API
error.

Every symbol on the allowlist has a seed price and GBM parameters, so the
simulator's random-price fallback for unseeded tickers becomes unreachable in
normal operation.

### Massive API (Optional)

- REST API polling (not WebSocket) — simpler, works on all tiers
- Polls for the union of all watched tickers on a configurable interval
- Free tier (5 calls/min): poll every 15 seconds
- Paid tiers: poll every 2-15 seconds depending on tier
- Parses REST response into the same format as the simulator
- Outside market hours real prices do not move: the grid sits still and no SSE events flow, while the connection indicator stays correctly green. Expected behavior, not a fault — the simulator is the default for a reason

### Shared Price Cache

- A single background task (simulator or Massive poller) writes to an in-memory price cache
- The cache holds the latest price, previous price, and timestamp for each ticker
- The cache also records the **session open** — the first price it ever saw for a ticker — which is the baseline for the change percentage the UI displays (see section 10). It is set once per ticker per backend process and never updated
- SSE streams read from this cache and push updates to connected clients
- This architecture supports future multi-user scenarios without changes to the data layer

### Which Tickers Are Tracked

The tracked set is the watchlist **union the tickers with a non-zero position**.

Positions must keep receiving prices even after their ticker leaves the
watchlist, or portfolio value silently freezes at the last price seen while the
position still counts toward the total. Removing NVDA from the watchlist while
holding NVDA hides the row; it does not stop the price. The watchlist panel
renders the watchlist only.

### SSE Streaming

- Endpoint: `GET /api/stream/prices`
- Long-lived SSE connection; client uses native `EventSource` API
- Pushes are **change-driven, at most every 500ms**: the server polls the cache on a 500ms loop and emits only when prices actually changed. Under the simulator that is a steady half-second stream; under Massive on the free tier it is one event every 15 seconds
- Because the gap between events can be long, the server emits an SSE comment frame as a keepalive after 15 seconds of silence, so proxies and browsers do not treat an idle connection as dead
- Each SSE event contains ticker, price, previous price, session open, timestamp, and change direction, for every tracked ticker
- Client handles reconnection automatically (EventSource has built-in retry)

---

## 7. Database

### SQLite with Lazy Initialization

The backend checks for the SQLite database on startup (or first request). If the file doesn't exist or tables are missing, it creates the schema and seeds default data. This means:

- No separate migration step
- No manual database setup
- Fresh Docker volumes start with a clean, seeded database automatically

### Access Rules

Request handlers and the 30-second snapshot task write the same file from the
same process, so a few rules are fixed here rather than discovered as an
intermittent "database is locked" mid-demo:

- **WAL mode**, enabled once at initialization
- **A connection per operation.** `sqlite3.connect` on a local file is cheap; no pooling, no long-lived shared handle
- **Short transactions.** Read prices from the cache first, then open the write
- **All SQL lives in `backend/db/`.** No queries in route handlers
- **Nothing blocking on the event loop.** Route handlers that touch the database are defined with `def` so FastAPI runs them in its threadpool; the async snapshot task uses `asyncio.to_thread`

### Schema

All tables include a `user_id` column defaulting to `"default"`. This is hardcoded for now (single-user) but enables future multi-user support without schema migration.

Tickers are stored uppercase, normalized once at the API boundary (section 8),
so `UNIQUE(user_id, ticker)` means what it appears to mean and `aapl` cannot
become a second row beside `AAPL`. Quantities are `REAL` throughout: fractional
shares are accepted everywhere they can be entered — the trade bar and the chat
assistant both — with the single rule that the quantity must parse to a number
greater than zero.

**users_profile** — User state (cash balance)
- `id` TEXT PRIMARY KEY (default: `"default"`)
- `cash_balance` REAL (default: `10000.0`)
- `created_at` TEXT (ISO timestamp)

**watchlist** — Tickers the user is watching
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `ticker` TEXT
- `added_at` TEXT (ISO timestamp)
- UNIQUE constraint on `(user_id, ticker)`

**positions** — Current holdings (one row per ticker per user)
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `ticker` TEXT
- `quantity` REAL (fractional shares supported)
- `avg_cost` REAL
- `updated_at` TEXT (ISO timestamp)
- UNIQUE constraint on `(user_id, ticker)`

**trades** — Trade history (append-only log)
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `ticker` TEXT
- `side` TEXT (`"buy"` or `"sell"`)
- `quantity` REAL (fractional shares supported)
- `price` REAL
- `executed_at` TEXT (ISO timestamp)

**portfolio_snapshots** — Portfolio value over time (for P&L chart). Recorded every 30 seconds by a background task, and immediately after each trade execution.
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `total_value` REAL
- `recorded_at` TEXT (ISO timestamp)

**chat_messages** — Conversation history with LLM
- `id` TEXT PRIMARY KEY (UUID)
- `user_id` TEXT (default: `"default"`)
- `role` TEXT (`"user"` or `"assistant"`)
- `content` TEXT
- `actions` TEXT (JSON — trades executed, watchlist changes made; null for user messages)
- `created_at` TEXT (ISO timestamp)

### Default Seed Data

- One user profile: `id="default"`, `cash_balance=10000.0`
- Ten watchlist entries: AAPL, GOOGL, MSFT, AMZN, TSLA, NVDA, META, JPM, V, NFLX

---

## 8. API Endpoints

### Market Data
| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/stream/prices` | SSE stream of live price updates |

### Portfolio
| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/portfolio` | Current positions, cash balance, total value, unrealized P&L |
| POST | `/api/portfolio/trade` | Execute a trade: `{ticker, quantity, side}` |
| GET | `/api/portfolio/history` | Portfolio value snapshots over time (for P&L chart) |

### Watchlist
| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/watchlist` | Current watchlist tickers with latest prices |
| POST | `/api/watchlist` | Add a ticker: `{ticker}` |
| DELETE | `/api/watchlist/{ticker}` | Remove a ticker |

### Chat
| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/chat` | Send a message, receive complete JSON response (message + executed actions) |
| GET | `/api/chat/history` | Past conversation, oldest first, so a page reload restores the panel |

### System
| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check (for Docker/deployment) |

### Conventions

**Ticker normalization.** Every endpoint that accepts a ticker uppercases and
strips it before anything else touches it, in one shared dependency. Tickers
outside the allowlist (section 6) are refused here, so no invalid symbol
reaches the market module, the database, or the trade path.

**Errors.** Insufficient cash, overselling, an unknown ticker, and a
non-positive quantity are ordinary expected outcomes, not exceptions:

- `400` with `{"detail": "<human-readable reason>"}` — the frontend renders `detail` verbatim in the trade bar
- `404` with the same shape — only for removing a watchlist ticker that is not there
- `200` — everything else

`/api/chat` is the exception: it always returns `200`. A rejected action is not
a failed request, it is something the assistant needs to tell the user about,
so the reason travels inside the chat response (section 9).

---

## 9. LLM Integration

When writing code to make calls to LLMs, use the `ollama-local` skill: HTTP to a
local Ollama instance running as a service in the stack, using its `format`
parameter for structured outputs. No API key and no network egress.

The model is `qwen2.5:1.5b` — about 1GB, answering in well under two seconds on
CPU. It is small, and the schema below is shaped around that fact.

### How It Works

When the user sends a chat message, the backend:

1. Loads the user's current portfolio context (cash, positions with P&L, watchlist with live prices, total portfolio value)
2. Loads the **last 6 messages** from the `chat_messages` table — three exchanges. The cap is a fixed number rather than "recent" because with a 1.5b model more context measurably degrades the answer; history is short and dropped in verbatim
3. Constructs a prompt with a system message, portfolio context, conversation history, and the user's new message
4. Calls Ollama's `/api/chat` with `format` set to the schema below, `stream: false`, and `temperature: 0`, per the `ollama-local` skill
5. Parses the structured JSON response, tolerating truncated output, and substitutes the fallback text below if `message` is missing or empty
6. Validates the proposed action against real state, then auto-executes it
7. Stores the message and executed actions in `chat_messages`
8. Returns the complete JSON response to the frontend (no token-by-token streaming — a loading indicator covers the roughly two seconds local CPU inference takes)

### Structured Output Schema

The schema is passed to Ollama as `format`, and the response comes back as JSON
matching it:

```json
{
  "message": "Your conversational response to the user",
  "action": "buy",
  "ticker": "AAPL",
  "quantity": "10"
}
```

- `message`: The conversational text shown to the user
- `action`: One of `buy`, `sell`, `watch_add`, `watch_remove`, `none` — an enum, so the model cannot invent a verb
- `ticker`: The symbol the action applies to
- `quantity`: Share count **as a string**, parsed by the backend; only meaningful for `buy` and `sell`

This is flat and single-action by design, and it differs from what a large
hosted model would be given. The `ollama-local` skill records four constraints
learned from measuring small models, and this schema follows all of them:

- **No `required`.** A required field makes the model invent a value it does not have. Absent keys are the signal that there is nothing to do.
- **No arrays.** Given an array field, a small model free-runs and fills it with plausible-looking entries nobody asked for. One action per turn instead; a user wanting three trades gets three turns.
- **No numeric fields.** `quantity` is a string because small models mangle numbers — the skill records `"five years"` coming back as `5000000000000000`. The backend parses it and rejects what does not parse.
- **Narrow.** Few fields, asked for one turn at a time.

If the single-action limit proves too tight in practice, the fix is a larger
model, not an array field.

Dropping `required` applies to `message` as well, so it too can come back
missing. When it does, the backend substitutes a fixed string — "Sorry, I could
not put that into words. Try asking again." — and still reports any executed
action inline. A blank assistant bubble is the one outcome this design must
never produce.

### Auto-Execution

Trades specified by the LLM execute automatically — no confirmation dialog. This is a deliberate design choice:
- It's a simulated environment with fake money, so the stakes are zero
- It creates an impressive, fluid demo experience
- It demonstrates agentic AI capabilities — the core theme of the course

If a trade fails validation (e.g., insufficient cash), the error is included in the chat response so the LLM can inform the user.

Auto-execution puts weight on validation that a confirmation dialog would
otherwise carry, and `format` constrains the shape of the response, not its
truth. A model-invented ticker or quantity must never reach the trade path, so
each action carries its own precondition:

| Action | Must hold before it executes |
|---|---|
| `buy` / `sell` | Ticker is on the allowlist **and** has a live price in the cache; quantity parses to a number greater than zero; the trade clears exactly the checks a manual trade does (cash on hand, shares owned) |
| `watch_add` | Ticker is on the allowlist. It is by definition not yet in the price cache, so the cache check cannot apply here — the allowlist is the whole guard |
| `watch_remove` | Ticker is currently on the watchlist |
| `none` | Nothing to do; reply with the message alone |

Actions go through the same functions the REST endpoints call — no second
implementation of trade logic for the chat path. When a precondition fails,
nothing executes, the reason is appended to the assistant's message so the user
learns what went wrong, and the request still returns `200`.

### System Prompt Guidance

The LLM should be prompted as "FinAlly, an AI trading assistant" with instructions to:
- Analyze portfolio composition, risk concentration, and P&L
- Suggest trades with reasoning
- Execute trades when the user asks or agrees
- Manage the watchlist proactively
- Be concise and data-driven in responses
- Take at most one action per reply, leaving `action` as `none` when only answering a question
- Never state a figure that is not in the supplied portfolio context

The system prompt matters more with a 1.5b model than it would with a large
hosted one: keep it short and concrete, since a long prompt full of conditionals
degrades small-model output rather than improving it.

### LLM Mock Mode

When `LLM_MOCK=true`, the backend returns deterministic mock responses instead of calling Ollama. This enables:
- Fast, reproducible E2E tests, with no dependence on model output varying between runs
- Development and CI without pulling a 1GB model or running the Ollama service

The mock is a contract between the backend and the E2E suite, not an
implementation detail — an E2E scenario asserting that "trade execution appears
inline" only passes if the mock emits an action. It matches the user's message
against these patterns, case-insensitively, first match wins, and returns the
corresponding structured response:

| User message matches | Response |
|---|---|
| `buy <number> <ticker>` | `action: buy` with that ticker and quantity; message `"Buying <qty> <ticker>."` |
| `sell <number> <ticker>` | `action: sell` with that ticker and quantity; message `"Selling <qty> <ticker>."` |
| `watch <ticker>` or `add <ticker>` | `action: watch_add`; message `"Added <ticker> to your watchlist."` |
| `unwatch <ticker>` or `remove <ticker>` | `action: watch_remove`; message `"Removed <ticker> from your watchlist."` |
| anything else | `action: none`; message `"Mock assistant: LLM_MOCK is enabled."` |

Mock responses pass through the same validation and execution path as real
ones, so an invalid ticker in mock mode fails exactly as it would in
production.

---

## 10. Frontend Design

### Layout

The frontend is a single-page application with a dense, terminal-inspired layout. The specific component architecture and layout system is up to the Frontend Engineer, but the UI should include these elements:

- **Watchlist panel** — grid/table of watched tickers with: ticker symbol, current price (flashing green/red on change), change % since the session open, and a sparkline mini-chart (accumulated from SSE since page load)
- **Main chart area** — larger chart for the currently selected ticker, with at minimum price over time. Clicking a ticker in the watchlist selects it here.
- **Portfolio heatmap** — treemap visualization where each rectangle is a position, sized by portfolio weight, colored by P&L (green = profit, red = loss)
- **P&L chart** — line chart showing total portfolio value over time, using data from `portfolio_snapshots`
- **Positions table** — tabular view of all positions: ticker, quantity, avg cost, current price, unrealized P&L, % change
- **Trade bar** — simple input area: ticker field, quantity field, buy button, sell button. Market orders, instant fill.
- **AI chat panel** — docked/collapsible sidebar. Message input, scrolling conversation history, loading indicator while waiting for LLM response. Trade executions and watchlist changes shown inline as confirmations.
- **Header** — portfolio total value (updating live), connection status indicator, cash balance

### Two Details Worth Fixing Here

**The change column is a session change, not a daily change.** There is no
previous close anywhere in the system, and inventing one is not worth the
complexity. The baseline is the session open the backend records the first time
it sees a ticker (section 6), which arrives in every SSE event. Label the
column `Chg %`, not `Day %` — it is honest, it survives a page reload, and it
resets to 0.00% when the backend restarts, which is exactly what it claims to
measure.

**The frontend owns the live header total.** There is no portfolio SSE stream.
Between REST calls the frontend recomputes total value as cash plus the sum of
each held quantity times its streamed price, so the header ticks along with the
prices. `/api/portfolio` remains the authority: the frontend refetches it after
every trade and reconciles. Cash changes only through trades, so it never needs
interpolating.

### Technical Notes

- Use `EventSource` for SSE connection to `/api/stream/prices`
- Canvas-based charting library preferred (Lightweight Charts or Recharts) for performance
- Price flash effect: on receiving a new price, briefly apply a CSS class with background color transition, then remove it
- All API calls go to the same origin (`/api/*`) — no CORS configuration needed
- Tailwind CSS for styling with a custom dark theme
- The trade bar accepts fractional quantities; it rejects nothing the backend would accept, and renders the `detail` string from a `400` as the error message
- On load, fetch `/api/chat/history` to repopulate the chat panel
- With `MASSIVE_API_KEY` set, prices are still outside market hours and the grid will not move. Do not treat a motionless grid as a dropped connection — the status dot reflects the SSE connection, not price activity

### Development Loop

The static export is the production artifact, not the way anyone develops
against this. Locally the frontend runs `next dev` on port 3000 with a
`rewrites` rule proxying `/api/*` to a backend on `http://localhost:8000`,
which keeps the same-origin assumption true in development. That backend can be
run directly with `uv run` against the Ollama container, which is why compose
publishes port 11434.

---

## 11. Docker & Deployment

### Multi-Stage Dockerfile

```
Stage 1: Node 20 slim
  - Copy frontend/
  - npm install && npm run build (produces static export)

Stage 2: Python 3.12 slim
  - Install uv
  - Copy backend/
  - uv sync (install Python dependencies from lockfile)
  - Copy frontend build output into a static/ directory
  - Expose port 8000
  - CMD: uvicorn serving FastAPI app
```

FastAPI serves the static frontend files and all API routes on port 8000. Only
this service is built here; `ollama` is the official image, unmodified.

### Running the Stack

`docker-compose.yml` defines both services and is the entry point:

```bash
docker compose up -d      # start
docker compose down       # stop, keeping both volumes
```

The app reaches the model over the compose network at `http://ollama:11434`,
which is the default for `OLLAMA_URL`. Port 11434 is also published to the host
so the backend can be run directly with `uv run` against the same model; that
mapping is a development convenience, nothing in the browser uses it.

### Volumes

Two named volumes, neither removed by `docker compose down`:

- **`finally-data`** → `/app/db` in the app container. The backend writes `finally.db` here, so the portfolio survives restarts
- **`ollama`** → the pulled model. Never discard it casually: throwing it away means downloading a gigabyte again

### Resources

Ollama in Docker on macOS is **CPU-only** — Docker Desktop offers no GPU
passthrough, which is why the model is a 1.5b one and why "under two seconds"
in section 9 is a CPU figure. Give Docker Desktop at least 4GB of memory;
roughly 2GB of that is the model.

### Start Scripts

**`scripts/start_mac.sh`** (macOS/Linux), with **`scripts/start_windows.ps1`**
as the PowerShell equivalent:

- Checks Docker is running and fails with a readable message if not
- `docker compose up -d --build`
- Pulls `OLLAMA_MODEL` inside the Ollama container — about 1GB the first time, a no-op afterwards
- Waits until both the app's `/api/health` and Ollama answer
- Prints the URL and opens the browser

Both scripts are idempotent. Stopping is `docker compose down`, documented in
the README — a stop script would be a one-line wrapper that can only drift out
of sync with what it wraps.

### Optional Cloud Deployment

The app container is designed to deploy to AWS App Runner, Render, or any container platform. A Terraform configuration for App Runner may be provided in a `deploy/` directory as a stretch goal, but is not part of the core build. Note that a cloud deployment has to answer the Ollama question separately — a second service, or a hosted model behind the same `OLLAMA_URL` — which is one more reason it stays a stretch goal.

---

## 12. Testing Strategy

### Unit Tests (within `frontend/` and `backend/`)

**Backend (pytest)**:
- Market data: simulator generates valid prices, GBM math is correct, Massive API response parsing works, both implementations conform to the abstract interface
- Ticker rules: the allowlist rejects unknown symbols, lowercase input is normalized, the session open is recorded once and never moves
- Tracked set: a ticker removed from the watchlist while a position is held keeps streaming; with the position closed it stops
- Portfolio: trade execution logic, P&L calculations, edge cases (selling more than owned, buying with insufficient cash, selling at a loss, fractional quantities)
- LLM: structured output parsing handles all valid schemas, graceful handling of malformed responses, the fallback message when `message` is absent, per-action validation (including `watch_add`, which is allowlist-checked rather than cache-checked), and the `LLM_MOCK` pattern table
- API routes: correct status codes, response shapes, `{"detail": ...}` on `400`, and `/api/chat` returning `200` even when the proposed action is rejected

**Frontend (React Testing Library or similar)**:
- Component rendering with mock data
- Price flash animation triggers correctly on price changes
- Watchlist CRUD operations
- Portfolio display calculations
- Chat message rendering and loading state

### E2E Tests (in `test/`)

**Infrastructure**: A separate `docker-compose.test.yml` in `test/` that spins up the app container plus a Playwright container. This keeps browser dependencies out of the production image.

**Environment**: Tests run with `LLM_MOCK=true` by default for speed and determinism.

**Key Scenarios**:
- Fresh start: default watchlist appears, $10k balance shown, prices are streaming
- Add and remove a ticker from the watchlist
- Buy shares: cash decreases, position appears, portfolio updates
- Sell shares: cash increases, position updates or disappears
- Portfolio visualization: heatmap renders with correct colors, P&L chart has data points
- AI chat (mocked): send `buy 5 AAPL`, receive the mock response, trade execution appears inline and the position table updates
- Chat history survives a reload: send a message, reload, the conversation is still there
- Rejected input: an unknown ticker in the trade bar shows the backend's `detail` string
- SSE resilience: disconnect and verify reconnection

---

## 13. Decisions from Review

A documentation review of this plan against the shipped code raised a set of
contradictions and undecided questions. All of them are now settled in the
sections above; this is the index, so nobody re-opens a closed question.

| Question | Decision | Section |
|---|---|---|
| "Single container" contradicted the Ollama service | Two compose services; `docker compose up -d` is the entry point; the `docker run` example is gone | 3, 4, 11 |
| First launch is no longer instant | Start script pulls the model, waits for both services, then opens the browser | 2, 11 |
| SSE cadence described as fixed | Change-driven, at most every 500ms, with a keepalive comment after 15s of silence | 6 |
| Cache-existence guard impossible for `watch_add` | Per-action precondition table; `watch_add` is allowlist-checked | 9 |
| No source for "daily change %" | Session open recorded by the cache, streamed in every event; the column is `Chg %` | 6, 10 |
| Any string became a tradable stock | Static allowlist, equal to the seeded symbols, enforced at the API boundary | 6, 8 |
| Held tickers went stale once unwatched | Tracked set is watchlist union non-zero positions | 6 |
| Chat history written but unreadable | `GET /api/chat/history`, fetched on load | 8, 10 |
| "Recent" history undefined | Last 6 messages | 9 |
| `LLM_MOCK` behavior undefined | Pattern table fixed as a contract with the E2E suite | 9 |
| `message` may be absent | Fixed fallback string; never a blank bubble | 9 |
| No error contract | `400` with `{"detail": ...}`; `/api/chat` always `200` | 8 |
| Live header total unowned | Frontend interpolates from streamed prices; `/api/portfolio` is the authority | 10 |
| SQLite write concurrency unaddressed | WAL, connection per operation, short transactions, threadpool | 7 |
| Frontend dev loop unspecified | `next dev` on 3000 with rewrites to `:8000` | 10 |
| Fractional shares ambiguous | Accepted in both paths; quantity must parse to a number above zero | 7 |
| Ticker case not normalized | Uppercased once at the API boundary | 7, 8 |
| `OLLAMA_PORT` undocumented | Added | 5 |
| Four start/stop scripts | Two start scripts; stopping is `docker compose down` | 4, 11 |
| Ollama performance expectations | CPU-only on macOS, 4GB for Docker Desktop, of which ~2GB is the model | 9, 11 |
| Frozen grid outside market hours | Documented as expected behavior of the Massive source | 6, 10 |

### Still Outstanding

- **`.env.example`** is committed (matching section 5) but the repo's own `docker-compose.yml`, `scripts/start_mac.sh`, and `scripts/stop_mac.sh` still describe the host-run world. They need to catch up with section 11: an `app` service, and `stop_mac.sh` deleted in favor of `docker compose down`.
- **The allowlist needs its symbols.** Section 6 commits to roughly forty; the market module currently seeds ten. Whoever expands `SEED_PRICES` sets the universe.

