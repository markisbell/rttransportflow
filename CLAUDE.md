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

**P0–P10 complete; refactoring campaign landed (2026-08-20);
strategic-zoom arc merged (2026-08-22)** — the real-grid look, the
freeze campaign and the site-note weekly graphs; see the last §6 entry.
Ten commits on `refactor/campaign` restructured tests, smokes, constants,
the API seam, the simulator file, and the game model layer with every
behavior pin held; ledger 45 records the one deliberate re-baseline (map
projection) and its open balancing item. Previously: The backend, the
contract, the game, the 5 km Europe map, the economy and the protection layer
are in and their gates are green; P9's determinism gate (`save_load_replay`)
passes and the campaign gate is the open item; P10 has export presets, a
packaging script that plays the bundle it builds, and the release checklist
in §8. Per-phase evidence is in §6 — read the last entry before touching
anything.

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
  ledger 25; 5176/8083 reserved-unused); game 8030 / acceptance smokes 8031
  (sequential by design) / contract tests 8032 / freeze smoke 8033 /
  backend-driving smokes 8034–8043, ONE port per smoke — the registry is
  `SMOKE_PORTS` in `game/main.gd` (kept off 8031 so smoke runs can overlap;
  four smokes silently sharing 8034 was the adopt-a-stale-backend failure).
  NEVER 8000–8002 (user dev instances), 8010–8016
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

38. **Map resolution and geometry source** (user direction, 2026-08-14):
    the map is **960 × 804 tiles at 5 km** (771 840 tiles — 100× the
    original 96 × 80 at 50 km). Two rounds of "bigger": at 50 km a country
    was a handful of tiles, so nations had no shape and mountains/forests
    had nowhere to live. Geometry now comes from **Natural Earth**
    (`tools/map_authoring/natural_earth.py`), NOT OpenStreetMap: NE vector
    data is explicitly public domain, whereas OSM is ODbL and the shipped
    tile grid IS a derived database, which would attach share-alike. NE at
    1:10 m resolves finer than a 5 km tile, so it is sufficient as well as
    cleaner. Real coastlines + lakes, the 222 named `Range/mtn` polygons
    (61 155 mountain / 150 050 hill tiles) and 55 real river courses.
    Consequences made binding:
    - **rasterise, never point-test**: per-tile point-in-polygon over
      Eurasia's ~10 k-vertex ring is hours; the scanline even-odd fill is
      3.4 s.
    - **terrain lives in packed rows**, not a Vector2i Dictionary — 772 k
      keys cost tens of MB; read via `terrain_at()` / `in_bounds()`.
    - **every radius is a DISTANCE, not a tile count** (`tiles_for_km`):
      metro footprints 60/45 km, PHS snap 40 km, load-centre search 150 km,
      foothill halo 50 km, forest noise span 250 km, smoke build rings
      200 km. Tile-count constants silently shrink by the resolution factor.
      This has now bitten **five** times, and the fifth was the worst kind:
      `HUB_BIND_TILES = 2` was not a rendering radius but a *game rule* —
      PARAMETERS §1.16's 100 km offshore collector reach — so at 5 km no
      far-shore farm could reach a platform and the whole DC path silently
      stopped existing. It is now `HUB_BIND_KM`. **A tile count in a rule is
      a bug**: write kilometres, convert at the edge.
    - a metro footprint may span water and keeps only its land tiles (a
      solid-land square left Rome with nowhere to stand).
    - the renderer MUST stream: the whole map cannot be resident (chunked
      terrain/decoration/models around the camera + a coarse overview mesh),
      and a navigation panel (minimap + jump list) replaces panning.
39. **Schedules RAMP across the block boundary** (2026-08-14): the dispatcher
    still decides once per 15-min block, but `Boundary.device_commands()`
    now blends the previous schedule into the new one over
    `Dispatch.RAMP_S = 300 s` instead of stepping the whole fleet at once.
    A step change is a synchronous multi-GW jolt that no real system ever
    applies: frequency wandered ±300 mHz in CALM with the grid otherwise
    healthy, and the resulting ALERT episodes both hid real events and cost
    compute. With ramping the same day holds 50.004–50.027 Hz. This is the
    *game* smoothing its own schedule, not the engine hiding a transient —
    trips and outages are still instantaneous, which is the point.
40. **A schedule is a budget, not a set of floors** (2026-08-14): the
    dispatcher allocates the residual ONCE — locality places what it can,
    the merit order places the rest, and a unit's schedule is the SUM of the
    two passes. `sum(dispatch) == residual` is the invariant. Taking
    `max(local_floor, merit_share)` per unit reads as conservative and is
    the opposite: summed over the fleet it exceeds either plan, and the
    campaign island (must-run nuclear, which does not regulate — ledger 9)
    had NO aFRR down-headroom to absorb it, so frequency parked at +60 mHz
    and climbed past +260 mHz, pinning the engine in ALERT on a grid where
    nothing was happening. Diagnostic that found it: `afrr_used_mw ≈ 0`
    while `fcr_used_mw` sat at a few hundred MW — primary control silently
    holding a steady-state error that secondary control should have erased.
    Post-fix the same world holds 50.000 Hz (f ∈ [49.986, 50.006]) in CALM.
