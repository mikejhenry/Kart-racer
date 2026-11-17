extends Node
## Autoload. State shared between the menu and races: the chosen mode, the
## player's name, personal bests, the time trial ghost and the online roster.

const TRACK_ID := "circuit_1"
const TRACK_NAME := "Circuit 1"
const TOTAL_LAPS := 3
const SETTINGS_PATH := "user://settings.cfg"
const GHOST_PATH := "user://ghost_circuit_1.json"

var mode := "grand_prix"   ## "grand_prix", "time_trial" or "online"
var player_name := ""
var best_time := 0.0       ## Personal best time trial (0 = none yet)
var best_lap := 0.0
var online_players: Array = []

# Tilt steering (phones and tablets)
var tilt_enabled := false
var tilt_range := 30.0     ## Degrees of tilt for full steering lock
var tilt_invert := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_settings()
	Net.race_started.connect(_on_race_started)
	if tilt_enabled:
		GameInput.set_tilt_wanted(true)


func set_tilt_enabled(on: bool) -> void:
	tilt_enabled = on
	GameInput.set_tilt_wanted(on)
	_save_settings()


func set_tilt_range(degrees: float) -> void:
	tilt_range = degrees
	_save_settings()


func set_tilt_invert(on: bool) -> void:
	tilt_invert = on
	_save_settings()


func display_name() -> String:
	return player_name if player_name != "" else "Racer"


func set_player_name(text: String) -> void:
	player_name = text.strip_edges().left(16)
	_save_settings()


func start_race(new_mode: String) -> void:
	mode = new_mode
	get_tree().paused = false
	get_tree().change_scene_to_file("res://race.tscn")


func go_to_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://menu.tscn")


## Saves personal bests. Returns true if this was a new best total time.
func record_time_trial(time: float, lap_times: Array) -> bool:
	var improved := best_time <= 0.0 or time < best_time
	if improved:
		best_time = time
	for lap in lap_times:
		if best_lap <= 0.0 or lap < best_lap:
			best_lap = lap
	_save_settings()
	return improved


func save_ghost(time: float, frames: Array) -> void:
	var file := FileAccess.open(GHOST_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"time": time, "frames": frames}))


func load_ghost() -> Dictionary:
	if not FileAccess.file_exists(GHOST_PATH):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(GHOST_PATH))
	return parsed if parsed is Dictionary else {}


func _on_race_started(players: Array) -> void:
	online_players = players
	start_race("online")


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	player_name = str(cfg.get_value("player", "name", ""))
	best_time = float(cfg.get_value("records", "best_time", 0.0))
	best_lap = float(cfg.get_value("records", "best_lap", 0.0))
	tilt_enabled = bool(cfg.get_value("controls", "tilt_enabled", false))
	tilt_range = float(cfg.get_value("controls", "tilt_range", 30.0))
	tilt_invert = bool(cfg.get_value("controls", "tilt_invert", false))
	if player_name == "":
		player_name = "Racer%d" % randi_range(100, 999)
		_save_settings()


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.set_value("records", "best_time", best_time)
	cfg.set_value("records", "best_lap", best_lap)
	cfg.set_value("controls", "tilt_enabled", tilt_enabled)
	cfg.set_value("controls", "tilt_range", tilt_range)
	cfg.set_value("controls", "tilt_invert", tilt_invert)
	cfg.save(SETTINGS_PATH)
