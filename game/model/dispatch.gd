extends Node
## Dispatch — the GridCo dispatcher (GAME_DESIGN §3.3): heuristic commitment
## + merit-order dispatch + reserve withholding + overload redispatch. Runs
## once per 15-min sim boundary; NO MILP, no per-step micromanagement. The
## AC solve remains the feasibility truth (backend).
##
## P6 simplifications (documented): startup cost uses one warm value;
## min-up/down enforcement is left to the engine's physical start sequences;
## FCR withholding is a flat 8 % headroom cap on committed thermal.

signal dispatched(t_block: int, price: float, commands: Dictionary)

const BLOCK_S := 900.0
const HEADROOM_FRAC := 0.92  # committed thermal capped here (reserve withheld)
const LOSS_MARGIN := 1.015

var economy_cfg: Dictionary = {}
var plant_catalog: Dictionary = {}
var wholesale_price := 0.0
var scarcity := false
var redispatch_cost_eur := 0.0
var last_block := -1
var last_commands: Dictionary = {}
var last_avail: Dictionary = {}
var last_curtailed_mw := 0.0
## player strategy (GAME_DESIGN §3.3): pid -> auto|must_run|reserve_only|mothballed
var plant_mode: Dictionary = {}
## P7 wire devices (reset `devices` channel) + hub -> bound-farm map, both
## set by Boundary.enable_gridco after each successful build registration.
var wire_devices: Array = []
var hub_farms: Dictionary = {}
## HVDC dispatcher mode is `manual` in v1: terminal pid -> setpoint MW
## (`auto` congestion relief is a P8+ refinement; documented deviation).
var link_setpoints: Dictionary = {}
## Flexibility LOAD commanded last block (electrolyzers + battery charging).
## Engine-side demand the zone ledger cannot see: without folding it back in,
## every commanded MW became an island deficit and the electrolyzers shed
## themselves at low frequency (found by the hydrogen_chain smoke).
var _flex_load_mw := 0.0
## Sticky flexibility states (hysteresis). Threshold-only switching limit-
## cycled: the ely's own load bumped the price over the threshold, switched
## it off, the price fell back, it switched on — ±600 MW every block until
## the island f-window-tripped (caught live by hydrogen_chain).
var _ely_on: Dictionary = {}
var _bat_charging: Dictionary = {}

var _mc_cache: Dictionary = {}


func setup(economy: Dictionary, catalog: Dictionary) -> void:
	economy_cfg = economy
	plant_catalog = catalog
	wire_devices = []
	hub_farms = {}
	link_setpoints = {}
	_ely_on.clear()
	_bat_charging.clear()
	_mc_cache.clear()


func marginal_cost(kind: String, fuel_override: String = "") -> float:
	var cache_key := kind + "|" + fuel_override
	if _mc_cache.has(cache_key):
		return _mc_cache[cache_key]
	var params: Dictionary = plant_catalog.get(kind, {})
	var vom: float = (economy_cfg["vom_eur_per_mwh"] as Dictionary).get(kind, 0.0)
	var mc := vom
	var fuel := fuel_override if fuel_override != "" else str(params.get("fuel", ""))
	if fuel != "" and fuel != "<null>" and params.get("eta_full", 0.0) > 0.0:
		var eta: float = params["eta_full"]
		var fuel_price: float = (economy_cfg["fuel_eur_per_mwh_th"] as Dictionary).get(fuel, 0.0)
		var ef: float = (economy_cfg["co2_t_per_mwh_th"] as Dictionary).get(fuel, 0.0)
		mc += fuel_price / eta + ef / eta * float(economy_cfg["co2_eur_per_t"])
	_mc_cache[cache_key] = mc
	return mc


