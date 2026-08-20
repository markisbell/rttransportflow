# GAME_DESIGN.md — map, building, economy, campaign, teaching UX

Authority: map/tiles, load centers, game loop, economy rules, campaign, UI
(SPEC §0.2). Physics numbers quoted here are courtesy copies —
[PARAMETERS.md](PARAMETERS.md) wins on any per-technology number,
[PHYSICS.md](PHYSICS.md) on engine behavior.

**Design pillars**

1. **You feel inertia.** The frequency dial is the protagonist. Every build
   decision changes how the grid *sounds and moves* when something trips.
2. **Physics is never faked.** Consequences are layered on solved outputs
   (infrastruct principle). The replay panel annotates a real engine trace,
   not a canned animation.
3. **Automatic dispatch, deliberate strategy.** The player sets policy and
   builds steel; the merit order runs itself. Overrides exist but are the
   exception.
4. **One honest compression.** Europe at 50 km tiles, 25 load zones, ≤150
   buses, 12 representative days per year. Every compression is documented and
   consistent; nothing pretends to be higher-fidelity than it is.

---

## 1. Europe map & tiles

### 1.1 Tile grid

- **Tile = 50 km × 50 km.** Grid **96 × 80 tiles** (4800 × 4000 km) on a
  stylized equal-area Europe covering Lisbon–Helsinki, Ireland–Athens. One
  tile = one *site*: at most one major facility per tile (readability over
  realism), with per-technology stacking rules (§1.3).
- Godot `TileMap` with the WorldModel pattern (infrastruct ADR-002): pure Vector2i-keyed
  dictionaries as source of truth, versioned JSON envelope, views only render.
  1 tile = 1.0 world unit.
- The map is **generated from public-domain Natural Earth vector data**:
  `data/map/europe_v3.json` (§1.7), 960×804 tiles at 5 km, produced by
  `tools/map_authoring/natural_earth.py` (ledger 38). The licensing rule
  moved with the source: NE is explicitly public domain, whereas OSM is ODbL
  and a shipped tile grid IS a derived database — so do **not** import OSM
  geometry into the game map (an OSM-derived *scenario seed* for the
  starting grid remains a stretch goal; keep gridedit's AGPL *code* out
  either way). The superseded hand-authored 96×80/50 km grids are archived
  under `tools/map_authoring/archive/`.

### 1.2 Terrain kinds & resource overlays

| Code | Terrain | Gameplay meaning |
|---|---|---|
| `S` | deep sea | HVDC submarine corridors + offshore converter platforms (§1.3); no other building |
| `s` | shelf sea | **offshore wind** sites; submarine cables |
| `c` | coast | land adjacent to sea; LNG access (gas −10 %), **nuclear cooling** qualifies |
| `p` | plain | default buildable; best solar/onshore wind |
| `h` | hills | buildable; wind bonus, slight solar malus |
| `m` | mountain | **pumped hydro** sites; AC lines ×1.6/tile; no large thermal |
| `r` | river | overlay on land tiles; **nuclear cooling** qualifies; drought events derate |

Resource overlays (sparse authored tile lists): `coal_basin` (Ruhr, Lusatia,
Upper Silesia, Asturias — coal fuel −25 %), `salt_cavern` (per PARAMETERS
§1.14 siting), `phs_site` (~14 viable massifs: Alps, Pyrenees, Norway,
Scotland, Carpathians, Dinarides), `wind_resource` (0.7–1.3 scalar),
`solar_resource` (latitude-driven 0.7–1.4, Iberia/Greece high).

### 1.3 Placement rules (validated at ghost-preview time)

| Buildable | Terrain requirement | Per-tile stacking (balancing constants, `economy.md`) |
|---|---|---|
| Nuclear | land with `c` or `r` (cooling; drought derates river-cooled units to 60 %) | 2 units |
| Coal / lignite | plain/hills/coast (lignite: `coal_basin` only) | 2 units |
| CCGT / OCGT | any land | 3 units |
| Wind onshore | `p`/`h`/`c` | 3 × 200 MW farms |
| Wind offshore | `s` (far-shore: `s` adjacent to `S`) | 2 × 500 MW farms |
| Offshore converter platform | `s` or `S` | 1 per tile; binds farms within 2 tiles up to its rating (PARAMETERS §1.16) |
| Solar PV | `p`/`h` | 4 × 150 MW parks |
| Pumped hydro | `phs_site` overlay | 1 site (site GWh cap authored) |
| Battery | any land | 4 × 100 MW |
| Electrolyzer | any land (co-locate with cavern or pay an H2 pipeline stub cost) | 4 × 100 MW |
| H2 cavern | `salt_cavern` overlay | 2 caverns |
| Synchronous condenser | any land; free conversion slot on retired thermal sites | 2 |
| Substation / lines / HVDC converter | any land (`m` at ×1.6 line cost) | — |

