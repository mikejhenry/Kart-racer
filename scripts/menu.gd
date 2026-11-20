extends Node3D
## Start screen: pick a mode, track and difficulty, set your name and kart,
## browse records, change settings, and create or join online lobbies.
## The chosen track slowly orbits in the background behind a dark scrim.
## Look: "Pro Sport" (see ui_theme.gd). The main menu and the lobby are
## full-screen layouts; the other screens use a single centred panel.

const Track := preload("res://scripts/track.gd")
const Tracks := preload("res://scripts/tracks.gd")
const Kart := preload("res://scripts/kart.gd")
const World := preload("res://scripts/world.gd")
const Hud := preload("res://scripts/hud.gd")
const UiTheme := preload("res://scripts/ui_theme.gd")

const MUTED := UiTheme.MUTED
const ACCENT := Color("#FF7468")      ## Highlights (your best, your row) on dark
const WARN := UiTheme.WARN
const GHOST_NAMES := {"mine": "Your best run", "record": "World record", "off": "No ghost"}

var _camera: Camera3D
var _bg: Node3D                ## Background track, sky and lights
var _bg_track                  ## The background Track node
var _bg_track_id := ""
var _track_focus := false       ## Panel moves left and the track is framed on the right
var _focus := 0.0               ## Eases towards _track_focus
var _ui_root: Control           ## Centred panel (most screens)
var _page: Control              ## Full-screen layout (main menu, lobby)
var _scrim: TextureRect
var _angle := 0.0
var _center := Vector3.ZERO
var _radius := 190.0
var _box: VBoxContainer
var _scroll: ScrollContainer
var _footer: HBoxContainer       ## Buttons pinned below the scrolling area
var _keep_scroll := -1
var _status: Label
var _screen := ""
var _busy := false
var _preview_kart
var _preview_holder: Node3D
var _autostart_label: Label
var _autostart_at := 0.0
var _voice_icons := {}         ## player id -> VoiceIcon
var _voice_status: Label
var _voice_ui_joined := false
var _name_edit: LineEdit        ## Garage name box, saved when leaving the screen


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.far = 1500.0
	add_child(_camera)
	_camera.make_current()
	_show_track(Game.track_id)

	_build_ui()
	Net.joined.connect(func(_id): _show_lobby())
	Net.lobby_updated.connect(_on_lobby_updated)
	Net.error.connect(_on_net_error)
	Net.disconnected.connect(_on_disconnected)
	Voice.changed.connect(_update_voice)
	get_viewport().size_changed.connect(_on_resized)
	Sfx.play_music("music_menu")
	if Net.in_lobby():
		_show_lobby()
	else:
		_show_main()


func _on_resized() -> void:
	# The full-screen layouts switch between side-by-side and stacked.
	if _screen == "main":
		_show_main()
	elif _screen == "lobby":
		_show_lobby()
	else:
		_fit()


## Shows a track (with its sky and lighting) orbiting behind the menu.
## Called whenever a screen is about a particular track.
func _show_track(id: String) -> void:
	var def := Tracks.get_track(id)
	if def.id == _bg_track_id:
		return
	_bg_track_id = def.id
	if _bg and is_instance_valid(_bg):
		remove_child(_bg)   # out of the scene now, so only one sky is active
		_bg.queue_free()
	_bg = Node3D.new()
	add_child(_bg)
	World.add_environment(_bg, Tracks.THEMES[def.theme])
	# The menu camera sits much further back than in a race: thin the fog
	# so the whole track stays clear.
	for n in _bg.get_children():
		if n is WorldEnvironment:
			n.environment.fog_density = 0.0007
	_bg_track = Track.new()
	_bg_track.track_id = def.id
	_bg.add_child(_bg_track)
	_bg_track.build()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in def.points:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	_center = Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.y + hi.y) * 0.5)
	_radius = maxf(hi.x - lo.x, hi.y - lo.y) * 0.75 + 40.0


func _process(delta: float) -> void:
	_angle += delta * 0.08
	# On track screens on a wide screen, the panel slides left and the camera
	# rises and shifts so the whole track sits in the free space on the right.
	var screen := get_viewport().get_visible_rect().size
	var aspect := screen.x / maxf(screen.y, 1.0)
	var panel_w: float = _ui_root.get_child(0).get_combined_minimum_size().x if _ui_root else INF
	var want := 1.0 if _track_focus and _ui_root.visible and screen.x * 0.5 >= panel_w + 24.0 else 0.0
	_focus = move_toward(_focus, want, delta * 2.5)
	var e := _focus * _focus * (3.0 - 2.0 * _focus)
	var height := lerpf(0.45, 0.85, e)
	var dist := lerpf(1.0, 0.85, e)
	_camera.position = _center + Vector3(cos(_angle) * _radius * dist, _radius * height, sin(_angle) * _radius * dist)
	_camera.look_at(_center, Vector3.UP)
	var reach := _camera.position.distance_to(_center) * tan(deg_to_rad(_camera.fov * 0.5)) * aspect
	_camera.h_offset = -0.5 * reach * e
	if _ui_root:
		_ui_root.anchor_right = lerpf(1.0, 0.5, e)
		_ui_root.offset_right = 0.0
	if _screen == "settings":
		_update_tilt_meter()
	if _preview_holder and is_instance_valid(_preview_holder):
		_preview_holder.rotate_y(delta * 0.8)
	if _autostart_label and is_instance_valid(_autostart_label) and _autostart_at > 0.0:
		var left := int(ceil(_autostart_at - Time.get_ticks_msec() / 1000.0))
		_autostart_label.text = "Starting in %d s..." % maxi(left, 0) if left > 0 else "Starting..."


