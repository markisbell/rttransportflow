# PHYSICS.md — simulation engine design

Authority: equations, integration scheme, tick order, protection logic, engine
module design, and validation tests (SPEC §0.2). Per-technology *numbers* live
in [PARAMETERS.md](PARAMETERS.md) — the table in §2.4 here is a courtesy copy
of the dynamics subset.

Status: design, validated numerically 2026-08-10 — a reference scheme check
(semi-implicit swing + exact-lag integrator) reproduced analytic RoCoF to
0.11 % at dt = 10 ms, quasi-steady-state Δf to < 0.01 %, step-slicing identity
bit-exact, 6.9 µs per dynamics tick measured for 100 devices × 3 states in
NumPy.

---

## 0. Summary of the design

**Strict puppet stepping with a variable-size step, a fixed-timestep internal
multi-rate integrator, and trajectory buffers returned per step.** The game
owns time exactly as in contract v1: one WS frame in → one frame out,
idempotent `t`, out-of-order → 409, divergence is data. New in v2:

1. `dt_s` is a float in [0.05, 900]. The game sizes it from its speed setting;
   the backend's evolution is **independent of how the game slices time**:
   engine state, events, and telemetry samples at shared sim-time instants are
   bit-identical across slicings (pinned by test). (The *wire* trajectory's
   per-step ≤512-sample decimation is per step and therefore not itself
   slicing-invariant — compare at shared sample instants.)
2. Inside each step the engine integrates a **per-island center-of-inertia
   (COI) swing equation + per-plant governor/turbine/battery ODEs** at a fixed
   internal tick (10 ms in ALERT mode, 250 ms in CALM mode — chosen by a
   deterministic state-based hysteresis controller), and runs **pandapower AC
   Newton-Raphson power flow** at scheduled sim-time instants (1 s cadence in
   ALERT, 30 s in CALM, plus immediately on every event) for flows, voltages,
   losses, reactive power, and flow-based protection.
3. The step result carries a **decimated frequency/RoCoF trajectory + exact-
   timestamped events + the latest PF frame + per-window PF extremes**, so the
   game renders 10 ms-resolution dynamics at 60 fps with the family's
   one-step-lag playback.
4. **Early return on event**: a step may return having consumed only part of
   the requested `dt_s` when a significant event fires. The game sees the
   event, drops its speed, and continues stepping from where the backend
   stopped. This reconciles 900× acceleration with 10 ms dynamics — and it is
   the right gameplay (auto-slowdown on incident).
5. All device dynamics are **first-order lags integrated with the exact
   exponential update** (unconditionally stable — a 100 ms battery lag survives
   a 250 ms CALM tick with zero stiffness pathology); the swing uses
   **semi-implicit Euler with implicit load damping** (one scalar division, no
   solver). Everything is struct-of-arrays NumPy; no per-device Python objects
   in the hot loop.

**Rejected alternatives** (brief):

- *Backend free-runs dynamics at accelerated wall-clock; game consumes an async
  push stream.* Breaks every family invariant at once: two clocks race, pause
  needs cross-process coordination, save/load races a live integrator,
  wall-clock jitter kills reproducibility, and the push stream inverts the
  one-in/one-out WS contract the contract suite pins.
- *Two separate wire tiers (coarse energy steps + fine dynamic ticks as
  distinct message types).* Variable `dt_s` + early return subsumes it with one
  code path, one idempotency story, one contract table.

---

## 1. Multi-rate architecture

### 1.1 Time model

- **Sim time** `t_sim` (float seconds since scenario start) is owned by the
  backend but only advances when the game asks. Wire **`t`** is a monotonically
  increasing integer **sequence number** (not sim time — `dt_s` varies), used
  for idempotency exactly like v1: re-send of last `t` returns the cached
  result *before any state is applied*; any other `t` than
  `last_t`/`last_t+1` → 409 / `out_of_order`.
- `step(t, dt_s)` means "advance sim time by *up to* `dt_s`". The result
  reports `dt_done_s` and `t_sim_end`; `dt_done_s < dt_s` happens only via
  early return on event (§1.4). The game's clock advances by what the backend
  *did*, not by what it asked — the backend's answer is authoritative.
- **Game stepping recipe** (documented in the contract, implemented game-side):
  step at ~10 Hz wall with `dt_s = 0.1 × speed`, clamped to [0.05, 900].
  Speed 1 → 0.1 s steps (near-realtime event watching); speed 300 → 30 s;
  speed 9000 (strategic fast-forward) → 900 s. 9000× is the *requested*
  ceiling — sustained realized speed is whatever the §3 budget carries
  (~900–3600×); the shortfall is absorbed by skip-never-stall, never by
  blocking. One in-flight step, one-step lag, skip-never-stall — inherited
  from the infrastruct Orchestrator unchanged. The game's economy layer aggregates on 15-min sim-time boundaries
  regardless of slicing (GAME_DESIGN §3.1).