41. **The inherited world is CONTINENTAL** (P9, 2026-08-14): `author_start`
    builds the 16 mainland metros (~95 GW peak, 142 plants, 64 buses / 120
    branches — inside the ledger-13 budget), not the 3-city demo cluster.
    This is physics, not scenery: a 12 GW island holds ~500 MW of FCR (bands
    are per-kind fractions of P_n and nuclear does not participate by
    default, ledger 9), so GAME_DESIGN §5.2.1's scripted 1.2 GW trip drove
    it through 49.0 Hz into UFLS — measured nadir **48.97 Hz**. The tutorial
    was teaching "your grid dies when a unit trips". On the mainland the
    same incident is the 1.3 % event it is meant to be. Islanded centres
    (london, stockholm, oslo, athens, lisbon, Iberia) join later via the
    links the player unlocks.
42. **Circuits are sized per branch, not per map** (P9, 2026-08-14):
    `GridTopology` sizes each branch from the power it must actually move.
    A branch whose removal splits the network is a bridge, and power balance
    pins its flow — everything behind it that is generated and not consumed
    has to cross — so it gets `ceil(min(max(gen, load) per side) / 562 MVA)`
    circuits, clamped to [4, 12]; meshed branches share their flow with the
    parallel path and keep 4. A flat 4 circuits (~2.5 GVA) cannot evacuate a
    5 GW plant cluster: the continental build tripped five spurs at
    157–211 % **within 10 ms of registering** and fell into eight islands
    before the player touched anything. Sizing from bus-local capacity
    instead is the obvious first attempt and does nothing — every spur runs
    plant→junction→…→metro and a junction has no capacity of its own, so the
    `min()` is zero exactly where the overload is.
43. **Silence is not zero** (P9, 2026-08-14): the engine holds the last
    setpoint it was given, so a plant the dispatcher does not commit keeps
    generating at whatever it was last told — for the inherited world, the
    bundle's startup profile. 40 of 142 plants uncommitted left ~5 GW of
    unasked-for generation in the island, parked frequency at +0.24 Hz and
    pinned the engine in ALERT (10 ms ticks) so hard that 194 wire steps
    advanced the sim clock by 0.05 days. Every uncommitted unit is now
    explicitly commanded to 0 MW; the breaker only opens on a real surplus
    (cycling it every block wears the plant). The 3-city world committed
    everything, which is why this hid until the fleet grew.

44. **The dispatcher's ledger is MEASURED, not commanded** (P9/P10,
    2026-08-14): every engine-side power the zone ledger cannot see must be
    folded back in from the last RESULT, never from the command that asked
    for it. Two instances, found within an hour of each other:
    - **Flexibility load**: a battery told to charge 250 MW draws nothing
      once it is full, and an electrolyzer that shed itself on low frequency
      draws nothing either — but `_flex_load_mw` carried the command, so the
      dispatcher generated for load that did not exist AND under-curtailed
      the wind that then had nowhere to go. The calm_week island sat at
      **50.72 Hz** with FCR absorbing 1.5 GW; measured, it sits at 50.000 Hz
      with FCR 0.
    - **HVDC terminals** (found by the smoke-repair fork): neither end was
      in the ledger at all, so an active bipole was ADDITIVE instead of a
      substitution — the exporting metro's coal still covered the importing
      metro's whole demand. An 800 MW link added ~1.1 GW of surplus
      (+0.29 Hz) and relieved 72 MW of the AC transit it exists to unload.
      Terminals now net against their home metro (devices get a home zone
      too, not just plants), using measured power so the DC path losses are
      counted by the engine exactly once.
    On the wire any negative injection is load, which covers both device
    kinds without a sign special case.

