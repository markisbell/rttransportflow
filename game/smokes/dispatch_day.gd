extends SmokeBase
## --smoke=dispatch_day: a full simulated day under the GridCo dispatcher —
## nuclear base-loaded, gas peaking in the evening, the wholesale price
## higher in the peak window than at night (window assertions, not instants).

const TAG := "SMOKE_DISPATCH_DAY"


func gridco_boot() -> bool:
	SidecarManager.configure(SMOKE_PORT)
	SidecarManager.start_all()
	if not await _wait_healthy(120.0):
		_fail(TAG, "health timeout")
		return false
	if not BuildSession.load_map():
		_fail(TAG, "map load failed")
		return false
	Weather.setup(42)
	Demand.setup(42)
	Demand.weather = Weather
	Dispatch.setup(BuildSession.load_repo_json("data/catalogs/economy.json"),
		BuildSession.load_repo_json("data/catalogs/plant_types.json").get("kinds", {}))
	Economy.setup(BuildSession.load_repo_json("data/catalogs/economy.json"))
	BuildSession.use_gridco = true
	if not await CosimBridge.handshake(Orchestrator.ID):
		_fail(TAG, "handshake failed")
		return false
	return true


func run() -> void:
	if not await gridco_boot():
		return
	DemoBuild.auto_build(World)
	BuildSession.rebuild_now()
	var status: Array = await BuildSession.build_status
	if not check("build_registered", bool(status[0])):
		_fail(TAG, "build failed: %s" % str(status[1]))
		return
	Orchestrator.stop()

	# one simulated day in 96 x 900 s steps; sample dispatch per block
	var nuclear_factors: Array[float] = []
	var gas_by_block: Array[float] = []
	var price_by_block: Array[float] = []
	var failures := 0
	for _block in range(96):
		if _block % 16 == 0:
			print("DISPATCH_DAY block ", _block)  # progress: ~2-6 s wall per block
		var result: Dictionary = await Orchestrator.step_once(900.0)
		if result.get("_status", 0) != 200:
			failures += 1
			continue
		price_by_block.append(Dispatch.wholesale_price)
		var gas_mw := 0.0
		for pid: String in result.get("devices", {}):
			var device: Dictionary = result["devices"][pid]
			var p: float = numf(device, "p_mw", 0.0)
			if pid.begins_with("nuclear") and str(device.get("state", "")) == "online":
				var p_max: float = World.plants.get(pid, {}).get("p_max_mw", 1600.0)
				nuclear_factors.append(p / p_max)
			elif pid.begins_with("gas_") and str(device.get("state", "")) == "online":
				gas_mw += p
		gas_by_block.append(gas_mw)

	check("no_transport_failures", failures == 0)
	check("full_day", price_by_block.size() == 96)

	# nuclear base-loaded: mean factor high, never below half load
	if nuclear_factors.is_empty():
		check("nuclear_present", false)
	else:
		var mean := 0.0
		var minimum := 1.0
		for f: float in nuclear_factors:
			mean += f
			minimum = minf(minimum, f)
		mean /= nuclear_factors.size()
		check("nuclear_present", true)
		check("nuclear_base_loaded_mean", mean > 0.7)
		check("nuclear_never_cycled_low", minimum > 0.4)

	# gas peaks in the evening window (17:00-21:00 = blocks 68..84) vs night
	var evening_gas := _window_mean(gas_by_block, 68, 84)
	var night_gas := _window_mean(gas_by_block, 4, 20)
	check("gas_peaking", evening_gas > night_gas * 1.15)

	# price: evening window above the night window (merit order at work)
	var evening_price := _window_mean(price_by_block, 68, 84)
	var night_price := _window_mean(price_by_block, 4, 20)
	check("price_scarcity_windows", evening_price > night_price)
	_finish(TAG, {"evening_gas": evening_gas, "night_gas": night_gas,
		"evening_price": evening_price, "night_price": night_price})


func _window_mean(values: Array[float], from_i: int, to_i: int) -> float:
	if values.size() <= to_i:
		return 0.0
	var total := 0.0
	for i in range(from_i, to_i):
		total += values[i]
	return total / (to_i - from_i)
