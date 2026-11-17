extends RefCounted
## Shared sky, sunlight and fog, used by the menu and the race. Pass a track
## theme (see tracks.gd) to tint the sky and fog to match.


static func add_environment(parent: Node, theme: Dictionary = {}) -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = theme.get("sky_top", Color(0.25, 0.5, 0.9))
	sky_mat.sky_horizon_color = theme.get("sky_horizon", Color(0.7, 0.85, 1.0))
	sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
	sky_mat.ground_bottom_color = Color(0.3, 0.45, 0.3)
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# A modest ambient light keeps colours rich; a bright sky washes them out.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.68, 0.8)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_light_color = theme.get("fog", Color(0.7, 0.82, 0.95))
	env.fog_density = 0.0022
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	parent.add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.25
	# Shadows cost a lot on phones; keep them for desktop.
	sun.shadow_enabled = not GameInput.low_quality
	sun.directional_shadow_max_distance = 60.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	parent.add_child(sun)
