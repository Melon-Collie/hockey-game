class_name LocalInputGatherer
extends Node

# Gathers the local player's per-tick InputState from mouse + keyboard, OR — when
# PlayerPrefs.gamepad_enabled is on and a pad is connected — from a gamepad.
#
# The gamepad path is deliberately thin: the right stick drives a SYNTHESIZED
# screen cursor (GamepadAimRules, an absolute "skill stick" anchored on the
# skater's on-screen position) that is stored into the SAME
# InputState.mouse_screen_pos / mouse_world_pos the mouse feeds. Everything below
# the gatherer — blade IK, the wrister charge tracker, its travel gate, smart-ping
# targeting — reads those two fields, so it runs byte-identically for pad and
# mouse with no controller branch in the sim. The pad's buttons/triggers are read
# directly here (contained behind the pref) and mapped onto the existing input
# flags. See CLAUDE.md → "How It Plays" for the mapping rationale.

# How far a full right-stick deflection reaches from the skater on screen. The
# blade IK ROM-clamps the projected cursor, so this only sets how much of the
# stick's throw maps into reachable space; sized so a genuine flick clears the
# wrister's full-power cursor speed (wrister_mouse_speed_full). Feel tunable.
const AIM_RADIUS_PX: float = 480.0
const AIM_DEADZONE: float = 0.15
# Analog-trigger pull that counts as a press for the wrister / slapshot.
const TRIGGER_THRESHOLD: float = 0.5

var _camera: Camera3D
# The local player's own skater — the on-screen anchor for the gamepad cursor.
var _aim_skater: Node3D = null
# Device id of the pad we read. NOT assumed to be 0 — Godot's connected-joypad id
# depends on connect order / platform, so a real pad can sit on a non-zero id and
# reads against 0 would silently return nothing. Cached and refreshed only on
# connect/disconnect (rare) so the per-tick reads don't allocate. -1 = no pad.
var _pad_device: int = -1
var _local_team_id: int = -1
var _pending_shoot_pressed: bool = false
var _pending_slap_pressed: bool = false
var _pending_stick_lift_pressed: bool = false
var _pending_quick_pass_pressed: bool = false
# Loft mode (0 flat / 1 low saucer / 2 high), stepped by scroll-wheel events (or
# the pad d-pad) in _process and stamped ABSOLUTE into every gathered frame.
# Living here — not as sticky controller state — makes it plain input: reconcile
# replay and the host's input-derived releases both read the level off the frame.
var _elevation_level: int = 0
# Last mouse world position. Returned in place of a fresh sample when input
# is blocked so the stick IK doesn't swing to the rink origin every frame
# the menu is open. Both client and host see the same value (it goes out in
# the input batch), so this does not desync.
var _last_mouse_world_pos: Vector3 = Vector3.ZERO
var _last_mouse_screen_pos: Vector2 = Vector2.ZERO
# Previous-frame pad edge state. The pad is read directly (not through the action
# system), so there is no built-in just_pressed here — we bridge the physics-tick /
# input-frame cadence with the same pending-flag latch the mouse actions use.
var _prev_pad_shoot: bool = false
var _prev_pad_slap: bool = false
var _prev_pad_stick_lift: bool = false
var _prev_pad_quick_pass: bool = false
var _prev_pad_elev_up: bool = false
var _prev_pad_elev_down: bool = false

func _init(camera: Camera3D) -> void:
	_camera = camera

func _ready() -> void:
	# Track which device id our pad is on, refreshed only when a pad connects or
	# disconnects. Capturing the current state here covers a pad already plugged in
	# before this node entered the tree.
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_refresh_pad_device()

func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	_refresh_pad_device()

func _refresh_pad_device() -> void:
	var pads: Array = Input.get_connected_joypads()
	_pad_device = int(pads[0]) if not pads.is_empty() else -1

func set_local_team_id(team_id: int) -> void:
	_local_team_id = team_id

# The local player's skater, used as the on-screen anchor for the gamepad
# skill-stick cursor. Set by LocalController once the skater is spawned.
func set_aim_skater(skater: Node3D) -> void:
	_aim_skater = skater

# Gamepad drives aim/buttons only when the player opted in AND a pad is present —
# with no pad the synthesized cursor would freeze on the skater with no mouse
# fallback. Read live so the Options toggle applies without a respawn.
func _gamepad_active() -> bool:
	return PlayerPrefs.gamepad_enabled and _pad_device >= 0

func _process(_delta: float) -> void:
	# Accumulate just_pressed events every frame — unless input is blocked,
	# in which case presses made over menu UI shouldn't queue up and fire
	# the moment the menu closes.
	if GameManager.is_input_blocked():
		return
	if _gamepad_active():
		_accumulate_gamepad_edges()
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
	if Input.is_action_just_pressed("quick_pass"):
		_pending_quick_pass_pressed = true

