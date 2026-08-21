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

const RIBBON_LIFT := 0.045  # above terrain, below the water-plane epsilon
const SUB_SIZE := 1.8  # substation marker half-extent (tiles)
const SUB_COLOR := Color(0.95, 0.96, 0.97)


static func build_mesh(world: Node) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for tile: Vector2i in world.corridors:
		var kind := str(world.corridors[tile])
		var color: Color = PlantModels.HVDC_COLOR if kind == "hvdc" \
			else PlantModels.LINE_220_COLOR if kind == "line_220" \
			else PlantModels.LINE_400_COLOR
		_quad(world, vertices, colors, indices, tile, 0.5, color)
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
