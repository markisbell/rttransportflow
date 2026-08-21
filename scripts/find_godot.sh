#!/usr/bin/env bash
# find_godot.sh — the ONE Godot resolver (sourced by start_game.sh and
# package_game.sh; CI downloads its own pinned build). Echoes the binary
# path, or exits 1 with a hint. Resolution order:
#   1. $GODOT (explicit override)
#   2. <repo>/.tools/godot/Godot_v4.7.1*   (repo-local install)
#   3. ../infrastruct/.tools/godot/Godot_v4.7.1*  (the sibling repo's copy)
#   4. `godot` on PATH
find_godot() {
    local repo
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [ -n "${GODOT:-}" ] && [ -x "$GODOT" ]; then
        echo "$GODOT"; return 0
    fi
    local candidate
    for candidate in \
        "$repo"/.tools/godot/Godot_v4.7.1*linux.x86_64 \
        "$repo"/../infrastruct/.tools/godot/Godot_v4.7.1*linux.x86_64; do
        if [ -x "$candidate" ]; then
            echo "$candidate"; return 0
        fi
    done
    if command -v godot >/dev/null 2>&1; then
        command -v godot; return 0
    fi
    echo "ERROR: no Godot 4.7.1 binary found." >&2
    echo "  Set GODOT=/path/to/Godot_v4.7.1-stable_linux.x86_64, or place it" >&2
    echo "  under .tools/godot/ (see ../infrastruct/.tools/godot/ for a copy)." >&2
    return 1
}
