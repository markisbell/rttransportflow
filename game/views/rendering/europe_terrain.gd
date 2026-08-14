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


static func height_of(kind: String) -> float:
	return float(LIFT.get(kind, 0.0))


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
## slightly above the deep-sea floor so shelf tiles shimmer through.
static func water_level() -> float:
	return LIFT["s"] + 0.012
