#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT_DIR/mydj-host"
CONFIG_PATH="$HOST_DIR/config.toml"

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker command not found"
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "[INFO] config.toml not found. Creating from all-in-one example..."
  cp "$HOST_DIR/config.allinone.toml.example" "$CONFIG_PATH"
fi

cd "$ROOT_DIR"
docker compose -f docker-compose.all.yml up -d --build

echo "[OK] All services started"
echo "  - mydj-host:   http://localhost:8000"
echo "  - fish-speech: http://localhost:8080"
echo "  - ollama:      http://localhost:11434"
echo "[NOTE] For first run, pull a model inside ollama container (example: llama3.2)."
