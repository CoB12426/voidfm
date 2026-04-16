#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT_DIR/mydj-host"
MODELS_DIR="$ROOT_DIR/models"
FISH_DIR="$ROOT_DIR/fish-speech"

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker command not found"
  exit 1
fi

if [[ ! -f "$HOST_DIR/config.toml" ]]; then
  echo "[INFO] config.toml not found. Creating from docker example..."
  cp "$HOST_DIR/config.docker.toml.example" "$HOST_DIR/config.toml"
  echo "[WARN] Edit $HOST_DIR/config.toml to match your model files."
fi

OLLAMA_URL="$(sed -n 's/^[[:space:]]*ollama_url[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$HOST_DIR/config.toml" | head -n1)"

mkdir -p "$MODELS_DIR"

if grep -Eq '^\s*mode\s*=\s*"subprocess"' "$HOST_DIR/config.toml"; then
  if [[ ! -f "$MODELS_DIR/s2-pro-q4_k_m.gguf" ]] || [[ ! -f "$MODELS_DIR/tokenizer.json" ]] || [[ ! -x "$MODELS_DIR/s2" ]]; then
    echo "[ERROR] TTS mode is subprocess, but required files are missing in $MODELS_DIR"
    echo "  - s2 (Linux executable)"
    echo "  - s2-pro-q4_k_m.gguf"
    echo "  - tokenizer.json"
    echo "Please place them and run again, or switch mode to \"http\" in config.toml."
    exit 1
  fi
else
  echo "[INFO] TTS mode is not subprocess. Skipping local model file checks."

  if [[ -d "$FISH_DIR" ]]; then
    echo "[INFO] Starting fish-speech server (http mode)..."
    (
      cd "$FISH_DIR"
      docker compose -f compose.yml --profile server up -d --build
    )
  else
    echo "[WARN] fish-speech directory not found: $FISH_DIR"
    echo "       Ensure tts.fish_speech_url is reachable from mydj-host container."
  fi
fi

cd "$ROOT_DIR"
docker compose -f docker-compose.easy.yml up -d --build

if [[ -n "$OLLAMA_URL" ]]; then
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsS --max-time 3 "${OLLAMA_URL%/}/api/tags" >/dev/null; then
      echo "[WARN] Ollama not reachable: ${OLLAMA_URL}"
      echo "       Start Ollama separately, or point llm.ollama_url to a reachable endpoint."
    else
      echo "[OK] Ollama reachable: ${OLLAMA_URL}"
    fi
  else
    echo "[WARN] curl not found. Skipping Ollama reachability check."
  fi
fi

echo "[OK] Host started: http://localhost:8000"
echo "[NEXT] Install APK from your GitHub Releases and set host IP in the app settings."
