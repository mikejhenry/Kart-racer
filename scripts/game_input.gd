extends Node
## Autoload. Registers input actions at startup so keyboard, gamepad and the
## on-screen touch buttons all drive the same actions, and detects the device.

## Set to true to preview the touch controls on a desktop.
const FORCE_TOUCH_UI := false

var touch_ui := false
var auto_accelerate := false
var low_quality := false

## Browser side of tilt steering. Listens to the phone's orientation sensor
## and works out how far the screen is rolled, like a steering wheel, for
## whichever way the phone is turned. iPhones only share motion data after
## the player allows it, and the request has to happen during a tap, so the
## next tap after turning tilt on asks for permission.
const TILT_JS := """
(function () {
  if (window.kartTilt) return;
  var t = window.kartTilt = { x: 0, ok: false, wanted: false, asked: false, perm: '' };
  window.addEventListener('deviceorientation', function (e) {
    if (e.beta === null || e.gamma === null) return;
    var r = Math.PI / 180, b = e.beta * r, g = e.gamma * r;
    var angle = (screen.orientation && typeof screen.orientation.angle === 'number')
      ? screen.orientation.angle : (window.orientation || 0);
    var a = angle * r;
    t.x = Math.sin(g) * Math.cos(b) * Math.cos(a) + Math.sin(b) * Math.sin(a);
    t.ok = true;
  });
  function ask() {
    if (!t.wanted || t.asked) return;
    if (typeof DeviceOrientationEvent === 'undefined' ||
        typeof DeviceOrientationEvent.requestPermission !== 'function') return;
    t.asked = true;
    DeviceOrientationEvent.requestPermission()
      .then(function (s) { t.perm = s; })
      .catch(function () { t.perm = 'denied'; });
  }
  document.addEventListener('touchend', ask, true);
  document.addEventListener('click', ask, true);
})();
"""
const TILT_DEADZONE := 2.0   ## Degrees around level that count as straight

var _web_tilt := false


func _enter_tree() -> void:
	_add_action("accelerate", [_key(KEY_W), _key(KEY_UP), _joy_button(JOY_BUTTON_A), _joy_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)])
	_add_action("brake", [_key(KEY_S), _key(KEY_DOWN), _joy_button(JOY_BUTTON_B), _joy_axis(JOY_AXIS_TRIGGER_LEFT, 1.0)])
	_add_action("steer_left", [_key(KEY_A), _key(KEY_LEFT), _joy_axis(JOY_AXIS_LEFT_X, -1.0), _joy_button(JOY_BUTTON_DPAD_LEFT)])
	_add_action("steer_right", [_key(KEY_D), _key(KEY_RIGHT), _joy_axis(JOY_AXIS_LEFT_X, 1.0), _joy_button(JOY_BUTTON_DPAD_RIGHT)])
	_add_action("drift", [_key(KEY_SPACE), _key(KEY_SHIFT), _joy_button(JOY_BUTTON_RIGHT_SHOULDER)])
	_add_action("use_item", [_key(KEY_E), _key(KEY_CTRL), _joy_button(JOY_BUTTON_X), _joy_button(JOY_BUTTON_LEFT_SHOULDER)])
	_add_action("respawn", [_key(KEY_R), _joy_button(JOY_BUTTON_Y)])
	_add_action("pause", [_key(KEY_ESCAPE), _key(KEY_P), _joy_button(JOY_BUTTON_START)])

	touch_ui = FORCE_TOUCH_UI or DisplayServer.is_touchscreen_available()
	# On touch screens the kart accelerates by itself, so one thumb steers
	# and the other handles drift, items and brake.
	auto_accelerate = touch_ui
	low_quality = touch_ui or OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")

	if OS.has_feature("web"):
		JavaScriptBridge.eval(TILT_JS, true)
		_web_tilt = true


# --- Tilt steering ----------------------------------------------------------

func set_tilt_wanted(on: bool) -> void:
	if _web_tilt:
		JavaScriptBridge.eval("window.kartTilt.wanted = %s; window.kartTilt.asked = false;" % ("true" if on else "false"), true)


## True on iPhone/iPad browsers, where the player must allow motion access.
func tilt_needs_permission() -> bool:
	if not _web_tilt:
		return false
	return bool(JavaScriptBridge.eval("typeof DeviceOrientationEvent !== 'undefined' && typeof DeviceOrientationEvent.requestPermission === 'function' && window.kartTilt.perm !== 'granted'", true))


## How far the screen is rolled, in degrees (right is positive), or NAN if
## the device isn't reporting motion data.
func tilt_angle() -> float:
	var s := NAN
	if _web_tilt:
		var v = JavaScriptBridge.eval("window.kartTilt.ok ? window.kartTilt.x : null", true)
		if v != null:
			s = clampf(float(v), -1.0, 1.0)
	else:
		var g := Input.get_gravity()
		if g.length() > 0.5:
			s = clampf(-g.x / g.length(), -1.0, 1.0)
	return NAN if is_nan(s) else rad_to_deg(asin(s))


## Steering from tilt, -1 (full left) .. 1 (full right). 0 without data.
func tilt_steer() -> float:
	var a := tilt_angle()
	if is_nan(a):
		return 0.0
	if Game.tilt_invert:
		a = -a
	var amount := clampf((absf(a) - TILT_DEADZONE) / maxf(Game.tilt_range - TILT_DEADZONE, 1.0), 0.0, 1.0)
	return amount * signf(a)


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
