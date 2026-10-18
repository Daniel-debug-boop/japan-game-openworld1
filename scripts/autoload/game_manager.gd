extends Node
## Global game state, objective tracking, scene flow and save/load.

signal objective_progress(changed: int, total: int)
signal objective_completed(total: int)
signal game_started
signal game_paused(is_paused: bool)

const MENU_SCENE := "res://scenes/main_menu.tscn"
const WORLD_SCENE := "res://scenes/main_world.tscn"
const SAVE_PATH := "user://savegame.json"

enum State { MENU, LOADING, PLAYING, PAUSED, COMPLETE }

var state: State = State.MENU
var objectives_total: int = 0
var objectives_collected: int = 0
var play_time_seconds: float = 0.0

# Spawn point in world metres (centre of the Kyoto slice).
var spawn_position := Vector3(0.0, 60.0, 0.0)


var smoke_mode := false

## Visual acceptance capture requested with `-- --visual-capture[=dir]`.
var capture_mode := false
var capture_out_dir := "user://screenshots"
var capture_video_frames := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	# Packaged-build self check: `-- --smoke-test` boots straight into the world.
	if "--smoke-test" in args:
		smoke_mode = true
		print("[smoke] booting world directly")
		start_new_game.call_deferred()
	# Visual acceptance: boot the real world and let the capture driver drive it.
	# The driver lives in scripts/, so this works in the exported game too.
	elif is_capture_requested():
		capture_mode = true
		capture_out_dir = capture_requested_dir()
		capture_video_frames = capture_requested_video_frames()
		print("[capture] booting world directly, output -> %s" % capture_out_dir)
		start_new_game.call_deferred()


func is_capture_requested() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--visual-capture"):
			return true
	return false


func capture_requested_dir() -> String:
	const PREFIX := "--visual-capture="
	for a in OS.get_cmdline_user_args():
		if a.begins_with(PREFIX):
			return a.substr(PREFIX.length())
	return "user://screenshots"


func capture_requested_video_frames() -> int:
	const PREFIX := "--capture-video="
	for a in OS.get_cmdline_user_args():
		if a.begins_with(PREFIX):
			return int(a.substr(PREFIX.length()))
	return 0


func _process(delta: float) -> void:
	if state == State.PLAYING:
		play_time_seconds += delta


func start_new_game() -> void:
	objectives_total = 0
	objectives_collected = 0
	play_time_seconds = 0.0
	_change_scene(WORLD_SCENE, State.LOADING)


func return_to_menu() -> void:
	get_tree().paused = false
	_change_scene(MENU_SCENE, State.MENU)


func _change_scene(path: String, new_state: State) -> void:
	state = new_state
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("Failed to change scene to %s (error %d)" % [path, err])
		state = State.MENU


func on_world_ready(total: int) -> void:
	objectives_total = total
	objectives_collected = 0
	state = State.PLAYING
	get_tree().paused = false
	game_started.emit()
	objective_progress.emit(0, total)


func register_objective() -> void:
	objectives_collected += 1
	objective_progress.emit(objectives_collected, objectives_total)
	if objectives_collected >= objectives_total and objectives_total > 0:
		state = State.COMPLETE
		objective_completed.emit(objectives_total)


func toggle_pause() -> void:
	if state != State.PLAYING and state != State.PAUSED:
		return
	var paused := state == State.PLAYING
	state = State.PAUSED if paused else State.PLAYING
	get_tree().paused = paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED
	game_paused.emit(paused)


func save_game(player_position: Vector3, player_yaw: float) -> bool:
	var data := {
		"version": 1,
		"objectives_collected": objectives_collected,
		"objectives_total": objectives_total,
		"play_time_seconds": play_time_seconds,
		"player": {"x": player_position.x, "y": player_position.y, "z": player_position.z, "yaw": player_yaw},
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("Could not open save file for writing")
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func load_game() -> Dictionary:
	if not has_save():
		return {}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func format_play_time() -> String:
	var total := int(play_time_seconds)
	return "%02d:%02d" % [total / 60, total % 60]
