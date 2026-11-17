extends Node3D
## Start screen: pick a mode, track and difficulty, set your name and kart,
## browse records, change settings, and create or join online lobbies.
## The chosen track slowly orbits in the background.

const Track := preload("res://scripts/track.gd")
const Tracks := preload("res://scripts/tracks.gd")
const Kart := preload("res://scripts/kart.gd")
const World := preload("res://scripts/world.gd")
const Hud := preload("res://scripts/hud.gd")
const UiTheme := preload("res://scripts/ui_theme.gd")

const MUTED := Color(0.75, 0.8, 0.9)
const ACCENT := Color(1.0, 0.85, 0.3)
const WARN := Color(1.0, 0.6, 0.5)
const GHOST_NAMES := {"mine": "Your best run", "record": "World record", "off": "No ghost"}

var _camera: Camera3D
var _angle := 0.0
var _center := Vector3.ZERO
var _radius := 190.0
var _box: VBoxContainer
var _scroll: ScrollContainer
var _title: Label
var _status: Label
var _screen := ""
var _busy := false
var _preview_kart
var _preview_holder: Node3D
var _autostart_label: Label
var _autostart_at := 0.0


func _ready() -> void:
	var def := Tracks.get_track(Game.track_id)
	World.add_environment(self, Tracks.THEMES[def.theme])
	var track = Track.new()
	track.track_id = def.id
	add_child(track)
	track.build()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in def.points:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	_center = Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.y + hi.y) * 0.5)
	_radius = maxf(hi.x - lo.x, hi.y - lo.y) * 0.75 + 40.0
	_camera = Camera3D.new()
	_camera.far = 1500.0
	add_child(_camera)
	_camera.make_current()

	_build_ui()
	Net.joined.connect(func(_id): _show_lobby())
	Net.lobby_updated.connect(_on_lobby_updated)
	Net.error.connect(_on_net_error)
	Net.disconnected.connect(_on_disconnected)
	get_viewport().size_changed.connect(_fit)
	Sfx.play_music("music_menu")
	if Net.in_lobby():
		_show_lobby()
	else:
		_show_main()


func _process(delta: float) -> void:
	_angle += delta * 0.08
	_camera.position = _center + Vector3(cos(_angle) * _radius, _radius * 0.45, sin(_angle) * _radius)
	_camera.look_at(_center, Vector3.UP)
	if _screen == "settings":
		_update_tilt_meter()
	if _preview_holder and is_instance_valid(_preview_holder):
		_preview_holder.rotate_y(delta * 0.8)
	if _autostart_label and is_instance_valid(_autostart_label) and _autostart_at > 0.0:
		var left := int(ceil(_autostart_at - Time.get_ticks_msec() / 1000.0))
		_autostart_label.text = "Starting in %d s..." % maxi(left, 0) if left > 0 else "Starting..."


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

	var modes := _row()
	_button("Grand Prix", func(): _show_setup("grand_prix"), modes)
	_button("Time Trial", func(): _show_setup("time_trial"), modes)
	var multi := _button("Multiplayer", _show_multiplayer)
	var more := _row()
	var board := _button("Records", func(): _show_leaderboard(Game.track_id), more)
	_button("Garage", _show_garage, more)
	_button("Settings", _show_settings, more)

	var session := Game.recent_session()
	if Net.is_configured() and not session.is_empty() and not Net.in_lobby():
		_button("Rejoin lobby %s" % session.code, func():
			_show_multiplayer("Rejoining...")
			Net.resume(session, Game.display_name()))
	if not Net.is_configured():
		multi.disabled = true
		board.disabled = true
		_box.add_child(_label("Online play isn't set up yet.", 20, WARN))


