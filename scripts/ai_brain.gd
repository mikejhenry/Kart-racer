extends RefCounted
## Simple racing AI: aims at a point further along the track, eases off for
## sharp bends, uses items, and backs up or respawns when stuck.

var track
var lane := 0.0
var _lane_target := 0.0
var _lane_timer := 0.0
var _stuck_time := 0.0
var _reverse_time := 0.0
var _item_delay := -1.0


func _init(p_track, p_lane: float = 0.0) -> void:
	track = p_track
	lane = p_lane
	_lane_target = p_lane


func think(kart, delta: float) -> void:
	var o: float = kart.current_offset
	var spd: float = kart.speed

	# Drift between lanes now and then so the pack spreads out
	_lane_timer -= delta
	if _lane_timer <= 0.0:
		_lane_timer = randf_range(2.0, 5.0)
		_lane_target = randf_range(-5.0, 5.0)
	lane = move_toward(lane, _lane_target, 2.0 * delta)

	# Steer toward a point ahead on the racing line
	var look := 8.0 + maxf(spd, 0.0) * 0.45
	var tf: Transform3D = track.frame_at(o + look)
	var target := tf.origin + tf.basis.x * lane
	var local: Vector3 = kart.to_local(target)
	var steer := clampf(atan2(local.x, -local.z) * 2.5, -1.0, 1.0)

	# Ease off for sharp bends further ahead
	var far: Transform3D = track.frame_at(o + look * 2.5)
	var heading: Vector3 = -kart.global_transform.basis.z
	var bend := heading.dot(-far.basis.z)
	var throttle := 1.0
	var brake := 0.0
	if bend < 0.55 and spd > 22.0:
		throttle = 0.0
	if bend < 0.2 and spd > 17.0:
		brake = 0.5
		throttle = 0.0

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
	if _reverse_time > 0.0:
		_reverse_time -= delta
		throttle = 0.0
		brake = 1.0
		steer = -steer

	kart.steer_in = steer
	kart.throttle_in = throttle
	kart.brake_in = brake
	kart.drift_in = false

	_think_items(kart, delta, bend)


func _think_items(kart, delta: float, bend: float) -> void:
	if kart.item == "":
		_item_delay = -1.0
		return
	if _item_delay < 0.0:
		_item_delay = randf_range(0.8, 3.0)
	_item_delay -= delta
	if _item_delay > 0.0:
		return
	# Save nitro for a straight
	if kart.item == "nitro" and bend < 0.85:
		return
	kart.use_item()
