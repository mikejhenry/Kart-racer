extends CanvasLayer
## Race HUD: lap, position, held item, countdown/announcements and results.

const ITEM_NAMES := {"nitro": "NITRO", "missile": "MISSILE", "oil": "OIL SLICK"}

var _lap_label: Label
var _place_label: Label
var _item_label: Label
var _center_label: Label
var _warning_label: Label
var _rotate_label: Label
var _flash_time := 0.0


func _ready() -> void:
	layer = 10
	_lap_label = _make_label(40, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_TOP)
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


func _process(delta: float) -> void:
	if _flash_time > 0.0:
		_flash_time -= delta
		if _flash_time <= 0.0:
			_center_label.text = ""
	var screen := get_viewport().get_visible_rect().size
	_rotate_label.visible = screen.y > screen.x


func set_status(lap: int, total_laps: int, place: int) -> void:
	_lap_label.text = "LAP %d/%d" % [lap, total_laps]
	_place_label.text = ordinal(place)


func set_item(item: String) -> void:
	_item_label.text = "[ %s ]" % ITEM_NAMES[item] if ITEM_NAMES.has(item) else ""


func flash(text: String, duration: float) -> void:
	_center_label.text = text
	_flash_time = duration


func set_wrong_way(on: bool) -> void:
	_warning_label.text = "WRONG WAY!" if on else ""


func show_results(place: int, racers: int, time: float) -> void:
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.1, 0.85)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(36)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)
	box.add_child(_text("RACE COMPLETE", 48))
	box.add_child(_text("You finished %s of %d" % [ordinal(place), racers], 36))
	box.add_child(_text("Time  %s" % format_time(time), 32))
	var again := Button.new()
	again.text = "Race again"
	again.custom_minimum_size = Vector2(320, 80)
	again.add_theme_font_size_override("font_size", 34)
	again.pressed.connect(func(): get_tree().reload_current_scene())
	box.add_child(again)
	again.grab_focus()


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


func _text(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var ls := LabelSettings.new()
	ls.font_size = size
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
