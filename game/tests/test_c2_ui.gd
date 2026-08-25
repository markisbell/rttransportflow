extends GdUnitTestSuite
## C2 UI logic — headless-safe assertions on the menu, inspector and
## milestone panel (construction, mode writes, panel content). Rendering
## and click plumbing are ui_boot's and the screenshot probe's job.

const MenuScript := preload("res://views/main_menu.gd")
const InspectorScript := preload("res://views/plant_inspector.gd")
const PanelScript := preload("res://views/milestone_panel.gd")
const FlowScript := preload("res://views/rendering/flow_layer.gd")


## C2 flow animation: the pure wire→texel mapping is pinned — direction
## from the sign of p_from_mw, dark when the line is absent (tripped) or
## unloaded, intensity monotone in loading.
func test_flow_texel_mapping() -> void:
	# tripped/absent and unloaded lines are dark
	assert_that(FlowScript.flow_texel(500.0, 80.0, false)).is_equal(Vector2.ZERO)
	assert_that(FlowScript.flow_texel(500.0, 0.0, true)).is_equal(Vector2.ZERO)
	# direction follows p_from_mw's sign (positive = path-forward)
	var forward: Vector2 = FlowScript.flow_texel(500.0, 60.0, true)
	var backward: Vector2 = FlowScript.flow_texel(-500.0, 60.0, true)
	assert_bool(forward.x > 0.0).is_true()
	assert_bool(backward.x < 0.0).is_true()
	assert_float(backward.x).is_equal_approx(-forward.x, 1e-6)
	assert_float(backward.y).is_equal_approx(forward.y, 1e-6)
	# speed and intensity climb with loading
	var light: Vector2 = FlowScript.flow_texel(100.0, 20.0, true)
	var heavy: Vector2 = FlowScript.flow_texel(100.0, 110.0, true)
	assert_bool(heavy.x > light.x).is_true()
	assert_bool(heavy.y > light.y).is_true()
	assert_bool(heavy.y <= 1.0).is_true()


## C2 flow animation: every native line carries its recorded tile path in
## the interpretation, path length matches the branch walk (steps + 1
## tiles), and the path's ENDPOINTS resolve to the line's from/to buses —
## the direction contract the shader's dash sign relies on.
func test_line_paths_cover_every_line_and_match_buses() -> void:
	# the topology suite's fixture map, not the Europe map — fixture_build's
	# coordinates belong to it
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		"res://testdata/mini_map.json"))
	assert_bool(World.load_map(doc)).is_true()
	World.clear_build()
	DemoBuild.fixture_build(World)
	var built := GridTopology.build(World)
	assert_bool(bool(built.get("ok", false))).is_true()
	var interp: Dictionary = built["interpretation"]
	var paths: Dictionary = interp.get("line_paths", {})
	var bus_of_tile: Dictionary = interp["bus_of_tile"]
	var rename: Dictionary = interp["bus_rename"]
	var lines: Array = built["native"]["lines"]["lines"]
	assert_bool(lines.size() > 0).is_true()
	for line: Dictionary in lines:
		var line_id := str(line["id"])
		assert_bool(paths.has(line_id)).override_failure_message(
			"%s has no recorded path" % line_id).is_true()
		var path: Array = paths[line_id]
		assert_bool(path.size() >= 2).is_true()
		var from_tile: Vector2i = path[0]
		var to_tile: Vector2i = path[path.size() - 1]
		var from_bus := "b%d" % int(rename[bus_of_tile[from_tile]])
		var to_bus := "b%d" % int(rename[bus_of_tile[to_tile]])
		assert_str(from_bus).override_failure_message(
			"%s path start maps to %s, doc says %s" \
			% [line_id, from_bus, line["from_bus"]]).is_equal(str(line["from_bus"]))
		assert_str(to_bus).is_equal(str(line["to_bus"]))
	World.clear_build()


func test_menu_constructs_with_actions() -> void:
	var menu: CanvasLayer = auto_free(MenuScript.new())
	add_child(menu)
	await get_tree().process_frame
	var buttons := menu.find_children("*", "Button", true, false)
	# New campaign + Sandbox always; Continue only with a savegame;
	# one per shipped scenario recipe (>= 3 recipes ship)
	assert_bool(buttons.size() >= 5).override_failure_message(
		"menu shows %d buttons" % buttons.size()).is_true()
	remove_child(menu)


func test_inspector_mode_writes_dispatch() -> void:
	var inspector: Variant = auto_free(InspectorScript.new())
	add_child(inspector)
	await get_tree().process_frame
	# the mode guard refuses plants that no longer exist — give it one
	World.plants["test_plant_1"] = {"kind": "gas_ccgt", "p_max_mw": 600.0}
	inspector.pid = "test_plant_1"
	inspector._on_mode(1)  # must_run
	assert_str(str(Dispatch.plant_mode.get("test_plant_1", ""))) \
		.is_equal("must_run")
	inspector._on_mode(3)  # mothballed
	assert_str(str(Dispatch.plant_mode.get("test_plant_1", ""))) \
		.is_equal("mothballed")
	inspector._on_mode(0)  # auto ERASES — absent key is auto, no shadow state
	assert_bool(Dispatch.plant_mode.has("test_plant_1")).is_false()
	# a vanished plant is never written (the stale-pid guard, C2 review)
	World.plants.erase("test_plant_1")
	inspector._on_mode(1)
	assert_bool(Dispatch.plant_mode.has("test_plant_1")).is_false()
	remove_child(inspector)


func test_milestone_panel_renders_pass_and_fail() -> void:
	Campaign.load_data()
	var autosave_0: String = Campaign.autosave_path
	Campaign.autosave_path = "user://nonexistent_c2_test.json"
	var panel: Variant = auto_free(PanelScript.new())
	add_child(panel)
	await get_tree().process_frame
	panel._on_passed("take_the_reins", 3)
	assert_bool(panel._panel.visible).is_true()
	assert_str(panel._title.text).contains("Take the Reins")
	assert_str(panel._body.text).contains("3/3")
	assert_bool(panel._retry.visible).is_false()
	panel._on_failed("merit_order", "avg_cost_below_eur_mwh")
	assert_str(panel._body.text).contains("avg_cost_below_eur_mwh")
	# no autosave file -> no retry offer (honest button, not a dead one)
	assert_bool(panel._retry.visible).is_false()
	panel._on_era({"id": "first_ratchet", "co2_eur_per_t": 60.0,
		"tariff_eur_per_mwh": 95.0})
	assert_str(panel._toast.text).contains("CO2 60")
	Campaign.autosave_path = autosave_0
	remove_child(panel)
