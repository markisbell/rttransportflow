class_name PlantModels
extends RefCounted
## Procedural component models (the infrastruct BuildingModels pattern):
## every plant, device, pylon and metro block is a by-eye rebuild from
## primitives — nothing downloaded, no licenses attach. Pure static
## factories over flat()/box()/cyl(); no scene or autoload reads, so the
## gallery, the palette thumbnails and the world renderer all share one
## library.
##
## SCALE: one tile = 1.0 world unit; the tile's real length is defined by
## the map (currently 5 km — ledger 38). These are SYMBOLS, not scale
## models — a 1600 MW station reads at a glance because its silhouette says
## "nuclear", not because the cooling tower is to scale. Every
## make() model fits a 0.9 x 0.9 footprint centred on the origin, base at
## y = 0, height <= 1.6 so a plant never hides its neighbours.

## Corridor accent colours — the game's line language (world_view_3d /
## build_menu): 400 kV red, 220 kV green, HVDC violet. Steel stays grey;
## the colour rides the conductors and a crossarm cap so a corridor's
## voltage reads from the air at any zoom.
const LINE_400_COLOR := Color(0.90, 0.25, 0.20)
const LINE_220_COLOR := Color(0.20, 0.75, 0.35)
const HVDC_COLOR := Color(0.55, 0.25, 0.85)

const STEEL := Color(0.60, 0.62, 0.66)
const STEEL_DARK := Color(0.44, 0.46, 0.50)
const CONCRETE := Color(0.72, 0.71, 0.68)
const PAD_GREY := Color(0.58, 0.58, 0.55)
const HALL_LIGHT := Color(0.82, 0.83, 0.86)
const ROOF_GREY := Color(0.40, 0.42, 0.47)
const WHITE := Color(0.95, 0.96, 0.97)
const WATER_BLUE := Color(0.18, 0.40, 0.62)
const TRANSFORMER := Color(0.62, 0.63, 0.65)
const HAZARD := Color(0.95, 0.80, 0.15)
## Hydrogen-chain accent (electrolyzer + cavern share it — one teal, not two)
const H2_TEAL := Color(0.20, 0.68, 0.66)

const KENNEY := "res://assets/kenney/"

static var _material_cache := {}
static var _scene_cache := {}
static var _mesh_cache := {}


# ─── primitive factories ───────────────────────────────────────────────
#
# Meshes are SHARED, keyed by their shape parameters. Procedural models
# repeat the same primitive thousands of times — every corridor pylon is
# the same lattice, every turbine the same spinner — and a fresh Mesh
# resource per call is a fresh set of RenderingDevice buffers: the
# continental boot allocated tens of thousands that way and exhausted the
# renderer's RID pool at first build ("Element limit reached",
# 2026-08-21) — every draw errored, the error spam saturated the main
# thread, and the process eventually crashed. Parameter-keyed sharing
# collapses the count to one mesh per DISTINCT shape (a few dozen) with
# zero geometry change. Consequence: never mutate a mesh after it leaves
# a factory — per-instance looks go through material_override and the
# node transform. Keys round to 1e-4 tile (~0.5 m) to absorb float noise
# between equivalent computations.


static func _box_mesh(size: Vector3) -> BoxMesh:
	var key := "b|%.4f|%.4f|%.4f" % [size.x, size.y, size.z]
	var mesh: BoxMesh = _mesh_cache.get(key)
	if mesh == null:
		mesh = BoxMesh.new()
		mesh.size = size
		_mesh_cache[key] = mesh
	return mesh


static func _cyl_mesh(top_r: float, bottom_r: float, height: float,
		segments: int) -> CylinderMesh:
	var key := "c|%.4f|%.4f|%.4f|%d" % [top_r, bottom_r, height, segments]
	var mesh: CylinderMesh = _mesh_cache.get(key)
	if mesh == null:
		mesh = CylinderMesh.new()
		mesh.top_radius = top_r
		mesh.bottom_radius = bottom_r
		mesh.height = height
		mesh.radial_segments = segments
		_mesh_cache[key] = mesh
	return mesh


static func _sphere_mesh(radius: float, height: float, radial: int,
		rings: int, hemisphere: bool) -> SphereMesh:
	var key := "s|%.4f|%.4f|%d|%d|%s" % [radius, height, radial, rings, hemisphere]
	var mesh: SphereMesh = _mesh_cache.get(key)
	if mesh == null:
		mesh = SphereMesh.new()
		mesh.radius = radius
		mesh.height = height
		mesh.radial_segments = radial
		mesh.rings = rings
		mesh.is_hemisphere = hemisphere
		_mesh_cache[key] = mesh
	return mesh

static func flat(color: Color, transparent: bool = false,
		unshaded: bool = false) -> StandardMaterial3D:
	var key := "%s|%s|%s" % [color.to_html(), transparent, unshaded]
	if not _material_cache.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		if transparent:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if unshaded:
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material_cache[key] = material
	return _material_cache[key]


## Emissive accent (aircraft warning lights, HVDC valve-hall strips) —
## SHADED, so it glows without blooming the whole tile at dusk.
static func glow(color: Color) -> StandardMaterial3D:
	var key := "glow|" + color.to_html()
	if not _material_cache.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.6
		_material_cache[key] = material
	return _material_cache[key]


