class_name StrategicGrid
extends RefCounted
## The grid's SYMBOLIC representation: one always-resident mesh of ground
## ribbons over every corridor tile (in the game's line language — 400 kV
## red, 220 kV green, HVDC violet) plus substation markers. Above
## MODEL_DETAIL_MAX_SIZE this layer IS the network — pylon models are
## sub-pixel there and cost minutes to build at continental scale; below
## it the ribbons read as the corridor's right-of-way under the models.
##
## One ArrayMesh for the whole map: a continental grid is a few thousand
## quads — trivial and O(1) RIDs, never churned by streaming.

const RIBBON_LIFT := 0.07  # above terrain, below the models
const SUB_SIZE := 1.8  # substation marker half-extent (tiles)
const SUB_COLOR := Color(0.95, 0.96, 0.97)


const RIBBON_W := 0.55

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0),
	Vector2i(0, 1), Vector2i(-1, 0)]


static func build_mesh(world: Node) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for tile: Vector2i in world.corridors:
		if world.diag_fillers.has(tile):
			continue  # its neighbours draw the diagonal segment across it
		var kind := str(world.corridors[tile])
		var color: Color = PlantModels.HVDC_COLOR if kind == "hvdc" \
			else PlantModels.LINE_220_COLOR if kind == "line_220" \
			else Color(0.62, 0.16, 0.14) if kind == "cable_400" \
			else PlantModels.LINE_400_COLOR
		# centre-to-centre SEGMENTS toward every connected partner (drawn
		# once, from the lexicographically smaller end): continuous ribbons
		# for straight, staircase and diagonal runs alike
		for offset: Vector2i in _connections(world, tile, kind):
			if offset.y > 0 or (offset.y == 0 and offset.x > 0):
				_segment(world, vertices, colors, indices, tile, offset, color)
	for tile: Vector2i in world.dc_overlay:
		# crossing spans: the DC ribbon rides visibly over the AC tile
		_quad(world, vertices, colors, indices, tile, 0.32,
			PlantModels.HVDC_COLOR, RIBBON_LIFT + 0.02)
	for tile: Vector2i in world.substations:
		_quad(world, vertices, colors, indices, tile, SUB_SIZE / 2.0, SUB_COLOR)
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Connected partner offsets of a (non-filler) corridor tile: same-kind
## 4-neighbours, with diagonal-span fillers resolved to their far end.
static func _connections(world: Node, tile: Vector2i,
		kind: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for offset: Vector2i in DIRS:
		var n := tile + offset
		if str(world.corridors.get(n, "")) != kind:
			continue
		if world.diag_fillers.has(n):
			for beyond: Vector2i in DIRS:
				var far := n + beyond
				if far != tile and str(world.corridors.get(far, "")) == kind:
					out.append(far - tile)
					break
			continue
		out.append(offset)
	return out


static func _segment(world: Node, vertices: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		tile: Vector2i, offset: Vector2i, color: Color) -> void:
	var a := Vector3(tile.x + 0.5,
		EuropeTerrain.ground_of(world, tile) + RIBBON_LIFT, tile.y + 0.5)
	var far := tile + offset
	var b := Vector3(far.x + 0.5,
		EuropeTerrain.ground_of(world, far) + RIBBON_LIFT, far.y + 0.5)
	var side := Vector3(-offset.y, 0, offset.x).normalized() * (RIBBON_W / 2.0)
	var base := vertices.size()
	# winding matches _quad's (the segment's first draft faced DOWN and
	# was back-face culled — an invisible strategic layer)
	for v: Vector3 in [a - side, b - side, b + side, a + side]:
		vertices.push_back(v)
		colors.push_back(color)
	for i: int in [0, 1, 2, 0, 2, 3]:
		indices.push_back(base + i)


static func _quad(world: Node, vertices: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		tile: Vector2i, half: float, color: Color,
		lift: float = RIBBON_LIFT) -> void:
	var y := EuropeTerrain.ground_of(world, tile) + lift
	var cx := tile.x + 0.5
	var cz := tile.y + 0.5
	var base := vertices.size()
	for corner: Vector2 in [Vector2(-half, -half), Vector2(half, -half),
			Vector2(half, half), Vector2(-half, half)]:
		vertices.push_back(Vector3(cx + corner.x, y, cz + corner.y))
		colors.push_back(color)
	for i: int in [0, 1, 2, 0, 2, 3]:
		indices.push_back(base + i)
