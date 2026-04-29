class_name SkaterController
extends Node

# ── State Machine ─────────────────────────────────────────────────────────────
# Type alias so LocalController and RemoteController keep compiling without
# changes when they reference State.X values or use State as a type annotation.
const State = SkaterStateMachine.State
var _sm: SkaterStateMachine = SkaterStateMachine.new()

# ── Movement Tuning ───────────────────────────────────────────────────────────
@export var thrust: float = 12.0
@export var friction: float = 0.8
@export var friction_drag: float = 0.27
@export var max_speed: float = 10.5
@export var move_deadzone: float = 0.1
@export var brake_multiplier: float = 4.0
@export var puck_carry_speed_multiplier: float = 0.82
@export var backward_thrust_multiplier: float = 0.80
@export var crossover_thrust_multiplier: float = 0.90
# ── Facing Tuning ─────────────────────────────────────────────────────────────
# How fast facing drifts toward the cursor during normal play. Lower = more
# skating lag before the body re-orients (more backskate/crossover time).
# Shift freezes facing entirely (see SkaterPoseCoordinator.apply_facing). Good range: 1.0 (very lazy) – 3.0 (snappy).
@export var facing_drag_speed: float = 3.0
@export var facing_drag_speed_braking: float = 8.0

# ── Blade / Stick / Top-Hand IK Tuning ────────────────────────────────────────
# Blade world-space Y. 0.0 = ice surface. Converted to upper-body-local via
# SkaterIKCoordinator.blade_y_local() before any IK or pose call, so the blade always sits at a
# fixed world height regardless of where the upper body anchor is placed in the
# scene. This also means crouching (block stance) doesn't pull the blade
# through the ice — the local Y compensates automatically.
@export var blade_height: float = 0.03
# Fixed, rigid shaft length (hand to blade heel). Baseline 1.30 m ≈ adult
# senior stick shaft (butt-to-heel). The blade mesh extends forward from the
# heel; see Skater.blade_length. Total hand-to-toe is stick_length + blade_length.
@export var stick_length: float = 1.30
# Hand Y in upper-body-local space. Baseline resting position (used in the
# FAR regime). In the CLOSE regime the hand rises toward `hand_y_max` so the
# stick tilts more vertical and the blade can tuck in close to the body.
# With the upper body at ~0.95 m world Y and blade at 0.0 (ice), -0.17 gives
# a hand world Y of ~0.78 m and a stick angle of ~37° — shallower than the
# previous ~47° and closer to a real hockey address position. Horizontal reach
# at rest rises from ~0.89 m to ~1.04 m.
@export var hand_rest_y: float = -0.17
# Ceiling for hand Y in the CLOSE regime. When aiming very close to the
# skater, the hand rises to shorten the stick's horizontal projection; this
# cap keeps the pose anatomical (hand won't climb past chin level). With
# default stick_length = 1.30 m, hand_y_max = 0.30 → min horizontal stick
# reach ≈ 0.36 m.
@export var hand_y_max: float = 0.30
# Asymmetric ROM for the top hand (measured from shoulder in upper-body-local
# horizontal plane, expressed in "forehand side = positive angle" convention).
# Forehand cross-body reach is anatomically limited; backhand same-side reach
# allows full arm extension, supporting one-handed backhand plays.
# Note: the upper body twists toward the blade (upper_body_twist_ratio = 1.0),
# which effectively reduces how far the hand must reach in upper-body-local space
# — these values assume that twist is active.
@export var rom_forehand_angle_max_deg: float = 90.0
@export var rom_backhand_angle_max_deg: float = 90.0
@export var rom_forehand_reach_max: float = 0.45
@export var rom_backhand_reach_max: float = 0.70

# ── Bottom-Hand IK Tuning ─────────────────────────────────────────────────────
# The bottom hand is purely reactive: each tick it targets a point a short way
# down the stick shaft (from the top hand toward the blade). It releases toward
# a shoulder rest only when the blade's world angle exceeds the upper body's
# rotation limit — ensuring the hand stays connected during any normal swing.
# Never influences blade placement. See domain/rules/bottom_hand_ik.gd.
# Fraction along the shaft (0 = top hand, 1 = blade heel) that the bottom hand
# grips. ~0.25 on a 1.30 m shaft ≈ a typical hockey grip width.
@export var bottom_hand_grip_fraction: float = 0.25
# Bottom hand resting Y in upper-body-local. Same height as top hand rest.
@export var bh_hand_y: float = 0.0
# Blade world angle (from skater forward, toward backhand) at which the bottom
# hand starts releasing toward the shoulder rest. Match upper_body_max_twist_deg
# so the hand releases exactly when the body can no longer rotate to follow.
@export var bh_release_angle_deg: float = 67.0
# Degrees past bh_release_angle_deg over which the hand blends to full rest.
@export var bh_release_angle_band_deg: float = 15.0

