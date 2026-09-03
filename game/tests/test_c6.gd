extends GdUnitTestSuite
## C6 — the two inertia buildables: kind wiring, the ONE-STRING invariant
## (tool id = world kind = unlock key = capex key), device emission, the
## syncon native row, and the dispatcher/economy honesty.


func after() -> void:
	World.plants.clear()


## The naming reconciliation the recon flagged: for each buildable, the
## build tool id, the world plant kind, the campaign unlock key and the
## economy capex/flat-price key must be ONE string.
func test_one_string_invariant() -> void:
	Campaign.load_data()
	var unlocks: Dictionary = Campaign.data["unlocks"]
	# grid_forming
	assert_bool(World.DEVICE_KINDS.has("grid_forming")).is_true()
	assert_bool(unlocks.has("grid_forming")).is_true()
	assert_bool(World.PLANT_SIZES.has("grid_forming")).is_true()
	# syncon
	assert_bool(World.SYNC_KINDS.has("syncon")).is_true()
	assert_bool(unlocks.has("syncon")).is_true()
	assert_bool(World.PLANT_SN_MVA.has("syncon")).is_true()
	# unlock gating resolves for both tool ids (not silently open)
	Campaign.start_campaign()
	GameClock.t_sim = 0.0  # 2025, before 2031
	assert_bool(Campaign.unlocked("grid_forming")).is_false()
	assert_bool(Campaign.unlocked("syncon")).is_false()
	GameClock.t_sim = 84.0 * 86400.0  # day 84 -> 2032
	assert_bool(Campaign.unlocked("grid_forming")).is_true()
	assert_bool(Campaign.unlocked("syncon")).is_true()
	Campaign.active = false


func test_placement_and_row_shape() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
	var gfm := World.place_plant("grid_forming", DemoBuild.find_site(
		World, "grid_forming", anchor, 10))
	var syn := World.place_plant("syncon", DemoBuild.find_site(
		World, "syncon", anchor, 10))
	assert_str(gfm).is_not_empty()
	assert_str(syn).is_not_empty()
	# grid_forming is a device carrying battery energy; syncon a sync
	# plant carrying its rating and zero power
	assert_float(float(World.plants[gfm]["e_mwh"])).is_equal(600.0)
	assert_float(float(World.plants[syn]["p_max_mw"])).is_equal(0.0)
	assert_float(float(World.plants[syn]["sn_mva"])).is_equal(300.0)
	World.clear_build()


## The wire path both kinds take, end to end through the topology builder,
## on the inherited world (the fixture map is too small to route two
## fresh plants into its web).
func test_topology_emits_gfm_device_and_syncon_row() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	assert_bool(GridPlan.author_start(World)).is_true()
	# place each on the free side of a substation so it joins an existing
	# bus (the packed-park rule the arc has used throughout)
	var stations: Array = World.substations.keys()
	var gfm := _place_beside_station("grid_forming", stations)
	var syn := _place_beside_station("syncon", stations)
	assert_str(gfm).is_not_empty()
	assert_str(syn).is_not_empty()
	var built := GridTopology.build(World)
	assert_bool(bool(built.get("ok", false))).override_failure_message(
		"build refused: %s" % str(built.get("error", ""))).is_true()
	# grid_forming -> devices channel, kind grid_forming (NOT battery)
	var gfm_dev := {}
	for dev: Dictionary in built.get("devices", []):
		if str(dev.get("id", "")) == gfm:
			gfm_dev = dev
	assert_str(str(gfm_dev.get("kind", ""))).is_equal("grid_forming")
	# syncon -> native plants doc, carrying sn_mva
	var syn_row := {}
	for row: Dictionary in built["native"]["plants"]["plants"]:
		if str(row.get("id", "")) == syn:
			syn_row = row
	assert_str(str(syn_row.get("kind", ""))).is_equal("syncon")
	assert_float(float(syn_row.get("sn_mva", 0.0))).is_equal(300.0)
	assert_float(float(syn_row.get("p_max_mw", -1.0))).is_equal(0.0)
	World.clear_build()


func _place_beside_station(kind: String, stations: Array) -> String:
	for station: Vector2i in stations:
		for offset: Vector2i in GridTopology.NEIGHBORS:
			var site: Vector2i = station + offset
			if World.can_place_plant(kind, site):
				var pid := World.place_plant(kind, site)
				if pid != "":
					return pid
	return ""


func test_economy_prices_both_kinds() -> void:
	var cfg: Dictionary = BuildSession.load_repo_json("data/catalogs/economy.json")
	# grid_forming: per-kW, ~+20 % over battery (D5)
	var gfm_kw := float((cfg["capex_eur_per_kw"] as Dictionary).get("grid_forming", 0.0))
	var bat_kw := float((cfg["capex_eur_per_kw"] as Dictionary).get("battery", 0.0))
	assert_bool(gfm_kw > bat_kw * 1.1).is_true()
	# syncon: flat per-unit (its p_max is 0, so a per-kW price is 0)
	assert_bool(float(cfg.get("syncon_meur", 0.0)) > 0.0).is_true()


## The blocking review find: sn_mva must survive World.serialize/restore
## or a saved syncon world 400s on re-register (the native row loses its
## rating and the backend validator refuses it).
func test_syncon_sn_mva_round_trips() -> void:
	assert_bool(BuildSession.load_map()).is_true()
	World.clear_build()
	var anchor: Vector2i = (World.load_centers["hamburg"]["tiles"] as Array)[0]
	var syn := World.place_plant("syncon",
		DemoBuild.find_site(World, "syncon", anchor, 10))
	assert_str(syn).is_not_empty()
	var envelope := World.serialize()
	World.clear_build()
	assert_bool(World.restore(envelope)).is_true()
	assert_bool(World.plants.has(syn)).is_true()
	assert_float(float(World.plants[syn]["sn_mva"])).is_equal(300.0)
	World.clear_build()


func test_plant_models_exist_for_both() -> void:
	var gfm: Node3D = PlantModels.make("grid_forming")
	var syn: Node3D = PlantModels.make("syncon")
	assert_object(gfm).is_not_null()
	assert_object(syn).is_not_null()
	assert_bool(gfm.get_child_count() > 0).is_true()
	assert_bool(syn.get_child_count() > 0).is_true()
	gfm.free()
	syn.free()
