extends Node3D
class_name TerrainStreamer
## Streams a real-elevation terrain built from the checked-in Kyoto DEM.
##
## Data pipeline: tools/build_world.py downloads AWS Terrain Tiles (Terrarium) and
## writes assets/terrain/heightmap.f32 + heightmap.json. This node turns that grid
## into chunked ArrayMeshes with collision, and loads/unloads chunks around the
## player so the whole 4 km region never has to exist in memory at once.

const META_PATH := "res://assets/terrain/heightmap.json"
const GRID_PATH := "res://assets/terrain/heightmap.f32"

## Chunk grid resolution across the whole region.
const CHUNK_GRID := 16
## Quads per chunk edge (so VERTS = QUADS + 1).
const CHUNK_QUADS := 32

signal chunk_loaded(coord: Vector2i)
signal terrain_ready

var _heights: PackedFloat32Array
var _hm_w: int = 0
var _hm_h: int = 0
var _world_x: float = 4000.0
var _world_z: float = 4000.0
var _elev_min: float = 0.0
var _elev_max: float = 200.0
var _chunk_size := Vector2.ZERO

var _chunks: Dictionary = {}          # Vector2i -> Node3D
var _player: Node3D
var _stream_radius: float = 1000.0
var _terrain_material: StandardMaterial3D
var _rock_material: StandardMaterial3D
var _collision_material: PhysicsMaterial

var _ready_flag := false


func _ready() -> void:
	_stream_radius = SettingsManager.get_draw_distance() if SettingsManager else 1000.0
	SettingsManager.settings_changed.connect(func() -> void: _stream_radius = SettingsManager.get_draw_distance())
	if not _load_data():
		push_error("TerrainStreamer: failed to load heightmap data")
		return
	_build_material()
	_collision_material = PhysicsMaterial.new()
	_collision_material.friction = 0.9
	_ready_flag = true
	terrain_ready.emit()


func _load_data() -> bool:
	if not FileAccess.file_exists(GRID_PATH) or not FileAccess.file_exists(META_PATH):
		push_error("TerrainStreamer: missing %s or %s" % [GRID_PATH, META_PATH])
		return false

	var meta_text := FileAccess.get_file_as_string(META_PATH)
	var meta: Variant = JSON.parse_string(meta_text)
	if typeof(meta) != TYPE_DICTIONARY:
		push_error("TerrainStreamer: heightmap.json is not valid JSON")
		return false
	var m: Dictionary = meta
	_elev_min = float(m.get("elevation_min_m", 0.0))
	_elev_max = float(m.get("elevation_max_m", 200.0))
	var ws: Dictionary = m.get("world_size_m", {})
	_world_x = float(ws.get("x", 4000.0))
	_world_z = float(ws.get("z", 4000.0))

	var bytes := FileAccess.get_file_as_bytes(GRID_PATH)
	if bytes.size() < 8:
		push_error("TerrainStreamer: heightmap.f32 truncated")
		return false
	_hm_w = bytes.decode_u32(0)
	_hm_h = bytes.decode_u32(4)
	var floats := bytes.slice(8).to_float32_array()
	if floats.size() < _hm_w * _hm_h:
		push_error("TerrainStreamer: heightmap.f32 has %d floats, expected %d" % [floats.size(), _hm_w * _hm_h])
		return false
	_heights = floats

	_chunk_size = Vector2(_world_x / CHUNK_GRID, _world_z / CHUNK_GRID)
	return true


func _build_material() -> void:
	_terrain_material = StandardMaterial3D.new()
	_terrain_material.albedo_color = Color(0.82, 0.86, 0.78)
	_terrain_material.roughness = 0.95
	_terrain_material.metallic = 0.0
	_terrain_material.uv1_scale = Vector3(90, 90, 1)

	var albedo := _load_texture("res://assets/textures/aerial_grass_rock/aerial_grass_rock_albedo.jpg")
	if albedo:
		_terrain_material.albedo_texture = albedo
	var normal := _load_texture("res://assets/textures/aerial_grass_rock/aerial_grass_rock_normal.jpg")
	if normal:
		_terrain_material.normal_enabled = true
		_terrain_material.normal_texture = normal
		_terrain_material.normal_scale = 0.8
	var rough := _load_texture("res://assets/textures/aerial_grass_rock/aerial_grass_rock_roughness.jpg")
	if rough:
		_terrain_material.roughness_texture = rough

	_terrain_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	# Higher-elevation chunks (the hills east of the city) use the rocky material
	# so the terrain reads as grass in the basin and exposed rock on the slopes.
	_rock_material = StandardMaterial3D.new()
	_rock_material.albedo_color = Color(0.72, 0.70, 0.66)
	_rock_material.roughness = 0.92
	_rock_material.uv1_scale = Vector3(110, 110, 1)
	_rock_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var rock_albedo := _load_texture("res://assets/textures/rocky_terrain_02/rocky_terrain_02_albedo.jpg")
	if rock_albedo:
		_rock_material.albedo_texture = rock_albedo
	var rock_normal := _load_texture("res://assets/textures/rocky_terrain_02/rocky_terrain_02_normal.jpg")
	if rock_normal:
		_rock_material.normal_enabled = true
		_rock_material.normal_texture = rock_normal
		_rock_material.normal_scale = 0.9


