extends Node3D
## One race, in any of the three modes (see Game.mode):
##   grand_prix  - you against 5 computer karts, with items
##   time_trial  - solo against the clock and your best-run ghost, no items
##   online      - against other players in a private lobby, with items

const Track := preload("res://scripts/track.gd")
const Kart := preload("res://scripts/kart.gd")
const PlayerBrain := preload("res://scripts/player_brain.gd")
const AiBrain := preload("res://scripts/ai_brain.gd")
const ChaseCamera := preload("res://scripts/chase_camera.gd")
const Hud := preload("res://scripts/hud.gd")
const TouchControls := preload("res://scripts/touch_controls.gd")
const World := preload("res://scripts/world.gd")

const PLAYER_COLOR := Color(0.9, 0.15, 0.2)
const KART_COLORS := [
	Color(0.95, 0.75, 0.1), Color(0.2, 0.75, 0.3), Color(0.6, 0.3, 0.9),
	Color(1.0, 0.5, 0.1), Color(0.2, 0.8, 0.85), Color(0.95, 0.45, 0.75),
]
## Base speed of each computer kart in a Grand Prix.
const AI_SKILL := [0.97, 0.95, 0.93, 0.91, 0.89]
const GHOST_RATE := 10.0   ## Ghost samples per second
const SEND_EVERY := 6      ## Physics frames between online updates (10/s)

var mode := "grand_prix"
var track
var karts: Array = []
var player
var camera
var hud
var state := "countdown"   ## countdown, racing, finished
var countdown := 3.5
var race_time := 0.0
var lap_times: Array = []
var finished_count := 0
var _lap_start := 0.0
var _last_count_shown := -1
var _best_lap := 1
var _paused := false

# Time trial
var ghost
var _ghost_frames: Array = []
var _recording: Array = []
var _rec_tick := 0

# Online
var remote := {}           ## player id -> kart
var _send_tick := 0
var _online_results: Array = []
var _offline := false


func _ready() -> void:
	mode = Game.mode
	World.add_environment(self)
	track = Track.new()
	track.items_enabled = mode != "time_trial"
	add_child(track)
	track.build()

	match mode:
		"time_trial":
			_spawn_time_trial()
		"online":
			_spawn_online()
		_:
			_spawn_grand_prix()

	camera = ChaseCamera.new()
	add_child(camera)
	camera.target = player
	camera.make_current()
	camera.snap()

	hud = Hud.new()
	add_child(hud)
	hud.pause_pressed.connect(_toggle_pause)
	player.item_changed.connect(hud.set_item)
	if GameInput.touch_ui:
		var touch := TouchControls.new()
		touch.show_item = mode != "time_trial"
		add_child(touch)

	if mode == "online":
		player.item_used.connect(_on_player_item_used)
		Net.kart_state.connect(_on_remote_state)
		Net.item_event.connect(_on_remote_item)
		Net.player_finished.connect(_on_player_finished_online)
		Net.player_left.connect(_on_remote_left)
		Net.disconnected.connect(_on_disconnected)


# --- Setup ------------------------------------------------------------------

func _add_kart(color: Color, slot: int):
	var k = Kart.new()
	k.body_color = color
	k.track = track
	k.add_to_group("karts")
	add_child(k)
	var row := int(slot / 2.0)
	var lateral := -3.5 if slot % 2 == 0 else 3.5
	k.place_at(track.length - 8.0 - row * 7.0, lateral)
	# Start just behind the line: crossing it begins lap 1.
	k.progress = k.prev_offset - track.length
	karts.append(k)
	return k


func _spawn_grand_prix() -> void:
	for i in 5:
		var k = _add_kart(KART_COLORS[i], i)
		k.skill = AI_SKILL[i]
		k.speed_factor = k.skill
		k.brain = AiBrain.new(track, -3.5 if i % 2 == 0 else 3.5)
	player = _add_kart(PLAYER_COLOR, 5)
	player.brain = PlayerBrain.new()


func _spawn_time_trial() -> void:
	player = _add_kart(PLAYER_COLOR, 0)
	player.brain = PlayerBrain.new()
	var data := Game.load_ghost()
	var frames = data.get("frames", [])
	if frames is Array and frames.size() > 1:
		_ghost_frames = frames
		ghost = Kart.new()
		ghost.is_ghost = true
		ghost.body_color = Color(0.55, 0.8, 1.0)
		add_child(ghost)
		_place_ghost(0.0)


func _spawn_online() -> void:
	var players: Array = Game.online_players
	for i in players.size():
		var p: Dictionary = players[i]
		var id := str(p.get("id", ""))
		var is_me := id == Net.my_id
		var k = _add_kart(PLAYER_COLOR if is_me else KART_COLORS[i % KART_COLORS.size()], i)
		if is_me:
			player = k
			k.brain = PlayerBrain.new()
		else:
			k.is_remote = true
			k.show_name_tag(str(p.get("name", "Racer")))
			remote[id] = k
	if player == null:
		# Shouldn't happen, but never leave the player without a kart.
		player = _add_kart(PLAYER_COLOR, players.size())
		player.brain = PlayerBrain.new()


