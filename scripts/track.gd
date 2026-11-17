extends Node3D
## Builds a closed-loop race track from a few control points: road with curbs,
## barrier walls (with collision), grass, a start gate, item boxes and trees.
## Edit CONTROL_POINTS to change the layout (x, z in metres, driven in order).

const ItemBox := preload("res://scripts/item_box.gd")

const CONTROL_POINTS := [
	Vector2(0, 0), Vector2(80, 0), Vector2(130, -30), Vector2(140, -90),
	Vector2(100, -130), Vector2(40, -110), Vector2(10, -150), Vector2(-50, -165),
	Vector2(-105, -125), Vector2(-100, -55), Vector2(-60, -5),
]
## Where item box rows sit, as a fraction of the lap.
const ITEM_ROWS := [0.2, 0.52, 0.8]
const SAMPLE_STEP := 2.0

var road_half_width := 9.0
var curb_width := 1.5
var wall_gap := 5.0
var wall_height := 1.2
var items_enabled := true

var curve: Curve3D
var length := 0.0
var offroad_distance := 0.0


func build() -> void:
	curve = Curve3D.new()
	curve.bake_interval = 0.5
	var n := CONTROL_POINTS.size()
	for i in n + 1:
		var handle := (_control_point(i + 1) - _control_point(i - 1)) * 0.25
		curve.add_point(_control_point(i), -handle, handle)
	length = curve.get_baked_length()
	offroad_distance = road_half_width + curb_width * 0.6

	_build_road()
	_build_walls()
	_build_ground()
	_build_start_gate()
	_build_item_boxes()
	_build_trees()


# --- Queries used by karts, AI and items ------------------------------------

## Distance along the track (0..length) of the closest point to world_pos.
func get_offset(world_pos: Vector3) -> float:
	return curve.get_closest_offset(world_pos)


func point_at(offset: float) -> Vector3:
	return curve.sample_baked(fposmod(offset, length), true)


## Transform at a distance along the track: origin on the centre line,
## -Z pointing in the racing direction, +X pointing to the right.
func frame_at(offset: float) -> Transform3D:
	var o := fposmod(offset, length)
	var p := curve.sample_baked(o, true)
	var ahead := curve.sample_baked(fposmod(o + 1.0, length), true)
	var behind := curve.sample_baked(fposmod(o - 1.0, length), true)
	var forward := ahead - behind
	forward.y = 0.0
	return Transform3D(Basis.looking_at(forward.normalized(), Vector3.UP), p)


# --- Construction -----------------------------------------------------------

func _control_point(i: int) -> Vector3:
	var p: Vector2 = CONTROL_POINTS[posmod(i, CONTROL_POINTS.size())]
	return Vector3(p.x, 0.0, p.y)


func _build_road() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := int(length / SAMPLE_STEP)
	var step := length / count
	var asphalt_a := Color(0.24, 0.24, 0.27)
	var asphalt_b := Color(0.27, 0.27, 0.30)
	var line := Color(0.92, 0.92, 0.92)
	for i in count:
		var a := frame_at(i * step)
		var b := frame_at((i + 1) * step)
		# Subtle banding on the asphalt helps you feel your speed.
		var road := asphalt_a if int(i / 4.0) % 2 == 0 else asphalt_b
		_strip(st, a, b, -road_half_width, road_half_width, 0.02, road)
		var curb := Color(0.85, 0.1, 0.1) if i % 2 == 0 else Color(0.95, 0.95, 0.95)
		_strip(st, a, b, road_half_width, road_half_width + curb_width, 0.02, curb)
		_strip(st, a, b, -road_half_width - curb_width, -road_half_width, 0.02, curb)
		if i % 3 == 0:
			_strip(st, a, b, -0.15, 0.15, 0.04, line)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _vertex_color_material(BaseMaterial3D.CULL_DISABLED)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_walls() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := int(length / SAMPLE_STEP)
	var step := length / count
	var dist := road_half_width + curb_width + wall_gap
	var up := Vector3.UP * wall_height
	for i in count:
		var a := frame_at(i * step)
		var b := frame_at((i + 1) * step)
		var color := Color(0.9, 0.15, 0.15) if int(i / 2.0) % 2 == 0 else Color(0.95, 0.95, 0.95)
		for side in [-1.0, 1.0]:
			var a0: Vector3 = a.origin + a.basis.x * dist * side
			var b0: Vector3 = b.origin + b.basis.x * dist * side
			# Both windings, so the barrier looks solid from either side.
			_tri(st, a0, b0, a0 + up, color)
			_tri(st, a0 + up, b0, b0 + up, color)
			_tri(st, a0, a0 + up, b0, color)
			_tri(st, a0 + up, b0 + up, b0, color)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _vertex_color_material(BaseMaterial3D.CULL_BACK)
	add_child(mi)

	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	add_child(body)


func _build_ground() -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1200, 1200)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _grass_texture()
	mat.uv1_scale = Vector3(75, 75, 1)
	mat.roughness = 1.0
	ground.material_override = mat
	add_child(ground)

	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	body.add_child(shape)
	add_child(body)