# --- Screens ----------------------------------------------------------------

func _wide() -> bool:
	var screen := get_viewport().get_visible_rect().size
	return screen.x >= screen.y * 1.25


## Main menu: numbered mode list on the left, the selected track on the right.
func _show_main() -> void:
	_screen = "main"
	_clear()
	_show_track(Game.track_id)
	var root := _use_page(0.94, 0.45)
	var cols := BoxContainer.new()
	cols.vertical = not _wide()
	cols.add_theme_constant_override("separation", 30)
	root.add_child(cols)

	# Left: logo and the mode list.
	var nav := VBoxContainer.new()
	nav.add_theme_constant_override("separation", 6)
	nav.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav.size_flags_stretch_ratio = 1.1
	cols.add_child(nav)
	var logo := HBoxContainer.new()
	logo.add_theme_constant_override("separation", 20)
	var mark := Slant.new()
	mark.color = UiTheme.ACCENT
	mark.custom_minimum_size = Vector2(48, 48)
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	logo.add_child(mark)
	logo.add_child(_lbl("KART RACER", 64, UiTheme.TEXT, "display"))
	nav.add_child(logo)
	nav.add_child(_spacer(8))

	var diff_name: String = Game.DIFFICULTY_NAMES.get(Game.difficulty, "Normal")
	var best := Game.best_time(Game.track_id)
	nav.add_child(_mode_row("01", "GRAND PRIX", "5 CPU · %s" % diff_name, true, func(): _show_setup("grand_prix")))
	nav.add_child(_mode_row("02", "TIME TRIAL", "PB %s" % Hud.format_time(best) if best > 0.0 else "No time yet", false, func(): _show_setup("time_trial")))
	var online := Net.is_configured()
	var multi := _mode_row("03", "MULTIPLAYER", "Online" if online else "Not set up", false, _show_multiplayer)
	multi.disabled = not online
	nav.add_child(multi)
	nav.add_child(_mode_row("04", "GARAGE", "", false, _show_garage))
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	nav.add_child(fill)
	var more := HBoxContainer.new()
	more.add_theme_constant_override("separation", 14)
	nav.add_child(more)
	var board := _button("Records", func(): _show_leaderboard(Game.track_id), more)
	board.disabled = not online
	_button("Settings", _show_settings, more)
	for b in more.get_children():
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.custom_minimum_size = Vector2(0, 80)
	var session := Game.recent_session()
	if online and not session.is_empty() and not Net.in_lobby():
		var rejoin := _button("Rejoin %s" % session.code, func():
			_show_multiplayer("Rejoining...")
			Net.resume(session, Game.display_name()), more)
		rejoin.theme_type_variation = "AccentButton"
		rejoin.add_theme_font_size_override("font_size", 30)
		rejoin.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	# Right: the selected track.
	cols.add_child(_track_panel())


## The selected-track card on the main menu.
func _track_panel() -> Control:
	var ids := Tracks.ids()
	var def := Tracks.get_track(Game.track_id)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiTheme.panel(Color(0.043, 0.055, 0.078, 0.72), Color(1, 1, 1, 0.12), 18, 30))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	card.add_child(box)

	var top := HBoxContainer.new()
	var count := _lbl("TRACK %d OF %d" % [ids.find(def.id) + 1, ids.size()], 22, MUTED, "bold")
	count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(count)
	var chip := Button.new()
	chip.custom_minimum_size = Vector2(0, 80)
	chip.pressed.connect(func(): Sfx.play("click"))
	chip.pressed.connect(_show_garage)
	var chip_row := HBoxContainer.new()
	chip_row.add_theme_constant_override("separation", 14)
	chip_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	chip_row.offset_left = 12
	chip_row.offset_right = -22
	var dot := Dot.new()
	dot.color = Game.color()
	dot.custom_minimum_size = Vector2(54, 54)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip_row.add_child(dot)
	var who := _lbl(Game.display_name(), 26, UiTheme.TEXT)
	chip_row.add_child(who)
	chip.custom_minimum_size.x = 54 + 14 + 12 + 22 + who.get_minimum_size().x + 10
	chip.add_child(chip_row)
	top.add_child(chip)
	box.add_child(top)

	var mid := HBoxContainer.new()
	mid.add_theme_constant_override("separation", 26)
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var outline := TrackOutline.new()
	outline.points = _bg_track.outline()
	outline.custom_minimum_size = Vector2(220, 220)
	outline.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mid.add_child(outline)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 6)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_child(_lbl(str(def.name).to_upper(), 70, UiTheme.TEXT, "display"))
	var blurb := _lbl(str(def.get("blurb", "")), 24, MUTED)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.custom_minimum_size.x = 260
	info.add_child(blurb)
	var stats := GridContainer.new()
	stats.columns = 2
	stats.add_theme_constant_override("h_separation", 40)
	stats.add_theme_constant_override("v_separation", 0)
	stats.add_child(_lbl("LENGTH", 20, UiTheme.DIM, "bold"))
	stats.add_child(_lbl("YOUR BEST", 20, UiTheme.DIM, "bold"))
	stats.add_child(_lbl("%d m" % int(round(_bg_track.length)), 40, UiTheme.TEXT, "number"))
	var best := Game.best_time(def.id)
	stats.add_child(_lbl(Hud.format_time(best) if best > 0.0 else "—", 40, UiTheme.TEXT, "number"))
	info.add_child(stats)
	mid.add_child(info)
	box.add_child(mid)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 14)
	for d in [-1, 1]:
		var arrow := _icon_button("<" if d < 0 else ">", "Previous track" if d < 0 else "Next track", func():
			var i := posmod(ids.find(Game.track_id) + d, ids.size())
			Game.set_value("track_id", ids[i])
			_show_main())
		bottom.add_child(arrow)
	var race := _button("RACE", func(): Game.start_race("grand_prix"), bottom)
	race.theme_type_variation = "LightButton"
	race.add_theme_font_size_override("font_size", 42)
	race.custom_minimum_size = Vector2(0, 88)
	box.add_child(bottom)
	return card