### 1.2 Internal integrator loop (the heart)

```
def _advance(self, target_t_sim, interrupt_on_event):
    while self.t_sim < target_t_sim - EPS:
        ev = self.event_queue.peek()                     # next scheduled event time
        dt = min(self.mode.dt,                           # 0.010 (ALERT) or 0.250 (CALM)
                 next_pf_time - self.t_sim,
                 next_sample_time - self.t_sim,
                 (ev.t - self.t_sim) if ev else INF,
                 target_t_sim - self.t_sim)
        self._tick(dt)                                   # §2.6 — devices, swing, SoC, f-protection
        self.t_sim += dt
        if ev and self.t_sim >= ev.t - EPS:
            fired = self._apply_events()                 # discrete state change, may split islands
            self._run_pf(reason="event")                 # immediate PF after any event
            self.mode.enter_alert()
            if interrupt_on_event and fired.significant:
                return EARLY_RETURN
        if self.t_sim >= next_pf_time - EPS:
            self._run_pf(reason="scheduled")             # §2.5
        self._maybe_sample()                             # telemetry ring + step trajectory buffer
        self.mode.update(self.islands)                   # deterministic hysteresis, §1.3
    return COMPLETE
```

Rules that make this deterministic and slicing-invariant:

- The tick never steps **across** an event, a PF instant, a sample instant, or
  the step boundary — `dt` shrinks to land exactly on them. Landing exactly on
  the step boundary is what makes `10 × step(1 s)` bit-identical to
  `1 × step(10 s)` (validated: bit-identical).
- `next_pf_time` and `next_sample_time` are absolute sim-time schedules
  (`k · pf_interval`), **not** offsets from step boundaries.
- The mode controller reads only sim state and the event queue — never `dt_s`,
  never wall time.
- **No RNG in the engine.** All stochasticity (weather, demand noise, random
  outage draws) lives game-side; the engine executes only *scheduled* events it
  was told about or that its own deterministic protection generated. Sole
  exception: pole-slip draws (§2.7) use a PRNG seeded from the reset doc's
  `protection_seed` — deterministic given the seed.

### 1.3 ALERT/CALM mode controller (deterministic dual-rate)

| | ALERT | CALM |
|---|---|---|
| dyn tick `dt` | **10 ms** | **250 ms** |
| PF cadence | **1 s** sim | **30 s** sim (config) |
| trajectory sampling | every 20 ms | every 1 s |

- **Enter ALERT** immediately when: any event fires (trip, breaker, UFLS,
  split, setpoint step > 5 % of island load), or |Δf| > 50 mHz, or
  |RoCoF| > 25 mHz/s on any island.
- **Return to CALM** when, for 30 consecutive sim-seconds: |Δf| < 30 mHz and
  |RoCoF| < 10 mHz/s on every island, no relay timer running, and no queued
  event within the next 5 s.
- Hysteresis constants are config values; the slicing-identity test must cover
  a window containing a mode transition.
- Numerical safety: the 250 ms CALM tick is safe for every model because all
  lags use the exact exponential update (unconditionally stable, no overshoot —
  validated at dt = 5·T) and the swing's damping term is implicit. CALM merely
  under-resolves transients — fine, because any transient worth resolving
  raises ALERT at the event that caused it.

### 1.4 Early return on event

- Request field `interrupt_on_event: true` (default). "Significant": device
  trip (any cause), UFLS stage, island split/merge, blackout, line trip. Not
  significant: warning-level violations, deadband entries, mode changes.
- On early return the result is a complete, normal result for
  `[t_sim_start, t_sim_end]` with `dt_done_s < dt_s` and the triggering event
  last in `events[]`. Nothing special is cached — the idempotency cache holds
  it like any other result.
- Slicing invariance is preserved by construction: early return just changes
  the slicing.
- Worst case bounded: with `interrupt_on_event`, a step never runs more than
  ~1 tick of ALERT beyond the event. With `interrupt_on_event: false`
  (batch/headless analysis), the worst case is 900 s fully in ALERT ≈ 90 000
  ticks + 900 PF ≈ 0.6 s ticks + 3–9 s PF — legal; the game's skip-never-stall
  absorbs it. Document; don't forbid.

### 1.5 Pause / speed / save / rendering

- **Pause**: the game stops sending steps; the backend is inert between steps.
- **Speed**: purely game-side `dt_s` sizing. Backend enforces only the range.
- **Save/load**: `GET /gb/snapshot` returns the full versioned engine state
  (§4 `snapshot.py`); restore = `/gb/net/reset` with topology + `snapshot`
  blob. Pinned by the bit-replay test.
