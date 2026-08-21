# PARAMETERS.md — asset models, parameters & frequency-response spec

Authority: every per-technology number (dynamics constants, operating
envelopes, economics), the reserve/defense-plan tables, and the weather model
(SPEC §0.2). The *equations, integrator, and protection mechanics* are owned by
[PHYSICS.md](PHYSICS.md).

Status: implementation-grade; every parameter is a concrete number. Context:
ENTSO-E Continental Europe (50 Hz), ~2026 European cost levels, EUR. Values
are literature-typical planning values (ENTSO-E SOGL/LFC handbook, ENTSO-E
RfG, IEEE PES turbine-governor reports, Kundur, Fraunhofer ISE / Lazard /
Danish Energy Agency technology catalogues, HyUnder) — chosen for
gameplay-correct *relative* behavior and internally consistent: the merit
order (§4) and the frequency worked example (§2.3) were computed numerically
from these exact numbers. These constants land in
`data/catalogs/plant_types.json` (+ `line_types.json`, `storage_types.json`,
`economy.json`), each with a rationale string.

---

## 0. Conventions

- `f0 = 50 Hz`; `Δf = f − f0`.
- Each synchronous machine: rated power `P_n` [MW], apparent rating
  `S_n = P_n / 0.9` [MVA]. Inertia constants `H` [s] on machine base `S_n`
  (kinetic energy `E_k = H·S_n` [MJ]).
- Frequency model, integration scheme, tick order: PHYSICS.md §1–§2
  (per-island COI swing; exact-exponential lags at 10 ms ALERT / 250 ms CALM).
- Deadbands are **soft/offset**: `e = sign(Δf)·max(0, |Δf| − db)` (hard
  deadbands limit-cycle).
- RoCoF is reported as a 500 ms sliding-window mean.
- All dynamic states persist across gamebridge steps and serialize into
  save/load (snapshot).
- Signs: generation positive; storage `p` positive = discharge; electrolyzer
  `p` positive = consumption.

**Shared governor pipeline** (realization in PHYSICS §2.4):

```
Δf → soft deadband db → e
p_cmd = clamp( P_set/P_n − e·S_n/(P_n·R·f0), P_min_pu, P_max_pu )
        # droop R in pu ON MACHINE BASE S_n (ledger 20): gain K = S_n/(R·f0) MW/Hz
FCR contribution |p_cmd − P_set/P_n| additionally clamped to the unit's fcr_band
p_cmd feeds the technology's turbine blocks → P_m
Dispatch changes of P_set are rate-limited by the ramp rate; unit-commitment
states (start/stop sequences) gate P_set.
```

---

## 1. Technology specifications

### 1.1 Nuclear — large PWR (unit 1600 MW)

**Dynamic model** — tandem-compound single-reheat steam turbine
(IEEEG1-reduced, 3 states):

```
servo:       T_SM · dx_g/dt = p_cmd − x_g        T_SM = 0.2 s
steam chest: T_CH · dp_HP/dt = x_g − p_HP        T_CH = 0.3 s
reheater:    T_RH · dp_RH/dt = p_HP − p_RH       T_RH = 8 s
P_m = P_n · ( F_HP·p_HP + (1−F_HP)·p_RH )        F_HP = 0.30
```

Slow reheat (70 % of the power arrives with an 8 s lag) is exactly why steam
plants can't arrest a fast dip — the game's core lesson.

| Parameter | Value |
|---|---|
| Unit size / S_n | 1600 MW / 1778 MVA |
| Inertia H | **6.0 s** (provides inertia: yes) |
| Droop R / deadband | 5 % / ±20 mHz |
| FCR band cap | ±2 % P_n (±32 MW); **game default: primary participation OFF (must-run); player-enabled at a wear fee** |
| Q capability | +0.48 / −0.30 · P_n (over/under-excited) |
| P_min / P_max | 50 % / 100 % |
| Ramp rate | 2 %/min (dispatch); governor action unrestricted within the FCR band |
| Start hot/warm/cold | 8 h / 24 h / 48 h; **post-trip xenon lockout 48 h** (scram → cannot restart) |
| Min up / down | 24 h / 24 h; ≤ 1 large maneuver per day (maneuvering counter) |
| Efficiency full / at P_min | 33 % / 32 % (linear in between; fuel_MWth = P_el/η(P)) |
| Capex / FOM / VOM | 7000 €/kW / 120 €/kW/a / 2.5 €/MWh |
| Fuel (uranium, full cycle) | 1.7 €/MWh_th |
| CO2 | 0 t/MWh_el |
| Startup cost hot/warm/cold | 50 / 100 / 200 €/MW |
| Lifetime / build time | 60 a / 96 months |

### 1.2 Hard coal — supercritical (unit 800 MW)

**Dynamic model**: the 1.1 steam model with `T_SM = 0.2, T_CH = 0.3,
T_RH = 10 s, F_HP = 0.30`. Boiler-storage limits are modeled as the FCR band
cap + dispatch ramp limit (no separate boiler ODE).

