"""Snapshot capture/restore: versioned, JSON-safe, bit-exact.

Floats travel as `repr` strings (binary64-exact round-trip) — the ONE
exemption from the `_r()` wire rule — so restore + continue reproduces the
uninterrupted run bit for bit (pinned by test_snapshot_replay).
"""

from __future__ import annotations

import hashlib
import json
from typing import Any


def capture(integrator) -> dict[str, Any]:
    return integrator.state_dict()


def restore(integrator, snap: dict[str, Any]) -> None:
    integrator.restore_state(snap)


def to_json(snap: dict[str, Any]) -> str:
    return json.dumps(snap, separators=(",", ":"), sort_keys=True)


def from_json(text: str) -> dict[str, Any]:
    return json.loads(text)


def model_hash(fleet) -> str:
    """Hash of the model structure+parameters (not state) — restore guard."""
    h = hashlib.sha256()
    h.update(",".join(fleet.ids).encode())
    h.update(",".join(fleet.inv_ids).encode())
    for arr in (fleet.s_n, fleet.p_max, fleet.h, fleet.k_droop, fleet.db,
                fleet.fcr_band, fleet.t_g, fleet.t_ch, fleet.t_rh, fleet.f_hp):
        h.update(arr.tobytes())
    return h.hexdigest()[:16]
