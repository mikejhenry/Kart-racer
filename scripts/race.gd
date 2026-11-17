extends Node3D
## One race, in any of the three modes (see Game.mode):
##   grand_prix  - you against 5 computer karts, with items
##   time_trial  - solo against the clock and a ghost, no items
##   online      - against other players (and optional computer karts)

const Track := preload("res://scripts/track.gd")
const Tracks := preload("res://scripts/tracks.gd")
const Kart := preload("res://scripts/kart.gd")
const PlayerBrain := preload("res://scripts/player_brain.gd")
const AiBrain := preload("res://scripts/ai_brain.gd")
const ChaseCamera := preload("res://scripts/chase_camera.gd")
const Hud := preload("res://scripts/hud.gd")
const TouchControls := preload("res://scripts/touch_controls.gd")
const World := preload("res://scripts/world.gd")

## Base speed of each computer kart, by difficulty.
const AI_SKILL := {
	"easy": [0.9, 0.88, 0.86, 0.84, 0.82],
	"normal": [0.97, 0.95, 0.93, 0.91, 0.89],
	"hard": [1.0, 0.99, 0.98, 0.97, 0.96],
}
## How much computer karts slow down when ahead / speed up when behind.
const RUBBER_BAND := {"easy": [0.88, 1.03], "normal": [0.9, 1.07], "hard": [0.93, 1.1]}
const GHOST_RATE := 10.0   ## Ghost samples per second
const SEND_EVERY := 6      ## Physics frames between online updates (10/s)

var mode := "grand_prix"
var track_id := "circuit_1"
var difficulty := "normal"
var track
var karts: Array = []
var player
var camera
var hud
var state := "countdown"   ## countdown, racing, finished
var countdown := 3.5
var race_time := 0.0       ## The player's time (stops when they finish)
var _clock := 0.0          ## Keeps running after the player finishes
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
var kart_by_id := {}       ## player or bot id -> kart
var _bots: Array = []
var _send_tick := 0
var _online_results: Array = []
var _offline := false
var _unsent: Array = []    ## Finish messages waiting for the connection to return


func _ready() -> void:
	mode = Game.mode
	if mode == "online":
		track_id = str(Game.online.get("track", "circuit_1"))
		difficulty = str(Game.online.get("difficulty", "normal"))
	else:
		track_id = Game.track_id
		difficulty = Game.difficulty if mode == "grand_prix" else "normal"
	var def := Tracks.get_track(track_id)
	World.add_environment(self, Tracks.THEMES[def.theme])
	track = Track.new()
	track.track_id = track_id
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
	for k in karts:
		k.class_speed = Game.class_speed(difficulty)
		k.racers = karts.size()

	camera = ChaseCamera.new()
	add_child(camera)
	camera.target = player
	camera.make_current()
	camera.snap()

	hud = Hud.new()
	add_child(hud)
	hud.pause_pressed.connect(_toggle_pause)
	hud.setup_minimap(track.outline(), karts, player)
	player.item_changed.connect(hud.set_item)
	if GameInput.touch_ui:
		var touch := TouchControls.new()
		touch.show_item = mode != "time_trial"
		add_child(touch)
	Sfx.play_music("music_race")
	hud.flash(str(def.name), 0.5)

	if mode == "online":
		player.item_used.connect(_on_item_used.bind(player))
		Net.kart_state.connect(_on_remote_state)
		Net.item_event.connect(_on_remote_item)
		Net.player_finished.connect(_on_player_finished_online)
		Net.player_left.connect(_on_remote_left)
		Net.player_dropped.connect(_on_player_dropped)
		Net.player_back.connect(_on_player_back)
		Net.lobby_updated.connect(func(_info): _sync_bots())
		Net.connection_lost.connect(_on_connection_lost)
		Net.reconnected.connect(_on_reconnected)
		Net.disconnected.connect(_on_disconnected)
		if Game.online.get("resume", false):
			_resume_race()


# --- Setup ------------------------------------------------------------------

