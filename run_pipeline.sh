#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

notify_failure() {
  status=$?
  if [ "$status" -ne 0 ]; then
    /usr/bin/osascript -e \
      'display notification "Check logs/scheduler.err.log for details." with title "World Bank pipeline failed"' \
      || true
  fi
  exit "$status"
}

trap notify_failure EXIT

cd "$PROJECT_DIR"

DB_PASSWORD=$(/usr/bin/security find-generic-password \
  -a "$(/usr/bin/id -un)" -s world-bank-db-password -w)
export DB_PASSWORD

"$PROJECT_DIR/venv/bin/python" main.py
