extends Node3D
## Builds a race track from a definition in tracks.gd: road with curbs and
## shoulders (with hills and jump ramps), barrier walls with gaps for
## shortcuts, ground, start gate, item boxes, boost pads, scenery, and a
## racing line for the AI.
##
## Everything along the track is addressed by "offset": metres along the
## centre line, measured flat (ignoring height), from 0 at the start line.

const ItemBox := preload("res://scripts/item_box.gd")
const BoostPad := preload("res://scripts/boost_pad.gd")
const Tracks := preload("res://scripts/tracks.gd")

const SAMPLE_STEP := 2.0
const JUMP_LENGTH := 14.0
const JUMP_HEIGHT := 3.0
const LINE_STEP := 2.0          ## Racing line resolution, metres
const LINE_LIMIT := 6.0         ## How far the racing line strays from centre

var track_id := "circuit_1"
var def: Dictionary
var theme: Dictionary
var road_half_width := 9.0
var curb_width := 1.5
var wall_gap := 5.0
var wall_height := 1.2
var items_enabled := true

var curve: Curve3D              ## Flat (y = 0) centre line
var length := 0.0
var offroad_distance := 0.0
var wall_distance := 0.0

var _height_keys: Array = []    ## [[offset, height], ...] sorted by offset
var _jumps: Array = []          ## Offsets where a ramp drops away
var _gaps: Array = []           ## [from_offset, to_offset, side]
var _samples: Array = []        ## Offsets used to build the meshes
var _line := PackedFloat32Array()


func build() -> void:
	def = Tracks.get_track(track_id)
	theme = Tracks.THEMES[def.theme]
	var pts: Array = def.points
	curve = Curve3D.new()
	curve.bake_interval = 0.5
	var n := pts.size()
	for i in n + 1:
		var handle := (_flat_point(pts, i + 1) - _flat_point(pts, i - 1)) * 0.25
		curve.add_point(_flat_point(pts, i), -handle, handle)
	length = curve.get_baked_length()
	offroad_distance = road_half_width + curb_width * 0.6
	wall_distance = road_half_width + curb_width + wall_gap

	_height_keys.clear()
	for i in n:
		var p: Vector3 = pts[i]
		var o := 0.0 if i == 0 else curve.get_closest_offset(Vector3(p.x, 0.0, p.z))
		_height_keys.append([o, p.y])
	_height_keys.sort_custom(func(a, b): return a[0] < b[0])
	_jumps.clear()
	for f in def.get("jumps", []):
		_jumps.append(float(f) * length)
	_gaps.clear()
	for g in def.get("shortcuts", []):
		_gaps.append(_make_gap(float(g[0]) * length, float(g[1]) * length))

	_build_samples()
	_build_racing_line()
	_build_road()
	_build_walls()
	_build_ground()
	_build_start_gate()
	_build_item_boxes()
	_build_boost_pads()
	_build_scenery()


# --- Queries used by karts, AI, items and the HUD ---------------------------

## Distance along the track (0..length) of the closest point to world_pos.
func get_offset(world_pos: Vector3) -> float:
	return curve.get_closest_offset(Vector3(world_pos.x, 0.0, world_pos.z))


## Road surface height at an offset.
func height_at(offset: float) -> float:
	var o := fposmod(offset, length)
	var h := maxf(_profile(o), 0.0)
	for j in _jumps:
		var d: float = j - o
		if d > 0.0 and d <= JUMP_LENGTH:
			h += JUMP_HEIGHT * (1.0 - d / JUMP_LENGTH)
	return h


func point_at(offset: float) -> Vector3:
	return frame_at(offset).origin


## Transform at an offset: origin on the centre line at road height, -Z
## pointing in the racing direction, +X pointing to the right (kept level).
func frame_at(offset: float) -> Transform3D:
	var o := fposmod(offset, length)
	var p := curve.sample_baked(o, true)
	var forward := curve.sample_baked(fposmod(o + 1.0, length), true) - curve.sample_baked(fposmod(o - 1.0, length), true)
	forward.y = 0.0
	p.y = height_at(o)
	return Transform3D(Basis.looking_at(forward.normalized(), Vector3.UP), p)


## Where the AI likes to be across the road at an offset (metres, + = right).
func racing_line_at(offset: float) -> float:
	var f := fposmod(offset, length) / LINE_STEP
	var i := int(f)
	var n := _line.size()
	return lerpf(_line[i % n], _line[(i + 1) % n], f - i)


## True within ~30 m of a shortcut, where being off the road is allowed.
func near_shortcut(offset: float) -> bool:
	for g in _gaps:
		if offset > g[0] - 30.0 and offset < g[1] + 30.0:
			return true
	return false


## Flat outline of the track for the minimap.
func outline(count: int = 96) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in count:
		var p := curve.sample_baked(length * i / count, true)
		pts.append(Vector2(p.x, p.z))
	return pts


## Points along the track the server uses to check uploaded time trial runs.
func checkpoints(count: int = 16) -> Array:
	var out := []
	for i in count:
		var o := length * (i + 0.5) / count
		if near_shortcut(o):
			continue
		var p := curve.sample_baked(o, true)
		out.append([snappedf(p.x, 0.1), snappedf(p.z, 0.1)])
	return out


