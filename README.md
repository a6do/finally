# FinAlly — AI Trading Workstation

A visually stunning AI-powered trading workstation that streams live market data, simulates portfolio trading, and integrates an LLM chat assistant that can analyze positions and execute trades via natural language.

Built entirely by coding agents as a capstone project for an agentic AI coding course.

## Features

- **Live price streaming** via SSE with green/red flash animations
- **Simulated portfolio** — $10k virtual cash, market orders, instant fills
- **Portfolio visualizations** — heatmap (treemap), P&L chart, positions table
- **AI chat assistant** — analyzes holdings, suggests and auto-executes trades
- **Watchlist management** — track tickers manually or via AI
- **Dark terminal aesthetic** — Bloomberg-inspired, data-dense layout

## Architecture

The app runs in a single container on port 8000, alongside an Ollama service
that hosts the local model:

- **Frontend**: Next.js (static export) with TypeScript and Tailwind CSS
- **Backend**: FastAPI (Python/uv) with SSE streaming
- **Database**: SQLite with lazy initialization
- **AI**: Ollama running locally (`qwen2.5:1.5b`) with structured outputs — no API key, no data leaves the machine
- **Market data**: Built-in GBM simulator (default) or Massive API (optional)

## Quick Start

```bash
# Starts Ollama and pulls the model (about 1GB, first run only)
./scripts/start_mac.sh

# Open http://localhost:8000
```

No API key needed. `./scripts/stop_mac.sh` stops the stack and keeps the
downloaded model.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `OLLAMA_URL` | No | Ollama address; defaults to the compose service. Use `http://localhost:11434` when running the backend with `uv run` |
| `OLLAMA_MODEL` | No | Local chat model; defaults to `qwen2.5:1.5b` |
| `MASSIVE_API_KEY` | No | Massive (Polygon.io) key for real market data; omit to use simulator |
| `LLM_MOCK` | No | Set `true` for deterministic mock LLM responses (testing) |

## Project Structure

```
finally/
├── frontend/    # Next.js static export
├── backend/     # FastAPI uv project
├── planning/    # Project documentation and agent contracts
├── test/        # Playwright E2E tests
├── db/          # SQLite volume mount (runtime)
└── scripts/     # Start/stop helpers
```

## License

See [LICENSE](LICENSE).
