#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT_DIR/mydj-host"
CONFIG_PATH="$HOST_DIR/config.toml"
MODELS_DIR="$ROOT_DIR/models"

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker command not found"
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "[INFO] config.toml not found. Creating from all-in-one example..."
  cp "$HOST_DIR/config.allinone.toml.example" "$CONFIG_PATH"
fi

# models/ ディレクトリを事前作成（Docker がroot所有で作らないように）
mkdir -p "$MODELS_DIR"

# modelsディレクトリ内の必要ファイルを確認
MISSING=0
for REQUIRED in s2 s2-pro-q4_k_m.gguf tokenizer.json; do
  if [[ ! -f "$MODELS_DIR/$REQUIRED" ]]; then
    echo "[WARN] TTS file not found: models/$REQUIRED"
    MISSING=1
  fi
done
if [[ "$MISSING" -eq 1 ]]; then
  echo "       Place the required files in the models/ directory before using TTS."
  echo "       See README.md for instructions."
fi

cd "$ROOT_DIR"

GPU_ENABLED=0
GPU_ERR_LOG="$(mktemp)"

if docker compose -f docker-compose.all.yml -f docker-compose.gpu.yml up -d --build 2>"$GPU_ERR_LOG"; then
  GPU_ENABLED=1
else
  if grep -qiE 'could not select device driver "nvidia"|capabilities: \[\[gpu\]\]|no such device|unknown runtime.*nvidia|nvidia-container-runtime' "$GPU_ERR_LOG"; then
    echo "[WARN] NVIDIA runtime is not available. Falling back to CPU mode."
    echo "       To enable GPU, install NVIDIA Container Toolkit and restart Docker."
    docker compose -f docker-compose.all.yml up -d --build
  else
    cat "$GPU_ERR_LOG" >&2
    rm -f "$GPU_ERR_LOG"
    exit 1
  fi
fi

rm -f "$GPU_ERR_LOG"

echo "[OK] All services started"
echo "  - mydj-host: http://localhost:8000"
echo "  - ollama:    http://localhost:11434"
if [[ "$GPU_ENABLED" -eq 1 ]]; then
  echo "[INFO] Started with GPU profile (docker-compose.gpu.yml)."
else
  echo "[INFO] Started with CPU profile (docker-compose.all.yml)."
fi
echo "[NOTE] For first run, pull a model: docker exec -it voidfm-ollama ollama pull llama3.2:1b"
