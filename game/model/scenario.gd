extends Node
## Scenarios as RECIPES, not snapshots (GAME_DESIGN §5.4).
##
## A snapshot freezes tile coordinates and plant ids; it breaks the moment
## the map is regenerated — which has happened twice already (50 km → 15 km
## → 5 km), each time invalidating every saved world in the repo. A recipe
## says what the situation IS ("the inherited mainland fleet, seed 42,
## January, these scripted incidents") and rebuilds it deterministically on
## whatever map ships. Same recipe + same seed = same world, verifiable by
## a smoke rather than by a 4 MB diff.
##
## A recipe may still point at an authored world file when the situation is
## genuinely hand-built (the campaign's inherited backbone is), but the
## seeds, weather forces, difficulty and scripted events always come from
## the recipe — those are what make a scenario a scenario.

const DIR := "data/scenarios"

var loaded_id := ""
var recipe: Dictionary = {}


func available() -> Array[String]:
	var ids: Array[String] = []
	var dir := DirAccess.open(AppPaths.root().path_join(DIR))
	if dir == null:
		return ids
	for file: String in dir.get_files():
		if file.ends_with(".json"):
			ids.append(file.trim_suffix(".json"))
	ids.sort()
	return ids


## Load and APPLY a recipe: map, world, seeds, difficulty, weather forces,
## scripted events. Returns false (and leaves the game untouched enough to
## retry) if anything essential is missing.
func load_scenario(id: String) -> bool:
	var path := AppPaths.root().path_join(DIR).path_join(id + ".json")
	if not FileAccess.file_exists(path):
		push_warning("scenario %s not found at %s" % [id, path])
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_warning("scenario %s is not a JSON object" % id)
		return false
	recipe = parsed as Dictionary
	loaded_id = id

	if not BuildSession.load_map():
		return false
	var seed_value := int(recipe.get("seed", 42))
	Weather.setup(seed_value)
	Demand.setup(seed_value)
	Demand.weather = Weather

	if not _apply_world():
		return false

	# Mid-campaign recipes (C1): the clock moves BEFORE the campaign arms,
	# so start_campaign() applies the era/year the recipe's day implies.
	# Wire t is a sequence number (ledger 3) — the backend is indifferent.
	# ALWAYS set (default 0): a recipe without start_day must not inherit
	# the previous recipe's clock. The billing counter re-anchors with it.
	GameClock.t_sim = float(recipe.get("start_day", 0.0)) * GameClock.SECONDS_PER_DAY
	Economy.sync_billing_day()

	# The battery policy is a GLOBAL dispatch knob a previous session/recipe
	# may have moved (the review: reserve_ffr set in one scenario silently
	# changed the next recipe's pinned behavior — the plant_mode leak class,
	# which four smokes already clear by hand). A recipe starts from the
	# pin-stable default; a policy key on the recipe can override later.
	Dispatch.set_battery_policy(str(recipe.get("battery_policy", "arbitrage")))
	Dispatch.plant_mode.clear()
	Restoration.reset()

	# Sandbox/campaign are mutually exclusive framings of the same world.
	if bool(recipe.get("sandbox", false)):
		Sandbox.start(str(recipe.get("difficulty", "normal")))
	else:
		Sandbox.active = false
		Sandbox.set_difficulty(str(recipe.get("difficulty", "normal")))
		if Campaign.load_data():
			Campaign.start_campaign()
			if recipe.has("campaign"):
				Campaign.apply_recipe_state(recipe["campaign"])

	if (recipe.get("economy", {}) as Dictionary).has("treasury_eur"):
		Economy.treasury_eur = float(
			(recipe["economy"] as Dictionary)["treasury_eur"])

	Weather.clear_forces()
	for force: Dictionary in recipe.get("forces", []):
		Weather.force_window(str(force.get("kind", "")),
			str(force.get("region", "")), float(force.get("t0_days", 0.0)),
			float(force.get("t1_days", 0.0)), float(force.get("value", 1.0)))
	return true


## Either restore an authored world, rebuild one from a build recipe, or
## GENERATE an era-progressed world (C4: recipes for mid-campaign slices
## whose worlds are the start world plus the plausible player build —
## GridPlan.author_era, one author, deterministic).
func _apply_world() -> bool:
	var era := str(recipe.get("author_era", ""))
	if era != "":
		World.clear_build()
		if GridPlan.author_era(World, era):
			return true
		push_warning("scenario %s: author_era(%s) failed" % [loaded_id, era])
		return false
	var world_path := str(recipe.get("world", ""))
	if world_path != "":
		var full := AppPaths.root().path_join(world_path)
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(full))
		if parsed is Dictionary and World.restore(parsed as Dictionary):
			return true
		push_warning("scenario %s: world %s failed to restore" % [loaded_id, world_path])
		return false
	var build: Dictionary = recipe.get("build", {})
	var metros: Array[String] = []
	for entry: Variant in build.get("metros", []):
		metros.append(str(entry))
	if metros.is_empty():
		push_warning("scenario %s has neither `world` nor `build.metros`" % loaded_id)
		return false
	return DemoBuild.auto_build(World, metros)


func to_dict() -> Dictionary:
	return {"id": loaded_id}


func from_dict(state: Dictionary) -> void:
	loaded_id = str(state.get("id", ""))
