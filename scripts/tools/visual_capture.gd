extends Node
class_name VisualCapture
## In-game visual acceptance capture.
##
## This script lives under `scripts/`, which the Linux export preset keeps, so the
## *packaged* game can prove its own visuals rather than only the editor project
## (`tests/*` is excluded from the export). Trigger it with:
##
##     ./japan_open_world.x86_64 -- --visual-capture=/abs/out/dir
##     ./japan_open_world.x86_64 -- --visual-capture=user://shots --capture-video=120
##
## Why this exists — the defects that made the old harness produce a meaningless
## image:
##
##  1. **Camera roll on steep views.** The old harness aimed the camera with
##     `look_at(target, Vector3.UP)`. When the view direction is nearly parallel to
##     the up vector — a camera high above the basin looking down into it — the
##     resulting roll is ill-conditioned and the camera can end up inverted, which
##     is what produced the original frame with ground above the sky. `_up_for()`
##     now picks a stable up axis for near-vertical views, and every shot records
##     `camera_up_dot_world_up` so the orientation is measured, not assumed.
##     Readback orientation is also measured rather than assumed: the driver draws
##     probe bands and records whether it had to correct them (`orientation_corrected`).
##     On the verified engine/renderer combination that value is always false, i.e.
##     the readback is upright and no correction is applied.
##
##  2. **Vantage points outside the streamed world.** The old harness teleported the
##     player to one place and then parked the camera hundreds of metres away, well
##     outside the terrain/city streaming radius, so the frame contained almost no
##     world. Every framed shot here stays inside the player's own stream radius.
##
##  3. **Fixed frame counts.** Each shot waited 3 frames regardless of whether the
##     terrain chunks, OSM meshes or PLATEAU tiles had finished loading. This driver
##     polls the real streaming counters with a wall-clock deadline and records what
##     was resident at the moment of capture.
##
## It writes `capture_report.json` (renderer identity, resident geometry, per-image
## statistics) and reports failure when a shot is blank, when two shots are
## identical, or when the world did not stream.

const BAND := 8  # px height of each orientation probe band

var _out_dir := ""
var _shots: Array[Dictionary] = []
var _failures: Array[String] = []
var _warnings: Array[String] = []

var _world: Node
var _player: Node3D
var _spawn := Vector3.ZERO
var _last_flipped := false
var _sequence_frames := 0
var _sequence_flips := 0
var _terrain: Node
var _city: Node
var _plateau: Node
var _probe: CanvasLayer


# ---------------------------------------------------------------------------
# Command-line entry point
# ---------------------------------------------------------------------------

## True when `--visual-capture[=dir]` was passed after `--` on the command line.
static func is_requested() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--visual-capture"):
			return true
	return false


static func requested_dir(fallback: String = "user://screenshots") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--visual-capture="):
			return a.substr("--visual-capture=".length())
	return fallback


## Optional number of successive gameplay frames to dump for video encoding.
static func requested_video_frames() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture-video="):
			return int(a.substr("--capture-video=".length()))
	return 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# ---------------------------------------------------------------------------
# Main entry
# ---------------------------------------------------------------------------

