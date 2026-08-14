# SPEC.md — rttransportflow master specification

| | |
|---|---|
| Deliverable | Europe-scale power transmission game: Python/FastAPI dynamics backend + Godot 4 game, one monorepo |
| Spec version | 0.1 (planning baseline, 2026-08-10) |
| Blueprint repos | `../rtpowerflow` (backend template), `../rtheatflow` (spec/process template), `../infrastruct` (game + contract template) |
| Solver core | pandapower (AC power flow) + own NumPy dynamics layer — versions pinned in `pyproject.toml` at P0 |
| License | Apache-2.0 (proposed — confirm; **hard rule: no code from gridedit/gridgen — AGPL — pattern-level reuse only**) |
| Platform | Linux + Windows, Python 3.11+, Godot 4.x |

## How to read this document

- SPEC.md is the **binding master document** for architecture, repo layout, data
  contract, testing, and process. Detail lives in the referenced documents; on
  conflict the **precedence rules** in §0.2 decide.
- Sections marked **(binding)** are requirements; a coding agent may not deviate
  without recording the deviation in CLAUDE.md as deliberate.
- The build order is [ROADMAP.md](ROADMAP.md). **Do not start a phase before the
  previous phase's acceptance criteria pass.**

---

## §0 Mandatory pre-reading and precedence

### §0.1 Pre-reading (binding)

Before writing any code, read — in this order:

1. [CLAUDE.md](CLAUDE.md) — binding rules + decision ledger.
2. [ROADMAP.md](ROADMAP.md) — the phase you are in.
3. [docs/PHYSICS.md](docs/PHYSICS.md) — the engine design (equations,
   integrator, tick order, protection, validation tests).
4. [docs/PARAMETERS.md](docs/PARAMETERS.md) — every per-technology model and
   number.
5. [docs/contract/v2.md](docs/contract/v2.md) — the wire contract.
6. [docs/GAME_DESIGN.md](docs/GAME_DESIGN.md) — the game half.
7. Reference implementations in the sibling repos (paths in CLAUDE.md §5):
   above all `infrastruct/docs/contract/v1.md` (contract ground rules),
   `infrastruct/backends/rtpowerflow/src/netzsim/api/gamebridge.py` (reference
   gamebridge implementation), `rtpowerflow/src/netzsim/{engine,simulator,
   network_builder,config}.py` (family backend shape), `rtheatflow/SPEC.md`
   (process discipline), `infrastruct/game/autoloads/orchestrator.gd` (the
   scheduler to port near-verbatim).

### §0.2 Document precedence (binding)

| Question | Authority |
|---|---|
| Equations, integration scheme, tick order, protection logic, engine module design, validation tests | docs/PHYSICS.md |
| Any per-technology parameter (H, droop, time constants, ramps, efficiencies, costs), reserve/defense-plan tables, weather model | docs/PARAMETERS.md |
| Wire protocol (messages, fields, semantics, versioning) | docs/contract/v2.md (→ `docs/contract/v2.md` once frozen in P4) |
| Map, tiles, load centers, game loop, economy rules, campaign, UI | docs/GAME_DESIGN.md |
| Architecture, repo layout, data files, testing strategy, process | SPEC.md (this file) |
| Build order and acceptance criteria | ROADMAP.md |

Where two documents state the same fact, the non-authoritative one is a
courtesy copy — fix it to match the authority, never the other way around.
The reconciliation ledger in CLAUDE.md §4 records every conflict already
resolved during planning; re-opening one requires a new ledger entry.

---

## §1 Vision

One sentence: **SimCity for the European transmission grid, with a real
frequency.** The player's build decisions continuously reshape a physically
honest system — AC power flow for where the power goes, a per-island swing
equation plus per-plant governor dynamics for how the grid *breathes* — so that
the energy transition's core systems problem (replacing synchronous inertia
with converter-based resources) is not narrated but *felt*.

Design pillars (binding, from docs/GAME_DESIGN.md):

1. **You feel inertia.** The frequency dial is the protagonist.
2. **Physics is never faked.** Consequences are layered on solved outputs
   (infrastruct principle); replays annotate real traces.
