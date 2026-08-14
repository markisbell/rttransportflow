extends P7SmokeBase
## --smoke=north_sea_hub: far-shore North Sea integration (§1.16, ledger
## 27/28). Farms on DEEP sea bind to an offshore converter platform; the hub
## delivers their aggregated availability through the DC export path minus
## the two-station + cable losses as ONE injection at the onshore terminal.
## Tripping the hub removes the full delivery in one infeed-loss ΔP event —
## the exact opposite of the embedded-link trip in hvdc_link.gd.

const TAG := "SMOKE_NORTH_SEA_HUB"


func run() -> void:
	p7_port = 8037
	if not await p7_boot(TAG):
		return
	var built := _build()
	if built.is_empty():
		return
	var platform: String = built["platform"]
	var registered := await p7_register(TAG)
	if registered.is_empty():
		return

	p7_report(registered)
	var hub_params := {}
	for dev: Dictionary in registered.get("devices", []):
		if str(dev.get("kind", "")) == "offshore_hub":
			hub_params = dev.get("params", {})
	check("hub_registered", not hub_params.is_empty())
	var farms: Array = registered.get("hub_farms", {}).get(platform, [])
	check("farms_bound", farms.size() == 3)
	var loss_frac := 0.02 + 0.003 * float(hub_params.get("cable_km", 0.0)) / 100.0

	# NO wind force. The platform lands in the southern North Sea, whose
	# region already draws ~17.7 m/s offshore — above rated, so the farms sit
	# at full output on their own. The old x1.5 ramp pushed that draw to
	# 26.6 m/s, past the 25 m/s STORM CUTOUT, and the hub delivered exactly
	# zero: the smoke was testing a gale, not a windy day (PARAMETERS §1.9
	# cutout; the same trap the x1.8 comment warned about, reached at x1.5
	# once the 5 km map moved the platform into british_isles).
	var t0_days := GameClock.t_sim / 86400.0
	Weather.force_window("wind_lambda_scale", "", t0_days, t0_days + 2.0, 1.0)

	for _i in range(10):
		await p7_block("warmup")
	var steady: Dictionary = await p7_block("steady")
	_report_wind(platform)
	if steady.get("_status", 0) != 200:
		_fail(TAG, "steady step failed")
		return
	var delivered := numf(steady.get("devices", {}).get(platform, {}), "p_mw", 0.0)
	var avail_sent: float = float(Dispatch.last_avail.get(platform, 0.0))
	var ratio := delivered / avail_sent if avail_sent > 0.0 else 0.0
	print("HUB delivered=", delivered, " avail_sent=", avail_sent,
		" ratio=", ratio, " expected≈", 1.0 - loss_frac)
	check("wind_delivers", avail_sent > 300.0 and delivered > 250.0)
	check("losses_match_1_16", ratio >= 0.90 and ratio < 1.0)
	check("ratio_tracks_loss_model", absf(ratio - (1.0 - loss_frac)) < 0.03)

	# --- hub trip: ONE infeed-loss ΔP event ------------------------------
	Orchestrator.inject([{"at_s_rel": 30.0, "kind": "trip", "element": platform}])
	var f_min := 100.0
	var trip_step: Dictionary = await p7_step(600.0, "trip")
	if trip_step.get("_status", 0) == 200:
		f_min = minf(f_min, numf(trip_step.get("islands", {}).get("0", {}),
			"f_min", 100.0))
	var hub_dead := false
	for _i in range(30):
		var follow: Dictionary = await Orchestrator.step_once(1.0)
		if follow.get("_status", 0) != 200:
			continue
		f_min = minf(f_min, numf(follow.get("islands", {}).get("0", {}),
			"f_min", 100.0))
		var hub_dev: Dictionary = follow.get("devices", {}).get(platform, {})
		if str(hub_dev.get("state", "")) == "tripped" \
				and numf(hub_dev, "p_mw", 1.0) == 0.0:
			hub_dead = true
	print("HUB trip f_min=", f_min)
	check("hub_trip_removes_delivery", hub_dead)
	check("hub_trip_is_infeed_loss", f_min < 49.95)
	_finish(TAG, {"delivered": delivered, "avail_sent": avail_sent,
		"ratio": ratio, "loss_frac": loss_frac, "f_min_after_trip": f_min})