func run(world: Node, out_dir: String, video_frames: int = 0) -> void:
	_world = world
	_out_dir = out_dir
	DirAccess.make_dir_recursive_absolute(globalize(out_dir))

	print("=== Japan Open World visual capture ===")
	var renderer := _renderer_info()
	for k: String in renderer:
		print("  renderer.%s = %s" % [k, str(renderer[k])])

	_terrain = world.get_node_or_null("Terrain")
	_city = world.get_node_or_null("City")
	_plateau = world.get_node_or_null("Plateau")
	_player = world.get_node_or_null("Player") as Node3D

	if _player == null:
		_fail("main world has no Player node; nothing to capture")
		return
	if _terrain == null:
		_fail("main world has no Terrain node; nothing to capture")
		return

	_install_orientation_probe()

	# The player camera is the shipping view; let the world stream before shooting.
	await _settle(120.0, 4, 1)

	# 1. The actual gameplay view — no camera override at all.
	await _capture("01_player_view")

	# Later shots place the camera by hand, so stop SpringArm3D from pulling it back.
	_freeze_camera()

	var spawn: Vector3 = _player.global_position
	_spawn = spawn
	var hill := spawn
	if _terrain.has_method("find_viewpoint"):
		hill = _terrain.call("find_viewpoint")

	var plateau_centre := Vector3.ZERO
	if _plateau != null and _plateau.has_method("get_nearest_tile_center"):
		plateau_centre = _plateau.call("get_nearest_tile_center", spawn)

	# 2. Street level at human eye height, looking along the road the player is on.
	await _framed("02_street_level", spawn, spawn + Vector3(0.0, 1.7, 0.0),
			spawn + Vector3(90.0, 2.0, 70.0), 70.0)

	# 3. Rooftop overview of the real city blocks.
	await _framed("03_city_overview", spawn, spawn + Vector3(-130.0, 95.0, -130.0),
			spawn + Vector3(40.0, 6.0, 40.0), 62.0)

	# 4. PLATEAU (MLIT 3D city model) buildings seen from street level.
	if plateau_centre != Vector3.ZERO:
		await _framed("04_plateau_buildings", plateau_centre,
				plateau_centre + Vector3(55.0, 24.0, 55.0),
				plateau_centre + Vector3(0.0, 12.0, 0.0), 58.0)
	else:
		_warn("no PLATEAU tile centre available; skipping the PLATEAU close-up")

	# 5. Higashiyama hills: the real elevation change across the Kyoto basin. The camera
	# sits a little above the ridge looking across the basin rather than straight down,
	# so both the hillside and the city are in frame.
	await _framed("05_hills_vista", hill, hill + Vector3(-150.0, 55.0, -150.0),
			hill + Vector3(120.0, -35.0, 120.0), 66.0)

	if video_frames > 0:
		await _capture_sequence(video_frames)

	_remove_orientation_probe()
	_write_report(renderer)

	print("=== visual capture %s (%d shots) ===" %
			["FAILED" if not _failures.is_empty() else "PASS", _shots.size()])
	for s: Dictionary in _shots:
		print("  %s  %dx%d  mean=%.1f sd=%.1f  terrain=%d city=%d plateau=%d" % [
			s["name"], s["width"], s["height"], s["mean"], s["stddev"],
			s["terrain_chunks"], s["city_chunks"], s["plateau_tiles"]])
	for w: String in _warnings:
		print("  WARN %s" % w)
	for f: String in _failures:
		printerr("  FAIL %s" % f)
	print("[capture] RESULT: %s" % ("PASS" if _failures.is_empty() else "FAIL"))


func exit_code() -> int:
	return 0 if _failures.is_empty() else 1


# ---------------------------------------------------------------------------
# Renderer / environment reporting
# ---------------------------------------------------------------------------

func _renderer_info() -> Dictionary:
	var device := RenderingServer.get_rendering_device()
	return {
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"video_api_version": RenderingServer.get_video_adapter_api_version(),
		"project_method": String(ProjectSettings.get_setting(
				"rendering/renderer/rendering_method", "unknown")),
		"active_backend": "vulkan" if device != null else "opengl",
		"display_driver": DisplayServer.get_name(),
		"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"user_args": OS.get_cmdline_user_args(),
	}


# ---------------------------------------------------------------------------
# Orientation probe
# ---------------------------------------------------------------------------
#
# A pure red band pinned to the top of the screen and a pure blue band pinned to the
# bottom. Whatever the renderer does to the readback, exactly one of them lands on
# row 0, and which one tells us whether to flip. This is a measurement rather than an
# assumption about engine behaviour, so it stays correct across renderers.

func _install_orientation_probe() -> void:
	_probe = CanvasLayer.new()
	_probe.name = "CaptureOrientationProbe"
	_probe.layer = 128
	_world.add_child(_probe)

	var vp_size := _world.get_viewport().get_visible_rect().size
	var top := ColorRect.new()
	top.color = Color(1, 0, 0, 1)
	top.size = Vector2(vp_size.x, BAND)
	top.position = Vector2.ZERO
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_probe.add_child(top)

	var bottom := ColorRect.new()
	bottom.color = Color(0, 0, 1, 1)
	bottom.size = Vector2(vp_size.x, BAND)
	bottom.position = Vector2(0, vp_size.y - BAND)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_probe.add_child(bottom)


func _remove_orientation_probe() -> void:
	if _probe != null and is_instance_valid(_probe):
		_probe.queue_free()
		_probe = null