45. **The map's projection block is the ONE tile→lat/lon truth** (refactor
    campaign re-baseline, 2026-08-20): Demand kept the europe_v1 projection
    as its live default and nothing ever assigned the v3 block, so on the
    10×-finer grid every zone's weather region resolved from garbage
    coordinates — deterministic, green, and wrong (Dispatch used the live
    projection, so demand-side and availability-side regions disagreed).
    The sixth ledger-38 instance, as a stale default rather than a tile
    count. BuildSession.load_map now assigns the map's block; the literal
    remains only as the documented fixture fallback. The corrected (colder)
    regions raise heating demand: night price 7.7 → 53.8 €/MWh (gas now
    commits at night), delivered energy +14 %, CO2 124 → 163 g/kWh —
    economy_windows.csv regenerated; dispatch_day/economy/calm_week hold on
    their windowed assertions; the campaign's scripted trip lands at nadir
    49.92 and milestone 1 stays ★★★. Two consequences worth their own
    lines: (a) the campaign smoke now loops on SIM TIME (its fixed
    194-iteration cap carried ~2 blocks of margin; every significant event
    early-returns and eats block time, and the corrected demand's extra
    shed events consumed the margin, so the day-2.0 milestone evaluation
    never ran); (b) OPEN ITEM for balancing: under true demand the
    inherited world's evening peak duty-trips two meshed continental
    trunks at day 1.34 (L116/L108 at ~121 %) — a generation pocket
    (nuclear_116/117) islands and blacks out before the graded window.
    Those branches are meshed/generation-bound, so a load-side sizing
    margin measurably changes nothing (tried, loadings byte-identical,
    reverted); the honest fixes are authored corridor upgrades on that
    pocket or a meshed-trunk flow estimator (a modeling project, not a
    margin). The campaign rubric is untouched (pre-window, ungraded), but
    the player now inherits a world with a real day-2 incident — arguably
    a teaching moment, explicitly an owner decision.

46. **The campaign world is the EUROPEAN PLAN + shunt compensation**
    (owner-directed re-baseline, 2026-08-21): `GridPlan.author_start`
    replaces the demo-chain author — the inherited world is now the curated
    realistic seed (`data/grids/europe_380kv_seed.json`: the German 380 kV
    backbone at full fidelity, lean spines to every CONTINENTAL_CORE metro,
    real interconnectors, the DC projects), every metro fed from its real
    substations with the adequacy fleet ringed around it (plants at distant
    park substations pushed each metro's whole supply through 1-2 feed
    corridors — measured 286 %). Three structural pieces landed with it:
    - **authored circuit counts** (`WorldModel.corridor_circuits`, seed
      `circuits`, feeds at 12): the ledger-45 "authored corridor upgrades"
      path — the sizer takes max(flow estimate, authored); estimator
      behavior unchanged where nothing is authored.
    - **AC gateways are corridor stubs** (no substation, no bus): a
      cross-border leaf bus bought nothing electrically and cost a
      node-budget slot each; the line still draws to the border.
    - **shunt-reactor compensation** (`scenario.shunt_comp`, builder-side
      pandapower shunts): the realistic grid's long corridors inject
      **87 GVAr** of line charging and the PF diverged outright — every
      t=0 "overload" was reactive charging current, not MW (zone-balanced
      startup transfers measure 1e-12). 90 % compensation converges at
      1.020-1.025 pu, max loading 24 %. Legacy bundles (flag absent)
      byte-identical; the topology golden re-baselined for the new
      scenario field. The ledger-45 L116/L108 day-1.34 duty trip is
      retired by construction (meshed real topology + authored circuits).
    Node budget: 135 buses / 252 branches (warn-range, inside 150).
    OSM/OpenInfraMap stays excluded (ODbL, ledger 38); plant-site realism
    is queued on the WRI Global Power Plant Database (CC-BY).

47. **The inherited fleet stands on real ground** (GPPD integration,
    2026-08-21): `europe_plants_seed.json` (WRI Global Power Plant
    Database v1.3, CC-BY — the licence-clean answer to the OpenInfraMap
    request) feeds `GridPlan.author_start`: the gigawatt class gets its
    real sites (REAL_SITE_MIN_MW 1000, top-2 stations per metro — the
    150-bus budget affords ~35 real stations; measured 244 buses when the
    full >=500 MW fleet was real-sited), the top-4 real pumped-storage
    stations snap to phs_site resources, the top-4 offshore parks connect
    near-shore AC; synthetic units stand ADJACENT TO THE WEB (a spur per
    unit fragmented the parks into lone tap buses) and the collector web
    around plants is authored HEAVY (12 circuits) with per-station
    evacuation paths — a real cluster's output transits its feed corridors
    from the first startup profile on (zone balance is energy, not
    geography; measured 84 % at startup, 121 % at the morning ramp, duty
    trip, pocket blackout). 145 buses; campaign ★★★ with zero
    trips/blackouts/UFLS; save_load bit-identical; dispatch prices
    unchanged to the cent. Next per the owner's sequence: cables
    (corridor kind with real cable charging — the shunt machinery is
    ready for it).

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

### UI overhaul + Europe map v3 (user direction, 2026-08-14)

