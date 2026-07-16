class_name LobbyArenaBackdrop
extends Node3D

# Live 3D arena behind the lobby panel: the real RinkArena scene (rink,
# stands, crowd, lights) with a slowly drifting camera, replacing the old
# static ice-texture background. The crowd's fan mix re-tints as the lobby's
# team colors resolve (set_team_color_slots), so color votes repaint the
# bowl live. PlayerPrefs.apply_video() is re-applied once the arena lands so
# the user's GI / crowd-density / shadow options carry into the lobby.

const _ARENA_SCENE_PATH: String = "res://Scenes/RinkArena.tscn"

# Camera path: a slow elliptical drift inside the bowl, matched to the rink's
# 60×26 footprint so the framing keeps a similar distance to the near boards
# all the way around. One lap ≈ 3.5 minutes — present, never distracting.
const _ORBIT_RADIUS_X: float = 16.0
const _ORBIT_RADIUS_Z: float = 22.0
const _ORBIT_HEIGHT: float = 8.5
const _ORBIT_SPEED: float = 0.03  # rad/s
const _LOOK_TARGET: Vector3 = Vector3(0.0, 1.2, 0.0)
const _CAMERA_FOV: float = 65.0

var _camera: Camera3D = null
var _stands: ArenaStands = null
var _orbit_angle: float = 0.0
var _home_slot: int = -1
var _away_slot: int = -1


func _ready() -> void:
	var arena_scene: PackedScene = load(_ARENA_SCENE_PATH)
	var arena: Node3D = arena_scene.instantiate() as Node3D
	add_child(arena)
	_stands = arena.find_child("ArenaStands", false, false) as ArenaStands
	_camera = Camera3D.new()
	_camera.fov = _CAMERA_FOV
	add_child(_camera)
	_update_camera(0.0)
	_camera.current = true
	# Deferred: apply_video reads the main loop's current_scene, which isn't
	# assigned yet while the lobby scene's children are still in _ready().
	PlayerPrefs.call_deferred(&"apply_video")


func _process(delta: float) -> void:
	_update_camera(delta)


func _update_camera(delta: float) -> void:
	_orbit_angle = fmod(_orbit_angle + _ORBIT_SPEED * delta, TAU)
	_camera.position = Vector3(
			cos(_orbit_angle) * _ORBIT_RADIUS_X,
			_ORBIT_HEIGHT,
			sin(_orbit_angle) * _ORBIT_RADIUS_Z)
	_camera.look_at(_LOOK_TARGET)


# Re-tint the crowd/benches to the lobby's currently-resolved color slots.
# ArenaStands.setup() is a full bowl rebuild, so skip when nothing changed —
# the lobby calls this from _refresh_grid, which also fires on ready toggles
# and roster churn that leave the colors alone.
func set_team_color_slots(home_slot: int, away_slot: int) -> void:
	if home_slot == _home_slot and away_slot == _away_slot:
		return
	_home_slot = home_slot
	_away_slot = away_slot
	if _stands == null:
		return
	var home: Dictionary = TeamColorRegistry.get_colors(home_slot, 0)
	var away: Dictionary = TeamColorRegistry.get_colors(away_slot, 1)
	_stands.setup(home.primary, home.secondary, away.primary, away.secondary)
