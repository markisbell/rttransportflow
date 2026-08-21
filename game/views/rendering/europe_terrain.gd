class_name EuropeTerrain
extends RefCounted
## Terrain geometry for the Europe map. Pure static builders over WorldModel
## — they return Packed arrays, so the renderer owns meshes and materials and
## this stays headless-testable (infrastruct's TerrainMeshBuilder pattern).
##
## A tile's terrain CLASS sets both its colour and an elevation lift, so the
## continent reads as sea -> shelf -> coast -> plain -> hills -> mountains
## from the isometric camera without any per-tile height data.
##
## The map is far too large to live in one mesh (960 x 804 = 772k tiles), so
## the renderer streams it: `build_region()` returns ONE CHUNK of tiles and
## `build_coarse()` returns a cheap whole-map backdrop that fills whatever
## the streamer has not loaded. Both read one tile PAST their borders via
## `terrain_at()`, which answers "S" outside the map — that is what makes
## chunk seams invisible and the map edge fall away into deep sea.

## One tile = 1.0 world unit. Vertical exaggeration is deliberate: at 5 km
## per tile true relief (Mont Blanc ≈ 0.1 units) would be invisible from the
## isometric camera. These lifts make ranges read as ranges.
const LIFT := {
	"S": -0.18,  # deep sea, dips well below the shelf so coastlines read
	"s": -0.06,  # continental shelf
	"c": 0.05,   # coast
	"p": 0.12,   # plain
	"h": 0.46,   # hills
	"m": 1.05,   # mountains
}

## Saturated, slightly warm palette in the sibling's key: greens for the
## lowlands, hay for the uplands, rock for the peaks, two blues for water.
const COLORS := {
	"S": Color(0.10, 0.24, 0.42),
	"s": Color(0.17, 0.38, 0.58),
	"c": Color(0.76, 0.70, 0.50),
	"p": Color(0.38, 0.57, 0.26),
	"h": Color(0.52, 0.55, 0.30),
	"m": Color(0.55, 0.53, 0.51),
}
const SNOW_COLOR := Color(0.92, 0.93, 0.95)
const SKIRT_COLOR := Color(0.62, 0.50, 0.36)  # earthen sides of a lifted tile

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


## ── real relief (render-only sidecar, tools/map_authoring/relief.py) ──
## When the map carries per-tile ETOPO elevation, the ground is a CONTINUOUS
## heightfield: vertices sit on tile CORNERS, each corner averaging its four
## tiles, so slopes run smoothly across tile borders and the shoreline is
## simply where the land slope passes through the water plane — the per-tile
## staircase (and its skirts) disappears without touching the 5 km grid.

## Vertical exaggeration over true scale (1 unit = tile_km horizontally).
## True relief is invisible from the isometric camera (Mont Blanc ≈ 0.9
## units at 5 km tiles); 2.2 makes ranges read as ranges while keeping the
## Alps in the same visual band the old class lifts occupied.
const EXAG := 2.2
const SEA_FLOOR_M := -900.0  # visual depth cap — abyssal detail adds nothing
## a water tile's own surface always sits below the water plane (see
## _build_relief_region: corner averaging must never close a lake basin)
const SUBMERGE := -0.004

# satellite-style palette: the land colour comes from vegetation density and
# altitude (dry tan -> lush green -> closed forest -> rock -> snow), water
# from depth, with sand where low land meets water
const DEEP := Color(0.043, 0.153, 0.271)
const SHALLOW := Color(0.169, 0.435, 0.541)
const LAKE := Color(0.157, 0.376, 0.443)
const DRY := Color(0.635, 0.557, 0.373)
const LUSH := Color(0.373, 0.514, 0.267)
const FOREST := Color(0.153, 0.278, 0.141)
const ROCK := Color(0.478, 0.443, 0.404)
const SAND := Color(0.769, 0.706, 0.537)
const URBAN_GREY := Color(0.556, 0.545, 0.529)  # concrete sprawl


static func height_of(kind: String) -> float:
	return float(LIFT.get(kind, 0.0))