func _add_kart(color: Color, slot: int, style: String, human: bool = false):
	var k = Kart.new()
	k.body_color = color
	k.style = style
	k.is_human = human
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
	var colors := []
	for i in Game.KART_COLORS.size():
		if i != Game.kart_color:
			colors.append(Game.KART_COLORS[i])
	for i in 5:
		var k = _add_kart(colors[i], i, Kart.STYLES[(i + 1) % Kart.STYLES.size()])
		k.skill = AI_SKILL[difficulty][i]
		k.speed_factor = k.skill
		k.brain = AiBrain.new(track, Game.ai_level(difficulty))
	player = _add_kart(Game.color(), 5, Game.kart_style, true)
	player.brain = PlayerBrain.new()


func _spawn_time_trial() -> void:
	player = _add_kart(Game.color(), 0, Game.kart_style, true)
	player.brain = PlayerBrain.new()
	match Game.ghost_mode:
		"mine":
			_use_ghost(Game.load_ghost(track_id).get("frames", []), "")
		"record":
			_load_record_ghost()


func _load_record_ghost() -> void:
	var res: Dictionary = await Net.get_record_ghost(track_id)
	if not is_inside_tree():
		return
	if res.has("frames"):
		_use_ghost(res.frames, "%s  %s" % [res.get("name", "?"), Hud.format_time(float(res.get("time", 0.0)))])
	else:
		_use_ghost(Game.load_ghost(track_id).get("frames", []), "")
		hud.flash("No record ghost yet", 1.5)


func _use_ghost(frames, holder: String) -> void:
	if not frames is Array or frames.size() < 2:
		return
	_ghost_frames = frames
	ghost = Kart.new()
	ghost.is_ghost = true
	ghost.body_color = Color(1.0, 0.85, 0.3) if holder != "" else Color(0.55, 0.8, 1.0)
	add_child(ghost)
	if holder != "":
		ghost.show_name_tag(holder)
	_place_ghost(race_time)


func _spawn_online() -> void:
	var players: Array = Game.online.get("players", [])
	for i in players.size():
		var p: Dictionary = players[i]
		var id := str(p.get("id", ""))
		var is_me := id == Net.my_id
		var k = _add_kart(Color.html(str(p.get("color", "e62633"))), i, str(p.get("style", "classic")), is_me)
		k.net_id = id
		kart_by_id[id] = k
		if bool(p.get("bot", false)):
			_bots.append(k)
		if is_me:
			player = k
			k.brain = PlayerBrain.new()
		else:
			k.show_name_tag(str(p.get("name", "Racer")))
			k.is_remote = true
	if player == null:
		# Shouldn't happen, but never leave the player without a kart.
		player = _add_kart(Game.color(), players.size(), Game.kart_style, true)
		player.brain = PlayerBrain.new()
	_sync_bots()


## Computer karts in online races are driven by the host's device. If the
## host changes (e.g. they lost connection) the new host takes them over.
func _sync_bots() -> void:
	var own := Net.is_host()
	for k in _bots:
		if own and k.is_remote:
			k.is_remote = false
			k.brain = AiBrain.new(track, Game.ai_level(difficulty))
			k.skill = AI_SKILL[difficulty][1]
			k.speed_factor = k.skill
			k.can_drive = state != "countdown"
			k.velocity = Vector3.ZERO
			k.prev_offset = track.get_offset(k.global_position)
			k.current_offset = k.prev_offset
			if not k.has_meta("items_hooked"):
				k.set_meta("items_hooked", true)
				k.item_used.connect(_on_item_used.bind(k))
		elif not own and not k.is_remote:
			k.is_remote = true
			k.brain = null
			k._snaps.clear()
			k._clock_offset = INF


## Rejoining a race already in progress (e.g. after the page reloaded).
func _resume_race() -> void:
	state = "racing"
	countdown = 0.0
	race_time = float(Game.online.get("elapsed", 0.0))
	_clock = race_time
	for k in karts:
		k.can_drive = true
	var me = Game.online.get("me")
	if me is Dictionary and me.get("d") is Array and me.d.size() >= 6:
		var d: Array = me.d
		player.global_position = Vector3(d[0], float(d[1]) + 0.3, d[2])
		player.rotation.y = d[3]
		player.progress = d[5]
		player.prev_offset = track.get_offset(player.global_position)
		player.current_offset = player.prev_offset
	_best_lap = clampi(int(floor(player.progress / track.length)) + 1, 1, Game.TOTAL_LAPS)
	var results: Array = Game.online.get("results", [])
	for i in results.size():
		var r: Dictionary = results[i]
		_on_player_finished_online(str(r.id), str(r.name), float(r.time), i + 1)
	hud.flash("Back in the race!", 1.5)


