extends Node
## Orchestrator — v2 stepping scheduler (ported from infrastruct, adapted to
## the variable-dt contract).
##
## Rules it enforces:
## - the game steps at ~STEP_HZ wall with dt_s = 0.1 × speed (clamped to the
##   contract range); wire `t` is a monotonically increasing sequence number
## - the game clock advances by the RESPONSE's dt_done_s (authoritative —
##   contract v2 "Time quantization"; it may exceed dt_s by up to 0.25 s)
## - one-step lag: the UI reads last_result while the next step is in flight
## - at most one step in flight; ticks that arrive while solving are skipped
##   (counted — never a stall)
## - auto-slow: on an early return carrying events, speed drops to 1× with a
##   cooldown of AUTO_SLOW_COOLDOWN quiet steps before restoring
## - solver failure is a gameplay event, not an error
## - backend death/recovery: on HEALTHY after DOWN, re-handshake + net/reset
##   (the game model is the source of truth) and resume; the gap becomes a
##   disturbance event

signal step_completed(t: int, result: Dictionary)
signal supply_event(kind: String, severity: String, data: Dictionary)
signal events_received(events: Array)

const ID := "transmission"
const STEP_HZ := 10.0
const DT_MIN := 0.05
const DT_MAX := 900.0
const AUTO_SLOW_COOLDOWN := 3
const FAILED_ESCALATION_STEPS := 3
## consecutive transport failures before we assume a DEAF backend and
## force a re-register (a live process with a dead step channel)
const TRANSPORT_FAILURES_BEFORE_RESET := 5

var running := false
var in_flight := false
var last_reset_status := ""
var last_t := -1
var last_result := {}
var topology := {}
var needs_reset := false
var resetting := false
var down_since_sim := -1.0
var consecutive_failed := 0
var consecutive_transport_failed := 0
var pending_events: Array = []  # scheduled_events queued for the next request
var watch: Array = []
var auto_slow_cooldown := 0
var restore_speed := 0.0
var stats := {"dispatched": 0, "completed": 0, "skipped_busy": 0,
	"skipped_down": 0, "rejected": 0}

## Test seams (infrastruct pattern): fakes drive the scheduler without
## sockets; the Python contract suite stays the wire authority.
var bridge_override: Object = null
var health_override: Object = null

var _timer: Timer


func _bridge() -> Object:
	return bridge_override if bridge_override != null else CosimBridge


func _healthy() -> bool:
	if health_override != null:
		return health_override.state_of(ID) == SidecarManager.State.HEALTHY
	return SidecarManager.state_of(ID) == SidecarManager.State.HEALTHY


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = 1.0 / STEP_HZ
	_timer.timeout.connect(_on_tick)
	add_child(_timer)
	SidecarManager.state_changed.connect(_on_sidecar_state)


## Register the network with its topology document; resets the backend.
## A reset starts a fresh wire sequence (t from 0 — the infrastruct wire-t
## resync pattern); GameClock.t_sim continues, boundary conditions follow it.
func register(topology_doc: Dictionary) -> bool:
	topology = topology_doc
	resetting = true
	var response: Dictionary = await _bridge().net_reset(ID, topology)
	resetting = false
	last_reset_status = str(response.get("status", ""))
	# refused_snapshot is a LEGAL cold start (contract reset semantics /
	# SPEC §4.2): the reset applied, only the exact-state restore didn't
	var ok: bool = response.get("_status", 0) == 200 \
		and (last_reset_status == "ok" or last_reset_status == "refused_snapshot")
	if ok and last_reset_status == "refused_snapshot":
		supply_event.emit("snapshot_refused", "warning", response)
	if ok:
		last_t = -1
		# a reset invalidates every prior wire result: serving a stale one
		# fed the dispatcher pre-reset device states — it saw a dead fleet,
		# zeroed every cap, declared scarcity and dumped the batteries into
		# a healthy island (found by battery_response run B)
		last_result = {}
	else:
		push_warning("net_reset failed: %s" % JSON.stringify(response))
		supply_event.emit("reset_failed", "critical", response)
	return ok


func start() -> void:
	running = true
	_timer.start()


func stop() -> void:
	running = false
	_timer.stop()


func latest() -> Dictionary:
	return last_result


## Queue scheduled_events (scenario/teaching injection) for the next request.
func inject(events: Array) -> void:
	pending_events.append_array(events)


func _on_tick() -> void:
	if not running or GameClock.speed <= 0.0:
		return
	if resetting or needs_reset or not _healthy():
		stats["skipped_down"] += 1
		if down_since_sim < 0.0 and needs_reset:
			down_since_sim = GameClock.t_sim
			supply_event.emit("backend_down", "critical", {"t_sim": GameClock.t_sim})
		return
	if in_flight:
		stats["skipped_busy"] += 1
		return
	var dt_s := clampf(0.1 * GameClock.speed, DT_MIN, DT_MAX)
	step_once(dt_s)


