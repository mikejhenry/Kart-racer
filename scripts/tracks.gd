extends RefCounted
## Track definitions.
##
## points     Control points (x, height, z) in metres, driven in order and
##            joined into a smooth closed loop. Keep the first point at the
##            start line on flat ground (height 0).
## items      Rows of item boxes, as fractions of the lap (0..1).
## boost_pads [fraction, lateral offset in metres from the centre line].
## jumps      Fractions where a ramp ends in a drop.
## shortcuts  [from, to] fractions: the inside wall is left open between them
##            so players can cut across the infield (slow on grass unless you
##            use a nitro). Only on flat ground.
##
## After changing a track, regenerate the server's copy so leaderboard
## checks match:  godot --headless --script res://tools/export_tracks.gd

const LIST := [
	{
		"id": "circuit_1",
		"name": "Green Loop",
		"blurb": "Flat and fast, with a sneaky shortcut",
		"theme": "grass",
		"points": [
			Vector3(0, 0, 0), Vector3(80, 0, 0), Vector3(130, 0, -30), Vector3(140, 0, -90),
			Vector3(100, 0, -130), Vector3(40, 0, -110), Vector3(10, 0, -150), Vector3(-50, 0, -165),
			Vector3(-105, 0, -125), Vector3(-100, 0, -55), Vector3(-60, 0, -5),
		],
		"items": [0.2, 0.52, 0.8],
		"boost_pads": [[0.07, -3.0], [0.66, 3.0]],
		"jumps": [],
		"shortcuts": [[0.12, 0.31]],
	},
	{
		"id": "dune_valley",
		"name": "Dune Valley",
		"blurb": "Rolling dunes, a hairpin dip and a big jump",
		"theme": "desert",
		"points": [
			Vector3(0, 0, 0), Vector3(140, 0, 0), Vector3(190, 2, -40), Vector3(190, 5, -110),
			Vector3(140, 7, -150), Vector3(80, 6, -150), Vector3(20, 3, -80), Vector3(-20, 3, -110),
			Vector3(-40, 6, -160), Vector3(-110, 8, -170), Vector3(-160, 6, -120), Vector3(-150, 3, -50),
			Vector3(-90, 0, -10),
		],
		"items": [0.18, 0.55, 0.8],
		"boost_pads": [[0.08, 0.0], [0.93, -3.0]],
		"jumps": [0.47],
		"shortcuts": [],
	},
	{
		"id": "frost_peak",
		"name": "Frost Peak",
		"blurb": "A zigzag climb to the summit, a jump and boost pads",
		"theme": "snow",
		"points": [
			Vector3(0, 0, 0), Vector3(80, 0, 0), Vector3(120, 3, -50), Vector3(90, 7, -110),
			Vector3(130, 11, -170), Vector3(110, 14, -240), Vector3(40, 13, -260), Vector3(-10, 10, -220),
			Vector3(20, 7, -160), Vector3(-20, 4, -100), Vector3(-60, 2, -50), Vector3(-50, 0, -10),
		],
		"items": [0.14, 0.49, 0.67],
		"boost_pads": [[0.33, 3.0], [0.58, -3.0], [0.96, 0.0]],
		"jumps": [0.77],
		"shortcuts": [],
	},
]

const THEMES := {
	"grass": {
		"ground_a": Color(0.30, 0.58, 0.25), "ground_b": Color(0.34, 0.63, 0.28),
		"shoulder": Color(0.31, 0.59, 0.26),
		"road_a": Color(0.24, 0.24, 0.27), "road_b": Color(0.27, 0.27, 0.30),
		"curb_a": Color(0.85, 0.1, 0.1), "curb_b": Color(0.95, 0.95, 0.95),
		"wall_a": Color(0.9, 0.15, 0.15), "wall_b": Color(0.95, 0.95, 0.95),
		"scenery": "pine", "trunk": Color(0.45, 0.3, 0.18), "leaves": Color(0.15, 0.45, 0.2),
		"backdrop": Color(0.3, 0.5, 0.32), "fog": Color(0.7, 0.82, 0.95),
		"sky_top": Color(0.25, 0.5, 0.9), "sky_horizon": Color(0.7, 0.85, 1.0),
	},
	"desert": {
		"ground_a": Color(0.86, 0.74, 0.5), "ground_b": Color(0.82, 0.7, 0.46),
		"shoulder": Color(0.8, 0.68, 0.45),
		"road_a": Color(0.33, 0.3, 0.28), "road_b": Color(0.36, 0.33, 0.3),
		"curb_a": Color(0.95, 0.55, 0.1), "curb_b": Color(0.95, 0.95, 0.9),
		"wall_a": Color(0.95, 0.55, 0.1), "wall_b": Color(0.95, 0.92, 0.85),
		"scenery": "cactus", "trunk": Color(0.55, 0.42, 0.3), "leaves": Color(0.3, 0.55, 0.3),
		"backdrop": Color(0.85, 0.62, 0.4), "fog": Color(0.95, 0.86, 0.72),
		"sky_top": Color(0.3, 0.55, 0.95), "sky_horizon": Color(0.95, 0.88, 0.75),
	},
	"snow": {
		"ground_a": Color(0.92, 0.94, 0.98), "ground_b": Color(0.87, 0.9, 0.95),
		"shoulder": Color(0.9, 0.92, 0.97),
		"road_a": Color(0.3, 0.32, 0.36), "road_b": Color(0.33, 0.35, 0.4),
		"curb_a": Color(0.15, 0.35, 0.85), "curb_b": Color(0.95, 0.95, 0.98),
		"wall_a": Color(0.15, 0.35, 0.85), "wall_b": Color(0.95, 0.95, 0.98),
		"scenery": "snowpine", "trunk": Color(0.4, 0.28, 0.2), "leaves": Color(0.12, 0.32, 0.22),
		"backdrop": Color(0.88, 0.9, 0.96), "fog": Color(0.85, 0.9, 1.0),
		"sky_top": Color(0.35, 0.55, 0.85), "sky_horizon": Color(0.85, 0.9, 1.0),
	},
}


static func get_track(id: String) -> Dictionary:
	for t in LIST:
		if t.id == id:
			return t
	return LIST[0]


static func index_of(id: String) -> int:
	for i in LIST.size():
		if LIST[i].id == id:
			return i
	return 0


## Changes whenever a track's layout or features change, so old ghosts are
## not replayed on a different layout.
static func layout_hash(id: String) -> int:
	var t := get_track(id)
	return hash(str(t.points) + str(t.get("jumps", [])) + str(t.get("shortcuts", [])))


static func ids() -> Array:
	var out := []
	for t in LIST:
		out.append(t.id)
	return out


static func name_of(id: String) -> String:
	return str(get_track(id).name)