| Parameter | Value |
|---|---|
| Unit size / S_n | 800 MW / 889 MVA |
| Inertia H | **4.0 s** |
| Droop / deadband / FCR cap | 5 % / ±10 mHz / ±5 % P_n |
| Q capability | +0.48 / −0.30 · P_n |
| P_min / ramp | 35 % / 3 %/min |
| Start hot (<8 h off) / warm (8–48 h) / cold | 3 h / 5 h / 10 h |
| Min up / down | 6 h / 6 h |
| Efficiency full / P_min | 45 % / 41 % |
| Capex / FOM / VOM | 1800 €/kW / 45 €/kW/a / 4.5 €/MWh |
| Fuel (API2-typical) | 12 €/MWh_th (−25 % on `coal_basin` tiles) |
| CO2 | 0.34 t/MWh_th → 0.756 t/MWh_el at full load |
| Startup hot/warm/cold | 60 / 90 / 130 €/MW |
| Lifetime / build | 40 a / 60 months |

### 1.3 Lignite (optional buildable; unit 900 MW)

Steam model as 1.2 (`T_RH = 10 s`). Differences only:

| Parameter | Value |
|---|---|
| H | **4.0 s** |
| P_min / ramp | 40 % / 2 %/min |
| Start hot/warm/cold | 4 h / 6 h / 12 h; min up/down 8 h / 8 h |
| Efficiency | 43 % / 39 % at P_min |
| Capex / FOM / VOM | 2000 €/kW / 55 €/kW/a / 5.0 €/MWh |
| Fuel (mine-mouth) / CO2 | 4 €/MWh_th; 0.40 t/MWh_th → 0.93 t/MWh_el |
| Startup / lifetime / build | 70/100/150 €/MW; 45 a; 66 months |

### 1.4 CCGT (unit 600 MW, H-class single-shaft)

**Dynamic model** — GAST-style gas path (2 states) + HRSG/steam tail
(1 state). GT delivers 2/3, steam 1/3:

```
fuel valve: T1 · dp_f/dt  = (2/3)·p_cmd − p_f     T1 = 0.4 s
GT:         T2 · dp_gt/dt = p_f − p_gt            T2 = 1.0 s
HRSG+ST:    T_ST · dp_st/dt = 0.5·p_gt − p_st     T_ST = 120 s
P_m = P_n · (p_gt + p_st)     # steady state: p_st = p_gt/2 → total = p_cmd ✓
```

The GT reacts in ~1–2 s (fast primary response), but only 2/3 of the headroom
is fast; the steam tail follows over 2 minutes — CCGTs feel "fast, then
breathes".

| Parameter | Value |
|---|---|
| Unit size / S_n | 600 MW / 667 MVA |
| Inertia H | **4.5 s** |
| Droop / deadband / FCR cap | 4 % / ±10 mHz / ±5 % P_n |
| Q capability | +0.48 / −0.30 · P_n |
| P_min / ramp | 40 % / 4 %/min sustained (governor transients unrestricted) |
| Start hot/warm/cold | 45 min / 2 h / 4 h; min up 3 h / down 2 h |
| Efficiency full / P_min | 59 % / 50 % |
| Capex / FOM / VOM | 950 €/kW / 27 €/kW/a / 2.0 €/MWh |
| Fuel (TTF-typical 2026) / CO2 | 30 €/MWh_th (−10 % on coast/LNG tiles); 0.202 t/MWh_th → 0.342 t/MWh_el |
| Startup hot/warm/cold | 25 / 40 / 55 €/MW |
| Lifetime / build | 30 a / 36 months |

### 1.5 OCGT (unit 200 MW)

**Dynamic model** — GAST, 2 states: `T1 = 0.3 s` (fuel valve), `T2 = 0.8 s`
(turbine), `P_m = P_n·p_gt`. The fastest thermal responder in the game.

| Parameter | Value |
|---|---|
| Unit size / S_n | 200 MW / 222 MVA |
| Inertia H | **3.0 s** |
| Droop / deadband / FCR cap | 4 % / ±10 mHz / ±10 % P_n |
| Q capability | +0.48 / −0.30 · P_n |
| P_min / ramp | 20 % / 15 %/min |
| Start (any state) | 15 min; min up/down 30 min / 30 min |
| Efficiency full / P_min | 40 % / 29 % |
| Capex / FOM / VOM | 500 €/kW / 18 €/kW/a / 3.0 €/MWh |
| Fuel / CO2 | 30 €/MWh_th; 0.505 t/MWh_el |
| Startup / lifetime / build | 15 €/MW flat / 30 a / 24 months |

### 1.6 H2-fired gas (CCGT/OCGT retrofit)

**Dynamics identical to the base model** (1.4/1.5) — H2 combustion does not
change the turbine lags meaningfully. Differences:

| Parameter | Value |
|---|---|
| Retrofit capex | +150 €/kW (CCGT), +100 €/kW (OCGT); retrofit outage 6 months |
| Efficiency | −2 pts vs base: H2-CCGT 57 % / 48 % at P_min; H2-OCGT 38 % / 28 % |
| Fuel draw | `ṁ_H2 [kg/h] = 1000·P_el / (η(P)·33.33)` (LHV 33.33 kWh/kg), integrated per tick against the linked cavern |
| Blending | `x_H2 ∈ [0,1]` energy share; NG cost and CO2 scale with `(1 − x_H2)` |
| Fuel starvation | cavern at 5 % floor → derate to available withdrawal, then forced ramp-out (PHYSICS §2.8); `fuel_starved` violation |
| CO2 at x_H2 = 1 | 0 |
| Reference marginal cost | with stored H2 at 75 €/MWh_th (≈ 2.5 €/kg): H2-CCGT ≈ 134 €/MWh, H2-OCGT ≈ 200 €/MWh. In-game the H2 fuel value is **endogenous** (rolling average cost of the H2 book) |

