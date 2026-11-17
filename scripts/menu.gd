extends Node3D
## Start screen: pick a mode, set your name, browse records, and create or
## join private lobbies. The track slowly orbits in the background.

const Track := preload("res://scripts/track.gd")
const World := preload("res://scripts/world.gd")
const Hud := preload("res://scripts/hud.gd")

const MUTED := Color(0.75, 0.8, 0.9)
const ACCENT := Color(1.0, 0.85, 0.3)
const WARN := Color(1.0, 0.6, 0.5)

var _camera: Camera3D
var _angle := 0.0
var _center := Vector3(17, 0, -82)
var _box: VBoxContainer
var _status: Label
var _screen := ""
var _busy := false


func _ready() -> void:
	World.add_environment(self)
	var track = Track.new()
	add_child(track)
	track.build()
	_camera = Camera3D.new()
	_camera.far = 1000.0
	add_child(_camera)
	_camera.make_current()

	_build_ui()
	Net.joined.connect(func(_id): _show_lobby())
	Net.lobby_updated.connect(_on_lobby_updated)
	Net.error.connect(_on_net_error)
	Net.disconnected.connect(_on_disconnected)
	if Net.in_lobby():
		_show_lobby()
	else:
		_show_main()


func _process(delta: float) -> void:
	_angle += delta * 0.08
	_camera.position = _center + Vector3(cos(_angle) * 190.0, 85.0, sin(_angle) * 190.0)
	_camera.look_at(_center, Vector3.UP)
	if _screen == "settings":
		_update_tilt_meter()


# --- Screens ----------------------------------------------------------------

func _show_main() -> void:
	_screen = "main"
	_clear()
	_box.add_child(_label("Your name", 22, MUTED))
	var name_edit := LineEdit.new()
	name_edit.text = Game.player_name
	name_edit.max_length = 16
	name_edit.placeholder_text = "Your name"
	name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_edit.text_changed.connect(Game.set_player_name)
	_box.add_child(name_edit)

	_button("Grand Prix", func(): Game.start_race("grand_prix"))
	_box.add_child(_label("Race 5 computer karts, with items", 20, MUTED))
	_button("Time Trial", func(): Game.start_race("time_trial"))
	var tt_note := "Beat the clock and your ghost"
	if Game.best_time > 0.0:
		tt_note += "  -  best %s" % Hud.format_time(Game.best_time)
	_box.add_child(_label(tt_note, 20, MUTED))
	var multi := _button("Multiplayer", _show_multiplayer)
	var board := _button("Leaderboards", _show_leaderboard)
	_button("Settings", _show_settings)
	if not Net.is_configured():
		multi.disabled = true
		board.disabled = true
		_box.add_child(_label("Online play isn't set up yet.", 20, WARN))


func _show_multiplayer(message: String = "") -> void:
	_screen = "multiplayer"
	_clear()
	_box.add_child(_label("Multiplayer", 40, Color.WHITE))
	_button("Create private lobby", _create_lobby)
	_box.add_child(_label("or join a friend's lobby", 22, MUTED))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var code_edit := LineEdit.new()
	code_edit.placeholder_text = "CODE"
	code_edit.max_length = 5
	code_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_edit.text_submitted.connect(_join)
	var join := Button.new()
	join.text = "Join"
	join.custom_minimum_size = Vector2(150, 0)
	join.pressed.connect(func(): _join(code_edit.text))
	row.add_child(code_edit)
	row.add_child(join)
	_box.add_child(row)
	_status = _label(message, 22, WARN)
	_box.add_child(_status)
	_button("Back", _show_main)


