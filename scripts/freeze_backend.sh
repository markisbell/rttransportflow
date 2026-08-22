#!/usr/bin/env bash
# Freeze the backend into a standalone onedir bundle (PyInstaller) and smoke it.
# Family lesson: the freeze smoke lives in P4 CI, not P10 — and PyInstaller
# only WARNS when numba is missing, so the smoke greps the build log for it.
set -euo pipefail
cd "$(dirname "$0")/.."

PY=".venv/bin/python"
BACKEND_BIN="rttransportflow-backend"
DATA_SEP=":"
# Windows (git-bash on the CI runner): venv layout and PyInstaller's
# --add-data separator both differ
DATA_ROOT="$(pwd)/data"
if [ -x ".venv/Scripts/python.exe" ]; then
    PY=".venv/Scripts/python.exe"
    BACKEND_BIN="rttransportflow-backend.exe"
    DATA_SEP=";"
    # a POSIX /d/a/... path reaches Windows PyInstaller mangled to \d\a\...
    # once the ';' defeats MSYS auto-conversion — hand it D:/a/... directly
    DATA_ROOT="$(pwd -W)/data"
fi
OUT="build/freeze"
LOG="$OUT/build.log"
mkdir -p "$OUT"

"$PY" -m PyInstaller \
    --distpath "$OUT/dist" --workpath "$OUT/work" --specpath "$OUT" \
    --name rttransportflow-backend --onedir --noconfirm --clean \
    --collect-all pandapower \
    --collect-all numba \
    --collect-all llvmlite \
    --hidden-import rttransportflow.main \
    --add-data "${DATA_ROOT}${DATA_SEP}data" \
    scripts/freeze_entry.py > "$LOG" 2>&1 || { tail -30 "$LOG" >&2; exit 1; }

# Fail on numba warnings EXCEPT the known-benign OPTIONAL threading layers
# (Linux: libtbb; macOS: libomp — numba falls back to its default workqueue
# layer either way; only numba being absent would be the silent-slow-path
# family gotcha).
if grep "WARNING" "$LOG" | grep -i "numba" | grep -v "libtbb" | grep -qv "libomp"; then
    echo "freeze log WARNS about numba — inspect $LOG" >&2
    grep "WARNING" "$LOG" | grep -i "numba" >&2
    exit 1
fi

# Smoke: boot the frozen binary on a scratch port, expect the identity payload.
PORT=8033
RTTRANSPORTFLOW_PORT=$PORT RTTRANSPORTFLOW_AUTOSTART=false \
RTTRANSPORTFLOW_EXTERNAL_CLOCK=true \
    "$OUT/dist/rttransportflow-backend/$BACKEND_BIN" &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
    if curl -sf --noproxy '*' "http://127.0.0.1:$PORT/health" | grep -q '"app":"rttransportflow"'; then
        echo "freeze smoke OK"
        exit 0
    fi
    sleep 0.5
done
echo "frozen backend did not become healthy" >&2
exit 1
