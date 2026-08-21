#!/usr/bin/env bash
# start_game.sh — launch the rttransportflow GAME from source, windowed
# (twin of start_rttransportflow.sh, which starts the standalone BACKEND
# stack for the Grafana teaching mode — the game needs only this script:
# it spawns and supervises its own backend sidecar on port 8030).
#
# Usage:
#   ./start_game.sh                # sandbox boot (inherited 2025 world)
#   ./start_game.sh --campaign     # campaign mode (milestone tracker armed)
#   ./start_game.sh --foreground   # stay attached (Ctrl-C quits the game)
#   GODOT=/path/to/godot ./start_game.sh   # explicit engine override
#
# Logs: .run/game.log   PID: .run/game.pid   Stop: ./stop_game.sh
set -euo pipefail
cd "$(dirname "$0")"

source scripts/find_godot.sh
GODOT_BIN="$(find_godot)"

FOREGROUND=0
USER_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --foreground) FOREGROUND=1 ;;
        *) USER_ARGS+=("$arg") ;;
    esac
done

# The game's sidecar owns port 8030. A HEALTHY leftover backend there would
# be silently ADOPTED — and an adopted stale backend runs OLD code (the
# documented smoke-hunt failure, CLAUDE.md §8). Kill it only if it is
# provably ours; refuse to touch anything else.
if health="$(curl -sf --max-time 2 http://127.0.0.1:8030/health 2>/dev/null)"; then
    if echo "$health" | grep -q '"app":\s*"rttransportflow"'; then
        echo "==> freeing a leftover rttransportflow backend on 8030"
        fuser -k 8030/tcp 2>/dev/null || true
        sleep 1
    else
        echo "ERROR: port 8030 is in use by something that is not our backend:" >&2
        echo "  $health" >&2
        exit 1
    fi
elif ss -tln 2>/dev/null | grep -q ':8030 '; then
    echo "ERROR: port 8030 is occupied but does not answer /health — not touching it." >&2
    exit 1
fi

if [ ! -x .venv/bin/python ]; then
    echo "ERROR: .venv missing — the game's backend sidecar needs it." >&2
    echo "  Run ./install.sh first." >&2
    exit 1
fi

mkdir -p .run
if [ -f .run/game.pid ] && kill -0 "$(cat .run/game.pid)" 2>/dev/null; then
    echo "Game already running (pid $(cat .run/game.pid)) — ./stop_game.sh first."
    exit 1
fi

echo "==> launching game ($GODOT_BIN)"
if [ "$FOREGROUND" = "1" ]; then
    exec "$GODOT_BIN" --path game -- "${USER_ARGS[@]}"
fi

nohup "$GODOT_BIN" --path game -- "${USER_ARGS[@]}" >> .run/game.log 2>&1 &
GAME_PID=$!
echo "$GAME_PID" > .run/game.pid
echo "==> game pid $GAME_PID (log: .run/game.log)"

# The window is up almost immediately; the world appears once the sidecar
# is healthy and the inherited grid registers (~10-30 s incl. numba warmup).
echo -n "==> waiting for the backend sidecar on 8030 "
for _ in $(seq 1 60); do
    if ! kill -0 "$GAME_PID" 2>/dev/null; then
        echo; echo "ERROR: game exited during boot — tail of .run/game.log:" >&2
        tail -20 .run/game.log >&2
        rm -f .run/game.pid
        exit 1
    fi
    if curl -sf --max-time 1 http://127.0.0.1:8030/health >/dev/null 2>&1; then
        echo " healthy."
        echo "==> running. Stop with ./stop_game.sh"
        exit 0
    fi
    echo -n "."
    sleep 1
done
echo
echo "WARNING: sidecar not healthy after 60 s — the window may still be fine;" >&2
echo "  check .run/game.log if the world stays empty." >&2
