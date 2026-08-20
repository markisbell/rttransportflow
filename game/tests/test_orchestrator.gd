extends GdUnitTestSuite
## The deaf-backend recovery path (ledger 36, game side): repeated transport
## failures must force a re-register even though the sidecar never leaves
## HEALTHY — the old recovery hung exclusively off a sidecar state EDGE that
## a deaf backend structurally never produces, so needs_reset spun forever.
## Driven through the test seams (bridge_override / health_override); the
## Python contract suite stays the wire authority.


class FakeBridge:
	extends RefCounted
	var resets := 0
	var handshakes := 0

	func net_reset(_id: String, _doc: Dictionary) -> Dictionary:
		resets += 1
		return {"_status": 200, "status": "ok"}

	func handshake(_id: String) -> bool:
		handshakes += 1
		return true

	func step(_id: String, _request: Dictionary) -> Dictionary:
		return {"_status": 0, "_error": "connection refused"}

	func drop(_id: String) -> void:
		pass


class FakeHealth:
	extends RefCounted
	func state_of(_id: String) -> int:
		return SidecarManager.State.HEALTHY


func test_deaf_backend_recovers_from_the_tick_loop() -> void:
	var bridge := FakeBridge.new()
	var prev_speed: float = GameClock.speed
	Orchestrator.reset_for_test()
	Orchestrator.bridge_override = bridge
	Orchestrator.health_override = FakeHealth.new()
	# minimal profile docs so step_once's boundary reads stay quiet
	Boundary.docs = {"scenario": {}, "load_centers": {}, "plants": {},
		"grid": {}, "lines": {}}

	assert_bool(await Orchestrator.register({"contract": "2.0"})).is_true()
	assert_int(bridge.resets).is_equal(1)

	# consecutive transport failures on a HEALTHY sidecar -> deaf verdict
	for _i in range(Orchestrator.TRANSPORT_FAILURES_BEFORE_RESET):
		await Orchestrator.step_once(1.0)
	assert_bool(Orchestrator.needs_reset).is_true()

	# the tick loop must recover WITHOUT any sidecar state transition
	Orchestrator.running = true
	GameClock.speed = 1.0
	Orchestrator._on_tick()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_int(bridge.handshakes).is_equal(1)
	assert_int(bridge.resets).is_equal(2)
	assert_bool(Orchestrator.needs_reset).is_false()

	Orchestrator.reset_for_test()
	GameClock.speed = prev_speed


func test_register_strips_the_one_shot_snapshot() -> void:
	## a snapshot in the reset doc is SaveLoad's exact restore — one-shot: a
	## later crash/deaf recovery must reset COLD, not silently rewind the sim
	var bridge := FakeBridge.new()
	Orchestrator.reset_for_test()
	Orchestrator.bridge_override = bridge
	Orchestrator.health_override = FakeHealth.new()
	assert_bool(await Orchestrator.register(
		{"contract": "2.0", "snapshot": {"blob": {}}})).is_true()
	assert_bool(Orchestrator.topology.has("snapshot")).is_false()
	Orchestrator.reset_for_test()
