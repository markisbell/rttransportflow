"""Runtime library-verification harness (rtheatflow rule: verify before trusting).

P0 feasibility spikes — run on the dev machine, paste the printed tables into
docs/adr/004-measured-budgets.md:

  (a) pandapower AC Newton-Raphson on a 20-bus 380 kV meshed net:
      cold vs warm-start solve times, enforce_q_lims behavior, iwamoto
      fallback availability, std_type existence.
  (b) vectorized NumPy dynamics tick for 150 devices x 3 lag states
      (struct-of-arrays, exact-exponential updates, droop/deadband/clamps,
      per-island reduceat, semi-implicit swing): us/tick at dt=10 ms and 250 ms.
  (c) syncon as a P=0 controllable gen (C6): solver-clean, Q pegs at the band.
  (d) per-machine angle observer (the phasor arc, ledger 56): the classical
      COI-anchored multi-machine swing — reducible from case9, analytically
      correct (2-machine inter-machine mode), COI-consistent (< 1e-12 so the
      wire f and every §6 pin survive), captures loss-of-synchronism, fast
      enough, deterministic. Proves the model BEFORE any engine change.

Usage: .venv/bin/python scripts/validate_core.py
"""

from __future__ import annotations

import statistics
import time

import numpy as np


# ---------------------------------------------------------------------------
# Spike (a): pandapower PF on a 20-bus 380 kV meshed net
# ---------------------------------------------------------------------------

LOAD_PATTERN = {1, 2, 4, 6, 8, 9, 11, 12, 14, 16, 18, 19}
GEN_PATTERN = {3, 5, 7, 10, 13, 15, 17}