- **60 fps rendering**: the game plays back the trajectory of step *t−1* while
  step *t* is in flight. At 10 Hz stepping this is a 100–200 ms broadcast
  delay — imperceptible on a frequency dial — and the 20 ms ALERT sample
  spacing interpolates smoothly. The needle visibly *jumps* at a trip and
  *dives* through the nadir because those samples are really in the buffer.

---

## 2. Physics layering

### 2.1 Honesty section (mirror in SPEC, docs, and the game UI)

**Modeled:** per-island uniform frequency (COI swing with aggregated inertia),
per-plant governor/turbine dynamics with distinct type parameters, battery FFR
with SoC, grid-forming virtual inertia, load frequency damping, AGC
restoration, frequency/RoCoF/flow protection with relay delays, UFLS, island
splits and blackouts, quasi-static AC network (flows, voltage magnitudes,
reactive power, losses) at 1 s/30 s cadence, the H₂ fuel chain.

**Not modeled (say so; do not fake it):** inter-machine rotor-angle swings and
inter-area oscillation modes (frequency is uniform per island by construction),
transient/voltage stability, loss of synchronism (splits happen only via
protection-driven line trips), AVR/exciter dynamics (voltage setpoints held
quasi-statically between PF solves), LFSM-U (ledger 22 — headroom release is
covered by aFRR/mFRR dispatch), EMT phenomena. This is the correct
fidelity for the pedagogical target: RoCoF, nadir depth, governor speed, FFR,
QSS offset, AGC restoration, and the UFLS cascade all live in the COI +
primary-control layer and are reproduced *endogenously* from the fleet's
H, R, T parameters — never scripted.

### 2.2 Conventions

Engineering units throughout: **MW, MVA, Hz, seconds, MJ (= MW·s)**. Per-unit
appears in exactly two places: droop `R` (pu on machine base) and load damping
`D` (pu). `f0 = 50.0`. The two pu constants are converted to MW/Hz gains once
at fleet build — this avoids the classic multi-base bug farm.

### 2.3 Per-island COI swing equation

Islands = connected components of the in-service grid graph (recomputed on
every topology-changing event by `islands.py`). Per island *a*:

- Kinetic constant: `E_k,a = Σ_{i∈a, online, sync} H_i · S_n,i` [MJ]. Only
  *online synchronous* machines and grid-forming converters (with their
  virtual `H_v`) count; grid-following wind/PV/battery/electrolyzers
  contribute 0. Recomputed on every connect/trip event — this is the mechanism
  by which "replacing coal with PV" raises RoCoF, for free.
- Swing:

  ```
  (2·E_k,a / f0) · df_a/dt = P_mech,a + P_inv,a − P_load,a(f_a) − P_loss,a − P_tie,a
  ```

  with `P_mech,a = Σ_i y_i` (turbine outputs, §2.4); `P_inv,a` = net
  grid-following inverter injections (wind + PV + battery discharge − battery
  charge − electrolyzers); `P_load,a(f) = P_L0,a · w_a · (1 + D·(f_a−f0)/f0)`
  where `P_L0,a` = zone demand ledger sum (sample-and-hold from the last step
  request), `w_a ∈ (0,1]` = surviving load fraction after UFLS, and
  **D = 0.5 pu default (= 1 %/Hz load self-regulation, ENTSO-E value; config
  range 0.5–1.0 pu = 1–2 %/Hz)**. `P_loss,a` = network losses, sample-and-hold
  from the last PF (§2.5). `P_tie,a` = scheduled net export to other AGC areas
  (0 until multi-area; after an island split, tie terms across the cut vanish
  with the lines).
- **RoCoF identity** (the pedagogical core): immediately after losing ΔP MW,
  `df/dt = −ΔP·f0 / (2·E_k,a)`. Validated: the dt=10 ms integrator reproduces
  this to 0.11 %.

**Semi-implicit update** (per tick, after device updates give
`P_inj ≡ P_mech + P_inv`; let `k_f = Δt·f0 / (2·E_k,a)`):

```
f⁺ = [ f + k_f·(P_inj − P_loss − P_L0·w·(1 − D)) ] / [ 1 + k_f·P_L0·w·D / f0 ]
```

One division, unconditionally stable in the damping term (algebra validated:
QSS error < 0.01 %).

### 2.4 Device dynamic models — one common realization, distinct parameters

Every dispatchable device is realized as (per device *i*, all arrays):

1. **Dispatch slew**: `P_disp,i` moves toward the commanded dispatch at
   `ramp_i` MW/min (the *economic* ramp — what makes nuclear ponderous and
   OCGT nimble for dispatch).