### 1.7 Wind onshore (farm 200 MW, 6 MW class)

**Dynamic model** — converter-coupled, **H = 0** (no inherent inertia):

```
P_avail(t) from the weather model (§3) · availability
p_cmd = min(P_avail, P_curtail_set) − LFSM-O term
LFSM-O (mandatory, EU RfG): f > 50.2 Hz → ΔP = −(Δf − 0.2)/(0.05·50) · P_current
converter/pitch lag: T_w = 0.2 s (down/curtail), 2.0 s (up, pitch)
```

Optional flag `synthetic_inertia` (default OFF; campaign unlock 2035): if
RoCoF < −0.3 Hz/s, one-shot boost +10 % P_n for 8 s from rotor kinetic energy,
followed by a **recovery dip of −5 % P_n for 20 s** (the dip is the teachable
part).

| Parameter | Value |
|---|---|
| Farm size | 200 MW (stackable per tile, GAME_DESIGN §1.3) |
| Inertia | **0 s** (converter; none unless synthetic flag) |
| Q capability | ±0.33 · P_n while grid-connected (pf 0.95) |
| Curtailment | 0–100 %, response 2 s; curtailment marginal cost 0 |
| Capacity factor | 0.21–0.32 by region (§3, emerges from weather) |
| Capex / FOM / VOM | 1350 €/kW / 30 €/kW/a / 1.3 €/MWh |
| Marginal cost | ≈ 0–1.3 €/MWh (price-taker) |
| Lifetime / build | 25 a / 18 months |

### 1.8 Wind offshore (farm 500 MW, 15 MW class)

Same dynamic model as 1.7. Two connection paths (GAME_DESIGN §1.4): **AC
near-shore** (own submarine corridor to a coastal bus, ≤ 150 km) or **DC
far-shore** via an offshore converter platform + HVDC export (§1.16) — the
only way to reach the best far-shore North Sea sites.

| Parameter | Value |
|---|---|
| Inertia | **0 s**; Q ±0.33 · P_n (AC-connected; hub-connected farms deliver Q via the onshore converter, §1.16) |
| Capacity factor | 0.30–0.48 by region (§3.1; North Sea best, far-shore `S`-adjacent sites at the top of the band) |
| Capex / FOM / VOM | **2600 €/kW** (array + offshore substation — both connection paths). AC-connected: + own export corridor billed per-km (§1.5 AC-submarine row, ≤ 150 km). Hub-connected: + shared platform/cable/station per §1.16. FOM 80 €/kW/a, VOM 2.5 €/MWh |
| Lifetime / build | 27 a / 36 months |

### 1.9 Solar PV (park 150 MW_ac)

**Dynamic model** — converter, **H = 0**: single lag `T_pv = 0.1 s`;
curtailment effectively instant; mandatory LFSM-O as in 1.7. Power from
weather (§3): DC/AC ratio 1.25, inverter clip at P_ac, temperature coefficient
−0.4 %/K, `T_cell = T_amb + 0.034·POA`.

| Parameter | Value |
|---|---|
| Inertia | **0 s**; Q ±0.33 · P_ac (night-Q optional flag) |
| Capacity factor (AC) | 0.09–0.18 by region |
| Capex / FOM / VOM | 550 €/kW_ac / 11 €/kW/a / 0 |
| Lifetime / build | 30 a / 12 months |

### 1.10 Pumped hydro storage (300 MW / 8 h = 2400 MWh)

**Dynamic model** — synchronous hydro with transient-droop governor and
non-minimum-phase water column (3 states; realization in PHYSICS §2.4):

```
gate command: shared pipeline (R = 4 % permanent, db ±10 mHz)
transient droop: gate_ref(s) = p_cmd(s) · (1 + T_r·s)/(1 + (r_t/R)·T_r·s)
                 T_r = 6 s, r_t = 0.4 → sustained-response lag (r_t/R)·T_r = 60 s
servo: T_g = 0.5 s, gate rate limit 0.1 pu/s
water column (1 − T_w·s)/(1 + 0.5·T_w·s), T_w = 1.5 s → P_m = P_n·(3·x − 2·g)
```

Classic **inverse response**: opening the gate +0.1 pu first *drops* P by
0.2 pu, recovering with τ = 0.75 s — hydro helps a lot, but half a second
late, and the transient droop makes its sustained response deliberately
sluggish (60 s) to stay stable. Player-visible.