# ── Upper Body Tuning ─────────────────────────────────────────────────────────
@export var upper_body_twist_ratio: float = 0.8
@export var upper_body_max_twist_deg: float = 67.0   # caps rotation so extreme angles don't over-rotate
@export var upper_body_return_speed: float = 6.0
@export var upper_body_lean_max_deg: float = 15.0
@export var upper_body_lean_return_speed: float = 8.0

# ── Velocity Lean Tuning ──────────────────────────────────────────────────────
@export var velocity_lean_max_deg: float = 10.0
@export var velocity_lean_speed: float = 6.0

# ── Lower Body Lag Tuning ─────────────────────────────────────────────────────
@export var lower_body_lag_max_deg: float = 20.0
@export var lower_body_lag_speed: float = 5.0

# ── Wrister Tuning ────────────────────────────────────────────────────────────
@export var min_wrister_power: float = 14.0
@export var max_wrister_power: float = 24.0
@export var max_wrister_charge_distance: float = 2.0
@export var backhand_power_coefficient: float = 0.75
@export var max_charge_direction_variance: float = 35.0
@export var quick_shot_power: float = 14.0
@export var quick_shot_threshold: float = 0.1
@export var quick_shot_elevation: float = 0.10
@export var wrister_elevation_target_height: float = 0.90
# Apex cap for elevated shots — puck can't rise more than this above the blade.
# 1.5 m is just under the glass, well above crossbar (1.22 m). On-net shots
# arrive at goal line at ≤ target_height; missed shots can't fly over boards.
@export var max_apex_above_blade: float = 1.5
# Cosine of the half-angle cone within which a shot counts as "toward the net".
# 0.5 = 60° cone. Shots outside this cone use `away_from_net_elevation` instead
# of the ballistic-targeting math.
@export var toward_net_dot_threshold: float = 0.5
# Fixed Y direction for elevated shots not aimed at the offensive net (passes,
# clears, backward dumps). Small positive value so the puck still lifts off ice
# without trying to arc toward an irrelevant target height.
@export var away_from_net_elevation: float = 0.10

# ── Head Tracking Tuning ─────────────────────────────────────────────────────
@export var head_track_speed: float = 12.0
@export var head_track_max_deg: float = 60.0

# ── Slapper Tuning ────────────────────────────────────────────────────────────
@export var slapper_wind_up_height: float = 0.4
@export var slapper_wind_up_time: float = 0.3
@export var slapper_zone_radius: float = 0.5
@export var slapper_zone_offset_x: float = 0.8  # lateral offset toward blade side
@export var slapper_zone_offset_z: float = -1.0  # forward offset (negative = in front of player)
@export var min_slapper_power: float = 17.0
@export var max_slapper_power: float = 34.0
@export var max_slapper_charge_time: float = 0.7
@export var slapper_blade_x: float = 1.0
@export var slapper_blade_z: float = -0.5
@export var slapper_aim_arc: float = 45.0
@export var slapper_elevation_target_height: float = 0.65
@export var one_timer_window_duration: float = 0.45  # seconds after puck arrives to release
@export var one_timer_leniency_time: float = 0.08   # seconds of puck travel added to zone radius as leniency
@export var one_timer_center_power_bonus: float = 0.10  # ±10%: edge of zone = −10%, dead centre = +10%

var show_one_timer_indicator: bool = false

# ── Follow Through Tuning ─────────────────────────────────────────────────────
@export var follow_through_duration: float = 0.25
@export var wrister_follow_through_hand_y: float = 0.35
@export var wrister_follow_through_blade_lift: float = 0.20
@export var slapper_follow_through_arc_dist: float = 0.4  # blade XZ travel along shot_dir during follow-through

# ── Shot-Block Tuning ─────────────────────────────────────────────────────────
@export var block_speed_multiplier: float = 0.45   # movement speed while blocking
@export var active_block_dampen: float = 0.35      # puck energy retention on active block

