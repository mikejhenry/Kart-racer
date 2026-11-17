extends Node
## Autoload. State shared between the menu and races: the chosen mode, track
## and difficulty, the player's name and kart, personal bests and ghosts per
## track, settings, and the online race roster.

const Tracks := preload("res://scripts/tracks.gd")

const TOTAL_LAPS := 3
const SETTINGS_PATH := "user://settings.cfg"
const DIFFICULTIES := ["easy", "normal", "hard"]
const DIFFICULTY_NAMES := {"easy": "Easy", "normal": "Normal", "hard": "Hard"}
## Speed of every kart (players too) in each class.
const CLASS_SPEED := {"easy": 0.85, "normal": 1.0, "hard": 1.12}
const KART_COLORS := [
	Color(0.9, 0.15, 0.2), Color(0.16, 0.42, 0.95), Color(0.2, 0.75, 0.3), Color(0.95, 0.75, 0.1),
	Color(0.6, 0.3, 0.9), Color(1.0, 0.5, 0.1), Color(0.2, 0.8, 0.85), Color(0.95, 0.45, 0.75),
	Color(0.15, 0.15, 0.18), Color(0.95, 0.95, 0.95),
]

var mode := "grand_prix"     ## "grand_prix", "time_trial" or "online"
var track_id := "circuit_1"
var difficulty := "normal"
var ghost_mode := "mine"     ## Time trial ghost: "mine", "record" or "off"
var player_name := ""
var kart_style := "classic"
var kart_color := 0          ## Index into KART_COLORS

# Settings
var music_volume := 0.6
var sfx_volume := 0.9
var vibration := true
var tilt_enabled := false
var tilt_range := 30.0       ## Degrees of tilt for full steering lock
var tilt_invert := false

# Online race, filled in from the server's start message
var online: Dictionary = {}

var _records := {}           ## track id -> {"time": float, "lap": float}
var _session := {}           ## Last lobby, for rejoining after a reload


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_settings()
	Net.race_started.connect(_on_race_started)
	if tilt_enabled:
		GameInput.set_tilt_wanted(true)


func display_name() -> String:
	return player_name if player_name != "" else "Racer"


func color() -> Color:
	return KART_COLORS[clampi(kart_color, 0, KART_COLORS.size() - 1)]


func class_speed(level: String = "") -> float:
	return CLASS_SPEED.get(level if level != "" else difficulty, 1.0)


func ai_level(level: String = "") -> int:
	return maxi(0, DIFFICULTIES.find(level if level != "" else difficulty))


func vibrate(ms: int) -> void:
	if vibration and GameInput.touch_ui:
		Input.vibrate_handheld(ms)


func start_race(new_mode: String) -> void:
	mode = new_mode
	get_tree().paused = false
	get_tree().change_scene_to_file("res://race.tscn")


func go_to_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://menu.tscn")


# --- Records and ghosts -----------------------------------------------------

func best_time(track: String) -> float:
	return float(_records.get(track, {}).get("time", 0.0))


func best_lap(track: String) -> float:
	return float(_records.get(track, {}).get("lap", 0.0))


## Saves personal bests. Returns true if this was a new best total time.
func record_time_trial(track: String, time: float, lap_times: Array) -> bool:
	var rec: Dictionary = _records.get(track, {"time": 0.0, "lap": 0.0})
	var improved: bool = rec.time <= 0.0 or time < rec.time
	if improved:
		rec.time = time
	for lap in lap_times:
		if rec.lap <= 0.0 or lap < rec.lap:
			rec.lap = lap
	_records[track] = rec
	_save_settings()
	return improved


func save_ghost(track: String, time: float, frames: Array) -> void:
	var file := FileAccess.open(_ghost_path(track), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"time": time, "frames": frames, "layout": Tracks.layout_hash(track)}))


func load_ghost(track: String) -> Dictionary:
	var path := _ghost_path(track)
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return {}
	# Ignore ghosts recorded on an older version of the track.
	if parsed.has("layout") and int(parsed.layout) != Tracks.layout_hash(track):
		return {}
	return parsed


func _ghost_path(track: String) -> String:
	return "user://ghost_%s.json" % track


# --- Lobby session (rejoin after a reload) ----------------------------------

func save_session(code: String, id: String, token: String) -> void:
	_session = {"code": code, "id": id, "token": token, "at": Time.get_unix_time_from_system()}
	_save_settings()


func clear_session() -> void:
	_session = {}
	_save_settings()


## The last lobby, if it was recent enough to still exist.
func recent_session() -> Dictionary:
	if _session.is_empty() or Time.get_unix_time_from_system() - float(_session.get("at", 0)) > 15 * 60:
		return {}
	return _session


# --- Settings ---------------------------------------------------------------

func set_player_name(text: String) -> void:
	player_name = text.strip_edges().left(16)
	_save_settings()


func set_value(key: String, value) -> void:
	set(key, value)
	if key == "tilt_enabled":
		GameInput.set_tilt_wanted(bool(value))
	if key in ["music_volume", "sfx_volume"]:
		Sfx.apply_volumes()
	_save_settings()


func _on_race_started(info: Dictionary) -> void:
	online = info
	start_race("online")


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	player_name = str(cfg.get_value("player", "name", ""))
	kart_style = str(cfg.get_value("player", "kart_style", "classic"))
	kart_color = int(cfg.get_value("player", "kart_color", 0))
	track_id = str(cfg.get_value("race", "track", "circuit_1"))
	difficulty = str(cfg.get_value("race", "difficulty", "normal"))
	ghost_mode = str(cfg.get_value("race", "ghost", "mine"))
	_records = cfg.get_value("records", "tracks", {})
	# Records from before there were several tracks
	var old_best := float(cfg.get_value("records", "best_time", 0.0))
	if old_best > 0.0 and not _records.has("circuit_1"):
		_records["circuit_1"] = {"time": old_best, "lap": float(cfg.get_value("records", "best_lap", 0.0))}
	music_volume = float(cfg.get_value("settings", "music_volume", 0.6))
	sfx_volume = float(cfg.get_value("settings", "sfx_volume", 0.9))
	vibration = bool(cfg.get_value("settings", "vibration", true))
	tilt_enabled = bool(cfg.get_value("controls", "tilt_enabled", false))
	tilt_range = float(cfg.get_value("controls", "tilt_range", 30.0))
	tilt_invert = bool(cfg.get_value("controls", "tilt_invert", false))
	_session = cfg.get_value("online", "session", {})
	if not Tracks.get_track(track_id).id == track_id:
		track_id = "circuit_1"
	if player_name == "":
		player_name = "Racer%d" % randi_range(100, 999)
		_save_settings()


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "kart_style", kart_style)
	cfg.set_value("player", "kart_color", kart_color)
	cfg.set_value("race", "track", track_id)
	cfg.set_value("race", "difficulty", difficulty)
	cfg.set_value("race", "ghost", ghost_mode)
	cfg.set_value("records", "tracks", _records)
	cfg.set_value("settings", "music_volume", music_volume)
	cfg.set_value("settings", "sfx_volume", sfx_volume)
	cfg.set_value("settings", "vibration", vibration)
	cfg.set_value("controls", "tilt_enabled", tilt_enabled)
	cfg.set_value("controls", "tilt_range", tilt_range)
	cfg.set_value("controls", "tilt_invert", tilt_invert)
	cfg.set_value("online", "session", _session)
	cfg.save(SETTINGS_PATH)