Load centers are **pre-placed fixed footprints** (2×2 or 3×3 tiles) — never
buildable, never removable.

### 1.4 From tiles to the transmission graph

Reuse infrastruct's topology-builder pattern (RefCounted builder, shared
graph-walk machinery, debounced 2.5 s rebuild, golden-file tests pinning
output byte-for-byte):

- **Corridor tiles** carry kind `line_220`, `line_400`, or `hvdc`. The player
  drags corridors like roads.
- **A bus (substation) forms** where: (a) a corridor touches a site footprint
  (the grid connection), (b) 3+ corridor neighbors meet, (c) corridor kind
  changes, or (d) the player places an explicit substation tile. Adjacent bus
  tiles collapse to one bus.
- **Branches** are the simple corridor paths between buses. Electrical length
  `L_km = tiles × 50 × 1.12` (sinuosity). Impedance/rating from the line
  catalog (§1.5) × length; circuits are a per-corridor upgrade (1 or 2), not
  extra tiles.
- **220↔400 coupling** only at a bus with a purchased transformer bay;
  otherwise the two systems pass through the same tile unconnected (warning
  icon).
- **HVDC point-to-point** = converter-station device on a bus at each end +
  `hvdc` corridor between (may cross `S`). Modeled as a controllable
  P-injection pair (backend devices, not an AC branch); setpoint by dispatcher
  (congestion relief) or player. This is the bulk north→south transport tool —
  the SuedLink lesson: AC corridors congest first, DC bypasses.
- **Offshore wind connection — two paths** (PARAMETERS §1.8/§1.16):
  (a) **AC near-shore**: the farm's own submarine corridor to a coastal bus,
  ≤ 3 tiles (150 km), billed per-km at the §1.5 submarine rate — cheap first
  gigawatts, saturates fast; (b) **DC far-shore**: farms bind to an
  **offshore converter platform** (≤ 2 tiles away), platform → `hvdc`
  submarine corridor (any length, crosses `S`) → onshore converter station at
  a bus. The hub is one backend `offshore_hub` injection at the onshore bus;
  the offshore collector grid is aggregated, not modeled, and bound farms are
  game-side entities only. Losing the hub loses everything behind it — a
  genuine infeed loss and the player's largest self-built contingency; the
  advisor says so. (An embedded onshore link trip is NOT an infeed loss — it
  redistributes flows; PARAMETERS §1.16.)
- **Sea crossings**: AC submarine ≤ 3 tiles (150 km; the Channel, Øresund,
  and Messina grid crossings are ≤ 1 tile) at ×2.2 cost; longer sea routes
  are HVDC-only. Tooltip teaches why (cable charging current), and shows the
  ≈ 150 km AC-vs-platform breakeven sitting right at that cap.
- **Islands**: sub-graphs without any grid-forming source are dead — zones
  unsupplied (backend blackout-island state). Islands *with* sources get their
  own frequency automatically (PHYSICS §2.7) — split events are real from day
  one; deliberate multi-area operation (separate AGC areas, HVDC-coupled
  frequency) is a later phase.
- **Node budget (hard)**: ≤ **150 buses / ≤ 300 branches** at maximum
  build-out (the infrastruct-proven ≤300-node budget). The builder enforces
  it: bus-merge rules plus a palette warning at 120 buses and hard refusal at
  150 ("consolidate substations"). The base scenario is authored ≤ 60 buses.
  Offshore platforms and HVDC links are **devices, not AC buses** — they
  don't consume the budget.

### 1.5 Line catalog (`data/catalogs/line_types.json`)

| Type | Rating/circuit | r' Ω/km | x' Ω/km | c' nF/km | Cost | Build |
|---|---|---|---|---|---|---|
| 220 kV AC | 400 MVA | 0.06 | 0.32 | 11 | 0.5 M€/km (+80 % 2nd circuit) | 8 d/tile, min 100 d |
| 400 kV AC | 1500 MVA | 0.02 | 0.25 | 14 | 1.1 M€/km (+80 % 2nd circuit) | 10 d/tile, min 120 d |
| AC submarine | as 220/400 | ×1.0 | ×0.6 | ×8 | ×2.2 | ×1.5 |
| HVDC VSC bipole (overland) | 2000 MW | loss 0.30 %/100 km + 1 %/station | — | — | 1.4 M€/km overhead (underground ×4) + converter stations (PARAMETERS §1.16) | 15 d/tile + 300 d converters |
| HVDC submarine export cable | 2000 MW | loss 0.30 %/100 km | — | — | 2.0 M€/km | 15 d/tile |
| Offshore converter platform | 1000 / 2000 MW | 1 %/station | — | — | 450 / 800 M€ | 42 months |