**Built:** the game's look and scale, on the user's direction that the
sibling's per-component 3D models and menu-driven building are the bar.
RENDERING: `views/world_view_3d.gd` (Forward+, SSAO, filmic tonemap, locked
isometric orthographic camera, depth fog), `views/rendering/` —
`europe_terrain.gd` (chunked terrain meshes), `plant_models.gd` (a distinct
procedural low-poly model per plant kind — cooling towers, turbine halls,
rotors, pylons), `deco_scatter.gd` (deterministic forest/rock MultiMesh
cover from a noise field, hashed jitter so a re-streamed chunk reproduces
exactly). BUILDING: `views/build_menu.gd` — five category tabs with live
SubViewport 3D thumbnails; **every build hotkey is gone** per the user's
instruction. NAVIGATION: `views/nav_panel.gd` (minimap + jump list) replaces
panning across a continent. MAP: `tools/map_authoring/natural_earth.py` +
regenerated `data/map/europe_v3.json` — 960 × 804 tiles at 5 km from
Natural Earth (public domain; ledger 38), real coastlines, 222 named
mountain ranges, 55 river courses.

**Tests:** 7 map validations re-pinned for the new grid (SHA-256 digest
comparison — pytest diffing two 4 MB strings hangs); GdUnit 33/33; the P4/P5
smoke set re-run green on the new map.

**Acceptance evidence:** screenshots at three zooms in `docs/look/`; the
continent streams at interactive frame rates with a 320 × 268 minimap built
in 41 ms.

**Discoveries:** (1) fog under an orthographic camera applies uniformly and
veils the whole scene white — `FOG_MODE_DEPTH` instead. (2) A missing
`vertex_color_is_srgb` bleached the terrain. (3) `PanelContainer` anchor
presets do not apply to a CanvasLayer child; set anchors explicitly.
(4) The 10× finer grid broke every radius written as a tile count — see
ledger 38, which now records five separate instances.

**Deviations (deliberate):** the offshore/HVDC visuals reuse the plant-model
system rather than bespoke meshes; `europe_v1`/`v2` stay in the repo as the
fallback chain `BuildSession.load_map()` walks.

**Next:** P9 — campaign, scenarios, save/load, balancing.

### P9 — Campaign, scenarios, sandbox, save/load (2026-08-14)

**Built:** the inherited world re-authored as the **continental** backbone
(`author_start` over 16 mainland metros — 142 plants, ~95 GW peak, 64 buses /
120 branches, ledger 41) because milestone 1's scripted 1.2 GW trip is only
the 1.3 % event the design intends on a real synchronous area; per-branch
circuit sizing in `GridTopology` (bridge analysis — ledger 42); the
dispatcher's allocator rewritten so locality and merit share ONE budget
(ledger 40) and every uncommitted or mothballed unit is explicitly zeroed
(ledger 43); `model/sandbox.gd` + `views/sandbox_panel.gd` (GAME_DESIGN §5.4
classroom console: difficulty presets, trip-the-largest-unit, weather force
windows, treasury) with the difficulty knobs wired into capex, demand growth
and VoLL — never into physics; `model/scenario.gd` + `data/scenarios/`
(recipes, not snapshots: seed + difficulty + forces + world-or-build).

**Tests:** backend suite green; GdUnit 33/33 (topology golden unchanged —
small worlds still take 4 circuits); smokes `campaign_take_the_reins`,
`save_load_replay`, `scenarios`, `dispatch_day`, plus the P4/P5 set.

**Acceptance evidence:** `SMOKE_CAMPAIGN {"ok":true, "stars":3, "ufls":0}` —
milestone 1 completed by scripted play at the pinned ★★★, replay viewed,
campaign state round-trips. `SMOKE_SAVE_LOAD {"ok":true}` with frequency and
plant power **bit-identical** across save → 4 blocks → load → replay.
`SMOKE_SCENARIOS {"ok":true}` — three recipes load and the build recipe
reproduces its world exactly. The continental world runs as ONE island at
w = 1.00, 49.98 Hz in CALM, with aFRR trimming (−600 MW) and zero line
trips; `SMOKE_DISPATCH_DAY` green with night price 7.7 €/MWh and evening
63.1 €/MWh.

**Discoveries:** four bugs, each invisible at 3-city scale and each fatal at
142 plants — ledger 40 (a schedule is a budget, not a set of floors), 41
(the island must be big enough for its own reference incident), 42 (circuits
sized per branch), 43 (silence is not zero). The diagnostic that found the
first: `afrr_used_mw ≈ 0` while `fcr_used_mw` held hundreds of MW — primary
control quietly carrying a steady-state error that secondary control should
have erased.

