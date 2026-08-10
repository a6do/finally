# FinAlly — AI Trading Workstation

An AI-powered trading workstation that streams live market data, simulates portfolio trading, and integrates a local LLM chat assistant able to analyze positions and execute trades from natural language.

Built entirely by coding agents as a capstone project for an agentic AI coding course.

## Status

Under construction. Two pieces work today:

- **Market data** — GBM simulator and Massive API client behind one interface, with an in-memory price cache and an async stream. 73 passing tests.
- **Ollama** — the local model that will back the AI chat, running as a service in the stack.

Not built yet: the FastAPI app and its endpoints, the database, the Next.js
frontend, the chat assistant, and the Dockerfile. There is no web UI to open —
`localhost:8000` serves nothing so far.

## Try What Exists

```bash
# Live-updating terminal dashboard of simulated prices
cd backend && uv run market_data_demo.py

# Tests
cd backend && uv run --extra dev pytest
```

```bash
# Start Ollama; pulls qwen2.5:1.5b (about 1GB) on first run
./scripts/start_mac.sh

# Ask it something
curl http://localhost:11434/api/chat -d '{
  "model": "qwen2.5:1.5b",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": false
}'
```

No API key needed. `./scripts/stop_mac.sh` stops the stack and keeps the
downloaded model.

## Target Architecture

The app will run in a single container on port 8000, alongside the Ollama
service:

- **Frontend**: Next.js (static export) with TypeScript and Tailwind CSS
- **Backend**: FastAPI (Python/uv) with SSE streaming
- **Database**: SQLite with lazy initialization
- **AI**: Ollama running locally (`qwen2.5:1.5b`) with structured outputs — no API key, no data leaves the machine
- **Market data**: Built-in GBM simulator (default) or Massive API (optional)

The full specification is in [planning/PLAN.md](planning/PLAN.md).

## Environment Variables

| Variable | Read today | Description |
|---|---|---|
| `MASSIVE_API_KEY` | Yes | Massive (Polygon.io) key for real market data; omit to use simulator |
| `OLLAMA_PORT` | Yes | Host port for the Ollama container; defaults to `11434` |
| `OLLAMA_MODEL` | Yes | Model the start script pulls; defaults to `qwen2.5:1.5b` |
| `OLLAMA_URL` | Not yet | Address the backend will use; the compose service by default |
| `LLM_MOCK` | Not yet | Set `true` for deterministic mock LLM responses (testing) |

## Project Structure

What exists now:

```
finally/
├── backend/     # uv project; market data module and tests
├── planning/    # Project documentation and agent contracts
├── scripts/     # Start/stop helpers
└── docker-compose.yml
```

PLAN.md adds `frontend/`, `test/`, and `db/` as the remaining work lands.

## License

See [LICENSE](LICENSE).
