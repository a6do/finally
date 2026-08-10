# FinAlly — AI Trading Workstation

An AI-powered trading workstation that streams live market data, simulates
portfolio trading, and integrates a local LLM assistant able to analyze
positions and execute trades from natural language.

Built entirely by coding agents as a capstone project for an agentic AI coding
course. Full specification in [planning/PLAN.md](planning/PLAN.md).

## Status

Under construction. Two pieces work today:

- **Market data** — GBM simulator and Massive API client behind one interface,
  with an in-memory price cache and an async stream. 73 passing tests.
- **Ollama** — the local model that will back the AI chat, running as a service.

Not built yet: the FastAPI app and its endpoints, the database, the Next.js
frontend, the chat assistant, and the Dockerfile. There is no web UI —
`localhost:8000` serves nothing so far.

## Try What Exists

```bash
cd backend && uv run market_data_demo.py      # live terminal price dashboard
cd backend && uv run --extra dev pytest       # tests
```

```bash
./scripts/start_mac.sh                        # pulls qwen2.5:1.5b (~1GB) once

curl http://localhost:11434/api/chat -d '{
  "model": "qwen2.5:1.5b",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": false
}'
```

No API key needed. `./scripts/stop_mac.sh` stops the stack and keeps the model.

## Target Architecture

One app container on port 8000 alongside the Ollama service:

- **Frontend** — Next.js static export, TypeScript, Tailwind CSS
- **Backend** — FastAPI (Python/uv) with SSE streaming
- **Database** — SQLite, lazily initialized
- **AI** — local Ollama (`qwen2.5:1.5b`) with structured outputs; nothing leaves the machine
- **Market data** — built-in GBM simulator, or Massive API if a key is set

## Environment Variables

All optional; copy [.env.example](.env.example) to `.env` to change any.

| Variable | Read today | Description |
|---|---|---|
| `MASSIVE_API_KEY` | Yes | Massive (Polygon.io) key; omit to use the simulator |
| `OLLAMA_PORT` | Yes | Host port for the Ollama container (`11434`) |
| `OLLAMA_MODEL` | Yes | Model the start script pulls (`qwen2.5:1.5b`) |
| `OLLAMA_URL` | Not yet | Address the backend will use |
| `LLM_MOCK` | Not yet | `true` for deterministic mock LLM responses in tests |

## License

See [LICENSE](LICENSE).
