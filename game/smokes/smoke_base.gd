class_name SmokeBase
extends Node
## Shared plumbing for the acceptance smokes (family pattern). Each smoke
## lives in res://smokes/<name>.gd as `func run()` over this base; main.gd
## only dispatches. Smokes print ONE machine-readable JSON line and quit
## 0/1 — that CLI contract is frozen (CI + wrappers grep it).

const SMOKE_PORT := 8031

var _checks := {}


func run() -> void:
	push_error("SmokeBase.run() not overridden")
	get_tree().quit(1)


## Boot the sidecar on `port`, wait healthy, load the bundle, handshake,
## register europe_mini. Returns false (after _fail) on any failure.
func _boot_and_register(tag: String, port: int = SMOKE_PORT) -> bool:
	SidecarManager.configure(port)
	SidecarManager.start_all()
	if not await _wait_healthy(120.0):
		_fail(tag, "health timeout")
		return false
	if not Boundary.load_bundle():
		_fail(tag, "bundle load failed")
		return false
	if not await CosimBridge.handshake(Orchestrator.ID):
		_fail(tag, "handshake failed")
		return false
	if not await Orchestrator.register(Boundary.reset_doc()):
		_fail(tag, "register failed")
		return false
	return true


func _wait_healthy(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not SidecarManager.all_healthy():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true


func _wait_state(state: SidecarManager.State, timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while SidecarManager.state_of(Orchestrator.ID) != state:
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.25).timeout
	return true


func _fail(tag: String, reason: String) -> void:
	print(tag, " ", JSON.stringify({"ok": false, "reason": reason,
		"failed": failed_checks()}))
	SidecarManager.stop_all()
	get_tree().quit(1)


func _finish(tag: String, extra: Dictionary = {}) -> void:
	var payload := {"ok": verdict(), "checks": _checks}
	payload.merge(extra)
	print(tag, " ", JSON.stringify(payload))
	SidecarManager.stop_all()
	get_tree().quit(0 if verdict() else 1)


## Named per-assertion reporting (family pattern): failures become
## attributable from the JSON line alone.
func check(check_name: String, passed: bool) -> bool:
	_checks[check_name] = passed
	return passed


func failed_checks() -> Array:
	var failed: Array = []
	for check_name: String in _checks:
		if not _checks[check_name]:
			failed.append(check_name)
	return failed


func verdict() -> bool:
	return failed_checks().is_empty()


## Null-tolerant numeric getter: the wire nulls non-finite floats (`_r()`),
## and GDScript float(null) is a hard script error.
static func numf(data: Dictionary, key: String, default: float) -> float:
	var value: Variant = data.get(key, default)
	return default if value == null else float(value)