static func box(size: Vector3, color: Color, offset: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = _box_mesh(size)
	node.position = offset
	node.material_override = flat(color)
	return node


static func cyl(radius: float, height: float, color: Color,
		offset: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = _cyl_mesh(radius, radius, height, 12)
	node.position = offset
	node.material_override = flat(color)
	return node


## Tapered cylinder — the workhorse for stacks, towers and turbine masts.
static func taper(top_r: float, bottom_r: float, height: float, color: Color,
		offset: Vector3, segments: int = 12) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = _cyl_mesh(top_r, bottom_r, height, segments)
	node.position = offset
	node.material_override = flat(color)
	return node


## A straight member between two points — conductors, lattice diagonals and
## guy wires all come from here (a thin box beats a cylinder: 12 fewer
## verts and the isometric camera never sees the difference).
static func strut(from: Vector3, to: Vector3, thickness: float,
		color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = _box_mesh(Vector3(thickness, thickness, from.distance_to(to)))
	node.transform = Transform3D(
		Basis.looking_at((to - from).normalized(), Vector3.UP),
		(from + to) / 2.0)
	node.material_override = flat(color)
	return node


## Ground slab every industrial site stands on: without it the models look
## like they were dropped on grass, and the pad reads as "site" at a glance.
static func pad(size: float, color: Color = PAD_GREY) -> MeshInstance3D:
	return box(Vector3(size, 0.04, size), color, Vector3(0, 0.02, 0))


static func _instance_glb(rel_path: String, fit: float) -> Node3D:
	var path := KENNEY + rel_path
	if not _scene_cache.has(path):
		_scene_cache[path] = load(path)
	var scene: PackedScene = _scene_cache[path]
	if scene == null:
		push_warning("PlantModels: missing model " + path)
		return box(Vector3(0.4, 0.4, 0.4), Color(0.9, 0.2, 0.9), Vector3(0, 0.2, 0))
	# container wrapper: callers may set position/rotation on the returned
	# node without clobbering the grounding offset applied inside
	var container := Node3D.new()
	var inner: Node3D = scene.instantiate()
	container.add_child(inner)
	var bounds := aabb_of(inner)
	var extent := maxf(bounds.size.x, bounds.size.z)
	if extent > 0.001:
		var scale_factor := fit / extent
		inner.scale = Vector3.ONE * scale_factor
		var bottom_center := bounds.position + Vector3(
			bounds.size.x / 2.0, 0.0, bounds.size.z / 2.0)
		inner.position = -bottom_center * scale_factor
	return container


static func aabb_of(node: Node) -> AABB:
	var total := AABB()
	var first := true
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		var bounds := mesh.transform * mesh.get_aabb()
		total = bounds if first else total.merge(bounds)
		first = false
	return total


# ─── shared sub-assemblies ─────────────────────────────────────────────

## Natural-draught cooling tower: the hyperboloid faked by stacking short
## cylinders whose radius pinches at the waist and flares at the lip. The
## single most recognisable thermal-plant silhouette, so nuclear/coal/
## lignite all borrow it at different sizes.
static func _cooling_tower(base_r: float, height: float,
		plume: bool = true) -> Node3D:
	var node := Node3D.new()
	var rings := 6
	for i in rings:
		var t0 := float(i) / rings
		var t1 := float(i + 1) / rings
		node.add_child(taper(_hyper_r(base_r, t1), _hyper_r(base_r, t0),
			height / rings, CONCRETE,
			Vector3(0, height * (t0 + t1) / 2.0, 0), 14))
	# open air intake: dark ring of legs around the flared foot
	for i in 8:
		var a := TAU * i / 8.0
		node.add_child(box(Vector3(0.02, height * 0.1, 0.02), STEEL_DARK,
			Vector3(cos(a) * base_r * 0.92, height * 0.05, sin(a) * base_r * 0.92)))
	if plume:
		# steam cap: two soft discs above the lip — the "it is running" tell
		node.add_child(taper(_hyper_r(base_r, 1.0) * 1.25,
			_hyper_r(base_r, 1.0) * 0.9, 0.05, Color(0.96, 0.97, 0.99, 0.85),
			Vector3(0, height + 0.04, 0), 14))
		var puff := taper(_hyper_r(base_r, 1.0) * 1.5,
			_hyper_r(base_r, 1.0) * 1.2, 0.06, Color(0.98, 0.98, 1.0, 0.6),
			Vector3(0, height + 0.11, 0), 14)
		puff.material_override = flat(Color(0.98, 0.98, 1.0, 0.6), true)
		node.add_child(puff)
	return node


## Hyperboloid profile: 1.0 at the foot, 0.62 at the waist (~60 % up),
## flaring back to 0.78 at the lip.
static func _hyper_r(base_r: float, t: float) -> float:
	var waist := 0.6
	if t <= waist:
		return base_r * lerpf(1.0, 0.62, t / waist)
	return base_r * lerpf(0.62, 0.78, (t - waist) / (1.0 - waist))


## Red/white banded flue stack (ICAO day marking) — every fired plant has
## one, only the height and slenderness change.
static func _banded_stack(radius: float, height: float, bands: int,
		offset: Vector3, band_color: Color = Color(0.80, 0.22, 0.18)) -> Node3D:
	var node := Node3D.new()
	var seg_h := height / bands
	for s in bands:
		var t0 := float(s) / bands
		var t1 := float(s + 1) / bands
		node.add_child(taper(radius * (1.0 - t1 * 0.25), radius * (1.0 - t0 * 0.25),
			seg_h, WHITE if s % 2 == 0 else band_color,
			offset + Vector3(0, height * (t0 + t1) / 2.0, 0), 10))
	# aircraft warning light on the rim
	var lamp := box(Vector3(0.02, 0.02, 0.02), Color(1.0, 0.25, 0.2),
		offset + Vector3(radius * 0.7, height, 0))
	lamp.material_override = glow(Color(1.0, 0.25, 0.2))
	node.add_child(lamp)
	return node


## Oil-filled power transformer: tank, radiator fins, three bushings. The
## unit that says "this is electrical plant" wherever it appears.
static func _transformer(scale_f: float = 1.0) -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(0.16, 0.12, 0.11) * scale_f, TRANSFORMER,
		Vector3(0, 0.06 * scale_f, 0)))
	for i in 5:  # radiator fin bank down one flank
		node.add_child(box(Vector3(0.006, 0.10, 0.08) * scale_f,
			Color(0.70, 0.71, 0.73),
			Vector3((0.09 + i * 0.011) * scale_f, 0.055 * scale_f, 0)))
	for b in 3:  # porcelain bushings on the lid
		var bz := (-0.035 + b * 0.035) * scale_f
		node.add_child(taper(0.006 * scale_f, 0.009 * scale_f, 0.07 * scale_f,
			Color(0.30, 0.24, 0.20),
			Vector3(0, 0.155 * scale_f, bz), 8))
	return node


## Lattice A-frame gantry carrying busbars — the substation's skyline.
static func _gantry(width: float, height: float, accent: Color) -> Node3D:
	var node := Node3D.new()
	for side: float in [-width / 2.0, width / 2.0]:
		node.add_child(strut(Vector3(side, 0, -0.02), Vector3(side, height, 0.0),
			0.012, STEEL))
		node.add_child(strut(Vector3(side, 0, 0.02), Vector3(side, height, 0.0),
			0.012, STEEL))
		for d in 3:  # diagonal bracing, alternating direction
			var y0 := height * d / 3.0
			var y1 := height * (d + 1) / 3.0
			node.add_child(strut(Vector3(side, y0, -0.02), Vector3(side, y1, 0.02),
				0.007, STEEL_DARK))
	node.add_child(box(Vector3(width + 0.04, 0.012, 0.03), STEEL,
		Vector3(0, height, 0)))
	# three busbar conductors slung under the crossbeam
	for c in 3:
		node.add_child(box(Vector3(width + 0.02, 0.008, 0.008), accent,
			Vector3(0, height - 0.05, -0.03 + c * 0.03)))
	return node


## Chain-link perimeter fence: the cheapest prop that makes a bare pad read
## as a guarded industrial site.
static func _fence(size: float) -> Node3D:
	var node := Node3D.new()
	var half := size / 2.0
	var posts := 7
	for i in posts + 1:
		var t := -half + size * i / float(posts)
		for edge: Vector3 in [Vector3(t, 0, -half), Vector3(t, 0, half),
				Vector3(-half, 0, t), Vector3(half, 0, t)]:
			node.add_child(box(Vector3(0.012, 0.09, 0.012), STEEL_DARK,
				edge + Vector3(0, 0.045, 0)))
	for rail_y: float in [0.045, 0.085]:
		node.add_child(box(Vector3(size, 0.006, 0.006), STEEL_DARK,
			Vector3(0, rail_y, -half)))
		node.add_child(box(Vector3(size, 0.006, 0.006), STEEL_DARK,
			Vector3(0, rail_y, half)))
		node.add_child(box(Vector3(0.006, 0.006, size), STEEL_DARK,
			Vector3(-half, rail_y, 0)))
		node.add_child(box(Vector3(0.006, 0.006, size), STEEL_DARK,
			Vector3(half, rail_y, 0)))
	return node


## One three-bladed HAWT. Shared by the onshore farm, the offshore farm and
## the platform's dressing — only the tower height and foot differ.
static func _turbine(tower_h: float, blade_len: float,
		phase_deg: float = 0.0) -> Node3D:
	var node := Node3D.new()
	node.add_child(taper(0.014, 0.030, tower_h, WHITE,
		Vector3(0, tower_h / 2.0, 0), 10))
	node.add_child(box(Vector3(0.05, 0.05, 0.13), Color(0.88, 0.89, 0.91),
		Vector3(0, tower_h, -0.01)))
	var rotor := Node3D.new()
	rotor.position = Vector3(0, tower_h, 0.06)
	rotor.rotation_degrees.z = phase_deg
	rotor.set_meta("rotor", true)  # the renderer spins these with wind
	var spinner := MeshInstance3D.new()
	spinner.mesh = _sphere_mesh(0.026, 0.052, 10, 5, false)
	spinner.scale = Vector3(1, 1, 1.4)
	spinner.material_override = flat(WHITE)
	rotor.add_child(spinner)
	for blade_i in 3:
		var arm := Node3D.new()
		arm.rotation_degrees.z = blade_i * 120.0
		var blade := taper(0.006, 0.022, blade_len, WHITE,
			Vector3(0, blade_len / 2.0 + 0.02, 0), 6)
		blade.scale = Vector3(1, 1, 0.3)  # flatten to an airfoil slab
		arm.add_child(blade)
		var tip := taper(0.007, 0.011, blade_len * 0.16, Color(0.83, 0.22, 0.22),
			Vector3(0, blade_len * 0.94, 0), 6)
		tip.scale = Vector3(1, 1, 0.3)
		arm.add_child(tip)
		rotor.add_child(arm)
	node.add_child(rotor)
	return node


## Shallow water plane for the offshore models — sits just above the site
## pad so the jacket/monopiles are visibly standing IN something.
static func _water_plane(size: float) -> MeshInstance3D:
	var water := box(Vector3(size, 0.02, size), WATER_BLUE, Vector3(0, 0.03, 0))
	water.material_override = flat(Color(0.18, 0.40, 0.62, 0.9), true)
	return water


# ─── public dispatch ───────────────────────────────────────────────────

## Plants and devices. Returns null for an unknown kind so the renderer can
## fall back to a marker box.
static func make(kind: String) -> Node3D:
	match kind:
		"nuclear": return _make_nuclear()
		"coal": return _make_coal(false)
		"lignite": return _make_coal(true)
		"gas_ccgt": return _make_ccgt()
		"gas_ocgt": return _make_ocgt()
		"hydro_ps": return _make_hydro_ps()
		"wind_onshore": return _make_wind_onshore()
		"wind_offshore": return _make_wind_offshore()
		"solar_pv": return _make_solar_pv()
		"battery": return _make_battery()
		"electrolyzer": return _make_electrolyzer()
		"h2_cavern": return _make_h2_cavern()
		"hvdc_converter": return _make_hvdc_converter()
		"offshore_platform": return _make_offshore_platform()
		"substation": return _make_substation()
	return null


# ─── thermal plants ────────────────────────────────────────────────────

## Nuclear: two natural-draught cooling towers dominate, the containment
## dome sits low and fat beside the turbine hall. Blue-grey palette — the
## "clean but enormous" read, and the tallest silhouette in the game.
static func _make_nuclear() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.9, Color(0.62, 0.63, 0.60)))
	var tower_a := _cooling_tower(0.17, 0.72)
	tower_a.position = Vector3(0.21, 0.04, 0.20)
	node.add_child(tower_a)
	var tower_b := _cooling_tower(0.15, 0.62)
	tower_b.position = Vector3(0.24, 0.04, -0.22)
	node.add_child(tower_b)
	# containment: cylinder + hemispherical cap, the reactor's signature
	node.add_child(cyl(0.13, 0.26, Color(0.86, 0.87, 0.88), Vector3(-0.19, 0.17, 0.13)))
	var dome := MeshInstance3D.new()
	dome.mesh = _sphere_mesh(0.13, 0.26, 16, 8, true)
	dome.position = Vector3(-0.19, 0.30, 0.13)
	dome.material_override = flat(Color(0.86, 0.87, 0.88))
	node.add_child(dome)
	node.add_child(box(Vector3(0.02, 0.10, 0.02), STEEL, Vector3(-0.19, 0.46, 0.13)))
	# turbine hall: long low shed with a ribbed roof
	node.add_child(box(Vector3(0.30, 0.16, 0.34), HALL_LIGHT, Vector3(-0.20, 0.12, -0.18)))
	node.add_child(box(Vector3(0.32, 0.03, 0.36), ROOF_GREY, Vector3(-0.20, 0.21, -0.18)))
	for i in 4:
		node.add_child(box(Vector3(0.30, 0.02, 0.015), Color(0.55, 0.57, 0.62),
			Vector3(-0.20, 0.23, -0.30 + i * 0.08)))
	var tr := _transformer(1.0)
	tr.position = Vector3(0.02, 0.04, -0.36)
	node.add_child(tr)
	node.add_child(_fence(0.88))
	return node


