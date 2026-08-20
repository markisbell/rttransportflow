"""Shared dynamics-engine fixtures: island-state construction, the droop-only
pin mode, and the P2 analytic fixture (previously in test_dynamics_analytic
and cross-imported by two other test modules).

The analytic pins are float-exact: these helpers must construct byte-identical
spec dicts and perform identical advance() sequences — pure lift-and-call.
"""

from __future__ import annotations

import numpy as np

from rttransportflow.dynamics import F0
from rttransportflow.dynamics.fleet import make_fleet
from rttransportflow.dynamics.integrator import Integrator, IslandState


def make_island(p_l0: float, d_pu: float = 0.5, f_hz: float = F0) -> IslandState:
    """The one-island state every dynamics fixture builds by hand."""
    return IslandState(
        f=np.array([f_hz]), e_k=np.zeros(1), p_l0=np.array([p_l0]),
        w=np.ones(1), p_loss=np.zeros(1), d_pu=d_pu,
    )


def pin_mode(integ: Integrator) -> Integrator:
    """Droop-only pin mode: the §6/§2.3 pins predate the P8 defense layer and
    AGC — fixtures run with both OFF (the family's "clamps disabled" rule)."""
    integ.defense_enabled = False
    integ.agc_enabled = False
    return integ


def make_fixture(h: float = 5.0, n_machines: int = 4, s_n: float = 2500.0,
                 load_mw: float = 8000.0, d_pu: float = 1.0) -> Integrator:
    """PHYSICS §6 analytic fixture: 4 × 2500 MVA, H = 5 s, R = 0.05, no
    deadband, all clamps disabled; the §6 pins were generated against it."""
    p_each = load_mw / n_machines
    sync = [
        {
            "id": f"g{i}", "island": 0, "s_n": s_n, "h": h, "r": 0.05,
            "db": 0.0, "fcr_band": np.inf, "p_max": np.inf, "p_min": 0.0,
            "t_g": 0.2, "t_ch": 0.4, "t_rh": 8.0, "f_hp": 1.0,
            "ramp_mw_s": np.inf, "p_set": p_each,
        }
        for i in range(n_machines)
    ]
    fleet = make_fleet(sync)
    fleet.init_steady_state()
    integrator = Integrator(fleet, make_island(load_mw, d_pu=d_pu))
    return pin_mode(integrator)