## One numbered entry of the main menu list.
func _mode_row(num: String, title: String, detail: String, primary: bool, action: Callable) -> Button:
	var b := Button.new()
	b.theme_type_variation = "FlatButton"
	b.custom_minimum_size = Vector2(0, 92)
	if primary:
		var sb := StyleBoxFlat.new()
		sb.bg_color = UiTheme.ACCENT
		sb.skew = Vector2(0.12, 0)
		sb.expand_margin_left = 10
		for state in ["normal", "hover", "focus"]:
			b.add_theme_stylebox_override(state, sb)
		var pressed_sb := sb.duplicate()
		pressed_sb.bg_color = UiTheme.ACCENT.darkened(0.2)
		b.add_theme_stylebox_override("pressed", pressed_sb)
	b.pressed.connect(func(): Sfx.play("click"))
	b.pressed.connect(action)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 28)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 26
	row.offset_right = -34
	var n := _lbl(num, 30, Color(1, 1, 1, 0.85) if primary else UiTheme.DIM, "number")
	row.add_child(n)
	var t := _lbl(title, 54 if primary else 50, UiTheme.TEXT, "display")
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(t)
	if detail != "":
		row.add_child(_lbl(detail, 24, Color.WHITE if primary else MUTED))
	b.add_child(row)
	return b


## Track (and difficulty or ghost) choice before a Grand Prix or Time Trial.
func _show_setup(mode: String) -> void:
	_screen = "setup"
	_clear()
	_show_track(Game.track_id)
	_track_focus = true
	var gp := mode == "grand_prix"
	_box.add_child(_heading("GRAND PRIX" if gp else "TIME TRIAL"))
	_box.add_child(_caption("TRACK"))
	var blurb := _label(str(Tracks.get_track(Game.track_id).get("blurb", "")), 22, MUTED)
	var best := _label("", 24, ACCENT)
	var refresh := func():
		blurb.text = str(Tracks.get_track(Game.track_id).get("blurb", ""))
		var t := Game.best_time(Game.track_id)
		best.text = "Your best here: %s" % Hud.format_time(t) if t > 0.0 else "No time set here yet"
	_box.add_child(_picker(Tracks.ids(), Tracks.name_of, Game.track_id, func(v):
		Game.set_value("track_id", v)
		_show_track(v)
		refresh.call()))
	_box.add_child(blurb)
	if gp:
		_box.add_child(_caption("CLASS"))
		_box.add_child(_segmented(Game.DIFFICULTIES, func(v): return str(Game.DIFFICULTY_NAMES[v]).to_upper(), Game.difficulty, true, func(v): Game.set_value("difficulty", v)))
	else:
		_box.add_child(_caption("RACE AGAINST"))
		var ghosts := ["mine", "record", "off"] if Net.is_configured() else ["mine", "off"]
		var current := Game.ghost_mode if Game.ghost_mode in ghosts else "mine"
		_box.add_child(_picker(ghosts, func(v): return GHOST_NAMES[v], current, func(v): Game.set_value("ghost_mode", v)))
		_box.add_child(best)
		refresh.call()
	_footer_button("Back", _show_main).size_flags_stretch_ratio = 0.5
	_footer_button("START", func(): Game.start_race(mode)).theme_type_variation = "AccentButton"


