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

# Reach disc: how far the cursor can sit from the anchor on screen. The blade IK
# ROM-clamps beyond this, so it just bounds the cursor to reachable ice. Also the
# radius the cursor is placed at while aiming a shot (so blade→cursor is a clean
# stick-direction line). Feel tunable.
const AIM_RADIUS_PX: float = 480.0
# Stickhandle rest: when the stick is released, the cursor eases to a point this
# many METERS ahead of the body along the facing, so the blade settles into a
# natural forward carry that tracks where you're pointed. Computed in WORLD space
# (not a screen offset) so the screen↔world round-trip is exact and the rest
# doesn't creep under the tilted camera. REST_RETURN_RATE is the ease speed.
const REST_WORLD_DIST: float = 0.55
const REST_RETURN_RATE: float = 10.0
const AIM_DEADZONE: float = 0.15
# Analog-trigger pull that counts as a press for the wrister / slapshot.
const TRIGGER_THRESHOLD: float = 0.5

var _camera: Camera3D
# The local player's own skater — the on-screen anchor for the gamepad cursor and
# the source of the facing the blade rests ahead of.
var _aim_skater: Skater = null
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
# Gamepad blade cursor (screen space). While stickhandling the stick maps to an
# absolute offset from the anchor; while shooting (RT) it is parked at the reach
# radius in the stick direction (aim). Seeded to the anchor on the first active
# frame (or after a pad reconnect) so it starts on the player.
var _pad_cursor: Vector2 = Vector2.ZERO
var _pad_cursor_valid: bool = false
# Committed wrister power (0..1) = how hard the right stick is pushed, latched while
# RT is held so the shot reads the held power even on the release frame. Aim is the
# stick DIRECTION, power the MAGNITUDE. _prev_gather_rt keeps commit_wrister_power
# true for that one release frame (RT already read as up) so the shot fired on RT-up
# still routes through the committed-power / player→cursor-aim path.
var _committed_wrister_power: float = 0.0
var _prev_gather_rt: bool = false
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
	# Re-seed the cursor onto the player next active frame (device swap / reconnect).
	_pad_cursor_valid = false

func set_local_team_id(team_id: int) -> void:
	_local_team_id = team_id

# The local player's skater, used as the on-screen anchor for the gamepad cursor
# and the facing the blade rests ahead of. Set by LocalController at spawn.
func set_aim_skater(skater: Skater) -> void:
	_aim_skater = skater

# Gamepad drives aim/buttons only when the player opted in AND a pad is present —
# with no pad the synthesized cursor would freeze on the skater with no mouse
# fallback. Read live so the Options toggle applies without a respawn.
func _gamepad_active() -> bool:
	return PlayerPrefs.gamepad_enabled and _pad_device >= 0

func _process(delta: float) -> void:
	# Accumulate just_pressed events every frame — unless input is blocked,
	# in which case presses made over menu UI shouldn't queue up and fire
	# the moment the menu closes.
	if GameManager.is_input_blocked():
		return
	if _gamepad_active():
		_accumulate_gamepad_edges()
		_update_pad_cursor(delta)
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
	var lift_now: bool = _pad_held("stick_lift")
	if lift_now and not _prev_pad_stick_lift:
		_pending_stick_lift_pressed = true
	_prev_pad_stick_lift = lift_now
	var quick_pass_now: bool = _pad_held("quick_pass")
	if quick_pass_now and not _prev_pad_quick_pass:
		_pending_quick_pass_pressed = true
	_prev_pad_quick_pass = quick_pass_now
	var up_now: bool = _pad_held("elevation_up")
	if up_now and not _prev_pad_elev_up:
		_elevation_level = mini(_elevation_level + 1, InputState.MAX_ELEVATION_LEVEL)
	_prev_pad_elev_up = up_now
	var down_now: bool = _pad_held("elevation_down")
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
		state.brake = _pad_held("brake")
		state.sprint_held = _pad_held("sprint")
		state.block_held = _pad_held("block")
		state.stick_lift_held = _pad_held("stick_lift")
		state.hit_held = _pad_held("hit")
		# COMMITTED WRISTER: aim comes from the cursor position (parked in the stick
		# direction in _update_pad_cursor → player→cursor is the shot line), power from
		# how hard the stick is pushed (its magnitude) — no flick, no drag timing, no
		# travel gate. Latch the power while RT is held and keep commit true one frame
		# into the release so the shot (fired on RT-up) reads the held power.
		if state.shoot_held:
			_committed_wrister_power = _pad_right_stick_dz().length()
		state.commit_wrister_power = state.shoot_held or _prev_gather_rt
		state.bot_wrister_power_t = _committed_wrister_power
		_prev_gather_rt = state.shoot_held
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