# --- Construction -----------------------------------------------------------

func _flat_point(pts: Array, i: int) -> Vector3:
	var p: Vector3 = pts[posmod(i, pts.size())]
	return Vector3(p.x, 0.0, p.z)


## Smooth periodic height profile through the control point heights.
func _profile(o: float) -> float:
	var k := _height_keys
	var n := k.size()
	var i := n - 1
	for idx in n:
		if k[idx][0] <= o:
			i = idx
	var o0: float = k[i][0]
	var o1: float = k[(i + 1) % n][0]
	if o1 <= o0:
		o1 += length
	var oo := o if o >= o0 else o + length
	var t := clampf((oo - o0) / maxf(o1 - o0, 0.001), 0.0, 1.0)
	var p0: float = k[(i - 1 + n) % n][1]
	var p1: float = k[i][1]
	var p2: float = k[(i + 1) % n][1]
	var p3: float = k[(i + 2) % n][1]
	return 0.5 * (2.0 * p1 + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t * t)


func _make_gap(from: float, to: float) -> Array:
	# The inside of the bend is where the chord between the ends lies.
	var mid := frame_at((from + to) * 0.5)
	var chord_mid := (frame_at(from).origin + frame_at(to).origin) * 0.5
	var side := signf(mid.basis.x.dot(chord_mid - mid.origin))
	return [from, to, side]


func _in_gap(o: float, side: float) -> bool:
	for g in _gaps:
		if g[2] == side and o >= g[0] and o <= g[1]:
			return true
	return false


func _build_samples() -> void:
	var list := []
	var count := int(length / SAMPLE_STEP)
	var step := length / count
	for i in count + 1:
		list.append(i * step)
	for j in _jumps:
		list.append(j - 0.05)
		list.append(j)
	list.sort()
	_samples = list


func _build_racing_line() -> void:
	var count := int(length / LINE_STEP)
	var curvature := PackedFloat32Array()
	curvature.resize(count)
	for i in count:
		var o := i * LINE_STEP
		var a := frame_at(o - 2.0).basis.z
		var b := frame_at(o + 2.0).basis.z
		var turn := wrapf(atan2(-b.x, b.z) - atan2(-a.x, a.z), -PI, PI)
		curvature[i] = turn / 4.0       # radians per metre, + = turning right
	var raw := PackedFloat32Array()
	raw.resize(count)
	var lead := int(25.0 / LINE_STEP)
	for i in count:
		# Outside before a bend, inside at the apex
		raw[i] = clampf(170.0 * (curvature[i] - 0.5 * curvature[(i + lead) % count]), -LINE_LIMIT, LINE_LIMIT)
	_line.resize(count)
	for i in count:
		var sum := 0.0
		for d in range(-3, 4):
			sum += raw[(i + d + count) % count]
		_line[i] = sum / 7.0


func _build_road() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var deck := PackedVector3Array()
	var line := Color(0.92, 0.92, 0.92)
	var edge := road_half_width + curb_width
	for i in _samples.size() - 1:
		var a := frame_at(_samples[i])
		var b := frame_at(_samples[i + 1])
		if a.origin.distance_to(b.origin) < 0.001:
			continue
		# Subtle banding on the asphalt helps you feel your speed.
		var road: Color = theme.road_a if int(i / 4.0) % 2 == 0 else theme.road_b
		_strip(st, a, b, -road_half_width, road_half_width, 0.02, road)
		var curb: Color = theme.curb_a if i % 2 == 0 else theme.curb_b
		_strip(st, a, b, road_half_width, edge, 0.02, curb)
		_strip(st, a, b, -edge, -road_half_width, 0.02, curb)
		_strip(st, a, b, edge, wall_distance, 0.01, theme.shoulder)
		_strip(st, a, b, -wall_distance, -edge, 0.01, theme.shoulder)
		if i % 3 == 0:
			_strip(st, a, b, -0.15, 0.15, 0.04, line)
		# Drivable surface, edge to edge
		var a0 := a.origin - a.basis.x * wall_distance
		var a1 := a.origin + a.basis.x * wall_distance
		var b0 := b.origin - b.basis.x * wall_distance
		var b1 := b.origin + b.basis.x * wall_distance
		deck.append_array([a0, b0, a1, a1, b0, b1])
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _vertex_color_material(BaseMaterial3D.CULL_DISABLED)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(deck)
	shape.backface_collision = true
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


