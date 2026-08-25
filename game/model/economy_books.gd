extends Node
## EconomyBooks — GridCo's ledgers (GAME_DESIGN §3.4). Family principles:
## revenue bills DELIVERED MWh only (blackouts cost revenue), all costs come
## from SOLVED outputs and engine meters, never estimates. The wholesale
## price is a teaching KPI (Dispatch computes it), not the revenue source.

signal books_updated

var cfg: Dictionary = {}
var treasury_eur := 0.0
var loan_eur := 0.0

## cumulative books [EUR]
var revenue := 0.0
var fuel_cost := 0.0
var co2_cost := 0.0
var vom_cost := 0.0
var fom_cost := 0.0
var capex_spent := 0.0
var voll_penalty := 0.0
var reserve_income := 0.0
var redispatch_cost := 0.0
var penalty_cost := 0.0
## §4.7 cost axis (D2, ledger 51): the annuity is a KPI accumulator, NOT a
## treasury debit — capex was already paid in full on placement; charging
## the annuity to the treasury would pay twice. The campaign's cost window
## bills its time-share of this number.
var capex_annuity_eur := 0.0
## KPI accumulators
var delivered_mwh := 0.0
var unserved_mwh := 0.0
var co2_t := 0.0

var _pid_kind: Dictionary = {}  # plant id -> kind (from the registered native)
var _pid_fuel: Dictionary = {}  # per-plant fuel override (H2 conversions)
var _fom_billed_days := 0
var _last_redispatch_seen := 0.0


func setup(economy: Dictionary) -> void:
	cfg = economy
	treasury_eur = float(economy.get("start_treasury_meur", 0.0)) * 1e6
	World.plant_placed.connect(_on_plant_placed)
	World.corridor_placed.connect(_on_corridor_placed)
	World.substation_placed.connect(_on_substation_placed)
	Orchestrator.step_completed.connect(_on_step)


## Re-anchor the daily-billing counter to the CURRENT game day — called
## when a recipe moves the clock (start_day). Without it the first step
## after a day-12 recipe start would back-bill twelve days of FOM and
## annuity in one lump.
func sync_billing_day() -> void:
	_fom_billed_days = int(GameClock.t_sim / GameClock.SECONDS_PER_DAY)


func set_fleet(plants: Array, devices: Array = []) -> void:
	_pid_kind.clear()
	_pid_fuel.clear()
	for plant: Dictionary in plants:
		_pid_kind[str(plant["id"])] = str(plant["kind"])
		# a converted plant burns from its cavern — book H2, not pipeline gas
		if plant.has("fuel"):
			_pid_fuel[str(plant["id"])] = str(plant["fuel"])
	for dev: Dictionary in devices:
		var kind := str(dev.get("kind", ""))
		if kind == "grid_forming":
			kind = "battery"
		elif kind == "hvdc":
			kind = "hvdc_converter"
		elif kind == "offshore_hub":
			kind = "offshore_platform"
		elif kind == "h2_store":
			kind = "h2_cavern"
		_pid_kind[str(dev.get("id", ""))] = kind


# --- capex on placement (gameplay rule: pay when you build) ---------------

func _on_plant_placed(_pid: String, kind: String, p_max_mw: float) -> void:
	if kind == "h2_cavern":
		# leached volume, not nameplate MW: flat per-cavern price (§1.14)
		_spend_capex(float(cfg.get("h2_cavern_meur", 93.0)) * 1e6)
		return
	var eur_per_kw: float = (cfg["capex_eur_per_kw"] as Dictionary).get(kind, 0.0)
	_spend_capex(eur_per_kw * p_max_mw * 1000.0)


func _on_corridor_placed(tile: Vector2i, kind: String) -> void:
	var per_km: float = (cfg["line_cost_meur_per_km"] as Dictionary).get(kind, 1.0) * 1e6
	var terrain := World.terrain_at(tile)
	var terrain_factor: Dictionary = cfg.get("line_terrain_factor", {})
	var factor := 1.0
	if kind == "hvdc":
		# submarine export cable has its own §1.16 price; no AC sea factor
		if terrain == "s" or terrain == "S":
			per_km = float(cfg.get("hvdc_submarine_meur_per_km", 2.0)) * 1e6
	elif terrain == "s":
		factor = float(terrain_factor.get("submarine_ac", 2.2))  # GAME_DESIGN §1.5
	elif terrain == "m":
		factor = float(terrain_factor.get("mountain", 1.6))
	# the billed kilometre IS the solved kilometre: one sinuosity, shared
	# with the topology builder (tuning line routing can no longer leave
	# capex on the old routing model)
	_spend_capex(per_km * World.tile_km * GridTopology.SINUOSITY * factor)