## Render height of a tile CENTRE — what models, cursor and deco stand on.
static func ground_of(world: Node, tile: Vector2i) -> float:
	if world.get("has_relief"):
		return _render_h(world, tile)
	return height_of(world.terrain_at(tile) as String)


static func _render_h(world: Node, tile: Vector2i) -> float:
	# relief.py already pins land >= 4 m and water <= -6 m, so the class
	# truth and the rendered shoreline can never disagree
	var elev: float = clampf(world.elev_at(tile), SEA_FLOOR_M, 4800.0)
	return elev / (world.tile_km * 1000.0) * EXAG


static func color_of(kind: String) -> Color:
	return COLORS.get(kind, Color.MAGENTA) as Color


## Per-tile surface colour: the palette plus deterministic variation, so a
## range reads as ridges and farmland as fields rather than billiard cloth.
static func tile_color(kind: String, x: int, y: int) -> Color:
	var color := color_of(kind)
	if kind == "m":
		return color.lerp(SNOW_COLOR, 0.35 if (x + y) % 3 == 0 else 0.1)
	if kind == "p" or kind == "h":
		return color.lerp(Color(0.58, 0.60, 0.28),
			0.09 * float((x * 7 + y * 13) % 5) / 4.0)
	return color


## Build ONE rectangular region [x0, x1) x [y0, y1) of the map.
## Returns {vertices, normals, colors, indices} in WORLD space (the caller
## places the mesh at the origin, not at the chunk corner, so neighbouring
## chunks share exact vertex positions and never crack).
static func build_region(world: Node, x0: int, y0: int,
		x1: int, y1: int) -> Dictionary:
	if world.get("has_relief"):
		return _build_relief_region(world, x0, y0, x1, y1)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	for y in range(y0, y1):
		for x in range(x0, x1):
			var kind := world.terrain_at(Vector2i(x, y)) as String
			var top := height_of(kind)
			_quad(vertices, normals, colors, indices,
				Vector3(x, top, y), Vector3(x + 1, top, y),
				Vector3(x + 1, top, y + 1), Vector3(x, top, y + 1),
				Vector3.UP, tile_color(kind, x, y))

			# Skirts face only DOWNHILL neighbours, so each cliff is drawn
			# once. terrain_at() answers "S" outside the map, which is what
			# lets a border chunk emit the same faces it would mid-map.
			for offset: Vector2i in NEIGHBOR_OFFSETS:
				var n_kind := world.terrain_at(Vector2i(x, y) + offset) as String
				var n_top := height_of(n_kind)
				if n_top >= top - 0.0001:
					continue
				_skirt(vertices, normals, colors, indices, x, y, offset,
					top, n_top)
	return {"vertices": vertices, "normals": normals, "colors": colors,
		"indices": indices}


## Whole-map build (small maps, tests). The renderer streams instead.
static func build(world: Node) -> Dictionary:
	return build_region(world, 0, 0, world.width, world.height)


## A cheap whole-map backdrop: one quad per `step` x `step` block, coloured
## by the majority class of a strided sample. This is always drawn UNDER the
## streamed chunks, so anything not yet loaded still reads as continent
## instead of a hole — the far distance simply loses its detail.
static func build_coarse(world: Node, step: int) -> Dictionary:
	if world.get("has_relief"):
		return _build_relief_coarse(world, step)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var sample_stride := maxi(1, step / 2)

	var y := 0
	while y < world.height:
		var x := 0
		while x < world.width:
			var counts := {}
			var sy := y
			while sy < mini(y + step, world.height):
				var sx := x
				while sx < mini(x + step, world.width):
					var k := world.terrain_at(Vector2i(sx, sy)) as String
					counts[k] = int(counts.get(k, 0)) + 1
					sx += sample_stride
				sy += sample_stride
			var kind := "S"
			var best := -1
			for k: String in counts:
				var n := int(counts[k])
				# ties resolve toward the LAND classes: a coarse cell that is
				# half coastline should still read as coast, not as sea
				if n > best or (n == best and height_of(k) > height_of(kind)):
					best = n
					kind = k
			var x1 := mini(x + step, world.width)
			var y1 := mini(y + step, world.height)
			# a hair below the detailed surface so streamed chunks win the
			# depth test wherever they exist
			var top := height_of(kind) - 0.05
			_quad(vertices, normals, colors, indices,
				Vector3(x, top, y), Vector3(x1, top, y),
				Vector3(x1, top, y1), Vector3(x, top, y1),
				Vector3.UP, color_of(kind))
			x += step
		y += step
	return {"vertices": vertices, "normals": normals, "colors": colors,
		"indices": indices}


