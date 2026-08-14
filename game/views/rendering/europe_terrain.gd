class_name EuropeTerrain
extends RefCounted
## Terrain geometry for the Europe map (96 x 80 tiles at 50 km). Pure static
## build over WorldModel's terrain dictionary — returns Packed arrays, so the
## renderer owns meshes and materials and this stays headless-testable
## (infrastruct's TerrainMeshBuilder pattern).
##
## Unlike the city-scale sibling there is no height field to smooth: a tile's
## terrain CLASS sets both its colour and a small elevation lift, so the
## continent reads as sea -> shelf -> coast -> plain -> hills -> mountains
## from the isometric camera without any per-tile height data.

## One tile = 1.0 world unit (a tile is 50 km — the map is a symbol, not a
## scale model). Sea sits at y = 0; land lifts by class.
const LIFT := {
	"S": -0.06,  # deep sea, dips below the shelf so coastlines read
	"s": -0.02,  # continental shelf
	"c": 0.03,   # coast
	"p": 0.06,   # plain
	"h": 0.16,   # hills
	"m": 0.30,   # mountains
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
## Mountain tops get a snow cap above this share of the tile.
const SNOW_COLOR := Color(0.92, 0.93, 0.95)
const SKIRT_COLOR := Color(0.62, 0.50, 0.36)  # earthen sides of a lifted tile


static func height_of(kind: String) -> float:
	return float(LIFT.get(kind, 0.0))


static func color_of(kind: String) -> Color:
	return COLORS.get(kind, Color.MAGENTA) as Color


## Build the whole terrain as one vertex-coloured surface: a top quad per
## tile plus skirt quads wherever a tile stands above its neighbour (the
## visible cliff faces). Returns {vertices, normals, colors, indices}.
static func build(world: Node) -> Dictionary:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	for y in range(world.height):
		for x in range(world.width):
			var tile := Vector2i(x, y)
			var kind := str(world.terrain_at(tile))
			var top := height_of(kind)
			var color := color_of(kind)
			if kind == "m":
				# deterministic dusting so ranges read as ridges, not a slab
				color = color.lerp(SNOW_COLOR, 0.35 if (x + y) % 3 == 0 else 0.1)
			elif kind == "p" or kind == "h":
				# gentle per-tile jitter toward hay: fields, not billiard cloth
				color = color.lerp(Color(0.58, 0.60, 0.28),
					0.09 * float((x * 7 + y * 13) % 5) / 4.0)
			_quad(vertices, normals, colors, indices,
				Vector3(x, top, y), Vector3(x + 1, top, y),
				Vector3(x + 1, top, y + 1), Vector3(x, top, y + 1),
				Vector3.UP, color)

			# skirts: only toward LOWER neighbours, so each face is drawn once
			for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]:
				var n := tile + offset
				var n_top := height_of(str(world.terrain_at(n))) \
					if world.terrain.has(n) else LIFT["S"]
				if n_top >= top - 0.0001:
					continue
				_skirt(vertices, normals, colors, indices, x, y, offset,
					top, n_top)
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