# ── Goalie Body Block ─────────────────────────────────────────────────────────
# XZ cylinder radius used to push the blade (and carried puck) away from a
# goalie's body center. Tunable in the editor — matches roughly the goalie's
# padded chest width. The hand moves with the blade to keep stick length intact.
@export var goalie_block_radius: float = 0.50
@export var goalie_strip_power: float = 1.5
# Half-extents of the butterfly leg-pad strip box in goalie local XZ space.
@export var butterfly_pad_half_x: float = 0.84
@export var butterfly_pad_half_z: float = 0.25

# ── References ────────────────────────────────────────────────────────────────
var skater: Skater = null
var puck: Puck = null
# Injected at setup. Expected methods:
#   is_host() -> bool                              — changes only per session; cached in _is_host
#   is_movement_locked() -> bool                   — polled per frame
#   get_goalie_data() -> Array[Dictionary]         — position/rotation_y/is_butterfly per goalie
var _game_state: Node = null
var _is_host: bool = false

# ── Runtime State ─────────────────────────────────────────────────────────────
var _blade_relative_angle: float = 0.0
var _is_elevated: bool = false
var _aiming: SkaterAimingBehavior = SkaterAimingBehavior.new()
var _pose: SkaterPoseCoordinator = SkaterPoseCoordinator.new()
var _shot_pose: SkaterShotPoseCoordinator = SkaterShotPoseCoordinator.new()
var _ik: SkaterIKCoordinator = SkaterIKCoordinator.new()
var last_processed_host_timestamp: float = 0.0
var has_puck: bool = false
var is_replaying: bool = false

# ── Setup ─────────────────────────────────────────────────────────────────────
func setup(assigned_skater: Skater, assigned_puck: Puck, game_state: Node) -> void:
	skater = assigned_skater
	puck = assigned_puck
	_game_state = game_state
	_is_host = game_state.is_host()
	process_physics_priority = -1  # Run before Skater.move_and_slide
	skater.body_checked_player.connect(_on_body_checked_player)
	skater.body_block_hit.connect(_on_body_block_hit)
	_ik.setup(skater, self)
	_shot_pose.setup(skater, _sm, _aiming, _ik, self)
	var _cb := SkaterStateMachine.Callbacks.new()
	_cb.apply_blade_from_mouse = _ik.apply_blade_from_mouse
	_cb.apply_slapper_blade_position = _shot_pose.apply_slapper_blade_position
	_cb.apply_wrister_follow_through = _shot_pose.apply_wrister_follow_through
	_cb.apply_slapper_follow_through = _shot_pose.apply_slapper_follow_through
	_cb.enter_shot_block = _enter_shot_block
	_cb.enter_slapper_charge = _enter_slapper_charge
	_cb.transition_to_skating = _transition_to_skating
	_cb.release_wrister = _release_wrister
	_cb.release_slapper = _release_slapper
	_cb.try_one_timer_release = _try_one_timer_release
	_cb.update_wrister_charge = _update_wrister_charge
	_cb.update_slapper_charge = _update_slapper_charge
	_cb.apply_slapper_velocity_drag = _apply_slapper_velocity_drag
	_cb.apply_block_movement = _apply_block_movement
	_sm.setup(_cb, _aiming)
	_pose.setup(skater, _sm, self)

func _on_body_checked_player(victim: Skater, impact_force: float, hit_direction: Vector3) -> void:
	if not _is_host:
		return
	puck.on_body_check(skater, victim, impact_force, hit_direction)

func _on_body_block_hit(body: Node3D) -> void:
	if not _is_host:
		return
	if not body is Puck:
		return
	var dampen: float = active_block_dampen if _sm.get_state() == State.SHOT_BLOCKING else puck.body_block_dampen
	puck.on_body_block(skater, dampen)