static func _quad(vertices: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		normal: Vector3, color: Color) -> void:
	var base := vertices.size()
	for corner: Vector3 in [a, b, c, d]:
		vertices.push_back(corner)
		normals.push_back(normal)
		colors.push_back(color)
	for i: int in [0, 1, 2, 0, 2, 3]:
		indices.push_back(base + i)


static func _skirt(vertices: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		x: int, y: int, offset: Vector2i, top: float, bottom: float) -> void:
	var a: Vector3
	var b: Vector3
	var normal: Vector3
	if offset == Vector2i(1, 0):
		a = Vector3(x + 1, top, y)
		b = Vector3(x + 1, top, y + 1)
		normal = Vector3.RIGHT
	elif offset == Vector2i(-1, 0):
		a = Vector3(x, top, y + 1)
		b = Vector3(x, top, y)
		normal = Vector3.LEFT
	elif offset == Vector2i(0, 1):
		a = Vector3(x + 1, top, y + 1)
		b = Vector3(x, top, y + 1)
		normal = Vector3.BACK
	else:
		a = Vector3(x, top, y)
		b = Vector3(x + 1, top, y)
		normal = Vector3.FORWARD
	_quad(vertices, normals, colors, indices,
		a, b, Vector3(b.x, bottom, b.z), Vector3(a.x, bottom, a.z),
		normal, SKIRT_COLOR)


## The water surface: one flat plane over the whole map at sea level, drawn
## slightly above the deep-sea floor so shelf tiles shimmer through. With
## relief, sea level is (just under) elevation zero — relief.py keeps land
## above +4 m, so the lowest polder still clears the plane.
static func water_level(world: Node) -> float:
	if world.get("has_relief"):
		return 0.0008
	return LIFT["s"] + 0.012


## One pixel of the minimap: the relief palette when the map carries it
## (lakes, forests and snow read on the navigator too), classes otherwise.
static func map_pixel(world: Node, tile: Vector2i) -> Color:
	if not world.get("has_relief"):
		return color_of(world.terrain_at(tile) as String)
	var kind := world.terrain_at(tile) as String
	var elev: float = world.elev_at(tile)
	if kind == "S" or kind == "s":
		if world.lake_at(tile):
			return LAKE
		return DEEP.lerp(SHALLOW, exp(-maxf(0.0, -elev) / 220.0))
	return _land_color(world.lat_of_row(tile.y), elev, world.green_at(tile)) \
		.lerp(URBAN_GREY, world.urban_at(tile) * 0.75)


## The one land-tint rule (mesh corners and minimap pixels alike): base
## colour from the latitude moisture gradient — farmed central Europe IS
## green, the Mediterranean IS dry — the vegetation byte then only darkens
## it toward closed forest, and altitude takes over above the treeline.
static func _land_color(lat: float, elev: float, green: float) -> Color:
	var moisture := smoothstep(37.5, 46.5, lat)
	var color := DRY.lerp(LUSH, 0.22 + 0.78 * moisture)
	color = color.lerp(FOREST, smoothstep(0.30, 0.80, green))
	var treeline := 2400.0 - (lat - 35.0) * 48.0
	color = color.lerp(ROCK, smoothstep(treeline * 0.72, treeline * 1.1, elev))
	var snowline := 3300.0 - (lat - 35.0) * 52.0
	return color.lerp(SNOW_COLOR,
		smoothstep(snowline * 0.9, snowline * 1.08, elev))


# ─── relief mesh builders ─────────────────────────────────────────────

