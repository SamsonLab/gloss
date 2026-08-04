#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export GLOSS_CODEX_RUNTIME_MODE=cli
exec "$SCRIPT_DIR/build_app.sh" "$@"