Mountain tiles ×1.6 on AC cost. Loading thresholds inherit the family enum
(>100 % warning, >120 % critical); sustained-overload trips per PHYSICS §2.7.

### 1.6 Substations & transformers

| Item | Cost | Notes |
|---|---|---|
| Substation (bus), 220 kV | 15 M€ | auto-created buses bill on first commit |
| Substation, 400 kV | 40 M€ | |
| Transformer bay 400/220, 700 MVA | 25 M€ | ≤ 3 per bus; loading reported like lines |
| Connection bay (plant / load-center feeder) | 5 M€ | auto-billed when a corridor touches a footprint |

### 1.7 Map authoring format (`data/map/europe_v3.json`)

```json
{
  "version": 1, "tile_km": 5, "width": 960, "height": 804,
  "terrain_rows": ["SSSSssccpp...", "..."],
  "resources": [
    {"kind": "coal_basin", "tiles": [[41,33],[42,33]]},
    {"kind": "salt_cavern", "tiles": [[44,28],[45,28]]},
    {"kind": "phs_site", "tiles": [[52,44]], "max_gwh": 40},
    {"kind": "wind_resource", "tiles": [[30,20]], "factor": 1.25},
    {"kind": "solar_resource", "band_lat": [36,44], "factor": 1.3}
  ],
  "load_centers": [
    {"id": "london", "name": "London & South-East", "tiles": [[30,26],[31,26],[30,27],[31,27]],
     "peak_mw_2025": 15000, "season": "winter", "temp_coeff_pct_per_c": 1.8}
  ]
}
```

---

## 2. Load centers

### 2.1 The 25 demand regions

Stylized "major load centers of Europe": aggregate non-coincident peak ≈
**148 GW**, coincident winter system peak ≈ **132 GW** (coincidence 0.89) —
deliberately ~¼ of real Europe; honest framing: "you serve the metropolitan
backbone".

| id | Region | Peak 2025 (GW) | Season class |
|---|---|---|---|
| london | London & South-East England | 15 | winter |
| paris | Île-de-France | 12 | winter (2.4 %/°C) |
| ruhr | Rhine-Ruhr | 11 | flat/industrial |
| milan | Po Valley (Milan–Turin) | 9 | summer |
| rome | Rome–Naples | 7 | summer |
| madrid | Madrid | 6 | summer |
| barcelona | Catalonia–Valencia | 6 | summer |
| silesia | Upper Silesia | 6 | flat/industrial |
| munich | Bavaria | 6 | winter |
| randstad | Randstad (NL) | 6 | winter |
| brussels | Brussels–Antwerp | 5 | winter |
| frankfurt | Rhine-Main | 5 | flat |
| stuttgart | Baden-Württemberg | 5 | flat/industrial |
| warsaw | Warsaw–Łódź | 5 | winter |
| lyon | Rhône-Alpes | 5 | winter |
| berlin | Berlin | 4 | winter |
| hamburg | Hamburg | 4 | winter |
| prague | Bohemia | 4 | winter |
| vienna | Vienna | 4 | winter |
| zurich | Swiss Plateau | 4 | winter |
| copenhagen | Øresund (CPH–Malmö) | 4 | winter |
| stockholm | Mälardalen | 4 | winter |
| athens | Attica | 4 | summer |
| lisbon | Lisbon–Porto | 4 | flat |
| oslo | Oslo–Viken | 3 | winter |

### 2.2 Demand model (game-side; the backend receives the summed zone value)

`P_z(t) = P̂_z · G(y) · S_z(m) · D_class(τ, dow) · W_z(T)`

- **G(y)** growth: +1.5 %/yr 2025–2030, +2.5 %/yr 2030–2040 (EVs + heat
  pumps; heat-pump share also raises winter temp sensitivity +0.5 %/°C per
  era). Campaign scripts may add zone step growth (new-industry event).
- **S_z(m)** seasonal by class (monthly): winter class 1.00 Dec/Jan, 0.74 Jul;
  summer class 1.00 Jul/Aug, 0.82 Jan; flat 0.95 ± 0.04.
- **D_class(τ, dow)** daily shape, 96 anchors; workday-winter anchors:
  00:00 .70, 03:00 .62, 06:00 .68, 07:30 .84, 09:00 .95, 12:00 .97, 14:00 .93,
  17:00 .97, **18:30 1.00**, 21:00 .88, 23:00 .76. Summer-south variant peaks
  14:00 (A/C). Weekend ×0.86 on the shaped part; industrial zones 60 % base +
  40 % shape.
