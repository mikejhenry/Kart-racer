extends CharacterBody3D
## Arcade-style kart. A "brain" (player input or AI) fills in the inputs each
## physics frame; this script turns them into driving, drifting, boosts and
## item use. The same script also draws online players' karts (is_remote)
## and the time trial ghost (is_ghost).

const Missile := preload("res://scripts/missile.gd")
const OilSlick := preload("res://scripts/oil_slick.gd")

const MAX_SPEED := 30.0
const ACCEL := 15.0
const BRAKE_DECEL := 35.0
const REVERSE_MAX := 9.0
const COAST_DECEL := 6.0
const OVERSPEED_DECEL := 25.0
const TURN_RATE := 2.1
const GRAVITY := 30.0
const OFFROAD_FACTOR := 0.45
const BOOST_EXTRA := 10.0
const DRIFT_MIN_SPEED := 12.0
const SPIN_DURATION := 1.1
const SHIELD_TIME := 8.0
const ROULETTE_TIME := 1.0
const INTERP_DELAY := 0.12      ## Remote karts are drawn this far in the past

const STYLES := ["classic", "speedster", "buggy"]
const STYLE_NAMES := {"classic": "Classic", "speedster": "Speedster", "buggy": "Buggy"}
const ITEM_ODDS := {
	"front": [["oil", 40], ["shield", 25], ["missile", 25], ["nitro", 10]],
	"middle": [["nitro", 25], ["missile", 25], ["triple", 15], ["oil", 15], ["shield", 15], ["storm", 5]],
	"back": [["nitro", 35], ["triple", 25], ["storm", 20], ["missile", 15], ["shield", 5]],
}

signal item_changed(item: String, count: int)
## Emitted when this kart uses an item, so online races can tell the others.
## target_id is set for the storm (who it hit).
signal item_used(kind: String, at: Vector3, target_id: String)

var body_color := Color(0.9, 0.2, 0.2)
var style := "classic"
var net_id := ""          ## Player or bot id in online races
var is_remote := false    ## Driven by network updates from another device
var is_ghost := false     ## Time trial ghost: see-through, no collisions
var is_human := false     ## The local player's own kart (sounds, vibration)
var preview := false      ## Just for show (garage): no physics or sound
var track                 ## The Track node (scripts/track.gd)
var brain                 ## Any object with think(kart, delta)
var can_drive := false
var class_speed := 1.0    ## Speed class from the difficulty setting
var skill := 1.0          ## AI base speed multiplier
var speed_factor := 1.0   ## Current multiplier (rubber-banding adjusts this)
var place := 1            ## Race position, kept up to date by race.gd
var racers := 6           ## How many karts are in the race

# Inputs, written by the brain every frame
var steer_in := 0.0      ## -1 left .. 1 right
var throttle_in := 0.0   ## 0..1
var brake_in := 0.0      ## 0..1
var drift_in := false

# Driving state
var speed := 0.0
var drifting := false
var drift_dir := 0.0
var drift_charge := 0.0
var boost_time := 0.0
var spin_time := 0.0
var shield_time := 0.0
var offroad := false
var air_time := 0.0
var item := ""
var item_count := 0

# Race progress: distance along the track, counting laps
var current_offset := 0.0
var prev_offset := 0.0
var progress := 0.0
var finish_order := -1

var _tilt: Node3D        # follows the slope of the road
var _visual: Node3D      # drift yaw, lean, hop and spin
var _front_wheels: Array[MeshInstance3D] = []
var _sparks: Array[CPUParticles3D] = []
var _shield_mesh: MeshInstance3D
var _engine: AudioStreamPlayer3D
var _drift_sound: AudioStreamPlayer3D
var _hop_t := 1.0
var _roll_time := 0.0
var _pending_item := ""
var _outside_time := 0.0
var _was_boosting := false
var _ground_vy := 0.0      # vertical speed while driving up or down the road