def build_net(n: int = 20):
    """380 kV net of n buses as k = n/20 regional 20-bus meshes (ring +
    chords, roughly self-balanced: 12 x 750 MW load vs 7 x 1300 MW gen)
    chained by short tie lines — the shape the game actually produces
    (regional meshes, moderate electrical span), not one giant ring."""
    import pandapower as pp

    std_type = "490-AL1/64-ST1A 380.0"
    assert std_type in pp.available_std_types(pp.create_empty_network(), "line").index, (
        f"std_type {std_type!r} missing — pin a replacement before trusting the spec"
    )
    assert n % 20 == 0

    net = pp.create_empty_network(sn_mva=1000.0)
    buses = [pp.create_bus(net, vn_kv=380.0, name=f"bus_{i}") for i in range(n)]

    chords = [(0, 10), (2, 12), (5, 15), (7, 17), (3, 8), (13, 18)]
    for ring in range(n // 20):
        base = ring * 20
        edges = [(base + i, base + (i + 1) % 20) for i in range(20)]
        edges += [(base + a, base + b) for a, b in chords]
        for a, b in edges:
            pp.create_line(net, buses[a], buses[b], length_km=120.0,
                           std_type=std_type, parallel=2, name=f"L_{a}_{b}")
        if ring > 0:
            prev = (ring - 1) * 20
            pp.create_line(net, buses[prev + 0], buses[base + 10], length_km=60.0,
                           std_type=std_type, parallel=2, name=f"T_{ring}a")
            pp.create_line(net, buses[prev + 5], buses[base + 15], length_km=60.0,
                           std_type=std_type, parallel=2, name=f"T_{ring}b")

    # Realistic operating point — degenerate points break solvers.
    for i in range(n):
        if i % 20 in LOAD_PATTERN:
            pp.create_load(net, buses[i], p_mw=750.0, q_mvar=245.0)
        if i % 20 in GEN_PATTERN:
            pp.create_gen(net, buses[i], p_mw=1300.0, vm_pu=1.02,
                          min_q_mvar=-600.0, max_q_mvar=600.0)
    pp.create_ext_grid(net, buses[0], vm_pu=1.02)
    return net


def spike_powerflow(n: int = 20, repeats: int = 100) -> dict:
    import pandapower as pp

    net = build_net(n)

    # First solve carries the numba JIT warmup — measure it separately
    # (family rule: warmup at reset so JIT never lands on a live step).
    t0 = time.perf_counter()
    pp.runpp(net, init="dc", enforce_q_lims=True)
    warmup_ms = (time.perf_counter() - t0) * 1e3

    cold = []
    for _ in range(repeats):
        t0 = time.perf_counter()
        pp.runpp(net, init="dc", enforce_q_lims=True)
        cold.append((time.perf_counter() - t0) * 1e3)

    warm = []
    for _ in range(repeats):
        t0 = time.perf_counter()
        pp.runpp(net, init="results", enforce_q_lims=True)
        warm.append((time.perf_counter() - t0) * 1e3)

    q_at_limit = int((np.isclose(net.res_gen.q_mvar.abs(), 600.0, atol=1.0)).sum())

    # Retry-ladder tier 3 must exist.
    pp.runpp(net, algorithm="iwamoto_nr", init="dc", enforce_q_lims=True, max_iteration=30)

    return {
        "n_buses": n,
        "warmup_first_solve_ms": warmup_ms,
        "cold_median_ms": statistics.median(cold),
        "cold_p95_ms": sorted(cold)[int(0.95 * len(cold)) - 1],
        "warm_median_ms": statistics.median(warm),
        "warm_p95_ms": sorted(warm)[int(0.95 * len(warm)) - 1],
        "converged": bool(net.converged),
        "gens_at_q_limit": q_at_limit,
        "max_line_loading_pct": float(net.res_line.loading_percent.max()),
        "min_vm_pu": float(net.res_bus.vm_pu.min()),
    }


# ---------------------------------------------------------------------------
# Spike (c) — C6/D4: a synchronous condenser as a P=0 controllable gen.
# Measured 2026-09-03: cold converges (first solve = JIT warmup), warm
# median 4.95 ms, P held at exactly 0, Q regulates within ±0.40·S_n and
# pegs cleanly under enforce_q_lims. The syncon plant kind stands on this.
# ---------------------------------------------------------------------------

def spike_syncon() -> dict:
    import pandapower as pp

    net = pp.create_empty_network(sn_mva=100.0)
    buses = [pp.create_bus(net, vn_kv=380.0) for _ in range(6)]
    for i in range(5):
        pp.create_line_from_parameters(net, buses[i], buses[i + 1], 80.0,
                                       0.028, 0.32, 13.0, 2.0, parallel=2)
    pp.create_ext_grid(net, buses[0], vm_pu=1.02)
    for i, b in enumerate(buses[1:4], 1):
        pp.create_load(net, b, p_mw=350.0 + 40 * i)
    pp.create_gen(net, buses[2], p_mw=600.0, vm_pu=1.02,
                  max_q_mvar=240.0, min_q_mvar=-240.0)
    # the syncon: P=0, Q band from S_n = 300 MVA (±0.4), 1 % station load
    sc = pp.create_gen(net, buses[4], p_mw=0.0, vm_pu=1.03,
                       max_q_mvar=120.0, min_q_mvar=-120.0)
    pp.create_load(net, buses[4], p_mw=3.0)
    pp.runpp(net, enforce_q_lims=True, init="flat")
    warm = []
    for k in range(50):
        net.load.loc[net.load.index[0], "p_mw"] = 350.0 + 5.0 * np.sin(k)
        t0 = time.perf_counter()
        pp.runpp(net, enforce_q_lims=True, init="results")
        warm.append((time.perf_counter() - t0) * 1e3)
    p_sc = float(net.res_gen.p_mw.at[sc])
    net.gen.loc[sc, "vm_pu"] = 1.10  # unreachable target → Q must peg
    pp.runpp(net, enforce_q_lims=True, init="results")
    return {
        "converged": bool(net.converged),
        "syncon_p_mw": p_sc,
        "warm_median_ms": statistics.median(warm),
        "q_pegged_mvar": float(net.res_gen.q_mvar.at[sc]),
        "ok": bool(net.converged) and abs(p_sc) < 1e-9
              and abs(float(net.res_gen.q_mvar.at[sc]) - 120.0) < 1.0,
    }


# ---------------------------------------------------------------------------
# Spike (b): vectorized dynamics tick, 150 devices x 3 lag states
# ---------------------------------------------------------------------------

def spike_dynamics_tick(n_dev: int = 150, n_ticks: int = 100_000, dt: float = 0.010) -> dict:
    rng = np.random.default_rng(0)

    # struct-of-arrays fleet (PHYSICS §3 vectorization directives)
    s_n = rng.uniform(200.0, 2500.0, n_dev)                 # MVA
    k_droop = s_n / (0.05 * 50.0)                           # MW/Hz
    deadband = np.full(n_dev, 0.010)                        # Hz
    fcr_band = 0.05 * s_n
    p_disp = 0.7 * s_n
    p_min = np.zeros(n_dev)
    p_avail = s_n.copy()

    t_g, t_ch, t_rh = 0.2, 0.4, 8.0
    a_g = np.full(n_dev, np.exp(-dt / t_g))
    a_1 = np.full(n_dev, np.exp(-dt / t_ch))
    a_2 = np.full(n_dev, np.exp(-dt / t_rh))
    f_hp = np.full(n_dev, 0.3)

    x_g = p_disp.copy()
    x_1 = p_disp.copy()
    x_2 = p_disp.copy()

    island_of = np.zeros(n_dev, dtype=np.int64)             # single island
    boundaries = np.array([0])

    f = 50.0
    f0 = 50.0
    p_load = float(p_disp.sum())
    e_k = float((5.0 * s_n).sum())                          # MJ
    d_pu = 0.5
    k_f = dt * f0 / (2.0 * e_k)

    u = np.empty(n_dev)
    y = np.empty(n_dev)
    scratch = np.empty(n_dev)

    t0 = time.perf_counter()
    for _ in range(n_ticks):
        # droop with soft deadband, clamped to FCR band and envelope
        df = f - f0
        e = np.sign(df) * np.maximum(0.0, abs(df) - deadband)
        np.multiply(k_droop, -e, out=scratch)
        np.clip(scratch, -fcr_band, fcr_band, out=scratch)
        np.add(p_disp, scratch, out=u)
        np.clip(u, p_min, p_avail, out=u)

        # exact-exponential lag cascade
        x_g += (1.0 - a_g) * (u - x_g)
        x_1 += (1.0 - a_1) * (x_g - x_1)
        x_2 += (1.0 - a_2) * (x_1 - x_2)
        np.multiply(f_hp, x_1, out=y)
        y += (1.0 - f_hp) * x_2

        # per-island sum + semi-implicit swing update
        p_inj = np.add.reduceat(y, boundaries)[0]
        f = (f + k_f * (p_inj - p_load * (1.0 - d_pu))) / (1.0 + k_f * p_load * d_pu / f0)
    total = time.perf_counter() - t0

    return {"n_dev": n_dev, "dt_s": dt, "us_per_tick": total / n_ticks * 1e6, "f_end": f}


# ---------------------------------------------------------------------------
# Spike (d): per-machine angle dynamics — the classical COI-anchored observer
# (the phasor arc, reopens ledger 1). Proves the model is reducible from a real
# pandapower case, analytically correct, COI-consistent (< 1e-12 so the wire f
# and every §6 pin survive), captures loss-of-synchronism, is fast enough, and
# is deterministic — BEFORE any engine change.
# ---------------------------------------------------------------------------

WS = 2.0 * np.pi * 50.0  # synchronous electrical speed [rad/s]


def _pe(E, G, B, delta):
    """Classical electrical power: P_ei = E_i Σ_j E_j (G_ij cos δij + B_ij sin δij)."""
    dij = delta[:, None] - delta[None, :]
    return E * ((G * np.cos(dij) + B * np.sin(dij)) @ E)


def _classical_reduce_case9(xd_prime: float = 0.30):
    """Kron-reduce the solved WSCC 3-machine 9-bus to its generator internal
    nodes (loads as constant-impedance shunts, machines E' behind Xd'). Returns
    the reduced Y and the internal EMFs — the exact machinery Phase 1 builds."""
    import pandapower as pp
    import pandapower.networks as ppn

    net = ppn.case9()
    pp.runpp(net)
    Y = np.asarray(net._ppc["internal"]["Ybus"].todense()).astype(complex)
    b_lookup = net._pd2ppc_lookups["bus"]  # net bus idx -> ppc idx
    base = net.sn_mva
    V = net.res_bus.vm_pu.values * np.exp(1j * np.deg2rad(net.res_bus.va_degree.values))
    for li in net.load.index:
        b = int(net.load.at[li, "bus"])
        s = (net.load.at[li, "p_mw"] + 1j * net.load.at[li, "q_mvar"]) / base
        Y[b_lookup[b], b_lookup[b]] += np.conj(s) / (abs(V[b]) ** 2)
    mach_bus, pg, qg, vg = [], [], [], []
    for i in net.ext_grid.index:
        b = int(net.ext_grid.at[i, "bus"]); mach_bus.append(b)
        pg.append(net.res_ext_grid.at[i, "p_mw"] / base)
        qg.append(net.res_ext_grid.at[i, "q_mvar"] / base); vg.append(V[b])
    for i in net.gen.index:
        b = int(net.gen.at[i, "bus"]); mach_bus.append(b)
        pg.append(net.res_gen.at[i, "p_mw"] / base)
        qg.append(net.res_gen.at[i, "q_mvar"] / base); vg.append(V[b])
    ng, nb = len(mach_bus), Y.shape[0]
    xdp = np.full(ng, xd_prime)
    vg = np.array(vg); s = np.array(pg) + 1j * np.array(qg)
    e_int = vg + 1j * xdp * np.conj(s / vg)  # E' = V + jXd' conj(S/V)
    n = ng + nb
    yaug = np.zeros((n, n), complex)
    yaug[ng:, ng:] = Y
    yg = 1.0 / (1j * xdp)
    ppc_mb = [b_lookup[b] for b in mach_bus]
    for k in range(ng):
        yaug[k, k] += yg[k]
        yaug[k, ng + ppc_mb[k]] -= yg[k]
        yaug[ng + ppc_mb[k], k] -= yg[k]
        yaug[ng + ppc_mb[k], ng + ppc_mb[k]] += yg[k]
    a, bm = yaug[:ng, :ng], yaug[:ng, ng:]
    c, d = yaug[ng:, :ng], yaug[ng:, ng:]
    y_red = a - bm @ np.linalg.solve(d, c)  # reduced to internal nodes
    return y_red, np.abs(e_int), ng


def _two_machine_mode(H=(5.0, 5.0), X=0.5, E=(1.1, 1.1), pm=0.5, dt=0.001, T=6.0):
    """Integrate the observer swing on a 2-machine island; return the analytic
    inter-machine mode frequency and the measured one (mean crossing period)."""
    B = np.array([[-1.0 / X, 1.0 / X], [1.0 / X, -1.0 / X]])
    G = np.zeros((2, 2)); em = np.array(E)
    pmax = em[0] * em[1] / X
    d0 = np.arcsin(pm / pmax)
    p_mech = _pe(em, G, B, np.array([d0, 0.0])).copy()
    k = pmax * np.cos(d0)  # synchronizing coefficient
    hs = np.array(H)
    f_analytic = (1.0 / (2 * np.pi)) * np.sqrt(WS * k * (hs[0] + hs[1]) / (2 * hs[0] * hs[1]))
    delta = np.array([d0 + 0.02, 0.0]); omega = np.zeros(2)
    minv = WS / (2.0 * hs)
    n = int(T / dt); trace = np.empty(n)
    for j in range(n):
        omega = omega + dt * minv * (p_mech - _pe(em, G, B, delta))
        delta = delta + dt * omega  # symplectic Euler (δ against post-update ω)
        trace[j] = delta[0] - delta[1]
    sig = trace - trace.mean()
    up = np.where((sig[:-1] <= 0) & (sig[1:] > 0))[0]
    tc = np.array([(i + sig[i] / (sig[i] - sig[i + 1])) * dt for i in up])
    return f_analytic, 1.0 / np.mean(np.diff(tc))


def _coi_projection_identity() -> float:
    """After the tick projection ω_i += (f_coi − ω_COI), the inertia-weighted
    mean speed EQUALS the Tier-1 COI f — the pin that keeps the wire f exact."""
    h = np.linspace(3.0, 8.0, 7); sn = np.linspace(300.0, 1600.0, 7)
    w = 2.0 * h * sn
    omega = np.array([0.03, -0.02, 0.05, -0.01, 0.00, 0.04, -0.03])
    f_coi_dev = 49.987 - 50.0
    omega_p = omega + (f_coi_dev - np.sum(w * omega) / np.sum(w))
    return abs(np.sum(w * omega_p) / np.sum(w) - f_coi_dev)


def _loss_of_sync(x_perm: float | None = None, dt=0.002, T=6.0, kick=0.02):
    E = np.array([1.1, 1.1]); G = np.zeros((2, 2))
    x0, pm = 0.5, 0.5
    d0 = np.arcsin(pm / (E[0] * E[1] / x0))
    b0 = np.array([[-1.0 / x0, 1.0 / x0], [1.0 / x0, -1.0 / x0]])
    p_mech = _pe(E, G, b0, np.array([d0, 0.0])).copy()
    x = x_perm if x_perm is not None else x0
    B = np.array([[-1.0 / x, 1.0 / x], [1.0 / x, -1.0 / x]])
    minv = WS / (2.0 * np.array([5.0, 5.0]))
    delta = np.array([d0 + kick, 0.0]); omega = np.zeros(2); slipped = False
    for _ in range(int(T / dt)):
        omega = omega + dt * minv * (p_mech - _pe(E, G, B, delta))
        delta = delta + dt * omega
        if abs(delta[0] - delta[1]) > np.pi:
            slipped = True
    return slipped


def _pe_perf(ng: int, ticks: int = 2000) -> float:
    rng = np.random.default_rng(1)
    E = rng.uniform(0.9, 1.15, ng)
    G = rng.uniform(-1, 1, (ng, ng)); G = (G + G.T) / 2
    B = rng.uniform(-5, 5, (ng, ng)); B = (B + B.T) / 2
    delta = rng.uniform(-0.5, 0.5, ng)
    t0 = time.perf_counter()
    for _ in range(ticks):
        _pe(E, G, B, delta)
    return (time.perf_counter() - t0) / ticks * 1e6


def spike_angles() -> dict:
    y_red, e_mag, ng = _classical_reduce_case9()
    sym = float(np.max(np.abs(y_red - y_red.T)))
    f_an, f_num = _two_machine_mode()
    mode_err = abs(f_an - f_num) / f_an
    coi_resid = _coi_projection_identity()
    slip_cleared = _loss_of_sync()            # small kick, intact tie -> bounded
    slip_perm = _loss_of_sync(x_perm=3.0)     # permanent weak tie -> pole slip
    det = _two_machine_mode()[1] == f_num
    return {
        "machines": ng,
        "reduced_sym_maxabs": sym,
        "mode_analytic_hz": f_an,
        "mode_numeric_hz": f_num,
        "mode_err_pct": mode_err * 100.0,
        "coi_residual": coi_resid,
        "sync_bounded": not slip_cleared,
        "sync_pole_slip": slip_perm,
        "us_per_tick_180": _pe_perf(180),
        "deterministic": det,
        "ok": sym < 1e-9 and mode_err < 0.01 and coi_resid < 1e-12
        and (not slip_cleared) and slip_perm and det,
    }


def main() -> None:
    for n in (20, 300):
        print(f"== Spike (a): pandapower NR, {n}-bus 380 kV meshed, enforce_q_lims ==")
        pf = spike_powerflow(n)
        for k, v in pf.items():
            print(f"  {k:26s} {v:.3f}" if isinstance(v, float) else f"  {k:26s} {v}")

    print("== Spike (c): syncon as a P=0 controllable gen (C6/D4) ==")
    for k, v in spike_syncon().items():
        print(f"  {k:26s} {v:.3f}" if isinstance(v, float) else f"  {k:26s} {v}")

    print("== Spike (b): NumPy dynamics tick, 150 devices x 3 lag states ==")
    for dt in (0.010, 0.250):
        d = spike_dynamics_tick(dt=dt)
        print(f"  dt={dt*1e3:5.0f} ms   {d['us_per_tick']:.2f} us/tick   (f_end={d['f_end']:.6f})")

    print("== Spike (d): per-machine angle observer (phasor arc, ledger 56) ==")
    a = spike_angles()
    print(f"  case9 machines={a['machines']}  reduced-Y |Y-Y^T|max={a['reduced_sym_maxabs']:.2e}")
    print(f"  inter-machine mode  analytic={a['mode_analytic_hz']:.4f} Hz  "
          f"numeric={a['mode_numeric_hz']:.4f} Hz  err={a['mode_err_pct']:.2f}%")
    print(f"  COI-projection residual={a['coi_residual']:.2e} (< 1e-12 keeps the wire f exact)")
    print(f"  loss-of-sync  cleared-bounded={a['sync_bounded']}  permanent-pole-slip={a['sync_pole_slip']}")
    print(f"  P_e matvec @180 machines={a['us_per_tick_180']:.1f} us/tick  deterministic={a['deterministic']}")
    print(f"  ok={a['ok']}")

    import numba, pandapower
    print(f"== versions: pandapower {pandapower.__version__}, numba {numba.__version__}, numpy {np.__version__} ==")


if __name__ == "__main__":
    main()
