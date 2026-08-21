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
# ONE Godot resolver, shared with start_game.sh (the toolchain used to be
# pinned in two unrelated forms — a sibling-repo default here, a download
# URL in CI; a machine without the sibling checkout hit a dead path).
source "$ROOT/scripts/find_godot.sh"
GODOT="$(find_godot)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml | head -1)"
[ -n "$VERSION" ] || VERSION="0.0.0"

case "$PLATFORM" in
    linux)   PRESET="Linux";           EXE="rttransportflow.x86_64" ;;
    windows) PRESET="Windows Desktop"; EXE="rttransportflow.exe" ;;
    *) echo "usage: $0 [linux|windows]" >&2; exit 2 ;;
esac
BUNDLE="build/dist/rttransportflow-$VERSION-$PLATFORM-x86_64"


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
# TRANSFORM the checked-in sidecar config rather than re-typing it: the env
# block has exactly one author (orchestration/sidecars.json) — a new env var
# added there used to need a manual mirror into a heredoc here, or the
# shipped bundle silently ran a different backend configuration than dev
# (the config-file variant of the ledger-36 stale-backend failure).
python3 - "orchestration/sidecars.json" "$BUNDLE/orchestration/sidecars.json" "$BACKEND_EXE" <<'PY'
import json, sys
src, out, exe = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.load(open(src))
doc["_comment"] = ("Packaged bundle (generated from orchestration/"
                   "sidecars.json): the sidecar is the FROZEN backend next "
                   "to the game, so no Python/venv is required on the "
                   "player's machine.")
for entry in doc["sidecars"]:
    entry.pop("python", None)
    entry.pop("module", None)
    entry["exe"] = exe
json.dump(doc, open(out, "w"), indent=2)
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
