extends P7SmokeBase
## --smoke=campaign_green_gigawatts: the C3 gate — milestone 3 (First
## Green Gigawatts) by scripted play from the green_gigawatts_2027
## recipe. The smoke IS the reference play: it builds the RE program and
## the hub commitment through the same World calls the UI makes, in two
## registration waves — day 28 (wind/solar/batteries, all 2027-open) and
## day 36+ (the platform program, gated on the LIVE unlock flip: G2's
## end-to-end proof, the first `year_changed` refresh mid-window).
## The scripted m3_congestion staircase (day 30–31, +35 % λ over the
## German Bight) must ride through with ZERO relay-outs; redispatch is
## measured, not assumed. Stepping is coarse 900 s except a fine 3×300 s
## band across the staircase (M2 measured coarse as artifact-free on
## this world). The window closes at day 48 → PINNED stars.
##
## Honesty notes: `redispatch_per_year` annualizes over the FULL window
## (2.0 years) while the recipe drives days 28–48 of [24,48] — the
## measured spend under-counts the base by ~1/6, in the LENIENT
## direction; revisit if the margin thins. On the authored ledgers-46/47
## corridors redispatch measures ZERO, so the cost axis is
## non-discriminative on this world — cost ★★★ here states that the
## authored grid carries M3's congestion, not that the player managed it
## (a C-era balancing note; it bites on player-built corridors). The
## battery pass places what the scarce substation ring offers (~900 of
## 3 000 MW) — reported, not asserted; the window holds zero-UFLS
## regardless. Each build wave is a full debounced reset (the P5
## design): the engine cold-starts at NOW (ledger 53) and battery SoCs
## reset — accepted, the player pays the same price. Hub execution is
## MEASURED, not committed (ledger 44): both platforms must register as
## offshore_hub devices and deliver during phase B — run 3 measured a
## silently dead "commitment" (converter tile claimed by its own cable,
## components fused with the inherited BorWin export) behind green
## placement checks.

const TAG := "SMOKE_GREEN_GIGAWATTS"
## Star pin (family rule): set from the first measured run — clean ★ from
## re_capacity (the program targets the ★★★ 24 GW tier with margin),
## cost ★ from redispatch/year. A later drift is a finding.
const PINNED_STARS := 6

## Program quotas [MW] — sized for ★★★ re_capacity (≥ 24 GW incl. the
## ~7.25 GW inherited base; batteries are NOT RE) plus adequacy
## batteries (the P3 FCR lesson: capacity without headroom is how the
## "fast" fleet sags).
const WIND_MW := 12000.0
const SOLAR_MW := 6000.0
const BATTERY_MW := 3000.0
const FINE_FROM := 29.0  # fine band: staircase baseline + event + exit
const FINE_TO := 31.5

var _passed_id := ""
var _passed_stars := -1
var _failed_reason := ""
var _campaign_failed := ""
var _flip_2028 := false  # the DAY-36 flip specifically — the boot emits a
# year_changed for 2027 too, which made a bare counter vacuous (review)
var _new_platform := ""