# ── Entry Point ───────────────────────────────────────────────────────────────
func _process_input(input: InputState, delta: float) -> void:
	if input.elevation_up:
		_is_elevated = true
	if input.elevation_down:
		_is_elevated = false
	skater.is_elevated = _is_elevated

	_apply_movement(input, delta)
	_pose.apply_velocity_lean(delta)
	_pose.apply_facing(input, delta)
	_apply_state(input, delta)
	# Save blade/hand world positions before upper body rotation. After the body
	# rotates toward the blade, re-expressing these in the new local frame gives
	# the bottom-hand IK the post-rotation geometry — so arm reach is evaluated
	# as if the body has fully caught up, independent of lerp speed.
	var blade_world_pre: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
	var hand_world_pre: Vector3 = skater.upper_body_to_global(skater.get_top_hand_position())
	_pose.apply_upper_body(delta)
	_pose.apply_head_tracking(input, delta)
	skater.set_top_hand_position(skater.upper_body_to_local(hand_world_pre))
	skater.set_blade_position(skater.upper_body_to_local(blade_world_pre))
	_ik.update_bottom_hand()
	# All mesh updates happen after upper body rotation is finalised so look_at
	# orientations are computed against the correct parent transform this frame.
	skater.update_stick_mesh()
	skater.update_arm_mesh()
	skater.update_bottom_arm_mesh()
	if not is_replaying:
		_pose.update_angular_velocities(delta)

# ── Network State ─────────────────────────────────────────────────────────────
# Returns the typed network state object. Flattening to Array happens at the
# RPC boundary (GameManager.get_world_state), not here.
func get_network_state() -> SkaterNetworkState:
	var state := SkaterNetworkState.new()
	state.position = skater.global_position
	state.velocity = skater.velocity
	state.blade_position = skater.get_blade_position()
	state.blade_contact_world = skater.get_blade_contact_global()
	state.top_hand_position = skater.get_top_hand_position()
	state.upper_body_rotation_y = skater.get_upper_body_rotation()
	state.facing = skater.get_facing()
	state.facing_angular_velocity = _pose.facing_angular_velocity
	state.upper_body_angular_velocity = _pose.upper_body_angular_velocity
	state.last_processed_host_timestamp = last_processed_host_timestamp
	state.is_ghost = skater.is_ghost
	state.shot_state = _sm.get_state() as int
	state.shot_charge = _aiming.charge_distance
	return state

func get_shot_state() -> int:
	return _sm.get_state()

func apply_network_state(_net_state: SkaterNetworkState, _host_ts: float) -> void:
	pass  # overridden by RemoteController on client

func apply_replay_state(state: SkaterNetworkState) -> void:
	if skater == null:
		return
	skater.global_position = state.position
	skater.visual_offset = Vector3.ZERO
	skater.velocity = state.velocity
	skater.set_facing(state.facing)
	skater.set_upper_body_rotation(state.upper_body_rotation_y)
	skater.set_top_hand_position(state.top_hand_position)
	skater.set_blade_position(state.blade_position)
	_ik.update_bottom_hand()
	skater.update_stick_mesh()
	skater.update_arm_mesh()
	skater.update_bottom_arm_mesh()
	
signal puck_release_requested(direction: Vector3, power: float, is_slapper: bool)
# Fired when the player releases slap while the puck is nearby but not yet
# carried — the leniency one-timer. GameManager acquires + releases the puck;
# the controller transitions to follow-through immediately.
signal one_timer_release_requested(direction: Vector3, power: float)

func _do_release(direction: Vector3, power: float) -> void:
	if is_replaying:
		return
	var slapper: bool = _sm.get_state() == State.SLAPPER_CHARGE_WITH_PUCK
	puck_release_requested.emit(direction, power, slapper)

# ── Puck Signals ──────────────────────────────────────────────────────────────
func on_puck_picked_up_network() -> void:
	has_puck = true
	var local_blade: Vector3 = skater.get_blade_position() - skater.shoulder.position
	_blade_relative_angle = atan2(local_blade.x, -local_blade.z)
	if _sm.get_state() == State.SLAPPER_CHARGE_WITHOUT_PUCK:
		# One-timer: puck arrived during a slapper charge. Open the timing
		# window — player must release within one_timer_window_duration or
		# the shot is cancelled and they keep the puck in carry state.
		skater.set_slapper_zone(false)
		skater.set_slapper_mode(true)
		_aiming.one_timer_window_timer = one_timer_window_duration + NetworkManager.get_latest_rtt_ms() / 2000.0
		_sm.set_state(State.SLAPPER_CHARGE_WITH_PUCK)
		if show_one_timer_indicator:
			skater.update_slapper_indicator_convergence(1.0)
			skater.update_slapper_indicator_window(1.0)
	else:
		_sm.set_state(State.SKATING_WITH_PUCK)

func on_puck_released_network() -> void:
	if not has_puck:
		return
	has_puck = false
	_transition_to_skating()

func teleport_to(pos: Vector3) -> void:
	skater.global_position = pos
	skater.velocity = Vector3.ZERO