- **W_z(T)**: +`temp_coeff` %/°C below 10 °C (winter class) or above 24 °C
  (summer class); temperature from the weather model (PARAMETERS §3.5) with
  `force_*` override windows as the test hook.
- Small band-limited noise (±1.5 %) on every zone every step so the frequency
  needle *breathes* (see §4.2 — the wobble is real physics through the swing
  model).

Authored as `data/profiles/demand_classes.json` (per-class 96-step shapes +
monthly factors), five-file-contract style with cross-validation.

### 2.3 Unserved energy: consequences ladder

The backend reports `zones{supplied 0..1}` + UFLS shed fractions; the game
layers consequences (never fakes them):

1. **Reserve scarcity** (no shed): scarcity adder on the wholesale ticker;
   advisor warning. No penalty.
2. **UFLS shed** (automatic, frequency events): shed MWh billed at **VoLL
   3000 €/MWh**; +1 reliability strike; event-log entry with replay.
3. **Brownout / rolling shed** (dispatch infeasible: supply or congestion):
   dispatcher sheds cheapest-to-shed zones (industrial first — teaches
   interruptible load); VoLL billing; SAIDI minutes accrue.
4. **Zone blackout** (zone dark ≥ 1 h, e.g. islanded without source): fine
   50 M€ + VoLL + demand growth frozen 1 year in that zone + reputation hit.
5. **Area blackout** (frequency collapse): screen goes dark, scripted 12 h
   (game) restoration with staged reconnection, 500 M€ + campaign strike
   (3 strikes in 12 months = dismissed).

**SAIDI-like index**: `SAIDI_z = Σ_steps (1 − supplied_z) × step_min`,
load-weighted system value, yearly. Stars: ★★★ < 15 min, ★★ < 60, ★ < 240.

---

## 3. Game loop & time

### 3.1 Time structure

- **Stepping (wire)**: the game steps the backend at ~10 Hz wall with
  `dt_s = 0.1 × speed` (PHYSICS §1.1) — variable-size steps, early return on
  events. One-step lag, at most one in-flight step, skip-never-stall
  (Orchestrator ported near-verbatim). The dial animates from the previous
  step's trajectory buffer at 60 fps.
- **Economy cadence**: dispatch, billing, and profiles operate on **15-min
  sim-time boundaries** (96/day) regardless of wire slicing — the dispatcher
  recomputes whenever sim time crosses a boundary. Construction progresses in
  months.
