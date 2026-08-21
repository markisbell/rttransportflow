extends Node
## ZoneHistory — the measured week behind the site notes' graphs: per-zone
## load and generation-by-source, and per-plant output, sampled from every
## applied wire result into a 7-day ring of 15-min blocks (672 slots).
## MEASURED, never commanded (ledger 44): powers come from the result's
## devices block, so a full battery or a shed electrolyzer records what it
## actually did. Deliberately NOT in the save envelope — the week refills
## as you play, and a load clears the ring (a restored clock can sit
## anywhere in a different week, where stale stamps would lie).

const BLOCKS := 672  # 7 days x 96 blocks; week start is a multiple of 7
                     # days, so ring slot == index-within-week, always

## kind (+ h2 fuel override) -> stack group. Batteries, electrolyzers,
## pumping hydro and HVDC terminals go NEGATIVE when they draw; the chart
## splits by sign at draw time, energy-charts style.
const GROUP_OF_KIND := {
	"nuclear": "nuclear", "lignite": "lignite", "coal": "coal",
	"gas_ccgt": "gas", "gas_ocgt": "gas", "hydro_ps": "hydro",
	"wind_onshore": "wind_on", "wind_offshore": "wind_off",
	"offshore_platform": "wind_off", "solar_pv": "solar",
	"battery": "battery", "electrolyzer": "electrolysis",
	"hvdc_converter": "transfer",
}

var _stamp := PackedInt64Array()  # abs block recorded in each slot, -1 empty
var _zone_load := {}   # zone -> Array[float](BLOCKS)
var _zone_gen := {}    # zone -> {group: Array[float](BLOCKS)}
var _plant_p := {}     # pid -> Array[float](BLOCKS)


func _ready() -> void:
	_stamp.resize(BLOCKS)
	_stamp.fill(-1)
	Orchestrator.step_completed.connect(_on_step)
	SaveLoad.load_completed.connect(_on_loaded)


func _on_loaded(ok: bool, _reason: String) -> void:
	if ok:
		clear()


func clear() -> void:
	_stamp.fill(-1)
	_zone_load.clear()
	_zone_gen.clear()
	_plant_p.clear()


## Every step overwrites its block's slot, so a slot always holds the
## block's LATEST measured state — no end-of-block bookkeeping needed.
func _on_step(_t: int, result: Dictionary) -> void:
	var b := int(GameClock.t_sim / Dispatch.BLOCK_S)
	var slot := b % BLOCKS
	_stamp[slot] = b
	var t_days := GameClock.t_sim / 86400.0
	var devices: Dictionary = result.get("devices", {})
	var sums := {}  # zone -> {group: mw}
	for pid: Variant in devices:
		var zone := str(Dispatch.home_zone.get(pid, ""))
		var group := _group_for(str(pid))
		if zone == "" or group == "":
			continue
		var p := float((devices[pid] as Dictionary).get("p_mw", 0.0))
		_series(_plant_p, str(pid))[slot] = p
		var zs: Dictionary = sums.get_or_add(zone, {})
		zs[group] = float(zs.get(group, 0.0)) + p
	for zone: String in World.load_centers:
		_series(_zone_load, zone)[slot] = Demand.zone_mw(zone, t_days)
	for zone: String in sums:
		var groups: Dictionary = _zone_gen.get_or_add(zone, {})
		# a group that vanished from this block (plant removed/offline set
		# empty) must not keep last week's value in the reused slot
		for g: String in groups:
			(groups[g] as Array)[slot] = 0.0
		var zs: Dictionary = sums[zone]
		for g: String in zs:
			_series(groups, g)[slot] = float(zs[g])


func _group_for(pid: String) -> String:
	var plant: Dictionary = World.plants.get(pid, {})
	if plant.is_empty():
		return ""
	if str(plant.get("fuel", "")) == "h2":
		return "h2"
	return str(GROUP_OF_KIND.get(str(plant["kind"]), ""))


## Plain Arrays, not PackedFloat32Array: packed arrays are value types, so
## `dict[key][i] = v` writes into a silently discarded copy.
func _series(store: Dictionary, key: String) -> Array:
	if not store.has(key):
		var a := []
		a.resize(BLOCKS)
		a.fill(0.0)
		store[key] = a
	return store[key]


# ─── chart accessors (index i is the block within the current week) ─────

func week_start_day() -> int:
	return int(floorf(GameClock.t_sim / 86400.0 / 7.0)) * 7


func now_block() -> int:
	return int(GameClock.t_sim / Dispatch.BLOCK_S) - week_start_day() * 96


func valid(i: int) -> bool:
	return _stamp[i] == week_start_day() * 96 + i


func zone_load_at(zone: String, i: int) -> float:
	return float((_zone_load.get(zone, []) as Array)[i]) \
		if _zone_load.has(zone) else 0.0


func zone_groups(zone: String) -> Array:
	return (_zone_gen.get(zone, {}) as Dictionary).keys()


func zone_gen_at(zone: String, group: String, i: int) -> float:
	var groups: Dictionary = _zone_gen.get(zone, {})
	if not groups.has(group):
		return 0.0
	return float((groups[group] as Array)[i])


func plant_p_at(pid: String, i: int) -> float:
	return float((_plant_p.get(pid, []) as Array)[i]) \
		if _plant_p.has(pid) else 0.0
