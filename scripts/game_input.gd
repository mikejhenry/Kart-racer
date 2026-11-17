extends Node
## Autoload. Registers input actions at startup so keyboard, gamepad and the
## on-screen touch buttons all drive the same actions, and detects the device.

## Set to true to preview the touch controls on a desktop.
const FORCE_TOUCH_UI := false

var touch_ui := false
var auto_accelerate := false
var low_quality := false


func _enter_tree() -> void:
	_add_action("accelerate", [_key(KEY_W), _key(KEY_UP), _joy_button(JOY_BUTTON_A), _joy_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)])
	_add_action("brake", [_key(KEY_S), _key(KEY_DOWN), _joy_button(JOY_BUTTON_B), _joy_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)])
	_add_action("steer_left", [_key(KEY_A), _key(KEY_LEFT), _joy_axis(JOY_AXIS_LEFT_X, -1.0), _joy_button(JOY_BUTTON_DPAD_LEFT)])
	_add_action("steer_right", [_key(KEY_D), _key(KEY_RIGHT), _joy_axis(JOY_AXIS_LEFT_X, 1.0), _joy_button(JOY_BUTTON_DPAD_RIGHT)])
	_add_action("drift", [_key(KEY_SPACE), _key(KEY_SHIFT), _joy_button(JOY_BUTTON_RIGHT_SHOULDER)])
	_add_action("use_item", [_key(KEY_E), _key(KEY_CTRL), _joy_button(JOY_BUTTON_X), _joy_button(JOY_BUTTON_LEFT_SHOULDER)])
	_add_action("respawn", [_key(KEY_R), _joy_button(JOY_BUTTON_Y)])

	touch_ui = FORCE_TOUCH_UI or DisplayServer.is_touchscreen_available()
	# On touch screens the kart accelerates by itself, so one thumb steers
	# and the other handles drift, items and brake.
	auto_accelerate = touch_ui
	low_quality = touch_ui or OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")


func _add_action(action: StringName, events: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)
	for e in events:
		InputMap.action_add_event(action, e)


func _key(code: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	return e


func _joy_button(button: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	return e


func _joy_axis(axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	return e