## Hamburg + thermal anchor; platform on the nearest DEEP-sea tile with
## 3 bound farms; onshore converter spurred into the city trunk; DC export
## corridor from the platform down to it.
## Why the hub is (or is not) delivering: bound farms, their weather region
## and its offshore CF — a storm CUTOUT and an unbound farm both read as
## "avail 0" on the wire and are otherwise indistinguishable.
func _report_wind(platform: String) -> void:
	var projection: Dictionary = BuildSession.map_projection()
	print("HUB farms=", Dispatch.hub_farms.get(platform, []),
		" avail=", Dispatch.last_avail.get(platform, "missing"))
	for farm_pid: String in Dispatch.hub_farms.get(platform, []):
		var farm: Dictionary = World.plants.get(farm_pid, {})
		var region := Weather.region_of_tile(farm.get("tile", Vector2i.ZERO),
			projection)
		print("HUB   ", farm_pid, " tile=", farm.get("tile"), " region=", region,
			" v_off=", Weather.wind_speed(region, true),
			" cf_off=", Weather.wind_cf(region, true))


func _build() -> Dictionary:
	World.clear_build()
	if not World.load_centers.has("hamburg"):
		_fail(TAG, "map has no hamburg")
		return {}
	var lc: Dictionary = World.load_centers["hamburg"]
	var anchor: Vector2i = lc["tiles"][0]
	var lc_tap := DemoBuild.tap_for(World, lc["tiles"])
	World.place_corridor(lc_tap)
	var avoid := foreign_avoid(["hamburg"])

	# platform: nearest deep-sea tile WITH room for 3 farms in its collector
	# ring (the closest S tile hugs the shelf edge — its ring is shallow)
	var platform_tile := Vector2i(-1, -1)
	var best_d := 1 << 30
	for y in range(World.height):
		for x in range(World.width):
			var tile := Vector2i(x, y)
			if World.terrain_at(tile) != "S":
				continue
			var deep_ring := 0
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if (dx != 0 or dy != 0) \
							and World.terrain_at(tile + Vector2i(dx, dy)) == "S":
						deep_ring += 1
			if deep_ring < 3:
				continue
			var d := absi(tile.x - anchor.x) + absi(tile.y - anchor.y)
			if d < best_d and World.can_place_plant("offshore_platform", tile):
				best_d = d
				platform_tile = tile
	if platform_tile == Vector2i(-1, -1):
		_fail(TAG, "no deep-sea platform site")
		return {}
	var platform: String = World.place_plant("offshore_platform", platform_tile)

	# 3 far-shore farms inside the collector ring (place platform first!)
	var farm_count := 0
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if farm_count >= 3 or (dx == 0 and dy == 0):
				continue
			var site := platform_tile + Vector2i(dx, dy)
			if World.terrain_at(site) == "S" \
					and World.can_place_plant("wind_offshore", site):
				if World.place_plant("wind_offshore", site) != "":
					farm_count += 1
	if farm_count < 3:
		_fail(TAG, "only %d far-shore farm sites" % farm_count)
		return {}

	var coal: Array[String] = place_ring("coal", 6, anchor, lc_tap, avoid)
	# two batteries absorb the wind-ramp transients (the P7 toolbox at work);
	# they cannot arrest the ~1.3 GW hub trip — that stays an infeed loss
	var bats: Array[String] = place_ring("battery", 2, anchor, lc_tap, avoid)
	if coal.size() < 6 or bats.size() < 2:
		_fail(TAG, "site exhaustion: coal=%d bats=%d" % [coal.size(), bats.size()])
		return {}
	# onshore converter DIRECTLY beside an existing AC corridor tile: the
	# corridor tile becomes its bus (touches-site rule) — no tap route, no
	# chance of overwriting the DC cable with an AC spur
	var conv_site := Vector2i(-1, -1)
	var ac_tiles: Array[Vector2i] = []
	for tile: Vector2i in World.corridors:
		if str(World.corridors[tile]) != "hvdc":
			ac_tiles.append(tile)
	ac_tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	for tile: Vector2i in ac_tiles:
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var cand: Vector2i = tile + offset
			if not World.can_place_plant("hvdc_converter", cand):
				continue
			var has_dc_exit := false
			for o2: Vector2i in GridTopology.NEIGHBORS:
				if _hvdc_free(cand + o2):
					has_dc_exit = true
			if has_dc_exit:
				conv_site = cand
				break
		if conv_site != Vector2i(-1, -1):
			break
	if conv_site == Vector2i(-1, -1):
		_fail(TAG, "no converter site beside the AC grid")
		return {}
	World.place_plant("hvdc_converter", conv_site)

	# DC export: platform -> onshore converter (BFS; any terrain)
	var dc_from := hvdc_neighbor(platform_tile)
	var dc_to := hvdc_neighbor(conv_site)
	if dc_from == Vector2i(-1, -1) or dc_to == Vector2i(-1, -1) \
			or not lay_hvdc(dc_from, dc_to):
		_fail(TAG, "could not lay the DC export corridor")
		return {}
	return {"platform": platform}
