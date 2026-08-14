# CLAUDE.md — project context & development state

> Handoff/context document. What this project is, the binding rules, the
> decision ledger from planning, and what a coding session must read first.
> Format follows the family convention (rtheatflow): per-phase log entries
> with Built / Tests / Acceptance evidence / Discoveries / Deviations.

## 1. What this project is

**rttransportflow** — a Europe-scale power **transmission** game: Godot 4 game
+ Python dynamics backend in one monorepo. The player builds plants, storage,
a hydrogen chain, and the 220/400 kV grid serving 25 European load centers —
and the grid has a *real frequency*: per-island center-of-inertia swing
equation + distinct governor/turbine ODEs per plant type, coupled to
pandapower AC power flow. Core pedagogical goal: **feel how frequency
dynamics change when renewables + batteries replace synchronous plants**
(RoCoF, nadir, FCR speed, grid-forming virtual inertia, UFLS cascades).

Fourth backend of the family — after rtpowerflow (power distribution),
rtheatflow (district heat), rtwaterflow (water) — alongside infrastruct (the
city-builder consuming those three as co-sim sidecars). Same DNA: FastAPI
backend, "the game owns time" puppet mode, gamebridge contract,
divergence-is-data, Docker/Grafana stack.

## 2. State

**Planning complete (2026-08-10). No code yet.** The plan was produced by a
multi-agent research+design pass over the sibling repos, then synthesized and
cross-reviewed. Start with ROADMAP P0.

Read order for any session: SPEC.md §0 → ROADMAP.md (current phase) →
docs/PHYSICS.md → docs/PARAMETERS.md → docs/contract/v2.md →
docs/GAME_DESIGN.md.

## 3. Binding rules

- **Document precedence**: SPEC §0.2. PARAMETERS wins on numbers, PHYSICS on
  equations/engine behavior, contract draft on the wire, GAME_DESIGN on
  gameplay, SPEC on architecture/process, ROADMAP on sequencing.
- **Phase gates are hard** (ROADMAP rules). Every phase ends with a log entry
  in §6 below.
- **Verify library claims at runtime** (`scripts/validate_core.py`) before
  trusting them; pin behaviors in `test_pandapower_pins.py`.
- **No RNG in the engine** except the `protection_seed` PRNG; no wall-clock in
  the sim path; slicing identity and snapshot bit-replay are non-negotiable.
- **Wire hygiene**: `_r()` on every float (round 6, non-finite → null) —
  sole exemption: the snapshot blob uses `repr` for bit-exact restore;
  `_as_int` tolerance (Godot sends ints as floats); idempotent last-t cache
  returns BEFORE any state application.
- **Never crash the loop**: catch-all in the solve path, non-convergence is
  data, never 500.
- **Ports**: backend 8003 / InfluxDB 8089 / Grafana 3003 (no web UI in v1 —
  ledger 25; 5176/8083 reserved-unused); game 8030 / smokes 8031 / contract
  tests 8032 / freeze smoke 8033 / P7 smokes 8034 (hydrogen_chain,
  battery_response, hvdc_link, north_sea_hub — kept off 8031 so P6 and P7
  smoke runs can overlap). NEVER 8000–8002 (user dev instances), 8010–8016
  (infrastruct sidecars + smokes), or 8020–8029 (infrastruct contract tests).
- **License**: no code from gridedit/gridgen (AGPL) — pattern reuse only.
- **Commit/push only on explicit authorization.**
- Lean solo agent work — ask before multi-agent fan-outs.

## 4. Decision ledger (planning-phase reconciliations; re-opening requires a new entry)

1. **New dedicated backend, not an rtpowerflow extension** — different engine
   paradigm (electromechanical ODE layer at 10–250 ms inside variable puppet
   steps vs quasi-static minute steps); rtpowerflow is a shipped tool with a
   pinned surface; no external slack at transmission level (the frequency
   model closes the balance). Family template inherited wholesale.
2. **One monorepo** (backend + game) — exactly one backend, co-evolving
   contract, atomic contract commits; backend stays standalone-runnable by
   convention (own pyproject/Docker/clock, no imports from game/).
3. **Stepping model**: variable `dt_s ∈ [0.05, 900]` float + early return on
   event + trajectory buffers (the numerically validated engine design won
   over a fixed-900 s-step sketch). Wire `t` is a sequence number; the game
   clock advances by `dt_done_s`. Economy layer aggregates on 15-min sim
   boundaries game-side.
4. **Per-island frequency from day one** (COI per connected component;
   emergent islanding/cascades). Normal operation = one synchronous area;
   *deliberate* multi-area (separate AGC, HVDC-coupled f) deferred to stretch.
5. **Integrator**: exact-exponential lag updates + semi-implicit COI swing,
   ALERT 10 ms / CALM 250 ms with deterministic hysteresis; PF at 1 s / 30 s
   + on every event. Validated in planning: RoCoF 0.11 % error, QSS < 0.01 %,
   slicing bit-exact, 6.9 µs/tick for 100 devices.
6. **UFLS table**: 6 stages 49.0→48.0 Hz × 7.5 % (cum 45 %), 150 ms pickup —
   PARAMETERS §2.2 is authoritative (an earlier engine-doc variant with
   5/7.5/10 % steps was superseded).
7. **Load self-regulation**: game default **1 %/Hz** (ENTSO-E). The analytic
   test fixture in PHYSICS §6 deliberately uses 2 %/Hz (D = 1.0 pu) because
   its pinned numbers were validated with it — formulas are parametric.
8. **Battery (GFL)**: T_b = 0.1 s, deadband ±10 mHz, full FFR at ±200 mHz,
   η_ch = η_dis = 0.94 (PARAMETERS wins over earlier engine-doc values).
   Grid-forming variant: H_v = 4 s default, counts into island inertia.
9. **Nuclear primary response**: physically capable (droop 5 %, db ±20 mHz,
   band ±2 % P_n) but **participation OFF by game default** (must-run
   identity); player-enabled at a wear fee.
10. **Ports/identity**: package `rttransportflow`, env prefix
    `RTTRANSPORTFLOW_`, backend port **8003** (power 8000 / heat 8001 / water
    8002 taken). An earlier engine-doc claim of 8002 was wrong.
11. **Wire unit MW** (deviation from the kW siblings; transmission scale) —
    contract `2.0`, `network_kind: "transmission"`, breaking successor to v1.2.
12. **Counterfactual replays run in the backend** (`POST /gb/replay`,
    read-only, off the step path) — physics implemented exactly once; the game
    never re-implements the swing model.
