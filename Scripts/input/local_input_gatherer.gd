class_name LocalInputGatherer
extends Node

var _camera: Camera3D
var _local_team_id: int = -1
var _pending_shoot_pressed: bool = false
var _pending_slap_pressed: bool = false
var _pending_stick_lift_pressed: bool = false
var _pending_quick_shot_pressed: bool = false
# Loft mode (0 flat / 1 low saucer / 2 high), stepped by scroll-wheel events in
# _process and stamped ABSOLUTE into every gathered frame. Living here — not as
# sticky controller state — makes it plain input: reconcile replay and the
# host's input-derived releases both read the level off the frame itself.
var _elevation_level: int = 0
# Last mouse world position. Returned in place of a fresh sample when input
# is blocked so the stick IK doesn't swing to the rink origin every frame
# the menu is open. Both client and host see the same value (it goes out in
# the input batch), so this does not desync.
var _last_mouse_world_pos: Vector3 = Vector3.ZERO
var _last_mouse_screen_pos: Vector2 = Vector2.ZERO

func _init(camera: Camera3D) -> void:
	_camera = camera

func set_local_team_id(team_id: int) -> void:
	_local_team_id = team_id

func _process(_delta: float) -> void:
	# Accumulate just_pressed events every frame — unless input is blocked,
	# in which case presses made over menu UI shouldn't queue up and fire
	# the moment the menu closes.
	if GameManager.is_input_blocked():
		return
	if Input.is_action_just_pressed("shoot"):
		_pending_shoot_pressed = true
	if Input.is_action_just_pressed("slapshot"):
		_pending_slap_pressed = true
	# Each scroll click steps the loft mode one notch, applied immediately so
	# multiple clicks between physics ticks all land (no pending-flag coalescing).
	if Input.is_action_just_pressed("elevation_up"):
		_elevation_level = mini(_elevation_level + 1, InputState.MAX_ELEVATION_LEVEL)
	if Input.is_action_just_pressed("elevation_down"):
		_elevation_level = maxi(_elevation_level - 1, 0)
	if Input.is_action_just_pressed("stick_lift"):
		_pending_stick_lift_pressed = true
	if Input.is_action_just_pressed("quick_shot"):
		_pending_quick_shot_pressed = true

func gather() -> InputState:
	# Input blocked → return a neutral state so the skater decelerates
	# naturally and any held action releases as if the player let go. Doing
	# this at the gatherer (rather than in LocalController) keeps host and
	# client in sync: both run the same neutral input through the same
	# physics, so there's no reconcile snap when the menu closes.
	if GameManager.is_input_blocked():
		var blocked := InputState.new()
		blocked.host_timestamp = NetworkManager.estimated_host_time()
		blocked.mouse_world_pos = _last_mouse_world_pos
		blocked.mouse_screen_pos = _last_mouse_screen_pos
		# Loft is a mode, not a held action — carry it through the block so
		# opening a menu doesn't flatten the player's chosen elevation.
		blocked.elevation_level = _elevation_level
		return blocked
	var state := InputState.new()
	state.move_vector = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	state.mouse_screen_pos = get_viewport().get_mouse_position()
	if PlayerPrefs.attack_up and _local_team_id == 1:
		state.move_vector = -state.move_vector
		# Negate screen-pos too. The wrister charge tracker reads its
		# direction from screen-pos delta via the Vector3(x, 0, y) packing,
		# which assumes screen Y → world Z directly. With the attack_up
		# camera rotated 180°, that mapping is backwards — drag-up-on-screen
		# points to -Z but the player's actual world attack is +Z, and the
		# blade tracks mouse_world (which projects through the flipped
		# camera correctly). Without this flip, intent_dir and blade_delta
		# end up in opposite frames; the charge tracker's
		# blade_delta·intent_dir projection clamps to zero and charge never
		# accumulates, so every shot fires as a quick shot. Negating screen-
		# pos puts both signals in the same frame for the tracker.
		state.mouse_screen_pos = -state.mouse_screen_pos
	state.shoot_held = Input.is_action_pressed("shoot")
	state.shoot_pressed = _pending_shoot_pressed
	state.slap_held = Input.is_action_pressed("slapshot")
	state.slap_pressed = _pending_slap_pressed
	state.brake = Input.is_action_pressed("brake")
	state.sprint_held = Input.is_action_pressed("sprint")
	state.elevation_level = _elevation_level
	state.block_held = Input.is_action_pressed("block")
	state.stick_lift_held = Input.is_action_pressed("stick_lift")
	state.stick_lift_pressed = _pending_stick_lift_pressed
	state.quick_shot_pressed = _pending_quick_shot_pressed
	state.mouse_world_pos = _get_mouse_world_pos(_camera)
	state.host_timestamp = NetworkManager.estimated_host_time()
	_last_mouse_world_pos = state.mouse_world_pos
	_last_mouse_screen_pos = state.mouse_screen_pos
	# Clear pending flags after gather
	_pending_shoot_pressed = false
	_pending_slap_pressed = false
	_pending_stick_lift_pressed = false
	_pending_quick_shot_pressed = false
	return state

func _get_mouse_world_pos(camera: Camera3D) -> Vector3:
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var ray_origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var t: float = -ray_origin.y / ray_dir.y
	return ray_origin + ray_dir * t