func _build_walls() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in _samples.size() - 1:
		var oa: float = _samples[i]
		var ob: float = _samples[i + 1]
		var a := frame_at(oa)
		var b := frame_at(ob)
		if a.origin.distance_to(b.origin) < 0.001:
			continue
		var color: Color = theme.wall_a if int(i / 2.0) % 2 == 0 else theme.wall_b
		for side in [-1.0, 1.0]:
			if _in_gap(oa, side) and _in_gap(ob, side):
				continue
			# From the ground up to just above the road, so raised sections
			# look like solid embankments.
			var a_top: Vector3 = a.origin + a.basis.x * wall_distance * side + Vector3.UP * wall_height
			var b_top: Vector3 = b.origin + b.basis.x * wall_distance * side + Vector3.UP * wall_height
			var a_low := Vector3(a_top.x, 0.0, a_top.z)
			var b_low := Vector3(b_top.x, 0.0, b_top.z)
			_tri(st, a_low, b_low, a_top, color)
			_tri(st, a_top, b_low, b_top, color)
			_tri(st, a_low, a_top, b_low, color)
			_tri(st, a_top, b_top, b_low, color)
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
	plane.size = Vector2(1400, 1400)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _ground_texture()
	mat.uv1_scale = Vector3(87, 87, 1)
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
	label.text = str(def.name).to_upper()
	label.font_size = 110
	label.pixel_size = 0.01
	label.outline_size = 18
	label.transform = Transform3D(tf.basis, banner_pos + tf.basis.z * 0.25)
	add_child(label)


func _build_item_boxes() -> void:
	if not items_enabled:
		return
	for fraction in def.get("items", []):
		var tf := frame_at(length * float(fraction))
		for lateral in [-6.0, -2.0, 2.0, 6.0]:
			var box := ItemBox.new()
			box.position = tf.origin + tf.basis.x * float(lateral) + Vector3.UP * 1.0
			add_child(box)


func _build_boost_pads() -> void:
	for pad_def in def.get("boost_pads", []):
		var tf := frame_at(length * float(pad_def[0]))
		var pad := BoostPad.new()
		pad.transform = Transform3D(tf.basis, tf.origin + tf.basis.x * float(pad_def[1]) + Vector3.UP * 0.03)
		add_child(pad)


func _build_scenery() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(track_id)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in def.points:
		var v: Vector3 = p
		lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.z))
		hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.z))
	var center := (lo + hi) * 0.5

	var clearance := wall_distance + 4.0
	var spots: Array[Transform3D] = []
	var tries := 0
	while spots.size() < 160 and tries < 4000:
		tries += 1
		var pos := Vector3(rng.randf_range(lo.x - 90.0, hi.x + 90.0), 0.0, rng.randf_range(lo.y - 90.0, hi.y + 90.0))
		if curve.get_closest_point(pos).distance_to(pos) < clearance:
			continue
		var s := rng.randf_range(0.8, 1.6)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		spots.append(Transform3D(b, pos))

	match str(theme.scenery):
		"cactus":
			var column := _cylinder(0.45, 0.5, 4.5, 8)
			var arms := BoxMesh.new()
			arms.size = Vector3(2.6, 0.55, 0.55)
			_add_multimesh(column, _plain_material(theme.leaves), spots, Vector3(0, 2.25, 0))
			_add_multimesh(arms, _plain_material(theme.leaves), spots, Vector3(0, 2.6, 0))
		"snowpine":
			_add_multimesh(_cylinder(0.25, 0.35, 2.0, 6), _plain_material(theme.trunk), spots, Vector3(0, 1.0, 0))
			_add_multimesh(_cylinder(0.0, 2.2, 5.0, 8), _plain_material(theme.leaves), spots, Vector3(0, 4.5, 0))
			_add_multimesh(_cylinder(0.0, 1.1, 2.0, 8), _plain_material(Color(0.95, 0.97, 1.0)), spots, Vector3(0, 6.2, 0))
		_:
			_add_multimesh(_cylinder(0.25, 0.35, 2.0, 6), _plain_material(theme.trunk), spots, Vector3(0, 1.0, 0))
			_add_multimesh(_cylinder(0.0, 2.2, 5.0, 8), _plain_material(theme.leaves), spots, Vector3(0, 4.5, 0))

	# Distant hills / dunes / mountains on the horizon
	var far: Array[Transform3D] = []
	for i in 16:
		var angle := TAU * i / 16.0 + rng.randf_range(-0.15, 0.15)
		var dist := rng.randf_range(420.0, 540.0)
		var s := rng.randf_range(0.7, 1.3)
		var pos := Vector3(center.x + cos(angle) * dist, 0.0, center.y + sin(angle) * dist)
		far.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.6, 1.2), s)), pos))
	var peak := _cylinder(0.0, 110.0, 90.0, 10)
	_add_multimesh(peak, _plain_material(theme.backdrop), far, Vector3(0, 40.0, 0))


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


func _cylinder(top: float, bottom: float, height: float, segments: int) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = height
	m.radial_segments = segments
	m.rings = 1
	return m


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
	m.vertex_color_is_srgb = true
	m.roughness = 0.9
	m.cull_mode = cull
	return m


func _plain_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	return m


func _ground_texture() -> Texture2D:
	var img := Image.create_empty(64, 64, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var a: Color = theme.ground_a
	var b: Color = theme.ground_b
	for y in 64:
		for x in 64:
			var base := a if (int(x / 32.0) + int(y / 32.0)) % 2 == 0 else b
			var n := rng.randf_range(-0.03, 0.03)
			img.set_pixel(x, y, Color(base.r + n, base.g + n, base.b + n))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