func _on_substation_placed(_tile: Vector2i) -> void:
	_spend_capex(float(cfg.get("substation_meur", 15.0)) * 1e6)


func _spend_capex(eur: float) -> void:
	eur *= Sandbox.knob("capex")
	capex_spent += eur
	treasury_eur -= eur
	books_updated.emit()


## Regulatory fines (§4.7 penalties axis — D2, ledger 51): a books
## category, not a raw treasury debit, so the campaign's cost window and
## the KPI panel can see them.
func book_penalty(eur: float) -> void:
	penalty_cost += eur
	treasury_eur -= eur
	books_updated.emit()


# --- per-step operating books --------------------------------------------

func _on_step(_t: int, result: Dictionary) -> void:
	var dt_h := float(result.get("dt_done_s", 0.0)) / 3600.0
	if dt_h <= 0.0:
		return
	# GAME time, not the wire's t_sim_end: the ENGINE clock restarts at 0
	# on every rebuild-triggered net/reset, so engine days would price the
	# wrong demand day for revenue and stall the daily FOM/annuity counter
	# forever after the player's first build (C1 review). GameClock has
	# already advanced to the step's end when step_completed fires — in a
	# rebuild-free run the two clocks are identical.
	var t_days := GameClock.t_sim / GameClock.SECONDS_PER_DAY
	var tariff := float(cfg.get("tariff_eur_per_mwh", 95.0))
	# unserved energy is priced by the difficulty knob (§5.3): the physics
	# of a blackout never changes, only what it costs GridCo
	var voll := float(cfg.get("voll_eur_per_mwh", 3000.0)) \
		* Sandbox.knob("voll_scale")

	for zone_id: String in result.get("zones", {}):
		var supplied: Variant = result["zones"][zone_id].get("supplied", 0.0)
		var frac: float = 0.0 if supplied == null else float(supplied)
		var zone_mwh: float = Demand.zone_mw(zone_id, t_days) * dt_h
		revenue += frac * zone_mwh * tariff
		treasury_eur += frac * zone_mwh * tariff
		delivered_mwh += frac * zone_mwh
		var lost := (1.0 - frac) * zone_mwh
		unserved_mwh += lost
		voll_penalty += lost * voll
		treasury_eur -= lost * voll

	for pid: String in result.get("devices", {}):
		var device: Dictionary = result["devices"][pid]
		var kind := str(_pid_kind.get(pid, ""))
		if kind == "":
			continue
		var energy: Variant = device.get("energy_mwh_step", 0.0)
		var fuel_th: Variant = device.get("fuel_mwh_th_step", 0.0)
		var energy_mwh: float = 0.0 if energy == null else float(energy)
		var fuel_mwh: float = 0.0 if fuel_th == null else float(fuel_th)
		var vom: float = (cfg["vom_eur_per_mwh"] as Dictionary).get(kind, 0.0)
		vom_cost += energy_mwh * vom
		treasury_eur -= energy_mwh * vom
		var fuel := str(_pid_fuel.get(pid,
			(Dispatch.plant_catalog.get(kind, {}) as Dictionary).get("fuel", "")))
		if fuel != "" and fuel != "<null>":
			var fuel_price: float = (cfg["fuel_eur_per_mwh_th"] as Dictionary).get(fuel, 0.0)
			var ef: float = (cfg["co2_t_per_mwh_th"] as Dictionary).get(fuel, 0.0)
			fuel_cost += fuel_mwh * fuel_price
			co2_cost += fuel_mwh * ef * float(cfg["co2_eur_per_t"])
			co2_t += fuel_mwh * ef
			treasury_eur -= fuel_mwh * fuel_price + fuel_mwh * ef * float(cfg["co2_eur_per_t"])

	# reserve remuneration (regulator pays for procured FCR/aFRR headroom)
	var island: Dictionary = result.get("islands", {}).get("0", {})
	var s_online: Variant = island.get("s_online_mva", 0.0)
	if s_online != null and float(s_online) > 0.0:
		var fcr_mw := float(cfg.get("reserve_margin_mw_min", 3000.0))
		reserve_income += fcr_mw * dt_h * float(cfg.get("fcr_eur_per_mw_h", 8.0))
		treasury_eur += fcr_mw * dt_h * float(cfg.get("fcr_eur_per_mw_h", 8.0))

	# redispatch cost (accrued by Dispatch, booked here once)
	var redispatch_delta: float = Dispatch.redispatch_cost_eur - _last_redispatch_seen
	if redispatch_delta > 0.0:
		redispatch_cost += redispatch_delta
		treasury_eur -= redispatch_delta
		_last_redispatch_seen = Dispatch.redispatch_cost_eur

	# daily fixed O&M + loan interest
	var day := int(t_days)
	if day > _fom_billed_days:
		_bill_fom(day - _fom_billed_days)
		_fom_billed_days = day
	books_updated.emit()


