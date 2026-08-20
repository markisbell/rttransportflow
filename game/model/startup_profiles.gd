class_name StartupProfiles
extends RefCounted
## The topology builder's START-UP operating point: the winter-day demand
## curve and the stub balanced dispatch that give a freshly registered grid
## a feasible first power flow (real dispatch is Dispatch, P6). Moved out of
## grid_topology.gd VERBATIM — build() mixed AC topology extraction,
## electrical sizing, profile AUTHORING and the device channel in one
## 754-line pipeline; the emitted native doc is byte-golden-pinned, so the
## extraction preserves construction order exactly.
##
## _home_zones resolves through GridTopology.nearest_zone (the ONE rule).


## Winter-workday demand shape (same curve family as europe_mini authoring).
static func _load_shape(step: int) -> float:
	var h := step / 4.0
	return 0.62 + 0.22 * exp(-pow(h - 9.5, 2) / 8.0) \
		+ 0.16 * exp(-pow(h - 13.0, 2) / 14.0) \
		+ 0.38 * exp(-pow(h - 18.5, 2) / 5.0)


static func _demand_profiles(world: Node, zone_ids: Array[String],
		demand_sampler: Callable = Callable()) -> Dictionary:
	# With a sampler (gridco mode) the native profiles COME FROM the live
	# demand model, so the backend resets onto the operating point the wire
	# will actually send — a stub-vs-live mismatch at t=0 collapsed a
	# winter grid before the first dispatch could ramp (found by probe).
	var out := {"total": []}
	var totals: Array[float] = []
	totals.resize(GridTopology.STEPS)
	totals.fill(0.0)
	for lc_id: String in zone_ids:
		var peak: float = world.load_centers[lc_id]["peak_mw"]
		var profile: Array[float] = []
		for step in range(GridTopology.STEPS):
			var value: float
			if demand_sampler.is_valid():
				value = snappedf(demand_sampler.call(lc_id, step), 0.1)
			else:
				value = snappedf(peak * _load_shape(step), 0.1)
			profile.append(value)
			totals[step] += value
		out[lc_id] = profile
	out["total"] = totals
	return out


## Stub balanced dispatch (real dispatch arrives in P6): must-take renewables
## + flat nuclear + dispatchables sharing the residual pro-rata (capped 92 %).
## Nearest metro for each plant, by tile distance. The START-UP operating
## point must be LOCAL: a global pro-rata split sends a city's supply across
## the whole network, and the first power flow after a reset hit 221 % on a
## trunk and instant-tripped it before the dispatcher had said a word.
static func _home_zones(world: Node, plant_ids: Array[String],
		zone_ids: Array[String]) -> Dictionary:
	var home := {}
	for pid: String in plant_ids:
		home[pid] = GridTopology.nearest_zone(world,
			world.plants[pid]["tile"], zone_ids)
	return home


static func _dispatch_profiles(world: Node, plant_ids: Array[String],
		total_load: Array[float], home_zones: Dictionary = {},
		demand: Dictionary = {}, zone_ids: Array[String] = []) -> Dictionary:
	var out := {}
	for pid: String in plant_ids:
		var profile: Array[float] = []
		profile.resize(GridTopology.STEPS)
		profile.fill(0.0)
		out[pid] = profile

	if not zone_ids.is_empty() and not home_zones.is_empty():
		for zone_id: String in zone_ids:
			var local: Array[String] = []
			for pid: String in plant_ids:
				if str(home_zones.get(pid, "")) == zone_id:
					local.append(pid)
			if local.is_empty():
				continue
			var zone_load: Array = demand[zone_id]
			var zone_total: Array[float] = []
			zone_total.resize(GridTopology.STEPS)
			for step in range(GridTopology.STEPS):
				zone_total[step] = float(zone_load[step])
			_fill_profiles(world, local, zone_total, out)
		# any plant with no metro of its own still shares the system load
		var orphans: Array[String] = []
		for pid: String in plant_ids:
			if not home_zones.has(pid):
				orphans.append(pid)
		if not orphans.is_empty():
			_fill_profiles(world, orphans, total_load, out)
		return out
	_fill_profiles(world, plant_ids, total_load, out)
	return out


## Balance one group of plants against one load series (must-take renewables
## + flat nuclear + dispatchables sharing the residual, capped at 92 %).
static func _fill_profiles(world: Node, plant_ids: Array[String],
		total_load: Array[float], out: Dictionary) -> void:
	for step in range(GridTopology.STEPS):
		var target: float = total_load[step] * Dispatch.loss_margin
		var fixed := 0.0
		var dispatchable_cap := 0.0
		var fixed_pids: Array[String] = []
		for pid: String in plant_ids:
			var p: Dictionary = world.plants[pid]
			var kind := str(p["kind"])
			var p_max: float = p["p_max_mw"]
			var value := 0.0
			match kind:
				"nuclear":
					value = 0.88 * p_max
				"solar_pv":
					var h := step / 4.0
					value = p_max * maxf(0.0, sin(PI * (h - 8.0) / 10.0)) if h >= 8.0 and h <= 18.0 else 0.0
				"wind_onshore", "wind_offshore":
					value = 0.55 * p_max
				_:
					dispatchable_cap += p_max
					continue
			out[pid][step] = snappedf(value, 0.1)
			fixed += out[pid][step]
			fixed_pids.append(pid)
		if fixed > target and fixed > 0.0:
			# Over-generation collapses the grid UPWARD (51.5 Hz trip cascade,
			# then blackout — found the hard way): scale must-run down so the
			# stub dispatch always balances.
			var scale := target / fixed
			for pid: String in fixed_pids:
				out[pid][step] = snappedf(out[pid][step] * scale, 0.1)
			fixed = target
		var residual := maxf(target - fixed, 0.0)
		if dispatchable_cap > 0.0:
			# ledger 30: the stub operating point uses the SAME deliverable
			# cap the live dispatcher schedules against (stub-vs-live mismatch
			# at t=0 collapsed a grid once — P6 discovery 3)
			var share := minf(residual / dispatchable_cap, Dispatch.headroom_frac)
			for pid: String in plant_ids:
				var p: Dictionary = world.plants[pid]
				if str(p["kind"]) in World.DISPATCHABLE_KINDS:
					out[pid][step] = snappedf(share * float(p["p_max_mw"]), 0.1)