## Dispatch ONE step (also the smoke seam). Returns the result Dictionary.
func step_once(dt_s: float) -> Dictionary:
	in_flight = true
	stats["dispatched"] += 1
	var t := last_t + 1
	var request := {
		"t": t,
		"dt_s": dt_s,
		"interrupt_on_event": true,
		"zone_demand": Boundary.zone_demand(GameClock.t_sim),
		"avail_mw": Boundary.avail_mw(GameClock.t_sim),
		"device_commands": Boundary.device_commands(GameClock.t_sim),
	}
	if not pending_events.is_empty():
		request["scheduled_events"] = pending_events.duplicate()
		pending_events.clear()
	if not watch.is_empty():
		request["watch"] = watch.duplicate()
	var result: Dictionary = await _bridge().step(ID, request)
	in_flight = false
	return _apply_result(t, result)


func _apply_result(t: int, result: Dictionary) -> Dictionary:
	# HTTP fallback nests protocol errors under FastAPI's "detail".
	var error_body: Dictionary = result.get("detail", result) \
		if result.get("detail") is Dictionary else result
	if result.get("_status", 0) == 409 \
			or str(error_body.get("error", "")) == "out_of_order":
		# resync from the backend's expectation
		var expected: Array = error_body.get("expected", [])
		if not expected.is_empty():
			last_t = int(expected[-1]) - 1
		stats["rejected"] += 1
		supply_event.emit("step_rejected", "warning", result)
		return result
	if result.get("_status", 0) != 200:
		consecutive_transport_failed += 1
		supply_event.emit("step_transport_failed", "warning",
			{"t": t, "error": result.get("_error", "?"),
			"consecutive": consecutive_transport_failed})
		# A backend can go DEAF without going down: an exception inside the
		# step handler killed the WS while /health stayed green, and the game
		# then span forever on a dead channel (found when two smokes froze
		# mid-run). Repeated transport failures now force a re-register —
		# skip-never-stall, but never spin silently either.
		if consecutive_transport_failed >= TRANSPORT_FAILURES_BEFORE_RESET:
			consecutive_transport_failed = 0
			needs_reset = true
			supply_event.emit("backend_deaf", "critical",
				{"t": t, "action": "re-register"})
		return result
	consecutive_transport_failed = 0

	last_result = result
	last_t = t
	stats["completed"] += 1
	GameClock.advance(float(result.get("dt_done_s", 0.0)))

	match str(result.get("status", "failed")):
		"converged":
			consecutive_failed = 0
		"degraded":
			consecutive_failed = 0
			supply_event.emit("solver_degraded", "warning", {"t": t})
		"failed":
			consecutive_failed += 1
			var severity := "critical" \
				if consecutive_failed >= FAILED_ESCALATION_STEPS else "warning"
			supply_event.emit("supply_failure", severity,
				{"t": t, "consecutive": consecutive_failed})

	var events: Array = result.get("events", [])
	# auto-slow on any significant event (a superset of early returns —
	# a trip landing exactly on the window end still deserves attention)
	if not events.is_empty():
		events_received.emit(events)
		if _significant(events) and GameClock.speed > 1.0:
			restore_speed = GameClock.speed
			GameClock.speed = 1.0
			auto_slow_cooldown = AUTO_SLOW_COOLDOWN
			supply_event.emit("auto_slow", "info", {"events": events})
	elif auto_slow_cooldown > 0:
		auto_slow_cooldown -= 1
		if auto_slow_cooldown == 0 and restore_speed > 0.0:
			GameClock.speed = restore_speed
			restore_speed = 0.0

	for violation: Dictionary in result.get("violations", []):
		if str(violation.get("severity", "info")) != "info":
			supply_event.emit("violation", str(violation["severity"]), violation)

	step_completed.emit(t, result)
	return result


static func _significant(events: Array) -> bool:
	for event: Dictionary in events:
		if str(event.get("kind", "")) != "start_complete" \
				and str(event.get("kind", "")) != "mode_change":
			return true
	return false


func _on_sidecar_state(_id: String, state: SidecarManager.State) -> void:
	if topology.is_empty():
		return
	if state == SidecarManager.State.DOWN or state == SidecarManager.State.RESTARTING:
		needs_reset = true
		in_flight = false
		_bridge().drop(ID)
	elif state == SidecarManager.State.HEALTHY and needs_reset:
		_recover()


func _recover() -> void:
	if not await _bridge().handshake(ID):
		supply_event.emit("handshake_failed", "critical", {})
		return
	var response: Dictionary = await _bridge().net_reset(ID, topology)
	if response.get("_status", 0) == 200 and str(response.get("status", "")) == "ok":
		needs_reset = false
		last_t = -1  # fresh wire sequence after the reset (see register())
		var gap_start := down_since_sim
		down_since_sim = -1.0
		supply_event.emit("backend_recovered", "info",
			{"gap_start_sim": gap_start, "resumed_sim": GameClock.t_sim})
	else:
		supply_event.emit("reset_failed", "critical", response)


func reset_for_test() -> void:
	running = false
	in_flight = false
	last_t = -1
	last_result = {}
	topology = {}
	needs_reset = false
	pending_events.clear()
	stats = {"dispatched": 0, "completed": 0, "skipped_busy": 0,
		"skipped_down": 0, "rejected": 0}
	bridge_override = null
	health_override = null
