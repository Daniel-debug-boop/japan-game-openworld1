extends Node3D
## Main playable world: real Kyoto terrain + OSM city + player + objectives.

const META_PATH := "res://assets/terrain/heightmap.json"
const PLAYER_SCENE := "res://scenes/player.tscn"
const HUD_SCRIPT := "res://scripts/ui/hud.gd"

## Real Kyoto landmarks used as objective locations (lat, lon).
const LANDMARKS: Array[Dictionary] = [
	{"name": "Kyoto Imperial Palace", "ja": "京都御所", "lat": 35.0254, "lon": 135.7621},
	{"name": "Nijo Castle", "ja": "二条城", "lat": 35.0142, "lon": 135.7482},
	{"name": "Nishiki Market", "ja": "錦市場", "lat": 35.0050, "lon": 135.7649},
	{"name": "Sanjo Ohashi Bridge", "ja": "三条大橋", "lat": 35.0090, "lon": 135.7715},
	{"name": "Kyoto City Hall", "ja": "京都市役所", "lat": 35.0116, "lon": 135.7681},
	{"name": "Yasaka Shrine", "ja": "八坂神社", "lat": 35.0037, "lon": 135.7786},
	{"name": "Chion-in Temple", "ja": "知恩院", "lat": 35.0053, "lon": 135.7832},
	{"name": "Heian Shrine", "ja": "平安神宮", "lat": 35.0160, "lon": 135.7824},
]

var _terrain: TerrainStreamer
var _city: OsmCity
var _plateau: PlateauCity
var _player: PlayerController
var _hud: GameHUD
var _lanterns: Array[LanternObjective] = []
var _meta_bbox: Dictionary = {}
var _current_target: Node = null
var _fps_accum := 0.0
var _fps_frames := 0
var _fps := 0.0
var _loaded := false
var _smoke_frames := 0


func _ready() -> void:
	_load_meta()
	_build_environment()

	_terrain = TerrainStreamer.new()
	_terrain.name = "Terrain"
	add_child(_terrain)

	if not _terrain.get_world_bounds().has_area():
		push_error("MainWorld: terrain has no bounds; aborting")
		return

	# Real PLATEAU government 3D city models take priority for buildings.
	_plateau = PlateauCity.new()
	_plateau.name = "Plateau"
	add_child(_plateau)
	_plateau.setup(_terrain)

	_city = OsmCity.new()
	_city.name = "City"
	add_child(_city)
	if _plateau.available:
		_city.set_coverage_check(_plateau.is_covered)
	_city.setup(_terrain)

	_spawn_player()
	_spawn_lanterns()
	_build_hud()

	GameManager.objective_progress.connect(_on_objective_progress)
	GameManager.objective_completed.connect(_on_objective_completed)
	GameManager.game_paused.connect(_on_paused)

	GameManager.on_world_ready(_lanterns.size())
	_loaded = true

	# Visual acceptance: run the capture driver against the real streaming world and
	# exit with its verdict. Works in the exported build because the driver lives
	# under scripts/ (the export preset excludes tests/).
	if GameManager.capture_mode:
		_run_visual_capture.call_deferred()


func _run_visual_capture() -> void:
	var capture := VisualCapture.new()
	capture.name = "VisualCapture"
	add_child(capture)
	await capture.run(self, GameManager.capture_out_dir, GameManager.capture_video_frames)
	get_tree().quit(capture.exit_code())


func _load_meta() -> void:
	if not FileAccess.file_exists(META_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(META_PATH))
	if typeof(parsed) == TYPE_DICTIONARY:
		_meta_bbox = (parsed as Dictionary).get("bbox", {})


func _build_environment() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()

	var hdri_path := "res://assets/hdri/kloofendal_48d_partly_cloudy_puresky_2k.hdr"
	if ResourceLoader.exists(hdri_path):
		var sky := Sky.new()
		var pano := PanoramaSkyMaterial.new()
		pano.panorama = load(hdri_path) as Texture2D
		sky.sky_material = pano
		sky.radiance_size = Sky.RADIANCE_SIZE_256
		env.sky = sky
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_energy = 0.65
	else:
		# Fallback: a physically-plausible procedural sky.
		var sky2 := Sky.new()
		var proc := ProceduralSkyMaterial.new()
		sky2.sky_material = proc
		env.sky = sky2
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY

	env.background_energy_multiplier = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.1
	env.ssao_enabled = true
	env.ssao_radius = 1.6
	env.ssao_intensity = 1.8
	env.ssao_power = 1.4
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.79, 0.88)
	env.fog_light_energy = 0.9
	env.fog_density = 0.0012
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.4
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 420.0
	sun.directional_shadow_blend_splits = true
	sun.rotation_degrees = Vector3(-48.0, 38.0, 0.0)
	add_child(sun)


