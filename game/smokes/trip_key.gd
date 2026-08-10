extends SmokeBase
## --smoke=trip_key: the HUD debug key (T) trips the largest online unit.
## Boots the REAL HUD — the code path the other smokes bypass; a
## nonexistent-function regression on exactly this path reached the user
## in P4, hence this smoke.

const TAG := "SMOKE_TRIP_KEY"


func run() -> void:
	if not await _boot_and_register(TAG):
		return
	var hud := preload("res://views/hud.gd").new()
	add_child(hud)

	# One settle step so step_completed populates the HUD's device cache.
	var settle: Dictionary = await Orchestrator.step_once(60.0)
	if settle.get("_status", 0) != 200:
		_fail(TAG, "settle step failed")
		return
	await get_tree().process_frame

	var key := InputEventKey.new()
	key.keycode = KEY_T
	key.physical_keycode = KEY_T
	key.pressed = true
	Input.parse_input_event(key)
	await get_tree().process_frame
	await get_tree().process_frame

	var pending: Array = Orchestrator.pending_events
	check("injection_queued", pending.size() == 1)
	var element := ""
	if pending.size() == 1:
		element = str((pending[0] as Dictionary).get("element", ""))
	check("largest_unit_selected", element == "nuc_paris")

	var result: Dictionary = await Orchestrator.step_once(300.0)
	if result.get("_status", 0) != 200:
		_fail(TAG, "trip step transport failure")
		return
	var tripped := false
	for event: Dictionary in result.get("events", []):
		if str(event.get("kind", "")) == "trip" \
				and str(event.get("element", "")) == element:
			tripped = true
	check("trip_event_fired", tripped)
	check("early_return_at_injection", float(result.get("dt_done_s", 300.0)) < 5.0)
	_finish(TAG, {"element": element})