3. **Automatic dispatch, deliberate strategy.** Merit order runs itself;
   the player builds and sets policy.
4. **One honest compression.** 50 km tiles, ~25 load zones, ≤150 buses,
   12 representative days per year — documented, consistent, never pretending
   to higher fidelity.

The **honesty section** (rtheatflow §3.5 pattern) is mandatory in
docs/PHYSICS.md §2.1 and must be mirrored in-game: uniform frequency per
island (no rotor angles, no inter-area modes, no transient/voltage stability,
no EMT, no AVR dynamics). Say what is modeled; do not fake the rest.

---

## §2 Architecture decisions (binding; ADRs to be written at P0)

### §2.1 New dedicated backend — not an rtpowerflow extension

rtpowerflow is a quasi-static one-solve-per-minute distribution simulator with
shipped users and a pinned API surface. This game needs an electromechanical
dynamics engine (10–250 ms internal ticks, continuous unit states, a frequency
result vocabulary) coupled to AC power flow — a different inner loop and state
model. Build the new sibling; inherit the family template (engine/simulator/
state/api shape, retry ladder, `_r()` rounding, gamebridge ground rules,
Docker/Grafana/launcher kit). Full rationale: CLAUDE.md §4 ledger entry 1.

### §2.2 One monorepo

`rttransportflow` holds backend (`src/rttransportflow/`) **and** game
(`game/`). Unlike infrastruct (three pre-existing backends → submodules), this
game has exactly one backend with a co-evolving contract: schema + backend +
game client + golden fixtures change atomically. The backend stays
standalone-runnable by convention (own pyproject, console script, Docker stack,
internal accelerated clock, zero imports from `game/`).

### §2.3 Identity (binding)

| Item | Value |
|---|---|
| Python package | `rttransportflow` (src-layout), console script `rttransportflow = rttransportflow.main:main` |
| Env prefix | `RTTRANSPORTFLOW_` (pydantic-settings, `.env` supported) |
| `/health` | `{app: "rttransportflow", version}` (family port-sharing identity) |
| Standalone ports | backend **8003**, InfluxDB 8089, Grafana 3003. **No backend web UI in v1** (ledger 25): the game is the UI; Grafana is the standalone visualization. 5176/8083 stay reserved-unused in the family scheme |
| Game/sidecar ports | game **8030**, smokes **8031**, contract tests **8032** (ledger 24) — never 8000–8002 (user dev instances), never 8010–8016 (infrastruct sidecars + smokes), never 8020–8029 (infrastruct contract tests) |
| Wire power unit | **MW** (deliberate, documented deviation from the kW distribution siblings; ADR at P0) |
| Frequency | f0 = 50 Hz; engine units MW/MVA/Hz/s/MJ (per-unit only for droop R and load damping D) |

### §2.4 Co-simulation model (binding)

“The game owns time” — unchanged from infrastruct: backend runs with
`RTTRANSPORTFLOW_EXTERNAL_CLOCK=true`, stepped over WS `/gb/ws` (HTTP control
plane `/gb/*`), one frame in → one frame out, strictly sequential, idempotent
last-`t` cache, out-of-order → 409, divergence is data, warmup solve at every
reset. What v2 adds (authority: docs/contract/v2.md):

- **Variable step size**: `dt_s` is a float in **[0.05, 900]**. The game sizes
  it from its speed setting (recipe: step at ~10 Hz wall with
  `dt_s = 0.1 × speed`). The backend integrates internally at its own fixed
  ticks; the trajectory is **independent of how the game slices time**
  (slicing-identity test, binding).
- **Early return on event**: a step may consume only part of `dt_s` when a
  significant event fires (`dt_done_s < dt_s`); the game auto-slows and
  continues from where the backend stopped. This reconciles 900× fast-forward
  with 10 ms dynamics.
- **Trajectory block** in every result (decimated f/RoCoF arrays ≤512 samples
  + exact-timestamped events) — the game renders 60 fps dial motion from the
  previous step's buffer (one-step lag, skip-never-stall, Orchestrator ported
  near-verbatim).
- **Snapshot/restore** for save/load; **`/gb/replay`** (control plane) re-runs
  the last event window with parameter overrides for the counterfactual
  teaching UI — physics is implemented exactly once, in the engine.

