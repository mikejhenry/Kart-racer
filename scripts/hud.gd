extends CanvasLayer
## Race HUD: lap and timer, position, held item, announcements, pause button
## and the end-of-race / pause panels.

const ITEM_NAMES := {"nitro": "NITRO", "missile": "MISSILE", "oil": "OIL SLICK"}

signal pause_pressed

var _lap_label: Label
var _place_label: Label
var _item_label: Label
var _center_label: Label
var _warning_label: Label
var _rotate_label: Label
var _panel_root: Control
var _flash_time := 0.0


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_lap_label = _make_label(36, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_TOP)
	_lap_label.offset_left = 110.0
	_place_label = _make_label(64, HORIZONTAL_ALIGNMENT_RIGHT, VERTICAL_ALIGNMENT_TOP)
	_item_label = _make_label(38, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_TOP)
	_item_label.label_settings.font_color = Color(1.0, 0.9, 0.3)
	_center_label = _make_label(120, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	_warning_label = _make_label(56, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_TOP)
	_warning_label.offset_top = 110.0
	_warning_label.label_settings.font_color = Color(1.0, 0.35, 0.25)
	_rotate_label = _make_label(34, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	_rotate_label.offset_top = 220.0
	_rotate_label.text = "Turn your phone sideways for a better view"

	var pause := Button.new()
	pause.text = "II"
	pause.focus_mode = Control.FOCUS_NONE
	pause.custom_minimum_size = Vector2(76, 76)
	pause.add_theme_font_size_override("font_size", 34)
	pause.position = Vector2(20, 16)
	pause.pressed.connect(func(): pause_pressed.emit())
	add_child(pause)


func _unhandled_input(event: InputEvent) -> void:
	# Handled here because the HUD keeps running while the game is paused.
	if event.is_action_pressed("pause"):
		pause_pressed.emit()


func _process(delta: float) -> void:
	if _flash_time > 0.0:
		_flash_time -= delta
		if _flash_time <= 0.0:
			_center_label.text = ""
	var screen := get_viewport().get_visible_rect().size
	_rotate_label.visible = screen.y > screen.x


## place <= 0 hides the position (time trial).
func set_status(lap: int, total_laps: int, place: int, time: float) -> void:
	_lap_label.text = "LAP %d/%d\n%s" % [lap, total_laps, format_time(time)]
	_place_label.text = ordinal(place) if place > 0 else ""


func set_item(item: String) -> void:
	_item_label.text = "[ %s ]" % ITEM_NAMES[item] if ITEM_NAMES.has(item) else ""


func flash(text: String, duration: float) -> void:
	_center_label.text = text
	_flash_time = duration


func set_wrong_way(on: bool) -> void:
	_warning_label.text = "WRONG WAY!" if on else ""


func has_panel() -> bool:
	return _panel_root != null


func hide_panel() -> void:
	if _panel_root:
		_panel_root.queue_free()
		_panel_root = null


## Shows a centred panel. buttons is a list of [label, Callable].
func show_panel(title: String, lines: Array, buttons: Array) -> void:
	hide_panel()
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_root = center

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.1, 0.88)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(30)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	box.add_child(_text(title, 46, Color.WHITE))
	for line in lines:
		var text := str(line)
		var color := Color(1.0, 0.85, 0.3) if text.begins_with("★") else Color(0.9, 0.92, 1.0)
		box.add_child(_text(text.trim_prefix("★"), 26, color))

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	box.add_child(row)
	var first: Button = null
	for b in buttons:
		var btn := Button.new()
		btn.text = b[0]
		btn.custom_minimum_size = Vector2(220, 72)
		btn.add_theme_font_size_override("font_size", 28)
		btn.pressed.connect(b[1])
		row.add_child(btn)
		if first == null:
			first = btn
	if first:
		first.grab_focus()


func _make_label(size: int, h: HorizontalAlignment, v: VerticalAlignment) -> Label:
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font_size = size
	ls.outline_size = maxi(4, int(size / 6.0))
	ls.outline_color = Color(0, 0, 0, 0.85)
	l.label_settings = ls
	l.horizontal_alignment = h
	l.vertical_alignment = v
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.offset_left = 24.0
	l.offset_top = 16.0
	l.offset_right = -24.0
	l.offset_bottom = -16.0
	return l


func _text(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var ls := LabelSettings.new()
	ls.font_size = size
	ls.font_color = color
	l.label_settings = ls
	return l


static func ordinal(n: int) -> String:
	if n % 100 in [11, 12, 13]:
		return "%dth" % n
	match n % 10:
		1:
			return "%dst" % n
		2:
			return "%dnd" % n
		3:
			return "%drd" % n
	return "%dth" % n


static func format_time(t: float) -> String:
	var minutes := int(t / 60.0)
	var seconds := t - minutes * 60.0
	return "%d:%05.2f" % [minutes, seconds]