# Remote karts: recent snapshots, drawn slightly in the past for smoothness
var _snaps: Array = []
var _clock_offset := INF
var _ghost_mats: Array = []


func _ready() -> void:
	floor_snap_length = 0.6
	if is_ghost:
		collision_layer = 0
		collision_mask = 0
	else:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(1.5, 0.9, 2.3)
		shape.shape = box
		shape.position.y = 0.45
		add_child(shape)
	_build_visual()
	if preview:
		set_physics_process(false)
		return
	if not is_ghost:
		_engine = Sfx.make_kart_loop(self, "engine", -9.0 if is_human else -16.0)
		_drift_sound = Sfx.make_kart_loop(self, "drift", -8.0)


func _physics_process(delta: float) -> void:
	if is_ghost:
		return
	if is_remote:
		_remote_step(delta)
		_update_sounds()
		return
	if brain:
		brain.think(self, delta)
	if not can_drive or spin_time > 0.0:
		throttle_in = 0.0
		brake_in = 0.0
		drift_in = false
	if spin_time > 0.0:
		spin_time -= delta
		steer_in = 0.0
		drifting = false
	if shield_time > 0.0:
		shield_time -= delta
	if _roll_time > 0.0:
		_roll_time -= delta
		if _roll_time <= 0.0:
			item = _pending_item
			item_count = 3 if item == "triple" else 1
			item_changed.emit(item, item_count)

	_update_speed(delta)
	_update_drift(delta)
	_update_steering(delta)
	_move(delta)
	_update_track_position(delta)
	_update_visual(delta)
	_update_sounds()


# --- Items ------------------------------------------------------------------

## Called by item boxes. Returns false if the kart already has an item.
func give_item() -> bool:
	if item != "" or _roll_time > 0.0 or is_remote or is_ghost:
		return false
	var band := "middle"
	if place <= maxi(1, int(racers / 3.0)):
		band = "front"
	elif place > int(racers * 2.0 / 3.0):
		band = "back"
	_pending_item = _pick(ITEM_ODDS[band])
	_roll_time = ROULETTE_TIME
	item_changed.emit("?", 0)
	if is_human:
		Sfx.play("item_get")
		Game.vibrate(30)
	return true


func has_item_ready() -> bool:
	return item != "" and _roll_time <= 0.0


func use_item() -> void:
	if not has_item_ready() or not can_drive or spin_time > 0.0:
		return
	var kind := item
	var at := global_position
	var target_id := ""
	match kind:
		"nitro":
			boost_time = 1.5
		"oil":
			var back := global_transform.basis.z
			back.y = 0.0
			at = global_position + back.normalized() * 2.8
		"shield":
			shield_time = SHIELD_TIME
			Sfx.play_at("shield", global_position)
		"storm":
			var target = _storm_target()
			if target:
				target_id = target.net_id
				target.storm_hit()
	var effect := "missile" if kind == "triple" else kind
	spawn_item_effect(effect, at)
	item_count -= 1
	if item_count <= 0:
		item = ""
		item_count = 0
	item_changed.emit(item, item_count)
	item_used.emit(effect, at, target_id)


## Creates the missile or oil slick for an item this kart used. Also called
## for remote karts when another player uses an item.
func spawn_item_effect(kind: String, at: Vector3) -> void:
	match kind:
		"missile":
			var missile := Missile.new()
			missile.setup(self, track)
			get_parent().add_child(missile)
			Sfx.play_at("missile", global_position)
		"oil":
			var slick := OilSlick.new()
			slick.position = at
			get_parent().add_child(slick)
			Sfx.play_at("oil", at, -4.0)


## Lightning from the storm item: shows a bolt, then spins the kart out.
func storm_hit() -> void:
	var bolt := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.5, 40.0, 0.5)
	bolt.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.85, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.6, 0.8, 1.0)
	mat.emission_energy_multiplier = 4.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bolt.material_override = mat
	bolt.position = Vector3(0, 20.0, 0)
	add_child(bolt)
	get_tree().create_timer(0.35).timeout.connect(bolt.queue_free)
	Sfx.play_at("storm", global_position)
	spin_out()


