extends Area3D
## Oil slick power-up, dropped behind a kart. The next kart to drive over it
## spins out.

const LIFETIME := 30.0
const ARM_TIME := 0.3

var _life := LIFETIME


func _ready() -> void:
	var shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = 1.4
	cylinder.height = 1.2
	shape.shape = cylinder
	shape.position.y = 0.5
	add_child(shape)

	var mesh := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.5
	disc.bottom_radius = 1.5
	disc.height = 0.04
	disc.radial_segments = 20
	disc.rings = 1
	mesh.mesh = disc
	mesh.position.y = 0.07
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.03, 0.08)
	mat.metallic = 0.6
	mat.roughness = 0.1
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)

	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()


func _on_body_entered(body: Node3D) -> void:
	if LIFETIME - _life < ARM_TIME or not body.has_method("spin_out"):
		return
	body.spin_out()
	queue_free()