- **Speeds**: pause / 1× / 4× / 16× / 60× / fast-forward (requested up to
  9000×; `dt_s` caps at 900 s and sustained realized speed follows the
  PHYSICS §3 budget (~900–3600×), the shortfall absorbed by skip-never-stall).
  **Auto-slow to 1× on any significant frequency event** (triggered by the
  backend's early return), 3-step cooldown before re-accelerating.
- **Calendar compression — representative days**: a campaign year = **12 epoch
  days**, one per month, each a fully simulated 96-step day drawn from that
  month's climatology (seeded). Monthly accounting scales by real
  days-in-month: energy, fuel, revenue, and **seasonal H2 storage** carry-over
  use `ΔE_month = net_daily_flow × days_in_month` (clamped to capacity; the H2
  panel shows the projected cavern trajectory). **Episodes**: the weather
  system or campaign script can expand a month into N consecutive days (storm
  week, 5-day Dunkelflaute, heat wave); accounting scales by
  `days_in_month / N`. Multi-day continuity exists when it matters, without
  playing 365 days/year.
- **Wall pacing**: one epoch day ≈ 3–4 min at cruise speed; a 15-year campaign
  ≈ 180 played days ≈ 6–9 wall hours at mixed speeds.

### 3.2 The two layers the player lives in

- **Energy/economy layer** (steps/days): merit-order dispatch, prices, fuel
  and CO2 bills, construction, H2 chain, KPI trends. Calm, plannable.
- **Live dynamics layer** (seconds, event-driven): frequency dial, RoCoF,
  reserve deployment, trips, replay panel. Tense, reactive. The game's
  identity is the interplay: decisions in layer 1 change what layer 2 feels
  like.

### 3.3 Dispatch: automatic merit order with player strategy

Every 15-min boundary, the game-side dispatcher (pure GDScript model class):

1. **Forecast** next 24 h net load per zone (persistence + weather forecast
   with authored error → forecast-bust events).
2. **Commit** (heuristic, no MILP): sort thermal by marginal cost; commit
   until forecast peak + reserve margin (max(largest online infeed — largest
   unit or offshore-hub delivery; embedded links don't count, they
   redistribute — and 3 GW));
   respect min up/down and start costs with a "worth starting if expected run
   ≥ break-even hours" rule.
3. **Dispatch** committed plants by merit order for load + losses; renewables
   first (MC 0); storage by policy; electrolyzers absorb when price < player
   threshold.
4. **Reserve procurement**: FCR sized to the reference incident (largest
   single online infeed), aFRR = 1.5 % of load; allocated to capable, flagged
   units; reserved headroom withheld from energy dispatch.
5. **Feasibility**: setpoints go to the backend; the AC solve is truth. On
   branch overload > 100 %: **redispatch heuristic** (raise cheapest unit on
   the import side, lower on the export side; cost booked as redispatch —
   teaches congestion); then curtailment; then shed (§2.3 ladder).

**Player controls (strategy, not knobs)**: per-plant mode
`auto | must-run | reserve-only | mothballed | manual` (manual pins a setpoint
and leaves merit order); battery policy slider `arbitrage ↔ reserve/FFR`;
electrolyzer price threshold; FCR/aFRR procurement margins; HVDC mode
`auto (congestion relief) | manual`; nuclear primary-response enable
(PARAMETERS §1.1). Every override possible, none required per-step.

### 3.4 Money (single company: "GridCo Europa" — owner *and* operator)

- **Revenue = regulated tariff × DELIVERED MWh** (family principle: billing on
  delivered energy makes blackouts cost revenue). Tariff per era: 95 €/MWh
  (2025) → 100 → 105, script-set.
- **Reserve remuneration**: regulator pays 8 €/MW/h procured FCR, 4 for aFRR —
  holding reserve is a real economic decision.
- **Costs**: fuel + CO2 (PARAMETERS §4) + fixed O&M + start costs + redispatch
  + VoLL penalties + capex (upfront; loan line at 4 %/yr up to 2× yearly
  revenue).
- **Wholesale shadow price** (marginal unit's MC + scarcity adder, cap
  4000 €/MWh) is displayed and drives battery/electrolyzer policy — a
  *teaching KPI*, not the revenue source (dodges the monopolist-price
  circularity while keeping merit-order literacy front and center).
- `tools/balancing/economy.md`: constants table with per-constant rationale,
  measured windows regenerated by `--smoke=economy`, rule "change a constant →
  rerun the smoke → commit both".

---

## 4. Teaching frequency dynamics (the core)

### 4.1 What the player experiences

All frequency physics is computed backend-side (PHYSICS §2); the game renders
the returned trajectory buffers and events. Normal operation shows a live
needle with a real stochastic wobble (zone noise through the swing equation —
a low-inertia grid *visibly and audibly* jitters more). Events arrive with
exact-timestamped trajectories; **counterfactual replays** call the backend's
`/gb/replay` (re-run of the event window with overrides — same engine, physics
implemented once).

### 4.2 The frequency instrument cluster (always-on HUD, top center)

1. **Frequency dial** — analog 50 Hz needle. Bands: green ±100 mHz, amber to
   ±200 mHz (FCR fully deployed at the edge), orange to 49.2, red below 49.0
   (UFLS territory), black mark 47.5 (collapse). Digital readout below.
2. **RoCoF readout** — Hz/s, peak-hold during events.
3. **Inertia gauge** — `H_sys` [s] *and* kinetic energy [GWs], stacked bar per
   contributing class (nuclear/coal/gas/hydro/syncon/grid-forming-virtual —
   the virtual segment visually hatched). Bands: >5 s comfortable, 3–5 s
   caution, <3 s alarm, <2 s critical.
4. **Reserve stack** — FCR / aFRR / battery-FFR: procured vs deployed MW,
   live bars.
5. **The hum** — a 50 Hz audio tone whose pitch follows f and whose flutter
   follows the wobble. The player *hears* inertia leaving the system before
   any event happens — the cheapest, strongest teaching device in the game.

### 4.3 Buildable classes: game-side identity

Dynamics + economics per class: **PARAMETERS §1 (authoritative)**. Game-side
attributes:

| Class | Buildable unit | Unlock (era) | Game notes |
|---|---|---|---|
| Nuclear | 1600 MW | start | must-run identity; primary response off by default; xenon lockout after scram |
| Coal / lignite | 800 / 900 MW | start (no new-build after 2030) | retirement deadlines drive the campaign |
| CCGT / OCGT | 600 / 200 MW | start | the dispatchable backbone; H2-retrofittable from 2033 |
| Pumped hydro | 300 MW site blocks | start | `phs_site` only; the inverse-response lesson |
| Wind onshore / offshore (AC near-shore) | 200 / 500 MW farms | start | zero inertia; storm-front cliffs |
| Solar PV | 150 MW parks | start | zero inertia; midday displacement of synchronous units |
| Battery (GFL) | 100 MW | **2027** | FFR product; arrests nadir, not RoCoF |
| HVDC + offshore platforms | 2000 MW bipole / 1–2 GW hubs | **2028** | congestion bypass + far-shore North Sea wind; the hub becomes the player's biggest self-made contingency |
| Electrolyzer + cavern | 100 MW / cavern | **2029** | H2 chain start; interruptible load |
| Grid-forming firmware | upgrade | **2031** | virtual inertia — the RoCoF fix |
| Syncon conversion | retired thermal sites | **2031** | "keep the mass, drop the boiler" |
| H2-fired turbines | retrofit | **2033** | seasonal storage closes the loop |
| Wind synthetic inertia | firmware flag | **2035** | one-shot boost + recovery dip (shown in replays) |

The unlock path *is* the campaign arc: each tool arrives roughly when the
problem it solves starts hurting.

### 4.4 Event system

Seeded, deterministic per save (smoke-testable). Rates at difficulty
*normal*, per game-year:

| Event | Rate | Mechanics |
|---|---|---|
| Unit trip | ~12/yr, MTBF-weighted by class (thermal higher when old) | scheduled into the engine (`scheduled_events`); the classic teaching event |
| Line/trafo trip | ~8/yr, storm-correlated | branch out → PF redistribution; possible cascade if neighbors sit > 100 % |
| Forecast bust (wind/load) | ~20/yr | ramp imbalance over 1–4 steps; stresses aFRR, not FCR |
| Dunkelflaute | 1–2/winter, endogenous (PARAMETERS §3.4) + scripted campaign instances | multi-day episode; storage + thermal adequacy test |
| Cold snap / heat wave | 1/yr each | demand surge; river-cooled nuclear derate in heat waves |
| HVDC link / offshore-hub loss | when built, ~1/yr per link, storm-correlated for hubs | **hub** loss = infeed ΔP step sized by its delivery (FCR reference incident: largest unit **or** largest hub delivery); **embedded link** loss = instant flow redistribution → overload/cascade risk + redispatch, near-zero Δf (PARAMETERS §1.16). The player *created* both contingencies; the advisor points them out |
| UFLS / cascades (consequence, not event) | — | per PARAMETERS §2.2 defense plan; < 47.5 Hz = area collapse |

On any significant frequency event: backend early-returns, time auto-slows to
1×, the dial animates the trace, the hum bends, the event log pins an entry
with a **Replay** button.

### 4.5 The replay panel — "What just happened"

Modal graph of the event's f(t) trace (from `/gb/telemetry/ring`), annotated
in stages — each stage a tappable chip that highlights its region and shows
its formula with *this event's numbers*:

1. **t0 — the event.** "Lost 1.6 GW (Fessenheim B)."
2. **Inertial phase (0–2 s).** Tangent line with the formula filled in:
   `RoCoF = ΔP·f0 / (2·E_k) = 1.6 GW × 50 / (2 × 160 GWs) = 0.25 Hz/s`, and
   the inertia gauge state at t0.
3. **FCR deployment (2–30 s).** Shaded area per responder class — the player
   *sees* OCGT rise fast, coal's reheat lag, hydro's wrong-way kick, the
   battery FFR slab appearing near-vertically at t+0.3 s.
4. **Nadir.** Marker with value and margin to the next UFLS stage.
5. **Quasi-steady settle.** `Δf_ss` from droop + damping.
6. **Restoration (minutes).** aFRR ramps, f returns to 50.00, FCR released.

**Counterfactual toggles** (the killer feature): re-run the same event *"with
yesterday's fleet"*, *"without battery FFR"*, *"+2 GWs grid-forming"* via
`/gb/replay` — ghost traces overlay the real one. Nothing teaches "inertia
matters" faster than the same trip with and without it. Live counterfactuals
are possible only while the event window is still in the backend's rolling
snapshot ring (~2 min); the game therefore **fetches its standard
counterfactual set right after each significant event and caches the ghost
traces with the event-log entry** — the campaign-long log (ring of last 50)
replays cached traces, no re-simulation needed.

### 4.6 Adequacy advisor (forward-looking warnings)

Once per game-hour the game projects, from the commitment schedule:
`H_sys(t+1..24 h)`, largest single infeed, procured FCR. Warnings fire as
event-log entries + map toasts:

- *"Sunday 13:00: solar displaces thermal — H_sys falls to 2.1 s. A 1.6 GW
  trip would hit RoCoF 0.6 Hz/s and a nadir below 49.0 (UFLS). Options:
  must-run one CCGT (≈ 0.4 M€), switch 1 GW battery to grid-forming, start
  the Lyon syncon."*
- N-1 check: reference incident > FCR+FFR capability → "under-secured" banner
  on the reserve stack.

The advisor never acts by itself (the player is the operator).

### 4.7 Scoring

Three axes, yearly and per-milestone:

- **Reliability**: SAIDI minutes, UFLS activations, blackouts, minutes outside
  ±100 mHz.
- **Cost**: average system cost €/MWh delivered = (fuel + CO2 + O&M +
  annualized capex + penalties) / delivered MWh.
- **Clean**: gCO2/kWh yearly average.

Stars per axis per milestone (thresholds authored in the campaign script);
campaign rank = total stars; all three as dials with 12-month sparklines.

---

## 5. Campaign & scenarios

### 5.1 Premise

2025. GridCo Europa inherits the continent's backbone: coal-heavy
Poland/Germany, nuclear France, gas UK/Italy/Netherlands, a modest renewable
fleet, an aging 220/400 kV grid with known bottlenecks. The regulator's
decarbonization law ratchets the CO2 price (30 → 60 → 100 → 160 → 250 €/t by
era) and sets **coal retirement deadlines** (all coal offline by 2035, hard).
Demand grows and electrifies. **Win condition: decarbonize without degrading
frequency stability.**

### 5.2 Milestones (gate-style acceptance criteria, family phase-gate style)

1. **Take the Reins (2025).** Tutorial: operate the inherited fleet 2 months;
   survive the scripted 1.2 GW trip; open the replay panel and identify RoCoF
   and nadir (UI-guided). *Pass: no UFLS, replay viewed.*
2. **The Merit Order (2026).** CO2 jumps to 60 €/t mid-year — coal and gas
   swap places in the stack. Keep average cost < 90 €/MWh for 6 months at
   ★★+ reliability. *Teaches: dispatch economics, fuel switch.*
3. **First Green Gigawatts (2027–28).** Build ≥ 20 GW wind+solar and the
   corridors to move it (scripted congestion on the North Sea → Ruhr axis —
   the near-shore AC connections saturate; the mid-milestone HVDC + platform
   unlock lets you commit far-shore hubs and DC bypass corridors, which
   deliver in the early 2030s — commit now or congest later). First midday
   low-inertia advisor warnings. *Pass: RE ≥ 20 GW, ≥ 4 GW hub-connected
   offshore committed/under construction, redispatch < 200 M€/yr (AC second
   circuits + discipline), zero UFLS.*
4. **The Dunkelflaute (2029).** Scripted 5-day calm-cold episode over NW
   Europe; survive on storage + thermal + new batteries. *Pass: SAIDI < 30 min
   across the episode.* Battery + electrolyzer unlocks land just before.
5. **Coal Exit (2031–35).** Retire all coal by deadline at ★★ yearly
   reliability. Syncon conversion unlock: the retiring plants are your inertia
   farm, if you choose. *Pass: 0 MW coal by Jan 2035, ≤ 2 UFLS events in the
   final year.*
6. **The Hydrogen Loop (2033–36).** ≥ 5 GW electrolysis + ≥ 400 GWh cavern
   storage + ≥ 4 GW gas converted to H2. Survive Dunkelflaute II burning only
   H2 and residual gas. *Teaches: seasonal storage economics, the ≈ 35 %
   round trip.*
7. **The Inverter Grid (2037–40, finale).** Run a full year at ≥ 70 %
   inverter-based energy share, ★★★ reliability, < 50 gCO2/kWh. Final exam: a
   scripted **double contingency** (largest offshore hub + largest unit
   within 10 s — both genuine infeed losses), survivable only with a properly
   sized grid-forming + FFR + syncon portfolio. The passed replay is the
   campaign's closing screen.

### 5.3 Failure states

- **Insolvency**: treasury < −2 B€ for 90 days (a loan line exists — use it).
- **Dismissed**: 3 area blackouts within 12 months, or > 12 UFLS events in a
  year.
- **Missed hard deadline**: coal past 2035 → forced shutdown + 100 M€/month
  fines (painful, not instant fail); milestone failed, retry from autosave.

### 5.4 Sandbox

Free build on the same map: all unlocks open, treasury slider, event-rate
sliders (including a "trip largest unit NOW" button — the sandbox is the
classroom demo mode), weather `force_*` overrides exposed, scenario
save/load as recipe-not-snapshot. Sandbox is also where smokes run.

---

## 6. UI panels (Godot 4; infrastruct's proven HUD grammar)

| Panel | Scene | Contents |
|---|---|---|
| **Map view** | `game/views/europe_map.tscn` | tilemap + toggles: terrain, grid (color by voltage), **flow animation** (dashes along branches, speed ∝ P), **loading heat**, N-1 overlay (post-contingency loadings, hourly), build ghosts with validity highlight; pan/zoom, flyTo on event click |
| **Build palette** | `game/ui/build_palette.tscn` | bottom HUD, categories Generation/Storage/Grid/Hydrogen; per-item cost, build time, terrain tooltip; corridor drag tool with live km + cost readout |
| **Inspector / plant detail** | `game/ui/inspector.tscn` | live P, Q, setpoint (slider in `manual`), state chip (offline/starting/online/tripped/retiring), fuel or SoC bar, **f-response card** (H, droop, reserve held, last-event contribution), economics tab, mode selector, retire/mothball/convert-to-syncon |
| **Merit order / market** | `game/ui/merit_panel.tscn` | capacity stack sorted by MC with clearing point, wholesale ticker, 24 h price + net-load forecast strip, redispatch cost meter |
| **Frequency cluster** | `game/ui/frequency_cluster.tscn` | §4.2, always-on; click-through to replay panel |
| **Replay panel** | `game/ui/replay_panel.tscn` | §4.5: annotated trace, stage chips, counterfactual toggles, export-to-PNG (teachers will want it) |
| **H2 chain view** | `game/ui/h2_panel.tscn` | left-to-right Sankey: electrolyzers → cavern level (with monthly projection line) → H2 plants; avg stored-H2 cost; threshold slider |
| **KPI dashboard** | `game/ui/kpi_panel.tscn` | 3 score dials + sparklines, SAIDI per zone, CO2 trend vs deadline, treasury |
| **Event log** | `game/ui/event_log.tscn` | filterable; click → flyTo + replay; advisor entries carry their options as action buttons |

Plumbing: infrastruct autoload split verbatim in shape — `GameClock`,
`SidecarManager`, `CosimBridge` (v2 handshake), `Orchestrator`
(near-verbatim), `GridCo` (game brain / BoundaryProvider: `get_zone_demand`,
`get_device_commands`, `get_avail_mw`), `SaveGame` (versioned envelope; SoC +
cavern + treasury replay). Smokes on SmokeBase, one JSON verdict line,
`--smoke=<name>` headless; goldens pin the topology builder. Static typing
mandatory in `model/`.

---

## 7. What NOT to simulate (scope guards — hold the line)

| Not simulated | Instead |
|---|---|
| EMT, per-machine rotor angles, oscillation modes, transient stability | per-island COI swing + per-class governor models; honesty note in-game |
| Deliberate multi-area operation (GB/Nordic separate f, HVDC-coupled areas) | v1: one synchronous area in normal operation; *emergent* islands from line trips are real (PHYSICS §2.7); planned multi-area = later phase |
| Distribution grids, per-household demand | 25 aggregated zones, authored profiles (the sibling games already do distribution) |
| Unit-commitment MILP / OPF | heuristic commitment + merit order + redispatch heuristic; the AC solve is the feasibility truth |
| Intra-plant thermodynamics | per-class governor/turbine blocks + ramp/min-load/start-time constraints only |
| Gas network hydraulics | fuel is bookkeeping; the H2 cavern is a tank model with ×days-in-month scaling |
| Offshore AC collector-grid electrical detail, multi-terminal DC grids | the hub aggregates bound farms into one onshore injection; multi-terminal "energy island" hubs are a post-v1 stretch |
| Voltage collapse dynamics, relay detail | threshold violations (family enum) + overload-duty trips |
| Market agents / competitors / bidding AI | single company, regulated tariff; wholesale price is a computed teaching signal |
| Real NWP weather | seeded stochastic model (PARAMETERS §3) + `force_*` windows |
| Black-start / island EMS gameplay | v1: scripted restoration sequence; grid-forming island survival gameplay = later phase |
| > 150 buses | hard builder cap; Europe stays coarse by design |

---

## 8. Data authoring deliverables

1. `data/map/europe_v3.json` — §1.7, via `tools/map_authoring/natural_earth.py`
   (v1/v2 predecessors archived in `tools/map_authoring/archive/`).
2. `data/load_centers/centers_v1.json` — §2.1 + footprints + temp
   coefficients.
3. `data/profiles/demand_classes.json` — §2.2 shapes + monthly factors.
4. `data/catalogs/plant_types.json`, `line_types.json`, `storage_types.json`,
   `economy.json` — from PARAMETERS (with rationale strings).
5. `data/campaign/campaign_v1.json` — eras, CO2 ratchet, unlock years,
   milestone scripts (scripted events + `force_*` windows), star thresholds,
   failure limits.
6. `tools/balancing/economy.md` — constants + rationale + regenerating smoke.

Performance guardrails (bind the implementation): ≤ 150 buses / 300 branches;
PHYSICS §3 budget table; one-step lag, skip-never-stall; trajectory ≤ 512
samples per frame.
