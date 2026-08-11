# FinAlly — AI Trading Workstation

A visually stunning AI-powered trading workstation that streams live market data, simulates portfolio trading, and integrates an LLM chat assistant that can analyze positions and execute trades via natural language.

Built entirely by coding agents as a capstone project for an agentic AI coding course. See [`planning/PLAN.md`](planning/PLAN.md) for the full project specification.

## Project Status

This project is under active development. Progress so far:

| Component | Status |
|---|---|
| Market data (simulator + Massive API + SSE cache) | ✅ Complete — see [`planning/MARKET_DATA_SUMMARY.md`](planning/MARKET_DATA_SUMMARY.md) |
| Database (SQLite schema, portfolio, trades, watchlist, chat) | 🚧 Not yet started |
| Backend API routes (`/api/portfolio`, `/api/watchlist`, `/api/chat`) | 🚧 Not yet started |
| AI chat integration (LiteLLM → OpenRouter/Cerebras) | 🚧 Not yet started |
| Frontend (Next.js trading terminal UI) | 🚧 Not yet started |
| Docker packaging & start/stop scripts | 🚧 Not yet started |
| E2E tests | 🚧 Not yet started |

The sections below describe the target end state of the product per the project plan; only the market data backend is currently implemented and runnable.

## Features (target)

- **Live price streaming** via SSE with green/red flash animations
- **Simulated portfolio** — $10k virtual cash, market orders, instant fills
- **Portfolio visualizations** — heatmap (treemap), P&L chart, positions table
- **AI chat assistant** — analyzes holdings, suggests and auto-executes trades
- **Watchlist management** — track tickers manually or via AI
- **Dark terminal aesthetic** — Bloomberg-inspired, data-dense layout

## Architecture (target)

Single Docker container serving everything on port 8000:

- **Frontend**: Next.js (static export) with TypeScript and Tailwind CSS
- **Backend**: FastAPI (Python/uv) with SSE streaming
- **Database**: SQLite with lazy initialization
- **AI**: LiteLLM → OpenRouter (Cerebras inference) with structured outputs
- **Market data**: Built-in GBM simulator (default) or Massive API (optional) — implemented

## Running What Exists Today

There's no Docker image or frontend yet, so the app as a whole doesn't run end-to-end. You can, however, run the backend's market data subsystem directly:

```bash
cd backend
uv sync --extra dev

# Live terminal dashboard with simulated prices
uv run market_data_demo.py

# Run the test suite
uv run pytest -v
```

See [`backend/README.md`](backend/README.md) and [`backend/CLAUDE.md`](backend/CLAUDE.md) for details on the market data API.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `OPENROUTER_API_KEY` | Yes (once AI chat is built) | OpenRouter API key for AI chat |
| `MASSIVE_API_KEY` | No | Massive (Polygon.io) key for real market data; omit to use simulator |
| `LLM_MOCK` | No | Set `true` for deterministic mock LLM responses (testing) |

## Project Structure

```
finally/
├── backend/     # FastAPI uv project (market data subsystem implemented)
├── planning/    # Project documentation and agent contracts
└── ...          # frontend/, test/, db/, scripts/, Dockerfile still to come
```

## License

See [LICENSE](LICENSE).