# ── State Machine ─────────────────────────────────────────────────────────────
func _apply_state(input: InputState, delta: float) -> void:
	_sm.dispatch(skater, input, delta, has_puck, _game_state.is_movement_locked())

# ── State Helpers ─────────────────────────────────────────────────────────────
func _transition_to_skating() -> void:
	# Lost-charge feedback: if we're leaving an active charge state without
	# firing (i.e. not via FOLLOW_THROUGH), flash the charge ring red. The
	# ring auto-clears via Skater._physics_process once the flash decays.
	var prev_state: int = _sm.get_state()
	var was_charging: bool = prev_state == State.WRISTER_AIM \
			or prev_state == State.SLAPPER_CHARGE_WITH_PUCK \
			or prev_state == State.SLAPPER_CHARGE_WITHOUT_PUCK
	skater.shot_charge = 0.0
	skater.slapper_aim_dir = Vector3.ZERO
	if has_puck:
		_sm.set_state(State.SKATING_WITH_PUCK)
	else:
		_sm.set_state(State.SKATING_WITHOUT_PUCK)
	_sm.shot_dir = Vector3.ZERO
	_pose.reset_lean_and_lag()
	skater.set_lower_body_lag(0.0)
	skater.set_slapper_mode(false)
	skater.set_slapper_zone(false)
	if show_one_timer_indicator:
		skater.set_slapper_indicator(false)
		skater.set_slapshot_arrow(false)
		skater.set_charge_ring_visible(false)
		if was_charging:
			skater.trigger_charge_lost_flash()

func _enter_shot_block() -> void:
	_sm.set_state(State.SHOT_BLOCKING)
	skater.set_block_stance(true)
	# Snap facing toward puck on entry — locked for duration of stance
	var to_puck: Vector3 = puck.global_position - skater.global_position
	to_puck.y = 0.0
	if to_puck.length() > 0.01:
		_pose.facing = Vector2(to_puck.x, to_puck.z).normalized()
		skater.set_facing(_pose.facing)

func _enter_slapper_charge(input: InputState) -> void:
	_aiming.reset_slapper()
	_sm.shot_dir = Vector3.ZERO
	# Snap facing toward mouse first so the blade-side world position is correct.
	var to_mouse := Vector2(
		input.mouse_world_pos.x - skater.global_position.x,
		input.mouse_world_pos.z - skater.global_position.z)
	_pose.facing = to_mouse.normalized() if to_mouse.length() > move_deadzone else _pose.facing
	skater.set_facing(_pose.facing)
	# Lock aim direction from the actual blade-side release point → mouse.
	var blade_side_sign: float = -1.0 if skater.is_left_handed else 1.0
	var blade_local := Vector3(
		skater.shoulder.position.x + blade_side_sign * slapper_blade_x,
		_ik.blade_y_local(),
		skater.shoulder.position.z + slapper_blade_z)
	var blade_world: Vector3 = skater.upper_body_to_global(blade_local)
	var to_mouse_from_blade := Vector2(
		input.mouse_world_pos.x - blade_world.x,
		input.mouse_world_pos.z - blade_world.z)
	_sm.locked_slapper_dir = to_mouse_from_blade.normalized() if to_mouse_from_blade.length() > move_deadzone else _pose.facing
	skater.slapper_aim_dir = Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
	_pose.reset_lean_and_lag()
	skater.set_upper_body_rotation(0.0)
	skater.set_upper_body_lean(0.0)
	skater.set_lower_body_lean(0.0, 0.0)
	skater.set_lower_body_lag(0.0)
	if has_puck:
		skater.set_slapper_mode(true)
		_sm.set_state(State.SLAPPER_CHARGE_WITH_PUCK)
	else:
		# Activate the ice-level slapper zone so the puck can be detected at
		# ground level even though the blade is lifted during wind-up.
		skater.set_slapper_zone(true, slapper_zone_radius, slapper_zone_offset_x, slapper_zone_offset_z)
		_sm.set_state(State.SLAPPER_CHARGE_WITHOUT_PUCK)
		if show_one_timer_indicator:
			skater.set_slapper_indicator(true, slapper_zone_offset_x, slapper_zone_offset_z, slapper_zone_radius)
	if show_one_timer_indicator:
		skater.set_charge_ring_visible(true)
		skater.set_slapshot_arrow(true, slapper_zone_offset_x, slapper_zone_offset_z, slapper_zone_radius)
		skater.update_slapshot_arrow_direction(skater.slapper_aim_dir)

