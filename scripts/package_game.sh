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
    linux)   PRESET="Linux";           EXE="rttransportflow.x86_64"; ARCH="x86_64" ;;
    windows) PRESET="Windows Desktop"; EXE="rttransportflow.exe";   ARCH="x86_64" ;;
    # arm64 only: PyInstaller cannot cross-compile, so the backend is
    # whatever the build host is — and the macOS build host (CI's
    # macos-14 runner) is Apple Silicon. An Intel Mac cannot run it.
    macos)   PRESET="macOS";           EXE="rttransportflow.zip";   ARCH="arm64" ;;
    *) echo "usage: $0 [linux|windows|macos]" >&2; exit 2 ;;
esac
BUNDLE="build/dist/rttransportflow-$VERSION-$PLATFORM-$ARCH"


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
BACKEND_EXE="backend/rttransportflow-backend/rttransportflow-backend"
if [ "$PLATFORM" = "macos" ]; then
    # The runtime resolves its root as the EXECUTABLE directory, which
    # inside a .app is Contents/MacOS — so backend, data and the sidecar
    # config live INSIDE the app bundle, and the .app is the whole game.
    mkdir -p "$BUNDLE"
    unzip -q "build/dist/$PLATFORM/$EXE" -d "$BUNDLE"
    APP="$BUNDLE/rttransportflow.app"
    [ -d "$APP" ] || { echo "export zip carried no rttransportflow.app" >&2; exit 1; }
    DEST_ROOT="$APP/Contents/MacOS"
    mkdir -p "$DEST_ROOT/backend" "$DEST_ROOT/orchestration"
    cp -r "$FROZEN" "$DEST_ROOT/backend/"
    cp -r data "$DEST_ROOT/data"
else
    mkdir -p "$BUNDLE/backend" "$BUNDLE/orchestration"
    cp "build/dist/$PLATFORM/$EXE" "$BUNDLE/$EXE"
    chmod +x "$BUNDLE/$EXE"
    cp -r "$FROZEN" "$BUNDLE/backend/"
    # data/ ships beside the executable (read through absolute paths, not res://)
    cp -r data "$BUNDLE/data"
    DEST_ROOT="$BUNDLE"
fi
[ "$PLATFORM" = "windows" ] && BACKEND_EXE="$BACKEND_EXE.exe"
# TRANSFORM the checked-in sidecar config rather than re-typing it: the env
# block has exactly one author (orchestration/sidecars.json) — a new env var
# added there used to need a manual mirror into a heredoc here, or the
# shipped bundle silently ran a different backend configuration than dev
# (the config-file variant of the ledger-36 stale-backend failure).
python3 - "orchestration/sidecars.json" "$DEST_ROOT/orchestration/sidecars.json" "$BACKEND_EXE" <<'PY'
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

RUN_LINE="./$EXE"
[ "$PLATFORM" = "macos" ] && RUN_LINE="open rttransportflow.app   (first: xattr -cr rttransportflow.app)"
cat > "$BUNDLE/README-RUN.txt" <<EOF
rttransportflow $VERSION — Europe-scale power transmission game

Run:   $RUN_LINE

Everything needed is in this folder: the game, the physics backend
(backend/), the map and campaign data (data/). No Python installation is
required. The game starts the backend itself on port 8030 and writes its
log to .run/ next to this file.

If the frequency dial stays grey, the backend did not start — read
.run/transmission.log.

macOS: the app is ad-hoc signed, not notarized. Gatekeeper refuses it
until you clear the quarantine flag once:
    xattr -cr rttransportflow.app
(That also disables App Translocation, which would mount the app
read-only and break its own log directory.) Apple Silicon only.
EOF

# --- 3b. sign (macOS) -------------------------------------------------------
# Every Mach-O must carry a signature on arm64 — and every one already
# DOES (the linker ad-hoc signs at build time; PyInstaller binaries come
# signed). What broke was the .app's bundle SEAL when the payload went in,
# and `codesign --deep` cannot repair it: it trips over the PyInstaller
# dist's framework-shaped directories ("bundle format unrecognized ...
# In subcomponent: .../backend/rttransportflow-backend/"). So: re-sign
# payload Mach-Os individually as a belt, then re-seal the app WITHOUT
# --deep, best-effort — an ad-hoc app is refused by Gatekeeper with or
# without a valid seal (the README's xattr -cr is the real unlock), and
# execution does not check the seal. The play-test below is the gate.
if [ "$PLATFORM" = "macos" ] && command -v codesign >/dev/null 2>&1; then
    echo "==> ad-hoc signing payload Mach-Os"
    find "$BUNDLE/rttransportflow.app/Contents/MacOS/backend" -type f \
            \( -name "*.dylib" -o -name "*.so" -o -perm -u+x \) | while read -r f; do
        file -b "$f" | grep -q "Mach-O" && codesign --force --sign - "$f" || true
    done
    codesign --force --sign - "$BUNDLE/rttransportflow.app" \
        || echo "WARN: app seal not restored (harmless for an ad-hoc bundle)"
fi

# --- 4. verify by playing it ------------------------------------------------
# A bundle that assembles but cannot boot its own backend is worthless, so
# the gate is a real scripted run inside the bundle, not a file listing.
if [ "$PLATFORM" = "macos" ] && [ "$(uname)" = "Darwin" ]; then
    echo "==> verifying bundle (scripted boot + a simulated day)"
    # stock macOS has no `timeout`; the runner usually has coreutils, but
    # the gate must not die on the tool that polices it
    TIMEOUT_CMD="timeout 900"
    command -v timeout >/dev/null 2>&1 || TIMEOUT_CMD=""
    ( cd "$BUNDLE" && RTTF_PORT_OFFSET=5 $TIMEOUT_CMD \
        "./rttransportflow.app/Contents/MacOS/rttransportflow" --headless -- \
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
if [ "$PLATFORM" = "macos" ] && command -v ditto >/dev/null 2>&1; then
    # ditto preserves the code signatures a plain zip can strip
    ditto -c -k --keepParent "$BUNDLE" "$BUNDLE.zip"
    echo "==> $BUNDLE.zip ($(du -h "$BUNDLE.zip" | cut -f1))"
    exit 0
fi
tar -czf "$BUNDLE.tar.gz" -C "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")"
echo "==> $BUNDLE.tar.gz ($(du -h "$BUNDLE.tar.gz" | cut -f1))"
