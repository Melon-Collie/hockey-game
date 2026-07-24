class_name SkaterPoseCoordinator
extends RefCounted

# Owns the per-tick pose layer: facing, upper-body twist/lean, velocity lean,
# lower-body lag, and head tracking. Stateless transforms live on the rules
# layer; this class carries the smoothed runtime state plus angular-velocity
# bookkeeping for network export.
#
# Pose state is read by LocalController.reconcile (facing snap, IK lock reset,
# lower-body-lag reset, post-replay re-apply) and by SkaterController to seed
# the upper-body angular-velocity tracker — kept public so those callsites
# stay terse.

const State = SkaterStateMachine.State

# ── Runtime State ─────────────────────────────────────────────────────────────
var facing: Vector2 = Vector2.DOWN
var upper_body_angle: float = 0.0
# Reach lean, split by axis: pitch (rotation.x) + roll (rotation.z). The lean
# points TOWARD the blade's reach direction, not just forward — see
# compute_upper_body_lean_target. Because the blade IK solves in the leaned
# upper-body frame, leaning toward the target genuinely extends world reach
# (the shoulder displaces toward it and the hands drop closer to the ice,
# lengthening the stick's horizontal footprint) — the same mechanism a real
# player uses.
var upper_body_lean: float = 0.0
var upper_body_lean_roll: float = 0.0
var velocity_lean_x: float = 0.0
var velocity_lean_z: float = 0.0
var lower_body_lag: float = 0.0
var head_angle: float = 0.0
var ik_locked_side: int = 0  # +1 = exited right, -1 = exited left, 0 = unlocked
# Upper-body twist follow-through (secondary motion): a damped spring trails the
# tracked twist so the shoulders whip through a fast cut and settle, instead of
# tracking rigidly. Converges to the tracked angle at steady state (adds nothing
# to a settled pose), so the cosmetic-rig dirty-gate still skips it. Advanced
# only on the local-sim path (apply_upper_body) like the rest of that pass.
var _twist_follow: float = 0.0
var _twist_follow_vel: float = 0.0

# ── Angular-Velocity Tracking ─────────────────────────────────────────────────
var facing_angular_velocity: float = 0.0
var upper_body_angular_velocity: float = 0.0
var _prev_facing_angle: float = 0.0
var _prev_upper_body_angle: float = 0.0

# ── References ────────────────────────────────────────────────────────────────
var _skater: Skater = null
var _sm: SkaterStateMachine = null
var _aiming: SkaterAimingBehavior = null
var _controller: SkaterController = null  # tunables live as @export on the controller
# Read-only source of the per-stride trunk texture (dig pitch / weight-shift
# sway). The gait computes those values but never writes torso rotations —
# this coordinator stays the single writer of the upper/lower-body lean.
var _skating: SkaterSkatingCoordinator = null

func setup(skater: Skater, sm: SkaterStateMachine, aiming: SkaterAimingBehavior,
		controller: SkaterController, skating: SkaterSkatingCoordinator) -> void:
	_skater = skater
	_sm = sm
	_aiming = aiming
	_controller = controller
	_skating = skating
	_prev_facing_angle = atan2(facing.x, facing.y)
	_prev_upper_body_angle = upper_body_angle

# ── Per-Tick Application ──────────────────────────────────────────────────────
func apply_velocity_lean(delta: float) -> void:
	var target: Vector2 = compute_velocity_lean_target(
			_skater.velocity, _skater.global_transform.basis, _controller.max_speed,
			_controller.velocity_lean_forward_max_deg,
			_controller.velocity_lean_back_max_deg,
			_controller.velocity_lean_lateral_max_deg)
	velocity_lean_x = lerpf(velocity_lean_x, target.x, _controller.velocity_lean_speed * delta)
	velocity_lean_z = lerpf(velocity_lean_z, target.y, _controller.velocity_lean_speed * delta)