**Deviations (deliberate):** §4.4's stochastic event table (MTBF unit trips,
storm-correlated line trips, forecast busts) is NOT in v1 — campaign
incidents are the scripted ones plus what the player's own grid does; the
sandbox therefore ships without an `event_rate` knob rather than with a knob
that scales nothing. The morning ramp dips to 49.60 Hz (pump and
electrolyzer shed fire, no UFLS) when the smoke drives 900 s wire steps.
Diagnosed twice: the first reading — "the schedule lags by a block" — was
WRONG, and fixing it (the ramp is now sampled at the step midpoint, which
was a real bug: a dt = 900 s step used to command the PREVIOUS block's
schedule) left the dip exactly where it was, 49.699/49.599 to the mHz. The
actual mechanism is coarser: `zone_demand` is sample-and-hold per wire
step, so at dt = 900 s the whole morning ramp arrives as one instantaneous
multi-GW jump while the fleet can only slew at a few %/min. It is an
artifact of stepping coarsely, not of the dispatcher — the game steps at
0.1-6 s, where the same ramp is smooth (P2 already logged the standalone
version of this). Smokes that care step 3 x 300 s per block instead.

**Next:** P10 — hardening, packaging, release.

### P10 — Hardening, packaging, release (2026-08-14)

**Built:** `game/export_presets.cfg` (Linux + Windows, gdUnit/tests excluded
from the PCK) and `scripts/package_game.sh` — freezes the backend, exports
the game, assembles the flat runtime layout (`data/` and
`orchestration/sidecars.json` beside the executable, the frozen backend under
`backend/`, sidecar config pointing at the binary rather than a venv) and
then **plays the bundle it just built**; `model/app_paths.gd` (one helper for
repo-relative reads); `smokes/soak.gd` (24 in-game hours: step budget,
backend RSS, leaked processes); CI grown two jobs — `game-tests` (GdUnit +
the fast smokes on a fetched Godot) and a test-gated `image` publish;
release checklist in §8; README quickstart rewritten around the bundle.

**Tests:** `SMOKE_SOAK {"ok":true}` — 96 blocks, 0 PF failures, RSS
331.3 → 332.9 MB, step 3.50 s → 4.61 s (ratio 1.32, no drift), no leaked
process. Packaging verified end to end: the 199 MB bundle boots its own
frozen backend and runs `boot_and_day` to 80/80 converged, t_sim exactly
7200 s, f ∈ [49.998, 50.036] — numerically identical to the same smoke from
source.

**Acceptance evidence:** `build/dist/rttransportflow-0.0.1-linux-x86_64.tar.gz`,
self-contained, no Python required on the player's machine.