## Coal / lignite: boiler house is the tall block, one banded stack spears
## the sky, two smaller cooling towers behind, and a fuel yard with heaps.
## Lignite gets a browner, bigger yard — it burns its own mine.
static func _make_coal(is_lignite: bool) -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.9, Color(0.55, 0.54, 0.51)))
	var yard_color := Color(0.30, 0.24, 0.19) if is_lignite else Color(0.16, 0.15, 0.15)
	var yard_w := 0.40 if is_lignite else 0.32
	node.add_child(box(Vector3(yard_w, 0.02, 0.34), yard_color,
		Vector3(-0.24, 0.05, -0.20)))
	for i in 3:  # conical fuel heaps
		node.add_child(taper(0.005, 0.055, 0.09, yard_color.lightened(0.06),
			Vector3(-0.36 + i * 0.11, 0.09, -0.20 + (i % 2) * 0.10), 10))
	# boiler house: tall narrow block with a service tower up its flank
	node.add_child(box(Vector3(0.24, 0.38, 0.24), Color(0.74, 0.72, 0.70),
		Vector3(0.02, 0.23, 0.16)))
	node.add_child(box(Vector3(0.26, 0.03, 0.26), ROOF_GREY, Vector3(0.02, 0.435, 0.16)))
	node.add_child(box(Vector3(0.07, 0.44, 0.07), Color(0.66, 0.64, 0.62),
		Vector3(-0.13, 0.26, 0.16)))
	# turbine hall alongside
	node.add_child(box(Vector3(0.30, 0.14, 0.18), HALL_LIGHT, Vector3(0.05, 0.11, -0.10)))
	node.add_child(box(Vector3(0.32, 0.03, 0.20), ROOF_GREY, Vector3(0.05, 0.19, -0.10)))
	node.add_child(_banded_stack(0.045, 0.86, 7, Vector3(0.30, 0.04, 0.32)))
	var tower := _cooling_tower(0.12, 0.44)
	tower.position = Vector3(0.28, 0.04, -0.30)
	node.add_child(tower)
	var tr := _transformer(0.9)
	tr.position = Vector3(-0.10, 0.04, -0.36)
	node.add_child(tr)
	node.add_child(_fence(0.88))
	return node