func _get_charge_direction() -> Vector3:
	return _aiming.prev_blade_dir

func _release_wrister(input: InputState) -> void:
	if has_puck:
		var blade_world: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
		# _prev_blade_dir is the world-space direction the cursor was dragged
		# (relative to the player, so skating velocity is already removed).
		var result := ShotMechanics.release_wrister(
				skater.global_position,
				input.mouse_world_pos,
				blade_world,
				skater.get_blade_position(),
				skater.shoulder.position,
				skater.is_left_handed,
				_is_elevated,
				_aiming.charge_distance,
				_wrister_config(),
				_get_charge_direction())
		_sm.shot_dir = result.direction
		_do_release(result.direction, result.power)

	_sm.follow_through_is_slapper = false
	_sm.set_state(State.FOLLOW_THROUGH)
	_sm.follow_through_timer = follow_through_duration

func _release_slapper(input: InputState, one_timer: bool = false) -> void:
	if has_puck:
		# Direction is locked at the moment slap was pressed — no mid-swing steering.
		var locked_dir_3d := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
		var cfg: ShotMechanics.SlapperConfig = _slapper_config()
		# One-timers always fire at max power regardless of actual charge built.
		var charge: float = cfg.max_slapper_charge_time if one_timer else _aiming.slapper_charge_timer
		var result := ShotMechanics.release_slapper(
				skater.upper_body_to_global(skater.get_blade_position()),
				input.mouse_world_pos,
				_is_elevated,
				charge,
				cfg,
				locked_dir_3d)
		_sm.shot_dir = result.direction
		_do_release(result.direction, result.power)

	_sm.follow_through_is_slapper = true
	_sm.set_state(State.FOLLOW_THROUGH)
	_sm.follow_through_timer = follow_through_duration

func _update_wrister_charge(input: InputState) -> void:
	if not has_puck:
		return
	_aiming.tick_wrister_charge(input.mouse_screen_pos, max_charge_direction_variance, max_wrister_charge_distance)
	skater.shot_charge = _aiming.charge_distance / max_wrister_charge_distance
	# Charge ring is local-only; gate on the same flag as the one-timer reticle.
	if show_one_timer_indicator:
		skater.set_charge_ring_visible(true)

func _update_slapper_charge(delta: float) -> void:
	_aiming.tick_slapper(delta)
	skater.shot_charge = minf(_aiming.slapper_charge_timer / max_slapper_charge_time, 1.0)
	if show_one_timer_indicator:
		skater.update_slapshot_arrow_direction(skater.slapper_aim_dir)

func _apply_slapper_velocity_drag(delta: float) -> void:
	var slapper_vel := Vector2(skater.velocity.x, skater.velocity.z)
	var drag: float = friction + friction_drag * slapper_vel.length()
	slapper_vel = slapper_vel.move_toward(Vector2.ZERO, drag * delta)
	skater.velocity.x = slapper_vel.x
	skater.velocity.z = slapper_vel.y

func _try_one_timer_release(input: InputState) -> Dictionary:
	# Use XZ distance from the slapper zone center (ground level) — this matches
	# the ring indicator the player sees and avoids penalising blade height since
	# the blade is lifted during wind-up.
	var zone_world: Vector3 = skater.get_slapper_zone_global_position()
	var zone_xz := Vector2(zone_world.x, zone_world.z)
	var puck_xz := Vector2(puck.global_position.x, puck.global_position.z)
	var dist: float = zone_xz.distance_to(puck_xz)
	if dist > _effective_one_timer_leniency():
		return {fired = false}
	var blade_world: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
	var locked_dir_3d := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
	var cfg: ShotMechanics.SlapperConfig = _slapper_config()
	var result := ShotMechanics.release_slapper(
			blade_world, input.mouse_world_pos,
			_is_elevated, cfg.max_slapper_charge_time, cfg, locked_dir_3d)
	var proximity: float = clampf(1.0 - dist / slapper_zone_radius, 0.0, 1.0)
	result.power *= 1.0 + one_timer_center_power_bonus * (2.0 * proximity - 1.0)
	if not is_replaying:
		one_timer_release_requested.emit(result.direction, result.power)
	return {fired = true, direction = result.direction, follow_through_duration = follow_through_duration}