func _build_start_gate() -> void:
	var tf := frame_at(0.0)
	var right := tf.basis.x
	var forward := -tf.basis.z

	# Chequered line across the road
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cols := 12
	var cell := road_half_width * 2.0 / cols
	for r in 2:
		for c in cols:
			var color := Color.WHITE if (r + c) % 2 == 0 else Color(0.08, 0.08, 0.08)
			var x0 := -road_half_width + c * cell
			var x1 := x0 + cell
			var f0 := (r - 1) * cell
			var f1 := f0 + cell
			var lift := Vector3.UP * 0.05
			var p00 := tf.origin + right * x0 + forward * f0 + lift
			var p10 := tf.origin + right * x1 + forward * f0 + lift
			var p01 := tf.origin + right * x0 + forward * f1 + lift
			var p11 := tf.origin + right * x1 + forward * f1 + lift
			_tri(st, p00, p01, p10, color)
			_tri(st, p10, p01, p11, color)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _vertex_color_material(BaseMaterial3D.CULL_DISABLED)
	add_child(mi)

	# Gate posts and banner
	var post_dist := road_half_width + curb_width + 1.0
	var post_mat := _plain_material(Color(0.2, 0.2, 0.25))
	for side in [-1.0, 1.0]:
		var pos: Vector3 = tf.origin + right * post_dist * side + Vector3.UP * 3.5
		_add_box(Vector3(0.8, 7.0, 0.8), Transform3D(tf.basis, pos), post_mat, true)
	var banner_pos := tf.origin + Vector3.UP * 6.6
	_add_box(Vector3(post_dist * 2.0 + 0.8, 1.6, 0.4), Transform3D(tf.basis, banner_pos), _plain_material(Color(0.1, 0.3, 0.8)), false)
	var label := Label3D.new()
	label.text = "KART RACER"
	label.font_size = 110
	label.pixel_size = 0.01
	label.outline_size = 18
	label.transform = Transform3D(tf.basis, banner_pos + tf.basis.z * 0.25)
	add_child(label)


func _build_item_boxes() -> void:
	if not items_enabled:
		return
	for fraction in ITEM_ROWS:
		var tf := frame_at(length * float(fraction))
		for lateral in [-6.0, -2.0, 2.0, 6.0]:
			var box := ItemBox.new()
			box.position = tf.origin + tf.basis.x * float(lateral) + Vector3.UP * 1.0
			add_child(box)


func _build_trees() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for p in CONTROL_POINTS:
		var v: Vector2 = p
		min_x = minf(min_x, v.x)
		max_x = maxf(max_x, v.x)
		min_z = minf(min_z, v.y)
		max_z = maxf(max_z, v.y)

	var clearance := road_half_width + curb_width + wall_gap + 4.0
	var spots: Array[Transform3D] = []
	var tries := 0
	while spots.size() < 160 and tries < 4000:
		tries += 1
		var pos := Vector3(rng.randf_range(min_x - 90.0, max_x + 90.0), 0.0, rng.randf_range(min_z - 90.0, max_z + 90.0))
		if curve.get_closest_point(pos).distance_to(pos) < clearance:
			continue
		var s := rng.randf_range(0.8, 1.6)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		spots.append(Transform3D(b, pos))

	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.25
	trunk.bottom_radius = 0.35
	trunk.height = 2.0
	trunk.radial_segments = 6
	trunk.rings = 1
	var leaves := CylinderMesh.new()
	leaves.top_radius = 0.0
	leaves.bottom_radius = 2.2
	leaves.height = 5.0
	leaves.radial_segments = 8
	leaves.rings = 1
	# MultiMesh draws all trees of one kind in a single draw call.
	_add_multimesh(trunk, _plain_material(Color(0.45, 0.3, 0.18)), spots, Vector3(0, 1.0, 0))
	_add_multimesh(leaves, _plain_material(Color(0.15, 0.45, 0.2)), spots, Vector3(0, 4.5, 0))


# --- Helpers ----------------------------------------------------------------

## Adds a quad between two track frames, from `from` to `to` metres across.
func _strip(st: SurfaceTool, a: Transform3D, b: Transform3D, from: float, to: float, y: float, color: Color) -> void:
	var lift := Vector3(0, y, 0)
	var a0 := a.origin + a.basis.x * from + lift
	var a1 := a.origin + a.basis.x * to + lift
	var b0 := b.origin + b.basis.x * from + lift
	var b1 := b.origin + b.basis.x * to + lift
	_tri(st, a0, b0, a1, color)
	_tri(st, a1, b0, b1, color)


## Adds one triangle. Godot treats clockwise winding as the front face; the
## normal is computed to match.
func _tri(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, color: Color) -> void:
	var normal := (v2 - v0).cross(v1 - v0).normalized()
	for v in [v0, v1, v2]:
		st.set_color(color)
		st.set_normal(normal)
		st.add_vertex(v)


func _add_box(size: Vector3, xform: Transform3D, mat: Material, solid: bool) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = xform
	add_child(mi)
	if solid:
		var body := StaticBody3D.new()
		body.transform = xform
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
		body.add_child(shape)
		add_child(body)


func _add_multimesh(mesh: Mesh, mat: Material, spots: Array[Transform3D], offset: Vector3) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = spots.size()
	for i in spots.size():
		mm.set_instance_transform(i, spots[i].translated_local(offset))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)


func _vertex_color_material(cull: BaseMaterial3D.CullMode) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.9
	m.cull_mode = cull
	return m


func _plain_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	return m


func _grass_texture() -> Texture2D:
	var img := Image.create_empty(64, 64, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for y in 64:
		for x in 64:
			var checker := (int(x / 32.0) + int(y / 32.0)) % 2
			var base := Color(0.30, 0.58, 0.25) if checker == 0 else Color(0.34, 0.63, 0.28)
			var n := rng.randf_range(-0.03, 0.03)
			img.set_pixel(x, y, Color(base.r + n, base.g + n, base.b + n))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