# --- Main loop --------------------------------------------------------------

func _physics_process(delta: float) -> void:
	match state:
		"countdown":
			countdown -= delta
			var n := int(ceil(countdown))
			if n != _last_count_shown and n >= 1 and n <= 3:
				_last_count_shown = n
				hud.flash(str(n), 1.0)
			if countdown <= 0.0:
				state = "racing"
				hud.flash("GO!", 1.0)
				for k in karts:
					k.can_drive = true
		"racing":
			race_time += delta
			_record_ghost()
			if mode == "grand_prix":
				_check_finishes_grand_prix()
				_rubber_band()
			else:
				_check_player_finish()
		"finished":
			if mode == "grand_prix":
				_check_finishes_grand_prix()
	_update_ghost()
	if mode == "online":
		_send_state()
	_update_places()
	_update_hud()


func _toggle_pause() -> void:
	if state == "finished":
		return
	_paused = not _paused
	if not _paused:
		hud.hide_panel()
		get_tree().paused = false
		return
	# Online races keep running for everyone else, so they never truly pause.
	get_tree().paused = mode != "online"
	var buttons := [["Resume", _toggle_pause]]
	if mode == "online":
		buttons.append(["Quit race", _quit_online])
	else:
		buttons.append(["Restart", _restart])
		buttons.append(["Main menu", Game.go_to_menu])
	hud.show_panel("PAUSED", [], buttons)


func _restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


# --- Finishing --------------------------------------------------------------

func _goal() -> float:
	return Game.TOTAL_LAPS * track.length


func _check_finishes_grand_prix() -> void:
	for k in karts:
		if k.finish_order < 0 and k.progress >= _goal():
			finished_count += 1
			k.finish_order = finished_count
			if k == player:
				_finish_player()


func _check_player_finish() -> void:
	if player.finish_order < 0 and player.progress >= _goal():
		player.finish_order = 0
		_finish_player()


func _finish_player() -> void:
	lap_times.append(race_time - _lap_start)
	state = "finished"
	if _paused:
		_toggle_pause()
	# Let the AI take the player's kart for a victory lap.
	player.brain = AiBrain.new(track, 0.0)
	match mode:
		"time_trial":
			_finish_time_trial()
		"online":
			_finish_online()
		_:
			_finish_grand_prix()


func _finish_grand_prix() -> void:
	hud.flash("FINISH!", 2.0)
	var lines := [
		"You finished %s of %d" % [Hud.ordinal(player.finish_order), karts.size()],
		"Time  %s" % Hud.format_time(race_time),
		"Best lap  %s" % Hud.format_time(lap_times.min()),
	]
	await get_tree().create_timer(2.0).timeout
	hud.show_panel("RACE COMPLETE", lines, [["Race again", _restart], ["Main menu", Game.go_to_menu]])


func _finish_time_trial() -> void:
	var improved: bool = Game.record_time_trial(race_time, lap_times)
	if improved:
		Game.save_ghost(race_time, _recording)
	hud.flash("NEW RECORD!" if improved else "FINISH!", 2.0)

	var laps := []
	for t in lap_times:
		laps.append(Hud.format_time(t))
	var lines := [
		("★" if improved else "") + "Time  %s" % Hud.format_time(race_time),
		"Laps  " + "  |  ".join(laps),
		"Personal best  %s" % Hud.format_time(Game.best_time),
	]
	var buttons := [["Try again", _restart], ["Main menu", Game.go_to_menu]]
	await get_tree().create_timer(2.0).timeout
	if not Net.is_configured():
		hud.show_panel("TIME TRIAL", lines, buttons)
		return
	hud.show_panel("TIME TRIAL", lines + ["Sending your time to the leaderboard..."], buttons)
	var res: Dictionary = await Net.submit_time(Game.TRACK_ID, Game.display_name(), race_time)
	if not is_inside_tree():
		return
	var board := []
	if res.has("error"):
		board.append(str(res.error))
	else:
		board.append("Leaderboard rank: #%d" % int(res.get("rank", 0)))
		var entries: Array = res.get("entries", [])
		for i in mini(entries.size(), 5):
			var e: Dictionary = entries[i]
			var row := "%d. %s  %s" % [i + 1, e.get("name", "?"), Hud.format_time(float(e.get("time", 0.0)))]
			board.append(("★" if str(e.get("name", "")) == Game.display_name() else "") + row)
	hud.show_panel("TIME TRIAL", lines + board, buttons)


func _finish_online() -> void:
	hud.flash("FINISH!", 2.0)
	Net.send({"t": "f", "time": snappedf(race_time, 0.001)})
	await get_tree().create_timer(1.5).timeout
	_show_online_results()


func _show_online_results() -> void:
	if state != "finished" or not is_inside_tree():
		return
	var lines := []
	var sorted := _online_results.duplicate()
	sorted.sort_custom(func(a, b): return a.place < b.place)
	for r in sorted:
		var row := "%d. %s  %s" % [r.place, r.name, Hud.format_time(r.time)]
		lines.append(("★" if r.id == Net.my_id else "") + row)
	if _offline:
		lines.append("Your time: %s (connection lost)" % Hud.format_time(race_time))
	else:
		var waiting := karts.size() - _online_results.size()
		if waiting > 0:
			lines.append("Waiting for %d more..." % waiting)
	var buttons := [["Main menu", _quit_online]] if _offline else [["Back to lobby", _back_to_lobby]]
	hud.show_panel("RESULTS", lines, buttons)


