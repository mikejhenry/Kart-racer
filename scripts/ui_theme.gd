extends RefCounted
## "Pro Sport" look shared by the menus and the race HUD: near-black panels,
## a red accent, condensed Saira for headings and numbers, Inter for text.
## Sizes are in the game's 1280x720 canvas units (about 1.85x a phone's
## CSS pixels in landscape).

const BG := Color("#0B0E14")
const TEXT := Color("#F2F4F8")
const MUTED := Color("#A3ABBA")
const DIM := Color("#8C95A6")
const ACCENT := Color("#D42A26")
const GOOD := Color("#34C759")
const WARN := Color("#FF8A7A")
const GOLD := Color("#F2BF1A")
const SURFACE := Color(1, 1, 1, 0.05)
const LINE := Color(1, 1, 1, 0.14)
const PANEL := Color(0.043, 0.055, 0.078, 0.84)   ## BG at 84%

const TEXT_FONT := preload("res://fonts/Inter-SemiBold.otf")
const BOLD_FONT := preload("res://fonts/Inter-Bold.otf")
const DISPLAY_FONT := preload("res://fonts/SairaCondensed-ExtraBold.ttf")
const NUMBER_FONT := preload("res://fonts/SairaCondensed-Bold.ttf")


static func make() -> Theme:
	var theme := Theme.new()
	theme.default_font = TEXT_FONT
	theme.default_font_size = 26

	# Plain buttons: a faint fill with a hairline border.
	_button_styles(theme, "Button", SURFACE * Color(1, 1, 1, 1.2), LINE, TEXT)
	# Accent (primary action) and light (selected / secondary call to action).
	theme.set_type_variation("AccentButton", "Button")
	_button_styles(theme, "AccentButton", ACCENT, ACCENT, Color.WHITE)
	theme.set_font("font", "AccentButton", DISPLAY_FONT)
	theme.set_font_size("font_size", "AccentButton", 40)
	theme.set_type_variation("LightButton", "Button")
	_button_styles(theme, "LightButton", TEXT, TEXT, BG)
	theme.set_font("font", "LightButton", DISPLAY_FONT)
	theme.set_font_size("font_size", "LightButton", 36)
	# Transparent rows for the main menu list.
	theme.set_type_variation("FlatButton", "Button")
	_button_styles(theme, "FlatButton", Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.0), TEXT)

	var field := _box(Color(1, 1, 1, 0.07), LINE)
	theme.set_stylebox("normal", "LineEdit", field)
	var focus_field := _box(Color(1, 1, 1, 0.1), MUTED)
	theme.set_stylebox("focus", "LineEdit", focus_field)
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", DIM)
	theme.set_color("caret_color", "LineEdit", TEXT)

	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var sb := StyleBoxEmpty.new()
		sb.set_content_margin_all(10)
		theme.set_stylebox(state, "CheckButton", sb)
	theme.set_color("font_color", "CheckButton", TEXT)
	theme.set_color("font_hover_color", "CheckButton", TEXT)
	theme.set_color("font_pressed_color", "CheckButton", TEXT)
	theme.set_color("font_hover_pressed_color", "CheckButton", TEXT)
	theme.set_icon("checked", "CheckButton", _switch(true))
	theme.set_icon("unchecked", "CheckButton", _switch(false))

	var rail := StyleBoxFlat.new()
	rail.bg_color = Color(1, 1, 1, 0.16)
	rail.set_corner_radius_all(4)
	rail.content_margin_top = 4
	rail.content_margin_bottom = 4
	theme.set_stylebox("slider", "HSlider", rail)
	var fill := rail.duplicate()
	fill.bg_color = ACCENT
	theme.set_stylebox("grabber_area", "HSlider", fill)
	theme.set_stylebox("grabber_area_highlight", "HSlider", fill)
	theme.set_icon("grabber", "HSlider", _dot(30, TEXT))
	theme.set_icon("grabber_highlight", "HSlider", _dot(34, Color.WHITE))

	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(1, 1, 1, 0.25)
	grab.set_corner_radius_all(4)
	theme.set_stylebox("grabber", "VScrollBar", grab)
	theme.set_stylebox("grabber_highlight", "VScrollBar", grab)
	theme.set_stylebox("grabber_pressed", "VScrollBar", grab)
	var none := StyleBoxEmpty.new()
	none.content_margin_left = 8
	theme.set_stylebox("scroll", "VScrollBar", none)
	return theme


static func _button_styles(theme: Theme, type: String, fill: Color, border: Color, font: Color) -> void:
	var states := {
		"normal": [fill, border],
		"hover": [fill.lightened(0.08), border.lightened(0.2)],
		"pressed": [fill.darkened(0.2), border],
		"hover_pressed": [fill.darkened(0.2), border],
		"disabled": [Color(fill, fill.a * 0.4), Color(border, border.a * 0.4)],
	}
	for key in states:
		theme.set_stylebox(key, type, _box(states[key][0], states[key][1]))
	var focus := StyleBoxFlat.new()
	focus.draw_center = false
	focus.border_color = Color(1, 1, 1, 0.7)
	focus.set_border_width_all(3)
	focus.set_corner_radius_all(11)
	theme.set_stylebox("focus", type, focus)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		theme.set_color(c, type, font)
	theme.set_color("font_disabled_color", type, Color(font, 0.4))


static func _box(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(11)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


## A rounded panel background (cards, lists, HUD boxes).
static func panel(fill: Color = SURFACE, border: Color = Color(1, 1, 1, 0.1), radius: int = 15, margin: int = 20) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(2 if border.a > 0.0 else 0)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	return sb


## Label styles. kind: "display" (Saira ExtraBold), "number" (Saira Bold),
## "bold" (Inter Bold) or "text" (Inter SemiBold).
static func label_settings(size: int, color: Color = TEXT, kind: String = "text") -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font = {"display": DISPLAY_FONT, "number": NUMBER_FONT, "bold": BOLD_FONT}.get(kind, TEXT_FONT)
	ls.font_size = size
	ls.font_color = color
	return ls


static func _dot(d: int, color: Color) -> ImageTexture:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var r := d * 0.5
	for y in d:
		for x in d:
			var dist := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			img.set_pixel(x, y, Color(color, clampf(r - dist, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


## On/off switch images for CheckButton.
static func _switch(on: bool) -> ImageTexture:
	var w := 76
	var h := 42
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var track := ACCENT if on else Color(1, 1, 1, 0.22)
	var r := h * 0.5
	var knob_x := w - r if on else r
	for y in h:
		for x in w:
			var p := Vector2(x + 0.5, y + 0.5)
			var cx := clampf(p.x, r, w - r)
			var d_track := r - p.distance_to(Vector2(cx, r))
			var c := Color(track, track.a * clampf(d_track, 0.0, 1.0))
			var d_knob := (r - 5.0) - p.distance_to(Vector2(knob_x, r))
			if d_knob > -1.0:
				c = c.blend(Color(1, 1, 1, clampf(d_knob + 1.0, 0.0, 1.0)))
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)
