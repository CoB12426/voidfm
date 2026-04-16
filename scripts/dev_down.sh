#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_FILE="$ROOT_DIR/.logs/mydj-host.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "[INFO] No pid file found. Host may already be stopped."
  exit 0
fi

PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  echo "[OK] Stopped mydj-host (pid=$PID)"
else
  echo "[INFO] Process not running (pid=$PID)"
fi

rm -f "$PID_FILE"