| Parameter | Value |
|---|---|
| Rating / energy | 300 MW gen / 2400 MWh (8 h); pump rating 300 MW |
| Inertia H | **3.5 s** (yes, in both modes) |
| Droop / deadband / FCR cap | 4 % / ±10 mHz / ±10 % P_n |
| Q capability | +0.48 / −0.30 · P_n; synchronous-condenser mode (Q at P=0) optional flag |
| Generating range | 30–100 % (10–30 % rough zone forbidden) |
| Ramp (dispatch) | 30 %/min |
| Pump mode | 4 fixed blocks × 75 MW (on/off); variable-speed variant 70–130 % continuous at +20 % capex |
| Mode switch / starts | gen↔pump 300 s (ternary variant 30 s, +20 % capex); standstill→gen 2 min; standstill→pump 5 min |
| Efficiency | pump 0.89 · turbine 0.88 → round trip **78.3 %** |
| Capex / FOM / VOM | 1100 €/kW (8 h reservoir; only on `phs_site` tiles) / 15 €/kW/a / 0.8 €/MWh |
| Start/mode-switch cost / lifetime / build | 2 €/MW; 80 a; 72 months |

### 1.11 Battery storage — grid-following (100 MW; 1/2/4 h, default 2 h)

**Dynamic model** — 1 electrical state + SoC:

```
converter lag: T_b = 0.1 s
FFR/FCR droop: p_cmd = P_set + clamp(−K_f·e, −P_n, +P_n)
               e = soft-db(Δf, ±10 mHz); K_f = P_n / 0.2 Hz  (full at ±200 mHz)
SoC: E −= P·dt/η_dis (P>0);  E += |P|·η_ch·dt (P<0)
     η_ch = η_dis = 0.94 → round trip 88.4 %; operating band SoC 5–95 %
recharge controller: while |Δf| ≤ 50 mHz, drift toward SoC_target = 55 % at ≤ 0.1·P_n
clamps: |P| ≤ P_n and SoC energy bounds per tick → "clamped" violation
```

Full power in ~0.3 s — the battery arrests the dip that steam plants
physically cannot. **No inertia** (does not slow RoCoF; only catches the
fall).

| Parameter | Value |
|---|---|
| Inertia | **0 s** |
| Q capability | ±0.33 · P_n, available also at P = 0 |
| Response | T_b = 0.1 s; FFR full at ±200 mHz, deadband ±10 mHz |
| Round trip / band | 88.4 % / SoC 5–95 % |
| Capex | 150 €/kW (PCS+BoP) + 200 €/kWh |
| FOM / VOM (degradation) | 8 €/kW/a / 1.5 €/MWh throughput |
| Lifetime / build | 15 a or 8000 equivalent full cycles / 12 months |

### 1.12 Battery storage — grid-forming (VSM variant)

As 1.11 plus **virtual inertia and forming behavior**:

- Declares `H_v = 4 s` (configurable 2–8) on `S_n`; **counts into the island
  inertia pool** — the only converter that lowers RoCoF.
- Fast droop `R_v = 2 %`, **no deadband**, lag `T_gfm = 0.05 s`.
- Current limit 1.2 pu ≤ 2 s, 1.0 pu continuous; inertial + droop energy from
  SoC. Persistent clamping > 2 s → `gfm_overload`; SoC empty → drops out of
  the inertia pool, reports `storage_empty` (contract v1.2 `grid_forming`
  advisory semantics: report, never enforce).
- Black-start capable; acts as island slack (maps to the `grid_forming`
  device kind).
- Capex premium +30 €/kW over 1.11; otherwise as 1.11.

### 1.13 Electrolyzer — PEM (100 MW)

**Dynamic model** — controllable load, 1 state: `T_e = 0.3 s`. Provides
upward reserve **by shedding load** (band = current draw, db ±10 mHz, full at
−200 mHz) and downward reserve by loading headroom. Auto-shed at 49.6 Hz
(interruptible tier, §2.2).

```
specific energy: η_spec(P) linear from 48 kWh/kg at 20 % load to 52 kWh/kg at 100 %
H2 output: ṁ [kg/h] = 1000·P / η_spec(P) → linked cavern (compression debited there)
```

| Parameter | Value |
|---|---|
| Inertia | 0 (load); Q ±0.33 · P_n (active rectifier) |
| Range / overload | 5–100 %; 120 % ≤ 10 min |
| Response | 0.3 s lag; ramp unconstrained within range |
| Efficiency | 52 kWh_el/kg rated (η_LHV = 64 %), 48 kWh/kg at 20 % (69 %) |
| Capex / FOM / VOM | 1500 €/kW / 45 €/kW/a (stack replacement inside FOM; stack 80 000 h) / ≈ 0 |
| Lifetime / build | 25 a / 18 months |

### 1.14 H2 storage — salt cavern (133 GWh_th ≈ 4000 t working gas)

Pure energy store with rate limits (no electrical dynamics of its own):

| Parameter | Value |
|---|---|
| Working capacity | 133 GWh_th LHV = 4000 t H2 per cavern |
| Injection max | 12 t/h = 400 MW_th; compressor consumes **2.5 kWh_el/kg** injected — an electric auxiliary load on the cavern's bus |
| Withdrawal max | 45 t/h = 1500 MW_th (free pressure letdown) |
| SoC floor / losses | 5 % (cushion-gas pressure floor) / 0 %/day |
| Siting | `salt_cavern` tiles only: N-Germany, Netherlands, Denmark, NW-England/Teesside, central Poland, Rhône valley |
| Capex / FOM | 0.7 €/kWh_th (≈ €93M/cavern incl. leaching + compressors) / 1.5 % capex/a |
| Lifetime / build (leaching) | 40 a / 36 months |