## One chunk of the continuous heightfield: per-tile quads whose four
## corners each average the surrounding tiles, so neighbouring chunks share
## exact corner heights and colours (same rule, same inputs) and never
## crack. Normals come from central differences over the corner grid.
static func _build_relief_region(world: Node, x0: int, y0: int,
		x1: int, y1: int) -> Dictionary:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	# HOT PATH (measured 40 ms/chunk naive, ~8 ms cached — 3 chunks/frame
	# was 120 ms of stutter while panning): every per-tile attribute is
	# read ONCE into flat arrays, every corner's height/normal/colour is
	# computed ONCE and shared by the four quads that touch it.
	var tw := x1 - x0 + 4  # tiles [x0-2 .. x1+1]
	var th := y1 - y0 + 4
	var t_elev := PackedFloat32Array()
	t_elev.resize(tw * th)
	var t_green := PackedFloat32Array()
	t_green.resize(tw * th)
	var t_h := PackedFloat32Array()
	t_h.resize(tw * th)
	var t_water := PackedByteArray()
	t_water.resize(tw * th)
	var t_lake := PackedByteArray()
	t_lake.resize(tw * th)
	var scale: float = 1.0 / (world.tile_km * 1000.0) * EXAG
	for ty in range(th):
		for tx in range(tw):
			var tile := Vector2i(x0 - 2 + tx, y0 - 2 + ty)
			var i := ty * tw + tx
			var e: float = world.elev_at(tile)
			t_elev[i] = e
			t_h[i] = clampf(e, SEA_FLOOR_M, 4800.0) * scale
			t_green[i] = world.green_at(tile)
			var kind := world.terrain_at(tile) as String
			t_water[i] = 1 if (kind == "S" or kind == "s") else 0
			t_lake[i] = 1 if (t_water[i] == 1 and world.lake_at(tile)) else 0

	# corner grid [x0-1 .. x1+1]: height, then colour, from the tile caches
	var cw := x1 - x0 + 3
	var ch := y1 - y0 + 3
	var corner_h := PackedFloat32Array()
	corner_h.resize(cw * ch)
	var corner_col := PackedColorArray()
	corner_col.resize(cw * ch)
	for cy in range(ch):
		for cx in range(cw):
			# corner (cx, cy) sits between tile-cache rows/cols [cy, cy+1] x
			# [cx, cx+1]: the cache starts one tile before the corner grid,
			# so the corner's NW tile IS cache index (cy, cx)
			var ta := cy * tw + cx
			var tb := ta + 1
			var tc := ta + tw
			var td := tc + 1
			var h := (t_h[ta] + t_h[tb] + t_h[tc] + t_h[td]) * 0.25
			corner_h[cy * cw + cx] = h
			var elev := (t_elev[ta] + t_elev[tb] + t_elev[tc] + t_elev[td]) * 0.25
			var green := (t_green[ta] + t_green[tb] + t_green[tc] + t_green[td]) * 0.25
			var water_n := int(t_water[ta]) + int(t_water[tb]) \
				+ int(t_water[tc]) + int(t_water[td])
			var lake_n := int(t_lake[ta]) + int(t_lake[tb]) \
				+ int(t_lake[tc]) + int(t_lake[td])
			var acx := x0 - 1 + cx
			var acy := y0 - 1 + cy
			var color: Color
			if h <= 0.0012:
				var depth := maxf(0.0, -elev)
				color = DEEP.lerp(SHALLOW, exp(-depth / 220.0))
				if lake_n > 0:
					color = color.lerp(LAKE, 0.75)
			else:
				var urban: float = (world.urban_at(Vector2i(acx - 1, acy - 1))
					+ world.urban_at(Vector2i(acx, acy - 1))
					+ world.urban_at(Vector2i(acx - 1, acy))
					+ world.urban_at(Vector2i(acx, acy))) * 0.25
				color = _land_color(world.lat_of_row(acy), elev, green)
				color = color.lerp(URBAN_GREY, urban * 0.75)
				if water_n > 0 and elev < 30.0:
					color = color.lerp(SAND, 0.65)
			var wobble := float((acx * 73856093 ^ acy * 19349663) % 100) / 100.0
			corner_col[cy * cw + cx] = color * (0.955 + 0.09 * wobble)

	for y in range(y0, y1):
		for x in range(x0, x1):
			var kind := world.terrain_at(Vector2i(x, y)) as String
			var is_water := kind == "S" or kind == "s"
			var base := vertices.size()
			for c in 4:
				var cx := x + (c & 1 ^ (c >> 1))  # 0,1,1,0 pattern -> quad order
				var cy := y + (c >> 1)
				var gx := cx - x0 + 1
				var gy := cy - y0 + 1
				var h := corner_h[gy * cw + gx]
				if is_water:
					# valley lakes and fjords: corner averaging against high
					# shores would lift a narrow water body above the plane
					# and close the basin over — a water tile's OWN quad is
					# always submerged; the walls below make up the shore
					h = minf(h, SUBMERGE)
				vertices.push_back(Vector3(cx, h, cy))
				normals.push_back(Vector3(
					corner_h[gy * cw + gx - 1] - corner_h[gy * cw + gx + 1],
					2.0,
					corner_h[(gy - 1) * cw + gx] - corner_h[(gy + 1) * cw + gx]
				).normalized())
				colors.push_back(corner_col[gy * cw + gx])
			for i: int in [0, 1, 2, 0, 2, 3]:
				indices.push_back(base + i)
			if is_water:
				_shore_walls(world, vertices, normals, colors, indices,
					x, y, x0, y0, cw, corner_h, SUBMERGE)
	return {"vertices": vertices, "normals": normals, "colors": colors,
		"indices": indices}


