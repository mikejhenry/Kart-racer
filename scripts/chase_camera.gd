extends Camera3D
## Smooth third-person camera that follows a kart and widens its field of
## view with speed.

var target
var distance := 6.5
var height := 2.8
var base_fov := 70.0


func _ready() -> void:
	fov = base_fov
	near = 0.1
	far = 800.0


func snap() -> void:
	if target == null:
		return
	global_position = _desired_position()
	look_at(_look_point(), Vector3.UP)
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	if target == null:
		return
	global_position = global_position.lerp(_desired_position(), 1.0 - exp(-7.0 * delta))
	look_at(_look_point(), Vector3.UP)
	var spd: float = target.speed
	var target_fov := base_fov + clampf(spd / 30.0, 0.0, 1.3) * 10.0
	if target.boost_time > 0.0:
		target_fov += 8.0
	fov = lerpf(fov, target_fov, 1.0 - exp(-4.0 * delta))


func _back() -> Vector3:
	var b: Vector3 = target.global_transform.basis.z
	b.y = 0.0
	return b.normalized()


func _desired_position() -> Vector3:
	return target.global_position + _back() * distance + Vector3.UP * height


func _look_point() -> Vector3:
	return target.global_position + Vector3.UP * 1.2 - _back() * 4.0
