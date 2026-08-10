extends Node2D
## Europe map: bus dots from grid.json geo, corridor segments, colors from
## the latest PF frame (one-step lag — the family playback pattern).

const MARGIN := 60.0
const MAP_RECT := Rect2(40, 120, 760, 620)

var _bus_geo := {}  # name -> Vector2 (lon, lat)
var _lines := []  # [{from, to}]
var _latest_buses := {}


func _ready() -> void:
	Orchestrator.step_completed.connect(_on_step)
	_load_topology()


func _load_topology() -> void:
	if not Boundary.loaded and not Boundary.load_bundle():
		return
	for bus: Dictionary in Boundary.docs["grid"].get("buses", []):
		var geo: Variant = bus.get("geo")
		if geo is Dictionary:
			_bus_geo[bus["name"]] = Vector2(float(geo["lon"]), float(geo["lat"]))
	for line: Dictionary in Boundary.docs["lines"].get("lines", []):
		_lines.append({"from": line["from_bus"], "to": line["to_bus"]})
	queue_redraw()


func _on_step(_t: int, result: Dictionary) -> void:
	_latest_buses = result.get("pf", {}).get("latest", {}).get("buses", {})
	queue_redraw()


func _project(geo: Vector2) -> Vector2:
	# equirectangular fit: lon -10..25, lat 35..60 into MAP_RECT
	var x := remap(geo.x, -10.0, 25.0, MAP_RECT.position.x, MAP_RECT.end.x)
	var y := remap(geo.y, 60.0, 35.0, MAP_RECT.position.y, MAP_RECT.end.y)
	return Vector2(x, y)


func _bus_color(bus_name: String) -> Color:
	var vm := float(_latest_buses.get(bus_name, {}).get("vm_pu", 1.0))
	if vm < 0.95 or vm > 1.05:
		return Color.RED
	return Color(0.2, 0.75, 0.35)


func _draw() -> void:
	if _bus_geo.is_empty():
		return
	for line: Dictionary in _lines:
		if _bus_geo.has(line["from"]) and _bus_geo.has(line["to"]):
			draw_line(_project(_bus_geo[line["from"]]),
				_project(_bus_geo[line["to"]]), Color(0.45, 0.5, 0.55), 2.0)
	var font := ThemeDB.fallback_font
	for bus_name: String in _bus_geo:
		var p := _project(_bus_geo[bus_name])
		draw_circle(p, 7.0, _bus_color(bus_name))
		draw_string(font, p + Vector2(10, 4), bus_name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.88, 0.9))
