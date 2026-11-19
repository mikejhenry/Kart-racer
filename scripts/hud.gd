extends CanvasLayer
## Race HUD in the "Pro Sport" style (see ui_theme.gd):
##   top left    pause and mic buttons, then the standings tower
##   top centre  held item (with roulette)
##   top right   position, lap and time; minimap below
##   centre      countdown and announcements, wrong-way warning
## plus connection status and the end-of-race / pause panels.

const UiTheme := preload("res://scripts/ui_theme.gd")
const ITEM_NAMES := {
	"nitro": "NITRO", "missile": "MISSILE", "triple": "MISSILES", "oil": "OIL SLICK",
	"shield": "SHIELD", "storm": "STORM",
}
const ROULETTE_ORDER := ["nitro", "missile", "oil", "shield", "storm"]
const BOX := Color(0.043, 0.055, 0.078, 0.82)

signal pause_pressed
signal mic_pressed

var _pos_box: PanelContainer
var _lap_sb: StyleBoxFlat
var _pos_label: Label
var _lap_caption: Label
var _time_label: Label
var _best_label: Label
var _item_box: PanelContainer
var _item_icon: ItemIcon
var _item_name: Label
var _item_count: Label
var _tower: VBoxContainer
var _tower_panel: PanelContainer
var _center_label: Label
var _warning_label: Label
var _net_label: Label
var _rotate_label: Label
var _panel_root: Control
var _minimap: Control
var _mic: Button
var _mic_icon: MicIcon
var _flash_time := 0.0
var _rolling := false
var _roll_tick := 0.0
var _roll_index := 0
var _items_on := true


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiTheme.make()
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# --- Top left: buttons and standings ---
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 14)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.position = Vector2(26, 26)
	root.add_child(left)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 14)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(buttons)
	var pause := _square_button()
	var pause_icon := PauseIcon.new()
	pause_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pause.add_child(pause_icon)
	pause_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause.pressed.connect(func(): pause_pressed.emit())
	buttons.add_child(pause)
	_mic = _square_button()
	_mic_icon = MicIcon.new()
	_mic_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mic.add_child(_mic_icon)
	_mic_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mic.visible = false
	_mic.pressed.connect(func(): mic_pressed.emit())
	buttons.add_child(_mic)

	_tower_panel = PanelContainer.new()
	_tower_panel.add_theme_stylebox_override("panel", UiTheme.panel(BOX, Color(0, 0, 0, 0), 11, 7))
	_tower_panel.custom_minimum_size = Vector2(330, 0)
	_tower_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tower_panel.visible = false
	_tower = VBoxContainer.new()
	_tower.add_theme_constant_override("separation", 3)
	_tower_panel.add_child(_tower)
	left.add_child(_tower_panel)

	# --- Top centre: item slot ---
	_item_box = PanelContainer.new()
	var item_sb := UiTheme.panel(BOX, Color(0, 0, 0, 0), 11, 10)
	item_sb.content_margin_right = 24
	_item_box.add_theme_stylebox_override("panel", item_sb)
	_item_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top_center := HBoxContainer.new()
	top_center.alignment = BoxContainer.ALIGNMENT_CENTER
	top_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top_center)
	top_center.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_center.offset_top = 26
	top_center.add_child(_item_box)
	var item_row := HBoxContainer.new()
	item_row.add_theme_constant_override("separation", 18)
	_item_box.add_child(item_row)
	_item_icon = ItemIcon.new()
	_item_icon.custom_minimum_size = Vector2(96, 96)
	item_row.add_child(_item_icon)
	var item_text := VBoxContainer.new()
	item_text.alignment = BoxContainer.ALIGNMENT_CENTER
	item_text.add_theme_constant_override("separation", -4)
	item_row.add_child(item_text)
	_item_name = _lbl("", 38, UiTheme.TEXT, "display")
	_item_name.custom_minimum_size.x = 170
	item_text.add_child(_item_name)
	_item_count = _lbl("", 22, UiTheme.MUTED, "bold")
	item_text.add_child(_item_count)

	# --- Top right: position / lap / time, minimap below ---
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 14)
	right.alignment = BoxContainer.ALIGNMENT_BEGIN
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(right)
	right.anchor_left = 1.0
	right.anchor_right = 1.0
	right.offset_left = -626
	right.offset_right = -26
	right.offset_top = 26
	var timing := HBoxContainer.new()
	timing.add_theme_constant_override("separation", 0)
	timing.size_flags_horizontal = Control.SIZE_SHRINK_END
	right.add_child(timing)
	_pos_box = PanelContainer.new()
	var pos_sb := UiTheme.panel(UiTheme.ACCENT, Color(0, 0, 0, 0), 11, 10)
	pos_sb.corner_radius_top_right = 0
	pos_sb.corner_radius_bottom_right = 0
	pos_sb.content_margin_left = 26
	pos_sb.content_margin_right = 26
	_pos_box.add_theme_stylebox_override("panel", pos_sb)
	var pos_col := VBoxContainer.new()
	pos_col.add_theme_constant_override("separation", -8)
	pos_col.alignment = BoxContainer.ALIGNMENT_CENTER
	_pos_box.add_child(pos_col)
	var pos_caption := _lbl("POS", 18, Color.WHITE, "bold")
	pos_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pos_col.add_child(pos_caption)
	_pos_label = _lbl("", 62, Color.WHITE, "display")
	_pos_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pos_col.add_child(_pos_label)
	timing.add_child(_pos_box)
	var lap_box := PanelContainer.new()
	var lap_sb := UiTheme.panel(BOX, Color(0, 0, 0, 0), 11, 10)
	lap_sb.corner_radius_top_left = 0
	lap_sb.corner_radius_bottom_left = 0
	lap_sb.content_margin_left = 26
	lap_sb.content_margin_right = 26
	lap_box.add_theme_stylebox_override("panel", lap_sb)
	_lap_sb = lap_sb
	var lap_col := VBoxContainer.new()
	lap_col.add_theme_constant_override("separation", -4)
	lap_col.alignment = BoxContainer.ALIGNMENT_CENTER
	lap_box.add_child(lap_col)
	_lap_caption = _lbl("", 18, UiTheme.MUTED, "bold")
	lap_col.add_child(_lap_caption)
	_time_label = _lbl("0:00.00", 48, UiTheme.TEXT, "number")
	_time_label.custom_minimum_size.x = 170
	lap_col.add_child(_time_label)
	_best_label = _lbl("", 20, UiTheme.MUTED)
	lap_col.add_child(_best_label)
	timing.add_child(lap_box)
	_minimap = Minimap.new()
	_minimap.custom_minimum_size = Vector2(207, 207)
	_minimap.size_flags_horizontal = Control.SIZE_SHRINK_END
	_minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap.visible = false
	right.add_child(_minimap)

	# --- Centre text ---
	_center_label = _overlay(120, VERTICAL_ALIGNMENT_CENTER)
	_warning_label = _overlay(64, VERTICAL_ALIGNMENT_TOP)
	_warning_label.offset_top = 170.0
	_warning_label.label_settings.font_color = Color("#FF5C4D")
	_net_label = _overlay(30, VERTICAL_ALIGNMENT_BOTTOM)
	_net_label.label_settings = UiTheme.label_settings(30, UiTheme.GOLD, "bold")
	_net_label.label_settings.outline_size = 6
	_net_label.label_settings.outline_color = Color(0, 0, 0, 0.8)
	_net_label.offset_bottom = -210.0
	_rotate_label = _overlay(36, VERTICAL_ALIGNMENT_CENTER)
	_rotate_label.offset_top = 240.0
	_rotate_label.label_settings.font = UiTheme.BOLD_FONT
	_rotate_label.text = "Turn your phone sideways for a better view"
	_rotate_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	set_item("")