Power-to-H2-to-power chain (computed): 33.33/52 · 0.57 = **36.5 %** round trip
excl. compression, **34.9 %** incl. — expensive firm power, exactly the
lesson.

### 1.15 Synchronous condenser (300 MVA)

Pure inertia + voltage support — "keep the mass, drop the boiler". A
synchronous machine at P ≈ 0: contributes `H·S_n` to the island inertia pool
and full Q capability; consumes losses as a small station load.

| Parameter | Value |
|---|---|
| Rating | 300 MVA; P = 0 (station losses 1 % S_n as load) |
| Inertia H | **3.0 s**; flywheel option **7.0 s** at +40 % capex |
| Q capability | ±0.40 · S_n |
| Capex | 180 €/kVA new; **conversion of a retired thermal site: 20 % of that plant's capex** (campaign unlock) |
| FOM | 4 €/kVA/a |
| Lifetime / build | 40 a / 15 months (conversion 9 months) |

### 1.16 HVDC & offshore connection (VSC technology)

**Electrical model** (realization PHYSICS §2.4): converter-based, **H = 0**,
no frequency contribution. An **onshore point-to-point link** is a paired
±P injection (`hvdc` device kind, one command per link); an **offshore hub**
(platform + export cable + onshore converter station) is a single injection
at the onshore bus: `P = min(avail_mw, p_max) − losses`, where `avail_mw` is
the **game-aggregated** availability of its bound farms (one wire value —
bound farms are never separate wire devices); delivery lag `T_hvdc = 0.1 s`,
curtailment via link control effectively instant, **LFSM-O applied at the
onshore terminal** (grid-code behavior — the hub curtails delivered wind
above 50.2 Hz).

**Two very different contingencies** (ledger 28): an **offshore-hub trip is a
genuine infeed loss** — a single ΔP step sized by its current delivery, the
player's self-built reference incident (the adequacy advisor sizes FCR
against max(largest unit, largest hub delivery); exactly the exogenous H = 0
incident of §2.3). An **embedded onshore link trip is not**: both terminals
sit in the same synchronous island, the ±P pair cancels in the COI ledger
(net effect ≈ its losses, tens of MW), so frequency barely moves — it is an
instant **flow-redistribution contingency** (overload-duty/cascade risk,
redispatch cost), which the PF + protection layer already handles. Cross-area
import links (post-v1 multi-area) would again be infeed losses.

