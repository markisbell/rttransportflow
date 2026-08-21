extends GdUnitTestSuite
## Topology-builder unit tests + the byte-stable golden pin (family rule:
## delete the golden file to re-baseline, then commit both).

const GOLDEN := "res://tests/goldens/topology_fixture.json"
const FIXTURE_MAP := "res://testdata/mini_map.json"


func _load_fixture() -> void:
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_MAP))
	assert_bool(World.load_map(doc)).is_true()
	World.clear_build()


func test_fixture_build_matches_golden() -> void:
	_load_fixture()
	DemoBuild.fixture_build(World)
	var built := GridTopology.build(World)
	assert_bool(built["ok"]).is_true()
	var text := JSON.stringify(built["native"], "  ", false) + "\n"
	if not FileAccess.file_exists(GOLDEN):
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path("res://tests/goldens"))
		var file := FileAccess.open(GOLDEN, FileAccess.WRITE)
		file.store_string(text)
		file.close()
		push_warning("topology golden (re)baselined — rerun to verify, commit both")
		return
	assert_str(text).is_equal(FileAccess.get_file_as_string(GOLDEN))


func test_build_is_deterministic() -> void:
	_load_fixture()
	DemoBuild.fixture_build(World)
	var first := JSON.stringify(GridTopology.build(World)["native"])
	DemoBuild.fixture_build(World)  # rebuild from scratch
	var second := JSON.stringify(GridTopology.build(World)["native"])
	assert_str(second).is_equal(first)


func test_nothing_built_is_a_clean_error() -> void:
	_load_fixture()
	var built := GridTopology.build(World)
	assert_bool(built["ok"]).is_false()
	assert_str(str(built["error"])).contains("nothing built")


func test_no_source_is_a_clean_error() -> void:
	_load_fixture()
	# corridor touches the load center but there is no plant anywhere
	for x in range(5, 9):
		World.place_corridor(Vector2i(x, 6))
	var built := GridTopology.build(World)
	assert_bool(built["ok"]).is_false()
	assert_str(str(built["error"])).contains("no synchronous source")


func test_unconnected_load_center_is_dropped_with_warning() -> void:
	_load_fixture()
	DemoBuild.fixture_build(World)
	World.remove_corridor(Vector2i(17, 6))  # cut east_city off
	var built := GridTopology.build(World)
	assert_bool(built["ok"]).is_true()
	assert_array(built["interpretation"]["dropped_zones"]).contains(["east_city"])
	var warned := false
	for warning: String in built["warnings"]:
		if warning.contains("east_city"):
			warned = true
	assert_bool(warned).is_true()


func test_node_budget_refusal() -> void:
	# Synthetic 320-wide plain: a trunk with 160 SPACED plant taps (spaced so
	# the bus tiles cannot collapse) exceeds the 150-bus hard cap.
	BuildSession.enabled = false
	var rows: Array = []
	for _y in range(5):
		rows.append("p".repeat(320))
	var doc := {"version": 1, "width": 320, "height": 5, "tile_km": 50.0,
		"terrain_rows": rows, "resources": [], "load_centers": []}
	assert_bool(World.load_map(doc)).is_true()
	World.clear_build()
	for x in range(320):
		World.place_corridor(Vector2i(x, 1))
	for i in range(160):
		assert_str(World.place_plant("gas_ocgt", Vector2i(i * 2, 2))).is_not_empty()
	var built := GridTopology.build(World)
	assert_bool(built["ok"]).is_false()
	assert_str(str(built["error"])).contains("node budget")


func test_line_length_uses_sinuosity() -> void:
	_load_fixture()
	DemoBuild.fixture_build(World)
	var built := GridTopology.build(World)
	for line: Dictionary in built["native"]["lines"]["lines"]:
		var steps := roundf(float(line["length_km"]) / (50.0 * GridTopology.SINUOSITY))
		assert_float(float(line["length_km"])).is_equal_approx(
			steps * 50.0 * GridTopology.SINUOSITY, 0.01)


