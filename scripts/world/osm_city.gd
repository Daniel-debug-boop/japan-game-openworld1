extends Node3D
class_name OsmCity
## Builds and streams real OpenStreetMap content for the Kyoto slice.
##
## Data pipeline: tools/build_world.py queries the Overpass API (ODbL 1.0) and packs
## roads.dat / buildings.dat. This node extrudes Building footprints into prisms,
## turns road centrelines into terrain-following ribbons, and streams both per
## terrain chunk so only nearby geometry exists in the scene.

const ROADS_PATH := "res://assets/world/roads.dat"
const BUILDINGS_PATH := "res://assets/world/buildings.dat"
const CHUNK_GRID := 16

const LEVEL_HEIGHT := 3.2
const BUILDING_MIN_HEIGHT := 2.8

## Per-channel correction applied to the facade albedo. Poly Haven's
## `painted_concrete` albedo is a *green*-painted wall (measured mean RGB
## 72,106,79); used raw it painted every Kyoto facade mint-green and, because the
## texture tiles densely in world space, the distant city averaged to flat green
## blocks. Solved so the texture's surface detail survives while the hue becomes
## concrete grey, without raising brightness:
##   (0.282, 0.416, 0.310) * (1.25, 0.85, 1.15) = (0.352, 0.354, 0.357)
## tests/validate_project.gd asserts the resulting effective albedo stays neutral.
const FACADE_TINT := Color(1.25, 0.85, 1.15)

var _terrain: TerrainStreamer
var _world_x: float = 4000.0
var _world_z: float = 4000.0
var _chunk_size := Vector2(250.0, 250.0)

# Parsed source data.
var _buildings: Array[Dictionary] = []
var _roads: Array[Dictionary] = []

# Spatial index: chunk coord -> arrays of indices.
var _bldg_by_chunk: Dictionary = {}
var _road_by_chunk: Dictionary = {}

# Live chunk geometry.
var _loaded: Dictionary = {}   # Vector2i -> Node3D

var _road_material: StandardMaterial3D
var _building_material: StandardMaterial3D
var _road_mesh_cache: Dictionary = {}
var _stats := {"buildings": 0, "roads": 0, "chunks": 0, "suppressed": 0}
## Optional predicate (x, z) -> bool. When it returns true the area already has
## real PLATEAU geometry, so extruding a fallback OSM box there would double up.
var _coverage_check: Callable = Callable()


func set_coverage_check(cb: Callable) -> void:
	_coverage_check = cb


func setup(terrain: TerrainStreamer) -> void:
	_terrain = terrain
	var bounds := terrain.get_world_bounds()
	_world_x = bounds.size.x
	_world_z = bounds.size.y
	_chunk_size = Vector2(_world_x / CHUNK_GRID, _world_z / CHUNK_GRID)

	_build_materials()
	if not _parse_data():
		push_error("OsmCity: failed to parse OSM data")
		return
	_index_data()
	terrain.chunk_loaded.connect(_on_chunk_loaded)
	pass


func _build_materials() -> void:
	_road_material = StandardMaterial3D.new()
	_road_material.albedo_color = Color(0.32, 0.32, 0.34)
	_road_material.roughness = 0.85
	_road_material.uv1_scale = Vector3(0.35, 0.35, 1)
	_road_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var asphalt := load("res://assets/textures/aerial_asphalt_01/aerial_asphalt_01_albedo.jpg") as Texture2D
	if asphalt:
		_road_material.albedo_texture = asphalt
	var asphalt_n := load("res://assets/textures/aerial_asphalt_01/aerial_asphalt_01_normal.jpg") as Texture2D
	if asphalt_n:
		_road_material.normal_enabled = true
		_road_material.normal_texture = asphalt_n

	_building_material = StandardMaterial3D.new()
	_building_material.albedo_color = FACADE_TINT
	_building_material.roughness = 0.8
	_building_material.uv1_scale = Vector3(0.5, 0.5, 1)
	_building_material.uv1_triplanar = true
	_building_material.uv1_world_triplanar = true
	var concrete := load("res://assets/textures/painted_concrete/painted_concrete_albedo.jpg") as Texture2D
	if concrete:
		_building_material.albedo_texture = concrete
	var concrete_n := load("res://assets/textures/painted_concrete/painted_concrete_normal.jpg") as Texture2D
	if concrete_n:
		_building_material.normal_enabled = true
		_building_material.normal_texture = concrete_n


