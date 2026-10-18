extends Node3D
class_name PlateauCity
## Streams real PLATEAU (Japanese government 3D city model) buildings.
##
## The source tiles are 3D Tiles 1.0 b3dm payloads compressed with
## KHR_draco_mesh_compression, which Godot cannot decode at runtime. They are
## converted offline by `tools/fetch_plateau.py` into compact `.pmesh` binaries
## (positions, normals, indices) already transformed into this project's world
## space. This node streams those binaries around the player.
##
## Failure behaviour, by design:
##   * missing index or missing tile files are warnings, never crashes;
##   * a tile that fails to parse is skipped and will not be retried on every
##     frame (it is marked failed);
##   * if nothing is available the rest of the world still runs.

signal plateau_ready(tile_count: int)
signal tile_loaded(index: int)

const INDEX_PATH := "res://assets/plateau/index.json"
const PMSH_MAGIC := "PMSH"

## Per-channel correction applied to the facade albedo, solved from the measured mean
## of `painted_concrete`'s albedo (72,106,79) — a green-painted wall — so real PLATEAU
## geometry is not rendered green:
##   (0.282, 0.416, 0.310) * (1.30, 0.88, 1.20) = (0.367, 0.366, 0.372)
## tests/validate_project.gd asserts the resulting effective albedo stays neutral.
const FACADE_TINT := Color(1.30, 0.88, 1.20)

## How many tiles may be built per frame, so streaming never spikes the frame.
const LOADS_PER_FRAME := 2

var available := false
var vertical_offset := 0.0
var tile_count := 0

var _tiles: Array = []
var _loaded: Dictionary = {}      # index -> Node3D
var _failed: Dictionary = {}      # index -> true
var _coverage: Dictionary = {}    # Vector2i (100 m cells) -> true
var _player: Node3D
var _terrain: TerrainStreamer
var _radius := 1200.0
var _material: StandardMaterial3D
var _pending: Array[int] = []
var _stats := {"loaded": 0, "vertices": 0, "triangles": 0, "failed": 0}


func setup(terrain: TerrainStreamer) -> void:
	_terrain = terrain
	_radius = SettingsManager.get_draw_distance() * 0.85
	if SettingsManager:
		SettingsManager.settings_changed.connect(func() -> void:
			_radius = SettingsManager.get_draw_distance() * 0.85)
	_build_material()
	if not _load_index():
		push_warning("PlateauCity: PLATEAU data unavailable (run tools/fetch_plateau.py)")
		return
	available = true
	_build_coverage()
	plateau_ready.emit(tile_count)


func _build_material() -> void:
	_material = StandardMaterial3D.new()
	# PLATEAU non-textured LOD2 carries geometry only; shade it as painted
	# concrete/mortar so it reads as a Japanese city block rather than white boxes.
	_material.albedo_color = FACADE_TINT
	_material.roughness = 0.82
	_material.metallic = 0.0
	_material.uv1_triplanar = true
	_material.uv1_world_triplanar = true
	_material.uv1_scale = Vector3(0.35, 0.35, 0.35)
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var albedo := load("res://assets/textures/painted_concrete/painted_concrete_albedo.jpg") as Texture2D
	if albedo:
		_material.albedo_texture = albedo
	var nrm := load("res://assets/textures/painted_concrete/painted_concrete_normal.jpg") as Texture2D
	if nrm:
		_material.normal_enabled = true
		_material.normal_texture = nrm


func _load_index() -> bool:
	if not FileAccess.file_exists(INDEX_PATH):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("PlateauCity: index.json is not valid JSON")
		return false
	var idx: Dictionary = parsed
	var raw_tiles: Array = idx.get("tiles", [])
	if raw_tiles.is_empty():
		return false
	_tiles = raw_tiles
	vertical_offset = float(idx.get("vertical_offset_m", 0.0))
	tile_count = _tiles.size()

	# The .pmesh files are generated (not committed) because the full Kyoto set
	# is ~157 MB. If the pipeline has not run, degrade to OSM fallback buildings
	# with a single clear warning instead of one warning per tile.
	var probe := String((_tiles[0] as Dictionary).get("file", ""))
	if probe.is_empty() or not FileAccess.file_exists("res://assets/plateau/" + probe):
		push_warning("PlateauCity: index.json present but meshes are missing; run tools/fetch_plateau.py")
		return false
	return true