## Hit by a missile, oil slick or storm. A shield absorbs one hit. Remote
## karts handle their own hits on their owner's device.
func spin_out() -> void:
	if spin_time > 0.0 or is_remote or is_ghost:
		return
	if shield_time > 0.0:
		shield_time = 0.0
		Sfx.play_at("shield", global_position, -2.0, 0.7)
		return
	spin_time = SPIN_DURATION
	speed *= 0.35
	boost_time = 0.0
	drifting = false
	Sfx.play_at("hit", global_position)
	if is_human:
		Game.vibrate(220)


func hit_boost_pad() -> void:
	if is_remote or is_ghost:
		return
	boost_time = maxf(boost_time, 1.0)
	if is_human:
		Sfx.play("pad")
		Game.vibrate(40)


func _pick(table: Array) -> String:
	var total := 0
	for row in table:
		total += int(row[1])
	var r := randi() % total
	for row in table:
		r -= int(row[1])
		if r < 0:
			return str(row[0])
	return str(table[0][0])


## The race leader (or second place, if this kart is leading).
func _storm_target():
	var best = null
	for k in get_tree().get_nodes_in_group("karts"):
		if k == self or k.finish_order > 0:
			continue
		if best == null or k.place < best.place:
			best = k
	return best


# --- Driving ----------------------------------------------------------------

func _update_speed(delta: float) -> void:
	var top := MAX_SPEED * class_speed * speed_factor
	if boost_time > 0.0:
		boost_time -= delta
		top += BOOST_EXTRA * class_speed
		speed = move_toward(speed, top, ACCEL * 3.0 * delta)
		return
	if offroad:
		top *= OFFROAD_FACTOR

	var accel := ACCEL * class_speed
	if spin_time > 0.0:
		speed = move_toward(speed, 0.0, BRAKE_DECEL * 0.5 * delta)
	elif brake_in > 0.05 and throttle_in < 0.05:
		if speed > 0.5:
			speed = move_toward(speed, 0.0, BRAKE_DECEL * brake_in * delta)
		else:
			speed = move_toward(speed, -REVERSE_MAX, accel * 0.6 * delta)
	elif speed > top:
		speed = move_toward(speed, top, OVERSPEED_DECEL * delta)
	elif throttle_in > 0.05:
		# More punch off the line, gentler near top speed
		var punch := lerpf(1.5, 0.7, clampf(speed / top, 0.0, 1.0))
		speed = move_toward(speed, top, accel * punch * throttle_in * delta)
	else:
		speed = move_toward(speed, 0.0, COAST_DECEL * delta)


func _update_drift(delta: float) -> void:
	if not drifting:
		if drift_in and absf(steer_in) > 0.3 and speed > DRIFT_MIN_SPEED and is_on_floor():
			drifting = true
			drift_dir = signf(steer_in)
			drift_charge = 0.0
			_hop_t = 0.0
		return
	if not drift_in or speed < DRIFT_MIN_SPEED * 0.7:
		# Releasing a charged drift gives a mini-turbo
		if drift_charge >= 2.0:
			boost_time = 1.2
		elif drift_charge >= 1.0:
			boost_time = 0.6
		drifting = false
		return
	# Steering into the drift charges the mini-turbo faster
	drift_charge += delta * (0.8 + 0.5 * clampf(steer_in * drift_dir, 0.0, 1.0))


func _update_steering(delta: float) -> void:
	var turn: float
	if drifting:
		# Always turn into the drift; steering widens or tightens the arc
		turn = drift_dir * (1.0 + 0.75 * steer_in * drift_dir) * TURN_RATE * 1.1
	else:
		turn = steer_in * TURN_RATE
	var low_speed := clampf(absf(speed) / 6.0, 0.0, 1.0)
	var high_speed := lerpf(1.0, 0.75, clampf(absf(speed) / (MAX_SPEED * class_speed), 0.0, 1.0))
	rotate_y(-turn * low_speed * high_speed * signf(speed) * delta)