func _parse_data() -> bool:
	if not FileAccess.file_exists(BUILDINGS_PATH) or not FileAccess.file_exists(ROADS_PATH):
		push_error("OsmCity: missing %s or %s" % [BUILDINGS_PATH, ROADS_PATH])
		return false

	# --- buildings ---------------------------------------------------------
	var b := FileAccess.get_file_as_bytes(BUILDINGS_PATH)
	if b.size() < 8 or b.slice(0, 4).get_string_from_ascii() != "BD01":
		push_error("OsmCity: bad buildings.dat magic")
		return false
	var count := b.decode_u32(4)
	var off := 8
	_buildings.resize(count)
	for i in range(count):
		var id := b.decode_u32(off)
		off += 4
		var levels := b.decode_u8(off)
		off += 1
		var npoints := b.decode_u32(off)
		off += 4
		var pts := PackedVector2Array()
		pts.resize(npoints)
		for p in range(npoints):
			var x := b.decode_float(off)
			off += 4
			var z := b.decode_float(off)
			off += 4
			pts[p] = Vector2(x, z)
		_buildings[i] = {"id": id, "levels": int(levels), "points": pts}

	# --- roads -------------------------------------------------------------
	var r := FileAccess.get_file_as_bytes(ROADS_PATH)
	if r.size() < 8 or r.slice(0, 4).get_string_from_ascii() != "RD01":
		push_error("OsmCity: bad roads.dat magic")
		return false
	var rcount := r.decode_u32(4)
	var roff := 8
	_roads.resize(rcount)
	for i in range(rcount):
		var id := r.decode_u32(roff)
		roff += 4
		var code := r.decode_u8(roff)
		roff += 1
		var width := r.decode_float(roff)
		roff += 4
		var npoints := r.decode_u32(roff)
		roff += 4
		var pts := PackedVector2Array()
		pts.resize(npoints)
		for p in range(npoints):
			var x := r.decode_float(roff)
			roff += 4
			var z := r.decode_float(roff)
			roff += 4
			pts[p] = Vector2(x, z)
		_roads[i] = {"id": id, "code": int(code), "width": width, "points": pts}

	_stats["buildings"] = _buildings.size()
	_stats["roads"] = _roads.size()
	return true


func _chunk_of(x: float, z: float) -> Vector2i:
	return Vector2i(
		clampi(int(floor((x + _world_x * 0.5) / _chunk_size.x)), 0, CHUNK_GRID - 1),
		clampi(int(floor((z + _world_z * 0.5) / _chunk_size.y)), 0, CHUNK_GRID - 1)
	)


func _index_data() -> void:
	for i in range(_buildings.size()):
		var pts: PackedVector2Array = _buildings[i]["points"]
		if pts.is_empty():
			continue
		var c := _chunk_of(pts[0].x, pts[0].y)
		if not _bldg_by_chunk.has(c):
			_bldg_by_chunk[c] = []
		_bldg_by_chunk[c].append(i)

	for i in range(_roads.size()):
		var pts: PackedVector2Array = _roads[i]["points"]
		if pts.is_empty():
			continue
		# Index a road into every chunk it touches.
		var seen: Dictionary = {}
		for p in pts:
			var c := _chunk_of(p.x, p.y)
			if not seen.has(c):
				seen[c] = true
				if not _road_by_chunk.has(c):
					_road_by_chunk[c] = []
				_road_by_chunk[c].append(i)


func _on_chunk_loaded(coord: Vector2i) -> void:
	if _loaded.has(coord):
		return
	_build_chunk(coord)


