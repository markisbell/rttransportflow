extends SmokeBase
## --smoke=trip_reaction: inject a scheduled plant trip mid-window; the
## backend must EARLY-RETURN at the event, the game must auto-slow to 1x,
## and the frequency must visibly dive in the following trajectory.

const TAG := "SMOKE_TRIP_REACTION"


func run() -> void:
	if not await _boot_and_register(TAG):
		return

	# settle one minute of sim time
	var settle: Dictionary = await Orchestrator.step_once(60.0)
	if settle.get("_status", 0) != 200:
		_fail(TAG, "settle step failed")
		return

	GameClock.speed = 300.0  # so auto-slow to 1x is observable
	Orchestrator.inject([{"at_s_rel": 30.0, "kind": "trip",
		"element": "lignite_berlin"}])
	var result: Dictionary = await Orchestrator.step_once(600.0)
	if result.get("_status", 0) != 200:
		_fail(TAG, "trip step transport failure: %s" % str(result))
		return

	var dt_done := numf(result, "dt_done_s", 600.0)
	var events: Array = result.get("events", [])
	var tripped := false
	for event: Dictionary in events:
		if str(event.get("kind", "")) == "trip" \
				and str(event.get("element", "")) == "lignite_berlin":
			tripped = true
	check("early_return", dt_done < 599.0)
	check("early_return_at_event", absf(dt_done - 30.0) < 1.0)
	check("trip_event_present", tripped)
	check("auto_slowed_to_1x", GameClock.speed == 1.0)

	# the dip lives in the NEXT window's trajectory (and this one's tail)
	var f_min := 100.0
	for _i in range(30):
		var follow: Dictionary = await Orchestrator.step_once(1.0)
		if follow.get("_status", 0) != 200:
			break
		var island: Dictionary = follow.get("islands", {}).get("0", {})
		f_min = minf(f_min, numf(island, "f_min", 100.0))
	check("frequency_dove", f_min < 49.9)
	check("frequency_not_collapsed", f_min > 47.5)
	_finish(TAG, {"dt_done_s": dt_done, "f_min": f_min,
		"n_events": events.size()})