# Pure helpers — derive lean targets from state. Used both by the live pose
# pipeline (apply_velocity_lean / apply_upper_body lerp toward these targets)
# and by snap_lean_to_state below (remote / replay path snaps directly). Means
# lean isn't transmitted over the wire — receivers re-derive it from the
# velocity and hand position they already have.
#
# The lean is INTO travel: forward skating folds the trunk forward (the
# skating posture — negative rotation.x pitches the torso top toward local
# −Z), backward skating sits slightly back, and lateral travel banks into the
# carve (negative rotation.z rolls the torso top toward local +X, the
# skater's right). Returned as Vector2(x = pitch, y = roll), radians.
static func compute_velocity_lean_target(
		world_velocity: Vector3, body_basis: Basis, max_speed: float,
		fwd_lean_max_deg: float, back_lean_max_deg: float,
		lateral_lean_max_deg: float) -> Vector2:
	if max_speed <= 0.0:
		return Vector2.ZERO
	var local_vel: Vector3 = body_basis.inverse() * world_velocity
	# −Z is the body's forward axis, so negate for a "how forward" fraction.
	var fwd_t: float = clampf(-local_vel.z / max_speed, -1.0, 1.0)
	var pitch_max_deg: float = fwd_lean_max_deg if fwd_t >= 0.0 else back_lean_max_deg
	var target_x: float = -fwd_t * deg_to_rad(pitch_max_deg)
	var lat_t: float = clampf(local_vel.x / max_speed, -1.0, 1.0)
	var target_z: float = -lat_t * deg_to_rad(lateral_lean_max_deg)
	return Vector2(target_x, target_z)


# Directional reach lean: the torso tips TOWARD the hand's reach direction
# (pitch AND roll), the way a real player leans into a poke or a wide dangle,
# instead of the old forward-only fold that wasted the lean on side reaches.
# Magnitude ramps with reach fraction through engage_power (>1 keeps the
# torso quiet mid-ROM and commits the lean near the rim, where a real player
# actually leans). Returns Vector2(pitch = rotation.x, roll = rotation.z):
# negative rotation.x pitches the torso top toward local −Z (forward),
# negative rotation.z rolls it toward local +X — hence (dir.y, −dir.x).
static func compute_upper_body_lean_target(
		hand_local_xz: Vector2, shoulder_local_xz: Vector2,
		rom_max_reach: float, lean_max_deg: float, engage_power: float = 1.0) -> Vector2:
	var hand_vec: Vector2 = hand_local_xz - shoulder_local_xz
	var hand_reach: float = hand_vec.length()
	if hand_reach <= 0.01 or rom_max_reach <= 0.0:
		return Vector2.ZERO
	var reach_factor: float = clampf(hand_reach / rom_max_reach, 0.0, 1.0)
	var mag: float = deg_to_rad(lean_max_deg) * pow(reach_factor, maxf(engage_power, 0.01))
	var dir: Vector2 = hand_vec / hand_reach
	return Vector2(mag * dir.y, -mag * dir.x)


# Snap lean to the targets implied by current velocity + hand position. Used
# by remote / replay state application — lean isn't in the network state, so
# receivers re-derive it the same way the host computed it. Must be called
# AFTER set_top_hand_position and BEFORE set_blade_position so the blade
# marker lands at the correct world Y under the leaning upper body.
func snap_lean_to_state() -> void:
	var v_target: Vector2 = compute_velocity_lean_target(
			_skater.velocity, _skater.global_transform.basis, _controller.max_speed,
			_controller.velocity_lean_forward_max_deg,
			_controller.velocity_lean_back_max_deg,
			_controller.velocity_lean_lateral_max_deg)
	velocity_lean_x = v_target.x
	velocity_lean_z = v_target.y
	if _skater.current_shot_state == State.SHOT_BLOCKING:
		# Mirror the local block branch in apply_upper_body: the chest folds
		# over the knees instead of deriving a reach lean from the block's
		# low hand pose. Snapped, like everything else on this path — the
		# block pose itself snaps on entry.
		upper_body_lean = -deg_to_rad(_controller.block_trunk_pitch_deg)
		upper_body_lean_roll = 0.0
	else:
		var reach_target: Vector2 = compute_upper_body_lean_target(
				Vector2(_skater.top_hand.position.x, _skater.top_hand.position.z),
				Vector2(_skater.shoulder.position.x, _skater.shoulder.position.z),
				_controller.rom_backhand_reach_max, _controller.upper_body_lean_max_deg,
				_controller.upper_body_lean_engage_power)
		upper_body_lean = reach_target.x
		upper_body_lean_roll = reach_target.y
	_apply_lean()


