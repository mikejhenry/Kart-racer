extends CharacterBody3D
## Arcade-style kart. A "brain" (player input or AI) fills in the inputs each
## physics frame; this script turns them into driving, drifting, boosts and
## item use.

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

signal item_changed(item: String)

var body_color := Color(0.9, 0.2, 0.2)
var track          ## The Track node (scripts/track.gd)
var brain          ## Any object with think(kart, delta)
var can_drive := false
var skill := 1.0          ## AI base speed multiplier
var speed_factor := 1.0   ## Current multiplier (rubber-banding adjusts this)
var place := 1            ## Race position, kept up to date by main.gd

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
var offroad := false
var item := ""

# Race progress: distance along the track, counting laps
var current_offset := 0.0
var prev_offset := 0.0
var progress := 0.0
var finish_order := -1

var _visual: Node3D
var _front_wheels: Array[MeshInstance3D] = []
var _sparks: Array[CPUParticles3D] = []
var _hop_t := 1.0


func _ready() -> void:
	floor_snap_length = 0.6
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.5, 0.9, 2.3)
	shape.shape = box
	shape.position.y = 0.45
	add_child(shape)
	_build_visual()


func _physics_process(delta: float) -> void:
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

	_update_speed(delta)
	_update_drift(delta)
	_update_steering(delta)
	_move(delta)
	_update_track_position()
	_update_visual(delta)


# --- Items ------------------------------------------------------------------

## Called by item boxes. Returns false if the kart already holds an item.
func give_item() -> bool:
	if item != "":
		return false
	# Karts further back get better odds of the catch-up items.
	var r := randf()
	if place <= 2:
		item = "oil" if r < 0.6 else ("missile" if r < 0.9 else "nitro")
	elif place >= 5:
		item = "nitro" if r < 0.6 else ("missile" if r < 0.95 else "oil")
	else:
		item = "nitro" if r < 0.35 else ("missile" if r < 0.7 else "oil")
	item_changed.emit(item)
	return true


func use_item() -> void:
	if item == "" or not can_drive or spin_time > 0.0:
		return
	match item:
		"nitro":
			boost_time = 1.5
		"missile":
			var missile := Missile.new()
			missile.setup(self, track)
			get_parent().add_child(missile)
		"oil":
			var slick := OilSlick.new()
			var back := global_transform.basis.z
			back.y = 0.0
			slick.position = global_position + back.normalized() * 2.8
			get_parent().add_child(slick)
	item = ""
	item_changed.emit(item)


## Hit by a missile or oil slick.
func spin_out() -> void:
	if spin_time > 0.0:
		return
	spin_time = SPIN_DURATION
	speed *= 0.35
	boost_time = 0.0
	drifting = false


# --- Driving ----------------------------------------------------------------

func _update_speed(delta: float) -> void:
	var top := MAX_SPEED * speed_factor
	if boost_time > 0.0:
		boost_time -= delta
		top += BOOST_EXTRA
		speed = move_toward(speed, top, ACCEL * 3.0 * delta)
		return
	if offroad:
		top *= OFFROAD_FACTOR

	if spin_time > 0.0:
		speed = move_toward(speed, 0.0, BRAKE_DECEL * 0.5 * delta)
	elif brake_in > 0.05 and throttle_in < 0.05:
		if speed > 0.5:
			speed = move_toward(speed, 0.0, BRAKE_DECEL * brake_in * delta)
		else:
			speed = move_toward(speed, -REVERSE_MAX, ACCEL * 0.6 * delta)
	elif speed > top:
		speed = move_toward(speed, top, OVERSPEED_DECEL * delta)
	elif throttle_in > 0.05:
		# More punch off the line, gentler near top speed
		var punch := lerpf(1.5, 0.7, clampf(speed / top, 0.0, 1.0))
		speed = move_toward(speed, top, ACCEL * punch * throttle_in * delta)
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
	drift_charge += delta * (0.6 + 0.6 * clampf(steer_in * drift_dir, 0.0, 1.0))