## Returns an upright copy of `img` with the probe bands cropped away.
##
## The readback's Y orientation is not guaranteed by the engine across renderers, and
## guessing it wrong is silent, so the probe bands measure it: red is pinned to the
## top of the screen and blue to the bottom, and whichever one lands on row 0 decides.
## The decision is recorded per shot as `orientation_corrected`.
func _orientation_correct(raw: Image) -> Image:
	var img := raw.duplicate() as Image
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBA8)

	var w := img.get_width()
	var h := img.get_height()
	if h < BAND * 2 + 4:
		return img

	var top_red := 0.0
	var top_blue := 0.0
	var bot_red := 0.0
	var bot_blue := 0.0
	var step := maxi(1, w / 64)
	for x in range(0, w, step):
		var t := img.get_pixel(x, BAND / 2)
		top_red += t.r
		top_blue += t.b
		var b := img.get_pixel(x, h - 1 - BAND / 2)
		bot_red += b.r
		bot_blue += b.b

	var flipped := (top_blue > top_red) and (bot_red > bot_blue)
	if flipped:
		img.flip_y()
	_last_flipped = flipped

	return img.get_region(Rect2i(0, BAND, w, h - BAND * 2))


# ---------------------------------------------------------------------------
# Streaming-aware settling
# ---------------------------------------------------------------------------

func _count(node: Node, method: String) -> int:
	if node != null and node.has_method(method):
		return int(node.call(method))
	return 0


## Polls until enough geometry is resident to photograph, or `max_seconds` elapses.
## Returns whether the threshold was reached.
func _settle(max_seconds: float, want_terrain: int, want_plateau: int) -> bool:
	var deadline := Time.get_ticks_msec() + int(max_seconds * 1000.0)
	var terrain := 0
	var city := 0
	var plateau := 0
	while Time.get_ticks_msec() < deadline:
		terrain = _count(_terrain, "get_loaded_chunk_count")
		city = _count(_city, "get_loaded_chunk_count")
		plateau = _count(_plateau, "get_loaded_tile_count")
		var plateau_ok := plateau >= want_plateau \
				or _count(_plateau, "get_available_tile_count") <= 0
		if terrain >= want_terrain and city >= 1 and plateau_ok:
			return true
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	_warn("streaming did not settle within %.0fs (terrain=%d city=%d plateau=%d)" %
			[max_seconds, terrain, city, plateau])
	return false


## Counts MeshInstance3D nodes anywhere under `root` whose own name starts with
## `wanted_prefix` (the OSM renderer names its meshes "Buildings" and "Roads").
func _mesh_instance_count(root: Node, wanted_prefix: String) -> int:
	if root == null:
		return 0
	var total := 0
	for child in root.find_children("*", "MeshInstance3D", true, false):
		if String(child.name).begins_with(wanted_prefix):
			total += 1
	return total


## Counts direct children of `root` whose node name starts with `wanted_prefix` and
## which actually carry a mesh. The PLATEAU loader names its tile nodes "PTile_0001"
## and their MeshInstance3D child "Mesh", so counting mesh instances would always
## report zero and quietly misrepresent the evidence.
func _tile_node_count(root: Node, wanted_prefix: String) -> int:
	if root == null:
		return 0
	var total := 0
	for child in root.get_children():
		if not String(child.name).begins_with(wanted_prefix):
			continue
		for grandchild in child.get_children():
			if grandchild is MeshInstance3D and (grandchild as MeshInstance3D).mesh != null:
				total += 1
				break
	return total


# ---------------------------------------------------------------------------
# Camera control
# ---------------------------------------------------------------------------

func _freeze_camera() -> void:
	if _player == null:
		return
	var arm := _player.get_node_or_null("CameraPivot/SpringArm3D")
	if arm == null:
		return
	arm.process_mode = Node.PROCESS_MODE_DISABLED
	if arm is SpringArm3D:
		(arm as SpringArm3D).spring_length = 0.0


func _camera() -> Camera3D:
	var cam: Camera3D = null
	if _world != null:
		cam = _world.get_viewport().get_camera_3d()
	if cam == null:
		cam = get_viewport().get_camera_3d()
	return cam


func _place_camera(from: Vector3, at: Vector3, fov: float) -> void:
	var cam := _camera()
	if cam == null:
		_fail("no active Camera3D in the world viewport")
		return
	cam.global_position = from
	cam.fov = fov
	cam.look_at(at, _up_for(from, at))
	cam.current = true


