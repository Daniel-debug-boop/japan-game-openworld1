extends SceneTree
## Static + data validation, safe to run with `--script` (no autoloads needed).
##
## Run with:  godot --headless --path . --script tests/validate_project.gd
##
## Compile/runtime verification is covered by tests/smoke_test.gd, which runs as a
## real scene so project autoloads are registered.

var _failures: Array[String] = []
var _warnings: Array[String] = []
var _passes: int = 0


func _init() -> void:
	print("=== Japan Open World validation ===")
	_check_project_config()
	_check_scene_files()
	_check_script_files()
	_check_data_files()
	_check_plateau()
	_check_assets()
	_check_facade_materials()
	_check_autoloads()
	_report()
	quit(1 if not _failures.is_empty() else 0)


func _pass(msg: String) -> void:
	_passes += 1
	print("  PASS  ", msg)


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("  FAIL  ", msg)


func _warn(msg: String) -> void:
	_warnings.append(msg)
	print("  WARN  ", msg)


func _check_project_config() -> void:
	print("\n[project configuration]")
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene.is_empty():
		_fail("application/run/main_scene is not set")
	elif not FileAccess.file_exists(main_scene):
		_fail("main scene does not exist: " + main_scene)
	else:
		_pass("main scene exists: " + main_scene)

	var project_name := String(ProjectSettings.get_setting("application/config/name", ""))
	if project_name == "Japan Open World":
		_pass("project name is 'Japan Open World'")
	else:
		_fail("unexpected project name: " + project_name)

	var renderer := String(ProjectSettings.get_setting("rendering/renderer/rendering_method", ""))
	if renderer == "forward_plus":
		_pass("renderer is forward_plus")
	else:
		_warn("renderer is '%s' (expected forward_plus)" % renderer)

	var required_inputs := ["move_forward", "move_back", "move_left", "move_right",
		"jump", "sprint", "interact", "pause", "toggle_camera"]
	for action in required_inputs:
		if InputMap.has_action(action):
			_pass("input action registered: " + action)
		else:
			_fail("missing input action: " + action)


func _check_scene_files() -> void:
	print("\n[scene files]")
	var scenes: Array[String] = []
	_collect_files("res://scenes", ".tscn", scenes)
	if scenes.is_empty():
		_fail("no scenes found")
		return
	for path in scenes:
		if FileAccess.file_exists(path):
			_pass("scene file present: " + path)
		else:
			_fail("missing scene: " + path)

	var packed := load("res://scenes/main_world.tscn")
	if packed is PackedScene:
		_pass("main_world.tscn parses as PackedScene")
	else:
		_fail("main_world.tscn failed to parse")


func _check_script_files() -> void:
	print("\n[script files]")
	var scripts: Array[String] = []
	_collect_files("res://scripts", ".gd", scripts)
	_collect_files("res://tests", ".gd", scripts)
	if scripts.is_empty():
		_fail("no scripts found")
		return
	for path in scripts:
		var src := FileAccess.get_file_as_string(path)
		if src.is_empty():
			_fail("empty script: " + path)
			continue
		if not src.begins_with("extends") and not src.contains("\nextends "):
			_fail("script has no extends clause: " + path)
			continue
		_pass("script present and non-empty: " + path)

	# Real parser check: invoke the engine in --check-only mode per script.
	# Autoload identifiers legitimately fail to resolve in this mode, so only
	# genuine "Parse Error" lines are treated as failures.
	var engine := OS.get_executable_path()
	for path in scripts:
		var out: Array = []
		OS.execute(engine, ["--headless", "--path", ".", "--check-only", "--script", path], out, true)
		var text := "\n".join(out)
		if text.contains("Parse Error"):
			var first_line := ""
			for line in text.split("\n"):
				if line.contains("Parse Error"):
					first_line = line.strip_edges()
					break
			_fail("parse error in %s: %s" % [path, first_line])
		else:
			_pass("parses cleanly: " + path)


