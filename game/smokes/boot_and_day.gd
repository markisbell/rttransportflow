extends SmokeBase
## --smoke=boot_and_day: boot the sidecar, reset europe_mini, step through
## >= 2 simulated hours in 90 s chunks; every response is physics data
## (never a transport/protocol error), frequency stays sane, sim time
## advances by exactly the sum of dt_done_s.

const TAG := "SMOKE_BOOT_AND_DAY"
const CHUNK_DT_S := 90.0
const N_STEPS := 80  # 80 x 90 s = 2 h


func run() -> void:
	if not await _boot_and_register(TAG):
		return

	GameClock.speed = 900.0  # sizing only — we drive step_once directly
	var statuses := {}
	var f_min := 100.0
	var f_max := 0.0
	var dt_done_sum := 0.0
	var completed := 0

	for i in range(N_STEPS):
		var result: Dictionary = await Orchestrator.step_once(CHUNK_DT_S)
		if result.get("_status", 0) != 200:
			_fail(TAG, "transport failure at step %d: %s" % [i, str(result)])
			return
		var status := str(result.get("status", "?"))
		statuses[status] = statuses.get(status, 0) + 1
		var island: Dictionary = result.get("islands", {}).get("0", {})
		f_min = minf(f_min, float(island.get("f_min", 100.0)))
		f_max = maxf(f_max, float(island.get("f_max", 0.0)))
		dt_done_sum += float(result.get("dt_done_s", 0.0))
		completed += 1

	check("all_steps_completed", completed == N_STEPS)
	check("no_failed_status", int(statuses.get("failed", 0)) == 0)
	check("f_band_sane", f_min > 49.5 and f_max < 50.5)
	check("sim_time_advanced", absf(GameClock.t_sim - dt_done_sum) < 1e-6
		and dt_done_sum >= 7000.0)
	check("t_monotonic", Orchestrator.last_t == N_STEPS - 1)
	_finish(TAG, {"statuses": statuses, "f_min": f_min, "f_max": f_max,
		"t_sim": GameClock.t_sim})