func _load_texture(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		push_warning("TerrainStreamer: texture not found: %s" % path)
		return null
	return load(path) as Texture2D


## Bilinear sample of real elevation, in world metres.
func get_height_at(x: float, z: float) -> float:
	if _heights.is_empty():
		return 0.0
	var u := clampf((x + _world_x * 0.5) / _world_x, 0.0, 1.0) * (_hm_w - 1)
	var v := clampf((z + _world_z * 0.5) / _world_z, 0.0, 1.0) * (_hm_h - 1)
	var x0 := int(floor(u))
	var y0 := int(floor(v))
	var x1: int = mini(x0 + 1, _hm_w - 1)
	var y1: int = mini(y0 + 1, _hm_h - 1)
	var fx := u - x0
	var fy := v - y0
	var h00 := _heights[y0 * _hm_w + x0]
	var h10 := _heights[y0 * _hm_w + x1]
	var h01 := _heights[y1 * _hm_w + x0]
	var h11 := _heights[y1 * _hm_w + x1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


func get_world_bounds() -> Rect2:
	return Rect2(-_world_x * 0.5, -_world_z * 0.5, _world_x, _world_z)


func world_to_chunk(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor((pos.x + _world_x * 0.5) / _chunk_size.x)),
		int(floor((pos.z + _world_z * 0.5) / _chunk_size.y))
	)


func chunk_to_world(coord: Vector2i) -> Vector3:
	return Vector3(
		-_world_x * 0.5 + coord.x * _chunk_size.x,
		get_height_at(-_world_x * 0.5 + coord.x * _chunk_size.x, -_world_z * 0.5 + coord.y * _chunk_size.y),
		-_world_z * 0.5 + coord.y * _chunk_size.y
	)


func _process(_delta: float) -> void:
	if not _ready_flag or _player == null:
		return
	update_streaming(_player.global_position)


func set_player(node: Node3D) -> void:
	_player = node
	update_streaming(_player.global_position)


## Load chunks inside the stream radius and free chunks outside the hysteresis band.
func update_streaming(pos: Vector3) -> void:
	if not _ready_flag:
		return
	var center := world_to_chunk(pos)
	var r := int(ceil(_stream_radius / _chunk_size.x)) + 1
	var wanted: Dictionary = {}

	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var c := Vector2i(center.x + dx, center.y + dy)
			if c.x < 0 or c.y < 0 or c.x >= CHUNK_GRID or c.y >= CHUNK_GRID:
				continue
			var world_c := Vector3(
				-_world_x * 0.5 + (c.x + 0.5) * _chunk_size.x,
				pos.y,
				-_world_z * 0.5 + (c.y + 0.5) * _chunk_size.y
			)
			if Vector2(world_c.x - pos.x, world_c.z - pos.z).length() > _stream_radius:
				continue
			wanted[c] = true
			if not _chunks.has(c):
				_load_chunk(c)

	var unload_dist := _stream_radius * 1.35
	for c: Vector2i in _chunks.keys():
		if not wanted.has(c):
			var wp := Vector3(
				-_world_x * 0.5 + (c.x + 0.5) * _chunk_size.x, pos.y,
				-_world_z * 0.5 + (c.y + 0.5) * _chunk_size.y
			)
			if Vector2(wp.x - pos.x, wp.z - pos.z).length() > unload_dist:
				_unload_chunk(c)


func _load_chunk(coord: Vector2i) -> void:
	var node := Node3D.new()
	node.name = "Chunk_%d_%d" % [coord.x, coord.y]

	var mesh := _build_chunk_mesh(coord)
	if mesh == null:
		node.queue_free()
		return

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.material_override = _material_for_chunk(coord)
	node.add_child(mi)

	var body := StaticBody3D.new()
	body.name = "Collision"
	body.physics_material_override = _collision_material
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var trimesh := ConcavePolygonShape3D.new()
	trimesh.set_faces(mesh.get_faces())
	shape.shape = trimesh
	body.add_child(shape)
	node.add_child(body)

	add_child(node)
	_chunks[coord] = node
	chunk_loaded.emit(coord)


func _material_for_chunk(coord: Vector2i) -> Material:
	var cx := -_world_x * 0.5 + (coord.x + 0.5) * _chunk_size.x
	var cz := -_world_z * 0.5 + (coord.y + 0.5) * _chunk_size.y
	var h := get_height_at(cx, cz)
	# Kyoto basin sits roughly 30-90 m; the surrounding hills rise to ~245 m.
	if h > 115.0:
		return _rock_material
	return _terrain_material


func _unload_chunk(coord: Vector2i) -> void:
	var node: Node3D = _chunks.get(coord)
	if node:
		node.queue_free()
		_chunks.erase(coord)


func _build_chunk_mesh(coord: Vector2i) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var step_x := _chunk_size.x / CHUNK_QUADS
	var step_z := _chunk_size.y / CHUNK_QUADS
	var origin_x := -_world_x * 0.5 + coord.x * _chunk_size.x
	var origin_z := -_world_z * 0.5 + coord.y * _chunk_size.y
	var n := CHUNK_QUADS + 1

	for iz in range(n):
		for ix in range(n):
			var wx := origin_x + ix * step_x
			var wz := origin_z + iz * step_z
			var h := get_height_at(wx, wz)
			verts.append(Vector3(wx, h, wz))
			uvs.append(Vector2(float(ix) / CHUNK_QUADS, float(iz) / CHUNK_QUADS))

	# Normals from finite differences of the real elevation field.
	for iz in range(n):
		for ix in range(n):
			var wx := origin_x + ix * step_x
			var wz := origin_z + iz * step_z
			var hl := get_height_at(wx - step_x, wz)
			var hr := get_height_at(wx + step_x, wz)
			var hd := get_height_at(wx, wz - step_z)
			var hu := get_height_at(wx, wz + step_z)
			var nrm := Vector3(hl - hr, 2.0 * step_x, hd - hu).normalized()
			normals.append(nrm)

	for iz in range(CHUNK_QUADS):
		for ix in range(CHUNK_QUADS):
			var i0 := iz * n + ix
			var i1 := i0 + 1
			var i2 := i0 + n
			var i3 := i2 + 1
			indices.append_array([i0, i2, i1, i1, i2, i3])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func get_loaded_chunk_count() -> int:
	return _chunks.size()


func clear_all() -> void:
	for c: Vector2i in _chunks.keys():
		_unload_chunk(c)
	_chunks.clear()


## Returns the highest point of the region (the Higashiyama hills). Used to frame a
## real-elevation vista for visual acceptance.
func find_viewpoint() -> Vector3:
	if _heights.is_empty():
		return Vector3.ZERO
	var step := maxi(1, _hm_w / 64)
	var best := Vector3.ZERO
	var best_h := -INF
	for iy in range(0, _hm_h, step):
		for ix in range(0, _hm_w, step):
			var h := _heights[iy * _hm_w + ix]
			if h <= best_h:
				continue
			best_h = h
			best = Vector3(
				-_world_x * 0.5 + (_world_x * float(ix) / float(_hm_w - 1)),
				h,
				-_world_z * 0.5 + (_world_z * float(iy) / float(_hm_h - 1))
			)
	return best


## Returns a random walkable point inside the region, snapped to terrain.
func find_spawn_point(seed_value: int = 0) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value if seed_value != 0 else 12345
	# Prefer the flatter city centre for a clean start.
	var best := Vector3.ZERO
	var best_score := INF
	for _i in range(64):
		var x := rng.randf_range(-600.0, 600.0)
		var z := rng.randf_range(-600.0, 600.0)
		var h := get_height_at(x, z)
		# Score: flat terrain, low elevation, close to centre.
		var slope := absf(get_height_at(x + 8.0, z) - get_height_at(x - 8.0, z))
		var score := slope * 4.0 + maxf(0.0, h - 80.0) * 0.02 + Vector2(x, z).length() * 0.001
		if score < best_score:
			best_score = score
			best = Vector3(x, h + 2.0, z)
	return best