func _unhandled_input(event: InputEvent) -> void:
	# Handled here because the HUD keeps running while the game is paused.
	if event.is_action_pressed("pause"):
		pause_pressed.emit()


func _process(delta: float) -> void:
	if _flash_time > 0.0:
		_flash_time -= delta
		if _flash_time <= 0.0:
			_center_label.text = ""
	if _rolling:
		_roll_tick -= delta
		if _roll_tick <= 0.0:
			_roll_tick = 0.08
			_roll_index = (_roll_index + 1) % ROULETTE_ORDER.size()
			var kind: String = ROULETTE_ORDER[_roll_index]
			_item_icon.kind = kind
			_item_icon.queue_redraw()
			_item_name.text = ITEM_NAMES[kind]
			Sfx.play("roulette")
	var screen := get_viewport().get_visible_rect().size
	_rotate_label.visible = screen.y > screen.x
	if _minimap.visible:
		_minimap.queue_redraw()


## place <= 0 hides the position (time trial). racers: karts in the race.
func set_status(lap: int, total_laps: int, place: int, time: float, racers: int = 6) -> void:
	_lap_caption.text = "LAP %d/%d" % [lap, total_laps]
	_time_label.text = format_time(time)
	if _pos_box.visible != (place > 0):
		_pos_box.visible = place > 0
		var r := 0 if place > 0 else 11
		_lap_sb.corner_radius_top_left = r
		_lap_sb.corner_radius_bottom_left = r
	if place > 0:
		var text := "%d/%d" % [place, racers]
		if _pos_label.text != text:
			_pos_label.text = text