| Item | Value |
|---|---|
| Onshore HVDC VSC bipole (point-to-point) | 2000 MW; corridor 1.4 M€/km overhead, underground variant ×4 (the SuedLink premium); converter stations: 1000 MW → 200 M€, 2000 MW → 350 M€ each end |
| HVDC submarine export cable (bipole) | 2.0 M€/km; may cross deep sea `S` |
| Offshore converter platform | 1000 MW → **450 M€**, 2000 MW → **800 M€** (marinized ≈ 2.3× an onshore station); FOM 2 % capex/a; build 42 months |
| Onshore converter station | as bipole station row; build 300 d |
| Losses | 1.0 % per converter station (×2 per path) + 0.30 %/100 km DC cable — a 2 GW hub 300 km out delivers ≈ 97.1 %; plus a **no-load auxiliary load of 0.15 % P_max while energized** (so STATCOM service isn't free) |
| Q capability | onshore terminal ±0.40 · P_max **at any P, including zero wind** (STATCOM service — converters double as voltage support; the no-load auxiliary is its price) |
| Collector rule | farms bind to a platform within 2 tiles (100 km); Σ bound farm capacity ≤ platform rating |
| Reliability | forced outage ~1/yr per link/hub; **hub outages storm-correlated** (GAME_DESIGN §4.4) |
| Lifetime | 40 a (platform 30 a) |

Reference sanity check: a 2 GW hub 150 km offshore ≈ 800 + 300 + 350 M€ ≈
**1.45 B€** before farms — same order of magnitude as BorWin/2-GW-TenneT-
class projects, deliberately ~2/3 of 2026 actuals in line with the game's
overall cost level. **AC vs DC breakeven**: with per-km AC export (§1.5
catalog, ×2.2 ≈ 2.42 M€/km) vs a 500 MW farm's fair share of a
fully-subscribed 2 GW hub (≈ 287.5 M€ + 0.5 M€/km), breakeven lands at
**≈ 150 km — right at the AC export cap** (≤ 150 km, charging current):
near-shore AC is cheaper, far-shore is DC-only, and an under-subscribed hub
never pays. Authored, and shown in the build tooltip.

---

## 2. Frequency-response and protection system (Continental Europe scheme)

### 2.1 Reserve layers

| Layer | Implementation | Numbers |
|---|---|---|
| Inertia | Emergent from the online fleet: `E_k = Σ(H_i·S_i)` incl. grid-forming `H_v·S_j` | per-tech H above |
| FCR (primary) | Emergent from unit droops within contracted `fcr_band_mw`, delivered through each unit's own turbine dynamics | CE design: full activation at ±200 mHz, ≥50 % in 15 s, 100 % in 30 s; deadband ±10 mHz (nuclear ±20). Sizing rule shown to the player: FCR ≥ largest online infeed |
| aFRR (secondary) | Central PI per island (PHYSICS §2.8 AGC): textbook bias `B = Σ K_i + D·P_L0/f0` [MW/Hz] (ledger 19), `K_I = 1/120 s⁻¹`, anti-windup; distributed by participation factors, default ∝ contracted `afrr_band_mw` (overridable via `agc_participation`), each unit applying its own ramp limit | full restoration ≤ 15 min |
| mFRR (tertiary) | Game-side dispatch (player or auto merit order) in 15-min blocks | — |
| Load self-regulation | **1 %/Hz** on actual island load (config 1–2 %/Hz) | ENTSO-E value |
| LFSM-O | Mandatory, all generation incl. renewables: above **50.2 Hz** reduce at 5 % droop | RfG |
| LFSM-U | **Not modeled in v1** (ledger 22): headroom release beyond the FCR band is covered by aFRR/mFRR dispatch; listed in the honesty sections. (Real RfG mandates it; adding it would invalidate the §2.3 pins.) | — |

### 2.2 Defense plan and protection thresholds (per island; mechanics in PHYSICS §2.7)

| Frequency | Action |
|---|---|
| 49.8 Hz | **Alarm state**: all reserves activated, UI red banner, market suspension event |
| 49.7 Hz | Automatic pump shedding (all PHS pumping trips) |
| 49.6 Hz | Automatic electrolyzer shedding (interruptible tier) |
| 49.0 Hz | UFLS stage 1: shed 7.5 % of island load (150 ms pickup) |
| 48.8 Hz | UFLS stage 2: +7.5 % (cum 15 %) |
| 48.6 Hz | UFLS stage 3: +7.5 % (cum 22.5 %) |
| 48.4 Hz | UFLS stage 4: +7.5 % (cum 30 %) |
| 48.2 Hz | UFLS stage 5: +7.5 % (cum 37.5 %) |
| 48.0 Hz | UFLS stage 6: +7.5 % (cum 45 %) |
| < 47.5 Hz | All synchronous generators trip (100 ms) → island blackout |
| > 50.2 Hz | LFSM-O active |
| > 51.5 Hz | Generator disconnection cascade → island blackout |
| Converters | ride through 47.5–51.5 Hz (RfG); trip outside |

UFLS sheds zone load fractionally (`supplied < 1`); restoration in 10 %
blocks, allowed only after f > 49.8 Hz for 5 min, ramped 1 %/10 s. Each stage
latches once per event (re-arm on restoration). Tripped plants restart per
their start times (hot).

**RoCoF feel table** (500 ms windowed):

| RoCoF | Effect |
|---|---|
| ≥ 0.1 Hz/s | "grid stress" UI warning |
| ≥ 0.5 Hz/s | 2 % of load-embedded distributed generation trips (legacy relays) — worsens the event |
| ≥ 1.0 Hz/s | 5 % embedded generation trips + alarm |
| ≥ 2.0 Hz/s | pole-slip risk: each sync unit trips with 20 % probability (drawn from the scenario `protection_seed` — deterministic per save); converters ride through |

**Embedded DG** (the base quantity for the ≥0.5/≥1.0 Hz/s rows):
`embedded_dg_frac = 0.15` — 15 % of each zone's current load is netted
embedded generation. The trip percentages apply to that quantity (a
≥0.5 Hz/s event raises island net load by 2 % × 0.15 ≈ 0.3 % of load);
latched per event, restored with load restoration; `rocof_dg_trip` event.

**Line/transformer overload protection** (evaluated at PF instants; mechanics
PHYSICS §2.7): instant trip at ≥ 150 % loading (next PF frame). Duty counter
while loading > 120 %: `duty += (loading% − 100) · Δt` [%·s]; trip at
`duty ≥ 3000 %·s` (= 60 s at 150 %, 100 s at 130 %). Decay
`duty −= 50 %·s per s` while loading < 100 %, floor 0.

### 2.3 Worked example (computed from this spec's models, dt = 5 ms)

Setup: 150 GW island (online rotating MVA ≈ load), 3 GW trip — **an exogenous
infeed loss with H = 0 (e.g. an HVDC import block or converter-coupled
infeed): the 150 GVA rotating fleet survives intact** (a synchronous-unit
trip would also remove its H·S and shift RoCoF by ~2 %, outside the pin
tolerance). Load damping 1500 MW/Hz, FCR 3000 MW with gain 15 GW/Hz through
an aggregate 8 s turbine lag, deadband ±10 mHz. Battery variant adds 1 GW GFL
BESS (K = 5 GW/Hz, T = 0.1 s, db ±10 mHz).

| Case | Initial RoCoF | Nadir | t(nadir) | f at 60 s | t to 49.8 alarm |
|---|---|---|---|---|---|
| H_sys = 5 s, FCR 3000 MW | **−0.100 Hz/s** | **49.50 Hz** | 12.3 s | 49.80 | 2.2 s |
| H_sys = 2 s, FCR 3000 MW | **−0.250 Hz/s** | **49.22 Hz** | 8.0 s | 49.81 | 0.9 s |
| H_sys = 2 s + 1 GW battery | −0.250 Hz/s | **49.57 Hz** | 5.3 s | 49.85 | 1.0 s |
| H_sys = 5 s + 1 GW battery | −0.100 Hz/s | 49.72 Hz | 7.3 s | 49.85 | 2.8 s |
| H_sys = 1.5 s, FCR only 1500 MW ("renewable weekend, reserves undersold") | −0.333 Hz/s | **48.77 Hz → UFLS stages 1+2 fire** | 12.1 s | ~49.0 pre-shed | 0.6 s |

The design teaches exactly the intended lesson: cutting inertia from 5 s to
2 s multiplies RoCoF ×2.5 and deepens the nadir by 280 mHz into near-UFLS
territory; 1 GW of fast battery response recovers 350 mHz of nadir *without
adding any inertia* (RoCoF unchanged — only grid-forming batteries fix RoCoF);
an under-reserved low-inertia system sheds load. Sizing corollary shown to the
player: a single 1600 MW unit in a young 20 GW grid at H = 3 s gives
RoCoF = 1600·50/(2·3·20000) = **0.67 Hz/s** on trip — "don't build one huge
plant in a small system". Pin this table as a known-answer test (±2 % on nadir
and RoCoF).

