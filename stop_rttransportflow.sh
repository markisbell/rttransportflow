#!/usr/bin/env bash
# Stop the backend by command line + working directory, never by port
# (family rule: a port may belong to a sibling).
set -uo pipefail
cd "$(dirname "$0")"

stopped=0
for pid in $(pgrep -f "rttransportflow.main" || true); do
    if [ "$(readlink -f "/proc/${pid}/cwd" 2>/dev/null)" = "$(pwd)" ]; then
        kill "$pid" 2>/dev/null && stopped=1
    fi
done
rm -f .run/backend.pid
[ "$stopped" = 1 ] && echo "stopped rttransportflow" || echo "rttransportflow was not running"
