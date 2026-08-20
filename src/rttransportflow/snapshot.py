"""Model-structure hash — the snapshot restore guard.

Snapshot capture/restore itself lives on the Integrator (state_dict /
restore_state; floats travel as `repr` strings, the ONE exemption from the
`_r()` wire rule — pinned by the bit-replay tests). This module keeps only
the hash of the model structure+parameters (not state): a mismatch on reset
means the snapshot describes a different model and is refused
(`refused_snapshot`).
"""

from __future__ import annotations

import hashlib

import numpy as np


def repr_floats(arr) -> list[str]:
    """The ONE repr-float serializer (previously five hand-rolled copies).
    `repr(float(v))` — the float() unwrap matters: NumPy 2's repr(np.float64)
    prints the dtype wrapper and broke restore (P2 log)."""
    return [repr(float(v)) for v in arr]


def parse_floats(items) -> np.ndarray:
    return np.array([float(v) for v in items])


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
                fleet.hy_e_mwh, fleet.hy_eta_ch, fleet.hy_eta_dis,
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