2. **Primary (droop) response**, bypassing the dispatch slew:
   `ΔP_prim,i = −K_i · db(f_a − f0)`, `K_i = S_n,i / (R_i·f0)` [MW/Hz], soft
   deadband `db(x) = sign(x)·max(0, |x| − db_i)`, clamped to the unit's FCR
   band `± fcr_band_i` and to `[P_min,i, P_avail,i]` headroom.
3. **Governor lag**: `u_i = P_disp,i + ΔP_prim,i + ΔP_AGC,i`;
   `x_g ← u + (x_g − u)·exp(−Δt/T_g,i)`.
4. **Turbine** (IEEE steam-reheat form covers all thermal):
   `x_1 ← x_g + (x_1 − x_g)·exp(−Δt/T_CH,i)`;
   `x_2 ← x_1 + (x_2 − x_1)·exp(−Δt/T_RH,i)`;
   output `y_i = F_HP,i·x_1 + (1−F_HP,i)·x_2`. Continuous transfer function
   `(1 + F_HP·T_RH·s) / ((1+T_CH·s)(1+T_RH·s))`.
   **Hydro** (pumped hydro, generating) uses PARAMETERS §1.10: transient-droop
   compensator (one lead-lag state) → gate servo → non-minimum-phase water
   column `(1 − T_W·s)/(1 + ½T_W·s)`, realized exactly as `y = P_n·(3x_h − 2g)`
   with `x_h ← g + (x_h − g)·exp(−Δt/(0.5·T_W))` — the initial *reverse* power
   swing on a hydro governor action is real physics the player gets for free.
5. **All lag updates use the per-stage exact exponential discretization**
   `x⁺ = u + (x − u)·exp(−Δt/T)` — exact for that stage's piecewise-constant
   input, unconditionally stable, no overshoot at any dt (validated at
   dt = 5·T). In a cascade the downstream stage sees a varying input, so the
   *global* cascade error is O(Δt) (~4·10⁻⁴ vs the continuous closed form at
   dt = 10 ms — accepted; ledger 21): ALERT resolves transients, CALM
   deliberately under-resolves them. Coefficient vectors `exp(−Δt/T)` are
   precomputed per mode-dt (two cached vectors, invalidated on fleet change).

**Dynamics parameter summary** (courtesy copy — [PARAMETERS.md](PARAMETERS.md)
is authoritative):

| type | H [s] | R [pu] | db [mHz] | T_g [s] | turbine | FCR band | dispatch ramp |
|---|---|---|---|---|---|---|---|
| nuclear | 6.0 | 0.05 | 20 | 0.2 | T_CH 0.3, T_RH 8, F_HP 0.30 | ±2 % P_n (game default: participation off) | 2 %/min |
| coal | 4.0 | 0.05 | 10 | 0.2 | T_CH 0.3, T_RH 10, F_HP 0.30 | ±5 % | 3 %/min |
| lignite | 4.0 | 0.05 | 10 | 0.2 | as coal | ±5 % | 2 %/min |
| gas_ccgt | 4.5 | 0.04 | 10 | — | GT path T1 0.4, T2 1.0 (2/3 share) + steam tail T_ST 120 (1/3) | ±5 % | 4 %/min |
| gas_ocgt | 3.0 | 0.04 | 10 | — | GAST T1 0.3, T2 0.8 | ±10 % | 15 %/min |
| hydro_ps | 3.5 | 0.04 | 10 | 0.5 | transient droop T_r 6, r_t 0.4; T_W 1.5 | ±10 % | 30 %/min (PARAMETERS §1.10) |
| wind / pv | 0 | — | — | — | availability-capped setpoint following, T 0.1–2 s; LFSM-O above 50.2 Hz | — | instant |
| battery (GFL) | 0 | FFR: full at ±200 mHz | 10 | — | T_b 0.1 | ±100 % | instant |
| battery (GFM) | H_v 4 (virtual, counts in E_k) | 0.02, no db | 0 | — | T_gfm 0.05 | ±100 % (1.2 pu ≤ 2 s) | instant |
| electrolyzer | 0 (load) | opt. shed-based | 10 | — | T_e 0.3 | load-shed band | unconstrained (T_e only) |
| hvdc / offshore_hub | 0 | — | — | — | T_hvdc 0.1; hub: P = min(avail_mw, rating) − losses, LFSM-O at the onshore terminal; link: paired ±P, frequency-neutral in-island (PARAMETERS §1.16); Q ±0.4·P_max at any P, per terminal | — | instant (link control) |