func _bill_fom(days: int) -> void:
	var daily := 0.0
	for pid: String in _pid_kind:
		var kind: String = _pid_kind[pid]
		if kind == "h2_cavern":  # flat per-cavern FOM (1.5 % capex/a, §1.14)
			daily += float(cfg.get("h2_cavern_fom_meur_a", 1.4)) * 1e6 / 365.0
			continue
		var p_max: float = World.plants.get(pid, {}).get("p_max_mw", 0.0)
		daily += (cfg["fom_eur_per_kw_a"] as Dictionary).get(kind, 0.0) * p_max * 1000.0 / 365.0
	fom_cost += daily * days
	treasury_eur -= daily * days
	# same daily convention as FOM (/365 of the annual figure per sim-day)
	capex_annuity_eur += capex_spent * _annuity_factor() / 365.0 * days
	if treasury_eur < 0.0:
		var interest: float = -treasury_eur * float(cfg.get("loan_rate_per_a", 0.04)) / 365.0 * days
		loan_eur += interest
		treasury_eur -= interest


## Annuity factor r/(1-(1+r)^-n) from economy.json's capex_annuity block
## (D2 default 6 %/25 a → ≈ 0.0782/a).
func _annuity_factor() -> float:
	var block: Dictionary = cfg.get("capex_annuity", {})
	var r := float(block.get("rate_per_a", 0.06))
	var n := float(block.get("years", 25))
	if r <= 0.0:
		return 1.0 / maxf(n, 1.0)
	return r / (1.0 - pow(1.0 + r, -n))


func avg_cost_eur_per_mwh() -> float:
	if delivered_mwh <= 0.0:
		return 0.0
	return (fuel_cost + co2_cost + vom_cost + fom_cost + voll_penalty
		+ redispatch_cost) / delivered_mwh


func g_co2_per_kwh() -> float:
	if delivered_mwh <= 0.0:
		return 0.0
	return co2_t * 1e6 / (delivered_mwh * 1000.0)


# ---------------------------------------------------------------- save/load

func to_dict() -> Dictionary:
	return {
		"treasury_eur": treasury_eur, "loan_eur": loan_eur,
		"revenue": revenue, "fuel_cost": fuel_cost, "co2_cost": co2_cost,
		"vom_cost": vom_cost, "fom_cost": fom_cost, "capex_spent": capex_spent,
		"voll_penalty": voll_penalty, "reserve_income": reserve_income,
		"redispatch_cost": redispatch_cost, "delivered_mwh": delivered_mwh,
		"unserved_mwh": unserved_mwh, "co2_t": co2_t,
		"penalty_cost": penalty_cost, "capex_annuity_eur": capex_annuity_eur,
		"fom_billed_days": _fom_billed_days,
		"last_redispatch_seen": _last_redispatch_seen,
	}


func from_dict(state: Dictionary) -> void:
	treasury_eur = float(state.get("treasury_eur", treasury_eur))
	loan_eur = float(state.get("loan_eur", 0.0))
	revenue = float(state.get("revenue", 0.0))
	fuel_cost = float(state.get("fuel_cost", 0.0))
	co2_cost = float(state.get("co2_cost", 0.0))
	vom_cost = float(state.get("vom_cost", 0.0))
	fom_cost = float(state.get("fom_cost", 0.0))
	capex_spent = float(state.get("capex_spent", 0.0))
	voll_penalty = float(state.get("voll_penalty", 0.0))
	reserve_income = float(state.get("reserve_income", 0.0))
	redispatch_cost = float(state.get("redispatch_cost", 0.0))
	delivered_mwh = float(state.get("delivered_mwh", 0.0))
	unserved_mwh = float(state.get("unserved_mwh", 0.0))
	co2_t = float(state.get("co2_t", 0.0))
	penalty_cost = float(state.get("penalty_cost", 0.0))
	capex_annuity_eur = float(state.get("capex_annuity_eur", 0.0))
	_fom_billed_days = int(state.get("fom_billed_days", 0))
	_last_redispatch_seen = float(state.get("last_redispatch_seen", 0.0))