## CCGT: gas turbine hall + the HRSG boiler box (the tell — a boxy heat
## recovery unit bolted to the turbine) + slim stack + transformer yard.
## Cleaner, lower and tidier than coal: the modern workhorse.
static func _make_ccgt() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.9, Color(0.60, 0.60, 0.58)))
	node.add_child(box(Vector3(0.40, 0.20, 0.26), HALL_LIGHT, Vector3(-0.14, 0.14, 0.14)))
	for i in 3:  # vaulted roof over the turbine hall
		var vault := taper(0.10, 0.10, 0.38, Color(0.74, 0.76, 0.80),
			Vector3(-0.14, 0.26, 0.04 + i * 0.10), 10)
		vault.rotation.z = PI / 2
		node.add_child(vault)
	# HRSG: tall ribbed box, the heat-recovery boiler
	node.add_child(box(Vector3(0.20, 0.34, 0.22), Color(0.66, 0.68, 0.72),
		Vector3(0.16, 0.21, 0.12)))
	for i in 4:
		node.add_child(box(Vector3(0.205, 0.012, 0.225), STEEL_DARK,
			Vector3(0.16, 0.10 + i * 0.08, 0.12)))
	node.add_child(_banded_stack(0.034, 0.60, 5, Vector3(0.32, 0.04, -0.06),
		Color(0.35, 0.37, 0.42)))
	# gas skid: the orange fuel-receiving station
	node.add_child(box(Vector3(0.16, 0.11, 0.13), Color(0.85, 0.58, 0.20),
		Vector3(-0.30, 0.09, -0.26)))
	for i in 2:
		var tr := _transformer(0.85)
		tr.position = Vector3(-0.02 + i * 0.17, 0.04, -0.32)
		node.add_child(tr)
	node.add_child(_fence(0.88))
	return node


## OCGT: one skid-mounted turbine box, a plain exhaust stack, a small
## transformer. Deliberately tiny — the peaker you can drop anywhere.
static func _make_ocgt() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.62, Color(0.60, 0.60, 0.58)))
	node.add_child(box(Vector3(0.30, 0.14, 0.18), Color(0.80, 0.81, 0.84),
		Vector3(-0.04, 0.11, 0.03)))
	node.add_child(box(Vector3(0.32, 0.03, 0.20), Color(0.85, 0.58, 0.20),
		Vector3(-0.04, 0.19, 0.03)))
	# intake filter house on the skid's cold end
	node.add_child(box(Vector3(0.09, 0.12, 0.14), Color(0.70, 0.72, 0.76),
		Vector3(-0.22, 0.10, 0.03)))
	node.add_child(taper(0.026, 0.032, 0.34, Color(0.55, 0.57, 0.62),
		Vector3(0.16, 0.21, 0.03), 10))
	node.add_child(box(Vector3(0.05, 0.02, 0.05), STEEL_DARK, Vector3(0.16, 0.39, 0.03)))
	var tr := _transformer(0.7)
	tr.position = Vector3(0.05, 0.04, -0.19)
	node.add_child(tr)
	return node


