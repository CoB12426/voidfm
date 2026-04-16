#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT_DIR/mydj-host"
CLIENT_DIR="$ROOT_DIR/mydj_client"
LOG_DIR="$ROOT_DIR/.logs"
PID_FILE="$LOG_DIR/mydj-host.pid"
VENV_PY="$ROOT_DIR/voidfm/bin/python"

MODE="full"
if [[ "${1:-}" == "--host-only" ]]; then
  MODE="host-only"
fi

mkdir -p "$LOG_DIR"

if [[ ! -x "$VENV_PY" ]]; then
  echo "[ERROR] Python venv not found: $VENV_PY"
  echo "        Create it first (example): python3 -m venv $ROOT_DIR/voidfm"
  exit 1
fi

if [[ ! -f "$HOST_DIR/config.toml" ]]; then
  echo "[ERROR] $HOST_DIR/config.toml not found."
  echo "        Copy config.toml.example to config.toml and edit it."
  exit 1
fi

if [[ ! -f "$HOST_DIR/requirements.txt" ]]; then
  echo "[ERROR] requirements.txt not found in $HOST_DIR"
  exit 1
fi

# Validate model-related paths from config.toml when mode=subprocess
"$VENV_PY" - <<'PY' "$HOST_DIR/config.toml"
import sys
from pathlib import Path

cfg_path = Path(sys.argv[1])
if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomli as tomllib

cfg = tomllib.loads(cfg_path.read_text(encoding="utf-8"))
mode = cfg.get("tts", {}).get("mode", "http")
if mode == "subprocess":
    missing = []
    for key in ("s2_binary", "s2_model", "s2_tokenizer"):
        p = cfg.get("tts", {}).get(key)
        if not p or not Path(p).exists():
            missing.append((key, p))
    if missing:
        print("[ERROR] Missing TTS resources in subprocess mode:")
        for k, p in missing:
            print(f"  - {k}: {p}")
        print("Please download/place files and update mydj-host/config.toml")
        raise SystemExit(1)
print("[OK] config.toml validation passed")
PY

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "[INFO] mydj-host already running (pid=$(cat "$PID_FILE"))"
else
  echo "[INFO] Installing/refreshing host deps..."
  "$VENV_PY" -m pip install -r "$HOST_DIR/requirements.txt" >/dev/null

  echo "[INFO] Starting mydj-host ..."
  (
    cd "$HOST_DIR"
    nohup "$VENV_PY" main.py > "$LOG_DIR/mydj-host.log" 2>&1 &
    echo $! > "$PID_FILE"
  )
  sleep 1
  if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "[ERROR] Failed to start mydj-host. Check $LOG_DIR/mydj-host.log"
    exit 1
  fi
  echo "[OK] mydj-host started (pid=$(cat "$PID_FILE"))"
fi

echo "[INFO] Host log: $LOG_DIR/mydj-host.log"

if [[ "$MODE" == "host-only" ]]; then
  echo "[DONE] Host is up."
  exit 0
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "[WARN] Flutter not found in PATH."
  echo "       Start client manually from $CLIENT_DIR"
  exit 0
fi

echo "[INFO] Running Flutter app..."
cd "$CLIENT_DIR"
flutter pub get
flutter run