func _check_data_files() -> void:
	print("\n[world data]")
	var required := [
		"res://assets/terrain/heightmap.json",
		"res://assets/terrain/heightmap.f32",
		"res://assets/world/roads.dat",
		"res://assets/world/buildings.dat",
		"res://assets/world/manifest.json",
	]
	for path in required:
		if FileAccess.file_exists(path):
			var size := FileAccess.get_file_as_bytes(path).size()
			if size > 0:
				_pass("%s (%d bytes)" % [path, size])
			else:
				_fail("empty data file: " + path)
		else:
			_fail("missing data file: " + path)

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/terrain/heightmap.json"))
	if typeof(parsed) == TYPE_DICTIONARY:
		var meta: Dictionary = parsed
		if meta.has("bbox") and meta.has("elevation_min_m") and meta.has("elevation_max_m"):
			_pass("heightmap.json contains bbox and elevation range")
			if float(meta["elevation_max_m"]) > float(meta["elevation_min_m"]):
				_pass("elevation range is valid (%.1f .. %.1f m)" % [
					float(meta["elevation_min_m"]), float(meta["elevation_max_m"])])
			else:
				_fail("elevation range is degenerate")
		else:
			_fail("heightmap.json missing required keys")
	else:
		_fail("heightmap.json is not valid JSON")

	if FileAccess.file_exists("res://assets/terrain/heightmap.f32"):
		var bytes := FileAccess.get_file_as_bytes("res://assets/terrain/heightmap.f32")
		var w := bytes.decode_u32(0)
		var h := bytes.decode_u32(4)
		var expected := w * h * 4 + 8
		if bytes.size() == expected and w > 0 and h > 0:
			_pass("heightmap grid %dx%d matches file size" % [w, h])
		else:
			_fail("heightmap.f32 size mismatch (expected %d, got %d)" % [expected, bytes.size()])

	if FileAccess.file_exists("res://assets/world/roads.dat"):
		var b := FileAccess.get_file_as_bytes("res://assets/world/roads.dat")
		if b.size() >= 8 and b.slice(0, 4).get_string_from_ascii() == "RD01":
			_pass("roads.dat magic valid (%d ways)" % b.decode_u32(4))
		else:
			_fail("roads.dat magic invalid")
	if FileAccess.file_exists("res://assets/world/buildings.dat"):
		var b := FileAccess.get_file_as_bytes("res://assets/world/buildings.dat")
		if b.size() >= 8 and b.slice(0, 4).get_string_from_ascii() == "BD01":
			_pass("buildings.dat magic valid (%d footprints)" % b.decode_u32(4))
		else:
			_fail("buildings.dat magic invalid")