## Where a submerged water quad meets terrain whose averaged corners stand
## higher, close the gap with a wall — the steep lakeshore or fjord cliff.
static func _shore_walls(world: Node, vertices: PackedVector3Array,
		normals: PackedVector3Array, colors: PackedColorArray,
		indices: PackedInt32Array, x: int, y: int, x0: int, y0: int,
		cw: int, corner_h: PackedFloat32Array, submerge: float) -> void:
	for offset: Vector2i in NEIGHBOR_OFFSETS:
		var n_tile := Vector2i(x, y) + offset
		var n_kind := world.terrain_at(n_tile) as String
		if n_kind == "S" or n_kind == "s":
			continue
		# the shared edge's two corners, in the order that faces the water
		var ca: Vector2i
		var cb: Vector2i
		if offset == Vector2i(1, 0):
			ca = Vector2i(x + 1, y + 1)
			cb = Vector2i(x + 1, y)
		elif offset == Vector2i(-1, 0):
			ca = Vector2i(x, y)
			cb = Vector2i(x, y + 1)
		elif offset == Vector2i(0, 1):
			ca = Vector2i(x, y + 1)
			cb = Vector2i(x + 1, y + 1)
		else:
			ca = Vector2i(x + 1, y)
			cb = Vector2i(x, y)
		var top_a := corner_h[(ca.y - y0 + 1) * cw + (ca.x - x0 + 1)]
		var top_b := corner_h[(cb.y - y0 + 1) * cw + (cb.x - x0 + 1)]
		if maxf(top_a, top_b) < submerge + 0.002:
			continue  # open sea: the averaged coast already slopes under
		var shore_elev: float = world.elev_at(n_tile)
		var color := SAND.lerp(ROCK, smoothstep(60.0, 600.0, shore_elev))
		var normal := Vector3(-offset.x, 0.4, -offset.y).normalized()
		var base := vertices.size()
		for v: Vector3 in [
				Vector3(ca.x, maxf(top_a, submerge), ca.y),
				Vector3(cb.x, maxf(top_b, submerge), cb.y),
				Vector3(cb.x, submerge - 0.02, cb.y),
				Vector3(ca.x, submerge - 0.02, ca.y)]:
			vertices.push_back(v)
			normals.push_back(normal)
			colors.push_back(color)
		for i: int in [0, 1, 2, 0, 2, 3]:
			indices.push_back(base + i)