## Mark 100 m cells covered by PLATEAU so OSM box buildings can be suppressed
## only where real geometry exists (partial coverage must still fall back).
## Build coverage only from wards whose mesh files are actually present on disk.
## The index lists every tile the pipeline *intended* to write, but an individual
## .pmesh can be missing (partial run, deleted, etc.). If we suppress OSM buildings
## from the whole index we get holes where fallback buildings should appear.
func _build_coverage() -> void:
	# Group tiles by ward so we can test whether a ward's files exist.
	var by_ward: Dictionary = {}
	for t: Dictionary in _tiles:
		var rel: String = String(t.get("file", ""))
		if rel.is_empty():
			continue
		var slash: int = rel.find("/")
		var ward: String = rel.substr(0, slash) if slash >= 0 else rel
		var list: Array = by_ward.get(ward, [])
		list.append(t)
		by_ward[ward] = list

	for ward: String in by_ward.keys():
		# A ward is "present" when at least one of its tiles exists on disk.
		var tiles: Array = by_ward[ward]
		var any_present := false
		for t: Dictionary in tiles:
			var rel: String = String(t.get("file", ""))
			if FileAccess.file_exists("res://assets/plateau/" + rel):
				any_present = true
				break
		if not any_present:
			continue
		for t: Dictionary in tiles:
			var b: Array = t.get("bounds", [])
			if b.size() < 6:
				continue
			for cx in range(int(floor(float(b[0]) / 100.0)), int(floor(float(b[3]) / 100.0)) + 1):
				for cz in range(int(floor(float(b[2]) / 100.0)), int(floor(float(b[5]) / 100.0)) + 1):
					_coverage[Vector2i(cx, cz)] = true


func is_covered(x: float, z: float) -> bool:
	if not available:
		return false
	return _coverage.has(Vector2i(int(floor(x / 100.0)), int(floor(z / 100.0))))


func set_player(node: Node3D) -> void:
	_player = node
	update_streaming(node.global_position)


func _process(_delta: float) -> void:
	if not available or _player == null:
		return
	update_streaming(_player.global_position)
	_drain_pending()


func update_streaming(pos: Vector3) -> void:
	var want: Dictionary = {}
	for i in range(_tiles.size()):
		if _failed.has(i):
			continue
		var b: Array = _tiles[i].get("bounds", [])
		if b.size() < 6:
			continue
		var cx := (float(b[0]) + float(b[3])) * 0.5
		var cz := (float(b[2]) + float(b[5])) * 0.5
		var half := Vector2(float(b[3]) - float(b[0]), float(b[5]) - float(b[2])).length() * 0.5
		var d := Vector2(cx - pos.x, cz - pos.z).length()
		if d - half > _radius:
			continue
		want[i] = true
		if not _loaded.has(i) and not _pending.has(i):
			_pending.append(i)

	var unload := _radius * 1.35
	for i: int in _loaded.keys():
		var b: Array = _tiles[i].get("bounds", [])
		if b.size() < 6:
			continue
		var cx := (float(b[0]) + float(b[3])) * 0.5
		var cz := (float(b[2]) + float(b[5])) * 0.5
		var half := Vector2(float(b[3]) - float(b[0]), float(b[5]) - float(b[2])).length() * 0.5
		if Vector2(cx - pos.x, cz - pos.z).length() - half > unload:
			_unload_tile(i)


func _drain_pending() -> void:
	var budget := LOADS_PER_FRAME
	while budget > 0 and not _pending.is_empty():
		var i: int = _pending.pop_front()
		if _loaded.has(i) or _failed.has(i):
			continue
		_load_tile(i)
		budget -= 1


