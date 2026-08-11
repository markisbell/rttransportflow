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
    h.update(",".join(fleet.bat_ids).encode())
    h.update(",".join(fleet.ely_ids).encode())
    for arr in (fleet.s_n, fleet.p_max, fleet.p_min, fleet.h, fleet.k_droop,
                fleet.db, fleet.fcr_band, fleet.ramp_mw_s,
                fleet.t_a, fleet.t_b, fleet.t_c, fleet.c_in, fleet.c_2,
                fleet.w_a, fleet.w_b, fleet.w_c,
                fleet.hy_t_lag, fleet.hy_k_lead, fleet.hy_t_srv, fleet.hy_t_w2,
                fleet.inv_t_up, fleet.inv_t_down, fleet.inv_p_rated,
                fleet.inv_aux_mw, fleet.inv_slew_mw_s,
                fleet.bat_p_max, fleet.bat_e_mwh, fleet.bat_h_v,
                fleet.ely_p_max):
        h.update(arr.tobytes())
    if fleet.h2 is not None:
        h.update(",".join(fleet.h2.ids).encode())
        h.update(fleet.h2.capacity_kg.tobytes())
        h.update(fleet.h2.inject_max_kgph.tobytes())
        h.update(fleet.h2.withdraw_max_kgph.tobytes())
    if fleet.hvdc is not None:
        h.update(",".join(fleet.hvdc.link_ids).encode())
        h.update(",".join(fleet.hvdc.term_ids).encode())
        h.update(fleet.hvdc.p_max.tobytes())
        h.update(fleet.hvdc.loss_frac.tobytes())
    return h.hexdigest()[:16]