# Single writer for the torso/leg lean rotations. Layers, in order: the reach
# lean (directional tip toward the blade — pitch + roll), the velocity lean
# (skating posture pitch + carve bank), and the per-stride trunk texture the
# gait computes (effort dig pitch + weight-shift sway roll — see
# SkaterSkatingCoordinator). The lower body banks fully with the carve but
# follows the forward pitch only fractionally, so the legs stay planted under
# the hips while the trunk folds forward over them.
func _apply_lean() -> void:
	# Body-check recoil: while staggered, the torso reels the way the hit shoved
	# it, easing out as the timer decays (same directional pitch/roll decomposition
	# as the reach lean). Runs on every path — local, bot, and remote (which reels
	# generically backward off the replicated timer) — since _apply_lean is the
	# single torso writer both the live pass and snap_lean_to_state go through.
	var recoil_pitch: float = 0.0
	var recoil_roll: float = 0.0
	var recoil_t: float = clampf(
			_controller.stagger_timer / maxf(_controller.stagger_max_seconds, 0.001), 0.0, 1.0)
	# Knockdown reels the torso far harder than a stagger — the fold that sells being
	# floored. It rides the SAME recoil direction (fall the way you were hit) and the
	# same deterministic/replicated timer, layered on top of the stagger recoil. kd_t
	# holds full while more than knockdown_getup_seconds remains, then eases to 0 (the
	# get-up). Remotes reel generically backward (default recoil dir), like stagger.
	var kd_t: float = clampf(
			_controller.knockdown_timer / maxf(_controller.knockdown_getup_seconds, 0.001), 0.0, 1.0)
	var mag: float = deg_to_rad(_controller.stagger_recoil_deg) * recoil_t \
			+ deg_to_rad(_controller.knockdown_fold_deg) * kd_t
	if mag > 0.0:
		var d: Vector2 = _controller.stagger_recoil_dir
		recoil_pitch = mag * d.y
		recoil_roll = -mag * d.x
	# The gait's per-stride trunk texture is deliberately NOT folded in here: the
	# blade markers hang under upper_body, so anything added to its rotation moves
	# the blade's WORLD position (pickup / poke geometry, which must match across
	# machines for reconcile). The gait runs at render rate now, so letting its
	# stride pitch reach this frame would make the blade world depend on frame
	# rate. Reach + velocity lean stay (both physics-rate, deterministic); the
	# stride texture is a render-only leg concern. See Skater.render_pose_update.
	_skater.set_upper_body_lean(
			upper_body_lean + velocity_lean_x + recoil_pitch,
			upper_body_lean_roll + velocity_lean_z + recoil_roll)
	_skater.set_lower_body_lean(
			velocity_lean_x * _controller.lower_body_pitch_follow, velocity_lean_z)