func _show_garage() -> void:
	_screen = "garage"
	_clear()
	_box.add_child(_heading("GARAGE"))
	_box.add_child(_caption("YOUR NAME"))
	var name_edit := LineEdit.new()
	name_edit.text = Game.player_name
	name_edit.max_length = 16
	name_edit.placeholder_text = "Racer"
	name_edit.custom_minimum_size = Vector2(0, 72)
	# Saved as you type, when you press Enter or tap away, and when you
	# leave the screen (on phones the browser's keyboard may not report
	# every keystroke before you tap Back). An empty box keeps the old name.
	var commit := func(text: String):
		if text.strip_edges() != "":
			Game.set_player_name(text)
	name_edit.text_changed.connect(commit)
	name_edit.text_submitted.connect(func(text):
		commit.call(text)
		name_edit.release_focus())
	name_edit.focus_exited.connect(func(): commit.call(name_edit.text))
	_name_edit = name_edit
	_box.add_child(name_edit)

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
	_preview_holder.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	viewport.add_child(_preview_holder)
	_box.add_child(container)
	_rebuild_preview()

	_box.add_child(_caption("KART"))
	_box.add_child(_picker(Kart.STYLES, func(v): return Kart.STYLE_NAMES[v], Game.kart_style, func(v):
		Game.set_value("kart_style", v)
		_rebuild_preview()))
	_box.add_child(_caption("COLOUR"))
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
	_footer_button("Back", _show_main)


func _style_swatches(swatches: Array[Button]) -> void:
	for i in swatches.size():
		var sb := StyleBoxFlat.new()
		sb.bg_color = Game.KART_COLORS[i]
		sb.set_corner_radius_all(11)
		if i == Game.kart_color:
			sb.border_color = Color.WHITE
			sb.set_border_width_all(5)
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
	_box.add_child(_heading("SETTINGS"))
	_box.add_child(_caption("MUSIC"))
	_box.add_child(_slider(0.0, 1.0, 0.05, Game.music_volume, func(v): Game.set_value("music_volume", v)))
	_box.add_child(_caption("SOUND EFFECTS"))
	_box.add_child(_slider(0.0, 1.0, 0.05, Game.sfx_volume, func(v): Game.set_value("sfx_volume", v)))
	var buzz := CheckButton.new()
	buzz.text = "Vibration"
	buzz.button_pressed = Game.vibration
	buzz.toggled.connect(func(on):
		Game.set_value("vibration", on)
		Game.vibrate(80))
	_box.add_child(buzz)

	var smooth := CheckButton.new()
	smooth.text = "Smooth motion"
	smooth.button_pressed = Game.smooth_motion
	smooth.toggled.connect(func(on): Game.set_value("smooth_motion", on))
	_box.add_child(smooth)

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
	_footer_button("Back", _show_main)


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
	_show_track(track)
	_track_focus = true
	_box.add_child(_heading("RECORDS"))
	_box.add_child(_caption("TIME TRIAL · BEST TIMES"))
	_box.add_child(_picker(Tracks.ids(), Tracks.name_of, track, func(v): _show_leaderboard(v)))
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	_box.add_child(list)
	list.add_child(_label("Loading...", 24, MUTED))
	var mine := Game.best_time(track)
	if mine > 0.0:
		_box.add_child(_label("Your best  %s" % Hud.format_time(mine), 24, ACCENT))
	_footer_button("Back", _show_main)

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
		var rank := _lbl("%d" % (i + 1), 34, ACCENT if me else UiTheme.DIM, "display")
		rank.custom_minimum_size = Vector2(56, 0)
		rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var who := _lbl(str(e.get("name", "?")), 28, ACCENT if me else UiTheme.TEXT, "bold")
		who.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var time := _lbl(Hud.format_time(float(e.get("time", 0.0))), 34, ACCENT if me else UiTheme.TEXT, "number")
		row.add_child(rank)
		row.add_child(who)
		row.add_child(time)
		list.add_child(row)
	_fit()


func _show_multiplayer(message: String = "") -> void:
	_screen = "multiplayer"
	_clear()
	_box.add_child(_heading("MULTIPLAYER"))
	_button("QUICK MATCH", _quick_match).theme_type_variation = "AccentButton"
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
	_footer_button("Back", _show_main)