## `look_at` is ill-conditioned when the view direction is nearly parallel to the up
## vector: the resulting roll becomes unstable and can flip the camera over, which is
## how an earlier revision produced frames with the ground above the sky. Pick a
## stable up axis for near-vertical views.
func _up_for(from: Vector3, at: Vector3) -> Vector3:
	var dir := (at - from)
	if dir.length() < 0.001:
		return Vector3.UP
	if absf(dir.normalized().dot(Vector3.UP)) > 0.94:
		return Vector3.FORWARD
	return Vector3.UP


func _framed(name: String, player_pos: Vector3, from: Vector3, at: Vector3, fov: float) -> void:
	# Keep the player under the camera so the terrain/OSM/PLATEAU streaming this shot
	# depends on is driven from a real position inside the frame.
	_player.global_position = player_pos
	await get_tree().process_frame
	_place_camera(from, at, fov)
	await _settle(120.0, 4, 1)
	await _capture(name)


# ---------------------------------------------------------------------------
# Capture and analysis
# ---------------------------------------------------------------------------

func _capture(name: String) -> void:
	# Two draws guarantee the frame we read back is the settled one.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var vp := _world.get_viewport() if _world != null else get_viewport()
	var tex := vp.get_texture()
	if tex == null:
		_fail("viewport texture is null for %s (a headless renderer cannot read back)" % name)
		return
	var raw: Image = tex.get_image()
	if raw == null or raw.is_empty():
		_fail("viewport readback is null for %s (a headless renderer cannot read back)" % name)
		return

	var img := _orientation_correct(raw)
	var stats := _image_stats(img)
	var cam := _camera()

	var shot := {
		"name": name,
		"file": "%s.png" % name,
		"width": img.get_width(),
		"height": img.get_height(),
		"mean": stats["mean"],
		"stddev": stats["stddev"],
		"distinct_colors": stats["distinct_colors"],
		"hash": _downscale_hash(img),
		"terrain_chunks": _count(_terrain, "get_loaded_chunk_count"),
		"city_chunks": _count(_city, "get_loaded_chunk_count"),
		"plateau_tiles": _count(_plateau, "get_loaded_tile_count"),
		"plateau_available": _count(_plateau, "get_available_tile_count") > 0,
		"road_meshes": _mesh_instance_count(_city, "Roads"),
		"building_meshes": _mesh_instance_count(_city, "Buildings"),
		"plateau_meshes": _tile_node_count(_plateau, "PTile"),
		"camera_position": [cam.global_position.x, cam.global_position.y, cam.global_position.z] if cam else [],
		"camera_fov": cam.fov if cam else 0.0,
		"orientation_corrected": _last_flipped,
		"camera_up_dot_world_up": cam.global_transform.basis.y.dot(Vector3.UP) if cam else 0.0,
		"camera_forward_pitch_deg": rad_to_deg(asin(clampf(
				-cam.global_transform.basis.z.y, -1.0, 1.0))) if cam else 0.0,
		"terrain_height_at_camera": _terrain_height_at(cam.global_position) if cam else 0.0,
	}

	var err := img.save_png(_path(shot["file"]))
	if err != OK:
		_fail("could not save %s (error %d)" % [shot["file"], err])
		return
	_shots.append(shot)
	_analyse(shot)


func _analyse(shot: Dictionary) -> void:
	if float(shot["stddev"]) < 1.0:
		_fail("%s is effectively blank (stddev %.3f)" % [shot["name"], shot["stddev"]])
	if int(shot["distinct_colors"]) < 8:
		_fail("%s has almost no colour variation (%d sampled colours)" %
				[shot["name"], shot["distinct_colors"]])
	for prev: Dictionary in _shots:
		if prev["name"] == shot["name"]:
			continue
		if prev["hash"] == shot["hash"]:
			_fail("%s is identical to %s (duplicate viewpoint)" % [shot["name"], prev["name"]])
	if int(shot["terrain_chunks"]) <= 0:
		_fail("%s was captured with no terrain chunks resident" % shot["name"])
	if int(shot["city_chunks"]) <= 0:
		_fail("%s was captured with no OSM city chunks resident" % shot["name"])
	if int(shot["road_meshes"]) <= 0:
		_fail("%s has no OSM road meshes in the scene" % shot["name"])
	if int(shot["building_meshes"]) <= 0 and not bool(shot["plateau_available"]):
		_fail("%s has neither OSM building meshes nor PLATEAU geometry" % shot["name"])


