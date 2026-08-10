"""Runtime library-verification harness (rtheatflow rule: verify before trusting).

P0 feasibility spikes — run on the dev machine, paste the printed tables into
docs/adr/004-measured-budgets.md:

  (a) pandapower AC Newton-Raphson on a 20-bus 380 kV meshed net:
      cold vs warm-start solve times, enforce_q_lims behavior, iwamoto
      fallback availability, std_type existence.
  (b) vectorized NumPy dynamics tick for 150 devices x 3 lag states
      (struct-of-arrays, exact-exponential updates, droop/deadband/clamps,
      per-island reduceat, semi-implicit swing): us/tick at dt=10 ms and 250 ms.

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


def main() -> None:
    for n in (20, 300):
        print(f"== Spike (a): pandapower NR, {n}-bus 380 kV meshed, enforce_q_lims ==")
        pf = spike_powerflow(n)
        for k, v in pf.items():
            print(f"  {k:26s} {v:.3f}" if isinstance(v, float) else f"  {k:26s} {v}")

    print("== Spike (b): NumPy dynamics tick, 150 devices x 3 lag states ==")
    for dt in (0.010, 0.250):
        d = spike_dynamics_tick(dt=dt)
        print(f"  dt={dt*1e3:5.0f} ms   {d['us_per_tick']:.2f} us/tick   (f_end={d['f_end']:.6f})")

    import numba, pandapower
    print(f"== versions: pandapower {pandapower.__version__}, numba {numba.__version__}, numpy {np.__version__} ==")


if __name__ == "__main__":
    main()
