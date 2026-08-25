extends P7SmokeBase
## --smoke=campaign_merit_order: the C2 gate — milestone 2 (The Merit
## Order) by scripted play from the merit_order_2026 recipe, the arc's
## first mid-campaign start. Phase 1 carries days 12→17.5 in coarse 900 s
## blocks with the accumulators LIVE (a fixture that pre-seeds the window
## narrows the exam); phase 2 drives the graded span 17.5→24.03 as
## 3×300 s per block (zone_demand is sample-and-hold per wire step — the
## P9 morning-ramp lesson). Asserts: the day-18 ratchet actually reprices
## (CO2 30→60; coal's fleet share falls across the boundary, gas rises —
## M2's whole lesson), the D2 window cost lands in its band, the UFLS
## ceiling holds, and the PINNED stars.

const TAG := "SMOKE_MERIT_ORDER"
## Star pin (family rule: assert the exact deterministic outcome).
## Measured (run 4, the first full pass): cost ★★★ (52.76 €/MWh window
## avg — the ratchet flips coal's thermal share 0.97 → 0.33 and gas
## carries the evening) + reliability ★★ (2 UFLS incidents, exactly the
## pass ceiling; both auto-restore within minutes) = 5 of 6. A later
## drift is a finding to investigate, never a blind re-pin.
const PINNED_STARS := 5
## The D2 window-cost band [€/MWh]: brackets the measured value with the
## rubric's tier edges in mind (three ≤ 72). Windowed, never an instant.
const COST_MIN := 20.0
const COST_MAX := 72.0

var _passed_id := ""
var _passed_stars := -1
var _failed_reason := ""
var _campaign_failed := ""


func run() -> void:
	if not await p7_boot(TAG):
		return
	if not Scenario.load_scenario("merit_order_2026"):
		_fail(TAG, "merit_order_2026 recipe failed to load")
		return
	# a smoke run must never clobber the player's real retry point
	Campaign.autosave_path = "user://autosave_milestone_smoke.json"
	Campaign.milestone_passed.connect(func(id: String, stars: int) -> void:
		print("CAMPAIGN milestone_passed ", id, " stars ", stars)
		_passed_id = id
		_passed_stars = stars)
	Campaign.milestone_failed.connect(func(id: String, reason: String) -> void:
		print("CAMPAIGN milestone_failed ", id, " ", reason)
		_failed_reason = reason)
	# a hard failure state stops _on_step forever — unobserved, it reads
	# as a wall of unrelated failed checks (C2 review)
	Campaign.campaign_failed.connect(func(reason: String) -> void:
		print("CAMPAIGN campaign_failed ", reason, " day %.2f" % Campaign.day_now())
		_campaign_failed = reason)
	var built := await p7_register(TAG)
	if built.is_empty():
		return
	var start_day := Campaign.day_now()

	# thermal-share sampling brackets the day-18 ratchet symmetrically
	var coal_pre := 0.0
	var gas_pre := 0.0
	var pre_n := 0
	var coal_post := 0.0
	var gas_post := 0.0
	var post_n := 0
	var co2_before_ratchet := -1.0
	var window_cost := -1.0
	var acc_snapshot := {}
	var blocks := 0
	# hang guard, not the schedule (the take_the_reins lesson): the sim
	# loop runs on SIM TIME
	var refused := 0
	while Campaign.day_now() < 24.03 and blocks < 2800:
		var result: Dictionary
		if Campaign.day_now() < 17.5:
			result = await p7_step(900.0, TAG)  # step_checked: refusals PRINT
			blocks += 1
		else:
			result = await p7_block(TAG)
			blocks += 3
		# a deaf backend must fail in minutes, not ride the block cap for
		# hours (each refused 900 s step burns its 45 s deadline)
		refused = refused + 1 if result.get("_status", 0) != 200 else 0
		if refused >= 20:
			_fail(TAG, "backend deaf: 20 consecutive refused steps at day %.2f"
				% Campaign.day_now())
			return
		if blocks % 48 < (1 if Campaign.day_now() < 17.5 else 3):
			print("MERIT block ", blocks, " day %.2f cost %.1f" \
				% [Campaign.day_now(), Campaign._window_avg_cost()])
		if result.get("_status", 0) != 200:
			continue
		var day := Campaign.day_now()
		if day >= 16.0 and day < 18.0:
			var sample := _thermal_mw()
			coal_pre += sample.x
			gas_pre += sample.y
			pre_n += 1
		elif day >= 19.0 and day < 21.0:
			var sample := _thermal_mw()
			coal_post += sample.x
			gas_post += sample.y
			post_n += 1
		if day >= 17.4 and day < 17.9 and co2_before_ratchet < 0.0:
			co2_before_ratchet = float(Economy.cfg.get("co2_eur_per_t", -1.0))
		if day >= 23.0 and day < 24.0:
			window_cost = Campaign._window_avg_cost()
			acc_snapshot = Campaign.acc.duplicate(true)
		if _passed_id != "" or _failed_reason != "":
			break

	var coal_share_pre := coal_pre / maxf(coal_pre + gas_pre, 1.0)
	var coal_share_post := coal_post / maxf(coal_post + gas_post, 1.0)
	# 11.9: the recipe's ungraded cold-start settle stretch (see the
	# recipe's _why_start_day — run 1 measured UFLS stage 1 from the
	# startup-profile-vs-evening-demand gap landing INSIDE the window)
	check("recipe_starts_before_window", absf(start_day - 11.9) < 0.05)
	check("pre_ratchet_co2_30", co2_before_ratchet == 30.0)
	check("ratchet_repriced_to_60",
		float(Economy.cfg.get("co2_eur_per_t", 0.0)) == 60.0)
	check("thermal_sampled", pre_n > 0 and post_n > 0)
	check("coal_share_falls", coal_share_post < coal_share_pre)
	check("gas_mw_rises", gas_post / maxf(post_n, 1) > gas_pre / maxf(pre_n, 1))
	check("window_cost_in_band",
		window_cost > COST_MIN and window_cost < COST_MAX)
	check("ufls_within_pass", int(acc_snapshot.get("ufls_events", 99)) <= 2)
	check("no_blackouts", int(acc_snapshot.get("blackouts", 99)) == 0)
	# the window-open autosave must actually LAND mid-smoke — the C1 fake
	# bridge test could not see the live snapshot path (starvation hid
	# there until this run measured it)
	check("autosave_written",
		FileAccess.file_exists(Campaign.autosave_file(1)))
	check("campaign_not_failed", _campaign_failed == "")
	check("milestone_passed", _passed_id == "merit_order")
	check("not_failed", _failed_reason == "")
	check("stars_match_pin", _passed_stars == PINNED_STARS)
	_finish(TAG, {"stars": _passed_stars, "window_cost": window_cost,
		"coal_share_pre": coal_share_pre, "coal_share_post": coal_share_post,
		"blocks": blocks, "ufls": int(acc_snapshot.get("ufls_events", -1))})


## (coal+lignite, gas) fleet MW from the last wire result — measured,
## never commanded (ledger 44).
func _thermal_mw() -> Vector2:
	var devices: Dictionary = Orchestrator.latest().get("devices", {})
	var coal := 0.0
	var gas := 0.0
	for pid: String in World.plants:
		var kind := str(World.plants[pid]["kind"])
		var p := Wire.numf(devices.get(pid, {}), "p_mw", 0.0)
		if kind == "coal" or kind == "lignite":
			coal += maxf(p, 0.0)
		elif kind == "gas_ccgt" or kind == "gas_ocgt":
			gas += maxf(p, 0.0)
	return Vector2(coal, gas)
