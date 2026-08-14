#!/usr/bin/env bash
# Package a standalone playable bundle (ROADMAP P10): frozen backend +
# exported Godot game + the data tree they both read, assembled into the
# layout the runtime expects and verified by actually PLAYING it.
#
# Layout — flat, because an exported build resolves its repo root as the
# executable's own directory (SidecarManager._ready):
#
#     rttransportflow-<version>-linux-x86_64/
#       rttransportflow.x86_64        the game (PCK embedded)
#       backend/rttransportflow-backend/…   the frozen sidecar (onedir)
#       data/                         map, campaign, catalogs, scenarios
#       orchestration/sidecars.json   points at the frozen binary, not .venv
#       README-RUN.txt
#
# The bundle carries no Python and no venv: `exe` in sidecars.json takes the
# branch build_launch_command() already has for a frozen backend.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PLATFORM="${1:-linux}"
GODOT="${GODOT:-$ROOT/../infrastruct/.tools/godot/Godot_v4.7.1-stable_linux.x86_64}"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml | head -1)"
[ -n "$VERSION" ] || VERSION="0.0.0"

case "$PLATFORM" in
    linux)   PRESET="Linux";           EXE="rttransportflow.x86_64" ;;
    windows) PRESET="Windows Desktop"; EXE="rttransportflow.exe" ;;
    *) echo "usage: $0 [linux|windows]" >&2; exit 2 ;;
esac
BUNDLE="build/dist/rttransportflow-$VERSION-$PLATFORM-x86_64"

[ -x "$GODOT" ] || { echo "Godot not found at $GODOT (set GODOT=)" >&2; exit 1; }

# --- 1. frozen backend ------------------------------------------------------
# Reuse an existing freeze unless the sources are newer — PyInstaller costs
# minutes and packaging is run repeatedly while iterating on the bundle.
FROZEN="build/freeze/dist/rttransportflow-backend"
if [ ! -x "$FROZEN/rttransportflow-backend" ] \
        || [ -n "$(find src -newer "$FROZEN/rttransportflow-backend" -name '*.py' -print -quit)" ]; then
    echo "==> freezing backend"
    scripts/freeze_backend.sh
else
    echo "==> frozen backend up to date"
fi

# --- 2. export the game -----------------------------------------------------
echo "==> exporting $PRESET"
mkdir -p "$(dirname "$ROOT/build/dist/$PLATFORM/$EXE")"
# Godot exits 0 on some export errors, so verify the artifact itself.
(cd game && "$GODOT" --headless --export-release "$PRESET" \
    "$ROOT/build/dist/$PLATFORM/$EXE" 2>&1 | tail -20)
[ -s "build/dist/$PLATFORM/$EXE" ] || { echo "export produced no binary" >&2; exit 1; }

# --- 3. assemble ------------------------------------------------------------
echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/backend" "$BUNDLE/orchestration"
cp "build/dist/$PLATFORM/$EXE" "$BUNDLE/$EXE"
chmod +x "$BUNDLE/$EXE"
cp -r "$FROZEN" "$BUNDLE/backend/"
# data/ ships beside the executable (read through absolute paths, not res://)
cp -r data "$BUNDLE/data"

BACKEND_EXE="backend/rttransportflow-backend/rttransportflow-backend"
[ "$PLATFORM" = "windows" ] && BACKEND_EXE="$BACKEND_EXE.exe"
python3 - "$BUNDLE/orchestration/sidecars.json" "$BACKEND_EXE" <<'PY'
import json, sys
out, exe = sys.argv[1], sys.argv[2]
json.dump({
    "_comment": "Packaged bundle: the sidecar is the FROZEN backend next to "
                "the game, so no Python/venv is required on the player's "
                "machine. Port 8030 per the family port map.",
    "sidecars": [{
        "id": "transmission",
        "exe": exe,
        "cwd": ".",
        "port": 8030,
        "env": {
            "RTTRANSPORTFLOW_EXTERNAL_CLOCK": "true",
            "RTTRANSPORTFLOW_HOST": "127.0.0.1",
            "RTTRANSPORTFLOW_SIMULATOR": "null",
            "RTTRANSPORTFLOW_AUTOSTART": "false",
            "RTTRANSPORTFLOW_LOG_LEVEL": "warning",
        },
    }],
}, open(out, "w"), indent=2)
PY

cat > "$BUNDLE/README-RUN.txt" <<EOF
rttransportflow $VERSION — Europe-scale power transmission game

Run:   ./$EXE

Everything needed is in this folder: the game, the physics backend
(backend/), the map and campaign data (data/). No Python installation is
required. The game starts the backend itself on port 8030 and writes its
log to .run/ next to this file.

If the frequency dial stays grey, the backend did not start — read
.run/transmission.log.
EOF

# --- 4. verify by playing it ------------------------------------------------
# A bundle that assembles but cannot boot its own backend is worthless, so
# the gate is a real scripted run inside the bundle, not a file listing.
if [ "$PLATFORM" = "linux" ]; then
    echo "==> verifying bundle (scripted boot + a simulated day)"
    ( cd "$BUNDLE" && RTTF_PORT_OFFSET=5 timeout 600 "./$EXE" --headless -- \
        --smoke=boot_and_day > package_verify.log 2>&1 ) || true
    if grep -q '"ok":true' "$BUNDLE/package_verify.log"; then
        grep -h '^SMOKE' "$BUNDLE/package_verify.log"
        rm -f "$BUNDLE/package_verify.log"
    else
        echo "bundle verification FAILED — see $BUNDLE/package_verify.log" >&2
        tail -20 "$BUNDLE/package_verify.log" >&2
        exit 1
    fi
fi

# --- 5. archive -------------------------------------------------------------
tar -czf "$BUNDLE.tar.gz" -C "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")"
echo "==> $BUNDLE.tar.gz ($(du -h "$BUNDLE.tar.gz" | cut -f1))"