# The screen-space aim cursor: the OS mouse, or the gamepad cursor (advanced in
# _update_pad_cursor). Seeds the gamepad cursor to the anchor on first read so it
# starts on the player even before _process runs.
func _screen_cursor(pad: bool) -> Vector2:
	if not pad:
		return get_viewport().get_mouse_position()
	if not _pad_cursor_valid:
		_pad_cursor = _aim_anchor_screen()
		_pad_cursor_valid = true
	return _pad_cursor

# Update the gamepad cursor. Two modes, chosen on the shoot trigger:
#   * STICKHANDLE (RT up): absolute proportional placement — the stick maps to a
#     blade offset from the anchor. Releasing the stick eases the cursor to a rest
#     just ahead of the body along the facing, so the blade settles into a natural
#     forward carry that tracks where you're pointed.
#   * SHOOT (RT held): the cursor is parked at the reach radius in the stick
#     DIRECTION, so the shot line (player→cursor, the release fallback used when the
#     committed path zeroes the drag direction) is exactly where the stick points —
#     a clean, held aim. Power is how hard the stick is pushed (committed in gather).
func _update_pad_cursor(delta: float) -> void:
	var anchor: Vector2 = _aim_anchor_screen()
	if not _pad_cursor_valid:
		_pad_cursor = anchor
		_pad_cursor_valid = true
	var stick := _pad_right_stick_dz()
	if _pad_trigger(JOY_AXIS_TRIGGER_RIGHT):
		# Aim = stick direction only (a full radius out). A centered stick during RT
		# holds the last aim so a shot already lined up doesn't drift to center.
		if not stick.is_zero_approx():
			_pad_cursor = GamepadAimRules.absolute_cursor(anchor, stick.normalized(), AIM_RADIUS_PX)
	elif not stick.is_zero_approx():
		_pad_cursor = GamepadAimRules.absolute_cursor(anchor, stick, AIM_RADIUS_PX)
	else:
		# Stickhandle mode, stick released → ease the blade to its forward carry rest.
		var ease: float = clampf(REST_RETURN_RATE * delta, 0.0, 1.0)
		_pad_cursor = _pad_cursor.lerp(_facing_rest_screen(anchor), ease)

# Deadzoned right stick (aim), in the JOY_AXIS_RIGHT_* / screen convention.
func _pad_right_stick_dz() -> Vector2:
	return GamepadAimRules.apply_radial_deadzone(Vector2(
			Input.get_joy_axis(_pad_device, JOY_AXIS_RIGHT_X),
			Input.get_joy_axis(_pad_device, JOY_AXIS_RIGHT_Y)), AIM_DEADZONE)

# The stickhandle rest cursor: a WORLD point REST_WORLD_DIST metres ahead of the
# body along the facing, projected to screen. Computing it in world space (not a
# screen-pixel offset) makes the cursor's screen→world round-trip land back exactly
# on this point — so the facing tracker (which chases the cursor while the cursor
# chases this facing-derived rest) settles instead of creeping under the tilt.
# On the flat ice (y = 0) the round-trip is exact. Falls back to the anchor with no
# skater/facing or when the point is behind the camera.
func _facing_rest_screen(anchor: Vector2) -> Vector2:
	if _aim_skater == null or _camera == null:
		return anchor
	var facing: Vector2 = _aim_skater.get_facing()
	if facing.is_zero_approx():
		return anchor
	var f: Vector2 = facing.normalized()
	var pos: Vector3 = _aim_skater.global_position
	var rest_world := Vector3(pos.x + f.x * REST_WORLD_DIST, 0.0, pos.z + f.y * REST_WORLD_DIST)
	if _camera.is_position_behind(rest_world):
		return anchor
	return _camera.unproject_position(rest_world)

# On-screen anchor for the gamepad cursor: the skater's projected position, so the
# reach disc tracks the player as the camera follows. Falls back to the viewport
# center before the skater is set or when it is behind the camera.
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

# Held state of a REBINDABLE pad button, resolved through the player's gamepad
# binds (PlayerPrefs.pad_button) so an Options rebind applies live with no respawn.
# The analog triggers and sticks are structural to the scheme and read directly
# (not through here). Cheap: a Dictionary int lookup, no allocation.
func _pad_held(action: String) -> bool:
	return Input.is_joy_button_pressed(_pad_device, PlayerPrefs.pad_button(action))
