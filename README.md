# rttransportflow

**A Europe-scale power transmission game with real grid physics.**

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

## What this repo is

A monorepo with two tightly-coupled halves, following the conventions of its
sibling projects ([rtpowerflow](https://github.com/markisbell/rtpowerflow),
rtheatflow, rtwaterflow, infrastruct):

1. **Backend** (`src/rttransportflow/`, Python/FastAPI): a realtime
   transmission-grid simulator coupling quasi-static AC power flow (pandapower)
   with a per-island frequency-dynamics layer (center-of-inertia swing equation
   + distinct governor/turbine ODE models per plant type). Runs standalone as a
   teaching/research tool (accelerated tick, REST+WS, Grafana stack) or in
   puppet mode under the game ("the game owns time", gamebridge contract v2).
2. **Game** (`game/`, Godot 4 / GDScript): the Europe map, tile building,
   economy, campaign, and the teaching UX (frequency instrument cluster,
   annotated event replays, adequacy advisor).

## Status

**P0–P8 implemented, P9/P10 in progress**: backend scaffold, europe_mini PF
time-series + Grafana stack, the frequency-dynamics engine (analytically
validated), per-kind plant models, the frozen gamebridge v2 contract, the
Godot game (960 × 804 tiles at 5 km over real Natural Earth geometry, 3D
isometric view with streamed terrain, menu-driven building, live frequency
dial), demand/weather/dispatch/economy, storage + hydrogen + HVDC, and the
protection layer (UFLS, cascades, black start, counterfactual replay).
Per-phase log: [CLAUDE.md](CLAUDE.md) §6. Plan documents:

| Document | Contents |
|---|---|
| [SPEC.md](SPEC.md) | Binding master spec: architecture, repo layout, data contract, testing, process rules |
| [ROADMAP.md](ROADMAP.md) | Phased build order P0–P10 with acceptance criteria and smokes |
| [docs/PHYSICS.md](docs/PHYSICS.md) | Simulation engine: equations, integrator, protection, performance budget, validation tests |
| [docs/PARAMETERS.md](docs/PARAMETERS.md) | Per-technology dynamic models, parameter tables, economics, weather model |
| [docs/GAME_DESIGN.md](docs/GAME_DESIGN.md) | Map, load centers, game loop, teaching UX, campaign |
| [docs/contract/v2.md](docs/contract/v2.md) | Gamebridge v2 wire contract (draft until frozen in P4) |
| [CLAUDE.md](CLAUDE.md) | Handoff/context document: binding rules, decision ledger, open questions |

## Quickstart

### Play the game

From a source checkout (needs `./install.sh` once, and a Godot 4.7.1
binary — `scripts/find_godot.sh` documents where it is looked for):

```bash
./start_game.sh                # sandbox: the inherited 2025 world
./start_game.sh --campaign     # campaign mode (milestone tracker armed)
./stop_game.sh                 # stop the game + its backend sidecar
```

The game spawns and supervises its own physics backend on port 8030;
`.run/game.log` carries the session log. Or build the self-contained
bundle (no Python on the player's machine):

```bash
scripts/package_game.sh linux      # frozen backend + exported game + data
build/dist/rttransportflow-*-linux-x86_64/rttransportflow.x86_64
```

### Run the backend alone (teaching mode)

```bash
docker compose up          # backend :8003, Grafana :3003
# or
./install.sh && ./start_rttransportflow.sh
```

## What the physics is (and honestly is not)

The backend couples quasi-static AC power flow (pandapower Newton-Raphson —
flows, voltages, reactive power, losses) with a **per-island
center-of-inertia swing equation + per-plant governor/turbine ODEs**
integrated at 10 ms (ALERT) / 250 ms (CALM). Frequency, RoCoF, nadir, and
governor response are computed, never scripted, and validated against
analytic closed forms (`tests/test_dynamics_analytic.py`).

**Not modeled** (docs/PHYSICS.md §2.1 — do not fake it): inter-machine
rotor-angle swings and inter-area oscillation modes (frequency is uniform
per island by construction), transient/voltage stability, loss of
synchronism, AVR/exciter dynamics (voltage is quasi-static between PF
instants), LFSM-U, EMT phenomena.