# --- Main loop --------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if state != "countdown":
		_clock += delta
	match state:
		"countdown":
			countdown -= delta
			var n := int(ceil(countdown))
			if n != _last_count_shown and n >= 1 and n <= 3:
				_last_count_shown = n
				hud.flash(str(n), 1.0)
				Sfx.play("beep")
			if countdown <= 0.0:
				state = "racing"
				hud.flash("GO!", 1.0)
				Sfx.play("go")
				for k in karts:
					k.can_drive = true
		"racing":
			race_time += delta
			_record_ghost()
			match mode:
				"grand_prix":
					_check_finishes_grand_prix()
					_rubber_band()
				"online":
					_check_player_finish()
					_check_bot_finishes()
				_:
					_check_player_finish()
		"finished":
			match mode:
				"grand_prix":
					_check_finishes_grand_prix()
				"online":
					_check_bot_finishes()
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


func _check_bot_finishes() -> void:
	if not Net.is_host():
		return
	for k in _bots:
		if not k.is_remote and k.finish_order < 0 and k.progress >= _goal() and not k.has_meta("reported"):
			k.set_meta("reported", true)
			_send_or_queue({"t": "f", "b": k.net_id, "time": snappedf(_clock, 0.001)})


func _finish_player() -> void:
	lap_times.append(race_time - _lap_start)
	state = "finished"
	if _paused:
		_toggle_pause()
	Sfx.play("finish")
	Game.vibrate(120)
	# Let the AI take the player's kart for a victory lap.
	player.brain = AiBrain.new(track, 1)
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
		"%s  -  %s" % [Tracks.name_of(track_id), Game.DIFFICULTY_NAMES[difficulty]],
	]
	await get_tree().create_timer(2.0).timeout
	hud.show_panel("RACE COMPLETE", lines, [["Race again", _restart], ["Main menu", Game.go_to_menu]])


func _finish_time_trial() -> void:
	var improved: bool = Game.record_time_trial(track_id, race_time, lap_times)
	if improved:
		Game.save_ghost(track_id, race_time, _recording)
	hud.flash("NEW RECORD!" if improved else "FINISH!", 2.0)

	var laps := []
	for t in lap_times:
		laps.append(Hud.format_time(t))
	var lines := [
		("★" if improved else "") + "Time  %s" % Hud.format_time(race_time),
		"Laps  " + "  |  ".join(laps),
		"Personal best  %s" % Hud.format_time(Game.best_time(track_id)),
	]
	var buttons := [["Try again", _restart], ["Main menu", Game.go_to_menu]]
	await get_tree().create_timer(2.0).timeout
	if not Net.is_configured():
		hud.show_panel("TIME TRIAL", lines, buttons)
		return
	hud.show_panel("TIME TRIAL", lines + ["Sending your time to the leaderboard..."], buttons)
	var res: Dictionary = await Net.submit_time(track_id, Game.display_name(), race_time, _recording)
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
	_send_or_queue({"t": "f", "time": snappedf(race_time, 0.001)})
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
	if _send_tick % SEND_EVERY != 0 or _offline:
		return
	var now := Time.get_ticks_msec() / 1000.0
	Net.send({"t": "s", "d": player.network_state(), "at": now})
	if Net.is_host():
		for k in _bots:
			if not k.is_remote:
				Net.send({"t": "s", "b": k.net_id, "d": k.network_state(), "at": now})


func _send_or_queue(msg: Dictionary) -> void:
	if Net.in_lobby():
		Net.send(msg)
	else:
		_unsent.append(msg)


func _on_remote_state(id: String, data: Array, sent_at: float) -> void:
	var k = kart_by_id.get(id)
	if k and k.is_remote:
		k.apply_remote(data, sent_at)


## The player (or a bot this device drives) used an item: tell the others.
func _on_item_used(kind: String, at: Vector3, target_id: String, kart) -> void:
	if kind not in ["missile", "oil", "storm"]:
		return   # nitro and shield show up in the kart's state instead
	var msg := {"t": "i", "k": kind, "x": snappedf(at.x, 0.01), "y": snappedf(at.y, 0.01), "z": snappedf(at.z, 0.01), "target": target_id}
	if kart != player:
		msg["b"] = kart.net_id
	Net.send(msg)