## Best completed lap so far (0 = none yet).
func set_best_lap(t: float) -> void:
	_best_label.text = "Best lap %s" % format_time(t) if t > 0.0 else ""


## rows: [{name, color, me, gap}] in race order.
func set_standings(rows: Array) -> void:
	_tower_panel.visible = rows.size() > 1
	while _tower.get_child_count() < rows.size():
		_tower.add_child(_tower_row())
	while _tower.get_child_count() > rows.size():
		var c := _tower.get_child(_tower.get_child_count() - 1)
		_tower.remove_child(c)
		c.queue_free()
	for i in rows.size():
		var r: Dictionary = rows[i]
		var row: PanelContainer = _tower.get_child(i)
		var me := bool(r.get("me", false))
		var sb: StyleBoxFlat = row.get_theme_stylebox("panel")
		sb.bg_color = UiTheme.ACCENT if me else Color(0, 0, 0, 0)
		var h: HBoxContainer = row.get_child(0)
		(h.get_child(0) as Label).text = str(i + 1)
		(h.get_child(1) as ColorRect).color = Color.WHITE if me else r.get("color", Color.WHITE)
		(h.get_child(2) as Label).text = str(r.get("name", ""))
		var gap := h.get_child(3) as Label
		gap.text = str(r.get("gap", ""))
		gap.label_settings.font_color = Color.WHITE if me else UiTheme.MUTED


func _tower_row() -> PanelContainer:
	var row := PanelContainer.new()
	var sb := UiTheme.panel(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 6, 0)
	sb.content_margin_left = 10
	sb.content_margin_right = 12
	row.add_theme_stylebox_override("panel", sb)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	h.custom_minimum_size = Vector2(0, 42)
	row.add_child(h)
	var n := _lbl("", 26, UiTheme.TEXT, "display")
	n.custom_minimum_size.x = 22
	h.add_child(n)
	var bar := ColorRect.new()
	bar.custom_minimum_size = Vector2(7, 26)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(bar)
	var who := _lbl("", 23, UiTheme.TEXT, "bold")
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.clip_text = true
	h.add_child(who)
	h.add_child(_lbl("", 22, UiTheme.MUTED, "number"))
	return row


## item "?" starts the roulette; "" clears the slot.
func set_item(item: String, count: int = 1) -> void:
	_rolling = item == "?"
	_item_box.visible = _items_on
	if _rolling:
		_item_count.text = ""
		_item_icon.empty = false
		return
	if not ITEM_NAMES.has(item):
		_item_icon.kind = ""
		_item_icon.empty = true
		_item_icon.queue_redraw()
		_item_name.text = "NO ITEM"
		_item_name.label_settings.font_color = UiTheme.DIM
		_item_count.text = "Drive through a box"
		return
	_item_icon.kind = item
	_item_icon.empty = false
	_item_icon.queue_redraw()
	_item_name.text = ITEM_NAMES[item]
	_item_name.label_settings.font_color = UiTheme.TEXT
	_item_count.text = "%d left" % count if item == "triple" or count > 1 else ""


## Time trials have no items: hide the slot.
func set_items_enabled(on: bool) -> void:
	_items_on = on
	_item_box.visible = on


## Voice chat mute button, shown while in voice.
func set_mic(shown: bool, muted: bool) -> void:
	_mic.visible = shown
	_mic_icon.muted = muted
	_mic_icon.queue_redraw()


func set_net_status(text: String) -> void:
	_net_label.text = text


## The minimap: the track outline with a dot per kart.
func setup_minimap(outline: PackedVector2Array, karts: Array, player) -> void:
	_minimap.outline = outline
	_minimap.karts = karts
	_minimap.player = player
	_minimap.visible = true


func flash(text: String, duration: float) -> void:
	_center_label.text = text
	_flash_time = duration


func set_wrong_way(on: bool) -> void:
	_warning_label.text = "WRONG WAY" if on else ""


func has_panel() -> bool:
	return _panel_root != null


func hide_panel() -> void:
	if _panel_root:
		_panel_root.queue_free()
		_panel_root = null