Battery/electrolyzer are inverter devices: their "turbine" is a single fast
lag; the exact update makes T = 50–100 ms perfectly integrable even at the
250 ms CALM tick. `hvdc` links are paired ±P injections (one command per
link, losses split per PARAMETERS §1.16); both terminals of an embedded link
sit in the same island, so a link trip **cancels in the COI ledger** (net ≈
its losses) — it is a flow-redistribution contingency handled by the PF +
overload-protection layer, frequency-neutral by construction, and LFSM-O is
therefore *not* applied to links within one island. An `offshore_hub` is a
single injection at its onshore bus whose game-aggregated farm availability
arrives per step as `avail_mw` — its trip removes the full delivery in one
ΔP step and enters the island ledger like any device trip, which is what
makes a big hub the system's reference incident. SoC clamps mirror the v1 gamebridge battery (signed P,
charge/discharge efficiency per PARAMETERS §1.11, energy-bound clamp over Δt,
`clamped` info violation); SoC integrates in ticks (ticks always run — PF
divergence stops flow/loss refresh, never SoC).

### 2.5 PF ↔ dynamics coupling (the ledger pattern)

The **ledger** (power balance in MW per island) drives frequency between PF
instants; **PF** is a quasi-static snapshot that redistributes flows and
refreshes the loss estimate. At each PF instant (per island, `powerflow.py`):

1. Write injections into the prebuilt pandapower net (build-once,
   element-index maps): each machine/inverter `p_mw` = its current dynamic
   output `y_i` or `P_inv,i`; generator buses are PV nodes at their
   `vm_setpoint` with `enforce_q_lims=True`; zone loads =
   `P_L0,z·w_z·(1 + D·Δf/f0)` with registered `q` (default pf 0.97 inductive);
   inverters at unity pf unless `q_mvar` commanded.
2. Slack = bus of the largest online sync machine in the island (or a
   grid-forming battery — v1 concept — for machine-less islands; no slack
   candidate ⇒ blackout state: zones unsupplied, skip PF).
3. Solve with the family retry ladder (`init="results"` → `"flat"` → iwamoto,
   catch-all exception arm; non-convergence = degraded frame, never a crash).
4. On convergence: update `P_loss,a`; collect bus V, line/trafo loadings, Q;
   run flow-based protection (§2.7); record violations (family thresholds:
   loading > 100 warning / > 120 critical; vm outside 0.95–1.05 / 0.90–1.10).
5. **No double counting**: the slack machine's ledger contribution is its
   *dynamic model output* `y_i`, never the PF slack residual. The residual is
   precisely the loss-estimate error; it self-corrects through the `P_loss`
   update at the next instant (geometric decay; settling pinned by test).
6. On divergence: hold previous `P_loss` and flows (sample-and-hold), mark the
   frame degraded, reset warm-start state — frequency dynamics continue
   uninterrupted on the ledger.

### 2.6 Tick order (normative)

Per island, per tick: (1) compute `u_i` from `f` (deadband → droop → clamps →
+ slewed dispatch + AGC signal); (2) exact-update all lag states, apply output
clamps → `y_i`, `P_inv,i`; (3) H₂ fuel check (§2.8) may derate; (4)
semi-implicit frequency update (§2.3); (5) integrate SoC / H₂ mass / energy
meters (trapezoid); (6) advance frequency-protection relay timers against
`f⁺`, enqueue trips; (7) sample telemetry if due. Events apply only *between*
ticks (§1.2).

### 2.7 Protection (`protection.py`) — explicit relay delays, everything is an event

Threshold values: PARAMETERS §2.2 is authoritative. Mechanics:

- **UFLS** per island: 6 stages 49.0 / 48.8 / 48.6 / 48.4 / 48.2 / 48.0 Hz,
  each shedding 7.5 % of original island load (cumulative 45 %; `w_a`
  multiplies down), 150 ms pickup delay each. Stages latch (once per event, no
  chattering); restoration is a game command (`restore_load`), ramped, allowed
  only per PARAMETERS §2.2 re-arm rules.
- **Automatic load relief before UFLS**: pumped-hydro pumping trips at
  49.7 Hz; electrolyzers shed at 49.6 Hz (interruptible tier).
- **Generator f-windows**: synchronous machines trip outside [47.5, 51.5] Hz
  after 100 ms; converters ride through 47.5–51.5 Hz (RfG), trip outside.
  Above **50.2 Hz** all generation applies **LFSM-O** continuous curtailment
  (5 % droop: reduce by 40 % of current P per Hz above 50.2) before any trip at
  51.5 — over-frequency feels right without mass-disconnection cliffs.
- **RoCoF effects** (500 ms filtered): per the PARAMETERS §2.2 feel table.
  Embedded-DG trips at ≥ 0.5 / ≥ 1.0 Hz/s remove the stated percentage of the
  island's embedded generation (`embedded_dg_frac` × island load, PARAMETERS
  §2.2), which raises island net load by that MW; latched per event, restored
  with load restoration, `rocof_dg_trip` event emitted. At ≥ 2.0 Hz/s each
  sync unit trips with 20 % probability drawn from the `protection_seed` PRNG
  (deterministic per scenario+event sequence).