**Discoveries:** (0) **CI had been red for twelve consecutive runs** and
nobody had looked — a local suite that passes for a reason CI does not
share is not a green suite. Two independent breakages: `pytest` could not
import two test modules (three tests import helpers from a sibling module,
which needs the repo root on `sys.path`; `python -m pytest` inserts the CWD
and hid it, bare `pytest` does not — `pythonpath = [".", "src"]` now), and
the Godot job died before running a test (GdUnit's vendored `runtest.sh`
passes `--headless` only to its log-copy pass, and GdUnit additionally
refuses headless unless given `--ignoreHeadlessMode`; CI now calls
`GdUnitCmdTool` directly rather than patching a vendored addon). Every job
now also carries a timeout sized to catch a hang rather than police
runtime; the ceilings are set from MEASURED durations on the runner —
backend suite 8m 24s, game-tests 1m 52s, freeze-smoke 1m 56s, image 1m 13s.
(An earlier reading of "over an hour" for the backend suite was me
mistaking queue time for run time, and it briefly went into this log and a
commit message before the completed run corrected it.)
(1) `globalize_path("res://").get_base_dir()` is correct in
the editor and WRONG in an export (res:// is the PCK) — the packaged game
booted to an empty world looking for `/data/grids/...`. Caught only because
the packaging script plays the bundle instead of listing its files; that is
the whole argument for the play step. (2) Measured speed on the continental
world: ~1.9-2.1 s per 900 s block off-peak, ~4.9 s across the evening peak,
so the game sustains ~180-450x real time rather than the 900x the top speed
button requests — the orchestrator's skip-never-stall absorbs it. The number
belongs in the log, not behind a loose threshold.

**Open at hand-off (ONE smoke-level item, diagnosed, not a model
defect):** `hvdc_link` is 8/9 — the netting fix works (measured terminal
power reaches the ledger and the schedule moves), but the converter's AC
spur is routed with `stop_at_existing` and ends at the FIRST corridor tile
it meets, so the receiving terminal injects halfway down a corridor instead
of at the metro's bus; giving each converter the city tap needs the DC
exit tile reserved before the AC web goes down. `hydrogen_chain` is **GREEN 7/7** once
the machine is quiet enough to give it an uninterrupted run (every earlier
attempt died to a wall-clock cap while the campaign/soak runs competed for
cores): cavern 280 → 411 t while power is cheap (10 920 MWh into the
electrolyzers), forced calm burns it to the 5 % floor at 200 t delivering
5 110 MWh, the plants starve there, and the **round trip measures 0.3645**
against the ≈35 % §1.14 prediction — a number nobody tuned, it falls out of
electrolyser specific energy × compression aux × turbine efficiency
composing. The fleet-sizing fix is what unblocked it: five 800 MW coal
units covered the island alone so the expensive H2 tier was never called;
three leave ~0.5 GW for it.

**Deviations (deliberate):** the heavy smokes (campaign, soak, calm_week)
stay local rather than in CI — minutes each, and CI is not where you want to
discover them. Windows packaging is wired (preset + script branch) but only
the Linux bundle is verified on this machine.

### Refactoring campaign — six stages, one re-baseline (2026-08-20)

**Built:** a whole-monorepo, behavior-preserving refactoring campaign on
`refactor/campaign` (ten commits), planned by a 15-agent survey — 10
parallel subsystem reviewers, an adversarial constraint audit (73 canonical
findings, 0 unsound), a completeness critic and a roadmap pass; the plan
and full finding inventory live in the published overview artifact.
S1 safety rails: `tests/helpers/` (one wire-fixture set, one dyn-fixture
set, one client fixture, ONE merge-semantics step helper), one smoke
harness (`gridco_boot`, the `SMOKE_PORTS` registry ending the silent 8034
sharing, `Wire.numf`, `chase_event`, FleetQuery-backed victim selection),
and the P4 contract schemas ENFORCED against the live wire. S2 deletions &
doc truth: frequency_panel, probe6/calm_probe/start_check, BOOT_TRACE,
`dynamics/islands.py` (the trap second union-find), europe_v1/v2 archived,
four orphaned Kenney kits (game binary 96 → 72 MB), one
`_restore_start_world`; v2.md/GAME_DESIGN corrected to shipped truth.
S3 single-sourcing (values identical, proven by unchanged hashes/goldens):
ModeConfig wired from Settings (4 dead knobs deleted, real homes named),
offshore_hub joins the catalog, `frequency_protection` finally read,
make_fleet fallbacks named + drift-tested, repr-float one home, the
`dispatch_policy` block in economy.json read by the live dispatcher AND
the stub (stub-vs-live can no longer diverge on 0.92/1.015), one BLOCK_S,
one tiles_for_km, one §1.16 loss model, one sidecars.json author. S4
backend seams then the split: reporting moved ONTO the simulator (ends
gamebridge's ~14-private reach and its one WRITE), one PF ladder, one
sim-kwargs source for live + replay, fleet-owned row maps, the
attachment-state splice; the never-crash guard extended over the boundary
prologue and restore_load routed to the zone's ACTUAL island (each change
with its first test); simulator.py split into wire / wire_devices /
topology / commands / report (MIXINS — file separation with zero attribute
or float motion). S5 game splits: StartupProfiles + WireDeviceEmit out of
GridTopology.build (golden byte-stable), one nearest_zone, one
`_reset_backend` with the deaf-backend recovery made REACHABLE (+ its
first GdUnit coverage, fake bridge/health), SaveLoad behind named seams,
decide() sectioned along its own comments, Campaign.repriced(), one BFS
for AC and DC routing, the campaign world author moved to Campaign. S6 hot
path, last and least: declared PER_ISLAND remap protocols on Integrator
and DefensePlan (the ledger-37 shape now impossible by construction), the
in-place two-segment FineRing search, one storage_caps clamp, the HVDC
coefficient memo, fcr_used/notices as declared fields.

**Tests:** backend 149 → 152 (the pins themselves proved the fixture
helpers byte-identical; new: catalog-drift ×3, schema validation,
prologue-failure, restore-routing); GdUnit 33 → 35 (the deaf path's first
tests). Each stage closed with its own full gate.

**Acceptance evidence:** save_load_replay BIT-identical at every stage;
dispatch_day's prices to the cent and hydrogen_chain's 0.364523 round trip
to six decimals through every extraction; topology + author_start goldens
byte-stable throughout; economy_windows.csv regenerated byte-identical
until the one sanctioned re-baseline. SOAK post-campaign: step 2647 →
2682 ms against the P10 reference 3500 → 4610 — 24 % faster with the
drift gone (ratio 1.013 vs 1.32), RSS flat. hvdc_link 9/9 — the first
full pass in the project's history (ac_relieved clears under corrected
demand; the converter-tap routing quirk from the P10 hand-off still
exists and the relief margin is thin).

**The re-baseline** is ledger 45: the stale-projection correction, landed
alone, reviewed as physics, with the day-1.34 meshed-trunk duty-trip /
generation-pocket blackout surfaced as an OPEN balancing item rather than
tuned away.

