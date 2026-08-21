#!/usr/bin/env bash
# stop_game.sh — stop the game started by start_game.sh, and free its
# backend sidecar on 8030 (the sidecar is a child process, but a killed
# game can leak it — and a leftover healthy backend would be silently
# adopted by the next run, executing stale code).
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .run/game.pid ]; then
    PID="$(cat .run/game.pid)"
    if kill -0 "$PID" 2>/dev/null; then
        echo "==> stopping game (pid $PID)"
        kill "$PID" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$PID" 2>/dev/null || true
    fi
    rm -f .run/game.pid
fi

# free the sidecar port only if what answers is provably OUR backend
if health="$(curl -sf --max-time 2 http://127.0.0.1:8030/health 2>/dev/null)" \
        && echo "$health" | grep -q '"app":\s*"rttransportflow"'; then
    echo "==> freeing the backend sidecar on 8030"
    fuser -k 8030/tcp 2>/dev/null || true
fi
echo "==> stopped."