func run() -> void:
	if not await p7_boot(TAG):
		return
	if not Scenario.load_scenario("green_gigawatts_2027"):
		_fail(TAG, "green_gigawatts_2027 recipe failed to load")
		return
	Campaign.autosave_path = "user://autosave_milestone_smoke.json"
	Campaign.milestone_passed.connect(func(id: String, stars: int) -> void:
		print("CAMPAIGN milestone_passed ", id, " stars ", stars)
		_passed_id = id
		_passed_stars = stars)
	Campaign.milestone_failed.connect(func(id: String, reason: String) -> void:
		print("CAMPAIGN milestone_failed ", id, " ", reason)
		_failed_reason = reason)
	Campaign.campaign_failed.connect(func(reason: String) -> void:
		print("CAMPAIGN campaign_failed ", reason, " day %.2f" % Campaign.day_now())
		_campaign_failed = reason)
	Campaign.year_changed.connect(func(y: int) -> void:
		print("CAMPAIGN year_changed ", y, " day %.2f" % Campaign.day_now())
		if y == 2028:
			_flip_2028 = true)

	# the 2028 kinds must be LOCKED at the 2027 start — the flip is the test
	check("hub_locked_at_start", not Campaign.unlocked("offshore_platform"))
	check("hvdc_locked_at_start", not Campaign.unlocked("hvdc_converter"))

	# ---- wave 1 (day 28): the RE program through the UI's own calls ----
	var re_before := Campaign.re_capacity_mw()
	var quotas := _re_program()
	print("PROGRAM placed wind=%.0f solar=%.0f battery=%.0f (re before=%.0f after=%.0f)"
		% [quotas.get("wind", 0.0), quotas.get("solar", 0.0),
		quotas.get("battery", 0.0), re_before, Campaign.re_capacity_mw()])
	check("re_program_placed", Campaign.re_capacity_mw() >= 25000.0)
	var registered := await p7_register(TAG)
	if registered.is_empty():
		return
	p7_report(registered)
	check("re_registered", _registered_re_mw(registered) >= 20000.0)

	# ---- phase A: coarse to the fine band, staircase, coarse to day 36 --
	var calls := 0
	var refused := 0
	var line_trips := 0
	var baseline_loading := 0.0
	var event_loading := 0.0
	var redispatch_0: float = Economy.redispatch_cost
	var hub_locked_at_35 := false
	while Campaign.day_now() < 36.0 and calls < 1500:
		var result := await _step_for(Campaign.day_now())
		calls += 1
		if result.get("_status", 0) != 200:
			refused += 1
			if refused >= 20:
				_fail(TAG, "backend deaf at day %.2f" % Campaign.day_now())
				return
			continue
		refused = 0
		line_trips += _count_kind(result, "line_trip")
		var day := Campaign.day_now()
		# window_extremes, not pf.latest instants: intra-step peaks are
		# exactly what the extremes block exists to carry (review)
		var top := _max_loading(result)
		if day >= 29.0 and day < 29.9:
			baseline_loading = maxf(baseline_loading, top)
		elif day >= 30.1 and day < 31.1:
			event_loading = maxf(event_loading, top)
		if day >= 35.0 and day < 35.9 and not hub_locked_at_35:
			hub_locked_at_35 = not Campaign.unlocked("offshore_platform")
		if calls % 96 < 3:
			print("GGW day %.2f loading=%.1f redispatch=%.0f" % [day, top,
				Economy.redispatch_cost - redispatch_0])
		if _campaign_failed != "":
			break
	if Campaign.day_now() < 36.0:
		_fail(TAG, "phase A cap exhausted at day %.2f" % Campaign.day_now())
		return
	var event_redispatch: float = Economy.redispatch_cost - redispatch_0
	print("GGW staircase baseline=%.1f event=%.1f redispatch=%.0f trips=%d"
		% [baseline_loading, event_loading, event_redispatch, line_trips])
	check("hub_still_locked_at_35", hub_locked_at_35)
	check("congestion_bites", event_loading > baseline_loading + 2.0)
	check("zero_relay_outs", line_trips == 0)

	# ---- wave 2 (day 36+): the unlock flips LIVE, then the hub program --
	check("year_flip_observed", _flip_2028)
	check("hub_unlocked_after_36", Campaign.unlocked("offshore_platform")
		and Campaign.unlocked("hvdc_converter") and Campaign.unlocked("corridor_hvdc"))
	var hub_before := Campaign.hub_offshore_mw()
	if not _hub_program():
		return
	print("PROGRAM hub before=%.0f after=%.0f re=%.0f" % [hub_before,
		Campaign.hub_offshore_mw(), Campaign.re_capacity_mw()])
	check("hub_committed_4gw", Campaign.hub_offshore_mw() >= 4000.0)
	registered = await p7_register(TAG)
	if registered.is_empty():
		return
	p7_report(registered)
	# MEASURED, not committed (ledger 44 — the review's blocking find):
	# BOTH platforms must register as offshore_hub devices (a fused or
	# one-station DC component is silently dropped by the emitter), and
	# both must actually DELIVER during phase B.
	var hub_pids: Array[String] = []
	for dev: Dictionary in registered.get("devices", []):
		if str(dev.get("kind", "")) == "offshore_hub":
			hub_pids.append(str(dev.get("id", "")))
	check("both_hubs_registered", hub_pids.size() == 2)
	check("new_hub_registered", _new_platform in hub_pids)

	# ---- phase B: coarse to the window close --------------------------
	var acc_snapshot := {}
	var hub_max := {}
	for pid: String in hub_pids:
		hub_max[pid] = 0.0
	while Campaign.day_now() < 48.03 and calls < 2900:
		var result: Dictionary = await p7_step(900.0, TAG)
		calls += 1
		if result.get("_status", 0) != 200:
			refused += 1
			if refused >= 20:
				_fail(TAG, "backend deaf at day %.2f" % Campaign.day_now())
				return
			continue
		refused = 0
		line_trips += _count_kind(result, "line_trip")
		var day := Campaign.day_now()
		for pid: String in hub_pids:
			hub_max[pid] = maxf(hub_max[pid],
				numf(result.get("devices", {}).get(pid, {}), "p_mw", 0.0))
		if calls % 96 < 1:
			print("GGW day %.2f ufls=%d redispatch=%.0f" % [day,
				int(Campaign.acc.get("ufls_events", -1)),
				Economy.redispatch_cost - redispatch_0])
		if day >= 47.0 and day < 48.0:
			acc_snapshot = Campaign.acc.duplicate(true)
		if _passed_id != "" or _failed_reason != "" or _campaign_failed != "":
			break
	if Campaign.day_now() < 47.0 and _passed_id == "" and _failed_reason == "":
		_fail(TAG, "phase B cap exhausted at day %.2f" % Campaign.day_now())
		return

	print("GGW hub delivery maxima: ", hub_max)
	var hubs_delivering := 0
	for pid: String in hub_max:
		if float(hub_max[pid]) > 50.0:
			hubs_delivering += 1
	check("both_hubs_deliver", hubs_delivering == 2)
	var redispatch_total: float = Economy.redispatch_cost - redispatch_0
	check("zero_relay_outs_full_run", line_trips == 0)
	check("ufls_zero", int(acc_snapshot.get("ufls_events", 99)) == 0)
	check("no_blackouts", int(acc_snapshot.get("blackouts", 99)) == 0)
	check("campaign_not_failed", _campaign_failed == "")
	check("milestone_passed", _passed_id == "green_gigawatts")
	check("not_failed", _failed_reason == "")
	check("stars_match_pin", _passed_stars == PINNED_STARS)
	_finish(TAG, {"stars": _passed_stars, "calls": calls,
		"re_mw": Campaign.re_capacity_mw(), "hub_mw": Campaign.hub_offshore_mw(),
		"baseline_loading": baseline_loading, "event_loading": event_loading,
		"redispatch_eur": redispatch_total, "line_trips": line_trips,
		"hub_max": hub_max, "ufls": int(acc_snapshot.get("ufls_events", -1))})


