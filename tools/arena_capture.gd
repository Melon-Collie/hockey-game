extends SceneTree

# Dev visualizer: renders the built arena offscreen from a set of fixed angles,
# so rink geometry, board and in-ice sponsors, crowd, and scoreboard can be SEEN
# without launching the game.
#
# It loads the real RinkArena.tscn rather than assembling a stand-in, which is
# the point: everything on screen is what a session builds — the same procedural
# boards, the same painted ice, the same ad layout derived from the same
# constants. Nothing here can look right while the game looks wrong.
#
# The shots cover what no single view can: SHOT_WIDE and SHOT_BROADCAST for the
# bowl, SHOT_BOARDS and SHOT_CORNER for the dasher panels at a reading angle
# (and through the corner curve, where the ribbon has to follow the arc), and
# SHOT_TOPDOWN for what the gameplay camera actually sees — which is the view
# that decides whether board ads were worth it, since it grazes them.
#
# One caveat, from the renderer rather than the scene: the compatibility renderer
# drops SDFGI, SSR, and volumetric fog, so these frames are flatter and less
# atmospheric than the game — read them for layout and legibility, not for mood.
#
# Needs a real (software) renderer, not --headless. On the web container:
#
#   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . \
#       --rendering-driver opengl3 --audio-driver Dummy \
#       -s res://tools/arena_capture.gd
#
# Locally any GPU works: drop the env var and xvfb-run. Output paths print on
# save (user:// — never the repo tree, so captures can't be committed).
#
# Pass a shot name to render just one, e.g. `-- boards`. Default is all of them.

const VIEWPORT_SIZE := Vector2i(1280, 720)

# The jumbotron hangs over centre ice on render layer 2, and GameCamera clears
# that bit so it never blocks the play. A shot reproducing the gameplay view has
# to clear it too, or the capture is a photo of the scoreboard's underside.
const JUMBOTRON_LAYER_BIT: int = 2

# The arena is built a frame in, not in _init: autoload identifiers inside its
# scripts (HockeyRink reaches GameManager, ArenaStands reaches NetworkManager
# through its dependants) do not compile-resolve until the tree is up, and a
# scene loaded before then fails to compile rather than failing to look right.
const BUILD_FRAME: int = 2
# Frames to let the scene settle before the first capture. The board-ad atlas,
# the in-ice ad overlay, and the centre-ice decals are all UPDATE_ONCE
# SubViewports — their textures are blank until they have rendered once, so
# capturing early photographs a rink whose ads have not been drawn yet.
const SETTLE_FRAMES: int = 14
# Frames between shots, so a camera move is on screen before the grab.
const FRAMES_PER_SHOT: int = 3

# `pos`/`look_at` in rink metres: +X is the bench side, +Z is team 0's end.
const SHOTS: Array[Dictionary] = [
	{
		"name": "wide",
		"pos": Vector3(34.0, 24.0, 46.0), "look_at": Vector3(0.0, 1.0, 0.0),
		"fov": 50.0, "note": "the bowl from a corner — rink, stands, scoreboard",
	},
	{
		"name": "broadcast",
		# In the concourse gap between the decks, which is where a real side
		# camera goes and the only place on this side that isn't inside seating:
		# the lower bowl tops out around y 7 at x 22, the upper deck starts
		# climbing again from x 24. Sitting anywhere else on +X photographs
		# somebody's back.
		"pos": Vector3(23.5, 9.5, 7.0), "look_at": Vector3(-1.0, 0.5, 1.0),
		"fov": 52.0, "note": "the side camera a broadcast would use",
	},
	{
		"name": "boards",
		"pos": Vector3(-8.0, 1.5, -15.0), "look_at": Vector3(-12.6, 0.6, 6.0),
		"fov": 55.0, "note": "down the west boards — dasher panels at a reading angle",
	},
	{
		"name": "corner",
		"pos": Vector3(3.0, 3.0, 15.0), "look_at": Vector3(11.0, 0.6, 26.0),
		"fov": 55.0, "note": "into the north-east corner, where the ribbon follows the arc",
	},
	{
		"name": "stands",
		# Stood on the ice looking at the west bowl. Anywhere past the boards is
		# inside the first rows, which photographs one spectator's coat.
		"pos": Vector3(-7.0, 2.6, 1.0), "look_at": Vector3(-19.0, 4.2, 0.0),
		"fov": 55.0, "note": "up into the bowl — seats, occupied and empty",
	},
	{
		"name": "ice_ads",
		"pos": Vector3(2.0, 9.0, -20.0), "look_at": Vector3(4.0, 0.0, 2.0),
		"fov": 50.0, "note": "over the neutral zone — the in-ice panels",
	},
	{
		"name": "topdown",
		"pos": Vector3(0.0, 32.0, 0.0), "look_at": Vector3(0.0, 0.0, 0.01),
		"fov": 60.0, "hide_jumbotron": true,
		"note": "what the gameplay camera sees — in-ice ads square on, boards grazed",
	},
]

var _frames: int = 0
var _shot_index: int = 0
var _camera: Camera3D = null
var _shots: Array[Dictionary] = []


func _init() -> void:
	DisplayServer.window_set_size(VIEWPORT_SIZE)
	_shots = _selected_shots()
	if _shots.is_empty():
		push_error("arena_capture: no shot matched; known shots are %s" % [_shot_names()])
		quit(1)
		return

	# The arena scene brings its own WorldEnvironment and light rig — that is
	# the arena's look, so the capture adds a camera and nothing else.
	_camera = Camera3D.new()
	root.add_child(_camera)

	process_frame.connect(_on_frame)


func _on_frame() -> void:
	_frames += 1
	if _frames == BUILD_FRAME:
		var arena: PackedScene = load("res://Scenes/RinkArena.tscn")
		root.add_child(arena.instantiate())
		# Aimed here rather than in _init: look_at needs the camera in the tree,
		# which it is not yet while the SceneTree is still initializing.
		_aim(_shots[0])
		return
	if _frames < SETTLE_FRAMES:
		return
	if (_frames - SETTLE_FRAMES) % FRAMES_PER_SHOT != 0:
		return

	var shot: Dictionary = _shots[_shot_index]
	_save("arena_%s.png" % shot.name, shot.note as String)
	_shot_index += 1
	if _shot_index >= _shots.size():
		quit()
		return
	_aim(_shots[_shot_index])


func _aim(shot: Dictionary) -> void:
	_camera.fov = shot.fov
	_camera.position = shot.pos
	_camera.look_at(shot.look_at as Vector3)
	var mask: int = _camera.cull_mask | JUMBOTRON_LAYER_BIT
	if shot.get("hide_jumbotron", false):
		mask &= ~JUMBOTRON_LAYER_BIT
	_camera.cull_mask = mask


# With no argument, every shot; otherwise the ones named after `--`.
func _selected_shots() -> Array[Dictionary]:
	var wanted: PackedStringArray = OS.get_cmdline_user_args()
	if wanted.is_empty():
		return SHOTS
	var picked: Array[Dictionary] = []
	for shot: Dictionary in SHOTS:
		if wanted.has(shot.name):
			picked.append(shot)
	return picked


func _shot_names() -> PackedStringArray:
	var names := PackedStringArray()
	for shot: Dictionary in SHOTS:
		names.append(shot.name)
	return names


func _save(fname: String, note: String) -> void:
	var img: Image = root.get_texture().get_image()
	var path: String = "user://" + fname
	img.save_png(path)
	print("saved %s  — %s" % [ProjectSettings.globalize_path(path), note])
