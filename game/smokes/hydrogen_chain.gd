extends P7SmokeBase
## --smoke=hydrogen_chain: the full P7 causal chain on a Hamburg island —
## a forced WINDY day fills the cavern from surplus wind via electrolyzers
## (price at/near zero), then a forced CALM stretch burns it through the
## H2-converted CCGTs until the cavern hits its 5 % floor and the plants
## starve. Asserts the sequence AND the ≈ 35 % power-to-power round trip
## (PARAMETERS §1.14), kg-matched so the authored start level cancels out.

const TAG := "SMOKE_HYDROGEN_CHAIN"


func run() -> void:
	if not await p7_boot(TAG):
		return
	var built := _build()
	if built.is_empty():
		return
	var cavern: String = built["cavern"]
	var elys: Array = built["elys"]
	var h2_plants: Array = built["h2_plants"]
	var registered := await p7_register(TAG)
	if registered.is_empty():
		return
	var native_ids := {}
	for plant: Dictionary in registered["native"]["plants"]["plants"]:
		native_ids[str(plant["id"])] = str(plant.get("fuel", ""))
	for pid: String in h2_plants:
		if str(native_ids.get(pid, "")) != "h2":
			for warning: String in registered.get("warnings", []):
				print("H2CHAIN build warn: ", warning)
			_fail(TAG, "H2 plant %s missing/unconverted in the native doc" % pid)
			return

	# --- phase 1: forced windy day — surplus wind fills the cavern -------
	# RAMP the force in (8 blocks): an instant step outruns the thermal
	# down-ramp and over-frequency-trips a small island. Cap at x1.4 — x1.8
	# drove midday speeds past the 25 m/s CUTOUT and 6 GW of wind vanished
	# in one block (a cutout storm, not a windy day)
	var t0_days := GameClock.t_sim / 86400.0
	for i in range(8):
		Weather.force_window("wind_lambda_scale", "",
			t0_days + i / 96.0, t0_days + (i + 1) / 96.0, 1.0 + 0.05 * (i + 1))
	Weather.force_window("wind_lambda_scale", "", t0_days + 8 / 96.0,
		t0_days + 2.0, 1.4)
	var level_start := -1.0
	var level_after_fill := 0.0
	var ely_mwh := 0.0
	var inj_kg := 0.0
	var cheap_price_sum := 0.0
	var cheap_blocks := 0
	for block in range(96):
		var result: Dictionary = await Orchestrator.step_once(900.0)
		if result.get("_status", 0) != 200:
			continue
		var store: Dictionary = result.get("devices", {}).get(cavern, {})
		if level_start < 0.0:
			level_start = numf(store, "h2_kg", 0.0) \
				- numf(store, "injected_kg_step", 0.0)
		level_after_fill = numf(store, "h2_kg", 0.0)
		inj_kg += numf(store, "injected_kg_step", 0.0)
		var drew := 0.0
		for pid: String in elys:
			drew += numf(result.get("devices", {}).get(pid, {}),
				"energy_mwh_step", 0.0)
		ely_mwh += drew
		if drew > 1.0:
			cheap_price_sum += Dispatch.wholesale_price
			cheap_blocks += 1
		if block % 16 == 0:
			print("H2CHAIN fill block=", block, " level_t=",
				int(level_after_fill / 1000.0), " price=",
				int(Dispatch.wholesale_price))
		if level_after_fill > level_start + 130_000.0:
			break  # demonstrably filling; buffer covers the burn-to-floor leg
	check("cavern_fills", level_after_fill > level_start + 100_000.0)
	check("electrolyzers_ran", ely_mwh > 1_000.0)
	check("filled_while_cheap",
		cheap_blocks > 0 and cheap_price_sum / maxf(cheap_blocks, 1.0) <= 20.0)

	# --- phase 2: forced calm — the H2 fleet burns the cavern down -------
	Weather.clear_forces()
	var t1_days := GameClock.t_sim / 86400.0
	# LONG down-ramp (24 blocks): per-block avail changes land as INSTANT
	# steps on the wire, and the CF curve's steep zone turned a 2-block ramp
	# into ~1 GW cliffs that relayed the whole island out at t=8101 twice
	for i in range(24):
		Weather.force_window("wind_lambda_scale", "",
			t1_days + i / 96.0, t1_days + (i + 1) / 96.0, 1.4 - 0.04375 * (i + 1))
	Weather.force_window("wind_lambda_scale", "", t1_days + 24 / 96.0,
		t1_days + 4.0, 0.35)
	Weather.force_window("clearness_scale", "", t1_days, t1_days + 4.0, 0.5)
	var wd_kg := 0.0
	var h2_out_mwh := 0.0
	var level_end := level_after_fill
	var starved_seen := false
	for block in range(140):
		var result: Dictionary = await Orchestrator.step_once(900.0)
		if result.get("_status", 0) != 200:
			continue
		var store: Dictionary = result.get("devices", {}).get(cavern, {})
		wd_kg += numf(store, "withdrawn_kg_step", 0.0)
		inj_kg += numf(store, "injected_kg_step", 0.0)
		level_end = numf(store, "h2_kg", level_end)
		for pid: String in elys:
			ely_mwh += numf(result.get("devices", {}).get(pid, {}),
				"energy_mwh_step", 0.0)
		for pid: String in h2_plants:
			var device: Dictionary = result.get("devices", {}).get(pid, {})
			h2_out_mwh += numf(device, "energy_mwh_step", 0.0)
			if str(device.get("state", "")) == "starved":
				starved_seen = true
		for event: Dictionary in result.get("events", []):
			if str(event.get("kind", "")) == "fuel_starved":
				starved_seen = true
		if block % 16 == 0:
			var h2_dev: Dictionary = result.get("devices", {}).get(h2_plants[0], {})
			var isl: Dictionary = result.get("islands", {}).get("0", {})
			print("H2CHAIN burn block=", block, " level_t=",
				int(level_end / 1000.0), " wd_t=", int(wd_kg / 1000.0),
				" price=", int(Dispatch.wholesale_price),
				" h2p=", h2_dev.get("p_mw"), " h2state=", h2_dev.get("state"),
				" f=[", isl.get("f_min"), ",", isl.get("f_max"), "]",
				" ek=", isl.get("e_k_mj"))
			for event: Dictionary in result.get("events", []):
				print("H2CHAIN   ev ", event.get("t_sim"), " ", event.get("kind"),
					" ", event.get("element"), " ", event.get("data"))
		if starved_seen and wd_kg > 50_000.0:
			break
	check("h2_burns_in_calm", wd_kg > 50_000.0)
	check("cavern_depletes", level_end < level_after_fill - 50_000.0)
	check("plant_starves_at_floor", starved_seen)

	# --- round trip, kg-matched (independent of the authored start level):
	# out per WITHDRAWN kg over in per INJECTED kg ≈ η·LHV / η_spec ≈ 0.35-0.40
	var round_trip := 0.0
	if wd_kg > 0.0 and inj_kg > 0.0 and ely_mwh > 0.0:
		round_trip = (h2_out_mwh / wd_kg) / (ely_mwh / inj_kg)
	check("round_trip_about_35pct", round_trip > 0.25 and round_trip < 0.45)
	_finish(TAG, {"level_start_t": level_start / 1000.0,
		"level_filled_t": level_after_fill / 1000.0,
		"level_end_t": level_end / 1000.0,
		"ely_mwh": ely_mwh, "h2_out_mwh": h2_out_mwh,
		"round_trip": round_trip})