---

## 3. Weather / resource model (game-side, seeded, deterministic)

Generation models live game-side (family rule): the game computes `P_avail`
per farm from this model and sends it on the wire; the backend does physics.
All processes are seeded. Discretized exactly per game step Δ via AR(1):
`x(t+Δ) = x·e^(−Δ/τ) + 𝒩(0, σ_st²·(1 − e^(−2Δ/τ)))` — exact for any Δ, so
variable step sizes stay consistent.

### 3.1 Regions and targets

12 weather regions; cross-region correlation from centroid great-circle
distance: `ρ_wind = exp(−d/1200 km)`, `ρ_solar = exp(−d/900 km)`,
`ρ_temp = exp(−d/1500 km)`. Build each Σ once, Cholesky-factor, drive with
common standard-normal innovations.

| Region | Centroid | v̄100 on [m/s] | CF_on | v̄100 off | CF_off | k̄_c sum/win | CF_pv | T_year [°C] |
|---|---|---|---|---|---|---|---|---|
| Iberia | 40N, 4W | 6.5 | 0.25 | 8.5 | 0.38 | 0.75/0.55 | 0.18 | 15 |
| France | 47N, 2E | 6.8 | 0.26 | 9.0 | 0.42 | 0.65/0.40 | 0.14 | 12 |
| British Isles | 54N, 2W | 7.8 | 0.32 | 10.5 | 0.48 | 0.55/0.30 | 0.10 | 10 |
| DE-North/Benelux | 53N, 7E | 7.2 | 0.28 | 10.0 | 0.47 | 0.60/0.32 | 0.11 | 10 |
| DE-South/Alps | 48N, 10E | 5.8 | 0.21 | — | — | 0.62/0.38 | 0.12 | 9 |
| Italy | 42N, 13E | 6.0 | 0.22 | 7.5 | 0.30 | 0.72/0.50 | 0.16 | 15 |
| Scandinavia-S | 58N, 12E | 7.0 | 0.28 | 9.5 | 0.44 | 0.55/0.25 | 0.10 | 8 |
| Scandinavia-N | 65N, 18E | 7.3 | 0.30 | 9.8 | 0.45 | 0.50/0.20 | 0.09 | 2 |
| Poland-Baltic | 52N, 19E | 6.6 | 0.26 | 9.2 | 0.43 | 0.58/0.32 | 0.11 | 9 |
| Balkans | 44N, 21E | 5.9 | 0.22 | — | — | 0.68/0.45 | 0.14 | 12 |
| Greece-Aegean | 38N, 24E | 7.0 | 0.28 | 8.8 | 0.38 | 0.78/0.55 | 0.17 | 17 |
| East (RO/W-UA) | 47N, 26E | 6.2 | 0.23 | 8.5 | 0.37 | 0.65/0.42 | 0.14 | 10 |

### 3.2 Wind

```
z_r(t): multivariate OU, τ_syn = 40 h, stationary σ = 1, correlated via Σ_wind
v_r(t) = λ_r(t) · (−ln(1 − Φ(z_r)))^(1/k)          # Weibull quantile transform
k = 2.0 onshore, 2.2 offshore;  λ̄_r = v̄_r / Γ(1 + 1/k)   (Γ(1.5) = 0.8862)
λ_r(t) = λ̄_r · (1 + A_s·cos(2π(doy−15)/365)) · (1 + A_d·cos(2π(h_local−15)/24))
A_s = 0.18 north of 48N, 0.12 south (winter peak mid-Jan); A_d = 0.08 onshore, 0 offshore
per-farm local factor: (1 + ε_farm), ε OU with τ = 3 h, σ = 0.10
```

Farm power curve (per-unit, farm-smoothed): cut-in 3 m/s, rated 11 m/s
onshore / 10.5 offshore, cubic `p = ((v−3)/(v_r−3))³` between, cut-out 25 m/s
with restart at 22 m/s after 10 min hysteresis. Precompute the smoothed lookup
as the mean of p over v ± 1.5 m/s (multi-turbine smoothing) — this creates the
**storm shutdown cliff** (a front passes → the regional offshore fleet drops
out near-simultaneously, correlated because one z_r drives the region).

### 3.3 Solar

