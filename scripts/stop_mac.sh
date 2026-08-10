#!/usr/bin/env bash
# Stops the FinAlly stack. No -v: the pulled model survives so the next start
# does not re-download it. Idempotent.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running; nothing to stop."
  exit 0
fi

docker compose down
echo "Stopped. The model volume was kept."
