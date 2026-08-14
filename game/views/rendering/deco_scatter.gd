class_name DecoScatter
extends RefCounted
## Deterministic environment props for the continent (the sibling's
## DecoScatter idea at map scale): a low-frequency noise field carves FOREST
## MASSES over plains and hills and STONE FIELDS over mountains, so the land
## between the grid reads as terrain rather than empty felt.
##
## Props cluster — they are never sprinkled evenly. Everything is derived
## from the tile coordinate and a fixed seed, so two runs place identical
## forests (screenshot diffs stay meaningful), and the renderer draws each
## prop kind as ONE MultiMesh: thousands of trees, a handful of draw calls.

const SEED := 1337
const FOREST_LEVEL := 0.15   # noise above this = forest mass
const ROCK_LEVEL := 0.05     # on mountains, noise above this = stone field
## props per member tile — a tile is 15 km, so these are symbols of cover
const FOREST_DENSITY := 5
const ROCK_DENSITY := 3

const MODELS := {
	"tree": "res://assets/kenney/mini-forest/Models/GLB format/tree.glb",
	"rocks": "res://assets/kenney/mini-forest/Models/GLB format/rocks-low.glb",
}


## placements() -> {prop_name: Array[Transform3D]} in world space.
static func placements(world: Node) -> Dictionary:
	var noise := FastNoiseLite.new()
	noise.seed = SEED
	noise.frequency = 0.018  # ~18-tile features: regions, not speckle
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

	var out := {"tree": [] as Array[Transform3D], "rocks": [] as Array[Transform3D]}
	for y in range(world.height):
		for x in range(world.width):
			var tile := Vector2i(x, y)
			# never dress a tile the player has built on — the grid must read
			if world.corridors.has(tile) or world.plant_at(tile) != "" \
					or world.load_center_at(tile) != "":
				continue
			var kind := str(world.terrain_at(tile))
			var field := noise.get_noise_2d(float(x), float(y))
			var prop := ""
			var count := 0
			if kind == "p" or kind == "h" or kind == "c":
				if field > FOREST_LEVEL:
					prop = "tree"
					count = FOREST_DENSITY if kind != "c" else 1
			elif kind == "m":
				if field > ROCK_LEVEL:
					prop = "rocks"
					count = ROCK_DENSITY
			if prop == "" or count == 0:
				continue
			var base_y := EuropeTerrain.height_of(kind)
			for i in range(count):
				# deterministic jitter: a cheap integer hash, not RNG state
				var h := _hash(x, y, i)
				var ox := 0.16 + 0.68 * float(h % 1000) / 1000.0
				var oz := 0.16 + 0.68 * float((h / 1000) % 1000) / 1000.0
				var yaw := TAU * float((h / 7) % 360) / 360.0
				var scale := 0.30 + 0.16 * float((h / 13) % 100) / 100.0
				var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale)
				(out[prop] as Array[Transform3D]).append(Transform3D(basis,
					Vector3(x + ox, base_y, y + oz)))
	return out


static func _hash(x: int, y: int, i: int) -> int:
	var h := (x * 73856093) ^ (y * 19349663) ^ ((i + 1) * 83492791) ^ SEED
	return absi(h)


## Build one MultiMeshInstance3D per surface of a prop's GLB.
static func build_multimeshes(prop: String,
		transforms: Array[Transform3D]) -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	if transforms.is_empty():
		return out
	var scene: PackedScene = load(MODELS[prop])
	if scene == null:
		return out
	var sample := scene.instantiate()
	# GLB models are authored around their own origin at their own scale;
	# fold each source MeshInstance's local transform into the instances so
	# a multi-part prop keeps its shape
	for mesh_node: MeshInstance3D in sample.find_children("*", "MeshInstance3D",
			true, false):
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = mesh_node.mesh
		multi.instance_count = transforms.size()
		var local := mesh_node.global_transform if mesh_node.is_inside_tree() \
			else mesh_node.transform
		for i in range(transforms.size()):
			multi.set_instance_transform(i, transforms[i] * local)
		var node := MultiMeshInstance3D.new()
		node.multimesh = multi
		if mesh_node.mesh.get_surface_count() > 0:
			node.material_override = mesh_node.mesh.surface_get_material(0)
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		out.append(node)
	sample.queue_free()
	return out
