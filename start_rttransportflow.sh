#!/usr/bin/env bash
# Launch the backend detached: PID + log in .run/ (family launcher pattern).
set -euo pipefail
cd "$(dirname "$0")"

PORT="${RTTRANSPORTFLOW_PORT:-8003}"
mkdir -p .run

# Identity check before reusing the port (never adopt a foreign process).
if curl -sf --noproxy '*' "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q '"app":"rttransportflow"'; then
    echo "rttransportflow already answering on :${PORT}"
    exit 0
fi

PY=".venv/bin/python"
[ -x "$PY" ] || { echo "no .venv — run ./install.sh first" >&2; exit 1; }

setsid nohup "$PY" -m rttransportflow.main >> .run/backend.log 2>&1 &
echo $! > .run/backend.pid
echo "started rttransportflow (pid $(cat .run/backend.pid)), log: .run/backend.log"

for _ in $(seq 1 40); do
    if curl -sf --noproxy '*' "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
        echo "healthy: http://127.0.0.1:${PORT}/health"
        exit 0
    fi
    sleep 0.25
done
echo "backend did not become healthy — check .run/backend.log" >&2
exit 1