func _move(delta: float) -> void:
	var forward := -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var grip := 3.5 if drifting else 10.0
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	flat = flat.lerp(forward * speed, 1.0 - exp(-grip * delta))
	velocity.x = flat.x
	velocity.z = flat.z
	var was_in_air := air_time
	if is_on_floor():
		velocity.y = -0.5
		air_time = 0.0
	else:
		if air_time == 0.0:
			# Just left the ground: keep the climb speed, so ramps launch you.
			velocity.y = maxf(_ground_vy, 0.0) * 1.5
		velocity.y -= GRAVITY * delta
		air_time += delta
	var y_before := global_position.y
	move_and_slide()
	if is_on_floor():
		_ground_vy = (global_position.y - y_before) / delta
	if is_on_floor() and was_in_air > 0.35:
		_hop_t = 0.5
		Sfx.play_at("land", global_position, -4.0)
		if is_human:
			Game.vibrate(60)

	# Scraping a wall or another kart costs speed
	for i in get_slide_collision_count():
		var hit := get_slide_collision(i)
		if absf(hit.get_normal().y) < 0.6:
			var actual := Vector3(velocity.x, 0.0, velocity.z).dot(forward)
			if speed > 0.0 and actual < speed:
				if speed - actual > 8.0:
					Sfx.play_at("bump", global_position, -6.0)
					if is_human:
						Game.vibrate(50)
				speed = lerpf(speed, maxf(actual, 0.0), 0.5)
			break

	if global_position.y < -10.0:
		respawn()


func _update_track_position(delta: float) -> void:
	if track == null:
		return
	var o: float = track.get_offset(global_position)
	var length: float = track.length
	var d := o - prev_offset
	if d > length * 0.5:
		d -= length
	elif d < -length * 0.5:
		d += length
	progress += d
	prev_offset = o
	current_offset = o
	var center: Vector3 = track.point_at(o)
	var lateral := Vector2(global_position.x - center.x, global_position.z - center.z).length()
	offroad = lateral > track.offroad_distance
	# Thrown outside the barriers (e.g. off a jump): put the kart back.
	var outside: bool = lateral > track.wall_distance + 1.5 and not track.near_shortcut(o)
	_outside_time = _outside_time + delta if outside or lateral > 70.0 else 0.0
	if _outside_time > 1.5:
		_outside_time = 0.0
		respawn()


func place_at(offset: float, lateral: float) -> void:
	var tf: Transform3D = track.frame_at(offset)
	global_transform = Transform3D(tf.basis, tf.origin + tf.basis.x * lateral + Vector3.UP * 0.2)
	reset_physics_interpolation()
	velocity = Vector3.ZERO
	speed = 0.0
	drifting = false
	boost_time = 0.0
	prev_offset = track.get_offset(global_position)
	current_offset = prev_offset


func respawn() -> void:
	place_at(current_offset, 0.0)


# --- Online -----------------------------------------------------------------

## Compact snapshot of this kart, sent about 10 times a second.
func network_state() -> Array:
	var level := 0
	if drifting:
		level = 2 if drift_charge >= 2.0 else (1 if drift_charge >= 1.0 else 0)
	return [
		snappedf(global_position.x, 0.01), snappedf(global_position.y, 0.01), snappedf(global_position.z, 0.01),
		snappedf(rotation.y, 0.001), snappedf(speed, 0.01), snappedf(progress, 0.01),
		snappedf(spin_time, 0.01), drift_dir if drifting else 0.0, level,
		1 if boost_time > 0.0 else 0, snappedf(steer_in, 0.01), 1 if shield_time > 0.0 else 0,
	]


