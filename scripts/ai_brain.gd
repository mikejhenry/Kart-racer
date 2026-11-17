extends RefCounted
## Racing AI: follows the track's racing line, eases off and drifts through
## bends, uses items with some sense, and gets itself unstuck.
## level: 0 = easy, 1 = normal, 2 = hard.

var track
var level := 1
var _wander := 0.0
var _wander_target := 0.0
var _wander_timer := 0.0
var _stuck_time := 0.0
var _reverse_time := 0.0
var _item_hold := 0.0
var _watch_progress := -INF
var _watch_timer := 0.0


func _init(p_track, p_level: int = 1) -> void:
	track = p_track
	level = p_level


func think(kart, delta: float) -> void:
	var o: float = kart.current_offset
	var spd: float = kart.speed

	# Weave a little around the racing line so the pack spreads out.
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = randf_range(2.0, 5.0)
		var spread: float = [3.5, 2.0, 1.0][level]
		_wander_target = randf_range(-spread, spread)
	_wander = move_toward(_wander, _wander_target, 2.0 * delta)

	# Steer toward a point ahead on the racing line
	var look := 8.0 + maxf(spd, 0.0) * 0.45
	var tf: Transform3D = track.frame_at(o + look)
	var line: float = track.racing_line_at(o + look) * [0.4, 0.8, 1.0][level]
	var target := tf.origin + tf.basis.x * clampf(line + _wander, -7.0, 7.0)
	var local: Vector3 = kart.to_local(target)
	var steer := clampf(atan2(local.x, -local.z) * 2.5, -1.0, 1.0)

	# How sharp is the road ahead? 1 = straight, lower = tighter bend.
	var heading: Vector3 = -kart.global_transform.basis.z
	heading.y = 0.0
	heading = heading.normalized()
	var far: Transform3D = track.frame_at(o + look * 2.5)
	var bend := heading.dot(-far.basis.z)
	var near: Transform3D = track.frame_at(o + look)
	var near_bend := heading.dot(-near.basis.z)

	var throttle := 1.0
	var brake := 0.0
	var ease_at: float = [0.7, 0.55, 0.45][level]
	if bend < ease_at and spd > 22.0:
		throttle = 0.0
	if bend < ease_at - 0.35 and spd > 17.0:
		brake = 0.5
		throttle = 0.0

	# Drift through longer bends for a mini-turbo (normal and hard only).
	# Judged by the road's own shape, since drifting turns the kart itself.
	var drift := false
	if level >= 1:
		var here: Transform3D = track.frame_at(o)
		var road_bend := (-here.basis.z).dot(-near.basis.z)
		if kart.drifting:
			# Hold it through the bend; counter-steering just widens the arc.
			# Stay in it a little longer if the mini-turbo is nearly charged.
			var hold := 0.998 if kart.drift_charge < 1.05 else 0.985
			# Let go before sliding onto the inside curb.
			var lateral: float = (kart.global_position - here.origin).dot(here.basis.x) * kart.drift_dir
			drift = road_bend < hold and lateral < track.road_half_width - 1.5
		else:
			drift = road_bend < 0.92 and spd > 18.0 and absf(steer) > 0.35

	# Get unstuck: back up for a moment, respawn if that doesn't work
	if kart.can_drive and kart.spin_time <= 0.0 and absf(spd) < 2.0:
		_stuck_time += delta
	else:
		_stuck_time = 0.0
	if _stuck_time > 1.5 and _reverse_time <= 0.0:
		_reverse_time = 1.0
	if _stuck_time > 5.0:
		kart.respawn()
		_stuck_time = 0.0
	# Moving but getting nowhere (e.g. scraping along a wall): reset.
	if kart.can_drive and kart.spin_time <= 0.0:
		_watch_timer += delta
		if _watch_timer > 4.0:
			if kart.progress - _watch_progress < 5.0:
				kart.respawn()
			_watch_progress = kart.progress
			_watch_timer = 0.0
	if _reverse_time > 0.0:
		_reverse_time -= delta
		throttle = 0.0
		brake = 1.0
		steer = -steer
		drift = false

	kart.steer_in = steer
	kart.throttle_in = throttle
	kart.brake_in = brake
	kart.drift_in = drift
	_think_items(kart, delta, bend)


func _think_items(kart, delta: float, bend: float) -> void:
	if not kart.has_item_ready():
		_item_hold = 0.0
		return
	_item_hold += delta
	if _item_hold < [2.0, 0.8, 0.4][level]:
		return
	var item: String = kart.item
	var use := false
	if level == 0:
		use = _item_hold > 3.0
	else:
		match item:
			"nitro":
				use = bend > 0.85
			"missile", "triple":
				use = _gap_to_kart(kart, true) < 60.0 or _item_hold > 6.0
			"oil":
				use = _gap_to_kart(kart, false) < 25.0 or _item_hold > 8.0
			"shield", "storm":
				use = true
			_:
				use = true
	if use:
		kart.use_item()
		_item_hold = 0.0


## Distance along the track to the nearest kart ahead (or behind).
func _gap_to_kart(kart, ahead: bool) -> float:
	var best := INF
	for k in kart.get_tree().get_nodes_in_group("karts"):
		if k == kart:
			continue
		var gap: float = (k.progress - kart.progress) if ahead else (kart.progress - k.progress)
		if gap > 0.0 and gap < best:
			best = gap
	return best