func _show_lobby() -> void:
	_screen = "lobby"
	_clear()
	var info: Dictionary = Net.lobby
	var code := str(info.get("code", "....."))
	var players: Array = info.get("players", [])
	_box.add_child(_label("Private lobby code", 24, MUTED))
	_box.add_child(_label(code, 76, ACCENT))
	_button("Copy code", func():
		DisplayServer.clipboard_set(code)
		if is_instance_valid(_status):
			_status.text = "Code copied. Send it to your friends.")
	_box.add_child(_label("Players  %d/%d" % [players.size(), int(info.get("max", 6))], 24, MUTED))
	for p in players:
		var tag := str(p.get("name", "Racer"))
		if str(p.get("id", "")) == str(info.get("host", "")):
			tag += "  (host)"
		if str(p.get("id", "")) == Net.my_id:
			tag += "  (you)"
		_box.add_child(_label(tag, 28, Color.WHITE))
	if Net.is_host():
		_button("Start race", func(): Net.send({"t": "start"}))
	elif str(info.get("phase", "")) == "racing":
		_box.add_child(_label("A race is still going. Hang on...", 22, MUTED))
	else:
		_box.add_child(_label("Waiting for the host to start...", 22, MUTED))
	_status = _label("", 22, ACCENT)
	_box.add_child(_status)
	_button("Leave lobby", func():
		Net.leave()
		_show_multiplayer())


func _show_leaderboard() -> void:
	_screen = "leaderboard"
	_clear()
	_box.add_child(_label("Time Trial records", 40, Color.WHITE))
	_box.add_child(_label("%s  -  %d laps" % [Game.TRACK_NAME, Game.TOTAL_LAPS], 22, MUTED))
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	_box.add_child(list)
	list.add_child(_label("Loading...", 24, MUTED))
	if Game.best_time > 0.0:
		_box.add_child(_label("Your best  %s" % Hud.format_time(Game.best_time), 24, ACCENT))
	_button("Back", _show_main)

	var res: Dictionary = await Net.get_leaderboard(Game.TRACK_ID)
	if not is_instance_valid(list):
		return
	for c in list.get_children():
		c.queue_free()
	if res.has("error"):
		list.add_child(_label(str(res.error), 24, WARN))
		return
	var entries: Array = res.get("entries", [])
	if entries.is_empty():
		list.add_child(_label("No records yet. Set the first one in Time Trial!", 22, MUTED))
	for i in entries.size():
		var e: Dictionary = entries[i]
		var mine := str(e.get("name", "")) == Game.display_name()
		var row := HBoxContainer.new()
		var rank := _label("%d." % (i + 1), 26, ACCENT if mine else MUTED)
		rank.custom_minimum_size = Vector2(56, 0)
		rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var who := _label(str(e.get("name", "?")), 26, ACCENT if mine else Color.WHITE)
		who.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var time := _label(Hud.format_time(float(e.get("time", 0.0))), 26, ACCENT if mine else Color.WHITE)
		row.add_child(rank)
		row.add_child(who)
		row.add_child(time)
		list.add_child(row)


func _show_settings() -> void:
	_screen = "settings"
	_clear()
	_box.add_child(_label("Settings", 40, Color.WHITE))
	var tilt := CheckButton.new()
	tilt.text = "Tilt to steer"
	tilt.button_pressed = Game.tilt_enabled
	tilt.toggled.connect(func(on):
		Game.set_tilt_enabled(on)
		_show_settings())
	_box.add_child(tilt)
	if not GameInput.touch_ui:
		_box.add_child(_label("Tilt steering works on phones and tablets.", 20, MUTED))

	if Game.tilt_enabled:
		_box.add_child(_label("Turn your phone like a steering wheel. Buttons and keys still work too.", 20, MUTED))
		var sens_label := _label("", 22, MUTED)
		var sens := HSlider.new()
		sens.min_value = 15.0
		sens.max_value = 50.0
		sens.step = 1.0
		sens.value = Game.tilt_range
		sens.custom_minimum_size = Vector2(0, 44)
		var describe := func(v: float):
			sens_label.text = "Full turn at %d degrees of tilt  (left = twitchier)" % int(v)
		describe.call(sens.value)
		sens.value_changed.connect(func(v):
			Game.set_tilt_range(v)
			describe.call(v))
		_box.add_child(sens_label)
		_box.add_child(sens)
		var invert := CheckButton.new()
		invert.text = "Invert tilt"
		invert.button_pressed = Game.tilt_invert
		invert.toggled.connect(Game.set_tilt_invert)
		_box.add_child(invert)

		# Live meter, so you can check tilt works before racing.
		var meter := Panel.new()
		meter.custom_minimum_size = Vector2(0, 34)
		var track_style := StyleBoxFlat.new()
		track_style.bg_color = Color(1, 1, 1, 0.12)
		track_style.set_corner_radius_all(17)
		meter.add_theme_stylebox_override("panel", track_style)
		var marker := ColorRect.new()
		marker.name = "Marker"
		marker.color = ACCENT
		marker.size = Vector2(16, 34)
		meter.add_child(marker)
		meter.name = "TiltMeter"
		_box.add_child(meter)
		var reading := _label("", 22, MUTED)
		reading.name = "TiltReading"
		_box.add_child(reading)
	_button("Back", _show_main)


