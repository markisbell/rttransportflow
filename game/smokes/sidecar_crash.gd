extends SmokeBase
## --smoke=sidecar_crash: kill the backend mid-run; SidecarManager must
## restart it, the Orchestrator must re-handshake + net/reset (the game
## model is the source of truth) and stepping must resume.

const TAG := "SMOKE_SIDECAR_CRASH"

## Member vars, NOT locals: GDScript lambdas capture scalars BY VALUE — a
## captured-local `recovered = true` mutates a copy (family gotcha; cost
## this exact smoke a debugging round).
var recovered := false
var went_down := false


func run() -> void:
	if not await _boot_and_register(TAG):
		return

	Orchestrator.supply_event.connect(
		func(kind: String, _severity: String, _data: Dictionary) -> void:
			if kind == "backend_recovered":
				recovered = true
			if kind == "backend_down":
				went_down = true)

	for _i in range(3):
		var result: Dictionary = await Orchestrator.step_once(10.0)
		if result.get("_status", 0) != 200:
			_fail(TAG, "pre-crash step failed")
			return
	var t_before := Orchestrator.last_t
	var sim_before := GameClock.t_sim

	# murder the backend (kill -9; SidecarManager owns the real pid — POSIX
	# exec launch makes the child pid the backend itself)
	SidecarManager.kill_for_test(Orchestrator.ID)

	if not await _wait_state(SidecarManager.State.HEALTHY, 90.0):
		# it may already be healthy again between polls — verify via recovery flag below
		pass
	var deadline := Time.get_ticks_msec() + 90_000
	while not recovered and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.5).timeout
	check("recovered_event", recovered)
	check("needs_reset_cleared", not Orchestrator.needs_reset)

	var post: Dictionary = await Orchestrator.step_once(10.0)
	check("post_crash_step_ok", post.get("_status", 0) == 200
		and str(post.get("status", "")) != "")
	# recovery = fresh wire sequence (t restarts at 0); SIM TIME continues —
	# that is the meaningful continuity (boundary conditions follow the clock)
	check("fresh_wire_sequence", Orchestrator.last_t == 0)
	check("sim_time_continued", GameClock.t_sim > sim_before)
	_finish(TAG, {"went_down": went_down, "t_before": t_before,
		"t_after": Orchestrator.last_t, "t_sim": GameClock.t_sim})
