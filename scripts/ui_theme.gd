extends RefCounted
## Button and text field styles shared by the menu and the race HUD panels.


static func make() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 28
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
		sb.set_content_margin_all(12)
		if key == "focus":
			sb.draw_center = false
			sb.border_color = Color(1, 1, 1, 0.8)
			sb.set_border_width_all(3)
		theme.set_stylebox(key, "Button", sb)
	var field := StyleBoxFlat.new()
	field.bg_color = Color(1, 1, 1, 0.1)
	field.set_corner_radius_all(12)
	field.set_content_margin_all(12)
	theme.set_stylebox("normal", "LineEdit", field)
	theme.set_stylebox("focus", "LineEdit", field)
	return theme