func apply_facing(input: InputState, delta: float) -> void:
	var s: SkaterStateMachine.State = _sm.get_state()
	if not (s == State.WRISTER_AIM or s == State.SLAPPER_CHARGE_WITH_PUCK
			or s == State.SLAPPER_CHARGE_WITHOUT_PUCK or s == State.SHOT_BLOCKING):
		var prev_angle: float = _skater.rotation.y
		var mouse_world: Vector3 = input.mouse_world_pos
		var to_mouse: Vector2 = Vector2(
			mouse_world.x - _skater.global_position.x,
			mouse_world.z - _skater.global_position.z
		)
		if to_mouse.length() > _controller.move_deadzone:
			# Gate: while the mouse is in the unreachable wedge behind the skater
			# (beyond rom_backhand_angle_max_deg + upper_body_max_twist_deg from
			# forward), freeze facing so the body doesn't chase a target it can't
			# reach. Resume tracking as soon as the mouse returns to the reachable
			# cone, regardless of side. Snap-prevention on wraps lives in the
			# blade speed cap (SkaterIKCoordinator), not in this lock — earlier
			# versions tied unlock to "same side it left from", which could
			# permanently strand facing when the mouse wrapped around.
			var mouse_body_angle: float = facing.angle_to(to_mouse.normalized())
			var ik_gate: float = deg_to_rad(_controller.rom_backhand_angle_max_deg + _controller.upper_body_max_twist_deg)
			if abs(mouse_body_angle) >= ik_gate:
				ik_locked_side = int(sign(mouse_body_angle))
			else:
				ik_locked_side = 0
				var drag: float = _controller.facing_drag_speed_braking if input.brake else _controller.facing_drag_speed
				# Re-square hard through the follow-through: the coil left facing stale
				# at the wind-up cursor, and a lazy drag can't catch up in ~0.22 s, so
				# the blade handoff snaps to the wrong side (ROM-clamped to the stale
				# facing) before reaching the cursor. See follow_through_facing_recover_speed.
				if s == State.FOLLOW_THROUGH:
					drag = maxf(drag, _controller.follow_through_facing_recover_speed)
				# Sprinting widens the turn: commit to straight-line speed at the
				# cost of agility. sprint_active is resolved in _apply_movement
				# earlier this tick, so it's deterministic across reconcile replay.
				if _controller.sprint_active:
					drag *= _controller.sprint_turn_multiplier
				# Committing a check widens the turn the same way sprint does — the
				# agility cost of loading up a hit. Stacks with sprint (both held =
				# very committed straight line). Deterministic across replay.
				if _controller.hit_active:
					drag *= _controller.hit_turn_multiplier
				facing = facing.lerp(to_mouse.normalized(), drag * delta).normalized()
		_skater.set_facing(facing)
		var turn_delta: float = angle_difference(prev_angle, _skater.rotation.y)
		lower_body_lag = clampf(
			lower_body_lag - turn_delta,
			-deg_to_rad(_controller.lower_body_lag_max_deg),
			deg_to_rad(_controller.lower_body_lag_max_deg))

	# Always decay and apply — even during locked states. The hockey-stop yaw
	# (legs turned across travel while the torso keeps facing the play) and
	# the hip-to-travel alignment (legs stride along the motion while the
	# torso faces the cursor) ride the same lower-body channel: the gait
	# computes both, this coordinator stays the single writer of the rotation.
	lower_body_lag = lerpf(lower_body_lag, 0.0, _controller.lower_body_lag_speed * delta)
	var gait_yaw: float = 0.0
	if _skating != null:
		gait_yaw = _skating.stop_yaw_offset + _skating.travel_align_yaw \
				+ _skating.shot_hip_yaw
	_skater.set_lower_body_lag(lower_body_lag + gait_yaw)