## Track (and difficulty or ghost) choice before a Grand Prix or Time Trial.
func _show_setup(mode: String) -> void:
	_screen = "setup"
	_clear()
	var gp := mode == "grand_prix"
	_box.add_child(_label("Grand Prix" if gp else "Time Trial", 40, Color.WHITE))
	_box.add_child(_label("Track", 22, MUTED))
	var blurb := _label(str(Tracks.get_track(Game.track_id).get("blurb", "")), 20, MUTED)
	var best := _label("", 22, ACCENT)
	var refresh := func():
		blurb.text = str(Tracks.get_track(Game.track_id).get("blurb", ""))
		var t := Game.best_time(Game.track_id)
		best.text = "Your best here: %s" % Hud.format_time(t) if t > 0.0 else "No time set here yet"
	_box.add_child(_picker(Tracks.ids(), Tracks.name_of, Game.track_id, func(v):
		Game.set_value("track_id", v)
		refresh.call()))
	_box.add_child(blurb)
	if gp:
		_box.add_child(_label("Difficulty", 22, MUTED))
		_box.add_child(_picker(Game.DIFFICULTIES, func(v): return Game.DIFFICULTY_NAMES[v], Game.difficulty, func(v): Game.set_value("difficulty", v)))
	else:
		_box.add_child(_label("Race against", 22, MUTED))
		var ghosts := ["mine", "record", "off"] if Net.is_configured() else ["mine", "off"]
		var current := Game.ghost_mode if Game.ghost_mode in ghosts else "mine"
		_box.add_child(_picker(ghosts, func(v): return GHOST_NAMES[v], current, func(v): Game.set_value("ghost_mode", v)))
		_box.add_child(best)
		refresh.call()
	_button("Start", func(): Game.start_race(mode))
	_button("Back", _show_main)


func _show_garage() -> void:
	_screen = "garage"
	_clear()
	_box.add_child(_label("Garage", 40, Color.WHITE))

	# Rotating 3D preview of the kart
	var container := SubViewportContainer.new()
	container.stretch = true
	container.custom_minimum_size = Vector2(0, 220)
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	container.add_child(viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.85, 1.0)
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	viewport.add_child(world_env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	viewport.add_child(light)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 2.2, 5.2)
	cam.rotation_degrees = Vector3(-18, 0, 0)
	cam.fov = 45.0
	viewport.add_child(cam)
	_preview_holder = Node3D.new()
	viewport.add_child(_preview_holder)
	_box.add_child(container)
	_rebuild_preview()

	_box.add_child(_label("Kart", 22, MUTED))
	_box.add_child(_picker(Kart.STYLES, func(v): return Kart.STYLE_NAMES[v], Game.kart_style, func(v):
		Game.set_value("kart_style", v)
		_rebuild_preview()))
	_box.add_child(_label("Colour", 22, MUTED))
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	var swatches: Array[Button] = []
	for i in Game.KART_COLORS.size():
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(90, 56)
		swatch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		swatches.append(swatch)
		swatch.pressed.connect(func():
			Sfx.play("click")
			Game.set_value("kart_color", i)
			_style_swatches(swatches)
			_rebuild_preview())
		grid.add_child(swatch)
	_style_swatches(swatches)
	_box.add_child(grid)
	_button("Back", _show_main)


func _style_swatches(swatches: Array[Button]) -> void:
	for i in swatches.size():
		var sb := StyleBoxFlat.new()
		sb.bg_color = Game.KART_COLORS[i]
		sb.set_corner_radius_all(10)
		if i == Game.kart_color:
			sb.border_color = Color.WHITE
			sb.set_border_width_all(4)
		for state in ["normal", "hover", "pressed", "focus"]:
			swatches[i].add_theme_stylebox_override(state, sb)


func _rebuild_preview() -> void:
	if _preview_kart and is_instance_valid(_preview_kart):
		_preview_kart.queue_free()
	_preview_kart = Kart.new()
	_preview_kart.preview = true
	_preview_kart.style = Game.kart_style
	_preview_kart.body_color = Game.color()
	_preview_holder.add_child(_preview_kart)


func _show_settings() -> void:
	_screen = "settings"
	_clear()
	_box.add_child(_label("Settings", 40, Color.WHITE))
	_box.add_child(_label("Music", 22, MUTED))
	_box.add_child(_slider(0.0, 1.0, 0.05, Game.music_volume, func(v): Game.set_value("music_volume", v)))
	_box.add_child(_label("Sound effects", 22, MUTED))
	_box.add_child(_slider(0.0, 1.0, 0.05, Game.sfx_volume, func(v): Game.set_value("sfx_volume", v)))
	var buzz := CheckButton.new()
	buzz.text = "Vibration"
	buzz.button_pressed = Game.vibration
	buzz.toggled.connect(func(on):
		Game.set_value("vibration", on)
		Game.vibrate(80))
	_box.add_child(buzz)

	var tilt := CheckButton.new()
	tilt.text = "Tilt to steer"
	tilt.button_pressed = Game.tilt_enabled
	tilt.toggled.connect(func(on):
		Game.set_value("tilt_enabled", on)
		_show_settings())
	_box.add_child(tilt)
	if not GameInput.touch_ui:
		_box.add_child(_label("Vibration and tilt work on phones and tablets.", 20, MUTED))

	if Game.tilt_enabled:
		_box.add_child(_label("Turn your phone like a steering wheel. Buttons and keys still work too.", 20, MUTED))
		var sens_label := _label("", 22, MUTED)
		var describe := func(v: float):
			sens_label.text = "Full turn at %d degrees of tilt  (left = twitchier)" % int(v)
		describe.call(Game.tilt_range)
		_box.add_child(sens_label)
		_box.add_child(_slider(15.0, 50.0, 1.0, Game.tilt_range, func(v):
			Game.set_value("tilt_range", v)
			describe.call(v)))
		var invert := CheckButton.new()
		invert.text = "Invert tilt"
		invert.button_pressed = Game.tilt_invert
		invert.toggled.connect(func(on): Game.set_value("tilt_invert", on))
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