**Discoveries:** (1) the projection bug — the sixth ledger-38 instance, as
a stale DEFAULT rather than a tile count; survey-found, live-confirmed.
(2) The campaign smoke's fixed 194-iteration cap held ~2 blocks of margin
against early-returning events; it loops on sim time now. (3) cascade's
1.5× windowed-RoCoF threshold had been passing at a measured 1.52 —
fixture luck, re-pinned at 1.3× with the instant-RoCoF physics still
pinned backend-side. (4) hvdc_link's absolute trip window tested the
island's operating point, not the trip (P7 discovery 5, refound). (5) The
four Kenney orphan kits were ~76 MB of every export.

**Deviations (deliberate, documented in the stage commits):** mixins
instead of collaborator objects for the simulator split (bit-exact pins
made attribute re-plumbing all risk, no gain); HELD OUT: the full Fleet
block split (the audit found it not purely mechanical — its safe slices
landed), Boundary provider objects + ScheduleRamp (residual pressure low
after the fixes), the ChunkStreamer/lighting/hud/UI-theme items (they live
in world_view_3d.gd, which carries uncommitted in-progress work). The
survey's periphery leads (engine.py's silent except-pass + absent backend
logging, ADR-004's phantom CI perf budget, the Godot toolchain
double-pin) are recorded in the overview artifact for later.

### Realistic campaign world re-baseline (owner-directed, 2026-08-21)

**Built:** ledger 46 in full — GridPlan (the renamed, generalized seed
author) builds the inherited world from the European plan; authored
circuit counts; AC gateway stubs; backend shunt-reactor compensation
(`scenario.shunt_comp`, pandapower shunts, legacy bundles untouched);
`DemoBuild.route` gains kind-aware stops (AC spurs stopping at HVDC tiles
orphaned 24 islands at t=0) and an index-head queue (pop_front went
quadratic at continental scale).

**Tests:** backend 152 green (europe_mini pins untouched); GdUnit 39
(topology golden re-baselined for the scenario field); author_start,
campaign_take_the_reins (★★★, ZERO trips/blackouts/UFLS through day
2.03 — the ledger-45 incident retired), save_load_replay bit-identical,
dispatch_day green with prices unchanged to the cent (night 53.83 /
evening 63.12 €/MWh).

**Discoveries:** (1) the t=0 "overloads" were never MW — zone-balanced
startup transfers measure 1e-12; they were 87 GVAr of uncompensated line
charging on realistic corridor lengths, and the PF diverged outright
(vm NaN). Real grids hang shunt reactors at every EHV station; now the
game's do too. (2) A metro's fleet must ring the metro: parks at distant
substations pushed the whole supply through 1-2 feed corridors (286 %
measured). (3) Scattered per-plant taps cost ~108 lone buses; packed
parks collapse to few. (4) The node-budget "153" appearing thrice was
apples-to-oranges estimation — mirror the sizer's exact rule before
tuning against it.