## Shows a centred panel. buttons is a list of [label, Callable]; the first
## is the main action. Lines starting with ★ are highlighted.
func show_panel(title: String, lines: Array, buttons: Array) -> void:
	hide_panel()
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.45)
	shade.theme = UiTheme.make()
	add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel_root = shade
	var center := CenterContainer.new()
	shade.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel(Color(0.043, 0.055, 0.078, 0.95), Color(1, 1, 1, 0.12), 18, 36))
	panel.custom_minimum_size = Vector2(620, 0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var stripe := HBoxContainer.new()
	stripe.add_theme_constant_override("separation", 16)
	var mark := ColorRect.new()
	mark.color = UiTheme.ACCENT
	mark.custom_minimum_size = Vector2(12, 56)
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stripe.add_child(mark)
	stripe.add_child(_lbl(title, 64, UiTheme.TEXT, "display"))
	box.add_child(stripe)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	box.add_child(spacer)
	for line in lines:
		var text := str(line)
		var hi := text.begins_with("★")
		var l := _lbl(text.trim_prefix("★"), 28, UiTheme.GOLD if hi else UiTheme.TEXT, "bold" if hi else "text")
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 540
		box.add_child(l)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 16)
	box.add_child(gap)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)
	var first: Button = null
	for b in buttons:
		var btn := Button.new()
		btn.text = str(b[0]).to_upper() if first == null else str(b[0])
		btn.custom_minimum_size = Vector2(220, 92)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(b[1])
		if first == null:
			btn.theme_type_variation = "AccentButton"
			btn.size_flags_stretch_ratio = 1.4
		row.add_child(btn)
		if first == null:
			first = btn
	if first:
		first.grab_focus()


func _square_button() -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(86, 86)
	var sb := UiTheme.panel(BOX, Color(1, 1, 1, 0.2), 11, 0)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	var down := sb.duplicate()
	down.bg_color = Color(0.15, 0.17, 0.21, 0.9)
	b.add_theme_stylebox_override("pressed", down)
	return b


func _lbl(text: String, size: int, color: Color, kind: String = "text") -> Label:
	var l := Label.new()
	l.text = text
	l.label_settings = UiTheme.label_settings(size, color, kind)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _overlay(size: int, v: VerticalAlignment) -> Label:
	var l := _lbl("", size, UiTheme.TEXT, "display")
	l.label_settings.outline_size = maxi(6, int(size / 7.0))
	l.label_settings.outline_color = Color(0.043, 0.055, 0.078, 0.9)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = v
	add_child(l)
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.offset_left = 24.0
	l.offset_top = 16.0
	l.offset_right = -24.0
	l.offset_bottom = -16.0
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


# --- Drawn pieces -------------------------------------------------------------

class Minimap extends Control:
	var outline := PackedVector2Array()
	var karts: Array = []
	var player
	var _lo := Vector2.ZERO
	var _scale := 1.0
	var _pad := Vector2.ZERO

	func _draw() -> void:
		draw_style_box(UiTheme.panel(BOX, Color(0, 0, 0, 0), 11, 0), Rect2(Vector2.ZERO, size))
		if outline.is_empty():
			return
		var lo := outline[0]
		var hi := outline[0]
		for p in outline:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		var span := hi - lo
		_scale = minf((size.x - 30.0) / maxf(span.x, 1.0), (size.y - 30.0) / maxf(span.y, 1.0))
		_pad = (size - span * _scale) * 0.5
		_lo = lo
		var pts := PackedVector2Array()
		for p in outline:
			pts.append(_map(p))
		pts.append(pts[0])
		draw_polyline(pts, UiTheme.TEXT, 6.0, true)
		draw_rect(Rect2(pts[0] - Vector2(3, 8), Vector2(6, 16)), UiTheme.ACCENT)
		for k in karts:
			if not is_instance_valid(k) or k == player:
				continue
			draw_circle(_map(Vector2(k.global_position.x, k.global_position.z)), 8.0, k.body_color, true, -1.0, true)
		if is_instance_valid(player):
			var at := _map(Vector2(player.global_position.x, player.global_position.z))
			draw_circle(at, 12.0, Color.WHITE, true, -1.0, true)
			draw_circle(at, 8.5, UiTheme.ACCENT, true, -1.0, true)

	func _map(p: Vector2) -> Vector2:
		return (p - _lo) * _scale + _pad


class PauseIcon extends Control:
	func _draw() -> void:
		var c := size * 0.5
		draw_rect(Rect2(c + Vector2(-15, -17), Vector2(10, 34)), UiTheme.TEXT)
		draw_rect(Rect2(c + Vector2(5, -17), Vector2(10, 34)), UiTheme.TEXT)