func _check_plateau() -> void:
	print("\n[PLATEAU 3D city models]")
	var index_path := "res://assets/plateau/index.json"
	var manifest_path := "res://assets/plateau/manifest.json"

	if not FileAccess.file_exists(index_path):
		_warn("PLATEAU index missing (run tools/fetch_plateau.py); OSM fallback will be used")
		return

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(index_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("plateau/index.json is not valid JSON")
		return
	var idx: Dictionary = parsed
	var tiles: Array = idx.get("tiles", [])
	if tiles.is_empty():
		_fail("plateau/index.json has no tiles")
		return
	_pass("PLATEAU index lists %d tiles" % tiles.size())

	var offset := float(idx.get("vertical_offset_m", 0.0))
	if absf(offset) < 200.0:
		_pass("PLATEAU vertical offset is plausible (%.2f m)" % offset)
	else:
		_fail("PLATEAU vertical offset looks wrong (%.2f m)" % offset)

	if FileAccess.file_exists(manifest_path):
		var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if typeof(m) == TYPE_DICTIONARY:
			var src := String((m as Dictionary).get("source", ""))
			if src.contains("PLATEAU"):
				_pass("PLATEAU manifest records the official source")
			else:
				_fail("PLATEAU manifest does not name the source")
		else:
			_fail("plateau/manifest.json is not valid JSON")
	else:
		_warn("plateau/manifest.json missing")

	# Meshes are generated, not committed. Verify the format when present.
	var present := 0
	var checked := 0
	var bad := 0
	for t: Dictionary in tiles:
		var rel := String(t.get("file", ""))
		if rel.is_empty() or checked >= 5:
			continue
		var path := "res://assets/plateau/" + rel
		if not FileAccess.file_exists(path):
			continue
		present += 1
		checked += 1
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "PMSH":
			bad += 1
			continue
		var vcount := bytes.decode_u32(8)
		var icount := bytes.decode_u32(12)
		if bytes.size() != 44 + vcount * 24 + icount * 4:
			bad += 1

	if present == 0:
		_warn("PLATEAU meshes not generated yet (gitignored; run tools/fetch_plateau.py)")
	elif bad == 0:
		_pass("sampled %d PLATEAU .pmesh files are structurally valid" % present)
	else:
		_fail("%d sampled PLATEAU .pmesh files are malformed" % bad)


func _check_assets() -> void:
	print("\n[assets]")
	var textures := [
		"res://assets/textures/aerial_grass_rock/aerial_grass_rock_albedo.jpg",
		"res://assets/textures/aerial_grass_rock/aerial_grass_rock_normal.jpg",
		"res://assets/textures/aerial_asphalt_01/aerial_asphalt_01_albedo.jpg",
		"res://assets/textures/painted_concrete/painted_concrete_albedo.jpg",
		"res://assets/hdri/kloofendal_48d_partly_cloudy_puresky_2k.hdr",
	]
	for path in textures:
		if FileAccess.file_exists(path):
			_pass("asset present: " + path)
		else:
			_fail("missing asset: " + path)


## The facade albedo is a green-painted concrete texture, so both building renderers
## correct it with a per-channel tint (FACADE_TINT). If that correction is dropped the
## whole city turns mint-green — which is exactly how the failed visual acceptance run
## looked. Measure the effective albedo here so it cannot regress silently.
func _check_facade_materials() -> void:
	print("\n[facade materials]")
	var albedo_path := "res://assets/textures/painted_concrete/painted_concrete_albedo.jpg"
	if not FileAccess.file_exists(albedo_path):
		_fail("facade albedo missing: " + albedo_path)
		return

	var tex := load(albedo_path) as Texture2D
	if tex == null:
		_fail("facade albedo did not load (was the project imported?): " + albedo_path)
		return

	# Mean colour of the texture, sampled on a grid so the check stays cheap.
	var img := tex.get_image()
	if img == null:
		_fail("facade albedo has no image data: " + albedo_path)
		return
	var step := maxi(1, img.get_width() / 64)
	var samples := 0
	var mean := Vector3.ZERO
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			mean += Vector3(c.r, c.g, c.b)
			samples += 1
	mean /= maxf(1.0, float(samples))
	print("  info  facade albedo mean RGB = (%.3f, %.3f, %.3f)" % [mean.x, mean.y, mean.z])

	for script_path in ["res://scripts/world/osm_city.gd", "res://scripts/world/plateau_city.gd"]:
		var tint := _read_facade_tint(script_path)
		if tint == Vector3.ZERO:
			_fail("could not read FACADE_TINT from " + script_path)
			continue
		var effective := Vector3(mean.x * tint.x, mean.y * tint.y, mean.z * tint.z)
		var dominance := effective.y - (effective.x + effective.z) * 0.5
		if absf(dominance) > 0.03:
			_fail("%s renders facades with a colour cast (effective RGB %.3f, %.3f, %.3f)" % [
				script_path, effective.x, effective.y, effective.z])
		elif effective.length() < 0.15 or effective.length() > 1.6:
			_fail("%s facade albedo is out of range (%.3f, %.3f, %.3f)" % [
				script_path, effective.x, effective.y, effective.z])
		else:
			_pass("%s facade albedo is neutral concrete (%.3f, %.3f, %.3f)" % [
				script_path, effective.x, effective.y, effective.z])


func _read_facade_tint(script_path: String) -> Vector3:
	if not FileAccess.file_exists(script_path):
		return Vector3.ZERO
	var regex := RegEx.new()
	if regex.compile(r"FACADE_TINT\s*:=\s*Color\s*\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)") != OK:
		return Vector3.ZERO
	var m := regex.search(FileAccess.get_file_as_string(script_path))
	if m == null:
		return Vector3.ZERO
	return Vector3(m.get_string(1).to_float(), m.get_string(2).to_float(), m.get_string(3).to_float())


func _check_autoloads() -> void:
	print("\n[autoloads]")
	for nm in ["GameManager", "SettingsManager"]:
		if ProjectSettings.has_setting("autoload/" + nm):
			var value := String(ProjectSettings.get_setting("autoload/" + nm)).trim_prefix("*")
			if FileAccess.file_exists(value):
				_pass("autoload %s -> %s" % [nm, value])
			else:
				_fail("autoload %s points at missing script %s" % [nm, value])
		else:
			_fail("autoload not registered: " + nm)


func _collect_files(root: String, ext: String, out: Array[String]) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := root.path_join(entry)
		if dir.current_is_dir():
			_collect_files(full, ext, out)
		elif entry.ends_with(ext):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _report() -> void:
	print("\n=== summary ===")
	print("passed: %d   warnings: %d   failures: %d" % [_passes, _warnings.size(), _failures.size()])
	if not _warnings.is_empty():
		print("\nwarnings:")
		for w in _warnings:
			print("  - ", w)
	if not _failures.is_empty():
		print("\nfailures:")
		for f in _failures:
			print("  - ", f)
		print("\nRESULT: FAIL")
	else:
		print("\nRESULT: PASS")
