class_name GridcoBoot
extends RefCounted
## The GridCo model boot ritual — ONE owner. It was copy-pasted across
## main.gd (twice), two smoke bases and three smokes, so a fix to boot
## ordering had to be replicated everywhere or silently diverged.
##
## Order is load-bearing: the map must be loaded (BuildSession.load_map)
## BEFORE this runs — Dispatch/Demand resolve regions through the map
## projection — and the catalogs are the single source of truth for every
## constant. The economy catalog is loaded once and shared by Dispatch and
## Economy (both only read it).

const SEED := 42


static func setup_models() -> void:
	var economy_cfg: Dictionary = BuildSession.load_repo_json("data/catalogs/economy.json")
	Weather.setup(SEED)
	Demand.setup(SEED)
	Demand.weather = Weather
	Dispatch.setup(economy_cfg,
		BuildSession.load_repo_json("data/catalogs/plant_types.json").get("kinds", {}))
	Economy.setup(economy_cfg)
