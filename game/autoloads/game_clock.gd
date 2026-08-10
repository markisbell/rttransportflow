extends Node
## GameClock — v2 semantics: the BACKEND's dt_done_s is authoritative
## (contract v2 "Time quantization"). Sim time only advances when the
## Orchestrator applies a step response; `speed` only sizes the next
## request's dt_s (0 = paused = no requests). Contrast with infrastruct's
## free-running wall clock: here the clock follows the wire.

signal speed_changed(speed: float)
signal time_advanced(t_sim: float, dt_done_s: float)

const SECONDS_PER_DAY := 86400.0
const STEP_SECONDS := 900.0  # economy-layer cadence (96 steps/day)

var speed := 1.0:
	set(value):
		speed = maxf(0.0, value)
		speed_changed.emit(speed)

## Seconds since scenario start — advanced ONLY by Orchestrator.
var t_sim := 0.0


func advance(dt_done_s: float) -> void:
	t_sim += dt_done_s
	time_advanced.emit(t_sim, dt_done_s)


func pause() -> void:
	speed = 0.0


func day() -> int:
	return int(t_sim / SECONDS_PER_DAY)


func second_of_day() -> float:
	return fmod(t_sim, SECONDS_PER_DAY)


func step_index(steps_per_day: int = 96) -> int:
	return int(t_sim / STEP_SECONDS) % steps_per_day


func time_of_day_string() -> String:
	var s := int(second_of_day())
	@warning_ignore("integer_division")
	return "%02d:%02d" % [s / 3600, (s % 3600) / 60]


func serialize() -> Dictionary:
	return {"t_sim": t_sim, "speed": speed}


func restore(data: Dictionary) -> void:
	t_sim = float(data.get("t_sim", 0.0))
	speed = float(data.get("speed", 1.0))