## Hamburg island: cavern + 2 electrolyzers + thin plain thermal + 2 CCGTs
## converted to H2 + a 1.5x-peak wind fleet. The plain thermal deliberately
## sits UNDER the calm-day demand so the (expensive) H2 tier dispatches.
func _build() -> Dictionary:
	World.clear_build()
	var lc_id := "hamburg"
	if not World.load_centers.has(lc_id):
		_fail(TAG, "map has no hamburg")
		return {}
	var lc: Dictionary = World.load_centers[lc_id]
	var anchor: Vector2i = lc["tiles"][0]
	var lc_tap := DemoBuild.tap_for(World, lc["tiles"])
	World.place_corridor(lc_tap)
	var avoid := foreign_avoid([lc_id])

	# cavern FIRST (its salt tile must not vanish under a corridor)
	var cavern_tile := Vector2i(-1, -1)
	var best_d := 1 << 30
	for tile: Vector2i in World.resources.get("salt_cavern", {}):
		var d: Vector2i = tile - anchor
		var manhattan := absi(d.x) + absi(d.y)
		if manhattan < best_d and World.can_place_plant("h2_cavern", tile):
			best_d = manhattan
			cavern_tile = tile
	if cavern_tile == Vector2i(-1, -1):
		_fail(TAG, "no placeable salt cavern near hamburg")
		return {}
	var cavern: String = World.place_plant("h2_cavern", cavern_tile)

	var elys: Array[String] = place_ring("electrolyzer", 2, anchor, lc_tap, avoid)
	# plain thermal is ONE tier (coal) sized so coal + H2 covers the calm
	# peak WITHOUT storage: the battery arbitrage policy discharges into a
	# sustained expensive tier until SoC-empty and then vanishes as a
	# ~480 MW cliff that trips the gas fleet (found the hard way here —
	# SoC-aware dispatch is a P8+ refinement, noted in the report)
	var coal: Array[String] = place_ring("coal", 5, anchor, lc_tap, avoid)
	var ccgt: Array[String] = place_ring("gas_ccgt", 2, anchor, lc_tap, avoid)
	# batteries eat the per-block wind steps (FFR); the scarcity-only
	# discharge policy keeps their SoC intact through the H2-tier burn
	var bats: Array[String] = place_ring("battery", 2, anchor, lc_tap, avoid)
	if elys.size() < 2 or coal.size() < 5 or ccgt.size() < 2 or bats.size() < 2:
		_fail(TAG, "site exhaustion: ely=%d coal=%d ccgt=%d bat=%d"
			% [elys.size(), coal.size(), ccgt.size(), bats.size()])
		return {}
	var h2_plants: Array[String] = [ccgt[0], ccgt[1]]
	for pid: String in h2_plants:
		if not World.convert_to_h2(pid, cavern):
			_fail(TAG, "convert_to_h2 failed for " + pid)
			return {}
	place_ring("wind_onshore", 30, anchor, lc_tap, avoid)  # 1.5x peak nameplate
	return {"cavern": cavern, "elys": elys, "h2_plants": h2_plants}