class MicIcon extends Control:
	var muted := false

	func _draw() -> void:
		var c := size * 0.5
		var col := Color("#FF5C4D") if muted else UiTheme.GOOD
		var body := Rect2(c + Vector2(-7, -20), Vector2(14, 24))
		draw_style_box(UiTheme.panel(Color(0, 0, 0, 0), col, 7, 0), body)
		draw_arc(c + Vector2(0, -2), 14.0, 0.0, PI, 14, col, 4.0, true)
		draw_line(c + Vector2(0, 12), c + Vector2(0, 20), col, 4.0, true)
		if muted:
			draw_line(c + Vector2(-18, -20), c + Vector2(18, 20), col, 4.0, true)


## Item pictures: simple shapes, no text.
class ItemIcon extends Control:
	var kind := ""
	var empty := true

	func _draw() -> void:
		var r := Rect2(Vector2(2, 2), size - Vector2(4, 4))
		var frame := UiTheme.panel(Color(0, 0, 0, 0), UiTheme.ACCENT if not empty else Color(1, 1, 1, 0.25), 8, 0)
		frame.set_border_width_all(4)
		draw_style_box(frame, r)
		var c := size * 0.5
		var s := size.x / 96.0
		match kind:
			"nitro":
				_bolt(c, s, Color("#FFB020"))
			"missile":
				_rocket(c, s, 1.0)
			"triple":
				_rocket(c + Vector2(-18, 8) * s, s, 0.6)
				_rocket(c + Vector2(0, -6) * s, s, 0.6)
				_rocket(c + Vector2(18, 8) * s, s, 0.6)
			"oil":
				# A drop: point at the top, round at the bottom.
				var pts := PackedVector2Array([c + Vector2(0, -28) * s])
				for i in 21:
					var a := lerpf(-PI * 0.12, PI * 1.12, i / 20.0)
					pts.append(c + Vector2(0, 8) * s + Vector2(cos(a), sin(a)) * 18.0 * s)
				draw_colored_polygon(pts, Color("#2A2140"))
				pts.append(pts[0])
				draw_polyline(pts, UiTheme.TEXT, 3.0, true)
			"shield":
				var pts := PackedVector2Array([c + Vector2(0, -28) * s, c + Vector2(24, -18) * s, c + Vector2(20, 8) * s,
					c + Vector2(0, 28) * s, c + Vector2(-20, 8) * s, c + Vector2(-24, -18) * s])
				draw_colored_polygon(pts, Color("#3A8BFF"))
				pts.append(pts[0])
				draw_polyline(pts, UiTheme.TEXT, 3.0, true)
			"storm":
				for p in [Vector2(-12, -8), Vector2(6, -14), Vector2(16, -4), Vector2(-2, -2)]:
					draw_circle(c + p * s, 12.0 * s, Color("#C9CED8"), true, -1.0, true)
				_bolt(c + Vector2(2, 14) * s, s * 0.6, Color("#FFD23F"))
			_:
				if not empty:
					draw_string(UiTheme.DISPLAY_FONT, Vector2(0, c.y + 18 * s), "?", HORIZONTAL_ALIGNMENT_CENTER, size.x, int(52 * s), UiTheme.TEXT)

	func _bolt(c: Vector2, s: float, col: Color) -> void:
		var pts := PackedVector2Array([c + Vector2(6, -30) * s, c + Vector2(-16, 4) * s, c + Vector2(-2, 4) * s,
			c + Vector2(-8, 30) * s, c + Vector2(16, -6) * s, c + Vector2(2, -6) * s])
		draw_colored_polygon(pts, col)

	func _rocket(c: Vector2, s: float, k: float) -> void:
		var u := s * k
		var body := PackedVector2Array([c + Vector2(0, -30) * u, c + Vector2(9, -14) * u, c + Vector2(9, 16) * u,
			c + Vector2(-9, 16) * u, c + Vector2(-9, -14) * u])
		draw_colored_polygon(body, UiTheme.TEXT)
		draw_colored_polygon(PackedVector2Array([c + Vector2(-9, 4) * u, c + Vector2(-18, 22) * u, c + Vector2(-9, 16) * u]), UiTheme.ACCENT)
		draw_colored_polygon(PackedVector2Array([c + Vector2(9, 4) * u, c + Vector2(18, 22) * u, c + Vector2(9, 16) * u]), UiTheme.ACCENT)
		draw_colored_polygon(PackedVector2Array([c + Vector2(-5, 16) * u, c + Vector2(0, 28) * u, c + Vector2(5, 16) * u]), Color("#FFB020"))