**Deviations (deliberate):** economy/calm_week/soak deferred to the next
sweep (dispatch_day's identical prices bound the economics); WRI GPPD
plant re-siting queued (CC-BY; OpenInfraMap/OSM stays excluded per
ledger 38).

### Strategic-zoom arc — look, real grid, freeze campaign, site notes (2026-08-21/22)

**Built:** twenty commits on `ui/strategic-zoom`, merged fast-forward
after a full green sweep. The Europe LOOK: ETOPO-derived relief sidecar
(smooth shorelines, lakes, satellite palette), real overhead lines
(silver three-phase conductors, faced towers, diagonal spans),
NE-urban-footprint cities with Kenney sprawl and night glow, day/night
cycle, mouse camera (RMB rotate / MMB pan). The REAL GRID: Germany's
380 kV seed, then the European-plan campaign world with the GPPD fleet
(ledgers 46/47), and underground cables (`cable_400` corridor kind
end-to-end: real cable parameters, charging into the shunt machinery,
trench rendering); wind rotors spin from live regional weather.
PERFORMANCE: shared primitive meshes (after an RID-exhaustion boot
crash), budgeted chunk streaming (6/14 ms/frame), staggered eviction,
strategic ribbon layer above zoom 30 / model band below 34. Voltage
bands corrected to transmission practice (warn outside [0.93, 1.08] pu,
critical outside [0.90, 1.105] — the reported "violations" were
distribution defaults judging a transmission grid; PARAMETERS §5). THE
FREEZE CAMPAIGN — four user-reported live freezes, four distinct
mechanisms, each named by evidence and fixed: (1) untimed step await +
sidecar hair-trigger restarts → step timeout counted as transport
failures, health-probe tolerance; (2) unexplained at the time → the
ORCH heartbeat (10 s gate-state log line) + a 60 s recovery unwedge;
(3) rotor nodes freed by chunk eviction while still keyed in the spin
dict — a TYPED for-loop variable throws on a freed instance at the
for-statement itself, before the body's validity guard, so one
backtrace-formatted error per frame forever (~60/s read as a frozen
game); untyped loop, guard now self-heals — found alongside the
register STOP-LEAK (every `_register_async` failure path left the
orchestrator stopped forever; each now restarts it onto the still-live
previous registration, loudly); (4) crossing the model band after
birdview populated ~120 resident chunks spanning central Europe in ONE
synchronous call — minutes of model building, most for chunks already
queued for eviction; population is now a nearest-first queue drained
under the frame budget. SITE NOTES (the energy-charts request):
ZoneHistory autoload (a measured 7-day ring of 15-min blocks from every
applied wire result — ledger 44 discipline), ZoneChart (generation
stacked by source with charging/electrolysis/pumping/export below the
zero line, measured load solid, forecast dashed, a now-slider with
timestamp), SiteNote billboards above cities (zoom ≤ 70) and plants
(≤ 16), nearest-first under hard caps, SubViewports rendered once per
block; `SHOT_FAKE_WEEK` joins the screenshot probe as the look harness.

**Tests:** backend 152; GdUnit 43 (ZoneHistory ring semantics new); the
FULL §8 smoke sweep green in 52 min — all 21 smokes, run while the
interactive game played on 8030.

**Acceptance evidence:** dispatch_day prices unchanged to the cent
(night 53.83 / evening 63.12 €/MWh); campaign ★★★ with zero
trips/blackouts/UFLS; save_load bit-identical; hvdc_link 9/9 for the
second consecutive full pass (ac_relieved 23.2); hydrogen_chain round
trip 0.3681 against the ≈ 35 % §1.14 window (the GPPD fleet moved it
from 0.3645); north_sea_hub delivery ratio 0.9506; soak RSS
333.7 → 333.9 MB, step 2385 → 2604 ms (ratio 1.09 vs the P10 1.32
reference) — measured beside the running game.

**Discoveries:** (1) the heartbeat is the load-bearing lesson: one 10 s
gate-state print turned "it froze again" from unfalsifiable into a
named cause within minutes — freeze #4's trail ending at a HEALTHY beat
itself named the class (a single synchronous main-thread call). (2) A
typed GDScript for-loop variable is an assignment — freed instances
throw before the loop body can guard. (3) `dict[key][i] = v` on a
packed array mutates a discarded copy — ZoneHistory stores plain
Arrays. (4) ptrace and perf are locked down on this box (yama=1,
perf_event_paranoid=4): external stack capture needs sudo, so
in-process instrumentation is the tool that actually answers.

**Deviations (deliberate):** site-note charts carry no legend (the
palette is the identity) and the slider is an indicator, not a
scrubber; the measured week is not in the save (a load clears the
ring); h2 caverns get no note (no power trace — a fill-level note is a
candidate). Freezes #1/#2 were never conclusively attributed — the
fixed mechanisms cover every found candidate, and the heartbeat plus
the REGISTER FAILED prints will name any recurrence directly.

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

## 8. Release checklist (ROADMAP P10)

Run in order; every step is a gate, not a suggestion.

1. `.venv/bin/pytest` — backend suites green (contract fixtures included).
2. `game/` GdUnit suites green (topology goldens, map validations).
3. Smoke sweep, each on its own port (`RTTF_PORT_OFFSET=<n>` isolates a
   parallel run — two runs on one port make the loser silently adopt the
   winner's backend and report someone else's grid):
   P4/P5 `boot_and_day`, `trip_reaction`, `trip_key`, `sidecar_crash`,
   `island_cut`, `build_and_supply`, `ui_boot` (the only test that
   constructs the HUD — model smokes never touch it); P6 `dispatch_day`,
   `economy`,
   `calm_week`; P7 `hydrogen_chain`, `battery_response`, `hvdc_link`,
   `north_sea_hub`; P8 `ride_through`, `cascade_low_inertia`,
   `replay_panel`; P9 `save_load_replay`, `campaign_take_the_reins`,
   `scenarios`; P10 `soak`.
4. `scripts/freeze_backend.sh` — frozen backend boots and answers `/health`.
5. `scripts/package_game.sh linux` — assembles the bundle AND plays it
   (`boot_and_day` inside the bundle). A bundle that assembles but cannot
   boot its own backend is worthless, so the play step is the real gate.
6. `--smoke=soak` — 24 in-game hours: step budget held, memory flat, zero
   leaked processes. Reference: RSS 331 -> 333 MB, step 3.5 -> 4.6 s (no
   drift). NEVER `pkill -f smoke=...` to clean up between runs: the pattern
   matches your own shell and kills the session (cost several runs today).
   Use `fuser -k <port>/tcp`, and give concurrent runs distinct offsets.
7. Docs: README status + quickstart current; PHYSICS honesty section still
   true of the code; this file's §6 log carries the phase entry.
8. Tag and publish only on explicit authorization (§3).
