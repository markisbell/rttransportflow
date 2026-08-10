#!/usr/bin/env bash
# One-shot Linux install: uv-managed venv + editable install + smoke test.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v uv >/dev/null 2>&1; then
    echo "uv not found — install it: https://docs.astral.sh/uv/" >&2
    exit 1
fi

uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e ".[dev]"
.venv/bin/python -m pytest -q
echo
echo "OK. Start with ./start_rttransportflow.sh (health: http://127.0.0.1:8003/health)"