### §2.5 Physics split (binding)

- **Backend**: network physics (AC PF: flows, V, Q, losses, loadings),
  frequency dynamics (per-island COI swing + per-plant governor/turbine/
  converter ODEs), protection (UFLS, f-windows, LFSM-O, overload trips,
  islanding), AGC, SoC/H₂ mass bookkeeping, energy/fuel meters.
- **Game**: weather + availability models (wind/PV `avail_mw` sent per step),
  demand model (zone `value_mw`), dispatch/commitment (merit order), economy/
  billing (on backend meters), events *scheduling* (the engine executes
  scheduled events deterministically; the engine itself contains **no RNG** —
  the one exception, seeded pole-slip draws, takes its seed from the reset doc).

---

## §3 Repository layout (binding)

```
rttransportflow/
├── CLAUDE.md  README.md  SPEC.md  ROADMAP.md  LICENSE
├── pyproject.toml                # src-layout, console script, pytest pythonpath=["src"]; numba EXPLICIT
├── .env.example  Dockerfile  docker-compose.yml  install.sh   # compose: backend + influxdb + grafana + collector (no web UI in v1)
├── start_rttransportflow.sh/.bat  stop_rttransportflow.sh/.bat   # .run/ PIDs+logs; stop kills by cmdline
├── scripts/
│   ├── pick_ports.sh/.ps1        # /health-identity port picking
│   ├── gen_api_doc.py            # docs/API.md generator
│   ├── validate_core.py          # runtime library-API verification harness (rtheatflow rule)
│   └── gen_contract_fixtures.py  # golden-fixture generator (must emit every hand-added probe key)
├── docs/
│   ├── adr/                      # 001 engine split · 002 monorepo · 003 MW wire units · 004 measured budgets · …
│   ├── contract/v2.md → v2.md (frozen at P4) + schemas/
│   ├── PHYSICS.md  PARAMETERS.md  GAME_DESIGN.md
│   └── API.md                    # generated
├── data/
│   ├── grids/europe_mini/        # P1: authored 10-bus, 8-country scenario bundle
│   ├── grids/europe/             # P5+: full campaign map bundle
│   ├── map/europe_v3.json        # tile map, 960x804 @ 5 km (GAME_DESIGN §1.7, ledger 38);
│   │                             #   v1/v2 kept as the load_map() fallback chain
│   ├── scenarios/<id>.json       # P9 scenario RECIPES (§5.4: seed + difficulty +
│   │                             #   forces + world-or-build, never a snapshot)
│   ├── catalogs/                 # plant_types.json line_types.json storage_types.json economy.json
│   ├── profiles/  load_centers/  campaign/
│   └── sources/<id>/DATASET.md   # vendored validation references with provenance
├── src/rttransportflow/
│   ├── main.py  config.py  models.py  data_loader.py
│   ├── network_builder.py        # pandapower build-once + element-index maps (ProfileArrays kin)
│   ├── powerflow.py              # apply ledger → retry-ladder solve → collect; flow protection hook
│   ├── dynamics/                 # docs/PHYSICS.md §4 is the authority for this package:
│   │   ├── fleet.py              #   struct-of-arrays device fleet (params/states/masks, exp-coeff cache)
│   │   ├── plant_types.py        #   loads data/catalogs/plant_types.json (single source of truth)
│   │   ├── swing.py  islands.py  agc.py  hydrogen.py
│   │   ├── integrator.py         #   master loop, ALERT/CALM mode controller, tick order
│   │   ├── events.py  protection.py
│   ├── telemetry.py  snapshot.py
│   ├── simulator.py              # couples PF + dynamics; step(dt_s) → StepResult (single wire format)
│   ├── engine.py                 # RealtimeEngine: accelerated tick (standalone) + external_step (puppet)
│   ├── state.py  recorder.py  exporter.py  scenarios.py
│   └── api/                      # runtime.py (App container) + core/control/grids/recordings/scenarios/gamebridge routers
├── tests/
│   ├── test_known_answer.py  test_api_surface.py  test_pandapower_pins.py
│   ├── test_dynamics_analytic.py  test_dynamics_convergence.py  test_state_chaining.py
│   ├── test_units_comparative.py  test_nonconvergence.py  test_determinism.py  test_perf_budget.py
│   ├── test_gamebridge.py  conftest.py            # process-leak session guard
│   └── contract/                 # WIRE authority: spawns real backend on 8032, golden fixtures, _floatify
├── game/                         # Godot 4 (GDScript; static typing mandatory in model/)
│   ├── project.godot  main.gd    # main.gd = smoke registry dispatch only
│   ├── autoloads/                # game_clock.gd sidecar_manager.gd cosim_bridge.gd orchestrator.gd gridco.gd save_game.gd
│   ├── model/                    # world_model.gd grid_topology.gd weather.gd demand.gd dispatch.gd economy_books.gd
│   ├── views/  ui/               # europe_map, frequency_cluster, replay_panel, build palette, inspector, …
│   ├── smokes/                   # smoke_base.gd + one file per acceptance scenario (--smoke=<name>, one JSON verdict line)
│   └── tests/                    # GdUnit4 + fakes/ + topology golden files
├── orchestration/sidecars.json   # game 8030 / smokes 8031 / contract 8032 port+env config
├── tools/balancing/economy.md    # constants + per-constant rationale + regenerating smoke (family rule)
└── visualization/                # collector → InfluxDB → Grafana (file-provisioned dashboards)
```