func _build_chunk(coord: Vector2i) -> void:
	var root := Node3D.new()
	root.name = "City_%d_%d" % [coord.x, coord.y]

	var bldg_indices: Array = _bldg_by_chunk.get(coord, [])
	if not bldg_indices.is_empty():
		var result := _build_buildings_mesh(bldg_indices)
		if result.mesh != null:
			var mi := MeshInstance3D.new()
			mi.name = "Buildings"
			mi.mesh = result.mesh
			mi.material_override = _building_material
			root.add_child(mi)
			if not result.collision_faces.is_empty():
				var body := StaticBody3D.new()
				body.name = "BuildingCollision"
				body.collision_layer = 1
				body.collision_mask = 0
				var shape := CollisionShape3D.new()
				var concave := ConcavePolygonShape3D.new()
				concave.set_faces(result.collision_faces)
				shape.shape = concave
				body.add_child(shape)
				root.add_child(body)

	var road_indices: Array = _road_by_chunk.get(coord, [])
	if not road_indices.is_empty():
		var road_mesh := _build_roads_mesh(road_indices)
		if road_mesh != null:
			var rmi := MeshInstance3D.new()
			rmi.name = "Roads"
			rmi.mesh = road_mesh
			rmi.material_override = _road_material
			rmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(rmi)

	if root.get_child_count() > 0:
		add_child(root)
		_loaded[coord] = root
		_stats["chunks"] = _loaded.size()


func _build_buildings_mesh(indices: Array) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var faces := PackedVector3Array()

	for idx: int in indices:
		var bdata: Dictionary = _buildings[idx]
		var pts: PackedVector2Array = bdata["points"]
		if pts.size() < 3:
			continue

		# Compute footprint centroid and terrain base height.
		var cx := 0.0
		var cz := 0.0
		for p in pts:
			cx += p.x
			cz += p.y
		cx /= pts.size()
		cz /= pts.size()

		# Prefer real PLATEAU geometry where it exists; OSM boxes are the
		# fallback for areas PLATEAU does not cover.
		if _coverage_check.is_valid() and bool(_coverage_check.call(cx, cz)):
			_stats["suppressed"] = int(_stats["suppressed"]) + 1
			continue

		var base := INF
		for p in pts:
			base = minf(base, _terrain.get_height_at(p.x, p.y))
		base -= 0.6   # sink slightly into the terrain

		var levels: int = maxi(int(bdata["levels"]), 1)
		var height: float = maxf(levels * LEVEL_HEIGHT, BUILDING_MIN_HEIGHT)
		var top := base + height

		# Walls.
		for i in range(pts.size()):
			var a := pts[i]
			var b2 := pts[(i + 1) % pts.size()]
			var edge := Vector2(b2.x - a.x, b2.y - a.y)
			if edge.length() < 0.5:
				continue
			var nrm := Vector3(-edge.y, 0.0, edge.x).normalized()
			if nrm.length() < 0.5:
				nrm = Vector3.UP

			var p0 := Vector3(a.x, base, a.y)
			var p1 := Vector3(b2.x, base, b2.y)
			var p2 := Vector3(b2.x, top, b2.y)
			var p3 := Vector3(a.x, top, a.y)

			_add_quad(verts, normals, uvs, faces, p0, p1, p2, p3, nrm, height)

		# Flat roof (triangle fan from centroid).
		var roof_center := Vector3(cx, top, cz)
		for i in range(pts.size()):
			var a := pts[i]
			var b2 := pts[(i + 1) % pts.size()]
			var va := Vector3(a.x, top, a.y)
			var vb := Vector3(b2.x, top, b2.y)
			verts.append(roof_center)
			verts.append(va)
			verts.append(vb)
			for _k in range(3):
				normals.append(Vector3.UP)
			uvs.append(Vector2(0.5, 0.5))
			uvs.append(Vector2(0.0, 0.0))
			uvs.append(Vector2(1.0, 0.0))

	if verts.is_empty():
		return {"mesh": null, "collision_faces": faces}

	# We appended raw triangles, so the index buffer is simply sequential.
	var index_buffer := PackedInt32Array()
	for i in range(verts.size()):
		index_buffer.append(i)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = index_buffer

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"mesh": mesh, "collision_faces": faces}