func _load_tile(index: int) -> void:
	var entry: Dictionary = _tiles[index]
	var rel := String(entry.get("file", ""))
	if rel.is_empty():
		return
	var path := "res://assets/plateau/" + rel
	if not FileAccess.file_exists(path):
		_failed[index] = true
		_stats["failed"] = int(_stats["failed"]) + 1
		push_warning("PlateauCity: missing tile %s" % path)
		return

	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != PMSH_MAGIC:
		_failed[index] = true
		push_warning("PlateauCity: bad pmesh header in %s" % path)
		return

	var vcount := bytes.decode_u32(8)
	var icount := bytes.decode_u32(12)
	var expected := 44 + vcount * 24 + icount * 4
	if bytes.size() != expected:
		_failed[index] = true
		push_warning("PlateauCity: truncated pmesh %s (%d vs %d)" % [path, bytes.size(), expected])
		return

	var min_x := bytes.decode_float(20)
	var min_y := bytes.decode_float(24)
	var min_z := bytes.decode_float(28)
	var max_x := bytes.decode_float(32)
	var max_y := bytes.decode_float(36)
	var max_z := bytes.decode_float(40)

	var vf := bytes.slice(44, 44 + vcount * 12).to_float32_array()
	var nf := bytes.slice(44 + vcount * 12, 44 + vcount * 24).to_float32_array()
	var idx := bytes.slice(44 + vcount * 24).to_int32_array()

	if vf.size() < vcount * 3 or nf.size() < vcount * 3:
		_failed[index] = true
		push_warning("PlateauCity: short vertex buffer in %s" % path)
		return

	# Mesh surfaces require PackedVector3Array, and the vertices also need the
	# vertical datum shift applied.
	var verts := PackedVector3Array()
	verts.resize(vcount)
	var nrms := PackedVector3Array()
	nrms.resize(vcount)
	for i in range(vcount):
		var k := i * 3
		verts[i] = Vector3(vf[k], vf[k + 1] + vertical_offset, vf[k + 2])
		nrms[i] = Vector3(nf[k], nf[k + 1], nf[k + 2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = nrms
	arrays[Mesh.ARRAY_INDEX] = idx

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var node := Node3D.new()
	node.name = "PTile_%04d" % index
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.material_override = _material
	node.add_child(mi)

	# Collision only for tiles close enough to walk into.
	if _player and _near_player(min_x, max_x, min_z, max_z, 450.0):
		var body := StaticBody3D.new()
		body.name = "Collision"
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var concave := ConcavePolygonShape3D.new()
		concave.set_faces(mesh.get_faces())
		shape.shape = concave
		body.add_child(shape)
		node.add_child(body)

	add_child(node)
	_loaded[index] = node
	_stats["loaded"] = _loaded.size()
	_stats["vertices"] = int(_stats["vertices"]) + vcount
	_stats["triangles"] = int(_stats["triangles"]) + icount / 3
	tile_loaded.emit(index)


func _near_player(min_x: float, max_x: float, min_z: float, max_z: float, radius: float) -> bool:
	var cx := (min_x + max_x) * 0.5
	var cz := (min_z + max_z) * 0.5
	return Vector2(cx - _player.global_position.x, cz - _player.global_position.z).length() <= radius


func _unload_tile(index: int) -> void:
	var node: Node3D = _loaded.get(index)
	if node == null:
		return
	_loaded.erase(index)
	if node.is_inside_tree():
		node.queue_free()
	_stats["loaded"] = _loaded.size()


func get_stats() -> Dictionary:
	return _stats.duplicate()


func get_loaded_tile_count() -> int:
	return _loaded.size()


## Centre of the indexed tile nearest `from`, in world metres, or Vector3.ZERO when
## there is no index. Used to frame the real PLATEAU geometry for visual acceptance.
func get_nearest_tile_center(from: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var best_d := INF
	for t: Dictionary in _tiles:
		var b: Array = t.get("bounds", [])
		if b.size() < 6:
			continue
		var c := Vector3(
			(float(b[0]) + float(b[3])) * 0.5,
			(float(b[1]) + float(b[4])) * 0.5 + vertical_offset,
			(float(b[2]) + float(b[5])) * 0.5
		)
		var d := Vector2(c.x - from.x, c.z - from.z).length()
		if d < best_d:
			best_d = d
			best = c
	return best


## Bounds of the loaded tile nearest `from`, as a Dictionary with "size" (Vector3)
## and "position", or an empty Dictionary when nothing is loaded nearby.
func get_nearest_loaded_bounds(from: Vector3) -> Dictionary:
	var best := {}
	var best_d := INF
	for i: int in _loaded.keys():
		var b: Array = _tiles[i].get("bounds", [])
		if b.size() < 6:
			continue
		var centre := Vector2((float(b[0]) + float(b[3])) * 0.5, (float(b[2]) + float(b[5])) * 0.5)
		var d := Vector2(centre.x - from.x, centre.y - from.z).length()
		if d < best_d:
			best_d = d
			best = {
				"size": Vector3(float(b[3]) - float(b[0]), float(b[4]) - float(b[1]), float(b[5]) - float(b[2])),
				"position": Vector3(centre.x, float(b[1]) + vertical_offset, centre.y),
			}
	return best


func get_available_tile_count() -> int:
	return _tiles.size()


func clear_all() -> void:
	for i: int in _loaded.keys():
		_unload_tile(i)
	_loaded.clear()
	_pending.clear()