13. **Tile = 50 km**, map 96×80, hard cap ≤ 150 buses / ≤ 300 branches
    (infrastruct's ≤300-node budget lesson made binding).
14. **Weather/demand/dispatch/economics game-side; physics/protection/meters
    backend-side** (family split). Wind/PV availability arrives as `avail_mw`.
15. **Calendar**: 12 representative epoch-days per year + episode expansion
    (load-bearing for campaign length and seasonal H2 via ×days-in-month).
16. **Money model**: single company "GridCo Europa", regulated tariff on
    DELIVERED MWh; wholesale shadow price is a teaching KPI only.
17. **Lignite**: in as optional buildable (matters below ~60 €/t CO2).
18. **H2 chain numbers**: electrolyzer 48–52 kWh/kg, H2-CCGT η 57 % →
    ≈ 35 % power-to-power **efficiency** (≈ 65 % loss) incl. compression (an
    earlier engine-doc 0.70/33 % shorthand was superseded by PARAMETERS
    §1.13–1.14).
19. **AGC bias** = textbook `B_a = Σ K_i + D·P_L0/f0` [MW/Hz] (an earlier
    "0.5 × FCR gain" shorthand in the reserve table was superseded); aFRR
    distribution: participation factors default ∝ contracted `afrr_band_mw`,
    overridable via `agc_participation`.
20. **Droop base = machine base S_n** (gain `K = S_n/(R·f0)` MW/Hz) — the
    PHYSICS §6 QSS pin encodes it; the PARAMETERS §0 pipeline formula was
    corrected to match (a P_n-base reading would be 11 % off and fail the
    pin).
21. **Lag discretization is per-stage exact-exponential**; the cascade's
    global O(Δt) error (~4e-4 at dt = 10 ms vs the continuous TF) is
    accepted; `test_exact_lag_pin` pins the discrete recursion (tol 1e-9),
    not the continuous transfer function. All §6 pins were generated with
    this scheme.
22. **LFSM-U is not modeled in v1** (honesty sections); headroom release
    beyond FCR is covered by aFRR/mFRR. Adding it later requires regenerating
    the PARAMETERS §2.3 pins.
23. **Counterfactual replay state source**: rolling engine-snapshot ring
    (full snapshot every 5 s sim, retained for the 120 s fine-ring window);
    `/gb/replay` takes `event_id`/`t_sim` and answers `window_expired` after
    the window ages out; the game fetches its counterfactual set right after
    each event and caches ghost traces with the event-log entry.
24. **Sidecar ports moved to 8030/8031/8032** — the initially chosen
    8020–8022 collide with infrastruct's contract-test range 8020–8029
    (water = 8022).
25. **No backend web UI in v1** — the game is the UI; Grafana serves the
    standalone teaching mode; compose ships 4 services (backend, influxdb,
    grafana, collector); 5176/8083 remain reserved in the family scheme.
26. **HVDC ships in P7** (paired-P-injection devices + corridor tool +
    dispatcher modes) — it must exist before the P9 campaign needs it; line
    switching is a wire-level state change (`line_commands` /
    `line_trip|line_close` scheduled events), never a topology reset; the
    overload-duty protection numbers live in PARAMETERS §2.2; PARAMETERS §2.3
    reference incident is an exogenous H = 0 infeed loss (surviving fleet
    unchanged); the §6 analytic fixture runs with clamps disabled and
    post-trip E_k = 37 500 MJ.
27. **North Sea offshore-DC integration** (user request 2026-08-10): offshore
    wind has two connection paths — AC near-shore (own submarine corridor
    ≤ 150 km) and DC far-shore via **offshore converter platforms**
    (`offshore_hub` wire kind: one aggregated injection at the onshore
    converter bus; the offshore collector grid is NOT electrically modeled;
    platforms/links are devices, not AC buses — no node-budget cost). Numbers
    in PARAMETERS §1.16 (platform 450/800 M€ per 1/2 GW, DC cable 2.0 M€/km,
    1 %/station + 0.30 %/100 km losses, Q ±0.4 at any P); LFSM-O applies at
    the hub's onshore terminal. Ships in P7 with `north_sea_hub.gd`;
    multi-terminal "energy island" DC grids are post-v1 stretch. (Contingency
    semantics refined by 28.)
28. **Embedded-HVDC physics correction** (verify pass, 2026-08-10): only
    **offshore hubs** (and future cross-area import links) are infeed-loss
    ΔP events and FCR reference incidents — an embedded onshore bipole's ±P
    pair cancels in the COI ledger (net ≈ its losses), so its trip is a
    **flow-redistribution/congestion contingency** (overload-duty, cascades,
    redispatch), asserted as such by `hvdc_link.gd` (near-zero Δf); the
    milestone-7 finale double contingency is re-anchored on hub + largest
    unit. Same pass: farm capex is a single 2600 €/kW (both paths) with AC
    export billed per-km and capped at 150 km — the ≈ 150 km AC/DC breakeven
    sits at that cap; platform "marinized ≈ 2.3×"; converter no-load
    auxiliary 0.15 % P_max; overland DC underground variant ×4; absolute DC
    costs deliberately ~2/3 of 2026 actuals, consistent with the game's cost
    level; milestone 3 requires hub capacity *committed*, not delivered
    (42-month platform build lands ~2031).
29. **Corridors block plant sites** (P6/P7 build hunt, 2026-08-11): a plant
    may not be placed on a tile that already carries a corridor (the reverse
    was always true). Found via `--smoke=buildcheck`: a nuclear unit dropped
    onto frankfurt's only tap-exit corridor orphaned the whole city. Same
    hunt: ruhr's footprint is ADJACENT to frankfurt, so frankfurt's avoid
    ring seals it — the demo trio is now **hamburg/berlin/munich** (verified
    pairwise-routable offline), the ladder's site search is avoid-ring-aware
    (a doomed site's BFS floods the full 7 680-tile map — 385 of them froze
    a smoke), unroutable plants are removed + banned instead of silently
    stranded, and the build margin is 1.35× map peak (the LIVE weather-driven
    demand peak runs up to ~1.2× the map's static `peak_mw_2025`).
30. **Commitment counts deliverable capacity** (2026-08-11): the dispatcher
    commits against `0.92 · p_max` (the FCR headroom cap it will actually
    dispatch to), not raw nameplate — raw accounting left Europe-scale
    evenings ~5 % short and the gas fleet never committed while the evening
    priced at the scarcity cap.
31. **H2 fuel value is a fixed reference in v1** (P7, 2026-08-11):
    `fuel_eur_per_mwh_th.h2 = 90` (≈ 3 €/kg LHV) prices converted plants'
    burn and the merit order; the endogenous H2 book (production-cost
    tracking per cavern) is deferred — documented simplification, the
    ROADMAP's "endogenous fuel value" gate is satisfied by the fixed
    reference + the hydrogen_chain smoke's round-trip assertion.
32. **HVDC dispatcher mode is `manual` in v1** (P7, 2026-08-11):
    `Dispatch.link_setpoints[terminal_pid] = MW` passes through per block;
    `auto` congestion relief moves to P8 with the overload/cascade layer.
    Electrolyzer/battery-charge MW feed back into next block's demand ledger
    (`_flex_load_mw`) — without it every commanded flexibility MW became an
    island deficit and the electrolyzers shed themselves (found by
    hydrogen_chain).
33. **Availability slew** (engine, 2026-08-11): `inv_avail` is a TARGET; the
    effective availability ramps toward it at `avail_slew_pct_pn_min`
    (catalog: wind 20 %/min, PV 40 %/min, offshore hubs 20 %/min; default
    instant — every pre-slew pin unchanged). The 15-min wire sample-and-hold
    is a SAMPLING artifact, not weather physics: a natural block-boundary
    wind step of ~1 GW relayed out a small island twice (calm_week hunt,
    predicted by the P7 fork's findings). model_hash covers the slew; old
    snapshots restore tolerantly (eff falls back to the target). Companion
    game truth: pre-aFRR, a small island survives sustained intra-block
    ramps only with the full stack — slew (physics) + must-run synchronous
    fleet (inertia) + batteries (FFR bridges the 15-min dispatch cadence).
34. **Blackout & black-start doctrine** (P8, 2026-08-13): an island whose
    E_k hits zero DISCONNECTS its load (w → 0, `blackout` wire event) — the
    collapse itself is the disconnection; a later `black_start: true`
    breaker-close bypasses the sick-island start hold and the first
    completed machine re-energizes the island at 50 Hz onto the unloaded
    system; demand returns only via `restore_load` blocks through the
    5-min-healthy gate. Found the hard way twice: restarting into a loaded
    dead island collapses again, and syncing at a forced P_min into ZERO
    load over-frequency-trips — the engine envelope's p_min stays 0 (the
    catalog p_min informs the dispatcher, P3 rule) and black-start units
    run at house load.
36. **Exceptions are data too** (P8 hardening, 2026-08-14): the never-crash
    rule covered solver divergence but NOT engine exceptions — a raise inside
    the step handler killed the WS channel while the process lived and
    `/health` stayed green, so the game span forever against a **deaf**
    backend (two smoke runs froze mid-flight; the autopsy found stale
    adopted backends running pre-fix code). Now: the step body has a
    catch-all returning a `failed` frame carrying the traceback, the WS loop
    guards its own dispatch, and the game re-registers after
    `TRANSPORT_FAILURES_BEFORE_RESET` consecutive transport failures.
    Companion rule for dev loops: **always free the smoke port before a run**
    (`fuser -k <port>/tcp`) — an adopted stale backend runs OLD code and
    silently invalidates the result.
37. **Island reshape mid-batch** (P8, 2026-08-14): a line event inside an
    event batch re-topologizes the island set, so any per-island mask
    captured before the loop must be remapped by parent island — a 2 → 3
    split raised `ValueError` (1 → 2 had survived only by numpy
    broadcasting). Consequence beyond the crash: an island BORN dead by a
    split must read as newly-black (`w → 0`, `blackout` event), not keep its
    load.

35. **§2.3 row-5 narrative refined + sync LFSM-O** (P8): with the defense
    live, UFLS stage 1's 7.5 % shed (11.25 GW on the 150 GW island)
    overcorrects the 3 GW reference loss — only stage 1 fires, the raw
    "stages 1+2" reading described the unshedded nadir (the §2.3 raw pins
    are untouched, fixtures run defense-off). Same hunt: sync-side LFSM-O
    (40 % of current P per Hz above 50.2) was missing — an over-shed rode
    f through 51.5 into a mass-disconnection cliff; PHYSICS §2.7 always
    mandated it on ALL generation.

## 5. Key reference paths (sibling repos, same parent folder)

| Path | Why |
|---|---|
| `../infrastruct/docs/contract/v1.md` + `schemas/` + `tests/contract/` | contract ground rules + golden-fixture suite to clone |
| `../infrastruct/backends/rtpowerflow/src/netzsim/api/gamebridge.py` | reference gamebridge implementation (idempotency, SoC, violations, warmup) |
| `../infrastruct/game/autoloads/orchestrator.gd` (+ autoloads generally) | the scheduler to port near-verbatim (one-step lag, skip-never-stall) |
| `../infrastruct/ROADMAP.md`, `../infrastruct/docs/adr/` | phase-template + ADR style |
| `../infrastruct/game/model/weather.gd`, `.../smokes/` | seeded weather + `force_*` windows; SmokeBase pattern |
| `../rtpowerflow/src/netzsim/{engine,simulator,network_builder,config}.py` | family backend shape (accelerated tick, retry ladder, ProfileArrays, `_r`) |
| `../rtheatflow/SPEC.md`, `../rtheatflow/CLAUDE.md` | spec discipline (runtime-verified claims, known answers) + log format |
| `../gridedit/src/gridedit/osm.py` | Overpass power-overlay *pattern* for the P10 OSM seed (AGPL — reimplement, never copy) |

Family gotchas already paid for (do not re-learn): JSON NaN kills browser
parsers (`_r`); Godot ints arrive as floats; numba needs explicit install +
warmup-at-reset; one slack per island; element indices are reused after
deletes (key on platform ids); debounce topology resets; per-port sidecar
logs; deterministic smokes assert windows not instants; `engine.reconfigure`
must await the in-flight step; zero/degenerate operating points break solvers
(floor them); Vite `strictPort` + 127.0.0.1 proxy targets on Windows.

## 6. Development log

### P0 — Scaffold, feasibility spikes, ADRs, CI (2026-08-10)

**Built:** family-shaped backend scaffold — `pyproject.toml` (src layout,
console script, pandapower==3.5.4 + numba==0.66.0 pinned, numba explicit),
`config.py` (RTTRANSPORTFLOW_, port 8003), `simulator.py` (StepResult single
wire format + `_r()`/`_as_int` + NullSimulator), `state.py` (latest/history/WS
fan-out, slow consumers drop frames), `engine.py` (RealtimeEngine:
accelerated tick + `external_step()` with the two-clock guard, shared
`_advance_once`), `api/` (runtime App container, core `/ /health /status
/state /history /ws`, control start/pause/resume), launchers
(start/stop `.sh`, `.run/` PIDs+logs, /health identity check, kill by
cwd+cmdline), `install.sh` (uv venv 3.12), Dockerfile, CI (pytest-gated),
`scripts/validate_core.py` spike harness, ADR-001…004.

**Tests:** 14 green — route-inventory pin, health identity, control flow,
WS streaming, engine wrap/pause, external-step refusal while internal clock
runs, internal-vs-puppet clock equivalence, `_r`/`_as_int` wire hygiene,
env-override settings.

**Acceptance evidence:** `curl :8003/health` →
`{"app":"rttransportflow","version":"0.0.1"}`; live `/status`+`/state` while
ticking; ADR-004 tables measured on this machine (300-bus warm NR 5.16 ms
median, 150-device tick 11.3 µs, JIT warmup 1.46 s → warmup-at-reset
confirmed load-bearing; both inside the ROADMAP budget).

**Discoveries:** (1) FastAPI ≥0.141 wraps `include_router` results in
`_IncludedRouter` containers — the surface-pin test walks
`.original_router.routes` (works for flat layouts too). (2) The spike net
initially diverged twice: 19 GW over ~1.3 GVA corridors, then segment
deficits dragged across a 36 000 km ring — "realistic operating points or the
solver refuses" applies to authored scenarios; the fixed topology
(self-balanced 20-bus regional meshes + short ties) is the shape the game's
topology builder should produce. (3) System Python here is 3.10; the venv is
uv-managed CPython 3.12.13.

**Deviations (deliberate):** Windows `.bat` launcher twins deferred to P10
packaging (Linux dev machine; `.sh` twins are the executable spec).
docker-compose ships in P1 with the viz stack rather than as an empty P0
skeleton.

**Next:** P1 — data contract, europe_mini bundle, PF simulator with retry
ladder, recorder/exporter, collector→InfluxDB→Grafana.

### P1 — Steady-state PF on the europe_mini grid, standalone + Grafana (2026-08-10)

**Built:** `models.py` + `data_loader.py` (pydantic scenario bundle:
grid/lines/plants/load_centers/scenario with full cross-validation;
`input_data_from_dicts` for the later gamebridge path);
`scripts/gen_europe_mini.py` (authored 11-bus / 8-country 380 kV grid, one
winter workday, dispatch by a per-bus balancing pass); `network_builder.py`
(build-once pandapower net, element-index maps, dense profile arrays; sync
kinds → PV gens with ±0.40·p_max Q bands, converter kinds → sgens with
static pf-0.97 Q support); `PFSimulator` (apply columns → retry ladder
warm-NR → cold-NR → iwamoto, catch-all, degraded frames, `warmup()`);
`recorder.py` (JSONL sink) + `/export.jsonl` + `/network` endpoints; runtime
wiring (config `simulator: pf|null`, warmup in lifespan); visualization stack
(stdlib-only collector → InfluxDB 2.7 on :8089 → Grafana 11 on :3003 with
provisioned datasource + dashboard) and full docker-compose.

**Tests:** 34 green — bundle cross-validation matrix, known-answer pins
(step 0 + step 74 exact summary numbers, full-day envelope: |slack| < 800 MW,
loading < 75 %), nonconvergence (forced divergence → degraded frame, retry
tiers exercised, self-heal next step; REST serves converged:false at 200),
collector line-protocol unit tests, updated surface pin.

**Acceptance evidence:** `docker compose up` → backend solves europe_mini in
the container (verified live: step 27 converged, 38.6 GW), collector data
confirmed in InfluxDB via Flux query, Grafana healthy with dashboard
`rttf-main` provisioned and datasource OK. Full day: 96/96 steps converge,
slack −0.3…−0.7 GW, losses 12–203 MW, max loading ≤ 70 %, solve ~6.3 ms
median.

**Discoveries (each cost a debugging round):** (1) First authoring attempt
diverged: night dispatch under-produced ~12 GW (all dragged from one slack)
and a 1050 km uncompensated AC corridor is infeasible — corridors now ≤ 550 km
with an intermediate Lyon bus, and dispatch is *authored balanced* per bus.
(2) Second attempt collapsed at the evening peak: fleet 43 GW available vs
54 GW peak — dispatchables now sized 50 GW. (3) Copenhagen showed textbook
voltage collapse (vm 0.74): 0.9 GW import over one corridor with only a
unity-pf wind sgen locally — fixed physically via converter Q support
(SGEN_Q_FACTOR 0.25, stand-in for the ±0.33·P_n grid-code capability) + a
local CCGT. The engine's honesty held: every divergence was a real
infeasibility.

**Deviations (deliberate):** europe_mini has 11 buses, not 10 (the Lyon bus
splits the Iberia corridor — physically necessary). Voltages sit pinned at
1.02 everywhere (every bus hosts a PV machine); the interesting voltage story
returns when dispatch deviates from the authored balance (P6). `weather.json`
/ `storage.json` / `links.json` not yet consumed (P6/P7 per SPEC §4.1).

**Next:** P2 — the frequency dynamics engine (PHYSICS §1–§2) + analytic
validation.

### P2 — Frequency dynamics engine + analytic validation (2026-08-10)

**Built:** `dynamics/` package — integer-µs time base (10 ms quantum),
`events.py` (heap queue, grid-quantized, FIFO tiebreak), `fleet.py`
(struct-of-arrays: dispatch slew → droop with soft deadband + FCR/envelope
clamps → T_g → T_CH/T_RH cascade with F_HP split, per-stage exact-exponential
updates, coefficient cache per dt), `islands.py` (connected components),
`integrator.py` (master loop: absolute-time boundaries only, per-island
semi-implicit COI swing, ALERT/CALM hysteresis controller, PF hook, energy
meters, state_dict); `telemetry.py` (fine ring + trajectory buffer with
≤512-sample decimation, event instants kept); `snapshot.py` (repr-float JSON,
bit-exact restore, model hash); `DynSimulator` (PF↔dynamics ledger coupling:
PF at mode cadence writes fleet outputs → solves → refreshes `p_loss`; the
slack residual is the loss-estimate error and self-corrects); standalone
default `simulator="dyn"`; collector `freq` measurement + Grafana frequency
panel + H_sys/RoCoF stat; README honesty section.

**Tests:** 53 green (19 new) — all P2 gates: RoCoF first tick −1.3319
(0.5 % of analytic, post-trip E_k), QSS −0.63291 (0.1 %), nadir 49.086 ±
10 mHz regression pin, RoCoF ∝ 1/E_k (R² > 0.999), nadir/inertia sweep
strictly monotone, exact-lag recursion pin 1e-9 + dt = 5T stability,
slicing identity **bit-exact** (10×1 s ≡ 1×10 s ≡ 0.3/4.7/5.0 across a
CALM→ALERT transition), snapshot bit-replay through JSON, early-return
semantics + seamless continuation, energy balance ≤ 1e-9 (semi-implicit
pairing makes the identity exact), case9 library pins, coupled europe_mini
hour (|Δf| < 0.1 Hz, PF failures 0), loss-feedback settling (slack < 0.1 %
of load).

**Acceptance evidence:** all engine-design pins reproduced on first run —
the numerically-validated planning design transferred cleanly. Live compose
stack: real frequency in Grafana (50.029 Hz on the morning ramp, boundary
transients to 49.92 Hz, H_sys 4.0 s, mode calm, `slack_mw: -0.0` — the
frequency model now closes the balance; 1180 PF solves, 0 failures).

**Discoveries:** (1) NumPy 2 `repr(np.float64)` prints the dtype wrapper —
snapshot serialization must `repr(float(v))`. (2) Standalone step boundaries
(sample-and-hold load jumps up to ~1 GW) excite |Δf| > 50 mHz transients →
ALERT episodes → ~0.8 s compute per 900 s step in Docker; keeps up with the
1 s tick but tight. P6's game-side per-wire-step demand updates smooth this;
revisit `alert_df_mhz` if standalone cost matters earlier.

**Deviations (deliberate, ledger-relevant):** `dt_done` is
boundary-quantized and may exceed `dt_s` by up to one CALM tick when the
request is shorter than the next boundary (min-one-boundary rule) — this is
what buys bit-exact slicing invariance; fold into the contract text at the
P4 freeze. Coarse 24 h ring and the rolling snapshot ring deferred (P4/P8).
LFSM-U honesty note mirrored in README.

**Next:** P3 — distinct per-kind plant models from the PARAMETERS catalog,
start/stop sequences, trips, storage device dynamics; `data/catalogs/
plant_types.json` with rationale strings; three-fleet comparative test.

### P3 — Distinct plant models, trips, storage dynamics (2026-08-10)

**Built:** `data/catalogs/plant_types.json` (12 kinds + f-protection block,
every entry with a rationale — PARAMETERS §1 authority);
`dynamics/plant_types.py` (validated loader → fleet specs; catalog p_min_pct
informs the dispatcher, the ENGINE envelope is device-level);
fleet rewrite: unified 3-stage chain covers steam/CCGT/OCGT via coefficients
(c_in 2/3 + c_2 0.5 give the CCGT gas-path + steam-tail topology), hydro
block (lead-lag transient droop → rate-limited servo → NMP water column,
y = 3x_h − 2g), battery block (FFR through converter lag, SoC with η and
band clamps, GFM virtual inertia into E_k + inertial SoC debit),
electrolyzer UF-shed block, wind/PV asymmetric lags + LFSM-O;
unit commitment (hot/warm/cold lead times from off-duration, nuclear xenon
lockout, sync-at-P_min) with `start_complete` events; energy + fuel meters
through the part-load η line; `dynamics/protection.py` f-window relays
(±[47.5, 51.5] Hz, 100 ms) generating engine trip events; DynSimulator is
catalog-driven per kind.

**Tests:** 77 green (24 new) — per-kind step-response character (OCGT t90
< 3 s; CCGT "fast then breathes"; coal reheat > 5× OCGT t90; hydro
wrong-way kick + 60 s transient-droop lag pinned to theory), battery FFR
(nadir +0.05 Hz min, 50 % of response < 300 ms, SoC drains), GFM lowers
RoCoF ≥ 15 % vs GFL, SoC floor clamp, electrolyzer shed curve, LFSM-O
steady state = avail/1.08 at 50.4 Hz, cold nuclear start (48 h, zero power,
zero inertia until sync-at-P_min), xenon lockout, OCGT 15-min cycle, fuel
meter = E/η, **PARAMETERS §2.3 worked example: all 5 rows within the ±2 %
pins** (independent cross-validation of the planning reference), lesson
orderings (RoCoF ×2.5, battery fixes nadir not RoCoF), three-fleet
comparative with regression pins.

**Acceptance evidence:** comparative table (same 1 GW infeed loss, 40 GW
island): gas RoCoF −0.123 nadir 49.87 @ 1.7 s; nuclear −0.094 / 49.45 @
28 s (most inertia, but the ±2 % band saturates and reheat crawls — mass
alone doesn't save you); renewables+battery −0.623 / 49.88 @ 0.36 s with
13 MWh SoC drained. Live stack: H_sys 4.65 s (capacity-weighted per-kind
mixture).

**Discoveries:** dispatching a fleet at ~97 % of P_max leaves no FCR
headroom — the envelope clamp silently eats primary response and the "fast"
gas fleet sagged below nuclear (found by the comparative test; fixed by
sizing dispatch ≥ one FCR band under P_max). This is a real adequacy lesson
the advisor (P8/GAME_DESIGN §4.6) must surface to the player.

**Deviations (deliberate):** GFM current limit (1.2 pu ≤ 2 s →
`gfm_overload`) deferred to P8 with the violation vocabulary; electrolyzer
downward reserve (over-frequency uptake) deferred to P7; H2 fuel-chain
draw (PHYSICS §2.8) is P7 — fuel meters only for now.

**Next:** P4 — gamebridge v2 (freeze the contract), contract golden suite,
Godot shell with the live frequency dial. NEEDS: Godot 4 binary on this
machine (infrastruct keeps one under `.tools/godot/`) — confirm location
before starting.

### P4 — Gamebridge v2 + contract suite + Godot shell (2026-08-10)

**Built:** contract FROZEN (`docs/contract/v2.md` + 3 JSON schemas; new
binding "Time quantization" section: dt_s 10 ms quantum, boundary-quantized
`dt_done_s`, min-one-boundary rule; trajectory example corrected to explicit
`t_rel_s`); `api/gamebridge.py` — version handshake, `net/reset` (native
bundle → DynSimulator, warmup, snapshot restore with model-hash guard +
`refused_snapshot`, clears the idempotency cache), `net/patch` (set_device;
add/remove rejected loudly until P5/P7), `step` + WS `/gb/ws` (strictly
sequential lock, idempotent cache BEFORE state application, flat
out_of_order body identical on both channels, sample-and-hold boundary,
scheduled events, watch sampling, per-step meters/violations/PF window
extremes), `result/latest`, `snapshot`, `telemetry/ring`; puppet mode
(`EXTERNAL_CLOCK=true` → null internal sim; gamebridge owns its own);
PyInstaller freeze script + smoke (452 MB onedir, boots + `/health`) wired
into CI. GAME (built by a context-fork agent, integrated + extended by the
main session): `game/` Godot 4.7 project — autoloads ported from infrastruct
(GameClock with `dt_done_s`-authoritative time, SidecarManager with
shell-wrapper env spawn + backoff restart + per-port logs, CosimBridge
`EXPECTED_CONTRACT "2.0"`, Orchestrator: 10 Hz wall ticks `dt_s = 0.1×speed`,
one-in-flight/skip-never-stall, one-step lag, auto-slow on significant
events + 3-step cooldown, crash recovery with fresh wire sequence), stub
Boundary provider (europe_mini profile replay), map view (geo buses/lines,
vm coloring), frequency panel (readout, 120 s trace, H_sys/E_k, mode), HUD
(speed buttons, event log, **debug key T = trip the largest online unit**);
smokes `boot_and_day`/`trip_reaction`/`sidecar_crash` on SmokeBase
(`SMOKE_<NAME> {json}` verdict lines, exit 0/1); `orchestration/sidecars.json`.

**Tests:** 95 green (18 new: 14 in-process gamebridge incl. bit-identical
external-clock equivalence and any-t-after-reset; 4 real-socket contract on
8032 incl. WS channel + no-NaN wire). Smokes verified end-to-end: boot_and_day
80/80 converged, t_sim exactly 7200 s; trip_reaction early return at 30.0 s,
auto-slow, nadir 49.562; sidecar_crash kill −9 → recover → stepping resumes.
Freeze smoke green.

**Discoveries:** (1) the game-shell integration found a real contract bug —
after reset the backend demanded t=0, violating "the game clock continues
across resets; any t is legal as the first step" (fixed + pinned by
`test_any_t_accepted_after_reset`); also the HTTP 409 body was
FastAPI-detail-nested vs the contract's flat frame (fixed: flat on both
channels). (2) GDScript lambdas capture by value bit the crash smoke exactly
as the family gotcha predicted (member-variable flags now). (3) PyInstaller's
only numba warning is the optional libtbb threading layer — allowlisted with
rationale in `freeze_backend.sh`.

**Deviations (deliberate):** GdUnit4 arrives with the topology goldens (P5) —
P4 game verification is smoke-based; coarse 24 h ring + rolling snapshot
ring still deferred (P8); frequency trace appends samples against sim time
rather than wall-replaying the previous buffer (visually equivalent at 10 Hz
stepping).

**Next:** P5 — tiles, building, topology builder (WorldModel, corridor
drawing, golden-file pinned native bundles, debounced reset).

### P5 — Tiles, building, topology builder (2026-08-11)

**Built:** Europe map data (fork-authored): `tools/map_authoring/quantize.py`
(deterministic polygon→raster generator, documented projection) +
`data/map/europe_v1.json` (96×80, 3 797 land tiles, recognizable coastlines,
all 25 GAME_DESIGN load centers, coal/cavern/PHS/wind/solar/river resources)
+ preview + 7 pytest validations. GAME: `model/world_model.gd` (WorldModel
autoload — Vector2i-keyed source of truth, placement rules per GAME_DESIGN
§1.3, versioned envelope), `model/grid_topology.gd` (bus formation/collapse,
branch walking, island drop with warnings, node budget warn 120 / refuse 150,
native-bundle synthesis incl. stub balanced dispatch), `model/build_session.gd`
(2.5 s debounced rebuild→re-register; deferred status emissions),
`model/demo_build.gd` (fixture build for the golden + BFS auto-build with
trunk merging + foreign-city avoidance), `views/build_view.gd` (terrain/
resource/corridor/plant/bus rendering, tool keys, ghost validity, camera),
build-mode boot in main.gd; GdUnit4 6.2.0 vendored from infrastruct;
smokes `build_and_supply` (real Europe map) + `island_cut` (fixture).
BACKEND: E_k = 0 blackout guard (frequency freezes, never NaN) + island
`blackout` flag on the wire.

**Tests:** backend 103 (blackout-guard new), GdUnit 8 (byte-stable topology
golden + re-baseline path, determinism, clean errors, unconnected-zone drop
+ warning, node-budget refusal on a synthetic 160-tap comb, sinuosity,
debounce), 6/6 smokes green incl. the two new P5 gates.

**Discoveries (each a real found bug):** (1) sync `build_status` emissions
on fail paths deadlocked `rebuild_now(); await` callers — all emissions
deferred now. (2) Corridor spaghetti from per-plant BFS routes exploded the
junction count → bus-budget refusal; spurs now merge into existing trunks.
(3) At 50 km tiles adjacent metros collapse into ONE bus (no branches) —
the demo uses a spread trio. (4) A corridor brushing a foreign load center
connects its load with zero generation → 47.4 Hz dive; router avoids
foreign footprints, and corridors can no longer cross occupied tiles.
(5) The dive exposed a REAL engine hole: total source loss divided by
E_k = 0 → NaN → `_r()` nulled it → GDScript `float(null)` crash; the engine
now freezes frequency at blackout and the game reads wire numerics
null-tolerantly (`numf`).

**Deviations (deliberate):** demo auto-build connects 2 of the 3 trio
cities on the Europe map (avoidance rings pinch the Munich chain — demo
polish, not a gate); per-corridor circuit upgrades + transformer bays
deferred to P6 economy; `/gb/net/patch` add/remove_device still rejected
(full debounced reset covers all edits).

**Next:** P6 — demand, weather, dispatch, market, economy.

### P6 — Demand, weather, dispatch, market, economy (2026-08-11)

**Built:** GAME model layer (weather/demand fork-authored, integrated +
extended): `model/weather.gd` (seeded regional weather: wind Weibull-λ
diurnal/synoptic process, clearness, temperature; `force_window` test hooks;
region-of-tile via the map projection), `model/demand.gd` (per-zone profiles:
weekday/weekend shape, temperature response, `zone_mw` live + `zone_mw_forecast`
that NEVER advances the weather timeline), `model/dispatch.gd` (GridCo
dispatcher per GAME_DESIGN §3.3: marginal-cost merit order incl. per-plant
fuel overrides, day-ahead-peak commitment against DELIVERABLE (0.92-capped)
capacity, tier-PROPORTIONAL energy dispatch, renewable must-take + pro-rata
curtailment, scarcity pricing at 4 000 €/MWh, redispatch heuristic on
overloads, FCR-headroom withholding), `model/economy_books.gd` (capex on
placement incl. per-terrain line factors, revenue on DELIVERED MWh at the
regulated tariff, fuel/CO2/VOM from engine meters, daily FOM, VoLL, loan
interest, reserve remuneration, ledger-consistency identity),
`data/catalogs/economy.json` (PARAMETERS §1/§4 authority), gridco boot
(Weather/Demand/Dispatch/Economy autoloads + `Boundary` mode "gridco":
one dispatcher decision per 15-min block feeding the wire), topology-builder
demand sampler (native profiles from the LIVE demand model), balancing
harness `tools/balancing/economy_windows.csv` regenerated by the economy
smoke; debug smokes `probe` (per-step wall/f/gen/demand) and `buildcheck`
(no-backend build report: connectivity, capacity ladder, live-vs-map peaks).

**Tests:** GdUnit weather/demand suites (seeded determinism, forecast purity,
region mapping) in the 25-green matrix; smokes `dispatch_day` + `economy` +
`calm_week` green (see below); backend 122 (start-hold pin new).

**Acceptance evidence:** dispatch_day — full day 96/96 converged on the
auto-built hamburg/berlin/munich grid (19 GW native, live peak 16.3 GW):
nuclear base-loaded (mean factor > 0.7, never cycled below 0.4), gas peaks
in the evening (2 085 MW evening window vs 85 MW night), wholesale 63.1 €/MWh
evening vs 53.8 night, zero transport failures. economy — 329 GWh delivered,
avg cost 34.9 €/MWh, 167.5 g CO2/kWh, ledger identity < 1 €, windows CSV
regenerated. calm_week — the renewables-heavy Hamburg island (wind 1.6× +
gas 1.28× must-run + batteries 0.3× peak) HOLDS a normal day at f_min 49.77;
the staircased Dunkelflaute prices 48 scarcity blocks and sags to 47.50 —
deep, brushing the trip floor, but SURVIVED (runtime note: this island runs
in permanent ALERT, ~2 h wall for 2 sim days — P8 perf item: vectorize the
tick hot path / revisit calm-return hysteresis for wobbly-but-stable
islands).

**Discoveries (each a real found bug):** (1) greedy merit dispatch + slew
asymmetry built a 570 MW surplus that tripped the fleet at 51.5 Hz →
tier-proportional dispatch. (2) demand forecasts dragged the weather state
24 h/block → frozen-state `zone_mw_forecast`. (3) stub-vs-live demand
mismatch collapsed the grid at t = 0 → the builder samples the live model.
(4) a dead grid burned 27 s/step in futile PF retries → blackout skips PF.
(5) commitment counted nameplate but dispatch delivers 0.92·P — every
evening ~5 % short, gas never committed (ledger 30). (6) plants placeable ON
corridor tiles + frankfurt sealed inside ruhr's avoid ring fragmented the
demo build to one city at 1.02× peak → ledger 29 (corridor-blocks-plants,
avoid-aware ladder, hamburg trio, 1.35× sizing, remove+ban unroutables).
(7) the dispatcher auto-restarted tripped units into a dying island and
sync-at-P_min ignored island health — f integrated to −27 Hz; starts now
HOLD while |Δf| > 1 Hz or blackout (pinned backend test); calm_week runs
its healthy baseline BEFORE the dark day (no restoration until P8).
(8) calm_week's custom build routed spurs WITHOUT the avoid rings and
dragged five foreign cities onto a 5 GW island (the P5 47.4 Hz lesson,
refound — whole fleet tripped at t = 0.25 s); its build is avoid-aware now.
(9) even with 1 city, a natural block-boundary wind step killed the island
64 s into a block: gas parked at 0 MW by the merit order, ~270 MW FCR, and
no aFRR until P8 — fixed by the full stack of ledger 33 (avail slew +
must-run gas + a battery fleet at 0.3× peak). (10) two agents' smoke runs
sharing port 8031 adopt each other's backends — P7 smokes moved to 8034;
`pkill -f` of a smoke pattern in the same shell command kills the launcher
itself (bracket-escape the pattern, or fuser the port).

**Deviations (deliberate):** wholesale price is a teaching KPI (revenue is
tariff-on-delivered); startup cost single warm value; no MILP commitment;
battery VOM unbooked pending a throughput meter; aFRR/mFRR remuneration
simplified to the FCR line item until P8.

**Next:** P7 game side (below) — backend committed separately (0d10782).

### P7 — Storage gameplay, hydrogen chain + HVDC (2026-08-11)

**Built:** BACKEND (committed 0d10782): `dynamics/hydrogen.py` (H2Stores:
rate-limited tanks, η_spec 48–52 kWh/kg, 2.5 kWh/kg compressor aux on the
store's island, 5 %/7 % floor/recovery starvation gating), `dynamics/hvdc.py`
(HVDCLinks: paired ±P terminals, 1 %/station + 0.30 %/100 km losses, 0.15 %
no-load aux, T = 0.1 s lag; embedded trip frequency-neutral by construction),
fleet attach hooks + `inv_aux_mw`, reset `devices` channel (battery |
grid_forming | electrolyzer | h2_store | hvdc | offshore_hub → fleet + PF
sgen/load rows; PlantSpec gains `fuel`/`h2_store_id`; dangling refs are 400s),
offshore hub as inverter row with backend-owned §1.16 path losses + LFSM-O,
per-class step commands with clamps, device reporting (soc/h2_kg/link p),
snapshot + model_hash over the new blocks. GAME: buildables battery 300 MW/
600 MWh, electrolyzer 300 MW, H2 cavern 4 000 t (salt-cavern resource),
HVDC converter 2 GW, offshore platform 2 GW; `hvdc` corridor kind (may cross
deep sea); far-shore farm→platform binding (2-tile collector ring, deep-sea
farms only placeable inside one); topology builder emits the devices channel
(HVDC component analysis: 2 converters = link, platform+converter = hub with
cable_km; nearest-cavern electrolyzer binding; `convert_to_h2` fuel switch
lands in the native doc), hub availability aggregated per block by Dispatch,
price-signal arbitrage with hysteresis (batteries scarcity-discharge/cheap-
charge, electrolyzers soak ≤ 20 €/MWh blocks), flex-load feedback into the
demand ledger, `link_setpoints` manual HVDC, Economy capex/FOM/fuel entries
(ledger 31), HUD storage/H2 strip; build-palette keys q/w/e/r/u/z.

**Tests:** backend 121 (17-case wire-device suite: reset validation, FFR,
H2 draw/derate at the 45 t/h cavern limit, paired-injection neutrality, hub
loss/trip asymmetry, snapshot round-trip carrying SoC/levels/link state);
GdUnit 25/25 (device-emission + H2-conversion topology tests new); smokes
`hydrogen_chain` / `battery_response` / `hvdc_link` / `north_sea_hub` all
green on port 8034 (P7SmokeBase).

**Acceptance evidence (fork-verified, current code):** H2 round trip
**0.349** (≈ 35 % §1.14 pin) across a forced windy→calm cycle with fill,
burn, floor-derate and `fuel_starved` in sequence; battery fleet turns a
47.47 Hz collapse into a **49.90 nadir** (Δ 2.43 Hz) on the same trip;
embedded bipole at 800 MW relieves a 142 %-loaded AC path to 70 %, its trip
redistributes flows back (155 %) at f_min 49.61 — while the hub trip on a
comparable island is a genuine infeed loss to 47.41 (ledgers 27/28 as a
matched pair); hub delivery ratio 0.9447 matches the §1.16 loss model.

**Discoveries:** (1) REAL orchestrator bug: `register()` left a stale
pre-reset `last_result` — after any rebuild the dispatcher read dead device
states, zeroed every cap and dumped batteries into a healthy island; now
cleared on register. (2) Threshold-only flexibility switching limit-cycled
±600 MW/block into fleet-wide f-window trips — hysteresis added; battery
discharge is scarcity-gated (SoC-aware policy queued for P8). (3) Per-block
`avail_mw` sample-and-hold turns weather ramps into GW-scale steps (relayed
out a 6 GW wind fleet twice): smokes ramp forces over 8–24 blocks; a wire
avail-slew or game-side interpolation is a P8 candidate. (4) λ-forces > ~1.5
push midday wind past the 25 m/s cutout — a "windy week" force of 3.0 is a
zero-delivery storm. (5) Small islands idle ~0.1 Hz low with standing FCR
(no aFRR until P8) — frequency assertions must be ambient-relative.

**Deviations (deliberate):** H2 fuel value fixed at 90 €/MWh_th (ledger 31);
HVDC dispatcher manual-only (ledger 32); battery VOM (throughput) not booked
(no per-battery energy meter on the wire yet); GFM buildable variant + SoC-
aware arbitrage + H2 monthly-projection panel deferred to P8 UI; `/gb/net/
patch` add/remove_device (AC↔hub farm switching) still via full debounced
reset; **PHS pump mode/SoC missed** — hydro_ps remains turbine-only (the
P7 "pumped hydro dispatchable + SoC on the wire" clause): catch up in P8
with the 49.7 Hz pump-shed tier, which is a no-op until pumping exists.

**Next:** P8 — protection, UFLS, cascades, replay, teaching UX.

### P8 — Protection, UFLS, cascades, replay, teaching UX (2026-08-13)

**Built:** BACKEND — DefensePlan (PARAMETERS §2.2: 6 UFLS stages, 150 ms
pickups, per-event latching onto `islands.w`; 49.7 pump-shed + 49.6
electrolyzer interruptible tiers, latched, dispatcher re-commands
overridden; restoration ramp 1 %/10 s gated on 5 min > 49.8 Hz, re-gated on
every dip, full restoration re-arms all latches; RoCoF feel table on the
500 ms windowed value — embedded-DG trips as `p_extra` net load, pole-slip
draws from the `protection_seed` PRNG in event order, PRNG state in the
snapshot); sync-side LFSM-O; overload protection at PF instants (≥150 %
instant, duty >120 % → 3000 %·s, decay <100 %); line_trip/line_close as
wire state changes with the |Δf| < 200 mHz resync gate; island split/merge
(components of the in-service graph, parent-inherited f/w/defense state,
per-island p_l0/loss redistribution, per-island PF slack election, dead
islands leave the AC solve; every island on the wire, zones supplied = its
island's w); snapshot v2 (engine + line states + duty); rolling snapshot
ring (5 s marks — already ON the tick grid, boundary sequence untouched) +
`POST /gb/replay` (throwaway sim, counterfactual overrides, PF off/losses
frozen, read-only-pinned); blackout w→0 doctrine + black start (ledger 34);
PHS pump mode (P7 catch-up: negative dispatch = motor load at unit ramp,
inertia stays in the pool, reservoir SoC η 0.88/0.90, hard bounds, soc on
the wire). GAME (fork-built): `views/frequency_cluster.gd` (banded dial,
RoCoF with §2.2 threshold colors + peak hold, H_sys gauge with 2.5 s
warning, FCR deployed-vs-procured bar, UFLS shed line, per-island rows
after splits, 120 s multi-island trace), `views/replay_panel.gd` (auto-
fetches ≤2 counterfactuals per significant event via `/gb/replay`, caches
3 events with ghost traces + stage chips + "removed device bought +X Hz",
key R), `model/advisor.gd` (N-1 reference incident = max(largest unit,
largest hub delivery) vs fleet FCR headroom — the P3 lesson — plus RoCoF
projection), event-log vocabulary for every P8 event kind; ALERT hot-path
fast-paths (defense + relays scalar guards: engine cost 13 → 7 s per 900 s
ALERT block).

**Tests:** backend 139 (defense gates, cascade acceptance, replay
isolation/ghost pins, black start, PHS); GdUnit 25/25; smokes
`cascade_low_inertia` + `ride_through` + `replay_panel` green (port 8034)
+ the full 8031 matrix rerun against the P8 engine.

**Acceptance evidence:** the SAME scripted double trip: high-inertia fleet
nadir 49.80, zero shed — low-inertia fleet 1.94× the RoCoF, dives to 47.94,
**all 5 reachable UFLS stages fire (45 % shed, w = 0.55) and the island
survives**; ride-through: largest-unit trip to 48.40 with UFLS 1+2 while
all 10 wind farms ride through delivering (RfG); emergent cascade pinned
backend-side: 1.75 GW hub delivery overloads the copenhagen corridor →
duty trip → island split → the surplus pocket outruns LFSM-O and dies
while the main island keeps solving — zero special code; replay: plain
aftermath reproduces the live nadir within 0.07 Hz, removing the battery
fleet deepens the ghost by +0.78 Hz, expiry honest after 120 s.

**Discoveries:** (1) restart-into-load and sync-at-P_min-into-no-load both
kill a black start — ledger 34's doctrine came from both failure modes.
(2) UFLS stage 1 overcorrects the §2.3 reference loss — ledger 35. (3) The
DefensePlan tick cost 25 % of the ALERT hot path before the scalar fast
paths. (4) An islanded SURPLUS pocket usually dies (over-f cliff) — the
honest counterpart to deficit collapse.

**Deviations (deliberate):** replay resolves `t_sim` only (wire events
carry no ids); ring entries at event instants are post-application —
replays compare AFTERMATHS (GAME_DESIGN §4.5 reads unchanged); `auto` HVDC
congestion relief still deferred (ledger 32); the §4.2 hum needs a headed
run to tune; mode-hysteresis constants (ledger 5) untouched — permanent-
ALERT islands remain slow-ish by design (7 s engine + PF per block), a
P10 revisit.

**Next:** P9 — campaign, scenarios, save/load, balancing.

## 7. Open questions for the project owner

Recommended defaults are in force until overridden; each override gets a
ledger entry:

1. **License** — Apache-2.0 proposed (family preference not recorded in the
   digests).
2. **UI language** — family is German-first (de → en parity). Same here, or
   English-first for this title?
3. **CO2 policy** — campaign ratchet 30→250 €/t as scripted eras (chosen);
   alternatively a free player-visible ETS slider in sandbox only.
4. **Unit granularity** — fixed unit sizes per tech (1600/800/600/… MW,
   chosen — the N-1/RoCoF sizing lesson needs discrete large units) vs
   continuously sizable plants.
5. **Calendar compression** — 12 representative days/year (chosen) vs
   continuous years (much longer campaigns or much faster wall speeds).
6. **infrastruct convergence** — assumed fully independent title with
   envelope-compatible contract lineage; if the backend should ever serve
   infrastruct, coordinate the v2 freeze (P4) with its CosimBridge.
7. **Synthetic-inertia & PHS variants** — wind synthetic inertia ships as a
   2035 unlock (chosen); ternary/var-speed PHS and PHS syncon mode are
   backlog flags.