func _show_leaderboard(track: String) -> void:
	_screen = "leaderboard"
	_clear()
	_box.add_child(_label("Time Trial records", 40, Color.WHITE))
	_box.add_child(_picker(Tracks.ids(), Tracks.name_of, track, func(v): _show_leaderboard(v)))
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	_box.add_child(list)
	list.add_child(_label("Loading...", 24, MUTED))
	var mine := Game.best_time(track)
	if mine > 0.0:
		_box.add_child(_label("Your best  %s" % Hud.format_time(mine), 24, ACCENT))
	_button("Back", _show_main)

	var res: Dictionary = await Net.get_leaderboard(track)
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
		var me := str(e.get("name", "")) == Game.display_name()
		var row := HBoxContainer.new()
		var rank := _label("%d." % (i + 1), 26, ACCENT if me else MUTED)
		rank.custom_minimum_size = Vector2(56, 0)
		rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var who := _label(str(e.get("name", "?")), 26, ACCENT if me else Color.WHITE)
		who.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var time := _label(Hud.format_time(float(e.get("time", 0.0))), 26, ACCENT if me else Color.WHITE)
		row.add_child(rank)
		row.add_child(who)
		row.add_child(time)
		list.add_child(row)
	_fit()


func _show_multiplayer(message: String = "") -> void:
	_screen = "multiplayer"
	_clear()
	_box.add_child(_label("Multiplayer", 40, Color.WHITE))
	_button("Quick match", _quick_match)
	_box.add_child(_label("Race whoever is online. Starts by itself.", 20, MUTED))
	_button("Create private lobby", _create_lobby)
	_box.add_child(_label("or join a friend's lobby", 22, MUTED))
	var row := _row()
	var code_edit := LineEdit.new()
	code_edit.placeholder_text = "CODE"
	code_edit.max_length = 5
	code_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_edit.text_submitted.connect(_join)
	row.add_child(code_edit)
	var join := _button("Join", func(): _join(code_edit.text), row)
	join.size_flags_horizontal = Control.SIZE_SHRINK_END
	join.custom_minimum_size = Vector2(150, 76)
	_status = _label(message, 22, WARN)
	_box.add_child(_status)
	_button("Back", _show_main)


