extends GdUnitTestSuite
## C4 — battery policy logic and the author_era generator.


func test_battery_policy_setter_and_roundtrip() -> void:
	var policy_0: String = Dispatch.battery_policy
	Dispatch.set_battery_policy("reserve_ffr")
	assert_str(Dispatch.battery_policy).is_equal("reserve_ffr")
	Dispatch.set_battery_policy("nonsense")
	assert_str(Dispatch.battery_policy).is_equal("arbitrage")  # clamped default
	Dispatch.set_battery_policy("balanced")
	var state: Dictionary = Dispatch.to_dict()
	Dispatch.set_battery_policy("arbitrage")
	Dispatch.from_dict(state)
	assert_str(Dispatch.battery_policy).is_equal("balanced")
	# pre-C4 saves carry no key -> the pin-stable default
	state.erase("battery_policy")
	Dispatch.from_dict(state)
	assert_str(Dispatch.battery_policy).is_equal("arbitrage")
	Dispatch.set_battery_policy(policy_0)


## The policy overlay on the P7 arbitrage block, at the unit level: under
## scarcity an "arbitrage" fleet discharges, "balanced" refuses below the
## SoC floor (measured soc, ledger 44), "reserve_ffr" never schedules out.
func test_policy_overlay_discharge_rules() -> void:
	var devices_0: Array = Dispatch.wire_devices
	var scarcity_0: bool = Dispatch.scarcity
	var policy_0: String = Dispatch.battery_policy
	Dispatch.wire_devices = [{"id": "bat_t", "kind": "battery",
		"params": {"p_max_mw": 300.0}}]
	Dispatch.scarcity = true
	var low_soc := {"bat_t": {"soc": 0.2}}
	var high_soc := {"bat_t": {"soc": 0.8}}

	Dispatch.set_battery_policy("arbitrage")
	var commands := {}
	Dispatch._apply_flexibility(commands, 100.0, low_soc)
	assert_bool(float((commands["bat_t"] as Dictionary)["dispatch_mw"]) > 0.0).is_true()

	Dispatch.set_battery_policy("balanced")
	commands = {}
	Dispatch._apply_flexibility(commands, 100.0, low_soc)
	assert_float(float((commands["bat_t"] as Dictionary)["dispatch_mw"])).is_equal(0.0)
	commands = {}
	Dispatch._apply_flexibility(commands, 100.0, high_soc)
	assert_bool(float((commands["bat_t"] as Dictionary)["dispatch_mw"]) > 0.0).is_true()

	Dispatch.set_battery_policy("reserve_ffr")
	commands = {}
	Dispatch._apply_flexibility(commands, 100.0, high_soc)
	assert_float(float((commands["bat_t"] as Dictionary)["dispatch_mw"])).is_equal(0.0)

	Dispatch.wire_devices = devices_0
	Dispatch.scarcity = scarcity_0
	Dispatch.set_battery_policy(policy_0)


func test_author_era_unknown_refused() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_era(World, "not_an_era")).is_false()
	World.clear_build()


## The era generator is DETERMINISTIC: same era, same world, byte for
## byte — the property every recipe and pin stands on.
func test_author_era_green_push_deterministic() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_era(World, "green_push")).is_true()
	var first := JSON.stringify(World.serialize(), "", false, true)
	assert_bool(Campaign.re_capacity_mw() >= 24000.0).is_true()
	assert_bool(Campaign.hub_offshore_mw() >= 4000.0).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_era(World, "green_push")).is_true()
	var second := JSON.stringify(World.serialize(), "", false, true)
	assert_bool(first == second).override_failure_message(
		"author_era(green_push) is not deterministic").is_true()
	World.clear_build()