## Lobby: the grid of racers on the left; track card, class, CPU karts and
## voice on the right; Leave and START RACE pinned at the bottom.
func _show_lobby() -> void:
	var keep := -1
	if _screen == "lobby":
		var old := _page.find_child("SettingsScroll", true, false) as ScrollContainer
		if old:
			keep = old.scroll_vertical
	_screen = "lobby"
	_clear()
	var info: Dictionary = Net.lobby
	var code := str(info.get("code", Net.lobby_code()))
	var is_public := bool(info.get("public", false))
	var players: Array = info.get("players", [])
	var max_players := int(info.get("max", 6))
	var phase := str(info.get("phase", ""))
	_voice_icons = {}
	_voice_status = null
	var settings: Dictionary = info.get("settings", {"track": "circuit_1", "bots": false, "difficulty": "normal"})
	var host := Net.is_host()
	_show_track(str(settings.get("track", "circuit_1")))
	var send_settings := func(changes: Dictionary):
		var s := settings.duplicate()
		s.merge(changes, true)
		Net.send({"t": "settings", "track": s.track, "bots": s.bots, "difficulty": s.difficulty})

	var root := _use_page(0.92, 0.7)
	var wide := _wide()
	var cols := BoxContainer.new()
	cols.vertical = not wide
	cols.add_theme_constant_override("separation", 34)
	root.add_child(cols)

	# --- Left: code and the grid ---
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 14)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 0.85
	cols.add_child(left)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", -6)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(_lbl("PUBLIC MATCH" if is_public else "PRIVATE LOBBY", 20, MUTED, "bold"))
	var big := _lbl("QUICK RACE" if is_public else code, 74, UiTheme.TEXT, "display")
	big.label_settings.font_size = 60 if is_public else 74
	titles.add_child(big)
	head.add_child(titles)
	if not is_public:
		var copy := _button("Copy code", func():
			DisplayServer.clipboard_set(code)
			if is_instance_valid(_status):
				_status.text = "Code copied. Send it to your friends.", head)
		copy.size_flags_horizontal = Control.SIZE_SHRINK_END
		copy.size_flags_vertical = Control.SIZE_SHRINK_END
		copy.custom_minimum_size = Vector2(0, 80)
	left.add_child(head)

	var grid_panel := PanelContainer.new()
	grid_panel.add_theme_stylebox_override("panel", UiTheme.panel(Color(0.07, 0.085, 0.11, 0.86), Color(1, 1, 1, 0.1), 15, 10))
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 6)
	grid_panel.add_child(grid)
	left.add_child(grid_panel)
	for i in max_players:
		if i < players.size():
			grid.add_child(_player_row(i + 1, players[i], str(info.get("host", ""))))
		else:
			var open := HBoxContainer.new()
			open.add_theme_constant_override("separation", 18)
			open.custom_minimum_size = Vector2(0, 52)
			var n := _lbl(str(i + 1), 34, UiTheme.DIM, "display")
			n.custom_minimum_size.x = 34
			open.add_child(_pad(n, 14))
			open.add_child(_lbl("OPEN · CPU" if bool(settings.bots) else "OPEN", 24, UiTheme.DIM, "bold"))
			grid.add_child(open)

	# --- Right: settings (scrolls if needed) and the pinned buttons ---
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 14)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	var scroll := ScrollContainer.new()
	scroll.name = "SettingsScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if not wide:
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var sheet := PanelContainer.new()
	sheet.add_theme_stylebox_override("panel", UiTheme.panel(Color(0.07, 0.085, 0.11, 0.86), Color(1, 1, 1, 0.1), 15, 0))
	sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(sheet)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 0)
	sheet.add_child(rows)

	# Track card: outline, name and description between the arrows.
	var card := HBoxContainer.new()
	card.add_theme_constant_override("separation", 18)
	var ids := Tracks.ids()
	var def := Tracks.get_track(str(settings.track))
	if host:
		card.add_child(_icon_button("<", "Previous track", func():
			send_settings.call({"track": ids[posmod(ids.find(def.id) - 1, ids.size())]})))
	var outline := TrackOutline.new()
	outline.points = _bg_track.outline()
	outline.custom_minimum_size = Vector2(150, 150)
	card.add_child(outline)
	var about := VBoxContainer.new()
	about.alignment = BoxContainer.ALIGNMENT_CENTER
	about.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	about.add_theme_constant_override("separation", 0)
	about.add_child(_lbl("TRACK", 20, MUTED, "bold"))
	about.add_child(_lbl(str(def.name).to_upper(), 50, UiTheme.TEXT, "display"))
	var blurb := _lbl(str(def.get("blurb", "")), 22, MUTED)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.custom_minimum_size.x = 200
	about.add_child(blurb)
	card.add_child(about)
	if host:
		card.add_child(_icon_button(">", "Next track", func():
			send_settings.call({"track": ids[posmod(ids.find(def.id) + 1, ids.size())]})))
	rows.add_child(_sheet_row(card, true))

	# Class: Easy / Normal / Hard.
	var class_row := HBoxContainer.new()
	class_row.add_theme_constant_override("separation", 18)
	var class_caption := _lbl("CLASS", 20, MUTED, "bold")
	class_caption.custom_minimum_size.x = 150
	class_row.add_child(class_caption)
	var seg := _segmented(Game.DIFFICULTIES, func(v): return str(Game.DIFFICULTY_NAMES[v]).to_upper(), str(settings.difficulty), host, func(v): send_settings.call({"difficulty": v}))
	seg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	class_row.add_child(seg)
	rows.add_child(_sheet_row(class_row, true))

	# CPU karts.
	var cpu_row := HBoxContainer.new()
	cpu_row.add_theme_constant_override("separation", 18)
	var cpu_caption := _lbl("CPU KARTS", 20, MUTED, "bold")
	cpu_caption.custom_minimum_size.x = 150
	cpu_row.add_child(cpu_caption)
	var cpu_text := _lbl("Fill open spots" if bool(settings.bots) else "Off", 26, UiTheme.TEXT)
	cpu_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cpu_row.add_child(cpu_text)
	if host:
		var bots := CheckButton.new()
		bots.button_pressed = bool(settings.bots)
		bots.custom_minimum_size = Vector2(96, 72)
		bots.toggled.connect(func(on): send_settings.call({"bots": on}))
		cpu_row.add_child(bots)
	rows.add_child(_sheet_row(cpu_row, not is_public))

	# Voice chat (private lobbies).
	if not is_public:
		rows.add_child(_sheet_row(_voice_row(), false))

	# Status line (copied code, autostart countdown, waiting...).
	_autostart_label = null
	_autostart_at = 0.0
	_status = _lbl("", 24, ACCENT)
	if phase == "racing":
		_status.text = "A race is still going. Hang on..."
	elif is_public and int(info.get("autostart_in", -1)) >= 0:
		_autostart_at = Time.get_ticks_msec() / 1000.0 + int(info.autostart_in)
		_autostart_label = _status
	elif is_public:
		_status.text = "Waiting for another player..."
	right.add_child(_status)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 14)
	right.add_child(footer)
	var leave := _button("Leave", func():
		Net.leave()
		_show_multiplayer(), footer)
	leave.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	leave.custom_minimum_size = Vector2(170, 100)
	if host and phase != "racing":
		var start := _button("START RACE", func(): Net.send({"t": "start"}), footer)
		start.theme_type_variation = "AccentButton"
		start.add_theme_font_size_override("font_size", 46)
		start.custom_minimum_size = Vector2(0, 100)
	elif not is_public and phase != "racing":
		var wait := _lbl("Waiting for the host to start...", 24, MUTED)
		wait.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		wait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		footer.add_child(wait)
	if keep >= 0:
		_restore_scroll(scroll, keep)
	_update_voice()


