#!/usr/bin/env bash
# Starts the FinAlly stack and waits until the model answers. Idempotent.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORT="${OLLAMA_PORT:-11434}"
export OLLAMA_PORT="$PORT"
MODEL="${OLLAMA_MODEL:-qwen2.5:1.5b}"

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start Docker Desktop and try again." >&2
  exit 1
fi

echo "Starting Ollama on port $PORT ..."
docker compose up -d

# Downloads about 1GB the first time and is a no-op afterwards, because the
# model is kept in a named volume that stop_mac.sh leaves alone.
echo "Making sure the $MODEL model is present ..."
docker compose exec -T ollama ollama pull "$MODEL"

echo -n "Waiting for Ollama to answer "
for _ in $(seq 1 60); do
  if curl -fs "http://localhost:$PORT/api/tags" >/dev/null 2>&1; then
    echo
    echo "Ollama is running at http://localhost:$PORT"
    # No app service yet: there is no FastAPI app to start. Point at what runs.
    echo "Try the market data demo: cd backend && uv run market_data_demo.py"
    exit 0
  fi
  echo -n "."
  sleep 1
done

echo
echo "Ollama did not come up in 60 seconds. Recent logs:" >&2
docker compose logs --tail 40 >&2
exit 1
