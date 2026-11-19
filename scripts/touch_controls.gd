extends CanvasLayer
## On-screen buttons for phones and tablets. TouchScreenButton supports
## multitouch and presses the same input actions as the keyboard.
## Layout: steer with the left thumb; brake, item and drift with the right.
## (The kart accelerates by itself on touch screens.)
## Look: chunky "arcade" buttons - solid colours, a thick dark outline and a
## drop shadow that disappears when pressed. A charge bar above DRIFT fills
## while drifting (grey, then blue = mini-turbo ready, orange = big turbo).

const UiTheme := preload("res://scripts/ui_theme.gd")
const INK := Color("#1B1B3A")
const SHADOW := 10            ## Drop-shadow depth in canvas units

var show_item := true   ## Hidden in time trials, which have no items
var kart                ## The player's kart, for the drift charge bar
var _buttons := {}
var _charge: ChargeBar


func _ready() -> void:
	layer = 5
	_add("steer_left", "", 163, Color(1, 1, 1, 0.92), true, -1)
	_add("steer_right", "", 163, Color(1, 1, 1, 0.92), true, 1)
	_add("drift", "DRIFT", 185, Color("#FFD23F"), false)
	_add("use_item", "ITEM", 130, Color(1, 1, 1, 0.95), false)
	_add("brake", "BRAKE", 118, Color("#FF5C5C"), false)
	_buttons["use_item"].visible = show_item
	_charge = ChargeBar.new()
	_charge.size = Vector2(178, 22)
	_charge.visible = false
	add_child(_charge)
	get_viewport().size_changed.connect(_layout)
	_layout()


func _process(_delta: float) -> void:
	var on: bool = kart != null and is_instance_valid(kart) and kart.drifting
	_charge.visible = on
	if on:
		var v: float = clampf(kart.drift_charge / 2.0, 0.0, 1.0)
		if absf(v - _charge.value) > 0.005:
			_charge.value = v
			_charge.queue_redraw()


## arrow: -1 / 1 draws a chevron instead of text.
func _add(action: String, text: String, d: int, fill: Color, passby: bool, arrow: int = 0) -> void:
	var b := TouchScreenButton.new()
	b.action = action
	b.passby_press = passby
	b.texture_normal = _button_texture(d, fill, false, arrow)
	b.texture_pressed = _button_texture(d, fill.darkened(0.12), true, arrow)
	if text != "":
		var label := Label.new()
		label.text = text
		label.size = Vector2(d, d)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.label_settings = UiTheme.label_settings(int(d * 0.24), INK, "display")
		b.add_child(label)
	add_child(b)
	_buttons[action] = b


func _layout() -> void:
	var screen := get_viewport().get_visible_rect().size
	var m := 34.0
	var bottom := screen.y - m - SHADOW
	_buttons["steer_left"].position = Vector2(m, bottom - 163)
	_buttons["steer_right"].position = Vector2(m + 163 + 26, bottom - 163)
	var drift_x := screen.x - m - 185
	_buttons["drift"].position = Vector2(drift_x, bottom - 185)
	_buttons["use_item"].position = Vector2(drift_x - 22 - 130, bottom - 130)
	var brake_x := drift_x - 22 - (130 + 22 if show_item else 0) - 118
	_buttons["brake"].position = Vector2(brake_x, bottom - 118)
	_charge.position = Vector2(drift_x + (185 - _charge.size.x) * 0.5, bottom - 185 - 22 - 16)
	# With tilt steering, the arrows go away and brake moves to the left thumb.
	_buttons["steer_left"].visible = not Game.tilt_enabled
	_buttons["steer_right"].visible = not Game.tilt_enabled
	if Game.tilt_enabled:
		_buttons["brake"].position = Vector2(m, bottom - 118)


## A circle with a thick outline and a drop shadow (drawn into an image so
## TouchScreenButton can use it). Pressed: the button sits on its shadow.
static func _button_texture(d: int, fill: Color, pressed: bool, arrow: int) -> ImageTexture:
	var w := d
	var h := d + SHADOW
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var r := d * 0.5
	var outline := 7.0
	var top := float(SHADOW) if pressed else 0.0
	var face_c := Vector2(r, r + top)
	var shadow_c := Vector2(r, r + SHADOW)
	for y in h:
		for x in w:
			var p := Vector2(x + 0.5, y + 0.5)
			var c := Color(0, 0, 0, 0)
			# Shadow (only visible below the face when not pressed)
			var ds := r - p.distance_to(shadow_c)
			if ds > -1.0:
				c = Color(INK, clampf(ds + 1.0, 0.0, 1.0))
			var df := r - p.distance_to(face_c)
			if df > -1.0:
				var a := clampf(df + 1.0, 0.0, 1.0)
				var face := fill if df > outline else INK
				if df > outline - 1.0 and df <= outline:
					face = INK.lerp(fill, df - (outline - 1.0))
				c = c.blend(Color(face, a * (face.a if df > outline else 1.0)))
			img.set_pixel(x, y, c)
	if arrow != 0:
		_chevron(img, face_c, d * 0.2, arrow)
	return ImageTexture.create_from_image(img)


static func _chevron(img: Image, c: Vector2, s: float, dir: int) -> void:
	# Thick "<" or ">" in ink, anti-aliased by distance to its two strokes.
	var tip := c + Vector2(s * 0.45 * dir, 0)
	var a := c + Vector2(-s * 0.45 * dir, -s)
	var b := c + Vector2(-s * 0.45 * dir, s)
	var half := s * 0.22
	var x0 := int(c.x - s * 1.4)
	var y0 := int(c.y - s * 1.4)
	for y in range(y0, int(c.y + s * 1.4)):
		for x in range(x0, int(c.x + s * 1.4)):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var p := Vector2(x + 0.5, y + 0.5)
			var dist := minf(_seg_dist(p, tip, a), _seg_dist(p, tip, b))
			var cov := clampf(half - dist + 0.5, 0.0, 1.0)
			if cov > 0.0:
				img.set_pixel(x, y, img.get_pixel(x, y).blend(Color(INK, cov)))


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


class ChargeBar extends Control:
	var value := 0.0

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color.WHITE
		bg.border_color = INK
		bg.set_border_width_all(5)
		bg.set_corner_radius_all(int(size.y * 0.5))
		draw_style_box(bg, r)
		if value > 0.0:
			var fill := StyleBoxFlat.new()
			# Grey until a mini-turbo is ready, then blue, then orange (big turbo).
			fill.bg_color = Color("#FF8A1F") if value >= 1.0 else (Color("#2F8BFF") if value >= 0.5 else Color("#9AA3B5"))
			fill.set_corner_radius_all(int(size.y * 0.5) - 5)
			var inner := r.grow(-5)
			inner.size.x *= value
			draw_style_box(fill, inner)
