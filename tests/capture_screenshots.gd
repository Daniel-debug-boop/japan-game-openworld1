extends Node
## Editor-side entry point for visual capture.
##
## This is deliberately thin: it boots the same `main_world.tscn` the game ships and
## hands it to `scripts/tools/visual_capture.gd`, which is the single implementation
## of capture, orientation correction, streaming waits and verification. That shared
## driver is also what the *packaged* build runs (`-- --visual-capture=DIR`), so the
## screenshot you review is produced by exactly the same code as the shipped game.
##
## Run it with a real display:
##
##     bash tools/setup_software_display.sh
##     source .cache/xvfb/env.sh
##     godot --path . --rendering-driver opengl3 \
##         --resolution 1280x720 res://tests/capture_screenshots.tscn
##
## Optional override of the output directory: pass `-- --visual-capture=/abs/dir`.
## If that flag is present the autoloaded GameManager boots the world itself, so this
## script steps aside to avoid capturing twice.

const WORLD_SCENE := "res://scenes/main_world.tscn"
const VIRTUAL_CAPTURE := "res://scripts/tools/visual_capture.gd"

var _world: Node
var _driver: Node


func _ready() -> void:
	if GameManager.capture_mode:
		# GameManager is already routing the run through main_world + VisualCapture.
		return

	var out_dir := VisualCapture.requested_dir("user://screenshots")
	print("=== Japan Open World capture harness (editor) ===")
	print("  output dir: %s" % ProjectSettings.globalize_path(out_dir) if
			out_dir.begins_with("user://") or out_dir.begins_with("res://") else out_dir)

	_world = load(WORLD_SCENE).instantiate()
	get_tree().root.add_child(_world)

	# The world builds its streaming nodes in _ready; give it one frame so the
	# Terrain/City/Plateau/Player children exist before the driver looks for them.
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	_driver = (load(VIRTUAL_CAPTURE) as GDScript).new()
	_driver.name = "VisualCapture"
	add_child(_driver)
	await _driver.call("run", _world, out_dir, VisualCapture.requested_video_frames())
	get_tree().quit(int(_driver.call("exit_code")))