func _apply_block_movement(input: InputState, delta: float) -> void:
	skater.velocity = SkaterMovementRules.apply_movement(
			skater.velocity, input.move_vector, skater.rotation.y,
			false, input.brake, delta, _block_movement_config())

func _effective_one_timer_leniency() -> float:
	var puck_xz_speed: float = Vector2(puck.linear_velocity.x, puck.linear_velocity.z).length()
	return slapper_zone_radius + puck_xz_speed * one_timer_leniency_time

func _is_in_slapper_state() -> bool:
	return _sm.get_state() in [State.SLAPPER_CHARGE_WITH_PUCK, State.SLAPPER_CHARGE_WITHOUT_PUCK]

# ── Movement ──────────────────────────────────────────────────────────────────
func _apply_movement(input: InputState, delta: float) -> void:
	# Brake held — drives hockey stop VFX (gated on speed in skater_vfx.gd).
	skater.is_braking = input.brake
	skater.is_braced = input.brake

	if _sm.get_state() in [State.SLAPPER_CHARGE_WITH_PUCK, State.SHOT_BLOCKING]:
		return

	var cfg: SkaterMovementRules.MovementConfig = _movement_config()
	skater.velocity = SkaterMovementRules.apply_movement(
			skater.velocity, input.move_vector, skater.rotation.y,
			has_puck, input.brake, delta, cfg)

func _movement_config() -> SkaterMovementRules.MovementConfig:
	var cfg := SkaterMovementRules.MovementConfig.new()
	cfg.thrust = thrust
	cfg.friction = friction
	cfg.friction_drag = friction_drag
	cfg.max_speed = max_speed
	cfg.move_deadzone = move_deadzone
	cfg.brake_multiplier = brake_multiplier
	cfg.puck_carry_speed_multiplier = puck_carry_speed_multiplier
	cfg.backward_thrust_multiplier = backward_thrust_multiplier
	cfg.crossover_thrust_multiplier = crossover_thrust_multiplier
	return cfg

func _block_movement_config() -> SkaterMovementRules.MovementConfig:
	var cfg: SkaterMovementRules.MovementConfig = _movement_config()
	cfg.max_speed = max_speed * block_speed_multiplier
	cfg.thrust = thrust * block_speed_multiplier
	return cfg

func _wrister_config() -> ShotMechanics.WristerConfig:
	var cfg := ShotMechanics.WristerConfig.new()
	cfg.min_wrister_power = min_wrister_power
	cfg.max_wrister_power = max_wrister_power
	cfg.max_wrister_charge_distance = max_wrister_charge_distance
	cfg.backhand_power_coefficient = backhand_power_coefficient
	cfg.quick_shot_power = quick_shot_power
	cfg.quick_shot_threshold = quick_shot_threshold
	cfg.quick_shot_elevation = quick_shot_elevation
	cfg.elevation_target_height = wrister_elevation_target_height
	cfg.elevation_blade_height = 0.05
	cfg.elevation_gravity = 9.8
	cfg.elevation_goal_line_z = GameRules.GOAL_LINE_Z
	cfg.max_apex_above_blade = max_apex_above_blade
	cfg.attacking_goal_z = get_attacking_goal_z()
	cfg.toward_net_dot_threshold = toward_net_dot_threshold
	cfg.away_from_net_y = away_from_net_elevation
	return cfg

func _slapper_config() -> ShotMechanics.SlapperConfig:
	var cfg := ShotMechanics.SlapperConfig.new()
	cfg.min_slapper_power = min_slapper_power
	cfg.max_slapper_power = max_slapper_power
	cfg.max_slapper_charge_time = max_slapper_charge_time
	cfg.elevation_target_height = slapper_elevation_target_height
	cfg.elevation_blade_height = 0.05
	cfg.elevation_gravity = 9.8
	cfg.elevation_goal_line_z = GameRules.GOAL_LINE_Z
	cfg.max_apex_above_blade = max_apex_above_blade
	cfg.attacking_goal_z = get_attacking_goal_z()
	cfg.toward_net_dot_threshold = toward_net_dot_threshold
	cfg.away_from_net_y = away_from_net_elevation
	return cfg

# Signed Z of the goal this skater is attacking. Default 0.0 means "team
# unknown" — the elevation math falls back to picking a goal by shot_dir.z
# sign. LocalController overrides this once team_id is set.
func get_attacking_goal_z() -> float:
	return 0.0