## The per-block decision. `plants` = native plants doc entries (id, kind,
## p_max_mw, bus); `device_states` = backend devices block (state, p_mw);
## `zone_ids` = registered zones. Returns {device_commands, avail_mw}.
func decide(t_sim: float, plants: Array, device_states: Dictionary,
		zone_ids: Array, pf_lines: Dictionary, line_buses: Dictionary,
		plant_bus: Dictionary) -> Dictionary:
	var t_days := t_sim / 86400.0
	var demand_now := 0.0
	for zone_id: String in zone_ids:
		demand_now += Demand.zone_mw(zone_id, t_days)
	# fold in last block's flexibility loads (sample-and-hold, same pattern
	# as the PF loss feedback) so the merit order generates for them and
	# renewable curtailment leaves them room
	demand_now += _flex_load_mw

	# --- renewables: availability from weather, must-take -----------------
	var avail := {}
	var renewable_mw := 0.0
	var projection: Dictionary = BuildSession.map_projection()
	for plant: Dictionary in plants:
		var kind := str(plant["kind"])
		if kind in World.CONVERTER_KINDS:
			var tile: Vector2i = World.plants.get(str(plant["id"]), {}).get("tile", Vector2i.ZERO)
			# fixture maps carry no projection block — fall back to one region
			var region := "France" if projection.is_empty() \
				else Weather.region_of_tile(tile, projection)
			var cf := 0.0
			match kind:
				"wind_onshore":
					cf = Weather.wind_cf(region, false)
				"wind_offshore":
					cf = Weather.wind_cf(region, true)
				"solar_pv":
					cf = Weather.pv_cf(region)
			avail[str(plant["id"])] = snappedf(cf * float(plant["p_max_mw"]), 0.1)
			renewable_mw += avail[str(plant["id"])]

	# offshore hubs: ONE aggregated avail value per hub (bound farms are
	# game-side only — §1.16); the backend owns the path losses
	for hub_id: String in hub_farms:
		var hub_avail := 0.0
		for farm_pid: String in hub_farms[hub_id]:
			var farm: Dictionary = World.plants.get(farm_pid, {})
			if farm.is_empty():
				continue
			var region := "France" if projection.is_empty() \
				else Weather.region_of_tile(farm["tile"], projection)
			hub_avail += Weather.wind_cf(region, true) * float(farm["p_max_mw"])
		avail[hub_id] = snappedf(hub_avail, 0.1)
		renewable_mw += avail[hub_id]

	# --- thermal merit order ---------------------------------------------
	var thermal: Array[Dictionary] = []
	for plant: Dictionary in plants:
		var kind := str(plant["kind"])
		if kind in World.SYNC_KINDS and plant_mode.get(str(plant["id"]), "auto") != "mothballed":
			thermal.append({"id": str(plant["id"]), "kind": kind,
				"p_max": float(plant["p_max_mw"]),
				"mc": marginal_cost(kind, str(plant.get("fuel", "")))})
	thermal.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["mc"] < b["mc"] or (a["mc"] == b["mc"] and a["id"] < b["id"]))

	# forecast peak over the next 24 h (hourly samples of the demand model)
	var forecast_peak := demand_now
	for hour in range(1, 25):
		var total := 0.0
		for zone_id: String in zone_ids:
			# frozen-state forecast: must not advance the weather timeline
			total += Demand.zone_mw_forecast(zone_id, t_days + hour / 24.0)
		forecast_peak = maxf(forecast_peak, total)

	# --- commitment: cheapest-first until peak + reserve ------------------
	var largest_infeed := 0.0
	for entry: Dictionary in thermal:
		var state := str(device_states.get(entry["id"], {}).get("state", "online"))
		if state == "online":
			largest_infeed = maxf(largest_infeed, float(entry["p_max"]))
	var reserve: float = maxf(largest_infeed, float(economy_cfg["reserve_margin_mw_min"]))
	var need := forecast_peak * LOSS_MARGIN + reserve - renewable_mw * 0.5
	var commands := {}
	var committed_cap := 0.0
	var committed: Array[Dictionary] = []
	for entry: Dictionary in thermal:
		var pid: String = entry["id"]
		var state := str(device_states.get(pid, {}).get("state", "online"))
		var wanted: bool = committed_cap < need \
			or plant_mode.get(pid, "auto") == "must_run"
		if wanted:
			# count what a committed unit can actually DELIVER (the 8 %
			# FCR-headroom cap): raw-p_max accounting left every Europe-scale
			# evening ~5 % short — scarcity with the gas fleet never committed
			committed_cap += entry["p_max"] * HEADROOM_FRAC
			committed.append(entry)
			if state == "offline" or state == "tripped":
				commands[pid] = {"breaker": "close"}
		elif state == "online" and committed_cap > need * 1.15:
			commands[pid] = {"breaker": "open", "dispatch_mw": 0.0}

	# --- energy dispatch: merit order BETWEEN price tiers, PROPORTIONAL
	# within a tier. Greedy fill-to-cap commanded 5 nuclear units up and the
	# marginal one 611 MW down — the slew asymmetry (fast up, 19 min down)
	# built a ~570 MW surplus that tiny nuclear FCR bands could not hold and
	# the fleet tripped at 51.5 Hz (found by probe). Proportional tiers keep
	# per-unit deltas small.
	var losses: float = demand_now * 0.01
	var latest_pf: Dictionary = Orchestrator.latest().get("pf", {}).get("latest", {})
	if latest_pf.has("loss_mw") and latest_pf["loss_mw"] != null:
		losses = float(latest_pf["loss_mw"])
	var residual := maxf(demand_now + losses - renewable_mw, 0.0)
	var price := 0.0
	var i := 0
	while i < committed.size():
		var tier_mc: float = committed[i]["mc"]
		var j := i
		var tier: Array[Dictionary] = []
		var tier_cap := 0.0
		while j < committed.size() and committed[j]["mc"] == tier_mc:
			var entry: Dictionary = committed[j]
			var pid: String = entry["id"]
			var online_now := str(device_states.get(pid, {}).get("state", "online")) == "online"
			var cap: float = entry["p_max"] * HEADROOM_FRAC
			if not online_now or plant_mode.get(pid, "auto") == "reserve_only":
				cap = 0.0
			tier.append({"pid": pid, "cap": cap})
			tier_cap += cap
			j += 1
		var take_tier: float = clampf(residual, 0.0, tier_cap)
		var share := take_tier / tier_cap if tier_cap > 0.0 else 0.0
		for unit: Dictionary in tier:
			var command: Dictionary = commands.get(unit["pid"], {})
			command["dispatch_mw"] = snappedf(share * float(unit["cap"]), 0.1)
			commands[unit["pid"]] = command
		residual -= take_tier
		if take_tier > 0.0:
			price = maxf(price, tier_mc)
		i = j

	# --- surplus renewables: curtail pro-rata -----------------------------
	last_curtailed_mw = 0.0
	var surplus := renewable_mw - (demand_now + losses)
	if surplus > 0.0 and renewable_mw > 0.0:
		var keep := 1.0 - surplus / renewable_mw
		for pid: String in avail:
			var curtailed: float = avail[pid] * keep
			last_curtailed_mw += avail[pid] - curtailed
			var command: Dictionary = commands.get(pid, {})
			command["curtail_to_mw"] = snappedf(curtailed, 0.1)
			commands[pid] = command
		price = 0.0  # renewables set the price at surplus

	# --- scarcity pricing -------------------------------------------------
	scarcity = residual > 1.0
	if scarcity:
		price = float(economy_cfg["scarcity_price_cap_eur_per_mwh"])
	wholesale_price = price

	# --- flexibility toolbox (P7): price-signal arbitrage -----------------
	# batteries discharge into the gas tier and above, charge on cheap
	# blocks; electrolyzers soak cheap/surplus power into their cavern.
	# HVDC is `manual` in v1: player/scenario setpoints pass through.
	var flex_next := 0.0
	for dev: Dictionary in wire_devices:
		var did := str(dev.get("id", ""))
		var dev_params: Dictionary = dev.get("params", {})
		match str(dev.get("kind", "")):
			"battery", "grid_forming":
				var bat_max := float(dev_params.get("p_max_mw", 0.0))
				var was_charging: bool = bool(_bat_charging.get(did, false))
				var bat_cmd := 0.0
				# discharge only into genuine scarcity: a lower threshold let
				# a sustained expensive tier drain the fleet to its SoC floor
				# and the arrested MW vanished as one cliff (hydrogen_chain)
				if scarcity or price >= 200.0:
					bat_cmd = 0.8 * bat_max
				elif price <= (45.0 if was_charging else 15.0):
					bat_cmd = -0.5 * bat_max  # sticky through the self-bump
				_bat_charging[did] = bat_cmd < 0.0
				if bat_cmd < 0.0:
					flex_next += -bat_cmd  # charging is load next block
				commands[did] = {"dispatch_mw": snappedf(bat_cmd, 0.1)}
			"electrolyzer":
				var was_on: bool = bool(_ely_on.get(did, false))
				var run: bool = (not scarcity) \
					and price < (80.0 if was_on else 20.001)
				_ely_on[did] = run
				var ely_mw: float = float(dev_params.get("p_max_mw", 0.0)) if run else 0.0
				flex_next += ely_mw
				commands[did] = {"dispatch_mw": ely_mw}
	_flex_load_mw = flex_next
	for term_id: String in link_setpoints:
		var link_cmd: Dictionary = commands.get(term_id, {})
		link_cmd["dispatch_mw"] = float(link_setpoints[term_id])
		commands[term_id] = link_cmd

	if OS.get_environment("DISPATCH_DEBUG") != "":
		var n_online := 0
		var gas_committed := 0.0
		var gas_online := 0.0
		for entry: Dictionary in committed:
			var st := str(device_states.get(entry["id"], {}).get("state", "online"))
			if st == "online":
				n_online += 1
			if str(entry["kind"]).begins_with("gas_"):
				gas_committed += entry["p_max"]
				if st == "online":
					gas_online += entry["p_max"]
		print("DBG block=", int(t_sim / BLOCK_S), " demand=", int(demand_now),
			" renew=", int(renewable_mw), " peak_fc=", int(forecast_peak),
			" need=", int(need), " cap92=", int(committed_cap),
			" committed=", committed.size(), "/", thermal.size(),
			" online=", n_online, " gas_cmt=", int(gas_committed),
			" gas_onl=", int(gas_online), " residual=", int(residual),
			" price=", int(price))

	# --- redispatch heuristic on overloads --------------------------------
	_redispatch(commands, pf_lines, line_buses, plant_bus, thermal, device_states)

	last_commands = commands
	last_avail = avail
	dispatched.emit(int(t_sim / BLOCK_S), price, commands)
	return {"device_commands": commands, "avail_mw": avail}