```
declination δ = 23.45°·sin(2π(284+doy)/365); sin α = sin φ sin δ + cos φ cos δ cos(hour angle)
GHI_clear = 1100 · max(0, sin α)^1.15  W/m²
clearness k_c = clamp(k̄_c(doy) + 0.25·y_r, 0.05, 1.0);  y_r: OU τ_c = 12 h, σ = 1, Σ_solar
k̄_c(doy): cosine interpolation between the winter and summer column values (table 3.1)
POA = GHI · tilt_gain(month): [1.40,1.30,1.20,1.10,1.05,1.00,1.02,1.10,1.20,1.30,1.40,1.45]
P_dc = P_stc · POA/1000 · (1 − 0.004·(T_cell − 25)),  T_cell = T_amb + 0.034·POA
P_ac = min(0.97·P_dc, P_ac_rated)     # DC/AC ratio 1.25
```

### 3.4 Dunkelflaute regime layer

Hidden 2-state Markov "anticyclonic gloom" regime over the NW macro-zone
(British Isles, DE-N/Benelux, France, DE-S, Scandinavia-S, Poland):
November–February entry probability **0.012/day**, exit 1/6 per day (mean
duration 6 days) → ≈ 1–2 events per winter of 4–10 days. While active: wind
scale λ × **0.35**, clearness × **0.6**, temperature −3 °C (raises heating
demand). This guarantees the flagship stress event even if the OU draw is
lucky; it rides on top of, not instead of, the correlated processes.

### 3.5 Temperature (feeds the game-side load model)

Per region: `T = T_year − A_T·cos(2π(doy−15)/365) + 4·sin(2π(h−9)/24) + u_r`,
`A_T = 9 °C` north of 48N / 7 °C south, `u_r` OU with τ = 24 h, σ = 3 °C,
correlation Σ_temp.

---

## 4. Merit order (computed from §1 numbers)

Marginal cost `MC = fuel/η + VOM + EF/η·p_CO2` at full-load η.
**Default campaign-start CO2 price 30 €/t** (ETS ratchet is a campaign policy
lever, GAME_DESIGN §5):

| Tech | Fuel €/MWh | VOM | CO2 €/MWh | **MC €/MWh_el** |
|---|---|---|---|---|
| Wind / PV | 0 | 0–1.3 | 0 | **≈ 0–1.3** |
| Nuclear | 5.2 | 2.5 | 0 | **7.7** |
| Lignite | 9.3 | 5.0 | 27.9 | **42.2** |
| Hard coal | 26.7 | 4.5 | 22.7 | **53.8** |
| CCGT | 50.8 | 2.0 | 10.3 | **63.1** |
| OCGT | 75.0 | 3.0 | 15.2 | **93.2** |
| H2-CCGT | 131.6 | 2.0 | 0 | **133.6** |
| H2-OCGT | 197.4 | 3.0 | 0 | **200.4** |

→ nuclear < lignite < coal < CCGT < OCGT emerges as required. At the realistic
2026 ETS level of **85 €/t** the order inverts to nuclear (7.7) < CCGT (81.9)
< lignite (93.4) < coal (95.4) < OCGT (120.9) — the coal-to-gas switch, an
intended campaign policy lever, not a bug. Storage bids at opportunity cost
(game-side dispatch); the H2 fuel value is endogenous (§1.6).

---

## 5. Wire-level notes (details: docs/contract/v2.md)

- Device params at `/gb/net/reset` (names match the contract draft, the wire
  authority): `h_s` (override), `droop`, `deadband_hz`, `fcr_band_mw`,
  `afrr_band_mw`, `h_v_s` (grid-forming is the `grid_forming` device *kind*,
  not a flag), `e_mwh`, `soc`, `eta_full`, `eta_min`, `p_min_mw`,
  `ramp_pct_min`, `fuel` (`ng|h2|coal|lignite|uranium`), `x_h2`,
  `h2_store_id`.
- Step result: per-island frequency block + trajectory + events (PHYSICS §5).
- Violation kinds: `freq_alarm`, `ufls_stage`, `gen_trip_uf`, `gen_trip_of`,
  `rocof_dg_trip`, `island_blackout`, `fcr_exhausted`, `gfm_overload`,
  `fuel_starved`, `storage_empty|full`, `clamped` (+ family loading/voltage
  kinds). Voltage bands are TRANSMISSION practice (base 380 kV): warning
  outside [0.93, 1.08] pu, critical outside [0.90, 1.105] pu — 420 kV
  (1.105) is the ENTSO-E continuous limit, so 1.05-1.08 is normal
  operation, not an alarm.
- Divergence and blackout are DATA (HTTP 200); the idempotent last-t cache
  returns **before** any SoC/state integration (family rule).

## 6. Honesty section

Uniform frequency per island (no inter-area oscillations, rotor angles,
transient/voltage stability, EMT); no AVR/excitation dynamics — voltage is
quasi-static between PF instants; UFLS/protection acts on island COI
frequency, not local; **LFSM-U is not modeled** (ledger 22); governor models
are reduced-order standards (IEEEG1/GAST/HYGOV-class), adequate for
nadir/RoCoF pedagogy, not PSS tuning. Document prominently (in-game too), and
pin §2.3 as a known-answer test.