## Pumped hydro: a dam wall plugging a notch, the upper reservoir behind
## it, penstocks running down the face into the powerhouse at the toe.
## Reads as "stored water = stored energy".
static func _make_hydro_ps() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.9, Color(0.50, 0.52, 0.48)))
	# valley walls either side of the notch
	for side: float in [-1.0, 1.0]:
		node.add_child(box(Vector3(0.22, 0.34, 0.9), Color(0.46, 0.44, 0.40),
			Vector3(side * 0.34, 0.17, 0)))
	# reservoir behind the wall, held high
	node.add_child(box(Vector3(0.46, 0.24, 0.34), WATER_BLUE, Vector3(0, 0.14, 0.26)))
	# the dam: slightly battered wall with a crest road
	node.add_child(box(Vector3(0.48, 0.34, 0.09), CONCRETE, Vector3(0, 0.17, 0.05)))
	node.add_child(box(Vector3(0.50, 0.02, 0.12), Color(0.80, 0.80, 0.78),
		Vector3(0, 0.35, 0.05)))
	for i in 5:  # crest parapet posts
		node.add_child(box(Vector3(0.012, 0.03, 0.012), WHITE,
			Vector3(-0.20 + i * 0.10, 0.375, 0.10)))
	# penstocks down the downstream face
	for i in 3:
		var pipe := taper(0.022, 0.022, 0.36, Color(0.48, 0.50, 0.55),
			Vector3(-0.11 + i * 0.11, 0.18, -0.10), 8)
		pipe.rotation.x = -0.6
		node.add_child(pipe)
	# powerhouse at the toe + tailrace
	node.add_child(box(Vector3(0.34, 0.11, 0.14), Color(0.76, 0.77, 0.80),
		Vector3(0, 0.095, -0.26)))
	node.add_child(box(Vector3(0.36, 0.025, 0.16), ROOF_GREY, Vector3(0, 0.16, -0.26)))
	node.add_child(box(Vector3(0.30, 0.02, 0.10), WATER_BLUE, Vector3(0, 0.05, -0.38)))
	return node


# ─── renewables ────────────────────────────────────────────────────────

## Onshore wind: three turbines of staggered height on a grass/gravel pad,
## rotors phase-offset so the cluster never looks stamped.
static func _make_wind_onshore() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.9, Color(0.46, 0.56, 0.34)))
	var spots := [
		{"pos": Vector3(-0.24, 0.04, 0.16), "h": 0.86, "b": 0.32, "ph": 0.0},
		{"pos": Vector3(0.06, 0.04, -0.10), "h": 1.02, "b": 0.36, "ph": 40.0},
		{"pos": Vector3(0.28, 0.04, 0.22), "h": 0.78, "b": 0.29, "ph": 75.0},
	]
	for spot: Dictionary in spots:
		var foot := taper(0.045, 0.055, 0.03, CONCRETE,
			(spot["pos"] as Vector3) + Vector3(0, 0.015, 0), 12)
		node.add_child(foot)
		var turbine := _turbine(spot["h"], spot["b"], spot["ph"])
		turbine.position = spot["pos"]
		node.add_child(turbine)
	# access track: the thin line that makes the site feel built
	node.add_child(box(Vector3(0.62, 0.005, 0.05), Color(0.62, 0.58, 0.50),
		Vector3(0.0, 0.045, 0.30)))
	return node


## Offshore wind: same turbines on yellow monopile transition pieces,
## standing in a water plane. The yellow foot is the offshore giveaway.
static func _make_wind_offshore() -> Node3D:
	var node := Node3D.new()
	node.add_child(_water_plane(0.9))
	var spots := [
		{"pos": Vector3(-0.22, 0.04, 0.18), "h": 0.94, "b": 0.36, "ph": 15.0},
		{"pos": Vector3(0.10, 0.04, -0.14), "h": 1.06, "b": 0.40, "ph": 55.0},
		{"pos": Vector3(0.30, 0.04, 0.24), "h": 0.88, "b": 0.34, "ph": 85.0},
	]
	for spot: Dictionary in spots:
		var base := spot["pos"] as Vector3
		# transition piece: yellow drum with a boat-landing ladder
		node.add_child(cyl(0.032, 0.14, Color(0.93, 0.76, 0.15),
			base + Vector3(0, 0.07, 0)))
		node.add_child(box(Vector3(0.008, 0.10, 0.03), Color(0.80, 0.64, 0.12),
			base + Vector3(0.034, 0.09, 0)))
		var turbine := _turbine(spot["h"], spot["b"], spot["ph"])
		turbine.position = base + Vector3(0, 0.13, 0)
		node.add_child(turbine)
	return node


## Solar: rows of south-tilted dark-blue modules on a pale gravel pad, one
## inverter/transformer skid at the edge.
static func _make_solar_pv() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.9, Color(0.68, 0.66, 0.58)))
	var cell_blue := Color(0.14, 0.20, 0.44)
	var frame := Color(0.72, 0.74, 0.78)
	for row in 4:
		for col in 3:
			var mount := Node3D.new()
			mount.position = Vector3(-0.26 + col * 0.26, 0.04, -0.30 + row * 0.19)
			for leg: float in [-0.09, 0.09]:
				mount.add_child(box(Vector3(0.008, 0.05, 0.008), frame,
					Vector3(leg, 0.025, 0)))
			var array := Node3D.new()
			array.position.y = 0.06
			array.rotation_degrees.x = 28  # tilted toward the sun
			array.add_child(box(Vector3(0.22, 0.008, 0.11), frame, Vector3.ZERO))
			for mx in 3:
				for mz in 2:
					array.add_child(box(Vector3(0.062, 0.006, 0.046), cell_blue,
						Vector3(-0.070 + mx * 0.070, 0.007, -0.026 + mz * 0.052)))
			mount.add_child(array)
			node.add_child(mount)
	node.add_child(box(Vector3(0.11, 0.09, 0.09), Color(0.80, 0.82, 0.85),
		Vector3(0.32, 0.085, 0.30)))
	var tr := _transformer(0.65)
	tr.position = Vector3(0.32, 0.04, 0.14)
	node.add_child(tr)
	return node


# ─── storage, hydrogen, HVDC ───────────────────────────────────────────

## Battery: a bank of white containers with roof-mounted cooling units and
## a step-up transformer. Modular and boring on purpose — it should read as
## "a lot of the same thing", which is exactly what a BESS site is.
static func _make_battery() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.9, Color(0.60, 0.60, 0.58)))
	for row in 2:
		for col in 3:
			var container := Node3D.new()
			container.position = Vector3(-0.24 + col * 0.24, 0.04, -0.16 + row * 0.26)
			container.add_child(box(Vector3(0.20, 0.10, 0.10), Color(0.90, 0.91, 0.92),
				Vector3(0, 0.05, 0)))
			for g in 4:  # corrugation grooves
				container.add_child(box(Vector3(0.004, 0.09, 0.102),
					Color(0.78, 0.79, 0.81), Vector3(-0.07 + g * 0.047, 0.05, 0)))
			container.add_child(box(Vector3(0.06, 0.03, 0.06), Color(0.62, 0.64, 0.68),
				Vector3(0.04, 0.115, 0)))  # HVAC unit on the roof
			container.add_child(box(Vector3(0.03, 0.03, 0.003), HAZARD,
				Vector3(-0.06, 0.06, 0.051)))
			node.add_child(container)
	var tr := _transformer(0.85)
	tr.position = Vector3(0.0, 0.04, 0.32)
	node.add_child(tr)
	node.add_child(_fence(0.88))
	return node