func _restore_scroll(scroll: ScrollContainer, value: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(scroll):
		scroll.scroll_vertical = value


## One racer in the lobby grid: number, colour bar, name, tags, voice icon.
func _player_row(n: int, p: Dictionary, host_id: String) -> Control:
	var id := str(p.get("id", ""))
	var me := id == Net.my_id
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", UiTheme.panel(Color(1, 1, 1, 0.09 if me else 0.06), Color(0, 0, 0, 0), 8, 0))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 18)
	h.custom_minimum_size = Vector2(0, 62)
	row.add_child(h)
	var num := _lbl(str(n), 34, UiTheme.DIM, "display")
	num.custom_minimum_size.x = 34
	h.add_child(_pad(num, 14))
	var bar := ColorRect.new()
	bar.color = Color.html(str(p.get("color", "e62633")))
	bar.custom_minimum_size = Vector2(11, 40)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(bar)
	var name_label := _lbl(str(p.get("name", "Racer")).to_upper(), 28, UiTheme.TEXT, "bold")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	h.add_child(name_label)
	if id == host_id:
		var pill := PanelContainer.new()
		var psb := UiTheme.panel(UiTheme.TEXT, Color(0, 0, 0, 0), 5, 0)
		psb.content_margin_left = 10
		psb.content_margin_right = 10
		pill.add_theme_stylebox_override("panel", psb)
		pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pill.add_child(_lbl("HOST", 20, UiTheme.BG, "bold"))
		h.add_child(pill)
	if me:
		h.add_child(_lbl("YOU", 20, MUTED, "bold"))
	var icon := VoiceIcon.new()
	icon.custom_minimum_size = Vector2(34, 34)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(icon)
	h.add_child(_spacer_w(6))
	_voice_icons[id] = icon
	return row


## Voice chat controls for private lobbies.
func _voice_row() -> Control:
	_voice_ui_joined = Voice.joined
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	var caption := _lbl("VOICE", 20, MUTED, "bold")
	caption.custom_minimum_size.x = 150
	row.add_child(caption)
	_voice_status = _lbl("", 24, UiTheme.TEXT)
	_voice_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_voice_status.custom_minimum_size.x = 160
	row.add_child(_voice_status)
	if not Voice.available:
		return row
	if not Voice.joined:
		var join := _button("Join", func():
			Voice.join()
			_show_lobby(), row)
		join.size_flags_horizontal = Control.SIZE_SHRINK_END
		join.custom_minimum_size = Vector2(130, 76)
	else:
		var mute := _button("Unmute" if Voice.muted else "Mute", func():
			Voice.set_muted(not Voice.muted)
			_show_lobby(), row)
		mute.size_flags_horizontal = Control.SIZE_SHRINK_END
		mute.custom_minimum_size = Vector2(130, 76)
		var off := _button("Leave", func():
			Voice.leave()
			_show_lobby(), row)
		off.size_flags_horizontal = Control.SIZE_SHRINK_END
		off.custom_minimum_size = Vector2(120, 76)
	return row


func _update_voice() -> void:
	if _screen != "lobby":
		return
	if Voice.joined != _voice_ui_joined and not bool(Net.lobby.get("public", false)):
		_show_lobby()   # e.g. the microphone was refused
		return
	for id in _voice_icons:
		var icon = _voice_icons[id]
		if not is_instance_valid(icon):
			continue
		var state := 0
		if Voice.joined and Voice.in_voice(id):
			state = 2 if Voice.is_talking(id) else 1
		if icon.state != state:
			icon.state = state
			icon.queue_redraw()
	if _voice_status and is_instance_valid(_voice_status):
		var text := ""
		if not Voice.available:
			text = "Works in the browser version"
		elif Voice.error != "":
			text = Voice.error
		elif Voice.joined and not Voice.mic_ready:
			text = "Starting your mic..."
		elif Voice.joined:
			text = "%s · %d connected" % ["Muted" if Voice.muted else "Mic on", Voice.connected_count()]
		else:
			text = "Talk while you race"
		if _voice_status.text != text:
			_voice_status.text = text


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
	var theme := UiTheme.make()

	# Dark scrim over the 3D background: heavier on the left where the text is.
	_scrim = TextureRect.new()
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scrim.stretch_mode = TextureRect.STRETCH_SCALE
	layer.add_child(_scrim)
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_set_scrim(0.85, 0.5)

	var center := CenterContainer.new()
	center.theme = theme
	layer.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root = center

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel(UiTheme.PANEL, Color(1, 1, 1, 0.12), 18, 34))
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_scroll)
	_footer = HBoxContainer.new()
	_footer.add_theme_constant_override("separation", 14)
	_footer.visible = false
	column.add_child(_footer)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 12)
	_box.custom_minimum_size = Vector2(580, 0)
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_box)

	_page = MarginContainer.new()
	_page.theme = theme
	_page.visible = false
	layer.add_child(_page)
	_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _set_scrim(left: float, right: float) -> void:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	g.colors = PackedColorArray([Color(UiTheme.BG, left), Color(UiTheme.BG, lerpf(left, right, 0.6)), Color(UiTheme.BG, right)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 256
	tex.height = 4
	_scrim.texture = tex


## Switches to a full-screen layout. Returns the container to fill. The
## margins keep clear of notches and rounded corners.
func _use_page(scrim_left: float, scrim_right: float) -> Container:
	_ui_root.visible = false
	_page.visible = true
	_set_scrim(scrim_left, scrim_right)
	var screen := get_viewport().get_visible_rect().size
	var safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	var inset := 0.0
	if win.x > 0 and safe.size.x > 0:
		inset = maxf(safe.position.x, win.x - safe.end.x) * screen.x / win.x
	var m := 40
	_page.add_theme_constant_override("margin_left", int(m + inset))
	_page.add_theme_constant_override("margin_right", int(m + inset))
	_page.add_theme_constant_override("margin_top", m)
	_page.add_theme_constant_override("margin_bottom", m)
	if _wide():
		return _page
	# Stacked (portrait): let it scroll.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_page.add_child(scroll)
	var inner := MarginContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner)
	return inner


## Sizes the panel to its content, scrolling if it's taller than the screen.
func _fit() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var screen := get_viewport().get_visible_rect().size
	var room := screen.y - 110.0
	if _footer.visible:
		room -= _footer.get_combined_minimum_size().y + 14.0
	_scroll.custom_minimum_size = Vector2(580, minf(_box.get_combined_minimum_size().y, room))
	if _keep_scroll >= 0:
		await get_tree().process_frame
		_scroll.scroll_vertical = _keep_scroll
		_keep_scroll = -1


func _clear() -> void:
	if _name_edit and is_instance_valid(_name_edit):
		if _name_edit.text.strip_edges() != "":
			Game.set_player_name(_name_edit.text)
		_name_edit = null
	_preview_holder = null
	_preview_kart = null
	_status = null
	_autostart_label = null
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	for c in _footer.get_children():
		_footer.remove_child(c)
		c.queue_free()
	for c in _page.get_children():
		_page.remove_child(c)
		c.queue_free()
	_page.visible = false
	_ui_root.visible = true
	_set_scrim(0.85, 0.5)
	_footer.visible = false
	_track_focus = false
	_fit()


## A button in the bar below the scrolling area, so it's always on screen.
func _footer_button(text: String, action: Callable) -> Button:
	_footer.visible = true
	var b := _button(text, action, _footer)
	b.custom_minimum_size = Vector2(0, 88)
	return b


func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_box.add_child(row)
	return row


func _button(text: String, action: Callable, parent: Control = null) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 80)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(func(): Sfx.play("click"))
	b.pressed.connect(action)
	(parent if parent else _box).add_child(b)
	return b


