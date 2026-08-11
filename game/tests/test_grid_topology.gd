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