func test_wire_devices_emitted() -> void:
	_load_fixture()
	DemoBuild.fixture_build(World)
	# storage + H2 sites off the trunk (trunk runs y = 6, x = 5..18)
	World.resources["salt_cavern"] = {Vector2i(6, 8): {"kind": "salt_cavern"}}
	var cavern := World.place_plant("h2_cavern", Vector2i(6, 8))
	var bat := World.place_plant("battery", Vector2i(8, 5))
	var ely := World.place_plant("electrolyzer", Vector2i(10, 5))
	# embedded point-to-point link between two trunk-adjacent converters
	var conv_a := World.place_plant("hvdc_converter", Vector2i(12, 5))
	var conv_b := World.place_plant("hvdc_converter", Vector2i(16, 5))
	for x in range(13, 16):
		assert_bool(World.place_corridor(Vector2i(x, 5), "hvdc")).is_true()
	# far-shore hub: platform + bound farm on DEEP sea, onshore converter
	var platform := World.place_plant("offshore_platform", Vector2i(0, 2))
	var farm := World.place_plant("wind_offshore", Vector2i(0, 4))
	var conv_c := World.place_plant("hvdc_converter", Vector2i(2, 2))
	assert_bool(World.place_corridor(Vector2i(1, 2), "hvdc")).is_true()
	for tile: Vector2i in [Vector2i(2, 3), Vector2i(2, 4), Vector2i(2, 5),
			Vector2i(2, 6), Vector2i(3, 6), Vector2i(4, 6)]:
		assert_bool(World.place_corridor(tile)).is_true()
	assert_str(cavern).is_not_empty()
	assert_str(farm).is_not_empty()

	var built := GridTopology.build(World)
	assert_bool(built["ok"]).is_true()
	var by_id := {}
	for dev: Dictionary in built["devices"]:
		by_id[str(dev["id"])] = dev
	assert_bool(by_id.has(cavern)).is_true()
	assert_str(str(by_id[cavern]["kind"])).is_equal("h2_store")
	assert_str(str(by_id[bat]["kind"])).is_equal("battery")
	assert_float(float(by_id[bat]["params"]["e_mwh"])).is_equal(600.0)
	assert_str(str(by_id[ely]["params"]["h2_store_id"])).is_equal(cavern)
	assert_str(str(by_id[conv_a]["kind"])).is_equal("hvdc")
	assert_str(str(by_id[conv_a]["params"]["link_id"])) \
		.is_equal(str(by_id[conv_b]["params"]["link_id"]))
	assert_str(str(by_id[platform]["kind"])).is_equal("offshore_hub")
	assert_bool(by_id.has(conv_c)).is_false()  # hub side: single injection
	assert_array(built["hub_farms"][platform]).is_equal([farm])
	# the bound farm is a game-side entity only — never in the native doc
	for plant: Dictionary in built["native"]["plants"]["plants"]:
		assert_str(str(plant["id"])).is_not_equal(farm)


func test_h2_conversion_lands_in_native() -> void:
	_load_fixture()
	DemoBuild.fixture_build(World)
	World.resources["salt_cavern"] = {Vector2i(6, 8): {"kind": "salt_cavern"}}
	var cavern := World.place_plant("h2_cavern", Vector2i(6, 8))
	var gas_pid: String = World.plant_at(Vector2i(10, 8))
	assert_bool(World.convert_to_h2(gas_pid, cavern)).is_true()
	var built := GridTopology.build(World)
	assert_bool(built["ok"]).is_true()
	for plant: Dictionary in built["native"]["plants"]["plants"]:
		if str(plant["id"]) == gas_pid:
			assert_str(str(plant["fuel"])).is_equal("h2")
			assert_str(str(plant["h2_store_id"])).is_equal(cavern)


func test_debounce_restarts_and_defers() -> void:
	_load_fixture()
	BuildSession.enabled = true
	var fired: Array = []
	var handler := func(ok: bool, _m: String, _w: Array) -> void: fired.append(ok)
	BuildSession.build_status.connect(handler)
	for x in range(5, 10):
		World.place_corridor(Vector2i(x, 6))
		await await_millis(80)
	# five rapid edits: timer keeps restarting, nothing rebuilt yet
	assert_float(BuildSession._timer.time_left).is_greater(BuildSession.DEBOUNCE_S - 0.6)
	assert_int(fired.size()).is_equal(0)
	BuildSession.enabled = false
	BuildSession._timer.stop()
	BuildSession.build_status.disconnect(handler)


func test_cable_transition_forms_bus_and_param_line() -> void:
	# a line<->cable kind change must form a bus (the kind_change rule) and
	# the cable branch must emit explicit parameters instead of a std_type
	_load_fixture()
	World.place_plant("gas_ccgt", Vector2i(4, 4))
	for x in range(5, 10):
		World.place_corridor(Vector2i(x, 4), "line_400")
	for x in range(10, 15):
		World.place_corridor(Vector2i(x, 4), "cable_400")
	World.place_plant("gas_ccgt", Vector2i(15, 4))
	var built := GridTopology.build(World)
	assert_bool(built["ok"]).is_true()
	var lines: Array = built["native"]["lines"]["lines"]
	assert_int(lines.size()).is_greater_equal(2)
	var cable: Dictionary = {}
	var overhead: Dictionary = {}
	for l: Dictionary in lines:
		if l.get("std_type") == null:
			cable = l
		else:
			overhead = l
	assert_bool(not cable.is_empty()).override_failure_message(
		"no parameter (cable) line emitted").is_true()
	assert_float(float(cable["c_nf_per_km"])).is_greater(100.0)
	assert_bool(not overhead.is_empty()).is_true()