func apply_upper_body(delta: float) -> void:
	if _sm.get_state() == State.SHOT_BLOCKING:
		# Chest folds over the knees — the braced-wall read, over the gait's
		# deep sit and wide leg V. Entry zeroed the lean so this eases in from
		# square; roll stays zero and the yaw stays locked at the snapped
		# facing (the block faces the shooter dead-on). The block blade pose
		# solves its ice height through blade_y_lean_corrected, so the stick
		# stays flat on the ice under the pitching torso.
		var block_ease: float = minf(_controller.block_pose_blend_speed * delta, 1.0)
		upper_body_lean = lerpf(upper_body_lean,
				-deg_to_rad(_controller.block_trunk_pitch_deg), block_ease)
		upper_body_lean_roll = lerpf(upper_body_lean_roll, 0.0, block_ease)
		_apply_lean()
		return

	var charge_state: SkaterStateMachine.State = _sm.get_state()
	if charge_state == State.SLAPPER_CHARGE_WITH_PUCK or charge_state == State.SLAPPER_CHARGE_WITHOUT_PUCK:
		# Hold upper body facing the locked shot direction throughout the wind-up,
		# then layer the coil rotation on top: back shoulder pulls away from the
		# target as the wind-up timer fills, ending in a loaded stance with the
		# non-stick shoulder pointing at the puck. Re-computed from world space
		# each frame so the torso stays on target even if the feet pivot.
		if _sm.locked_slapper_dir.length_squared() > 0.0001:
			var locked_world := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
			var local_dir := _skater.global_transform.basis.inverse() * locked_world
			var locked_angle := atan2(local_dir.x, -local_dir.z)
			var max_twist := deg_to_rad(_controller.upper_body_max_twist_deg)
			var aim_target: float = clampf(-locked_angle * _controller.upper_body_twist_ratio, -max_twist, max_twist)
			var wind_up_eased: float = sqrt(_controller.slapper_wind_up_t())
			var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
			var coil: float = -blade_side_sign * deg_to_rad(_controller.slapper_wind_up_twist_deg) * wind_up_eased
			upper_body_angle = lerp_angle(upper_body_angle, aim_target + coil, _controller.slapper_wind_up_lerp_speed * delta)
			_skater.set_upper_body_rotation(upper_body_angle)
		return

	if charge_state == State.FOLLOW_THROUGH:
		# Rotate the shoulders THROUGH the shot: the torso squares to the shot
		# line and uncoils past it (opposite sign to the wind-up coil — the back
		# shoulder comes through), riding the same asymmetric arc as the blade so
		# the body snaps through the release and settles out of the finish. The
		# trunk also drives forward over the front foot. Both targets decay to
		# the neutral aim pose by the end of the timer, handing the generic
		# blade-tracking branch a torso it can pick up without a pop. Whiffed
		# wristers (no shot_dir) fall through to blade tracking.
		var dir_world: Vector3 = _sm.shot_dir
		if dir_world.length_squared() <= 0.0001 and _sm.follow_through_is_slapper:
			dir_world = Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
		if dir_world.length_squared() > 0.0001:
			var total: float = maxf(_sm.follow_through_duration_total, 0.001)
			var t: float = clampf(1.0 - _sm.follow_through_timer / total, 0.0, 1.0)
			var env: float = sin(PI * pow(t, _controller.follow_through_arc_skew)) \
					* _sm.follow_through_power
			# Ease the finish aim from the shot line back to the live cursor over
			# the tail (follow_through_return_frac), so the shoulders end squared
			# to where the mouse now is and the generic tracker picks the torso up
			# without a re-rotate. Meat of the timer keeps the shot-line uncoil.
			var cursor_dir: Vector3 = _controller._current_aim_world - _skater.global_position
			var aim_world: Vector3 = ShotMechanics.follow_through_aim(
					dir_world, cursor_dir, t, _controller.follow_through_return_frac)
			if aim_world.length_squared() > 0.0001:
				dir_world = aim_world
			var shot_local: Vector3 = _skater.global_transform.basis.inverse() * dir_world
			var shot_angle: float = atan2(shot_local.x, -shot_local.z)
			var ft_max_twist: float = deg_to_rad(_controller.upper_body_max_twist_deg)
			var ft_aim: float = clampf(
					-shot_angle * _controller.upper_body_twist_ratio, -ft_max_twist, ft_max_twist)
			var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
			var through_deg: float = _controller.slapper_follow_through_twist_deg \
					if _sm.follow_through_is_slapper else _controller.wrister_follow_through_twist_deg
			var through: float = blade_side_sign * deg_to_rad(through_deg) * env
			if _controller.wrister_freeze_blade and not _sm.follow_through_is_slapper:
				# The coil IS the windup — discharge the through-overshoot INSTANTLY
				# with the release. env is front-loaded (peaks ~40 ms), but a lerp at
				# follow_through_twist_lerp_speed needs ~150 ms to converge, so it can
				# never catch the fast bell — the snap gets muted into a slow rotation
				# that trails the blade and reads as "release → pause → follow-through."
				# Drive the angle straight off env instead: ft_aim ≈ the coil angle
				# (same -angle·ratio formula), so this is continuous at the boundary.
				upper_body_angle = ft_aim + through
			else:
				upper_body_angle = lerp_angle(upper_body_angle, ft_aim + through,
						_controller.follow_through_twist_lerp_speed * delta)
			_skater.set_upper_body_rotation(upper_body_angle)
			# Keep the twist-follow spring glued to the tracked angle through the
			# FT (it isn't advanced on this branch): the handoff preserves the
			# pose instead of zeroing it (see SkaterController._transition_to_skating),
			# so the first skating tick must find the spring already settled or it
			# whips off the stale pre-shot value.
			_twist_follow = upper_body_angle
			_twist_follow_vel = 0.0
			# Trunk drives TOWARD the shot line (pitch + roll, same directional
			# decomposition as the reach lean) — a cross-body finish tips the
			# shoulders over the front foot toward the target, not just forward.
			var lean_dir3: Vector3 = _skater.upper_body.global_transform.basis.inverse() * dir_world
			var lean_dir := Vector2(lean_dir3.x, lean_dir3.z)
			var ft_lean_target := Vector2.ZERO
			if lean_dir.length_squared() > 0.0001:
				lean_dir = lean_dir.normalized()
				var ft_lean_mag: float = deg_to_rad(_controller.follow_through_lean_deg) * env
				ft_lean_target = Vector2(ft_lean_mag * lean_dir.y, -ft_lean_mag * lean_dir.x)
			upper_body_lean = lerpf(upper_body_lean, ft_lean_target.x,
					_controller.follow_through_twist_lerp_speed * delta)
			upper_body_lean_roll = lerpf(upper_body_lean_roll, ft_lean_target.y,
					_controller.follow_through_twist_lerp_speed * delta)
			_apply_lean()
			return

	var target_angle: float = 0.0
	var target_lean: Vector2 = Vector2.ZERO
	var hand_vec := Vector2(
		_skater.top_hand.position.x - _skater.shoulder.position.x,
		_skater.top_hand.position.z - _skater.shoulder.position.z)
	var hand_reach: float = hand_vec.length()

	if hand_reach > 0.01:
		# Drive twist from the blade's world direction in the skater body frame.
		# Using skater-local (not upper-body-local) gives a stable target that
		# doesn't shrink as the body rotates — the old hand-angle approach had a
		# dampening feedback loop that capped steady-state rotation at ~43% of the
		# world angle. Now the body tracks 1:1 up to upper_body_max_twist_deg.
		# FREEZE: the coil normally faces the blade (which tracks the cursor), but a
		# FROZEN blade can't lead the wind-up — so face the CURSOR directly, keeping
		# the shoulders rotating toward the aim while the puck sits still.
		var twist_source: Vector3 = _skater.upper_body_to_global(_skater.get_blade_position())
		if _sm.get_state() == State.WRISTER_AIM and _controller.wrister_freeze_blade:
			twist_source = _controller._current_aim_world
		var to_blade: Vector3 = twist_source - _skater.global_position
		to_blade.y = 0.0
		if to_blade.length() > 0.01:
			var local_dir: Vector3 = _skater.global_transform.basis.inverse() * to_blade.normalized()
			var blade_angle: float = atan2(local_dir.x, -local_dir.z)
			var max_twist: float = deg_to_rad(_controller.upper_body_max_twist_deg)
			target_angle = clampf(-blade_angle * _controller.upper_body_twist_ratio, -max_twist, max_twist)
		target_lean = compute_upper_body_lean_target(
				Vector2(_skater.top_hand.position.x, _skater.top_hand.position.z),
				Vector2(_skater.shoulder.position.x, _skater.shoulder.position.z),
				_controller.rom_backhand_reach_max,
				_controller.upper_body_lean_max_deg,
				_controller.upper_body_lean_engage_power)

	upper_body_angle = lerp_angle(upper_body_angle, target_angle, _controller.upper_body_return_speed * delta)
	upper_body_lean = lerpf(upper_body_lean, target_lean.x, _controller.upper_body_lean_return_speed * delta)
	upper_body_lean_roll = lerpf(upper_body_lean_roll, target_lean.y, _controller.upper_body_lean_return_speed * delta)
	# Follow-through: a damped spring trails the tracked twist so the shoulders
	# whip through a fast cut and settle. We RENDER the tracked angle plus the
	# spring's lag (whip in the direction of motion), but keep upper_body_angle
	# itself the rigidly-tracked value so the network angular-velocity export and
	# next-frame lerp are unaffected. Converges to zero lag at steady state.
	var tw_accel: float = _controller.upper_body_follow_stiffness * (upper_body_angle - _twist_follow) \
			- _controller.upper_body_follow_damping * _twist_follow_vel
	_twist_follow_vel += tw_accel * delta
	_twist_follow += _twist_follow_vel * delta
	var rendered_twist: float = upper_body_angle \
			+ (upper_body_angle - _twist_follow) * _controller.upper_body_follow_gain
	_skater.set_upper_body_rotation(rendered_twist)
	_apply_lean()