func _spawn_player() -> void:
	_player = load(PLAYER_SCENE).instantiate() as PlayerController
	if _player == null:
		push_error("MainWorld: failed to instantiate player scene")
		return
	# Prefer a point on an OSM road: road centrelines are free of building
	# collision, so the player never starts inside a PLATEAU or OSM structure.
	var spawn := _city.find_road_spawn() if _city else Vector3.ZERO
	if spawn == Vector3.ZERO:
		spawn = _terrain.find_spawn_point(7)
		spawn.y = _terrain.get_height_at(spawn.x, spawn.z) + 1.6
	_player.position = spawn
	add_child(_player)
	GameManager.spawn_position = spawn

	var cam := _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if cam:
		cam.far = 6000.0
		cam.near = 0.1
		cam.fov = 72.0
		cam.current = true
	_terrain.set_player(_player)
	if _plateau and _plateau.available:
		_plateau.set_player(_player)


func _project(lat: float, lon: float) -> Vector2:
	var north := float(_meta_bbox.get("north", 35.03))
	var south := float(_meta_bbox.get("south", 34.994))
	var east := float(_meta_bbox.get("east", 135.791))
	var west := float(_meta_bbox.get("west", 135.747))
	var lat_c := (north + south) * 0.5
	var lon_c := (east + west) * 0.5
	var m_per_deg_lat := 110574.0
	var m_per_deg_lon := 111320.0 * cos(deg_to_rad(lat_c))
	return Vector2((lon - lon_c) * m_per_deg_lon, -(lat - lat_c) * m_per_deg_lat)


func _spawn_lanterns() -> void:
	for lm in LANDMARKS:
		var flat := _project(float(lm["lat"]), float(lm["lon"]))
		var bounds := _terrain.get_world_bounds()
		if not bounds.has_point(flat):
			push_warning("Landmark %s outside terrain bounds" % lm["name"])
			continue
		var y := _terrain.get_height_at(flat.x, flat.y)
		var lantern := LanternObjective.new()
		lantern.landmark_name = String(lm["name"])
		lantern.landmark_name_ja = String(lm["ja"])
		lantern.position = Vector3(flat.x, y + 1.0, flat.y)
		add_child(lantern)
		lantern.collected.connect(_on_lantern_collected)
		_lanterns.append(lantern)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	layer.set_script(load(HUD_SCRIPT))
	add_child(layer)
	_hud = layer as GameHUD
	_hud.resume_requested.connect(func() -> void: GameManager.toggle_pause())
	_hud.quit_requested.connect(_on_quit_to_menu)
	_hud.save_requested.connect(_on_save)
	_hud.set_objectives(0, _lanterns.size())


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		GameManager.toggle_pause()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _loaded:
		return
	_update_prompt()

	_fps_accum += delta
	_fps_frames += 1
	if _fps_accum >= 0.4:
		_fps = _fps_frames / _fps_accum
		_fps_accum = 0.0
		_fps_frames = 0

	if _hud and _player:
		_hud.set_stats(
			_fps,
			_player.get_current_speed(),
			SettingsManager.get_draw_distance(),
			_terrain.get_loaded_chunk_count()
		)

	if GameManager.smoke_mode:
		_smoke_frames += 1
		if _smoke_frames == 90:
			_run_packaged_smoke_check()


func _update_prompt() -> void:
	if not _player or not _hud:
		return
	var target := _player.get_interact_target()
	if target is LanternObjective:
		var lantern := target as LanternObjective
		_current_target = target
		_hud.show_prompt("[E]  Restore lantern — %s" % lantern.get_label())
	else:
		_current_target = null
		_hud.hide_prompt()


func _on_lantern_collected(landmark: String) -> void:
	print("[objective] restored: ", landmark)
	if _hud:
		_hud.show_banner("Lantern restored: %s" % landmark)
		var t := create_tween()
		t.tween_interval(2.4)
		t.tween_callback(_hud.hide_banner)


func _on_objective_progress(collected: int, total: int) -> void:
	if _hud:
		_hud.set_objectives(collected, total)


func _on_objective_completed(total: int) -> void:
	print("[objective] all %d lanterns restored" % total)
	if _hud:
		_hud.show_banner("All %d Kyoto lanterns restored!\nThank you for exploring." % total)


func _on_paused(paused: bool) -> void:
	if _hud:
		_hud.set_paused(paused)


func _on_save() -> void:
	if _player:
		var ok := GameManager.save_game(_player.global_position, _player.get_yaw())
		print("[save] ", "ok" if ok else "failed")


func _run_packaged_smoke_check() -> void:
	var chunks := _terrain.get_loaded_chunk_count() if _terrain else 0
	var city_chunks := _city.get_loaded_chunk_count() if _city else 0
	var lanterns := _lanterns.size()
	var p_tiles := _plateau.get_loaded_tile_count() if _plateau else 0
	var p_available := _plateau.available if _plateau else false
	# Missing PLATEAU data degrades gracefully rather than hard-failing, but a
	# build that ships the data must actually stream it.
	var ok := chunks > 0 and city_chunks > 0 and lanterns > 0 and _player != null \
		and (p_tiles > 0 or not p_available)
	print("[smoke] terrain_chunks=%d city_chunks=%d plateau_available=%s plateau_tiles=%d lanterns=%d player=%s" % [
		chunks, city_chunks, "yes" if p_available else "no", p_tiles, lanterns,
		"yes" if _player != null else "no"])
	print("[smoke] RESULT: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


func _on_quit_to_menu() -> void:
	if _player:
		GameManager.save_game(_player.global_position, _player.get_yaw())
	_terrain.clear_all()
	GameManager.return_to_menu()
