"""Per-machine rotor-angle observer (ledger 56) — the phasor arc, Phase 1.

A classical multi-machine swing ANCHORED to the per-island COI: each online
synchronous machine i carries a rotor angle delta_i and speed deviation
omega_i, integrated on the same tick grid as the COI swing but NEVER feeding
back into it. Each tick the machine speeds are projected so their
inertia-weighted mean equals the Tier-1 COI frequency (the integrator's
IslandState.f) — so the wire f and every frequency pin are the untouched COI
numbers, while the SPREAD (delta_i, omega_i - f_coi) is the genuine
inter-machine motion the phasor overlay renders.

Electrical coupling is a FIXED classical reduced-Y-bus (machines as E' behind
Xd', loads as constant-impedance shunts), rebuilt on topology change by the
simulator (which owns pandapower) and handed here via `set_islands`. The tick
is a dense O(n_gen^2) matvec — no solve, no pandapower call — so it can never
turn a step into a 500 or perturb the balance. A pole slip is bounded to a
visual (delta wraps, omega clamps), never an unbounded float or a NaN.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from . import F0, US

TWO_PI = 2.0 * np.pi
OMEGA_CLAMP_HZ = 10.0  # |omega - f_coi| clamp: a pole slip stays a visual


@dataclass
class IslandNet:
    """One island's classical reduced network + the derived swing constants.
    All power is MW (the reduced G/B fold in the system base), angle rad, speed
    Hz deviation. Built by the simulator at PF instants (`build_island_nets`)."""

    island: int          # island index (into IslandState.f)
    rows: np.ndarray     # fleet sync-row indices of the machines [int]
    g_mw: np.ndarray     # reduced conductance [MW/pu^2], N x N
    b_mw: np.ndarray     # reduced susceptance  [MW/pu^2], N x N
    e_prime: np.ndarray  # internal EMF magnitude [pu], N
    p_bias: np.ndarray   # P_e(delta0) - P_m0 [MW], N — classical-vs-PF offset
    inv_m: np.ndarray    # f0 / (2 H_i S_n,i) [Hz/(MW·s)], N
    weight: np.ndarray   # 2 H_i S_n,i, the COI inertia weight, N
    d_coeff: np.ndarray  # D_i S_n,i / f0 [MW/Hz], the damping torque, N


def _p_e(e: np.ndarray, g: np.ndarray, b: np.ndarray, delta: np.ndarray) -> np.ndarray:
    """Classical electrical power [MW]: P_ei = E_i Σ_j E_j (G_ij cos + B_ij sin)."""
    dij = delta[:, None] - delta[None, :]
    return e * ((g * np.cos(dij) + b * np.sin(dij)) @ e)


class AngleObserver:
    """Downstream consumer of the COI swing — integrates per-machine (delta,
    omega) into fleet.delta / fleet.omega each tick, projected to the COI f."""

    def __init__(self) -> None:
        self.nets: list[IslandNet] = []
        self.enabled = False

    def set_islands(self, nets: list[IslandNet]) -> None:
        """Adopt the freshly-reduced per-island networks (topology change / PF
        re-anchor). Machines outside every net keep their last (delta, omega)
        — a tripped machine freezes until the next rebuild."""
        self.nets = nets
        self.enabled = bool(nets)

    def step(self, dt_us: int, fleet, f_island: np.ndarray) -> None:
        """Semi-implicit-style symplectic integrate + COI projection. Reads the
        Tier-1 island f READ-ONLY; writes only fleet.delta / fleet.omega."""
        if not self.enabled:
            return
        dt = dt_us / US
        for net in self.nets:
            rows = net.rows
            if rows.size == 0:
                continue
            w_sum = float(np.sum(net.weight))
            if w_sum <= 0.0:
                continue  # no inertia (all offline) — nothing to swing
            f_coi = float(f_island[net.island]) - F0  # island speed deviation [Hz]
            e = net.e_prime
            delta = fleet.delta[rows]
            omega = fleet.omega[rows]
            p_e = _p_e(e, net.g_mw, net.b_mw, delta)
            p_m = fleet.y[rows] + net.p_bias
            damp = net.d_coeff * (omega - f_coi)                 # MW
            omega = omega + dt * net.inv_m * (p_m - p_e - damp)  # swing
            # project: inertia-weighted mean speed EQUALS the COI f (< 1e-12,
            # the pin that keeps the wire f exact) — the observer never the
            # other way round.
            omega = omega + (f_coi - float(np.sum(net.weight * omega)) / w_sum)
            np.clip(omega, f_coi - OMEGA_CLAMP_HZ, f_coi + OMEGA_CLAMP_HZ, out=omega)
            # angle relative to the COI reference; wrap so a pole slip is a
            # spinning phasor, never an unbounded float.
            delta = delta + dt * TWO_PI * (omega - f_coi)
            delta = (delta + np.pi) % TWO_PI - np.pi
            fleet.delta[rows] = delta
            fleet.omega[rows] = omega