func apply_head_tracking(input: InputState, delta: float) -> void:
	apply_head_tracking_aim(input.mouse_world_pos, delta)

# Head tracking from a raw aim point rather than an InputState — used by the
# render-rate cosmetic pass (Skater.render_pose_update), which has no input
# frame, off the controller's last-seen aim world position.
func apply_head_tracking_aim(aim_world: Vector3, delta: float) -> void:
	var mouse_local: Vector3 = _skater.upper_body_to_local(aim_world)
	mouse_local.y = 0.0
	var target_angle: float = 0.0
	if mouse_local.length() > 0.01:
		target_angle = clampf(
			atan2(mouse_local.x, -mouse_local.z),
			-deg_to_rad(_controller.head_track_max_deg),
			deg_to_rad(_controller.head_track_max_deg))
	head_angle = lerpf(head_angle, target_angle, _controller.head_track_speed * delta)
	_skater.set_head_angle(head_angle)

# ── Angular Velocity Bookkeeping ──────────────────────────────────────────────
# Called at the end of _process_input on real (non-replay) frames so the
# network state carries C1-continuous facing / upper-body rotation.
func update_angular_velocities(delta: float) -> void:
	if delta <= 0.0:
		return
	var cur_fa: float = atan2(facing.x, facing.y)
	facing_angular_velocity = angle_difference(_prev_facing_angle, cur_fa) / delta
	upper_body_angular_velocity = angle_difference(_prev_upper_body_angle, upper_body_angle) / delta
	_prev_facing_angle = cur_fa
	_prev_upper_body_angle = upper_body_angle

# ── Pose Resets ───────────────────────────────────────────────────────────────
# Used by SkaterController._transition_to_skating and _enter_slapper_charge.
# Clears smoothed pose state so the next tick starts from a neutral torso/lean.
func reset_lean_and_lag() -> void:
	upper_body_angle = 0.0
	upper_body_lean = 0.0
	upper_body_lean_roll = 0.0
	velocity_lean_x = 0.0
	velocity_lean_z = 0.0
	lower_body_lag = 0.0
	_twist_follow = 0.0
	_twist_follow_vel = 0.0