- **Line/trafo overload** (at PF instants): loading > 150 % → trip at next PF
  frame; > 120 % → integrate an overload duty counter (loading-weighted
  seconds), trip when duty exceeds the equivalent of 60 s at 120 %; duty decays
  below 100 %. Cascading outages then emerge naturally: trip → PF →
  redistribution → next overload → island split → per-island frequency
  divergence. The end-game scenario requires zero special code.
- **Island split**: new islands inherit `f = f_parent` (COI approximation),
  their own `E_k`, ledger, AGC. **Merge/resync** (line breaker close between
  live islands — via the wire `line_commands` or a scheduled `line_close`
  event) allowed only when |Δf| < 200 mHz across the breaker, else rejected
  with a violation (angle-difference realism without angle dynamics).
- **UFLS island↔zone mapping**: the island shed factor `w_a` applies as a
  uniform fraction to every member zone (`supplied_z = w_a`, modulated by any
  congestion shedding); `zone_commands.restore_load` aggregates load-weighted
  per island to raise `w_a`; stage latches and re-arm live per island
  (PARAMETERS §2.2).

### 2.8 Secondary control (AGC) and the H₂ chain

- **AGC** per control area (launch: one area = the main synchronous island):
  `ACE_a = ΔP_tie,a + B_a·Δf_a` with the textbook bias
  `B_a = Σ_i K_i + D·P_L0,a/f0` [MW/Hz] (ledger 19; PARAMETERS §2.1 mirrors
  this); PI `ΔP_AGC = −(K_P·ACE + K_I·∫ACE dt)`, `K_P = 0.1`,
  `K_I = 1/120 s⁻¹`, anti-windup at total participating headroom; distributed
  by participation factors — **default ∝ contracted `afrr_band_mw`,
  overridable via the game command `agc_participation`** — and pushed through
  each unit's dispatch slew, so AGC restoration is visibly slow when only
  coal/nuclear participate, another felt lesson. Integrator state is in the
  snapshot.
- **H₂**: an electrolyzer consuming `P_e` produces
  `ṁ = 1000·P_e / η_spec(P_e)` kg/h into a named `h2_store` (kg,
  capacity-capped, injection/withdrawal rate limits and compressor auxiliary
  load per PARAMETERS §1.13–1.14). A gas plant with `fuel: "h2"` draws
  `ṁ = 1000·y_i / (η_plant(P)·33.33)` kg/h (LHV 33.33 kWh/kg; η per
  PARAMETERS §1.6). Store at its 5 % cushion floor ⇒ `fuel_starved` event:
  the plant derates to what withdrawal allows, then ramps to 0 over 10 s
  (forced dispatch slew) and stays unavailable until the store recovers above
  the floor + 2 % — a physical constraint the engine must own because it gates
  primary-reserve availability mid-event. Natural gas is unconstrained (cost
  is game-side). Per-device energy/fuel meters per step feed game-side billing.

---

## 3. Performance budget (measured + estimated, 2026-08-10, Linux x86-64)

| item | cost | basis |
|---|---|---|
| dyn tick (100 devices, 3 lag states, swing, clamps) | **6.9 µs** | measured, NumPy, this design's exact update |
| pandapower NR, 300 buses, warm start | 3–6 ms | family experience (netzsim ~100-bus low-single-digit ms; sparse NR scales gently); cold ≤ 20 ms; numba warmup at reset |
| PF Python-layer overhead | 2–4 ms | pandapower result collection |

**Wall cost per 1 s of wall time, worst cases:**

| scenario | ticks/wall-s | PF/wall-s | dyn | PF | total | headroom |
|---|---|---|---|---|---|---|
| ALERT, speed 1 (event watching) | 100 | 1 | 0.7 ms | ~6 ms | **< 10 ms** | 100× |
| ALERT, speed 10 (max sensible in-event) | 1 000 | 10 | 7 ms | ~60 ms | **< 80 ms** | 12× |
| CALM, speed 900× sustained (strategic cruise) | 3 600 | 30 | 25 ms | ~180 ms | **< 250 ms** | 4× |
| pathological: `interrupt_on_event:false`, 900 s all-ALERT | 90 000/step | 900/step | 0.6 s/step | 3–9 s/step | absorbed by skip-never-stall | n/a |

PF dominates everywhere ⇒ the tuning knob is `pf_interval_calm` (30 s default;
60 s halves the worst case). Two islands roughly double PF cost (two smaller
solves) — still inside budget. These numbers are re-measured at P0 and pinned
in ADR-004.