## sent_at is the sender's own clock (seconds) when it took the snapshot.
func apply_remote(d: Array, sent_at: float) -> void:
	if d.size() < 12:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var off := now - sent_at
	# The quickest packet seen tells us the clock difference plus the
	# shortest delay. Big jumps mean the other device restarted.
	if off < _clock_offset or absf(off - _clock_offset) > 2.0:
		_clock_offset = off
	else:
		_clock_offset = lerpf(_clock_offset, off, 0.02)
	var pos := Vector3(d[0], d[1], d[2])
	if _snaps.is_empty():
		global_position = pos
		rotation.y = d[3]
		reset_physics_interpolation()
	_snaps.append([sent_at, pos, float(d[3])])
	while _snaps.size() > 30:
		_snaps.pop_front()
	speed = d[4]
	progress = d[5]
	spin_time = d[6]
	drift_dir = d[7]
	drifting = drift_dir != 0.0
	drift_charge = float(d[8])
	boost_time = 0.2 if d[9] else 0.0
	steer_in = d[10]
	shield_time = 1.0 if d[11] else 0.0


func show_name_tag(text: String) -> void:
	var tag := Label3D.new()
	tag.text = text
	tag.font_size = 56
	tag.pixel_size = 0.01
	tag.outline_size = 12
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position = Vector3(0, 2.4, 0)
	add_child(tag)


func _remote_step(delta: float) -> void:
	if _snaps.is_empty():
		_update_visual(delta)
		return
	var render_t := Time.get_ticks_msec() / 1000.0 - _clock_offset - INTERP_DELAY
	var target: Vector3
	var yaw: float
	var last: Array = _snaps[-1]
	if render_t >= last[0]:
		# No newer snapshot yet: carry on in the same direction for a moment.
		var ahead := minf(render_t - last[0], 0.3)
		yaw = last[2]
		target = last[1] + Vector3(-sin(yaw), 0.0, -cos(yaw)) * speed * ahead
	elif render_t <= _snaps[0][0]:
		target = _snaps[0][1]
		yaw = _snaps[0][2]
	else:
		var i := _snaps.size() - 2
		while i > 0 and _snaps[i][0] > render_t:
			i -= 1
		var a: Array = _snaps[i]
		var b: Array = _snaps[i + 1]
		var w := clampf((render_t - a[0]) / maxf(b[0] - a[0], 0.001), 0.0, 1.0)
		target = (a[1] as Vector3).lerp(b[1], w)
		yaw = lerp_angle(a[2], b[2], w)
	var blend := 1.0 - exp(-25.0 * delta)
	global_position = global_position.lerp(target, blend)
	rotation.y = lerp_angle(rotation.y, yaw, blend)
	if track:
		current_offset = track.get_offset(global_position)
	if spin_time > 0.0:
		spin_time = maxf(spin_time - delta, 0.0)
	_update_visual(delta)


# --- Sound ------------------------------------------------------------------

func _update_sounds() -> void:
	if _engine == null:
		return
	var top := MAX_SPEED * class_speed
	_engine.pitch_scale = 0.55 + clampf(absf(speed) / top, 0.0, 1.5) * 0.9
	var drifting_now := drifting and (is_on_floor() or is_remote)
	if drifting_now != _drift_sound.playing:
		if drifting_now:
			_drift_sound.play()
		else:
			_drift_sound.stop()
	var boosting := boost_time > 0.0
	if boosting and not _was_boosting:
		Sfx.play_at("boost", global_position, -2.0 if is_human else -8.0)
	_was_boosting = boosting


# --- Looks ------------------------------------------------------------------