func _update_tilt_meter() -> void:
	var meter := _box.get_node_or_null("TiltMeter")
	var reading := _box.get_node_or_null("TiltReading")
	if meter == null or reading == null:
		return
	var marker: ColorRect = meter.get_node("Marker")
	var steer := GameInput.tilt_steer()
	marker.position.x = (meter.size.x - marker.size.x) * (steer + 1.0) / 2.0
	var angle := GameInput.tilt_angle()
	if is_nan(angle):
		if GameInput.tilt_needs_permission():
			reading.text = "Tap the screen, then choose Allow for motion access."
		else:
			reading.text = "No motion data from this device yet."
	elif absf(steer) < 0.01:
		reading.text = "Straight"
	else:
		reading.text = "%s %d%%" % ["Right" if steer > 0.0 else "Left", int(absf(steer) * 100.0)]


# --- Actions ----------------------------------------------------------------

func _create_lobby() -> void:
	if _busy:
		return
	_busy = true
	_status.text = "Creating a lobby..."
	var res: Dictionary = await Net.create_lobby(Game.display_name())
	_busy = false
	if res.has("error") and _screen == "multiplayer" and is_instance_valid(_status):
		_status.text = str(res.error)


func _join(code: String) -> void:
	code = code.strip_edges().to_upper()
	if code.length() != 5:
		_status.text = "Lobby codes are 5 characters."
		return
	_status.text = "Joining..."
	Net.join(code, Game.display_name())


func _on_lobby_updated(_info: Dictionary) -> void:
	if _screen == "lobby":
		_show_lobby()


func _on_net_error(message: String) -> void:
	_show_multiplayer(message)


func _on_disconnected() -> void:
	if _screen == "lobby":
		_show_multiplayer("Disconnected from the lobby.")


# --- UI helpers -------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var center := CenterContainer.new()
	center.theme = _make_theme()
	layer.add_child(center)
	center.set_anchors_preset(Control.PRESET_FULL_RECT)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 14)
	center.add_child(outer)
	var title := _label("KART RACER", 84, Color.WHITE)
	title.label_settings.outline_size = 16
	title.label_settings.outline_color = Color(0.1, 0.2, 0.5)
	outer.add_child(title)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.15, 0.82)
	sb.set_corner_radius_all(20)
	sb.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(560, 0)
	outer.add_child(panel)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 10)
	panel.add_child(_box)


func _make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 30
	var states := {
		"normal": Color(0.16, 0.36, 0.85),
		"hover": Color(0.22, 0.44, 0.95),
		"pressed": Color(0.1, 0.26, 0.65),
		"focus": Color(0.22, 0.44, 0.95),
		"disabled": Color(0.25, 0.27, 0.32),
	}
	for key in states:
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[key]
		sb.set_corner_radius_all(14)
		sb.set_content_margin_all(14)
		if key == "focus":
			sb.draw_center = false
			sb.border_color = Color(1, 1, 1, 0.8)
			sb.set_border_width_all(3)
		theme.set_stylebox(key, "Button", sb)
	var field := StyleBoxFlat.new()
	field.bg_color = Color(1, 1, 1, 0.1)
	field.set_corner_radius_all(12)
	field.set_content_margin_all(14)
	theme.set_stylebox("normal", "LineEdit", field)
	theme.set_stylebox("focus", "LineEdit", field)
	return theme


func _clear() -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()


func _button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 76)
	b.pressed.connect(action)
	_box.add_child(b)
	return b


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var ls := LabelSettings.new()
	ls.font_size = size
	ls.font_color = color
	l.label_settings = ls
	return l
