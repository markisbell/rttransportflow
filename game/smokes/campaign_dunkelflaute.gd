extends P7SmokeBase
## --smoke=campaign_dunkelflaute: the C4 gate — milestone 4 (The
## Dunkelflaute) by scripted play from the dunkelflaute_2029 recipe
## (the first author_era world: start world + the C3-class build, one
## author). Episode SAIDI's FIRST execution: the scripted five-day
## calm-and-dark blankets NW Europe days 49–54, and the milestone grades
## Σ(1 − mean supplied) × minutes across it. The battery fleet enters
## the episode in "reserve_ffr" (the §3.3 policy shipping with this
## slice — SoC held for the dark evenings) and returns to "balanced"
## after; the smoke asserts the fleet actually ARRIVES charged
## (measured SoC, ledger 44). Stepping: fine 3×300 s across the episode
## and its staircased entry/exit (SAIDI is dt-weighted but the scarcity
## dispatch dynamics deserve block thirds), coarse 900 s elsewhere;
## window [48,60] closes at 60.0 → PINNED stars.

const TAG := "SMOKE_DUNKELFLAUTE"
## Star pin (family rule): set from the first measured run — reliability
## is M4's only axis (episode SAIDI: ★★★ < 5 min, ★★ < 30, ★ < 33).
const PINNED_STARS := 3
const FINE_FROM := 48.5  # staircase entry starts at 49.0; margin ahead
const FINE_TO := 54.6    # exit staircase ends ~54.0; margin behind

var _passed_id := ""
var _passed_stars := -1
var _failed_reason := ""
var _campaign_failed := ""


func run() -> void:
	if not await p7_boot(TAG):
		return
	if not Scenario.load_scenario("dunkelflaute_2029"):
		_fail(TAG, "dunkelflaute_2029 recipe failed to load")
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
	var registered := await p7_register(TAG)
	if registered.is_empty():
		return
	p7_report(registered)
	check("era_world_has_re", Campaign.re_capacity_mw() >= 24000.0)
	check("era_world_has_hubs", Campaign.hub_offshore_mw() >= 4000.0)

	# the designed play: hold the fleet's energy for the dark days
	Dispatch.set_battery_policy("reserve_ffr")
	check("policy_set", Dispatch.battery_policy == "reserve_ffr")

	var calls := 0
	var refused := 0
	var pre_wind := 0.0
	var pre_n := 0
	var episode_wind := 0.0
	var episode_n := 0
	var scarcity_blocks := 0
	var soc_at_entry := -1.0
	var min_treasury: float = Economy.treasury_eur
	var acc_snapshot := {}
	while Campaign.day_now() < 60.03 and calls < 2400:
		var day := Campaign.day_now()
		var result: Dictionary
		if day >= FINE_FROM and day < FINE_TO:
			result = await p7_block(TAG)
		else:
			result = await p7_step(900.0, TAG)
		calls += 1
		if result.get("_status", 0) != 200:
			refused += 1
			if refused >= 20:
				_fail(TAG, "backend deaf at day %.2f" % Campaign.day_now())
				return
			continue
		refused = 0
		day = Campaign.day_now()
		min_treasury = minf(min_treasury, Economy.treasury_eur)
		var wind := _wind_fleet_mw(result)
		if day >= 48.0 and day < 48.9:
			pre_wind += wind
			pre_n += 1
		elif day >= 49.5 and day < 53.5:
			episode_wind += wind
			episode_n += 1
			if Dispatch.scarcity:
				scarcity_blocks += 1
		if soc_at_entry < 0.0 and day >= 49.0:
			soc_at_entry = _fleet_mean_soc(result)
		if day >= 55.0 and Dispatch.battery_policy == "reserve_ffr":
			Dispatch.set_battery_policy("balanced")  # episode over — trade again
			print("DUNKEL policy back to balanced at day %.2f" % day)
		if calls % 96 < 1:
			print("DUNKEL day %.2f saidi=%.1f treasury=%.1fB wind=%.0f" % [day,
				float(Campaign.acc.get("episode_saidi_min", -1.0)),
				Economy.treasury_eur / 1e9, wind])
		if day >= 59.0 and day < 60.0:
			acc_snapshot = Campaign.acc.duplicate(true)
		if _passed_id != "" or _failed_reason != "" or _campaign_failed != "":
			break
	if Campaign.day_now() < 59.0 and _passed_id == "" \
			and _failed_reason == "" and _campaign_failed == "":
		_fail(TAG, "cap exhausted at day %.2f" % Campaign.day_now())
		return  # a campaign_failed break falls through to its own check

	var pre_mean := pre_wind / maxf(pre_n, 1.0)
	var episode_mean := episode_wind / maxf(episode_n, 1.0)
	var saidi := float(acc_snapshot.get("episode_saidi_min", 999.0))
	print("DUNKEL pre_wind=%.0f episode_wind=%.0f scarcity_blocks=%d saidi=%.2f soc_entry=%.2f min_treasury=%.2fB"
		% [pre_mean, episode_mean, scarcity_blocks, saidi, soc_at_entry,
		min_treasury / 1e9])
	check("episode_bites", episode_mean < pre_mean * 0.55)
	# MEASURED, then pinned (run 1): the 2029 reference world still
	# carries the FULL 2025 thermal fleet — retirement is M5's job — so a
	# 99.4 % wind collapse is a 13 % supply event the dispatchables cover
	# without ever pricing scarcity (0 blocks measured, SAIDI 0.0). The
	# plan's "scarcity blocks priced" bet was written for a leaner fleet;
	# M4's ECONOMIC bite belongs to post-retirement worlds (a C7+ truth),
	# while its physical bite is pinned above. A scarcity block appearing
	# HERE would mean the fleet or dispatcher regressed.
	check("no_scarcity_on_adequate_fleet", scarcity_blocks == 0)
	check("fleet_arrived_charged", soc_at_entry >= 0.5)
	check("saidi_measured", saidi < 900.0)
	check("treasury_survives", min_treasury > -1.0e9)
	check("autosave_written",
		FileAccess.file_exists(Campaign.autosave_file(3)))
	check("campaign_not_failed", _campaign_failed == "")
	check("milestone_passed", _passed_id == "dunkelflaute")
	check("not_failed", _failed_reason == "")
	check("stars_match_pin", _passed_stars == PINNED_STARS)
	_finish(TAG, {"stars": _passed_stars, "calls": calls,
		"saidi_min": saidi, "pre_wind": pre_mean, "episode_wind": episode_mean,
		"scarcity_blocks": scarcity_blocks, "soc_entry": soc_at_entry,
		"min_treasury_b": min_treasury / 1e9})


## Measured wind-fleet delivery [MW] from the step result (ledger 44).
func _wind_fleet_mw(result: Dictionary) -> float:
	var devices: Dictionary = result.get("devices", {})
	var total := 0.0
	for pid: String in World.plants:
		var kind := str(World.plants[pid]["kind"])
		if kind in ["wind_onshore", "wind_offshore", "offshore_platform"]:
			total += maxf(numf(devices.get(pid, {}), "p_mw", 0.0), 0.0)
	return total


func _fleet_mean_soc(result: Dictionary) -> float:
	var devices: Dictionary = result.get("devices", {})
	var total := 0.0
	var n := 0
	for pid: String in World.plants:
		if str(World.plants[pid]["kind"]) in ["battery", "grid_forming"]:
			var soc := numf(devices.get(pid, {}), "soc", -1.0)
			if soc >= 0.0:
				total += soc
				n += 1
	return total / n if n > 0 else -1.0
