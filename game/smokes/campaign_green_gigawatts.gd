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

## Program quotas live in GridPlan (ERA_WIND_MW/ERA_SOLAR_MW/
## ERA_BATTERY_MW) since the C4 author_era extraction — one author.
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
	var quotas: Dictionary = GridPlan.author_re_program(World)
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
	_new_platform = GridPlan.author_hub_wave(World)
	if _new_platform == "":
		_fail(TAG, "hub wave failed (platform/farms/converter/cable)")
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


## The build passes live in GridPlan (author_re_program / author_hub_wave)
## since C4's author_era extraction — ONE author for the smoke's waves
## and the era recipes, so the worlds cannot drift apart. The smoke keeps
## its wave structure (the unlock gating is what IT proves); the
## discovery history (ledger-55 wall, Potemkin hub, isolation) is
## documented on the GridPlan functions.


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