func _step_for(day: float) -> Dictionary:
	if day >= FINE_FROM and day < FINE_TO:
		return await p7_block(TAG)  # demand ramps land in thirds (P9 lesson)
	return await p7_step(900.0, TAG)


## Units pack against EXISTING SUBSTATIONS so they join existing buses —
## the ledger-13 node budget has almost no headroom on the 145-bus
## realistic world, and run 1 re-learned ledger 47 the fast way:
## stride-scattered singles minted a lone tap bus each (234 buses,
## build refused). Wind takes the northern half, solar the southern
## (region CF reality), batteries ring the metros. Deterministic:
## substations walked in (y, x) order, at most two units per station
## for geographic spread.
func _re_program() -> Dictionary:
	var split_y := 0.0
	for lc_id: String in World.load_centers:
		var tiles: Array = World.load_centers[lc_id]["tiles"]
		split_y += float((tiles[0] as Vector2i).y)
	split_y /= maxf(World.load_centers.size(), 1.0)
	var stations: Array = []
	for tile: Vector2i in World.substations:
		stations.append(tile)
	stations.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	var placed := {"wind": 0.0, "solar": 0.0, "battery": 0.0}
	# pass 1: two units per station; pass 2 (if quotas remain): fill up
	for per_station in [2, 8]:
		if placed["wind"] >= WIND_MW and placed["solar"] >= SOLAR_MW:
			break
		for station: Vector2i in stations:
			if placed["wind"] >= WIND_MW and placed["solar"] >= SOLAR_MW:
				break
			var north: bool = float(station.y) < split_y
			var kind := "wind_onshore" if north else "solar_pv"
			var key := "wind" if north else "solar"
			var quota: float = WIND_MW if north else SOLAR_MW
			if placed[key] >= quota:
				continue
			var here := 0
			for offset: Vector2i in GridTopology.NEIGHBORS:
				if here >= per_station or placed[key] >= quota:
					break
				var site := station + offset
				if World.can_place_plant(kind, site):
					var pid := World.place_plant(kind, site)
					if pid != "":
						placed[key] += float(World.plants[pid]["p_max_mw"])
						here += 1
	# pass 3: the substation ring is SCARCE (the adequacy fleet already
	# rings the real stations — run 2 found only ~12 GW of free sides), so
	# the remainder mints bounded PARK TAPS on the trunk: one bus per tap,
	# up to 3 units each, hard-capped at 20 taps (~145 + 20 + hub ≈ 170
	# buses ≤ the ledger-55 180) — packed parks, never the 234-bus scatter
	var corridor_tiles: Array = []
	for tile: Vector2i in World.corridors:
		if str(World.corridors[tile]) == "line_400":
			corridor_tiles.append(tile)
	corridor_tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	var taps := 0
	var i := 0
	while i < corridor_tiles.size() and taps < 20 \
			and (placed["wind"] < WIND_MW or placed["solar"] < SOLAR_MW):
		var tap: Vector2i = corridor_tiles[i]
		i += 11  # stride: geographic spread
		var north: bool = float(tap.y) < split_y
		var kind := "wind_onshore" if north else "solar_pv"
		var key := "wind" if north else "solar"
		var quota: float = WIND_MW if north else SOLAR_MW
		if placed[key] >= quota:
			continue
		var here := 0
		for offset: Vector2i in GridTopology.NEIGHBORS:
			if here >= 3 or placed[key] >= quota:
				break
			var site := tap + offset
			if World.can_place_plant(kind, site):
				var pid := World.place_plant(kind, site)
				if pid != "":
					placed[key] += float(World.plants[pid]["p_max_mw"])
					here += 1
		if here > 0:
			taps += 1
	print("PROGRAM park taps minted: ", taps)
	# adequacy batteries against metro-adjacent substations (unlock 2027)
	for station: Vector2i in stations:
		if placed["battery"] >= BATTERY_MW:
			break
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var site := station + offset
			if World.can_place_plant("battery", site):
				var pid := World.place_plant("battery", site)
				if pid != "":
					placed["battery"] += float(World.plants[pid]["p_max_mw"])
				break
	return placed