## Colour of corner (cx, cy) from its four surrounding tiles.
static func _corner_color(world: Node, cx: int, cy: int, h: float) -> Color:
	var elev := 0.0
	var green := 0.0
	var urban := 0.0
	var water_n := 0
	var lake_n := 0
	for tile: Vector2i in [Vector2i(cx - 1, cy - 1), Vector2i(cx, cy - 1),
			Vector2i(cx - 1, cy), Vector2i(cx, cy)]:
		elev += world.elev_at(tile)
		green += world.green_at(tile)
		urban += world.urban_at(tile)
		var kind := world.terrain_at(tile) as String
		if kind == "S" or kind == "s":
			water_n += 1
			if world.lake_at(tile):
				lake_n += 1
	elev *= 0.25
	green *= 0.25
	urban *= 0.25
	var color: Color
	if h <= 0.0012:  # under (or at) the water plane
		var depth := maxf(0.0, -elev)
		color = DEEP.lerp(SHALLOW, exp(-depth / 220.0))
		if lake_n > 0:
			color = color.lerp(LAKE, 0.75)
	else:
		color = _land_color(world.lat_of_row(cy), elev, green)
		color = color.lerp(URBAN_GREY, urban * 0.75)  # concrete over the sprawl
		if water_n > 0 and elev < 30.0:
			color = color.lerp(SAND, 0.65)  # shoreline sand strip
	# per-corner brightness hash: fields and stands, not billiard cloth
	var wobble := float((cx * 73856093 ^ cy * 19349663) % 100) / 100.0
	return color * (0.955 + 0.09 * wobble)


## Relief backdrop: the same heightfield at `step`-tile stride, kept UNDER
## the detailed surface. Sampling corner tiles is not enough for that: a
## cell interpolated between two 2 000 m ridges sits ABOVE the valley the
## detail mesh digs between them, poking through every alpine valley and
## burying valley lakes. Each corner therefore takes the MINIMUM height of
## the cells it touches (one full pass over the map, built once at boot) —
## the backdrop reads slightly sunken at distance, which the fog hides,
## and it can never occlude the detail or the water above it.
static func _build_relief_coarse(world: Node, step: int) -> Dictionary:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var nx := int(ceil(float(world.width) / step))
	var ny := int(ceil(float(world.height) / step))
	var cw := nx + 1
	var cell_min := PackedFloat32Array()
	cell_min.resize(nx * ny)
	cell_min.fill(1e9)
	for ty in range(world.height):
		var gy := mini(ty / step, ny - 1)
		for tx in range(world.width):
			var i := gy * nx + mini(tx / step, nx - 1)
			var h := _render_h(world, Vector2i(tx, ty))
			if h < cell_min[i]:
				cell_min[i] = h
	var corner_h := PackedFloat32Array()
	corner_h.resize(cw * (ny + 1))
	for gy in range(ny + 1):
		for gx in range(nx + 1):
			var low := 1e9
			for cell: Vector2i in [Vector2i(gx - 1, gy - 1), Vector2i(gx, gy - 1),
					Vector2i(gx - 1, gy), Vector2i(gx, gy)]:
				if cell.x >= 0 and cell.y >= 0 and cell.x < nx and cell.y < ny:
					low = minf(low, cell_min[cell.y * nx + cell.x])
			corner_h[gy * cw + gx] = low if low < 1e8 else -0.4
	for gy in range(ny):
		for gx in range(nx):
			var base := vertices.size()
			for c in 4:
				var ix := gx + (c & 1 ^ (c >> 1))
				var iy := gy + (c >> 1)
				var h := corner_h[iy * cw + ix] - 0.05
				var tx := mini(ix * step, world.width - 1)
				var ty := mini(iy * step, world.height - 1)
				vertices.push_back(Vector3(mini(ix * step, world.width), h,
					mini(iy * step, world.height)))
				var hl := corner_h[iy * cw + maxi(ix - 1, 0)]
				var hr := corner_h[iy * cw + mini(ix + 1, nx)]
				var hu := corner_h[maxi(iy - 1, 0) * cw + ix]
				var hd := corner_h[mini(iy + 1, ny) * cw + ix]
				normals.push_back(Vector3(hl - hr, 2.0 * step, hu - hd).normalized())
				colors.push_back(_corner_color(world, tx, ty, h + 0.05))
			for i: int in [0, 1, 2, 0, 2, 3]:
				indices.push_back(base + i)
	return {"vertices": vertices, "normals": normals, "colors": colors,
		"indices": indices}