func _build_visual() -> void:
	_tilt = Node3D.new()
	add_child(_tilt)
	_visual = Node3D.new()
	_tilt.add_child(_visual)
	var paint := _material(body_color)
	var trim := _material(body_color.darkened(0.4))
	var dark := _material(Color(0.1, 0.1, 0.12))
	var suit := _material(Color(0.95, 0.95, 0.95))
	var wheel_radius := 0.34
	var wheel_x := 0.82
	var wheel_z := 0.8
	var driver_y := 0.0

	match style:
		"speedster":
			_box(Vector3(1.3, 0.3, 2.6), Vector3(0, 0.38, 0.0), paint)
			_box(Vector3(0.7, 0.22, 0.9), Vector3(0, 0.34, -1.6), paint)
			_box(Vector3(1.9, 0.12, 0.3), Vector3(0, 0.25, -2.0), trim)
			_box(Vector3(1.8, 0.08, 0.45), Vector3(0, 1.0, 1.25), trim)
			_box(Vector3(0.08, 0.5, 0.08), Vector3(-0.6, 0.75, 1.25), dark)
			_box(Vector3(0.08, 0.5, 0.08), Vector3(0.6, 0.75, 1.25), dark)
			_box(Vector3(0.7, 0.25, 0.6), Vector3(0, 0.62, 0.45), dark)
			wheel_radius = 0.3
			wheel_z = 0.95
			driver_y = -0.1
		"buggy":
			_box(Vector3(1.3, 0.45, 1.9), Vector3(0, 0.75, 0.0), paint)
			_box(Vector3(1.1, 0.3, 0.5), Vector3(0, 0.7, -1.15), trim)
			_box(Vector3(0.75, 0.3, 0.6), Vector3(0, 1.05, 0.35), dark)
			# Roll cage
			for x in [-0.6, 0.6]:
				_box(Vector3(0.08, 0.9, 0.08), Vector3(x, 1.4, 0.7), dark)
				_box(Vector3(0.08, 0.08, 1.0), Vector3(x, 1.85, 0.25), dark)
			_box(Vector3(1.28, 0.08, 0.08), Vector3(0, 1.85, 0.7), dark)
			wheel_radius = 0.48
			wheel_x = 0.9
			wheel_z = 0.85
			driver_y = 0.3
		_:
			_box(Vector3(1.4, 0.4, 2.1), Vector3(0, 0.45, 0.0), paint)
			_box(Vector3(1.0, 0.3, 0.7), Vector3(0, 0.42, -1.3), paint)
			_box(Vector3(1.7, 0.15, 0.25), Vector3(0, 0.3, -1.65), trim)
			_box(Vector3(0.75, 0.3, 0.6), Vector3(0, 0.78, 0.4), dark)
			_box(Vector3(1.6, 0.1, 0.35), Vector3(0, 1.05, 1.1), trim)
			_box(Vector3(0.08, 0.4, 0.08), Vector3(-0.55, 0.85, 1.1), dark)
			_box(Vector3(0.08, 0.4, 0.08), Vector3(0.55, 0.85, 1.1), dark)

	_box(Vector3(0.6, 0.45, 0.4), Vector3(0, 0.95 + driver_y, 0.3), suit)   # driver
	var helmet := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.34
	sphere.height = 0.68
	sphere.radial_segments = 16
	sphere.rings = 8
	helmet.mesh = sphere
	helmet.material_override = paint
	helmet.position = Vector3(0, 1.35 + driver_y, 0.25)
	_visual.add_child(helmet)
	_box(Vector3(0.5, 0.15, 0.1), Vector3(0, 1.37 + driver_y, -0.07), dark)   # visor

	var wheel_mesh := CylinderMesh.new()
	wheel_mesh.top_radius = wheel_radius
	wheel_mesh.bottom_radius = wheel_radius
	wheel_mesh.height = 0.34
	wheel_mesh.radial_segments = 12
	wheel_mesh.rings = 1
	for z in [-wheel_z, wheel_z]:
		for x in [-wheel_x, wheel_x]:
			var wheel := MeshInstance3D.new()
			wheel.mesh = wheel_mesh
			wheel.material_override = dark
			wheel.rotation.z = PI / 2.0
			wheel.position = Vector3(x, wheel_radius, z)
			_visual.add_child(wheel)
			if z < 0.0:
				_front_wheels.append(wheel)

	# Drift / boost sparks from the rear wheels
	var spark_mesh := QuadMesh.new()
	spark_mesh.size = Vector2(0.2, 0.2)
	var spark_mat := StandardMaterial3D.new()
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	spark_mat.vertex_color_use_as_albedo = true
	spark_mesh.material = spark_mat
	for x in [-wheel_x, wheel_x]:
		var p := CPUParticles3D.new()
		p.mesh = spark_mesh
		p.amount = 12
		p.lifetime = 0.35
		p.emitting = false
		p.local_coords = false
		p.direction = Vector3(0, 1, 1)
		p.spread = 35.0
		p.initial_velocity_min = 2.0
		p.initial_velocity_max = 4.5
		p.gravity = Vector3(0, -12, 0)
		p.position = Vector3(x, 0.15, wheel_z + 0.35)
		_visual.add_child(p)
		_sparks.append(p)

	# Shield bubble
	_shield_mesh = MeshInstance3D.new()
	var bubble := SphereMesh.new()
	bubble.radius = 1.7
	bubble.height = 3.0
	bubble.radial_segments = 20
	bubble.rings = 10
	_shield_mesh.mesh = bubble
	var shield_mat := StandardMaterial3D.new()
	shield_mat.albedo_color = Color(0.4, 0.8, 1.0, 0.25)
	shield_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shield_mat.emission_enabled = true
	shield_mat.emission = Color(0.3, 0.6, 1.0)
	shield_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shield_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_shield_mesh.material_override = shield_mat
	_shield_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shield_mesh.position.y = 0.9
	_shield_mesh.visible = false
	add_child(_shield_mesh)