## Square arrow button.
func _icon_button(glyph: String, label: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = glyph
	b.tooltip_text = label
	b.custom_minimum_size = Vector2(88, 88)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_override("font", UiTheme.DISPLAY_FONT)
	b.add_theme_font_size_override("font_size", 40)
	b.pressed.connect(func(): Sfx.play("click"))
	b.pressed.connect(action)
	return b


## [<] value [>] chooser. names maps a value to its display text.
func _picker(values: Array, names: Callable, current, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var index := [maxi(0, values.find(current))]
	var label := _lbl(str(names.call(values[index[0]])).to_upper(), 40, UiTheme.TEXT, "display")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var step := func(d: int):
		index[0] = posmod(index[0] + d, values.size())
		label.text = str(names.call(values[index[0]])).to_upper()
		on_change.call(values[index[0]])
	row.add_child(_icon_button("<", "Previous", step.bind(-1)))
	row.add_child(label)
	row.add_child(_icon_button(">", "Next", step.bind(1)))
	return row


## Segmented choice (e.g. EASY | NORMAL | HARD). The chosen one is light.
## When not editable, only the chosen value is lit and nothing can be pressed.
func _segmented(values: Array, names: Callable, current, editable: bool, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var buttons: Array[Button] = []
	var paint := func(chosen):
		for i in buttons.size():
			var on: bool = values[i] == chosen
			buttons[i].theme_type_variation = "LightButton" if on else ""
			buttons[i].add_theme_font_override("font", UiTheme.DISPLAY_FONT)
			buttons[i].add_theme_font_size_override("font_size", 34)
	for v in values:
		var b := Button.new()
		b.text = str(names.call(v))
		b.custom_minimum_size = Vector2(0, 80)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = not editable and v != current
		if not editable:
			b.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func():
			Sfx.play("click")
			paint.call(v)
			on_change.call(v))
		buttons.append(b)
		row.add_child(b)
	paint.call(current)
	return row


## A row of the lobby settings sheet, with a divider below it.
func _sheet_row(content: Control, divider: bool) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 24)
	m.add_theme_constant_override("margin_right", 16)
	m.add_theme_constant_override("margin_top", 14)
	m.add_theme_constant_override("margin_bottom", 14)
	m.add_child(content)
	box.add_child(m)
	if divider:
		var line := ColorRect.new()
		line.color = Color(1, 1, 1, 0.08)
		line.custom_minimum_size = Vector2(0, 2)
		box.add_child(line)
	return box


func _slider(lo: float, hi: float, step: float, value: float, on_change: Callable) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(0, 52)
	s.value_changed.connect(on_change)
	return s


## Centred, wrapping body text.
func _label(text: String, size: int, color: Color) -> Label:
	var l := _lbl(text, size, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 560   # measure wrapped height at panel width
	return l


## Left-aligned single-line label in one of the theme's type styles.
func _lbl(text: String, size: int, color: Color, kind: String = "text") -> Label:
	var l := Label.new()
	l.text = text
	l.label_settings = UiTheme.label_settings(size, color, kind)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _heading(text: String) -> Label:
	return _lbl(text, 64, UiTheme.TEXT, "display")


## Small spaced-out caption above a control (TRACK, CLASS, ...).
func _caption(text: String) -> Label:
	var l := _lbl(text, 20, MUTED, "bold")
	return l


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _spacer_w(w: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, 0)
	return c


func _pad(c: Control, left: int) -> Control:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", left)
	m.add_child(c)
	return m


# --- Small drawn pieces -----------------------------------------------------

## The logo mark: a slanted block.
class Slant extends Control:
	var color := Color.RED

	func _draw() -> void:
		var k := size.y * 0.25
		draw_colored_polygon(PackedVector2Array([Vector2(k, 0), Vector2(size.x, 0), Vector2(size.x - k, size.y), Vector2(0, size.y)]), color)


## A filled circle (kart colour chip).
class Dot extends Control:
	var color := Color.WHITE

	func _draw() -> void:
		draw_circle(size * 0.5, minf(size.x, size.y) * 0.5, color, true, -1.0, true)


## Track outline seen from above, with the start line marked.
class TrackOutline extends Control:
	var points := PackedVector2Array()

	func _draw() -> void:
		if points.size() < 3:
			return
		var lo := points[0]
		var hi := points[0]
		for p in points:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		var span := hi - lo
		var pad := 10.0
		var s := minf((size.x - pad * 2) / maxf(span.x, 1.0), (size.y - pad * 2) / maxf(span.y, 1.0))
		var off := (size - span * s) * 0.5
		var pts := PackedVector2Array()
		for p in points:
			pts.append((p - lo) * s + off)
		pts.append(pts[0])
		draw_polyline(pts, UiTheme.TEXT, 6.0, true)
		draw_circle(pts[0], 9.0, UiTheme.ACCENT, true, -1.0, true)


## Voice state next to a name: nothing, a mic (in voice) or green bars (talking).
class VoiceIcon extends Control:
	var state := 0

	func _draw() -> void:
		var c := size * 0.5
		if state == 2:
			var hs := [0.25, 0.75, 0.55, 0.2]
			for i in 4:
				var x := c.x + (i - 1.5) * 8.0
				var h: float = size.y * hs[i]
				draw_line(Vector2(x, c.y - h * 0.5), Vector2(x, c.y + h * 0.5), UiTheme.GOOD, 5.0, true)
		elif state == 1:
			var col := UiTheme.MUTED
			draw_rect(Rect2(c.x - 5, 3, 10, 18), col, false, 3.0, true)
			draw_arc(Vector2(c.x, 14), 11.0, 0.0, PI, 12, col, 3.0, true)
			draw_line(Vector2(c.x, 25), Vector2(c.x, 31), col, 3.0, true)
