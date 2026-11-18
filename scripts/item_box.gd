extends Area3D
## Floating item box. Driving through it gives the kart a random power-up
## (if it isn't already holding one). Reappears a few seconds later.

const RESPAWN_TIME := 3.0

var _mesh: MeshInstance3D
var _label: Label3D
var _cooldown := 0.0
var _t := 0.0


func _ready() -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.8, 2.0, 1.8)
	shape.shape = box
	add_child(shape)

	_mesh = MeshInstance3D.new()
	var cube := BoxMesh.new()
	cube.size = Vector3(1.2, 1.2, 1.2)
	_mesh.mesh = cube
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.8, 1.0, 0.75)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.5, 1.0)
	mat.emission_energy_multiplier = 0.6
	_mesh.material_override = mat
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)

	_label = Label3D.new()
	_label.text = "?"
	_label.font_size = 96
	_label.pixel_size = 0.01
	_label.outline_size = 16
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	add_child(_label)

	_t = randf() * TAU
	# Spun every frame in _process, so it needs no physics interpolation.
	_mesh.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	_t += delta
	_mesh.rotation = Vector3(_t * 0.7, _t * 1.3, 0.0)
	_mesh.position.y = sin(_t * 2.0) * 0.15
	if _cooldown > 0.0:
		_cooldown -= delta
		if _cooldown <= 0.0:
			_mesh.visible = true
			_label.visible = true


func _on_body_entered(body: Node3D) -> void:
	if _cooldown > 0.0 or not body.has_method("give_item"):
		return
	body.give_item()
	_cooldown = RESPAWN_TIME
	_mesh.visible = false
	_label.visible = false
