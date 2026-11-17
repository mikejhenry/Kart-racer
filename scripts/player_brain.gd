extends RefCounted
## Reads player input (keyboard, gamepad or touch buttons) into a kart.


func think(kart, _delta: float) -> void:
	var steer := Input.get_axis("steer_left", "steer_right")
	# Buttons, keys and sticks still work with tilt on, and win when used.
	if Game.tilt_enabled and absf(steer) < 0.1:
		steer = GameInput.tilt_steer()
	kart.steer_in = steer
	var brake := Input.get_action_strength("brake")
	var gas := Input.get_action_strength("accelerate")
	if GameInput.auto_accelerate and brake < 0.1:
		gas = 1.0
	kart.throttle_in = gas
	kart.brake_in = brake
	kart.drift_in = Input.is_action_pressed("drift")
	if Input.is_action_just_pressed("use_item"):
		kart.use_item()
	if Input.is_action_just_pressed("respawn"):
		kart.respawn()