## Electrolyzer: the stack-module hall, a row of tall gas dryer/purifier
## columns, and looping H2 pipework — teal accents mark the hydrogen chain
## wherever it appears.
static func _make_electrolyzer() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.9, Color(0.62, 0.63, 0.62)))
	node.add_child(box(Vector3(0.42, 0.20, 0.26), Color(0.86, 0.87, 0.89),
		Vector3(-0.14, 0.14, 0.14)))
	node.add_child(box(Vector3(0.44, 0.03, 0.28), H2_TEAL, Vector3(-0.14, 0.255, 0.14)))
	for i in 4:  # stack modules visible through the hall's open bay
		node.add_child(box(Vector3(0.06, 0.13, 0.07), Color(0.50, 0.54, 0.60),
			Vector3(-0.29 + i * 0.10, 0.105, 0.02)))
	# dryer / purification columns
	for i in 3:
		node.add_child(cyl(0.028, 0.30, Color(0.78, 0.80, 0.83),
			Vector3(0.16 + i * 0.08, 0.19, -0.02)))
		node.add_child(taper(0.0, 0.028, 0.04, Color(0.66, 0.68, 0.72),
			Vector3(0.16 + i * 0.08, 0.36, -0.02), 10))
	# H2 header pipe + valve skid
	var header := cyl(0.014, 0.42, H2_TEAL, Vector3(0.16, 0.06, -0.22))
	header.rotation.z = PI / 2
	node.add_child(header)
	node.add_child(box(Vector3(0.10, 0.08, 0.09), Color(0.70, 0.72, 0.76),
		Vector3(-0.06, 0.08, -0.30)))
	node.add_child(_fence(0.88))
	return node


## H2 cavern: the salt cavern is a kilometre underground, so the model is
## its surface plant — a wellhead christmas tree, two valve skids and the
## teal gas header running off-site.
static func _make_h2_cavern() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.66, Color(0.66, 0.64, 0.58)))
	# wellhead: casing spool stack topped by the valve tree
	node.add_child(cyl(0.05, 0.05, Color(0.55, 0.57, 0.62), Vector3(0, 0.06, 0)))
	node.add_child(cyl(0.030, 0.16, Color(0.68, 0.70, 0.74), Vector3(0, 0.16, 0)))
	for v in 2:  # side valve wheels on the tree
		var wheel := taper(0.026, 0.026, 0.008, Color(0.85, 0.30, 0.22),
			Vector3(0, 0.19 + v * 0.06, 0.036), 10)
		wheel.rotation.x = PI / 2
		node.add_child(wheel)
	node.add_child(box(Vector3(0.05, 0.04, 0.05), H2_TEAL, Vector3(0, 0.26, 0)))
	node.add_child(taper(0.014, 0.018, 0.06, Color(0.55, 0.57, 0.62),
		Vector3(0, 0.31, 0), 8))
	# valve skids either side + the header leaving the pad
	for side: float in [-0.20, 0.20]:
		node.add_child(box(Vector3(0.11, 0.07, 0.10), Color(0.74, 0.76, 0.80),
			Vector3(side, 0.075, -0.10)))
		node.add_child(cyl(0.010, 0.09, H2_TEAL, Vector3(side, 0.15, -0.10)))
	var header := cyl(0.013, 0.40, H2_TEAL, Vector3(0, 0.09, 0.20))
	header.rotation.z = PI / 2
	node.add_child(header)
	node.add_child(box(Vector3(0.06, 0.05, 0.04), HAZARD, Vector3(-0.22, 0.07, 0.20)))
	return node


## HVDC converter station: the long windowless valve hall is the icon, with
## a DC filter yard of capacitor racks and a converter-transformer bank
## alongside. Violet accents tie it to the HVDC corridor colour.
static func _make_hvdc_converter() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.9, Color(0.58, 0.58, 0.58)))
	# valve hall: big, blank, slightly imposing
	node.add_child(box(Vector3(0.52, 0.30, 0.26), Color(0.84, 0.85, 0.88),
		Vector3(-0.08, 0.19, 0.16)))
	node.add_child(box(Vector3(0.54, 0.035, 0.28), ROOF_GREY, Vector3(-0.08, 0.355, 0.16)))
	var strip := box(Vector3(0.50, 0.018, 0.005), HVDC_COLOR, Vector3(-0.08, 0.30, 0.031))
	strip.material_override = glow(HVDC_COLOR)
	node.add_child(strip)
	for i in 3:  # roof vents
		node.add_child(box(Vector3(0.06, 0.03, 0.07), Color(0.60, 0.62, 0.66),
			Vector3(-0.24 + i * 0.16, 0.385, 0.16)))
	# DC filter yard: capacitor racks in rows
	for row in 2:
		for col in 4:
			node.add_child(box(Vector3(0.045, 0.13, 0.045), Color(0.72, 0.74, 0.78),
				Vector3(-0.28 + col * 0.10, 0.105, -0.14 + row * 0.13)))
			node.add_child(box(Vector3(0.05, 0.012, 0.05), STEEL_DARK,
				Vector3(-0.28 + col * 0.10, 0.176, -0.14 + row * 0.13)))
	# converter transformer bank
	for i in 2:
		var tr := _transformer(0.95)
		tr.position = Vector3(0.24, 0.04, -0.18 + i * 0.20)
		node.add_child(tr)
	node.add_child(_gantry(0.30, 0.30, HVDC_COLOR))
	node.get_child(node.get_child_count() - 1).position = Vector3(0.24, 0.04, 0.30)
	node.add_child(_fence(0.88))
	return node