func _back_to_lobby() -> void:
	# The host can end the race early, e.g. if someone stopped playing.
	if Net.is_host():
		Net.send({"t": "end"})
	Game.go_to_menu()


func _quit_online() -> void:
	Net.leave()
	Game.go_to_menu()


# --- Online events ----------------------------------------------------------

func _send_state() -> void:
	_send_tick += 1
	if _send_tick % SEND_EVERY == 0 and not _offline:
		Net.send({"t": "s", "d": player.network_state()})


func _on_remote_state(id: String, data: Array) -> void:
	if remote.has(id):
		remote[id].apply_remote(data)


func _on_player_item_used(kind: String, at: Vector3) -> void:
	if kind != "nitro":
		Net.send({"t": "i", "k": kind, "x": snappedf(at.x, 0.01), "y": snappedf(at.y, 0.01), "z": snappedf(at.z, 0.01)})


func _on_remote_item(id: String, msg: Dictionary) -> void:
	if remote.has(id):
		var at := Vector3(float(msg.get("x", 0.0)), float(msg.get("y", 0.0)), float(msg.get("z", 0.0)))
		remote[id].spawn_item_effect(str(msg.get("k", "")), at)


func _on_player_finished_online(id: String, player_name: String, time: float, place: int) -> void:
	_online_results.append({"id": id, "name": player_name, "time": time, "place": place})
	if remote.has(id):
		remote[id].finish_order = place
	elif id == Net.my_id:
		player.finish_order = place
	if id != Net.my_id and state != "finished":
		hud.flash("%s finished!" % player_name, 1.5)
	_show_online_results()


func _on_remote_left(id: String) -> void:
	if not remote.has(id):
		return
	var k = remote[id]
	remote.erase(id)
	karts.erase(k)
	k.queue_free()
	_show_online_results()


func _on_disconnected() -> void:
	_offline = true
	hud.flash("Connection lost", 2.5)
	_show_online_results()


# --- Ghost ------------------------------------------------------------------

func _record_ghost() -> void:
	if mode != "time_trial":
		return
	if _rec_tick % int(60.0 / GHOST_RATE) == 0:
		_recording.append([
			snappedf(player.global_position.x, 0.01),
			snappedf(player.global_position.z, 0.01),
			snappedf(player.rotation.y, 0.001),
		])
	_rec_tick += 1


func _update_ghost() -> void:
	if ghost == null:
		return
	if state == "countdown":
		_place_ghost(0.0)
	else:
		_place_ghost(race_time)


func _place_ghost(t: float) -> void:
	var f := t * GHOST_RATE
	var i := int(f)
	if i >= _ghost_frames.size() - 1:
		ghost.visible = false
		return
	var a: Array = _ghost_frames[i]
	var b: Array = _ghost_frames[i + 1]
	var w := f - i
	ghost.global_position = Vector3(lerpf(a[0], b[0], w), 0.0, lerpf(a[1], b[1], w))
	ghost.rotation.y = lerp_angle(a[2], b[2], w)


# --- Positions and HUD ------------------------------------------------------

## Computer karts slow down a little when far ahead and speed up when far
## behind, which keeps races close.
func _rubber_band() -> void:
	for k in karts:
		if k == player or k.finish_order > 0:
			continue
		var gap: float = k.progress - player.progress
		k.speed_factor = k.skill * clampf(1.0 - gap / 600.0, 0.9, 1.07)


func _update_places() -> void:
	var order := karts.duplicate()
	order.sort_custom(_ahead_of)
	for i in order.size():
		order[i].place = i + 1


func _ahead_of(a, b) -> bool:
	var a_done: bool = a.finish_order > 0
	var b_done: bool = b.finish_order > 0
	if a_done and b_done:
		return a.finish_order < b.finish_order
	if a_done != b_done:
		return a_done
	return a.progress > b.progress


func _update_hud() -> void:
	var lap := clampi(int(floor(player.progress / track.length)) + 1, 1, Game.TOTAL_LAPS)
	var place: int = 0 if mode == "time_trial" else player.place
	hud.set_status(lap, Game.TOTAL_LAPS, place, race_time)
	if state == "racing" and lap > _best_lap:
		_best_lap = lap
		lap_times.append(race_time - _lap_start)
		_lap_start = race_time
		var text := "FINAL LAP!" if lap == Game.TOTAL_LAPS else "LAP %d" % lap
		if mode == "time_trial":
			text += "\n" + Hud.format_time(lap_times[-1])
		hud.flash(text, 1.5)

	var tf: Transform3D = track.frame_at(player.current_offset)
	var heading: Vector3 = -player.global_transform.basis.z
	var wrong: bool = state == "racing" and heading.dot(-tf.basis.z) < -0.3 and absf(player.speed) > 3.0
	hud.set_wrong_way(wrong)