func _update_visual(delta: float) -> void:
	var blend := 1.0 - exp(-10.0 * delta)
	# Follow the slope of the road
	if not is_remote and is_on_floor():
		var n := global_transform.basis.inverse() * get_floor_normal()
		_tilt.rotation.x = lerpf(_tilt.rotation.x, atan2(n.z, n.y), blend)
		_tilt.rotation.z = lerpf(_tilt.rotation.z, -atan2(n.x, n.y), blend)
	elif not is_remote:
		_tilt.rotation.x = lerpf(_tilt.rotation.x, 0.0, blend * 0.3)
		_tilt.rotation.z = lerpf(_tilt.rotation.z, 0.0, blend * 0.3)

	if spin_time > 0.0:
		_visual.rotation.y = spin_time / SPIN_DURATION * TAU * 2.0
	else:
		var yaw := -drift_dir * 0.35 if drifting else 0.0
		_visual.rotation.y = lerpf(_visual.rotation.y, yaw, blend)
	var lean := -steer_in * 0.05 * clampf(speed / MAX_SPEED, 0.0, 1.0)
	_visual.rotation.z = lerpf(_visual.rotation.z, lean, blend)
	if _hop_t < 1.0:
		_hop_t = minf(_hop_t + delta * 4.0, 1.0)
	_visual.position.y = sin(_hop_t * PI) * 0.3
	for wheel in _front_wheels:
		wheel.rotation.y = -steer_in * 0.45
	_shield_mesh.visible = shield_time > 0.0

	var level := 0
	if drifting:
		if drift_charge >= 2.0:
			level = 2
		elif drift_charge >= 1.0:
			level = 1
	var color := Color(1.0, 0.9, 0.4)
	if level == 1:
		color = Color(0.3, 0.7, 1.0)
	elif level == 2:
		color = Color(1.0, 0.5, 0.1)
	var on := level > 0 or boost_time > 0.0
	for s in _sparks:
		s.emitting = on
		s.color = color


func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.55
	if is_ghost:
		m.albedo_color.a = 0.35
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_mats.append(m)
	return m


## Ghost only: how see-through it is (0 = invisible). The ghost fades out as
## you drive through it, so overtaking it never looks like a crash.
func set_ghost_alpha(a: float) -> void:
	for m in _ghost_mats:
		m.albedo_color.a = a


func _box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	_visual.add_child(mi)
