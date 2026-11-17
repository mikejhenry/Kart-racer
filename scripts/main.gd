extends Node3D
## Sets up a race: environment, track, karts, camera, HUD and (on touch
## devices) on-screen controls. Runs the countdown, laps, positions and finish.

const Track := preload("res://scripts/track.gd")
const Kart := preload("res://scripts/kart.gd")
const PlayerBrain := preload("res://scripts/player_brain.gd")
const AiBrain := preload("res://scripts/ai_brain.gd")
const ChaseCamera := preload("res://scripts/chase_camera.gd")
const Hud := preload("res://scripts/hud.gd")
const TouchControls := preload("res://scripts/touch_controls.gd")

const TOTAL_LAPS := 3
const KART_COLORS := [
	Color(0.95, 0.75, 0.1), Color(0.2, 0.75, 0.3), Color(0.6, 0.3, 0.9),
	Color(1.0, 0.5, 0.1), Color(0.2, 0.8, 0.85), Color(0.9, 0.15, 0.2),
]
## Base speed of each AI kart (the last colour is the player).
const AI_SKILL := [0.97, 0.95, 0.93, 0.91, 0.89]

var track
var karts: Array = []
var player
var camera
var hud
var state := "countdown"
var countdown := 3.5
var race_time := 0.0
var finished_count := 0
var _last_count_shown := -1
var _best_lap := 1


func _ready() -> void:
	_setup_environment()
	track = Track.new()
	add_child(track)
	track.build()
	_spawn_karts()

	camera = ChaseCamera.new()
	add_child(camera)
	camera.target = player
	camera.make_current()
	camera.snap()

	hud = Hud.new()
	add_child(hud)
	player.item_changed.connect(hud.set_item)
	if GameInput.touch_ui:
		add_child(TouchControls.new())


func _spawn_karts() -> void:
	var count := KART_COLORS.size()
	for i in count:
		var k = Kart.new()
		k.body_color = KART_COLORS[i]
		k.track = track
		k.add_to_group("karts")
		add_child(k)
		var row := int(i / 2.0)
		var lateral := -3.5 if i % 2 == 0 else 3.5
		k.place_at(track.length - 8.0 - row * 7.0, lateral)
		# Start just behind the line: crossing it begins lap 1.
		k.progress = k.prev_offset - track.length
		if i == count - 1:
			player = k
			k.brain = PlayerBrain.new()
		else:
			k.skill = AI_SKILL[i]
			k.speed_factor = k.skill
			k.brain = AiBrain.new(track, lateral)
		karts.append(k)


func _physics_process(delta: float) -> void:
	match state:
		"countdown":
			countdown -= delta
			var n := int(ceil(countdown))
			if n != _last_count_shown and n >= 1 and n <= 3:
				_last_count_shown = n
				hud.flash(str(n), 1.0)
			if countdown <= 0.0:
				state = "racing"
				hud.flash("GO!", 1.0)
				for k in karts:
					k.can_drive = true
		"racing":
			race_time += delta
			_check_finishes()
			_rubber_band()
		"finished":
			_check_finishes()
	_update_places()
	_update_hud()


func _check_finishes() -> void:
	var goal: float = TOTAL_LAPS * track.length
	for k in karts:
		if k.finish_order < 0 and k.progress >= goal:
			finished_count += 1
			k.finish_order = finished_count
			if k == player:
				_on_player_finished()


func _on_player_finished() -> void:
	state = "finished"
	# Let the AI drive the player's kart for a victory lap.
	player.brain = AiBrain.new(track, 0.0)
	hud.flash("FINISH!", 2.0)
	var final_place: int = player.finish_order
	var time := race_time
	get_tree().create_timer(2.0).timeout.connect(func(): hud.show_results(final_place, karts.size(), time))


## AI karts slow down a little when far ahead and speed up when far behind,
## which keeps races close.
func _rubber_band() -> void:
	for k in karts:
		if k == player or k.finish_order > 0:
			continue
		var gap: float = k.progress - player.progress
		k.speed_factor = k.skill * clampf(1.0 - gap / 600.0, 0.9, 1.07)


func _update_places() -> void:
	var order := karts.duplicate()
	order.sort_custom(_ahead_of)
	for i in order.size():
		order[i].place = i + 1


func _ahead_of(a, b) -> bool:
	var a_done: bool = a.finish_order > 0
	var b_done: bool = b.finish_order > 0
	if a_done and b_done:
		return a.finish_order < b.finish_order
	if a_done != b_done:
		return a_done
	return a.progress > b.progress


func _update_hud() -> void:
	var lap := clampi(int(floor(player.progress / track.length)) + 1, 1, TOTAL_LAPS)
	hud.set_status(lap, TOTAL_LAPS, player.place)
	if state == "racing" and lap > _best_lap:
		_best_lap = lap
		hud.flash("FINAL LAP!" if lap == TOTAL_LAPS else "LAP %d" % lap, 1.5)

	var tf: Transform3D = track.frame_at(player.current_offset)
	var heading: Vector3 = -player.global_transform.basis.z
	var wrong: bool = state == "racing" and heading.dot(-tf.basis.z) < -0.3 and absf(player.speed) > 3.0
	hud.set_wrong_way(wrong)


func _setup_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.25, 0.5, 0.9)
	sky_mat.sky_horizon_color = Color(0.7, 0.85, 1.0)
	sky_mat.ground_horizon_color = Color(0.7, 0.85, 1.0)
	sky_mat.ground_bottom_color = Color(0.3, 0.45, 0.3)
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.82, 0.95)
	env.fog_density = 0.0025
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.1
	# Shadows cost a lot on phones; keep them for desktop.
	sun.shadow_enabled = not GameInput.low_quality
	sun.directional_shadow_max_distance = 60.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	add_child(sun)
