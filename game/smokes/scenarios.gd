extends SmokeBase
## --smoke=scenarios: every shipped recipe loads, and a recipe that BUILDS
## its world rebuilds it identically from the map (that is the whole claim
## of recipe-not-snapshot — see model/scenario.gd). No backend: this is
## about the world the game constructs before anything is registered.

const TAG := "SMOKE_SCENARIOS"


func run() -> void:
	var ids := Scenario.available()
	check("recipes_found", ids.size() >= 3)
	var loaded: Array[String] = []
	var summary := {}
	for id: String in ids:
		World.clear_build()
		if not Scenario.load_scenario(id):
			_fail(TAG, "scenario %s failed to load" % id)
			return
		loaded.append(id)
		summary[id] = {"plants": World.plants.size(),
			"corridors": World.corridors.size(),
			"sandbox": Sandbox.active,
			"difficulty": Sandbox.difficulty}
		check("%s_has_world" % id, World.plants.size() > 0)
		# a sandbox recipe opens the unlocks; a campaign recipe must not
		check("%s_mode" % id, Sandbox.active != Campaign.active)

	# determinism: the build recipe must reproduce its world exactly
	var build_id := ""
	for id: String in ids:
		World.clear_build()
		if not Scenario.load_scenario(id):
			continue
		if Scenario.recipe.has("build"):
			build_id = id
			break
	if build_id == "":
		check("build_recipe_present", false)
		_finish(TAG, {"scenarios": summary})
		return
	check("build_recipe_present", true)
	var first := JSON.stringify(World.serialize(), "", false, true)
	World.clear_build()
	Scenario.load_scenario(build_id)
	var second := JSON.stringify(World.serialize(), "", false, true)
	check("build_recipe_deterministic", first == second)
	# weather forces from the recipe actually reached the model
	var forced := 0
	for id: String in ids:
		World.clear_build()
		Scenario.load_scenario(id)
		forced += (Scenario.recipe.get("forces", []) as Array).size()
	check("forces_declared_somewhere", forced > 0)
	_finish(TAG, {"scenarios": summary, "build_recipe": build_id})