## Offshore converter platform: jacket legs in water, a stacked topside
## deck, crane and helipad. The North Sea hub — deliberately the most
## "installation" looking thing in the game.
static func _make_offshore_platform() -> Node3D:
	var node := Node3D.new()
	node.add_child(_water_plane(0.9))
	var deck_y := 0.34
	# jacket: four battered legs with X bracing
	var legs := [Vector3(-0.16, 0, -0.14), Vector3(0.16, 0, -0.14),
		Vector3(-0.16, 0, 0.14), Vector3(0.16, 0, 0.14)]
	for leg: Vector3 in legs:
		node.add_child(strut(leg + Vector3(0, 0.02, 0),
			leg * 0.72 + Vector3(0, deck_y, 0), 0.022, Color(0.85, 0.72, 0.18)))
	for pair: Array in [[0, 1], [2, 3], [0, 2], [1, 3]]:
		var a: Vector3 = legs[pair[0]]
		var b: Vector3 = legs[pair[1]]
		node.add_child(strut(a + Vector3(0, 0.06, 0),
			b * 0.85 + Vector3(0, 0.22, 0), 0.010, Color(0.80, 0.68, 0.18)))
		node.add_child(strut(b + Vector3(0, 0.06, 0),
			a * 0.85 + Vector3(0, 0.22, 0), 0.010, Color(0.80, 0.68, 0.18)))
	# topside: main deck slab + two module levels
	node.add_child(box(Vector3(0.42, 0.035, 0.38), Color(0.72, 0.74, 0.78),
		Vector3(0, deck_y, 0)))
	node.add_child(box(Vector3(0.30, 0.14, 0.26), Color(0.86, 0.87, 0.89),
		Vector3(-0.02, deck_y + 0.09, 0.02)))
	node.add_child(box(Vector3(0.20, 0.10, 0.18), Color(0.78, 0.80, 0.83),
		Vector3(-0.04, deck_y + 0.21, 0.02)))
	var strip := box(Vector3(0.28, 0.014, 0.004), HVDC_COLOR,
		Vector3(-0.02, deck_y + 0.13, 0.151))
	strip.material_override = glow(HVDC_COLOR)
	node.add_child(strip)
	# helideck cantilevered off one corner
	var heli := taper(0.10, 0.10, 0.012, Color(0.36, 0.38, 0.42),
		Vector3(0.20, deck_y + 0.20, -0.20), 12)
	node.add_child(heli)
	node.add_child(box(Vector3(0.05, 0.004, 0.012), WHITE,
		Vector3(0.20, deck_y + 0.208, -0.20)))
	node.add_child(box(Vector3(0.012, 0.004, 0.05), WHITE,
		Vector3(0.20, deck_y + 0.208, -0.20)))
	for supp: Vector3 in [Vector3(0.16, 0, -0.16), Vector3(0.24, 0, -0.24)]:
		node.add_child(strut(supp + Vector3(0, deck_y, 0),
			Vector3(0.20, deck_y + 0.19, -0.20), 0.008, STEEL))
	# pedestal crane + flare-style vent mast
	node.add_child(cyl(0.016, 0.10, Color(0.85, 0.72, 0.18),
		Vector3(-0.18, deck_y + 0.07, -0.14)))
	node.add_child(strut(Vector3(-0.18, deck_y + 0.12, -0.14),
		Vector3(-0.30, deck_y + 0.26, -0.06), 0.012, Color(0.85, 0.72, 0.18)))
	node.add_child(taper(0.008, 0.014, 0.22, STEEL,
		Vector3(0.14, deck_y + 0.14, 0.14), 8))
	var lamp := box(Vector3(0.018, 0.018, 0.018), Color(1.0, 0.30, 0.2),
		Vector3(0.14, deck_y + 0.26, 0.14))
	lamp.material_override = glow(Color(1.0, 0.30, 0.2))
	node.add_child(lamp)
	return node


## Substation: two busbar gantries at right angles, a transformer pair, the
## control building, and the disconnector posts that make a switchyard look
## like a switchyard.
static func _make_substation() -> Node3D:
	var node := Node3D.new()
	node.add_child(pad(0.78, Color(0.62, 0.62, 0.60)))
	var gantry_a := _gantry(0.44, 0.34, LINE_400_COLOR)
	gantry_a.position = Vector3(0, 0.04, 0.24)
	node.add_child(gantry_a)
	var gantry_b := _gantry(0.44, 0.28, LINE_400_COLOR)
	gantry_b.position = Vector3(0, 0.04, -0.06)
	gantry_b.rotation_degrees.y = 0.0
	node.add_child(gantry_b)
	for i in 2:
		var tr := _transformer(1.0)
		tr.position = Vector3(-0.14 + i * 0.26, 0.04, -0.26)
		node.add_child(tr)
	# disconnector / instrument-transformer posts in a neat row
	for i in 5:
		node.add_child(box(Vector3(0.018, 0.14, 0.018), Color(0.78, 0.80, 0.83),
			Vector3(-0.24 + i * 0.12, 0.11, 0.06)))
		node.add_child(taper(0.010, 0.014, 0.06, Color(0.30, 0.24, 0.20),
			Vector3(-0.24 + i * 0.12, 0.21, 0.06), 8))
	node.add_child(box(Vector3(0.14, 0.09, 0.11), Color(0.84, 0.85, 0.88),
		Vector3(0.26, 0.085, -0.02)))
	node.add_child(box(Vector3(0.15, 0.02, 0.12), Color(0.72, 0.45, 0.30),
		Vector3(0.26, 0.14, -0.02)))
	node.add_child(_fence(0.76))
	return node


# ─── corridors ─────────────────────────────────────────────────────────

## A transmission corridor tile: one pylon at the tile centre plus half-span
## conductors reaching toward each connected neighbour, so adjacent tiles
## meet mid-edge and the line reads as continuous across the map.
## `neighbours` are the N/E/S/W offsets that carry the same corridor.
## Conductors are aluminium — SILVER, never the voltage accent (the accent
## stays on the mast peak cap, so the line language survives at a glance).
const CONDUCTOR := Color(0.80, 0.81, 0.84)