---

## §4 Data formats (binding shapes; field detail refined at P1)

### §4.1 Scenario bundle (backend-native input, family N-JSON convention)

A grid scenario is a directory of validated JSON docs (pydantic `models.py` +
`data_loader.py` cross-validation; `input_data_from_dicts` for the gamebridge
path; bus index = list position; platform-unique ids everywhere — never
pandapower element indices):

| File | Content |
|---|---|
| `grid.json` | buses `{name, vn_kv: 380\|220, geo, area}`, `reference_bus`, `zones [{id, bus}]` |
| `lines.json` | AC lines + trafos: std_type or explicit per-km params, `length_km`, `parallel`, `max_i_ka` |
| `plants.json` | `{id, name, bus, kind, type_ref → catalog, overrides{}, p_max_mw, p_min_mw, fuel: ng\|h2\|coal\|lignite\|uranium\|null, h2_store_id?, initial:{online, p_mw}}` |
| `storage.json` | `{id, kind: pumped_hydro\|battery\|battery_gfm\|electrolyzer\|h2_store\|syncon, bus, type_ref, p_max_mw, energy_mwh, soc0, h2_store_id?}` |
| `links.json` | HVDC: `{hvdc_links: [{id, from_bus, to_bus, p_max_mw, length_km}], offshore_hubs: [{id, bus, p_max_mw, platform_mw, cable_km, farm_ids}]}` — wire kinds `hvdc` / `offshore_hub`; `farm_ids` serves standalone-mode availability synthesis only (bound farms are not electrical devices) |
| `load_centers.json` | family profile shape `{resolution_minutes, steps, items:[{name, zone, p_mw[steps], q_mvar?}]}` — drives standalone mode; zeroed in puppet mode (game sends `zone_demand`) |
| `weather.json` | standalone/teaching mode only; **detached in puppet mode** (availability comes from the game) |
| `scenario.json` | name, steps_per_day, budget, objectives, scripted event timeline, economy ref, `protection_seed` |

Native `storage.json` kinds map to wire device kinds as: `battery_gfm` →
`grid_forming`, `pumped_hydro` → `sync_plant` (`type: hydro_ps`), `syncon` →
`sync_plant` (`type: syncon`). The 400 kV level is modeled at nominal
`vn_kv = 380` (industry convention; GAME_DESIGN's "400 kV" names the same
level).

