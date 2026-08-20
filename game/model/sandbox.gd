extends Node
## Sandbox / classroom mode (GAME_DESIGN §5.4) and the difficulty knobs
## (§4.4, §5.3).
##
## Sandbox is not a separate game: it is the SAME map, engine and economy
## with the campaign's gates lifted (`Campaign.active == false` already
## opens every unlock) plus the teaching controls a demonstrator needs —
## set the treasury, force a weather regime, trip the largest unit NOW.
##
## Everything here writes to state the rest of the game already owns; the
## sandbox holds no simulation state of its own, so a save taken in sandbox
## loads in campaign and vice versa. Deliberately: the whole point of the
## classroom mode is to reproduce a campaign situation and poke at it.

signal knobs_changed()

## Difficulty presets: `capex` and `demand_growth` move the economy,
## `voll_scale` the cost of unserved energy. Physics is NEVER a difficulty
## knob — the swing equation is the same for everyone; only the world around
## it changes.
##
## §4.4's stochastic event table (MTBF-weighted unit trips, storm-correlated
## line trips, forecast busts) is NOT in v1: campaign incidents are the
## scripted ones in campaign_v1.json plus whatever the player's own grid
## does to itself. There is deliberately no `event_rate` knob here rather
## than a knob that scales nothing.
const PRESETS := {
	"relaxed": {"capex": 0.85, "demand_growth": 0.5, "voll_scale": 0.5},
	"normal": {"capex": 1.0, "demand_growth": 1.0, "voll_scale": 1.0},
	"demanding": {"capex": 1.15, "demand_growth": 1.4, "voll_scale": 1.5},
}

var active := false
var difficulty := "normal"
var knobs: Dictionary = PRESETS["normal"].duplicate()


func start(with_difficulty: String = "normal") -> void:
	active = true
	Campaign.active = false  # every unlock open, no milestone clock
	set_difficulty(with_difficulty)


func set_difficulty(name: String) -> void:
	if not PRESETS.has(name):
		return
	difficulty = name
	knobs = (PRESETS[name] as Dictionary).duplicate()
	knobs_changed.emit()


func knob(key: String, fallback: float = 1.0) -> float:
	return float(knobs.get(key, fallback))


# ------------------------------------------------------------ controls

func set_treasury_meur(value_meur: float) -> void:
	Economy.treasury_eur = value_meur * 1e6


## "Trip the largest unit NOW" — the classroom button. Same path as the
## debug key and the campaign's scripted incidents: a scheduled engine
## event, never a game-side fake.
func trip_largest_unit(delay_s: float = 1.0) -> String:
	var ranked: Array = FleetQuery.online_sync_ranked(
		Orchestrator.latest().get("devices", {}))
	var best_id: String = str(ranked.front()) if not ranked.is_empty() else ""
	if best_id != "":
		Orchestrator.inject([{"at_s_rel": delay_s, "kind": "trip",
			"element": best_id}])
	return best_id


## Weather overrides, exposed as a window starting now (§5.4). `kind` is one
## of Weather's force kinds; `hours` bounds it so a demo cannot silently
## poison the rest of the session.
func force_weather(kind: String, value: float, hours: float = 6.0,
		region: String = "") -> void:
	var t0 := GameClock.t_sim / 86400.0
	Weather.force_window(kind, region, t0, t0 + hours / 24.0, value)


func clear_weather_forces() -> void:
	Weather.clear_forces()


func to_dict() -> Dictionary:
	return {"active": active, "difficulty": difficulty}


func from_dict(state: Dictionary) -> void:
	active = bool(state.get("active", false))
	set_difficulty(str(state.get("difficulty", "normal")))