## Raise the cheapest unit at the importing bus, lower the costliest at the
## exporting bus (GAME_DESIGN §3.3 step 5); cost booked for Economy.
func _redispatch(commands: Dictionary, pf_lines: Dictionary,
		line_buses: Dictionary, plant_bus: Dictionary,
		thermal: Array[Dictionary], device_states: Dictionary) -> void:
	for line_id: String in pf_lines:
		var loading: Variant = pf_lines[line_id].get("loading_percent", 0.0)
		if loading == null or float(loading) <= 100.0:
			continue
		var buses: Dictionary = line_buses.get(line_id, {})
		if buses.is_empty():
			continue
		var p_from: Variant = pf_lines[line_id].get("p_from_mw", 0.0)
		var exporting := str(buses["from"]) if float(p_from if p_from != null else 0.0) >= 0.0 else str(buses["to"])
		var importing := str(buses["to"]) if exporting == str(buses["from"]) else str(buses["from"])
		var delta := float(pf_lines[line_id].get("loading_percent", 100.0)) - 95.0
		var shift_mw := delta * 10.0  # crude MW-per-% heuristic; the next PF is the truth
		var cheapest_import: Dictionary = {}
		var priciest_export: Dictionary = {}
		for entry: Dictionary in thermal:
			var pid: String = entry["id"]
			if str(device_states.get(pid, {}).get("state", "")) != "online":
				continue
			if str(plant_bus.get(pid, "")) == importing \
					and (cheapest_import.is_empty() or entry["mc"] < cheapest_import["mc"]):
				cheapest_import = entry
			if str(plant_bus.get(pid, "")) == exporting \
					and (priciest_export.is_empty() or entry["mc"] > priciest_export["mc"]):
				priciest_export = entry
		if cheapest_import.is_empty() or priciest_export.is_empty():
			continue
		var up: Dictionary = commands.get(cheapest_import["id"], {})
		var down: Dictionary = commands.get(priciest_export["id"], {})
		up["dispatch_mw"] = snappedf(minf(float(up.get("dispatch_mw", 0.0)) + shift_mw,
			float(cheapest_import["p_max"]) * HEADROOM_FRAC), 0.1)
		down["dispatch_mw"] = snappedf(maxf(float(down.get("dispatch_mw", 0.0)) - shift_mw, 0.0), 0.1)
		commands[cheapest_import["id"]] = up
		commands[priciest_export["id"]] = down
		redispatch_cost_eur += shift_mw * BLOCK_S / 3600.0 \
			* absf(float(cheapest_import["mc"]) - float(priciest_export["mc"]))
