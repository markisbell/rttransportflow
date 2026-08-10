# ADR-004 — Measured performance budgets (P0 feasibility spikes)

Status: accepted · Phase: P0 · Date: 2026-08-10
Measured on: Linux x86_64, 20 cores, Python 3.12.13 —
`scripts/validate_core.py` (re-run it after environment changes; CI asserts
the budget at a relaxed multiplier from P2 on).

Versions: pandapower 3.5.4 · numba 0.66.0 · numpy 2.4.6

## Spike (a) — pandapower AC NR, 380 kV meshed nets, `enforce_q_lims=True`

Topology: self-balanced 20-bus regional meshes (ring + chords, 12×750 MW
load vs 7×1300 MW gen + slack) chained by short tie lines — the shape the
game's topology builder actually produces. All solves converged; Q-limit
enforcement and the iwamoto fallback verified present.

| n_buses | first solve (JIT warmup) | cold median (init="dc") | cold p95 | warm median (init="results") | warm p95 |
|---|---|---|---|---|---|
| 20  | **1457 ms** | 7.36 ms | 7.87 ms | 4.67 ms | 4.85 ms |
| 300 | 10.8 ms (already warm) | 9.98 ms | 10.55 ms | **5.16 ms** | 5.46 ms |

Findings:

- **Warm-start NR at the 300-bus reference size costs ≈ 5.2 ms** — inside
  the ≤ 8 ms budget (ROADMAP table). Sparse NR scales gently: 15× the buses
  costs ~10 % more warm time; the Python layer dominates at small sizes.
- **The ~1.5 s numba JIT lands entirely on the first solve** — the family
  warmup-at-reset rule is confirmed load-bearing (`warmup_solve_ms` in the
  reset response).
- A physically degenerate operating point (segment deficits dragged across a
  36 000 km ring) reliably diverges — the family lesson "realistic operating
  points or the solver refuses" applies to authored scenarios too.

## Spike (b) — vectorized dynamics tick, 150 devices × 3 lag states

Droop with soft deadband + FCR-band/envelope clamps, exact-exponential
3-stage lag cascade, per-island `reduceat` sum, semi-implicit swing update;
struct-of-arrays, no Python objects in the loop; 100 000 ticks.

| dt | µs/tick |
|---|---|
| 10 ms (ALERT) | **11.26** |
| 250 ms (CALM) | **11.29** |

Findings:

- 11.3 µs/tick at the 150-device reference — inside the ≤ 15 µs budget.
  **numba is NOT needed for the tick loop** (it stays a declared dependency
  because pandapower's solver uses it — family rule).
- Tick cost is dt-independent (coefficients precomputed per mode-dt), as
  designed.

## Resulting budget check (PHYSICS §3 worst cases, this machine)

| scenario | dynamics | PF | total/wall-s | budget |
|---|---|---|---|---|
| ALERT, speed 10 | 1 000 ticks ≈ 11 ms | 10 × 5.2 ms = 52 ms | **≈ 65 ms** | < 100 ms ✓ |
| CALM, speed 900× | 3 600 ticks ≈ 41 ms | 30 × 5.2 ms = 156 ms | **≈ 200 ms** | < 250 ms ✓ |

PF dominates everywhere; `pf_interval_calm` (30 s → 60 s) halves the CALM
worst case if ever needed. Feasibility confirmed — no architecture change
required.
