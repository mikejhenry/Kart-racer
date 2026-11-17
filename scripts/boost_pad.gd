extends Area3D
## Glowing pad on the road. Driving over it gives a short speed boost.

func _ready() -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 1.5, 5.0)
	shape.shape = box
	shape.position.y = 0.75
	add_child(shape)

	var plate := MeshInstance3D.new()
	var plate_mesh := BoxMesh.new()
	plate_mesh.size = Vector3(4.0, 0.05, 5.0)
	plate.mesh = plate_mesh
	plate.material_override = _glow(Color(1.0, 0.45, 0.05), 1.2)
	plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(plate)
	# Three chevrons pointing in the racing direction (-Z)
	for i in 3:
		for side in [-1.0, 1.0]:
			var bar := MeshInstance3D.new()
			var bar_mesh := BoxMesh.new()
			bar_mesh.size = Vector3(1.9, 0.06, 0.35)
			bar.mesh = bar_mesh
			bar.material_override = _glow(Color(1.0, 0.95, 0.5), 2.0)
			bar.position = Vector3(0.75 * side, 0.03, 1.4 - i * 1.4)
			bar.rotation.y = -0.6 * side
			add_child(bar)
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if body.has_method("hit_boost_pad"):
		body.hit_boost_pad()


func _glow(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m