**Vectorization directives (binding):** struct-of-arrays fleet
(`params: dict[str, np.ndarray]`, `states: np.ndarray[n_states, n_dev]`,
per-type boolean masks); precomputed `exp(−Δt/T)` per mode-dt, rebuilt on
fleet change; per-island sums via `np.add.reduceat` over island-sorted device
order (re-sorted on split/merge, not per tick); `np.clip(..., out=)`; no
Python attribute access or dict lookups inside `_tick` (hoist to locals);
telemetry appends into preallocated ring arrays with a write cursor, never
`list.append` of dicts.

---

## 4. Engine module layout

The `dynamics/` package inside `src/rttransportflow/` (repo tree: SPEC §3):

| module | contents |
|---|---|
| `dynamics/fleet.py` | DeviceFleet struct-of-arrays: params/states/masks; add/remove/trip; exp-coefficient cache; per-type output maps & clamps |
| `dynamics/plant_types.py` | loads `data/catalogs/plant_types.json` (single source of truth for §2.4 constants) |
| `dynamics/swing.py` | per-island COI state (f, E_k, ledger terms), semi-implicit update |
| `dynamics/islands.py` | connectivity partition, split/merge, slack election, blackout state |
| `dynamics/agc.py` | per-area ACE PI, participation, anti-windup |
| `dynamics/hydrogen.py` | stores, electrolyzer/consumer mass flows, fuel_starved logic |
| `dynamics/integrator.py` | §1.2 master loop; ALERT/CALM ModeController; tick order §2.6 |
| `dynamics/events.py` | Event dataclasses (kind, t_sim, element, data, significant); EventQueue (heap by t_sim, FIFO tiebreak by insertion seq — determinism) |
| `dynamics/protection.py` | UFLS stages, f-windows, LFSM-O, RoCoF relays, overload duty; relay timers |
| `telemetry.py` | fine ring (120 s @ 10 ms: f, RoCoF, ΣP by class, per island) + coarse ring (24 h @ 1 s) + per-step trajectory buffer + decimation + **rolling engine-snapshot ring** (full snapshot every 5 s sim, retained for the fine-ring window — the state source for `/gb/replay`) |
| `snapshot.py` | versioned full-state capture/restore: t_sim, seq, island f's, fleet states/SoC/meters, AGC integrators, UFLS latches, duty counters, relay timers, event queue, mode state, PF warm-start reset flag. Floats via `repr` (binary64-exact JSON round-trip) → bit replay |
| `powerflow.py` | PF adapter: apply ledger → retry-ladder solve → collect; `_r()` rounding |
| `simulator.py` | owns net+fleet+integrator+telemetry; `step(dt_s) → StepResult` (single wire format dataclass) |
| `engine.py` | RealtimeEngine (family shape): internal accelerated clock for standalone + `external_step()` for puppet; `_advance_once` shared body |

Config keys (`RTTRANSPORTFLOW_`): `data_dir, external_clock, host (127.0.0.1),
port=8003, log_level, cors_origins, history_size, dt_alert=0.010,
dt_calm=0.250, pf_interval_alert=1.0, pf_interval_calm=30.0, alert_df_mhz=50,
alert_rocof_mhz_s=25, calm_df_mhz=30, calm_rocof_mhz_s=10, calm_hold_s=30,
d_load_pct_per_hz=1.0, embedded_dg_frac=0.15, max_dt_s=900,
trajectory_max_samples=512, snapshot_ring_interval_s=5` (+ family keys:
step_interval_seconds, autostart, warm_start, …).

---

## 5. Wire contract

Authority: [contract/v2.md](contract/v2.md). This engine exposes:
`/gb/version` (contract "2.0", network_kind "transmission", units MW),
`/gb/net/reset` (native bundle + zones + devices + optional snapshot),
`/gb/net/patch`, `/gb/ws` + `/gb/step` (variable `dt_s`, early return,
trajectory + events + PF blocks), `/gb/result/latest`, `/gb/snapshot`,
`/gb/telemetry/ring`, `/gb/replay` (counterfactual re-run, control plane,
read-only).

---

## 6. Validation tests (binding for the coding agent)