## Terrain elevation directly under a point, or NAN when the terrain does not expose it.
func _terrain_height_at(pos: Vector3) -> float:
	if _terrain != null and _terrain.has_method("get_height_at"):
		return float(_terrain.call("get_height_at", pos.x, pos.z))
	return NAN


func _image_stats(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, int(sqrt(float(w * h) / 4096.0)))
	var n := 0
	var sum := 0.0
	var sumsq := 0.0
	var colours: Dictionary = {}
	for y in range(0, h, step):
		for x in range(0, w, step):
			var c := img.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sum += l
			sumsq += l * l
			n += 1
			colours[Vector3i(int(c.r * 31.0), int(c.g * 31.0), int(c.b * 31.0))] = true
	var mean := sum / maxf(1.0, float(n))
	var variance := maxf(0.0, sumsq / maxf(1.0, float(n)) - mean * mean)
	return {
		"mean": mean * 255.0,
		"stddev": sqrt(variance) * 255.0,
		"distinct_colors": colours.size(),
	}


## Stable-within-a-run fingerprint of a 16x16 reduction of the frame. Used to detect
## two shots that recorded the same viewpoint.
func _downscale_hash(img: Image) -> String:
	var small := img.duplicate() as Image
	small.resize(16, 16, Image.INTERPOLATE_BILINEAR)
	return str(hash(small.get_data()))


func _path(file: String) -> String:
	if _out_dir.ends_with("/"):
		return _out_dir + file
	return _out_dir + "/" + file


func globalize(dir: String) -> String:
	if dir.begins_with("res://") or dir.begins_with("user://"):
		return ProjectSettings.globalize_path(dir)
	return dir


# ---------------------------------------------------------------------------
# Video frame sequence
# ---------------------------------------------------------------------------

## Writes successive PNGs while the player walks forward, so the caller can encode a
## gameplay video from them. Captured at the live player camera.
func _capture_sequence(frames: int) -> void:
	print("  capturing %d gameplay frames for video" % frames)

	# Recording must start from normal gameplay, not from wherever the last framed
	# shot parked the camera (which is metres above the rooftops looking down).
	# Put the player back on its spawn point, restore the follow camera and aim it
	# at the horizon before the walk begins.
	_player.global_position = _spawn

	# Drive the camera explicitly for every recorded frame instead of handing control
	# back to SpringArm3D. Re-attaching the arm leaves it to re-assert its own state,
	# and an earlier revision recorded the whole sequence from underneath the terrain
	# because the arm's stale state won over the reset transform. Explicit placement
	# uses the same guarded code path as the framed shots, so it is reproducible.
	var dir := globalize("%s/sequence" % _out_dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var forward := Vector3(0.0, 0.0, -1.0)
	var eye := Vector3(0.0, 1.55, 0.0)

	for i in range(frames):
		_player.global_position += forward * 0.35
		# A little behind and above the player, looking ahead down the street.
		var pos: Vector3 = _player.global_position
		_place_camera(pos + eye - forward * 4.0, pos + eye + forward * 40.0, 72.0)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img: Image = _world.get_viewport().get_texture().get_image()
		if img == null:
			_warn("video frame %d could not be read back" % i)
			break
		img = _orientation_correct(img)
		_sequence_frames += 1
		if _last_flipped:
			_sequence_flips += 1
		img.save_png("%s/frame_%04d.png" % [dir, i])


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

func _fail(msg: String) -> void:
	_failures.append(msg)
	printerr("[capture] FAIL: %s" % msg)


func _warn(msg: String) -> void:
	_warnings.append(msg)
	printerr("[capture] WARN: %s" % msg)


func _write_report(renderer: Dictionary) -> void:
	var report := {
		"generated_utc": Time.get_datetime_string_from_system(true),
		"renderer": renderer,
		"out_dir": _out_dir,
		"sequence": {"frames": _sequence_frames, "frames_flipped": _sequence_flips},
		"shots": _shots,
		"warnings": _warnings,
		"failures": _failures,
		"result": "PASS" if _failures.is_empty() else "FAIL",
	}
	var f := FileAccess.open(_path("capture_report.json"), FileAccess.WRITE)
	if f == null:
		printerr("[capture] could not write capture_report.json")
		return
	f.store_string(JSON.stringify(report, "\t"))
	f.close()
