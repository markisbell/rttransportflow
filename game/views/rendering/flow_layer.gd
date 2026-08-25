extends MeshInstance3D
## Animated power flow over the strategic ribbons (C2 owner request): at
## far zoom, moving dashes show WHERE the power flows — direction from the
## wire's signed p_from_mw (positive runs path-forward: the topology walk
## records each line's tile path from_bus → to_bus), speed and brightness
## from loading_percent. The mesh builds ONCE per registered topology
## (UV.x = accumulated tiles along the path, so dashes stay continuous
## through corners; UV2.x = the line's texel column) and each APPLIED wire
## step writes one small float texture — the animation itself is pure
## shader TIME, zero per-frame CPU. Flow numbers are the PF's
## sample-and-hold block (CALM cadence 30 s of sim time); a line absent
## from pf.latest.lines (tripped) goes dark while its base ribbon stays.
## No class_name (the sandbox_panel headless-cache lesson).

const RIBBON_W := 0.85  # wider than the base ribbon: room for the halo +
# backing (owner review: 0.30 mix-blended dashes drowned in pale terrain)
const LIFT := 0.10      # above RIBBON_LIFT 0.07: dashes ride on top
const MAX_LINES := 512  # texel columns; the node budget caps branches at 300

var _line_index := {}  # line id -> texel column
var _flow_image: Image
var _flow_tex: ImageTexture
var _material: ShaderMaterial


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = preload("res://views/rendering/flow_dashes.gdshader")
	_material.render_priority = 10
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flow_image = Image.create(MAX_LINES, 1, false, Image.FORMAT_RGF)
	_flow_tex = ImageTexture.create_from_image(_flow_image)
	_material.set_shader_parameter("flow_tex", _flow_tex)
	Orchestrator.step_completed.connect(_on_step)


## Mirrors the base ribbons' sun dim (they use albedo_color; a
## ShaderMaterial needs the uniform — the documented cast trap).
func set_day_level(level: float) -> void:
	_material.set_shader_parameter("day_level", level)


## Zoom-adaptive dash length: from orbit a 0.7-tile dash is a speck —
## stretch toward ~3-tile dashes at MAX_ZOOM, tighten near the band edge.
func set_zoom(zoom: float) -> void:
	_material.set_shader_parameter("dash_density",
		clampf(48.0 / maxf(zoom, 1.0), 0.35, 1.4))


## Build the dash ribbons from interpretation.line_paths and a ground
## height callable ((tile: Vector2i) -> float).
func build_from(line_paths: Dictionary, ground: Callable) -> void:
	_line_index.clear()
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	var column := 0
	for line_id: String in line_paths:
		if column >= MAX_LINES:
			push_warning("flow layer: > %d lines — the rest stay unanimated"
				% MAX_LINES)
			break
		var raw: Array = line_paths[line_id]
		if raw.size() < 2:
			continue
		# Diagonal FILLER tiles staircase the walked path while the base
		# ribbon cuts the corner (StrategicGrid resolves fillers to their
		# far ends) — dashes wandered off every diagonal line (owner
		# review). Skip fillers the same way; endpoints always survive.
		var path: Array = []
		for i in range(raw.size()):
			if i == 0 or i == raw.size() - 1 \
					or not World.diag_fillers.has(raw[i]):
				path.append(raw[i])
		if path.size() < 2:
			continue
		_line_index[line_id] = column
		var u := 0.0
		for i in range(path.size() - 1):
			var a: Vector2i = path[i]
			var b: Vector2i = path[i + 1]
			var pa := Vector3(a.x + 0.5, float(ground.call(a)) + LIFT, a.y + 0.5)
			var pb := Vector3(b.x + 0.5, float(ground.call(b)) + LIFT, b.y + 0.5)
			var seg := Vector2(pb.x - pa.x, pb.z - pa.z)
			var seg_len := seg.length()
			if seg_len < 1e-6:
				continue
			var side := Vector3(-seg.y, 0.0, seg.x) / seg_len * (RIBBON_W * 0.5)
			var base := verts.size()
			verts.append_array([pa - side, pa + side, pb + side, pb - side])
			uvs.append_array([Vector2(u, 0.0), Vector2(u, 1.0),
				Vector2(u + seg_len, 1.0), Vector2(u + seg_len, 0.0)])
			for _corner in 4:
				uv2s.append(Vector2(float(column), 0.0))
			indices.append_array([base, base + 1, base + 2,
				base, base + 2, base + 3])
			u += seg_len
		column += 1
	var built := ArrayMesh.new()
	if verts.size() > 0:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
		arrays[Mesh.ARRAY_INDEX] = indices
		built.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = built
	_clear_flows()


func _on_step(_t: int, result: Dictionary) -> void:
	if _line_index.is_empty():
		return
	var pf: Dictionary = result.get("pf", {})
	var latest: Dictionary = pf.get("latest", {})
	var lines: Dictionary = latest.get("lines", {})
	for line_id: String in _line_index:
		var entry: Dictionary = lines.get(line_id, {})
		var texel := flow_texel(Wire.numf(entry, "p_from_mw", 0.0),
			Wire.numf(entry, "loading_percent", 0.0), not entry.is_empty())
		_flow_image.set_pixel(int(_line_index[line_id]), 0,
			Color(texel.x, texel.y, 0.0))
	_flow_tex.update(_flow_image)


func _clear_flows() -> void:
	_flow_image.fill(Color(0.0, 0.0, 0.0))
	_flow_tex.update(_flow_image)


## Pure wire→texel mapping (GdUnit-pinned): signed dash speed [tiles/s]
## and intensity [0..1]. Absent entry (tripped line) is dark; visible from
## ~2 % loading so an idle grid does not shimmer; speed and brightness
## climb with loading (an overload reads urgent before the relay says so).
static func flow_texel(p_from_mw: float, loading_pct: float,
		present: bool) -> Vector2:
	if not present or loading_pct <= 0.0:
		return Vector2.ZERO
	var load01 := clampf(loading_pct / 100.0, 0.0, 1.5)
	var direction := 1.0 if p_from_mw >= 0.0 else -1.0
	var speed := direction * (0.35 + 1.4 * load01)
	# visibility floor at 0.55 (owner review: low-load lines were near
	# invisible); still monotone in loading and dark when absent/idle
	var intensity := clampf(0.55 + 0.45 * load01, 0.0, 1.0) \
		* smoothstep(0.0, 0.02, load01)
	return Vector2(speed, intensity)