`data/catalogs/` is the backend-served single source of truth (gridedit catalog
pattern); `plant_types.json` carries **every constant of docs/PARAMETERS.md
with a rationale string** ("change a constant → rerun the smoke → commit
both").

### §4.2 Save-game

- **Source of truth = game WorldModel** (infrastruct ADR-002 pattern): versioned JSON
  envelope — tiles, entities (platform pids), money, market state, weather
  seed + clock, per-device replay state (`online`, `p_set_mw`, `soc`,
  start-sequence phase, fuel mode).
- **Load** = rebuild WorldModel → topology builder → `/gb/net/reset` with
  per-device state replayed in `params` → resume.
- **Exact dynamic resume**: `GET /gb/snapshot` → `{t, t_sim, model_hash,
  version, blob}` stored in the save; restore via reset with `snapshot`. On
  hash/version mismatch the backend applies the reset without the snapshot and
  answers `status: "refused_snapshot"`; the game cold-starts from replay
  params — legal because the save UI enforces a **quiesce rule** (save only
  in a settled-frequency window).

---

## §5 Testing strategy (binding)

1. **Analytic physics tests** — docs/PHYSICS.md §6 is the authority: RoCoF and
   quasi-steady-state Δf closed forms, nadir/inertia monotonic sweep, battery
   FFR effect, hydro non-minimum phase sign, exact-lag pin, UFLS cascade,
   islanding, H₂ starvation, energy balance ≤1 % every step
   (`summary.balance_err`).
2. **Numerics honesty** — slicing identity (`step(1×10 s)` ≡ `step(10×1 s)`
   bit-identical, across a mode transition), snapshot bit-replay, sub-step
   convergence.
3. **Library pins** — every pandapower behavior relied on is verified at
   runtime via `scripts/validate_core.py` *before* its spec section is
   trusted, then pinned in `test_pandapower_pins.py` (the rtheatflow rule
   that caught silent-wrong-physics traps).
4. **Contract golden files** — `tests/contract/` spawns the real backend on
   8032; the wire is the authority, in-process fakes never are; `_floatify`
   pins Godot's int-as-float coercion; fixtures for reset+warmup, idempotent
   re-send (no double SoC integration), out_of_order, degraded frame,
   early-return, event ordering, snapshot round-trip.
5. **Game smokes** — `game/smokes/`, one per acceptance scenario on SmokeBase:
   deterministic (seeded, events off, `force_*` weather windows, clock restored
   before start), window assertions not instants, ONE machine-readable JSON
   verdict line, exit 0/1, frozen CLI `--smoke=<name>` headless. A timed-out
   smoke has NO verdict — a gate only counts when its JSON line printed.
6. **Determinism/replay** — same bundle + same command log → byte-identical
   recorder output modulo timestamp/solve_ms.
7. **Performance budget** — pinned at P0 with measured numbers (ADR-004),
   asserted in CI at a relaxed multiplier. Planning targets (docs/PHYSICS.md
   §3): reset+warmup ≤ 5 s; 900 sim-s of CALM in < 1 s wall at reference size
   (≤300 buses / ≤150 devices); ALERT at speed 10 < 100 ms wall per wall-second.
8. **Inherited hygiene** — API-surface route pinning; nonconvergence-is-data
   (forced divergence → degraded frame, loop alive, never 500); external-clock
   equivalence (internal vs puppet 100-step identity); process-leak conftest
   guard; per-hunk `assert old in s` for scripted edits.

---

## §6 Process rules (binding)

- **CLAUDE.md is the handoff log** (rtheatflow format): per-phase entries
  Built / Tests / Acceptance evidence / Discoveries / Deviations (documented,
  deliberate) / Next.
- **Verify before trusting**: no simulation-library claim enters the spec or
  code without a `validate_core.py` runtime check against the pinned version.
- **Phase gates**: ROADMAP.md acceptance criteria are hard gates.
- **JSON wire hygiene**: all wire floats through one `_r()` (round 6,
  non-finite → null — browsers reject literal NaN) — **sole exemption: the
  snapshot blob serializes floats via `repr` for bit-exact restore**;
  `_as_int` tolerance everywhere (Godot sends 96 as 96.0).
- **Never crash the loop**: catch-all in the solve path; racing runtime
  mutations tolerated without locks; self-heal next tick.
- **Determinism**: no RNG in the engine (seeded draws only from
  `protection_seed`); no wall-clock reads in the sim path.
- **Ports**: never 8000–8002 or 8010–8012. Launchers identity-check via
  `/health` before reusing a port.
- **Licensing**: no gridedit/gridgen (AGPL) code — pattern reuse only.
- **Commit/push only on explicit authorization.**