func _show_lobby() -> void:
	_screen = "lobby"
	_clear()
	var info: Dictionary = Net.lobby
	var code := str(info.get("code", Net.lobby_code()))
	var is_public := bool(info.get("public", false))
	var players: Array = info.get("players", [])
	var settings: Dictionary = info.get("settings", {"track": "circuit_1", "bots": false, "difficulty": "normal"})
	var host := Net.is_host()

	if is_public:
		_box.add_child(_label("Public match", 40, Color.WHITE))
	else:
		_box.add_child(_label("Private lobby code", 22, MUTED))
		var code_row := _row()
		var code_label := _label(code, 64, ACCENT)
		code_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		code_row.add_child(code_label)
		var copy := _button("Copy", func():
			DisplayServer.clipboard_set(code)
			if is_instance_valid(_status):
				_status.text = "Code copied. Send it to your friends.", code_row)
		copy.size_flags_horizontal = Control.SIZE_SHRINK_END
		copy.custom_minimum_size = Vector2(140, 76)

	# Race settings: the host can change them, everyone else sees them.
	var send_settings := func(changes: Dictionary):
		var s := settings.duplicate()
		s.merge(changes, true)
		Net.send({"t": "settings", "track": s.track, "bots": s.bots, "difficulty": s.difficulty})
	if host:
		_box.add_child(_picker(Tracks.ids(), Tracks.name_of, str(settings.track), func(v): send_settings.call({"track": v})))
		_box.add_child(_picker(Game.DIFFICULTIES, func(v): return Game.DIFFICULTY_NAMES[v], str(settings.difficulty), func(v): send_settings.call({"difficulty": v})))
		var bots := CheckButton.new()
		bots.text = "Fill empty spots with computer karts"
		bots.button_pressed = bool(settings.bots)
		bots.toggled.connect(func(on): send_settings.call({"bots": on}))
		_box.add_child(bots)
	else:
		_box.add_child(_label("%s  -  %s" % [Tracks.name_of(str(settings.track)), Game.DIFFICULTY_NAMES.get(str(settings.difficulty), "Normal")], 26, Color.WHITE))
		_box.add_child(_label("Computer karts: %s" % ("on" if settings.bots else "off"), 22, MUTED))

	_box.add_child(_label("Players  %d/%d" % [players.size(), int(info.get("max", 6))], 22, MUTED))
	for p in players:
		var row := _row()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(22, 22)
		dot.color = Color.html(str(p.get("color", "e62633")))
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(dot)
		var tag := str(p.get("name", "Racer"))
		if str(p.get("id", "")) == str(info.get("host", "")):
			tag += "  (host)"
		if str(p.get("id", "")) == Net.my_id:
			tag += "  (you)"
		var name_label := _label(tag, 26, Color.WHITE)
		name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		row.add_child(name_label)

	_autostart_label = null
	_autostart_at = 0.0
	if str(info.get("phase", "")) == "racing":
		_box.add_child(_label("A race is still going. Hang on...", 22, MUTED))
	elif is_public and int(info.get("autostart_in", -1)) >= 0:
		_autostart_at = Time.get_ticks_msec() / 1000.0 + int(info.autostart_in)
		_autostart_label = _label("", 24, ACCENT)
		_box.add_child(_autostart_label)
	elif is_public:
		_box.add_child(_label("Waiting for another player...", 22, MUTED))
	if host and str(info.get("phase", "")) != "racing":
		_button("Start race", func(): Net.send({"t": "start"}))
	elif not host and not is_public:
		_box.add_child(_label("Waiting for the host to start...", 22, MUTED))
	_status = _label("", 22, ACCENT)
	_box.add_child(_status)
	_button("Leave lobby", func():
		Net.leave()
		_show_multiplayer())


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


func _quick_match() -> void:
	if _busy:
		return
	_busy = true
	_status.text = "Finding a race..."
	var res: Dictionary = await Net.quick_match(Game.display_name())
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
	center.theme = UiTheme.make()
	layer.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	center.add_child(outer)
	_title = _label("KART RACER", 72, Color.WHITE)
	_title.label_settings.outline_size = 16
	_title.label_settings.outline_color = Color(0.1, 0.2, 0.5)
	outer.add_child(_title)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.15, 0.82)
	sb.set_corner_radius_all(20)
	sb.set_content_margin_all(24)
	panel.add_theme_stylebox_override("panel", sb)
	outer.add_child(panel)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(_scroll)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 10)
	_box.custom_minimum_size = Vector2(560, 0)
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_box)


## Sizes the panel to its content, scrolling if it's taller than the screen.
func _fit() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var screen := get_viewport().get_visible_rect().size
	_title.visible = screen.y > 600
	var room := screen.y - (150.0 if _title.visible else 60.0)
	_scroll.custom_minimum_size = Vector2(560, minf(_box.get_combined_minimum_size().y, room))




func _clear() -> void:
	_preview_holder = null
	_preview_kart = null
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	_fit()


func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_box.add_child(row)
	return row


func _button(text: String, action: Callable, parent: Control = null) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 72)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(func(): Sfx.play("click"))
	b.pressed.connect(action)
	(parent if parent else _box).add_child(b)
	return b


## [<] value [>] chooser. names maps a value to its display text.
func _picker(values: Array, names: Callable, current, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var index := [maxi(0, values.find(current))]
	var label := _label(str(names.call(values[index[0]])), 28, Color.WHITE)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var step := func(d: int):
		Sfx.play("click")
		index[0] = posmod(index[0] + d, values.size())
		label.text = str(names.call(values[index[0]]))
		on_change.call(values[index[0]])
	for d in [-1, 1]:
		var b := Button.new()
		b.text = "<" if d < 0 else ">"
		b.custom_minimum_size = Vector2(76, 64)
		b.pressed.connect(step.bind(d))
		row.add_child(b)
		if d < 0:
			row.add_child(label)
	return row


func _slider(lo: float, hi: float, step: float, value: float, on_change: Callable) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(0, 44)
	s.value_changed.connect(on_change)
	return s


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
