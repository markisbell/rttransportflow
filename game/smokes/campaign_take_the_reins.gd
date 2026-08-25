extends P7SmokeBase
## --smoke=campaign_take_the_reins: the ROADMAP P9 gate — milestone 1 by
## scripted play. Boots the inherited-2025 campaign world (start_2025.json),
## runs the compressed 2 months (2 sim-days of 900 s blocks), lets the
## campaign's scripted 1.2 GW trip fire from the event table, exercises the
## REAL replay-panel fetch path ("replay viewed"), and asserts the milestone
## verdict + the PINNED star score + campaign-state serialization identity.

const TAG := "SMOKE_CAMPAIGN"
## Star pin (family rule: assert the exact deterministic outcome). The 2025
## trio grid holds the scripted trip without UFLS and above 49.5 → ★★★ per
## the campaign_v1 rubric; a regression to ★★ means the inherited fleet's
## FCR margin thinned — investigate, don't re-pin blindly.
const PINNED_STARS := 3

var _passed_id := ""
var _passed_stars := -1
var _failed_reason := ""


func run() -> void:
	if not await p7_boot(TAG):
		return
	# inherited 2025 world + campaign mode
	var repo := AppPaths.root()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		repo + "/" + Campaign.START_STATE_PATH))
	if not (parsed is Dictionary) or not World.restore(parsed):
		_fail(TAG, "start_2025.json missing — run --smoke=author_start first")
		return
	if not Campaign.load_data():
		_fail(TAG, "campaign_v1.json missing")
		return
	# a smoke run must never clobber the player's real retry point
	Campaign.autosave_path = "user://autosave_milestone_smoke.json"
	Campaign.start_campaign()
	Campaign.milestone_passed.connect(func(id: String, stars: int) -> void:
		print("CAMPAIGN milestone_passed ", id, " stars ", stars)
		_passed_id = id
		_passed_stars = stars)
	Campaign.milestone_failed.connect(func(id: String, reason: String) -> void:
		print("CAMPAIGN milestone_failed ", id, " ", reason)
		_failed_reason = reason)
	var built := await p7_register(TAG)
	if built.is_empty():
		return
	# the real replay-panel fetch path (its auto-fetch hook sets
	# Campaign.replay_viewed — milestone 1's "replay viewed" gate)
	var panel: Control = (load("res://views/replay_panel.gd") as GDScript).new()
	add_child(panel)

	var ufls_events := 0
	var trip_seen := false
	var blocks := 0
	# Loop on SIM TIME, not a block count: every significant event
	# early-returns (step_once requests interrupt_on_event) and eats block
	# time, so a fixed 194-iteration cap carried only ~2 blocks of margin —
	# the corrected map projection (colder true regions, steeper morning
	# ramp, more shed events) consumed it and the milestone's day-2.0
	# window-close evaluation never ran. The hard cap below is a hang
	# guard, not the schedule.
	while Campaign.day_now() < 2.03 and blocks < 240:
		if blocks % 16 == 0:
			print("CAMPAIGN block ", blocks, " day %.2f" % Campaign.day_now())
		var result: Dictionary = await Orchestrator.step_once(900.0)
		blocks += 1
		if result.get("_status", 0) != 200:
			continue
		for event: Dictionary in result.get("events", []):
			var kind := str(event.get("kind", ""))
			print("CAMPAIGN ev day %.3f " % Campaign.day_now(), kind, " ",
				str(event.get("element", "")), " ", JSON.stringify(event.get("data", {})))
			# graded window only (milestone 1's exam brackets the scripted
			# trip; the free-play morning dip is ungraded — see campaign_v1)
			if kind == "ufls_stage" and Campaign.day_now() >= 1.5:
				ufls_events += 1
			elif kind == "trip":
				trip_seen = true
		if _passed_id != "" or _failed_reason != "":
			break

	# let the async replay fetch settle before asserting the viewed flag
	for _i in range(20):
		if Campaign.replay_viewed:
			break
		await get_tree().create_timer(0.25).timeout

	check("scripted_trip_fired", trip_seen)
	check("no_ufls", ufls_events == 0)
	check("replay_viewed", Campaign.replay_viewed)
	check("milestone_passed", _passed_id == "take_the_reins")
	check("not_failed", _failed_reason == "")
	check("stars_match_pin", _passed_stars == PINNED_STARS)
	# campaign state serializes/deserializes identically
	# ints float through JSON — compare parse-normalized forms
	var before := JSON.stringify(JSON.parse_string(
		JSON.stringify(Campaign.to_dict(), "", false, true)), "", false, true)
	Campaign.from_dict(JSON.parse_string(before))
	var after := JSON.stringify(JSON.parse_string(
		JSON.stringify(Campaign.to_dict(), "", false, true)), "", false, true)
	check("state_round_trips", before == after)
	_finish(TAG, {"stars": _passed_stars, "ufls": ufls_events,
		"trip_f_min": float(Campaign.acc.get("trip_f_min", 100.0))
			if _passed_id == "" else -1.0,
		"blocks": blocks})
