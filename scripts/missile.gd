extends Area3D
## Missile power-up. Flies along the track ahead of the kart that fired it and
## homes in on the next kart in front. Spins out whoever it hits.

const SPEED := 55.0
const LIFETIME := 5.0
const HOMING_RANGE := 45.0

var shooter
var track
var _offset := 0.0
var _lateral := 0.0
var _life := LIFETIME


func setup(kart, p_track) -> void:
	shooter = kart
	track = p_track
	var tf: Transform3D = track.frame_at(kart.current_offset)
	_lateral = (kart.global_position - tf.origin).dot(tf.basis.x)
	_offset = kart.current_offset + 3.0
	_place()


func _ready() -> void:
	var shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = 0.9
	shape.shape = sphere_shape
	add_child(shape)

	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.4
	mesh.mesh = capsule
	mesh.rotation.x = PI / 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.25, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.3, 0.1)
	mesh.material_override = mat
	add_child(mesh)

	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	_offset += SPEED * delta
	var target = _find_target()
	var goal_lateral := 0.0
	if target:
		var tf: Transform3D = track.frame_at(target.current_offset)
		goal_lateral = (target.global_position - tf.origin).dot(tf.basis.x)
	_lateral = move_toward(_lateral, goal_lateral, 10.0 * delta)
	_place()
	_life -= delta
	if _life <= 0.0:
		queue_free()


func _place() -> void:
	var tf: Transform3D = track.frame_at(_offset)
	transform = Transform3D(tf.basis, tf.origin + tf.basis.x * _lateral + Vector3.UP * 0.7)


## The nearest kart ahead of the missile within homing range.
func _find_target():
	var best = null
	var best_gap := HOMING_RANGE
	for node in get_tree().get_nodes_in_group("karts"):
		if node == shooter:
			continue
		var gap := fposmod(node.current_offset - _offset, track.length)
		if gap < best_gap:
			best_gap = gap
			best = node
	return best


func _on_body_entered(body: Node3D) -> void:
	if body == shooter or not body.has_method("spin_out"):
		return
	body.spin_out()
	queue_free()
