#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FISH_DIR="$ROOT_DIR/fish-speech"
cd "$ROOT_DIR"

docker compose -f docker-compose.easy.yml down

if [[ -d "$FISH_DIR" ]]; then
	(
		cd "$FISH_DIR"
		docker compose -f compose.yml --profile server down
	)
fi

echo "[OK] Host stopped"