func _on_remote_item(id: String, msg: Dictionary) -> void:
	var k = kart_by_id.get(id)
	if k == null:
		return
	var kind := str(msg.get("k", ""))
	if kind == "storm":
		# Spins the target if it's ours to drive; otherwise just shows the bolt.
		var target = kart_by_id.get(str(msg.get("target", "")))
		if target:
			target.storm_hit()
		return
	var at := Vector3(float(msg.get("x", 0.0)), float(msg.get("y", 0.0)), float(msg.get("z", 0.0)))
	k.spawn_item_effect(kind, at)


func _on_player_finished_online(id: String, player_name: String, time: float, place: int) -> void:
	for r in _online_results:
		if r.id == id:
			return
	_online_results.append({"id": id, "name": player_name, "time": time, "place": place})
	var k = kart_by_id.get(id)
	if k:
		k.finish_order = place
	if id != Net.my_id and state != "finished":
		hud.flash("%s finished!" % player_name, 1.5)
	_show_online_results()


func _on_remote_left(id: String) -> void:
	var k = kart_by_id.get(id)
	if k == null:
		return
	kart_by_id.erase(id)
	karts.erase(k)
	_bots.erase(k)
	k.queue_free()
	_show_online_results()


func _on_player_dropped(id: String) -> void:
	var k = kart_by_id.get(id)
	if k:
		hud.flash("A player lost connection", 1.5)


func _on_player_back(id: String) -> void:
	if kart_by_id.has(id):
		hud.flash("A player is back", 1.5)


func _on_connection_lost() -> void:
	hud.set_net_status("Connection lost - reconnecting...")


func _on_reconnected() -> void:
	hud.set_net_status("")
	hud.flash("Reconnected", 1.0)
	for msg in _unsent:
		Net.send(msg)
	_unsent.clear()


func _on_disconnected() -> void:
	_offline = true
	hud.set_net_status("Offline")
	hud.flash("Connection lost", 2.5)
	_show_online_results()


# --- Ghost ------------------------------------------------------------------

func _record_ghost() -> void:
	if mode != "time_trial":
		return
	if _rec_tick % int(60.0 / GHOST_RATE) == 0:
		var p: Vector3 = player.global_position
		_recording.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01), snappedf(player.rotation.y, 0.001)])
	_rec_tick += 1


func _update_ghost() -> void:
	if ghost == null:
		return
	_place_ghost(0.0 if state == "countdown" else race_time)


func _place_ghost(t: float) -> void:
	var f := t * GHOST_RATE
	var i := int(f)
	if i >= _ghost_frames.size() - 1:
		ghost.visible = false
		return
	var a := _ghost_point(_ghost_frames[i])
	var b := _ghost_point(_ghost_frames[i + 1])
	var w := f - i
	ghost.global_position = (a[0] as Vector3).lerp(b[0], w)
	ghost.rotation.y = lerp_angle(a[1], b[1], w)


## Ghost frames are [x, y, z, yaw] ([x, z, yaw] in older saves).
func _ghost_point(frame: Array) -> Array:
	if frame.size() >= 4:
		return [Vector3(frame[0], frame[1], frame[2]), float(frame[3])]
	return [Vector3(frame[0], 0.0, frame[1]), float(frame[2])]


# --- Positions and HUD ------------------------------------------------------

## Computer karts slow down a little when far ahead and speed up when far
## behind, which keeps races close.
func _rubber_band() -> void:
	var limits: Array = RUBBER_BAND[difficulty]
	for k in karts:
		if k == player or k.finish_order > 0:
			continue
		var gap: float = k.progress - player.progress
		k.speed_factor = k.skill * clampf(1.0 - gap / 600.0, limits[0], limits[1])


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
		Sfx.play("lap")

	var tf: Transform3D = track.frame_at(player.current_offset)
	var heading: Vector3 = -player.global_transform.basis.z
	var wrong: bool = state == "racing" and heading.dot(-tf.basis.z) < -0.3 and absf(player.speed) > 3.0
	hud.set_wrong_way(wrong)