# Rising-edge detection for the pad's press-type inputs, mirroring the mouse
# action just_pressed latch above. Triggers (wrister/slapshot) edge on crossing
# TRIGGER_THRESHOLD; the d-pad steps the loft mode in place.
func _accumulate_gamepad_edges() -> void:
	var shoot_now: bool = _pad_trigger(JOY_AXIS_TRIGGER_RIGHT)
	if shoot_now and not _prev_pad_shoot:
		_pending_shoot_pressed = true
	_prev_pad_shoot = shoot_now
	var slap_now: bool = _pad_trigger(JOY_AXIS_TRIGGER_LEFT)
	if slap_now and not _prev_pad_slap:
		_pending_slap_pressed = true
	_prev_pad_slap = slap_now
	var lift_now: bool = Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_RIGHT_SHOULDER)
	if lift_now and not _prev_pad_stick_lift:
		_pending_stick_lift_pressed = true
	_prev_pad_stick_lift = lift_now
	var quick_pass_now: bool = Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_A)
	if quick_pass_now and not _prev_pad_quick_pass:
		_pending_quick_pass_pressed = true
	_prev_pad_quick_pass = quick_pass_now
	var up_now: bool = Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_DPAD_UP)
	if up_now and not _prev_pad_elev_up:
		_elevation_level = mini(_elevation_level + 1, InputState.MAX_ELEVATION_LEVEL)
	_prev_pad_elev_up = up_now
	var down_now: bool = Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_DPAD_DOWN)
	if down_now and not _prev_pad_elev_down:
		_elevation_level = maxi(_elevation_level - 1, 0)
	_prev_pad_elev_down = down_now

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
	var pad: bool = _gamepad_active()
	state.move_vector = _read_move(pad)
	# The screen cursor is the single aim signal: mouse position, or the gamepad
	# skill-stick's synthesized point. World pos ray-projects the RAW cursor; the
	# stored screen pos may then be negated for attack_up (the tracker's frame).
	var raw_screen: Vector2 = _screen_cursor(pad)
	state.mouse_screen_pos = raw_screen
	state.mouse_world_pos = _screen_to_world(_camera, raw_screen)
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
		# accumulates, so every shot fires as a quick pass. Negating screen-
		# pos puts both signals in the same frame for the tracker.
		state.mouse_screen_pos = -state.mouse_screen_pos
	if pad:
		state.shoot_held = _pad_trigger(JOY_AXIS_TRIGGER_RIGHT)
		state.slap_held = _pad_trigger(JOY_AXIS_TRIGGER_LEFT)
		state.brake = Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_B)
		state.sprint_held = Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_LEFT_STICK)
		state.block_held = Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_LEFT_SHOULDER)
		state.stick_lift_held = Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_RIGHT_SHOULDER)
		state.hit_held = Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_X)
	else:
		state.shoot_held = Input.is_action_pressed("shoot")
		state.slap_held = Input.is_action_pressed("slapshot")
		state.brake = Input.is_action_pressed("brake")
		state.sprint_held = Input.is_action_pressed("sprint")
		state.block_held = Input.is_action_pressed("block")
		state.stick_lift_held = Input.is_action_pressed("stick_lift")
		state.hit_held = Input.is_action_pressed("hit")
	# Edge flags come from the pending latch (set in _process for whichever source
	# is active), so the physics-tick / input-frame cadence mismatch is bridged the
	# same way regardless of device.
	state.shoot_pressed = _pending_shoot_pressed
	state.slap_pressed = _pending_slap_pressed
	state.elevation_level = _elevation_level
	state.stick_lift_pressed = _pending_stick_lift_pressed
	state.quick_pass_pressed = _pending_quick_pass_pressed
	state.host_timestamp = NetworkManager.estimated_host_time()
	_last_mouse_world_pos = state.mouse_world_pos
	_last_mouse_screen_pos = state.mouse_screen_pos
	# Clear pending flags after gather
	_pending_shoot_pressed = false
	_pending_slap_pressed = false
	_pending_stick_lift_pressed = false
	_pending_quick_pass_pressed = false
	return state

# Movement vector. Mouse+keyboard reads the WASD action vector; the pad adds the
# left stick on top (both summed and clamped, so a keyboard is still live in pad
# mode). InputState decode also limits this to the unit disc at the trust boundary.
func _read_move(pad: bool) -> Vector2:
	var kbd: Vector2 = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if not pad:
		return kbd
	var stick := Vector2(
			Input.get_joy_axis(_pad_device, JOY_AXIS_LEFT_X),
			Input.get_joy_axis(_pad_device, JOY_AXIS_LEFT_Y))
	stick = GamepadAimRules.apply_radial_deadzone(stick, AIM_DEADZONE)
	return (kbd + stick).limit_length(1.0)

# The screen-space aim cursor: the OS mouse, or the gamepad skill-stick's
# synthesized point anchored on the skater.
func _screen_cursor(pad: bool) -> Vector2:
	if not pad:
		return get_viewport().get_mouse_position()
	var stick := Vector2(
			Input.get_joy_axis(_pad_device, JOY_AXIS_RIGHT_X),
			Input.get_joy_axis(_pad_device, JOY_AXIS_RIGHT_Y))
	return GamepadAimRules.blade_cursor_screen(_aim_anchor_screen(), stick, AIM_RADIUS_PX, AIM_DEADZONE)

# On-screen anchor for the skill-stick cursor: the skater's projected position, so
# the blade cursor tracks the player as the camera follows. Falls back to the
# viewport center before the skater is set or when it is behind the camera.
func _aim_anchor_screen() -> Vector2:
	var vp_center: Vector2 = get_viewport().get_visible_rect().size * 0.5
	if _aim_skater == null or _camera == null:
		return vp_center
	if _camera.is_position_behind(_aim_skater.global_position):
		return vp_center
	return _camera.unproject_position(_aim_skater.global_position)

func _screen_to_world(camera: Camera3D, screen: Vector2) -> Vector3:
	var ray_origin: Vector3 = camera.project_ray_origin(screen)
	var ray_dir: Vector3 = camera.project_ray_normal(screen)
	var t: float = -ray_origin.y / ray_dir.y
	return ray_origin + ray_dir * t

func _pad_trigger(axis: int) -> bool:
	return Input.get_joy_axis(_pad_device, axis) >= TRIGGER_THRESHOLD
