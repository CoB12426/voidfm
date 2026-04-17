#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT_DIR/mydj-host"
CONFIG_PATH="$HOST_DIR/config.toml"
MODELS_DIR="$ROOT_DIR/models"
S2_DIR="$ROOT_DIR/s2.cpp"
S2_BIN="$MODELS_DIR/s2"

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker command not found"
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "[INFO] config.toml not found. Creating from all-in-one example..."
  cp "$HOST_DIR/config.allinone.toml.example" "$CONFIG_PATH"
fi

mkdir -p "$MODELS_DIR"

# ── s2.cpp: clone & build ──────────────────────────────────────────────────
if [[ ! -f "$S2_BIN" ]]; then
  echo "[INFO] s2 binary not found. Building from source..."

  if [[ ! -d "$S2_DIR/src" ]]; then
    if command -v git >/dev/null 2>&1; then
      echo "[INFO] Cloning s2.cpp..."
      git -C "$ROOT_DIR" clone https://github.com/rodrigomatta/s2.cpp.git s2.cpp
    else
      echo "[ERROR] s2.cpp not found and git is unavailable."
      exit 1
    fi
  fi

  for TOOL in cmake make g++; do
    if ! command -v "$TOOL" >/dev/null 2>&1; then
      echo "[ERROR] Build tool not found: $TOOL"
      echo "        Install build tools and try again:"
      echo "        sudo apt install cmake build-essential"
      exit 1
    fi
  done

  echo "[INFO] Building s2.cpp (this may take a few minutes)..."
  cmake -S "$S2_DIR" -B "$S2_DIR/build" -DCMAKE_BUILD_TYPE=Release -DS2_CUDA=OFF -Wno-dev -DCMAKE_POLICY_VERSION_MINIMUM=3.5 2>/dev/null
  cmake --build "$S2_DIR/build" --target s2 -j"$(nproc)"
  cp "$S2_DIR/build/s2" "$S2_BIN"
  chmod +x "$S2_BIN"
  echo "[INFO] s2 binary built: $S2_BIN"
fi

# tokenizer.json をmodels/にコピー（s2.cppから）
if [[ ! -f "$MODELS_DIR/tokenizer.json" ]] && [[ -f "$S2_DIR/tokenizer.json" ]]; then
  cp "$S2_DIR/tokenizer.json" "$MODELS_DIR/tokenizer.json"
  echo "[INFO] tokenizer.json copied to models/"
fi

# GGUFモデルの確認
if [[ ! -f "$MODELS_DIR/s2-pro-q4_k_m.gguf" ]]; then
  echo "[WARN] TTS model not found: models/s2-pro-q4_k_m.gguf"
  echo "       TTS will not work until the model is placed in models/."
  echo "       See README.md for instructions."
fi

# ── Docker起動 ────────────────────────────────────────────────────────────
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
