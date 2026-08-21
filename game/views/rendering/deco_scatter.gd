class_name DecoScatter
extends RefCounted
## Deterministic environment props for the continent (the sibling's
## DecoScatter idea at map scale): a low-frequency noise field carves FOREST
## MASSES over plains and hills and STONE FIELDS over mountains, so the land
## between the grid reads as terrain rather than empty felt.
##
## Props cluster — they are never sprinkled evenly. Everything derives from
## the tile coordinate and a fixed seed, so a chunk scattered now and the
## same chunk scattered after an eviction land identically (streaming must
## not make forests wander), and each chunk draws its props as MultiMeshes:
## thousands of trees, a handful of draw calls.

const SEED := 1337
const FOREST_LEVEL := 0.15   # noise above this = forest mass
const ROCK_LEVEL := 0.05     # on mountains, noise above this = stone field
## props per member tile — a tile is 5 km, so these are symbols of cover
const FOREST_DENSITY := 2
const ROCK_DENSITY := 1

const MODELS := {
	"tree": "res://assets/kenney/mini-forest/Models/GLB format/tree.glb",
	"rocks": "res://assets/kenney/mini-forest/Models/GLB format/rocks-low.glb",
}

## a forest region is ~250 km across whatever the tile size is — frequency
## is cycles per TILE, so it has to follow the grid resolution or the same
## constant paints continent-sized woods on a fine map
const FOREST_SPAN_KM := 250.0

## prop -> Array of {mesh, material, local} — extracted from the GLB ONCE.
## Chunks are built and freed constantly; instantiating the source scene per
## chunk showed up immediately in the streaming budget.
static var _mesh_cache := {}
## one shared noise object, rebuilt only when the map resolution changes
static var _noise: FastNoiseLite = null
static var _noise_tile_km := 0.0


static func _field(tile_km: float) -> FastNoiseLite:
	if _noise == null or not is_equal_approx(_noise_tile_km, tile_km):
		var noise := FastNoiseLite.new()
		noise.seed = SEED
		noise.frequency = maxf(tile_km, 0.5) / FOREST_SPAN_KM
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_noise = noise
		_noise_tile_km = tile_km
	return _noise


## Props for ONE region [x0, x1) x [y0, y1) -> {prop_name: Array[Transform3D]}.
static func placements_region(world: Node, x0: int, y0: int,
		x1: int, y1: int) -> Dictionary:
	var noise := _field(world.tile_km)
	var out := {"tree": [] as Array[Transform3D],
		"rocks": [] as Array[Transform3D]}
	for y in range(y0, y1):
		for x in range(x0, x1):
			var tile := Vector2i(x, y)
			# never dress a tile the player has built on — the grid must read
			if world.corridors.has(tile) or world.plant_at(tile) != "" \
					or world.load_center_at(tile) != "":
				continue
			var kind := world.terrain_at(tile) as String
			var prop := ""
			var count := 0
			if world.get("has_relief"):
				# the relief sidecar carries REAL vegetation density — the
				# tree cover follows it, so the scattered forests and the
				# dark-green terrain tint are the same forests
				var veg: float = world.green_at(tile)
				if kind == "m" and veg < 0.30:
					# stone fields only above the treeline-ish, and sparse
					if world.elev_at(tile) > 1400.0 \
							and noise.get_noise_2d(float(x), float(y)) > 0.35:
						prop = "rocks"
						count = ROCK_DENSITY
				elif veg > 0.42 and kind != "S" and kind != "s":
					prop = "tree"
					count = 1 + int(veg * 2.6)
			elif kind == "p" or kind == "h" or kind == "c":
				if noise.get_noise_2d(float(x), float(y)) > FOREST_LEVEL:
					prop = "tree"
					count = FOREST_DENSITY if kind != "c" else 1
			elif kind == "m":
				if noise.get_noise_2d(float(x), float(y)) > ROCK_LEVEL:
					prop = "rocks"
					count = ROCK_DENSITY
			if prop == "" or count == 0:
				continue
			var base_y := EuropeTerrain.ground_of(world, tile)
			for i in range(count):
				# deterministic jitter: a cheap integer hash, not RNG state,
				# so a re-streamed chunk reproduces its forest exactly
				var h := _hash(x, y, i)
				var ox := 0.16 + 0.68 * float(h % 1000) / 1000.0
				var oz := 0.16 + 0.68 * float((h / 1000) % 1000) / 1000.0
				var yaw := TAU * float((h / 7) % 360) / 360.0
				var scale := 0.34 + 0.20 * float((h / 13) % 100) / 100.0
				var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale)
				(out[prop] as Array[Transform3D]).append(Transform3D(basis,
					Vector3(x + ox, base_y, y + oz)))
	return out


## Whole-map scatter (small maps, tests). The renderer streams instead.
static func placements(world: Node) -> Dictionary:
	return placements_region(world, 0, 0, world.width, world.height)


static func _hash(x: int, y: int, i: int) -> int:
	var h := (x * 73856093) ^ (y * 19349663) ^ ((i + 1) * 83492791) ^ SEED
	return absi(h)


## Extract a prop's meshes from its GLB once and keep them: the streamer
## rebuilds MultiMeshes constantly but the source geometry never changes.
static func _parts(prop: String) -> Array:
	if _mesh_cache.has(prop):
		return _mesh_cache[prop] as Array
	var parts: Array = []
	var scene: PackedScene = load(MODELS[prop])
	if scene != null:
		var sample := scene.instantiate()
		# GLB models are authored around their own origin at their own scale;
		# fold each source MeshInstance's local transform into the instances
		# so a multi-part prop keeps its shape
		for mesh_node: MeshInstance3D in sample.find_children("*",
				"MeshInstance3D", true, false):
			var material: Material = null
			if mesh_node.mesh != null and mesh_node.mesh.get_surface_count() > 0:
				material = mesh_node.mesh.surface_get_material(0)
			parts.append({"mesh": mesh_node.mesh, "material": material,
				"local": mesh_node.transform})
		sample.queue_free()
	_mesh_cache[prop] = parts
	return parts


## Build one MultiMeshInstance3D per surface of a prop.
static func build_multimeshes(prop: String,
		transforms: Array[Transform3D]) -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	if transforms.is_empty():
		return out
	for part: Dictionary in _parts(prop):
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = part["mesh"] as Mesh
		multi.instance_count = transforms.size()
		var local := part["local"] as Transform3D
		for i in range(transforms.size()):
			multi.set_instance_transform(i, transforms[i] * local)
		var node := MultiMeshInstance3D.new()
		node.multimesh = multi
		if part["material"] != null:
			node.material_override = part["material"] as Material
		# props are small and numerous; their shadows cost more than they add
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		out.append(node)
	return out
