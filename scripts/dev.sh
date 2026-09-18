#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SUBSYSTEM="${AI_USAGE_LOG_SUBSYSTEM:-com.silfoxs.AIUsageBar}"
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

swift run AIUsageBar &
APP_PID=$!
echo "AIUsageBar running (pid $APP_PID). Streaming unified logs; press Ctrl-C to stop."
log stream --style compact --level debug --predicate "subsystem == '$SUBSYSTEM'"
