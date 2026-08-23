# rttransportflow — a Europe-scale power transmission game with real grid physics

![AI-generated](https://img.shields.io/badge/source-AI--generated-8A2BE2)
![validated](https://img.shields.io/badge/physics-analytically%20validated-brightgreen)
![platforms](https://img.shields.io/badge/plays%20on-Linux%20%7C%20macOS%20%7C%20Windows-blue)

> [!NOTE]
> **AI-generated code.** The source code, tests and documentation of this
> project were written by an AI coding agent (Claude Code, Anthropic),
> working under human direction: a person specified the requirements and
> domain decisions, reviewed the results and verified the features live
> against the running game. Treat it accordingly — read before you trust.

You are GridCo Europa: owner and operator of the continent's transmission
backbone. You build large power plants (nuclear, coal, CCGT/OCGT, wind on- and
offshore, solar), storage (pumped hydro, batteries), and a hydrogen chain
(electrolyzers → salt caverns → H₂-fired gas turbines). You string the 220/400 kV
lines that move the power to Europe's load centers — and, when the near-shore
connections saturate, the HVDC corridors and North Sea converter platforms
that bring far-shore offshore wind ashore. And you keep the lights on —
because the grid in this game has a *real frequency*.

Every synchronous machine you build adds rotating inertia; every solar park that
displaces one removes it. When a 1.6 GW unit trips, the frequency dives with a
RoCoF and nadir computed from an actual per-island swing equation, arrested by
the governor dynamics of *your* fleet — coal's sluggish reheat, the gas
turbine's quick valve, the battery's near-instant FFR, the pumped-hydro
governor's wrong-way kick. Decarbonize Europe without degrading frequency
stability. Feel why inertia matters, and learn the toolkit (grid-forming
storage, synchronous condensers, fast reserves) that replaces it.

Fourth backend of a family — after
[rtpowerflow](https://github.com/markisbell/rtpowerflow) (distribution),
rtheatflow (district heat) and rtwaterflow (water) — and the first that is a
*game* first: same FastAPI/puppet-mode/contract DNA, plus a Godot 4 title on
top.

---

## The two halves

One monorepo, two tightly-coupled applications:

| App | What it is | Port |
|-----|-----------|------|
| **Backend** (`src/rttransportflow/`) | FastAPI transmission simulator: pandapower AC power flow coupled to a per-island frequency-dynamics engine; standalone teaching mode or puppet mode under the game | 8003 (standalone) / 8030 (game sidecar) |
| **Game** (`game/`) | Godot 4 title: the 5 km Europe map, building, economy, campaign, teaching UX | spawns and supervises its own backend |
| *Visualization* (`visualization/`) | collector → InfluxDB → Grafana for the standalone teaching mode | 8089 / 3003 |

The backend stays standalone-runnable by convention: its own pyproject,
Docker, clock — no imports from `game/`.

---

## What it can do

- **Real frequency dynamics.** Per-island center-of-inertia swing equation +
  distinct governor/turbine ODE models per plant kind (steam reheat, CCGT
  gas-path, hydro water-column with wrong-way kick, battery FFR with SoC,
  grid-forming virtual inertia, electrolyzer shed, wind/PV LFSM-O),
  integrated at 10 ms (ALERT) / 250 ms (CALM) with exact-exponential lags —
  bit-exact under step slicing, snapshot/restore bit-replayable.
- **A real European grid.** 960 × 804 tiles at 5 km on Natural Earth
  geometry (real coastlines, relief, lakes, urban footprints); the inherited
  world is the German 380 kV backbone at full fidelity plus lean spines to
  16 continental metros, real interconnectors and DC projects (SuedLink,
  NordLink…), the gigawatt fleet on its real sites (WRI GPPD: Jänschwalde,
  Eemshaven…), six Alpine pumped-storage stations, the 2025 renewable base,
  and a North Sea that exports like the real one — near-shore parks over
  submarine AC cables, the German Bight over a BorWin-style converter
  platform landing DC at Diele.
- **Protection & blackouts as gameplay.** Six-stage UFLS, RoCoF-triggered
  distributed-generation trips, line overload duty, cascade splits, islands
  that die and black-start back, pump/electrolyzer shed tiers — and
  **counterfactual replay**: after an event, ghost traces show what the
  frequency would have done without your battery fleet.
- **Economy & dispatch.** A merit-order dispatcher with locality, FCR/aFRR
  reserves, must-take renewables and curtailment, scarcity pricing; regulated
  tariff on delivered energy; capex/fuel/CO₂/VoLL books with a
  ledger-consistency identity.
- **Teaching UX.** Frequency instrument cluster (RoCoF, nadir peak-hold,
  inertia gauge, FCR deployment), an adequacy advisor, event vocabulary, and
  per-site weekly charts in the energy-charts.info style — click a city's or
  plant's location pin to open its measured generation/load week.
- **Campaign, sandbox, scenarios.** Milestone campaign on the inherited 2025
  world, a classroom sandbox console (difficulty, scripted trips, weather
  forcing), and hand-editable scenario recipes.
- **Ships on three platforms.** Self-contained bundles (frozen backend, no
  Python on the player's machine) for Linux, macOS (Apple Silicon) and
  Windows — each verified in CI by *playing a simulated day inside the
  bundle*.

---

## Status & documents

**P0–P10 complete** — scaffold through packaging, plus the post-release
arcs: the realistic campaign world, the strategic-zoom UI, site notes, the
North Sea build-out and the macOS/Windows installers. Per-phase log with
acceptance evidence: [CLAUDE.md](CLAUDE.md) §6.

| Document | Contents |
|---|---|
| [SPEC.md](SPEC.md) | Binding master spec: architecture, repo layout, data contract, testing, process rules |
| [ROADMAP.md](ROADMAP.md) | Phased build order P0–P10 with acceptance criteria and smokes |
| [docs/PHYSICS.md](docs/PHYSICS.md) | Simulation engine: equations, integrator, protection, performance budget, validation |
| [docs/PARAMETERS.md](docs/PARAMETERS.md) | Per-technology dynamic models, parameter tables, economics, weather model |
| [docs/GAME_DESIGN.md](docs/GAME_DESIGN.md) | Map, load centers, game loop, teaching UX, campaign |
| [docs/contract/v2.md](docs/contract/v2.md) | Frozen gamebridge v2 wire contract |
| [CLAUDE.md](CLAUDE.md) | Handoff document: binding rules, decision ledger, development log |

---

## Install & play (no Python, no Godot required)

Download the bundle for your OS from the
[**Releases**](https://github.com/markisbell/rttransportflow/releases) page
— each is fully self-contained (game, frozen physics backend, map and
campaign data) and was verified in CI by *playing a simulated day inside
the bundle*:

| OS | Download | Install |
|---|---|---|
| **Windows** (x86_64) | [rttransportflow-0.0.1-windows-x86_64.zip](https://github.com/markisbell/rttransportflow/releases/download/v0.0.1-pre/rttransportflow-0.0.1-windows-x86_64.zip) | unzip anywhere → run `rttransportflow.exe`. SmartScreen warns once (unsigned binary): **More info → Run anyway**. `rttransportflow.console.exe` runs the same game with a log console. |
| **macOS** (Apple Silicon) | [rttransportflow-0.0.1-macos-arm64.zip](https://github.com/markisbell/rttransportflow/releases/download/v0.0.1-pre/rttransportflow-0.0.1-macos-arm64.zip) | unzip → once, in Terminal: `xattr -cr rttransportflow.app` (the app is ad-hoc signed, not notarized — this clears Gatekeeper's quarantine) → open `rttransportflow.app`. Intel Macs are not supported. |
| **Linux** (x86_64) | [rttransportflow-0.0.1-linux-x86_64.tar.gz](https://github.com/markisbell/rttransportflow/releases/download/v0.0.1-pre/rttransportflow-0.0.1-linux-x86_64.tar.gz) | `tar xzf`, then `./rttransportflow.x86_64` |

The game starts its physics backend itself (port 8030) and writes logs to
`.run/` next to the executable. Save games land beside it too — keep the
folder somewhere writable.

Rebuilding the installers: `scripts/package_game.sh linux` on a Linux
machine; the macOS and Windows bundles build on GitHub's runners
(PyInstaller cannot cross-compile, so each backend freezes on its own
platform) — trigger the `ci.yml` workflow manually (`gh workflow run
ci.yml` or the Actions tab) and fetch the artifacts.

---

## Installation (from source)

**Requirements:** Python ≥ 3.12 for the backend and a Godot 4.7.1 binary
for the game.

```bash
git clone https://github.com/markisbell/rttransportflow.git
cd rttransportflow
./install.sh        # uv-managed .venv (Python 3.12) + dev dependencies
```

`scripts/find_godot.sh` documents where the Godot binary is looked for
(`$GODOT` env, `.tools/godot/`, a sibling checkout, `PATH`).

---

## Run it

### Play the game (from source)

```bash
./start_game.sh                # sandbox: the inherited 2025 world
./start_game.sh --campaign     # campaign mode (milestone tracker armed)
./stop_game.sh                 # stops the game AND its backend sidecar
```

The game spawns and supervises its own physics backend on port 8030 and
writes the session log to `.run/game.log`. `stop_game.sh` matches by working
directory, so a parallel stack stays untouched (family launcher pattern).

### Run the backend alone (teaching mode)

```bash
docker compose up          # backend :8003 · InfluxDB :8089 · Grafana :3003
# or, without Docker:
./start_rttransportflow.sh && ./stop_rttransportflow.sh
```

Standalone, the backend free-runs its own accelerated clock over the
europe_mini day and streams every solved step (REST + WebSocket); the
provisioned Grafana dashboard shows flows, voltages and the live frequency.

**Port scheme** (deliberate, collision-checked against the sibling
projects): backend 8003, game sidecar 8030, acceptance smokes 8031, contract
tests 8032, per-smoke backends 8034–8043. `RTTF_PORT_OFFSET=<n>` shifts a
whole smoke run for parallel use.

---

## Architecture

```
                     GAME (Godot 4) — owns time
  WorldModel ─► GridTopology ─► native bundle ─► gamebridge v2 (HTTP/WS :8030)
      │              (debounced rebuild+reset)         │  puppet mode:
  Weather/Demand/Dispatch/Economy (15-min blocks)      │  "one step per wire call"
      │                                                ▼
  Orchestrator (10 Hz wall ticks, one-in-flight, ── DynSimulator
  skip-never-stall, auto-slow on events)               │
                                                       ├─ pandapower AC PF (1 s/30 s + events)
                                                       ├─ per-island COI swing + fleet ODEs
                                                       │  (10 ms ALERT / 250 ms CALM)
                                                       └─ DefensePlan (UFLS, RoCoF, overload,
                                                          islanding, black start) + snapshot ring
  standalone instead: RealtimeEngine (accelerated tick :8003)
                         └─► collector ─► InfluxDB ─► Grafana
```

Key design choices, all inherited from the family: **build once, step
cheaply**; the solve runs off the event loop; **the game owns time** (wire
`t` is a sequence number, the game clock advances by `dt_done_s`);
divergence is data (non-convergence never 500s); no RNG in the engine except
the seeded protection PRNG; every wire float rounded, NaN-free.

---

## Configuration (`.env`, prefix `RTTRANSPORTFLOW_`)

| Var | Default | Meaning |
|-----|---------|---------|
| `DATA_DIR` | `data/grids/europe_mini` | native grid bundle (standalone mode) |
| `SIMULATOR` | `dyn` | `dyn` (PF + frequency dynamics) · `pf` · `null` |
| `PORT` | `8003` | backend port |
| `STEP_INTERVAL_SECONDS` | `1.0` | wall seconds per 15-min step (standalone tick) |
| `EXTERNAL_CLOCK` | `false` | `true` = puppet mode (the game owns time) |
| `AUTOSTART` | `true` | start the standalone loop on boot |
| `WARM_START` | `true` | warm-start each power flow |
| `RECORD` / `RECORD_DIR` | `false` / `.run/recordings` | JSONL session recording |

Dynamics knobs (tick sizes, hysteresis, PF cadence) exist but move the
bit-exact-pinned test grid — see the warning in `config.py`.

---

## Tests

```bash
.venv/bin/pytest                    # backend suite (includes contract fixtures)
```

Game side: GdUnit4 suites (topology goldens, map validations, model layers)
plus ~20 headless **acceptance smokes** — each boots the real game against a
real backend and asserts a scripted verdict (`--smoke=boot_and_day`,
`trip_reaction`, `hydrogen_chain`, `cascade_low_inertia`,
`campaign_take_the_reins`, `save_load_replay`, `soak`, …). The release
checklist in [CLAUDE.md](CLAUDE.md) §8 runs all of them, each smoke on its
own port.

---

## Validation

The frequency engine is pinned against **analytic closed forms**, not
against itself: post-trip RoCoF within 0.5 % of the analytic value,
quasi-steady-state frequency within 0.1 %, nadir regression-pinned to
±10 mHz, the energy-balance identity ≤ 1e-9 (semi-implicit pairing makes it
exact), slicing invariance bit-exact, and the PARAMETERS §2.3 worked
reference incident reproduced within its ±2 % pins
(`tests/test_dynamics_analytic.py`, `tests/test_plant_models.py`). Library
behavior is runtime-verified (`scripts/validate_core.py`) and pinned
(`tests/test_pandapower_pins.py`). Emergent cross-checks are pinned too —
the hydrogen chain's measured **36.5 % power-to-power round trip** against
the ≈ 35 % prediction that falls out of electrolyzer specific energy ×
compression aux × turbine efficiency, untuned.

---

## What the physics is (and honestly is not)

The backend couples quasi-static AC power flow (pandapower Newton-Raphson —
flows, voltages, reactive power, losses, shunt-compensated cable charging)
with a per-island center-of-inertia swing equation and per-plant
governor/turbine ODEs. Frequency, RoCoF, nadir and governor response are
computed, never scripted.

**Not modeled** (docs/PHYSICS.md §2.1 — do not fake it): inter-machine
rotor-angle swings and inter-area oscillation modes (frequency is uniform
per island by construction), transient/voltage stability, loss of
synchronism, AVR/exciter dynamics (voltage is quasi-static between PF
instants), LFSM-U, EMT phenomena. HVDC is a controlled P-transfer with
converter losses and Q capability — no DC-side load flow or droop control.

---

## License & data

The **code has no license yet** — the choice (Apache-2.0 proposed) is an
open owner decision tracked in [CLAUDE.md](CLAUDE.md) §7; until a LICENSE
file lands, default copyright applies.

The shipped **data** is deliberately license-clean:

- Map geometry, relief, lakes, urban footprints:
  [Natural Earth](https://www.naturalearthdata.com/) (public domain).
- Real power-plant sites and names: [Global Power Plant Database
  v1.3](https://datasets.wri.org/dataset/globalpowerplantdatabase), World
  Resources Institute (CC-BY 4.0).
- Location-pin icon: [openclipart 305298](https://openclipart.org/detail/305298/location)
  (CC0); city building models: [Kenney](https://kenney.nl/) kits (CC0).
- OpenStreetMap/OpenInfraMap data is **deliberately not used** (ODbL
  share-alike would attach to the shipped tile grid — CLAUDE.md ledger 38).

Runtime dependencies are permissively licensed (pandapower/numpy: BSD;
FastAPI/pydantic: MIT; Godot: MIT); Grafana (AGPL-3.0) and InfluxDB are only
*operated* as separate containers, never linked or embedded.