func _add_quad(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
		faces: PackedVector3Array, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		nrm: Vector3, height: float) -> void:
	# Two triangles, wound counter-clockwise when viewed from outside.
	verts.append(p0); verts.append(p1); verts.append(p2)
	verts.append(p0); verts.append(p2); verts.append(p3)
	for _i in range(6):
		normals.append(nrm)
	var u_scale := 0.25
	uvs.append(Vector2(0, height * u_scale))
	uvs.append(Vector2(p0.distance_to(p1) * u_scale, height * u_scale))
	uvs.append(Vector2(p0.distance_to(p1) * u_scale, 0))
	uvs.append(Vector2(0, height * u_scale))
	uvs.append(Vector2(p0.distance_to(p1) * u_scale, 0))
	uvs.append(Vector2(0, 0))
	faces.append(p0); faces.append(p1); faces.append(p2)
	faces.append(p0); faces.append(p2); faces.append(p3)


func _build_roads_mesh(indices: Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()

	for idx: int in indices:
		var rdata: Dictionary = _roads[idx]
		var pts: PackedVector2Array = rdata["points"]
		if pts.size() < 2:
			continue
		var width: float = maxf(float(rdata["width"]), 1.2)
		var half := width * 0.5

		var accumulated := 0.0
		for i in range(pts.size() - 1):
			var a := pts[i]
			var b2 := pts[i + 1]
			var dir := (b2 - a)
			if dir.length() < 0.05:
				continue
			dir = dir.normalized()
			var side := Vector2(-dir.y, dir.x) * half

			var a0 := Vector2(a.x + side.x, a.y + side.y)
			var a1 := Vector2(a.x - side.x, a.y - side.y)
			var b0 := Vector2(b2.x + side.x, b2.y + side.y)
			var b1 := Vector2(b2.x - side.x, b2.y - side.y)

			var ya0 := _terrain.get_height_at(a0.x, a0.y) + 0.25
			var ya1 := _terrain.get_height_at(a1.x, a1.y) + 0.25
			var yb0 := _terrain.get_height_at(b0.x, b0.y) + 0.25
			var yb1 := _terrain.get_height_at(b1.x, b1.y) + 0.25

			var v00 := Vector3(a0.x, ya0, a0.y)
			var v01 := Vector3(a1.x, ya1, a1.y)
			var v10 := Vector3(b0.x, yb0, b0.y)
			var v11 := Vector3(b1.x, yb1, b1.y)

			var seg_len := a.distance_to(b2)
			var uv0 := accumulated / 8.0
			var uv1 := (accumulated + seg_len) / 8.0

			verts.append(v00); verts.append(v01); verts.append(v11)
			verts.append(v00); verts.append(v11); verts.append(v10)
			for _i in range(6):
				normals.append(Vector3.UP)
			uvs.append(Vector2(0, uv0))
			uvs.append(Vector2(1, uv0))
			uvs.append(Vector2(1, uv1))
			uvs.append(Vector2(0, uv0))
			uvs.append(Vector2(1, uv1))
			uvs.append(Vector2(0, uv1))
			accumulated += seg_len

	if verts.is_empty():
		return null

	var indices_arr := PackedInt32Array()
	for i in range(verts.size()):
		indices_arr.append(i)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices_arr

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Pick a spawn point on a walkable OSM way near the region centre. Buildings
## (PLATEAU or OSM fallback) do not occupy road centrelines, so this guarantees
## the player does not start inside collision geometry.
func find_road_spawn(prefer_codes: Array = [8, 7, 10, 5, 9]) -> Vector3:
	var best := Vector3.ZERO
	var best_dist := INF
	var found := false
	for pass_code: int in prefer_codes:
		for r in _roads:
			if int(r["code"]) != pass_code:
				continue
			var pts: PackedVector2Array = r["points"]
			if pts.size() < 2:
				continue
			var p: Vector2 = pts[pts.size() / 2]
			var d := p.length()
			if d < best_dist:
				best_dist = d
				best = Vector3(p.x, 0.0, p.y)
				found = true
		if found:
			break
	if not found:
		return Vector3.ZERO
	best.y = _terrain.get_height_at(best.x, best.z) + 1.6
	return best


func get_stats() -> Dictionary:
	return _stats.duplicate()


func get_loaded_chunk_count() -> int:
	return _loaded.size()