**Analytic single-island fixture**: 4 machines × 2500 MVA, H = 5 s, R = 0.05
(on machine base S_n — ledger 20), T_g = 0.2, T_CH = 0.4 (no reheat stage),
load 8000 MW, **D = 1.0 pu (fixture value = 2 %/Hz; the game default is
1 %/Hz — the formulas are parametric)**, no deadband, losses 0, AGC off,
**all clamps disabled (`fcr_band = ∞`, `P_min = 0`, `P_avail` unbounded)** —
the survivors must deliver +25 % of S_n, far beyond any catalog FCR band;
trip unit 1 (2000 MW) at t = 1 s. Note **E_k in the RoCoF form is the
post-trip fleet**: 3 × 2500 × 5 = 37 500 MJ. Pinned expected values
(validated 2026-08-10 with the reference implementation at dt = 10 ms):
**RoCoF first tick −1.3319 Hz/s** vs analytic
`−ΔP·f0/(2·E_k) = −2000·50/75000 = −1.3333` (tol 0.5 %); **QSS
Δf −0.63291 Hz** vs analytic `−ΔP / (Σ_i S_n,i/(R_i·f0) + D·P_L0/f0)
= −2000/(3000+160)` (tol 0.1 %); **nadir 49.086 Hz at t ≈ 2.15 s** (tol
10 mHz, regression pin).

1. `test_rocof_analytic` / `test_qss_analytic` — the formulas above, plus
   RoCoF ∝ 1/E_k across E_k ∈ {½, 1, 2}× (linear fit R² > 0.999).
2. `test_nadir_inertia_sweep` — same ΔP, H ∈ {2,3,4,5,6,8} s: nadir strictly
   monotonically deeper with lower H; time-to-nadir shrinks.
3. `test_battery_ffr` — add 500 MW battery (T_b = 0.1, db = 10 mHz, full at
   ±200 mHz): nadir strictly shallower than baseline; battery output crosses
   50 % of its final response within 300 ms of the trip.
4. `test_hydro_nonminimum_phase` — hydro-only island, upward dispatch step:
   output initially moves *negative* before rising (assert sign of first
   0.5 s).
5. `test_exact_lag_pin` — per-stage exponential update vs the closed form of
   the **discrete recursion itself** at 3 sample times, tol 1e-9 (the pins in
   this section were generated with the per-stage scheme — ledger 21); the
   cascade's O(Δt) deviation from the *continuous* transfer function is
   documented, not pinned (~4e-4 at dt = 10 ms for the coal reheat model);
   stability at dt = 5·T (no overshoot).
6. `test_slicing_identity` — event mid-window, mode transition inside:
   `step(1×10 s)` ≡ `step(10×1 s)` ≡ `step(0.3+4.7+5.0)` bit-identical final
   state hash, event list, and telemetry samples **compared at shared
   sim-time instants** (the wire trajectory's per-step decimation is not
   slicing-invariant — §0 item 1).
7. `test_snapshot_replay` — scripted 300 s scenario with trip + UFLS: snapshot
   at 150 s → restore → continue: bit-identical to the uninterrupted run.
8. `test_early_return` — trip scheduled at 400 s inside a 900 s request:
   `dt_done_s ≈ 400`, event present, follow-up step continues seamlessly;
   concatenated trajectory ≡ `interrupt_on_event:false` run.
9. `test_pf_sanity` — pandapower `networks.case9`/`case30`: bus voltages vs
   pinned library results (tol 1e-6); loss-feedback settling: constant
   boundary ⇒ slack residual < 0.1 % of load after 3 PF instants.
10. `test_ufls_cascade` — low-inertia island, oversized trip: stages fire in
    threshold order with 150 ms delays, frequency arrested above 48.0 Hz,
    `w_a` matches the shed table.
11. `test_islanding` — trip tie lines: two islands, deficit island falls /
    surplus island rises, separate trajectories; resync rejected at
    |Δf| > 200 mHz, then accepted after AGC.
12. `test_energy_balance` — every step:
    `|∫(P_inj − P_load − P_loss)dt − (2/f0)·Σ_a E_k,a·Δf_a| ≤ 1 %` of
    throughput, exposed as `summary.balance_err`.
13. `test_h2_starvation` — electrolyzer fills store, CCGT on H₂ drains it
    during an event: `fuel_starved` fires at the floor, plant ramps out over
    10 s, frequency consequence visible.
14. `test_units_comparative` (P3 gate) — identical 1 GW trip against
    (a) gas-heavy, (b) nuclear-heavy, (c) renewables+battery fleets:
    (a) arrests faster than (b); (c) shows highest RoCoF and fastest-acting
    arrest with SoC visibly draining; all three pinned numerically.
15. Family suite: idempotent re-send returns cache without double-integrating
    SoC; out-of-order 409; forced PF divergence → degraded frame, loop alive,
    never 500; API-surface pin; `_floatify` Godot int tolerance;
    `test_perf_budget` — 300-bus/**150-device** net (the SPEC §5.7 reference
    size), 900 sim-s CALM in < 1 s wall on CI (soft: warn at 0.5 s).

**Version pins**: pandapower + numba pinned in `pyproject.toml`; every
pandapower behavior relied on (result columns, `enforce_q_lims`, warm-start
init behavior) gets a `test_pandapower_pins.py` entry, per the rtheatflow
rule: verify at runtime before trusting.