static func corridor(kind: String, neighbors: Array[Vector2i]) -> Node3D:
	var node := Node3D.new()
	var accent := LINE_400_COLOR
	var mast_h := 0.62
	var arms: Array[float] = [0.44, 0.56]  # two circuits, three phases each
	var arm_w := 0.30
	var per_arm := 3  # conductors per crossarm (one three-phase circuit)
	match kind:
		"line_220":
			accent = LINE_220_COLOR
			mast_h = 0.44
			arms = [0.34]
			arm_w = 0.24
			per_arm = 3
		"hvdc":
			accent = HVDC_COLOR
			mast_h = 0.58
			arms = [0.46]
			arm_w = 0.22
			per_arm = 2  # bipole: one conductor per pole
	# the tower FACES the line: crossarms perpendicular to the primary span,
	# so the phases stay side by side instead of converging at the tile
	# edge (they used to fan into the centreline and fan out again — a
	# split-and-reconnect no real line has)
	var yaw := 0.0
	if not neighbors.is_empty():
		var d0 := Vector3(neighbors[0].x, 0, neighbors[0].y)
		yaw = atan2(d0.x, d0.z)
	var tower := Node3D.new()
	tower.rotation.y = yaw
	node.add_child(tower)
	tower.add_child(_lattice_mast(mast_h, accent))
	# crossarms + insulator strings (tower-local X = across the line)
	var hangers: Array[Vector3] = []  # LOCAL positions
	for arm_y: float in arms:
		tower.add_child(box(Vector3(arm_w, 0.014, 0.014), STEEL, Vector3(0, arm_y, 0)))
		tower.add_child(strut(Vector3(-arm_w / 2.0, arm_y, 0),
			Vector3(0, arm_y + 0.09, 0), 0.008, STEEL_DARK))
		tower.add_child(strut(Vector3(arm_w / 2.0, arm_y, 0),
			Vector3(0, arm_y + 0.09, 0), 0.008, STEEL_DARK))
		for c in per_arm:
			var x := -arm_w / 2.0 + arm_w * c / float(maxi(per_arm - 1, 1))
			if per_arm == 2:
				x = -arm_w / 2.0 + arm_w * c
			tower.add_child(taper(0.006, 0.006, 0.05, Color(0.30, 0.26, 0.24),
				Vector3(x, arm_y - 0.03, 0), 6))
			hangers.append(Vector3(x, arm_y - 0.055, 0))
	# half-span conductors: every phase keeps its LATERAL offset relative
	# to the span, so the wires run parallel — including diagonal spans,
	# whose half-vector is simply half the way to the neighbour's centre
	var spin := Basis(Vector3.UP, yaw)
	for offset: Vector2i in neighbors:
		var half := Vector3(offset.x, 0, offset.y) * 0.5
		var dir := half.normalized()
		for hang: Vector3 in hangers:
			var hw := spin * hang  # hanger in tile space
			var flat := Vector3(hw.x, 0, hw.z)
			var lateral := flat - dir * flat.dot(dir)
			var edge := half + lateral + Vector3(0, hang.y - 0.05, 0)
			var mid := half * 0.5 + lateral + Vector3(0, hang.y - 0.045, 0)
			node.add_child(strut(hw, mid, 0.007, CONDUCTOR))
			node.add_child(strut(mid, edge, 0.007, CONDUCTOR))
		# earth wire along the same span, off the mast peak
		node.add_child(strut(Vector3(0, mast_h, 0),
			half + Vector3(0, mast_h - 0.04, 0), 0.005, STEEL_DARK))
	return node


## Steel lattice mast: four battered legs, horizontal belts and X bracing,
## with the voltage accent capping the peak.
static func _lattice_mast(height: float, accent: Color) -> Node3D:
	var node := Node3D.new()
	var base := 0.075
	var top := 0.022
	var levels := 4
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for corner: Vector2 in corners:
		for level in levels:
			var t0 := float(level) / levels
			var t1 := float(level + 1) / levels
			var r0 := lerpf(base, top, t0)
			var r1 := lerpf(base, top, t1)
			node.add_child(strut(
				Vector3(corner.x * r0, height * t0, corner.y * r0),
				Vector3(corner.x * r1, height * t1, corner.y * r1), 0.011, STEEL))
	for level in levels + 1:
		var t := float(level) / levels
		var r := lerpf(base, top, t)
		var y := height * t
		for i in 4:
			var a: Vector2 = corners[i]
			var b: Vector2 = corners[(i + 1) % 4]
			node.add_child(strut(Vector3(a.x * r, y, a.y * r),
				Vector3(b.x * r, y, b.y * r), 0.008, STEEL_DARK))
	for level in levels:  # X bracing on each face
		var t0 := float(level) / levels
		var t1 := float(level + 1) / levels
		var r0 := lerpf(base, top, t0)
		var r1 := lerpf(base, top, t1)
		for i in 4:
			var a: Vector2 = corners[i]
			var b: Vector2 = corners[(i + 1) % 4]
			node.add_child(strut(Vector3(a.x * r0, height * t0, a.y * r0),
				Vector3(b.x * r1, height * t1, b.y * r1), 0.006, STEEL_DARK))
	node.add_child(box(Vector3(0.05, 0.018, 0.05), accent, Vector3(0, height, 0)))
	return node


# ─── load centres ──────────────────────────────────────────────────────

## A metro footprint tile: a cluster of Kenney city blocks on a street
## grid. `size_class` picks the density ("large" metros get towers), and
## `index` deterministically varies the block mix so a 2x2 city footprint
## does not look like four copies of the same tile.
static func load_center(size_class: String, index: int = 0) -> Node3D:
	var node := Node3D.new()
	node.add_child(box(Vector3(0.94, 0.03, 0.94), Color(0.44, 0.44, 0.46),
		Vector3(0, 0.015, 0)))
	# street cross: the asphalt the blocks sit between
	node.add_child(box(Vector3(0.94, 0.006, 0.10), Color(0.30, 0.31, 0.34),
		Vector3(0, 0.033, 0)))
	node.add_child(box(Vector3(0.10, 0.006, 0.94), Color(0.30, 0.31, 0.34),
		Vector3(0, 0.033, 0)))
	var tall := ["building-skyscraper-a", "building-skyscraper-c",
		"building-skyscraper-e", "building-f"]
	var mid := ["building-a", "building-c", "building-d", "building-h",
		"building-k", "building-n"]
	var low := ["low-detail-building-b", "low-detail-building-g",
		"low-detail-building-h", "low-detail-building-k"]
	var quadrants := [Vector3(-0.24, 0.03, -0.24), Vector3(0.24, 0.03, -0.24),
		Vector3(-0.24, 0.03, 0.24), Vector3(0.24, 0.03, 0.24)]
	for q in quadrants.size():
		var pick_from: Array = low
		if size_class == "large":
			pick_from = tall if q % 2 == (index % 2) else mid
		elif q % 2 == (index % 2):
			pick_from = mid
		var name: String = pick_from[(index + q * 3) % pick_from.size()]
		var fit := 0.30 if size_class == "large" else 0.26
		var block := _instance_glb(
			"city-kit-commercial/Models/GLB format/%s.glb" % name, fit)
		block.position = quadrants[q]
		block.rotation_degrees.y = 90.0 * ((index + q) % 4)
		node.add_child(block)
	return node
