#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT_DIR/mydj-host"
FISH_DIR="$ROOT_DIR/fish-speech"
CONFIG_PATH="$HOST_DIR/config.toml"

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker command not found"
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "[INFO] config.toml not found. Creating from all-in-one example..."
  cp "$HOST_DIR/config.allinone.toml.example" "$CONFIG_PATH"
fi

if [[ ! -d "$FISH_DIR" ]]; then
  if command -v git >/dev/null 2>&1; then
    echo "[INFO] fish-speech not found. Cloning..."
    git -C "$ROOT_DIR" clone https://github.com/fishaudio/fish-speech.git fish-speech
  else
    echo "[ERROR] fish-speech directory not found and git command is unavailable."
    echo "        Install git or place fish-speech/ manually."
    exit 1
  fi
fi

# fish-speech server requires writable references and checkpoints dirs
for DIR_PATH in "$FISH_DIR/references" "$FISH_DIR/checkpoints"; do
  mkdir -p "$DIR_PATH"
  if [[ ! -w "$DIR_PATH" ]]; then
    echo "[ERROR] $DIR_PATH is not writable by current user."
    echo "        Please fix permissions and run again:"
    echo "        sudo chown -R $(id -u):$(id -g) $DIR_PATH"
    exit 1
  fi
done

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

# quick post-check for fish-speech startup issues
sleep 2
FISH_STATE="$(docker inspect -f '{{.State.Status}}' voidfm-fish-speech 2>/dev/null || echo unknown)"
FISH_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' voidfm-fish-speech 2>/dev/null || echo '')"
if [[ "$FISH_STATE" != "running" ]] || [[ "$FISH_HEALTH" == "unhealthy" ]]; then
  echo "[WARN] fish-speech is not healthy yet (state=$FISH_STATE health=${FISH_HEALTH:-n/a})."
  echo "[INFO] Recent fish-speech logs:"
  docker logs --tail 60 voidfm-fish-speech || true
  echo "[HINT] If you see 'FileNotFoundError: checkpoints/s2-pro', download model checkpoints into fish-speech/checkpoints/s2-pro."
  echo "[HINT] If you see 'cudaGetDeviceCount ... Error 804', your NVIDIA driver is too old for CUDA 12.9 image."
  echo "       Update GPU driver (recommended), or run CPU mode until updated."
fi

echo "[OK] All services started"
echo "  - mydj-host:   http://localhost:8000"
echo "  - fish-speech: http://localhost:8080"
echo "  - ollama:      http://localhost:11434"
if [[ "$GPU_ENABLED" -eq 1 ]]; then
  echo "[INFO] Started with GPU profile (docker-compose.gpu.yml)."
else
  echo "[INFO] Started with CPU profile (docker-compose.all.yml)."
fi
echo "[NOTE] For first run, pull a model inside ollama container (example: llama3.2)."