func _update_steering(delta: float) -> void:
	var turn: float
	if drifting:
		# Always turn into the drift; steering widens or tightens the arc
		turn = drift_dir * (1.0 + 0.55 * steer_in * drift_dir) * TURN_RATE * 1.1
	else:
		turn = steer_in * TURN_RATE
	var low_speed := clampf(absf(speed) / 6.0, 0.0, 1.0)
	var high_speed := lerpf(1.0, 0.75, clampf(absf(speed) / MAX_SPEED, 0.0, 1.0))
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
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()

	# Scraping a wall or another kart costs speed
	for i in get_slide_collision_count():
		var hit := get_slide_collision(i)
		if absf(hit.get_normal().y) < 0.6:
			var actual := Vector3(velocity.x, 0.0, velocity.z).dot(forward)
			if speed > 0.0 and actual < speed:
				speed = lerpf(speed, maxf(actual, 0.0), 0.5)
			break

	if global_position.y < -10.0:
		respawn()


func _update_track_position() -> void:
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


func place_at(offset: float, lateral: float) -> void:
	var tf: Transform3D = track.frame_at(offset)
	global_transform = Transform3D(tf.basis, tf.origin + tf.basis.x * lateral + Vector3.UP * 0.2)
	velocity = Vector3.ZERO
	speed = 0.0
	drifting = false
	boost_time = 0.0
	prev_offset = track.get_offset(global_position)
	current_offset = prev_offset


func respawn() -> void:
	place_at(current_offset, 0.0)


# --- Looks ------------------------------------------------------------------

func _build_visual() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	var paint := _material(body_color)
	var trim := _material(body_color.darkened(0.4))
	var dark := _material(Color(0.1, 0.1, 0.12))
	var suit := _material(Color(0.95, 0.95, 0.95))

	_box(Vector3(1.4, 0.4, 2.1), Vector3(0, 0.45, 0.0), paint)       # chassis
	_box(Vector3(1.0, 0.3, 0.7), Vector3(0, 0.42, -1.3), paint)      # nose
	_box(Vector3(1.7, 0.15, 0.25), Vector3(0, 0.3, -1.65), trim)     # front bumper
	_box(Vector3(0.75, 0.3, 0.6), Vector3(0, 0.78, 0.4), dark)       # seat
	_box(Vector3(0.6, 0.45, 0.4), Vector3(0, 0.95, 0.3), suit)       # driver
	_box(Vector3(1.6, 0.1, 0.35), Vector3(0, 1.05, 1.1), trim)       # spoiler
	_box(Vector3(0.08, 0.4, 0.08), Vector3(-0.55, 0.85, 1.1), dark)
	_box(Vector3(0.08, 0.4, 0.08), Vector3(0.55, 0.85, 1.1), dark)

	var helmet := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.34
	sphere.height = 0.68
	sphere.radial_segments = 16
	sphere.rings = 8
	helmet.mesh = sphere
	helmet.material_override = paint
	helmet.position = Vector3(0, 1.35, 0.25)
	_visual.add_child(helmet)
	_box(Vector3(0.5, 0.15, 0.1), Vector3(0, 1.37, -0.07), dark)     # visor

	var wheel_mesh := CylinderMesh.new()
	wheel_mesh.top_radius = 0.34
	wheel_mesh.bottom_radius = 0.34
	wheel_mesh.height = 0.34
	wheel_mesh.radial_segments = 12
	wheel_mesh.rings = 1
	for z in [-0.8, 0.8]:
		for x in [-0.82, 0.82]:
			var wheel := MeshInstance3D.new()
			wheel.mesh = wheel_mesh
			wheel.material_override = dark
			wheel.rotation.z = PI / 2.0
			wheel.position = Vector3(x, 0.34, z)
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
	for x in [-0.82, 0.82]:
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
		p.position = Vector3(x, 0.15, 1.15)
		_visual.add_child(p)
		_sparks.append(p)


func _update_visual(delta: float) -> void:
	var blend := 1.0 - exp(-10.0 * delta)
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
	return m


func _box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	_visual.add_child(mi)