## One more 2 GW platform beside the German Bight (the inherited BorWin
## platform carries the other 2 GW), three far-shore farms in its ring,
## the onshore converter FIRST beside an existing AC tile, then the DC
## export laid between free endpoints — the north_sea_hub recipe,
## executed on the campaign world.
func _hub_program() -> bool:
	if not World.load_centers.has("hamburg"):
		_fail(TAG, "map has no hamburg")
		return false
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
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
		return false
	var platform := World.place_plant("offshore_platform", platform_tile)
	var farms := 0
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if farms >= 3 or (dx == 0 and dy == 0):
				continue
			var site := platform_tile + Vector2i(dx, dy)
			if World.terrain_at(site) == "S" \
					and World.can_place_plant("wind_offshore", site):
				if World.place_plant("wind_offshore", site) != "":
					farms += 1
	if platform == "" or farms < 3:
		_fail(TAG, "hub program: platform=%s farms=%d" % [platform, farms])
		return false
	# Onshore converter DIRECTLY beside an existing AC corridor tile with a
	# verified DC exit — the north_sea_hub pattern, converter FIRST: run 3
	# laid the DC cable onto the converter's own site, the refused
	# place_plant went unchecked, the emitter dropped the one-station
	# component, and the free-routing cable had FUSED with the inherited
	# BorWin export — a silently dead 4 GW "commitment" (the review's
	# blocking find; the ledger-44 commanded-not-measured shape applied to
	# a build program). The AC tile becomes the converter's bus: no spur,
	# nothing to overwrite, and lay_hvdc's _hvdc_free predicate refuses
	# every existing corridor tile.
	# COASTAL converter: sorted by distance to the PLATFORM, not the metro
	# — the DC run stays ~tens of tiles of open sea (Diele's real shape),
	# and the corridor-excluding route BFS finds it before it can flood
	# (an inland converter behind the corridor maze hung two full runs:
	# the ledger-29 flood at 5 km scale, now also capped in route itself)
	var ac_tiles: Array[Vector2i] = []
	for tile: Vector2i in World.corridors:
		if str(World.corridors[tile]) != "hvdc":
			ac_tiles.append(tile)
	ac_tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := absi(a.x - platform_tile.x) + absi(a.y - platform_tile.y)
		var db := absi(b.x - platform_tile.x) + absi(b.y - platform_tile.y)
		return da < db or (da == db and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	var conv_site := Vector2i(-1, -1)
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
		return false
	if World.place_plant("hvdc_converter", conv_site) == "":
		_fail(TAG, "converter placement refused at %s" % str(conv_site))
		return false
	var dc_from := hvdc_neighbor(platform_tile)
	var dc_to := hvdc_neighbor(conv_site)
	if dc_from == Vector2i(-1, -1) or dc_to == Vector2i(-1, -1) \
			or not lay_hvdc(dc_from, dc_to):
		_fail(TAG, "could not lay the DC export corridor")
		return false
	_new_platform = platform
	return true


func _registered_re_mw(registered: Dictionary) -> float:
	var total := 0.0
	for plant: Dictionary in registered.get("native", {}) \
			.get("plants", {}).get("plants", []):
		if str(plant.get("kind", "")) in ["wind_onshore", "wind_offshore", "solar_pv"]:
			total += float(plant.get("p_max_mw", 0.0))
	return total


func _count_kind(result: Dictionary, kind: String) -> int:
	var n := 0
	for event: Dictionary in result.get("events", []):
		if str(event.get("kind", "")) == kind:
			n += 1
	return n


func _max_loading(result: Dictionary) -> float:
	# the step's PF window extremes — every solve inside the step, not the
	# last instant (the wire carries this block for exactly this purpose)
	var top := 0.0
	var extremes: Dictionary = (result.get("pf", {}) as Dictionary) \
		.get("window_extremes", {})
	for line_id: String in extremes:
		top = maxf(top, float(extremes[line_id]) if extremes[line_id] != null else 0.0)
	return top
