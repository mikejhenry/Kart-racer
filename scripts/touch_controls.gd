extends CanvasLayer
## On-screen buttons for phones and tablets. TouchScreenButton supports
## multitouch and presses the same input actions as the keyboard.
## Layout: steer with the left thumb; drift, item and brake with the right.
## (The kart accelerates by itself on touch screens.)

var show_item := true   ## Hidden in time trials, which have no items
var _buttons := {}


func _ready() -> void:
	layer = 5
	_add("steer_left", "<", 170, true)
	_add("steer_right", ">", 170, true)
	_add("drift", "DRIFT", 180, false)
	_add("use_item", "ITEM", 140, false)
	_add("brake", "BRAKE", 120, false)
	_buttons["use_item"].visible = show_item
	get_viewport().size_changed.connect(_layout)
	_layout()


func _add(action: String, text: String, diameter: int, passby: bool) -> void:
	var b := TouchScreenButton.new()
	b.action = action
	b.passby_press = passby
	b.texture_normal = _circle(diameter, Color(1, 1, 1, 0.22))
	b.texture_pressed = _circle(diameter, Color(1, 1, 1, 0.5))
	var label := Label.new()
	label.text = text
	label.size = Vector2(diameter, diameter)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ls := LabelSettings.new()
	ls.font_size = 64 if text.length() == 1 else 28
	ls.outline_size = 6
	ls.outline_color = Color(0, 0, 0, 0.7)
	label.label_settings = ls
	b.add_child(label)
	add_child(b)
	_buttons[action] = b


func _layout() -> void:
	var screen := get_viewport().get_visible_rect().size
	var m := 28.0
	_buttons["steer_left"].position = Vector2(m, screen.y - m - 170)
	_buttons["steer_right"].position = Vector2(m + 190, screen.y - m - 170)
	_buttons["drift"].position = Vector2(screen.x - m - 180, screen.y - m - 180)
	_buttons["use_item"].position = Vector2(screen.x - m - 160, screen.y - m - 180 - 160)
	_buttons["brake"].position = Vector2(screen.x - m - 180 - 140, screen.y - m - 120)
	# With tilt steering, the arrows go away and brake moves to the left thumb.
	_buttons["steer_left"].visible = not Game.tilt_enabled
	_buttons["steer_right"].visible = not Game.tilt_enabled
	if Game.tilt_enabled:
		_buttons["brake"].position = Vector2(m, screen.y - m - 120)


func _circle(d: int, color: Color) -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.88, 0.94, 1.0])
	g.colors = PackedColorArray([color, color, Color(1, 1, 1, minf(color.a + 0.3, 1.0)), Color(1, 1, 1, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = d
	tex.height = d
	return tex
