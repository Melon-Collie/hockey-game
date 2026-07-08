class_name SkaterShotPoseCoordinator
extends RefCounted

# Owns the blade and top-hand pose during shot states: the slapper wind-up
# (charge with or without puck) and the post-release follow-through for both
# wrister and slapper. The aim/IK flow in SkaterIKCoordinator is bypassed for
# these states because the blade pose is choreographed, not player-aimed.
#
# All clamp helpers (net exclusion, goalie body / butterfly) and the small
# geometry utilities (blade_y_local, stick_horiz) live on SkaterIKCoordinator
# because they are also used by the per-tick IK pipeline.

const State = SkaterStateMachine.State

# ── References ────────────────────────────────────────────────────────────────
var _skater: Skater = null
var _sm: SkaterStateMachine = null
var _aiming: SkaterAimingBehavior = null
var _ik: SkaterIKCoordinator = null
var _controller: SkaterController = null

func setup(skater: Skater, sm: SkaterStateMachine, aiming: SkaterAimingBehavior,
		ik: SkaterIKCoordinator, controller: SkaterController) -> void:
	_skater = skater
	_sm = sm
	_aiming = aiming
	_ik = ik
	_controller = controller


# ── Follow-Through Start Capture ──────────────────────────────────────────────
# The wrister/quick-shot pose at the release instant is wherever the aim left
# it — hands dragged back, blade wound up. The authored follow-through curve
# starts from the REST pose, so without a bridge the stick teleported to a
# near-rest pose on the first FT frame (which looks like the follow-through's
# END, since the envelopes finish at rest) and then played the arc — "the
# animation runs twice". Capture the live pose at release; the FT blends from
# it onto the authored swing over the first follow_through_takeover_frac of
# the timer, so release reads as ONE continuous motion. Live ticks only:
# reconcile replay re-runs releases against replayed poses and must not
# clobber the visual capture. (The slapper doesn't need this — its downswing
# already starts from the captured wind-up pose.)
var _ft_start_hand: Vector3 = Vector3.ZERO
var _ft_start_blade: Vector3 = Vector3.ZERO
var _ft_start_valid: bool = false


func begin_follow_through() -> void:
	if _controller.is_replaying:
		return
	_ft_start_hand = _skater.get_top_hand_position()
	_ft_start_blade = _skater.get_blade_position()
	_ft_start_valid = true

# ── Slapper Charge Pose ───────────────────────────────────────────────────────
# Slapper has a fixed blade pose offset from the shoulder — separate from
# the IK flow (this is a charged pre-shot pose, not player-aimed). Hand
# sits at the shoulder XZ at `hand_rest_y`; blade XZ is offset from the
# shoulder by slapper_blade_x/z; Y lerps from _ik.blade_y_local() (ice) up to
# slapper_wind_up_height during the wind-up charge.
func apply_slapper_blade_position() -> void:
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	var wind_up_t: float = clampf(_aiming.slapper_charge_timer / _controller.slapper_wind_up_time, 0.0, 1.0)
	# Front-loaded ease so the coil snaps into place and the back half of the
	# wind-up is a held loaded pose — matches the torso coil in SkaterPoseCoordinator.
	var wind_up_eased: float = sqrt(wind_up_t)
	# Lerp blade XZ from the "ready" position out to the side to the "loaded"
	# position pulled in and back, so the stick wraps over the back shoulder
	# once the torso coil completes.
	var blade_x_offset: float = lerpf(_controller.slapper_blade_x, _controller.slapper_wind_up_blade_x, wind_up_eased)
	var blade_z_offset: float = lerpf(_controller.slapper_blade_z, _controller.slapper_wind_up_blade_z, wind_up_eased)
	var blade_x: float = _skater.shoulder.position.x + blade_side_sign * blade_x_offset
	var blade_z: float = _skater.shoulder.position.z + blade_z_offset
	var current_blade_y: float = lerpf(
			_ik.blade_y_lean_corrected(blade_x, blade_z),
			_controller.slapper_wind_up_height,
			wind_up_t)
	var pos := Vector3(blade_x, current_blade_y, blade_z)
	pos = _skater.clamp_blade_to_walls(pos)
	var blade_world: Vector3 = _skater.upper_body_to_global(pos)
	var clamped_heel: Vector3 = blade_world
	if _controller.has_puck:
		clamped_heel = _ik.clamp_blade_from_goalies(clamped_heel)
	# Lift the top hand and push it forward in upper-body-local space. The
	# forward push (negative local Z) rides the torso coil — for an LHS player
	# the body rotates CCW so local -Z maps to world upper-left in top-down
	# view, putting the hand out in front of the rotated body instead of glued
	# to the back-shoulder marker. hand_back/hand_inward stay opt-in (default 0)
	# since they fight the coil direction.
	var hand_pos := Vector3(
			_skater.shoulder.position.x - blade_side_sign * _controller.slapper_wind_up_hand_inward * wind_up_eased,
			_controller.hand_rest_y + _controller.slapper_wind_up_hand_up * wind_up_eased,
			_skater.shoulder.position.z + _controller.slapper_wind_up_hand_back * wind_up_eased - _controller.slapper_wind_up_hand_forward * wind_up_eased)
	var hand_world: Vector3 = _skater.upper_body_to_global(hand_pos)
	var shaft: Vector3 = clamped_heel - hand_world
	shaft.y = 0.0
	var contact_world: Vector3 = clamped_heel
	if shaft.length() > 0.001:
		contact_world = clamped_heel + shaft.normalized() * _skater.blade_length * 0.5
	var clamped_contact: Vector3 = _ik.clamp_blade_from_net(contact_world)
	if clamped_contact != contact_world:
		var delta: Vector3 = clamped_contact - contact_world
		clamped_heel += delta
		if _controller.has_puck:
			_controller._do_release(delta.normalized(), _controller.goalie_strip_power)
	if clamped_heel != blade_world:
		pos = _skater.upper_body_to_local(clamped_heel)
	_skater.set_top_hand_position(hand_pos)
	_skater.set_blade_position(pos)

# ── Shot-Block Pose ───────────────────────────────────────────────────────────
# Choreographed "stick down" block: the blade lies flat on the ice extended
# forward (toward the shooter the stance snapped to on entry) and slightly to
# the stick side, with the top hand dropped low and pushed forward so the shaft
# lies across the lane. Authored in upper-body-local space like the slapper
# pose; the torso stays yaw-locked at the snapped facing for the duration
# (SkaterPoseCoordinator's block branch only pitches the chest over the knees
# — blade_y_lean_corrected re-lands the blade on the ice under that pitch), so
# the pose holds steady relative to the snapped facing.
func apply_block_blade_position() -> void:
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	var blade_x: float = _skater.shoulder.position.x + blade_side_sign * _controller.block_blade_x
	var blade_z: float = _skater.shoulder.position.z - _controller.block_blade_reach
	var blade_y: float = _ik.blade_y_lean_corrected(blade_x, blade_z)
	var blade_local := Vector3(blade_x, blade_y, blade_z)
	blade_local = _skater.clamp_blade_to_walls(blade_local)
	var hand_pos := Vector3(
			_skater.shoulder.position.x + blade_side_sign * _controller.block_hand_x,
			_controller.block_hand_y,
			_skater.shoulder.position.z - _controller.block_hand_forward)
	_skater.set_top_hand_position(hand_pos)
	_skater.set_blade_position(blade_local)

# ── Goal Celebration Pose ─────────────────────────────────────────────────────
# Cosmetic raised-stick celebration for the scorer: top hand punches up with
# the stick held overhead (blade above the hand, tilted so the shaft never
# goes dead vertical — the stick/blade look_at needs a horizontal component),
# off hand pumps up on the free side. t runs [0,1] across the celebration
# window; a fast smoothstep ramp raises the arms, then the pose holds with a
# gentle bob (no ease-out — the faceoff teleport's pose reset ends it).
# Applied AFTER the tick's normal hand/blade placement, so it simply wins;
# runs only on the scorer's own machine and rides the hand/blade wire state
# to everyone else like every other pose.
func apply_celebration_pose(t: float) -> void:
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	var ramp: float = clampf(t / 0.2, 0.0, 1.0)
	ramp = ramp * ramp * (3.0 - 2.0 * ramp)
	var bob: float = sin(t * TAU * 1.5) * 0.03 * ramp
	var hand_pos := Vector3(
			_skater.shoulder.position.x,
			lerpf(_controller.hand_rest_y, _controller.celebration_hand_y, ramp) + bob,
			_skater.shoulder.position.z - 0.10)
	var blade_pos := Vector3(
			_skater.shoulder.position.x + blade_side_sign * 0.18,
			hand_pos.y + _controller.celebration_stick_rise * ramp,
			_skater.shoulder.position.z - 0.28)
	blade_pos = _skater.clamp_blade_to_walls(blade_pos)
	_skater.set_top_hand_position(hand_pos)
	_skater.set_blade_position(blade_pos)
	# Off hand: fist pump on the free side (normally it rides the shaft —
	# this override runs after update_bottom_hand, so it wins the tick).
	_skater.set_bottom_hand_position(Vector3(
			_skater.bottom_shoulder.position.x,
			lerpf(0.0, _controller.celebration_hand_y, ramp) + bob * 1.4,
			_skater.bottom_shoulder.position.z - 0.12))


# ── Wrister Follow-Through ────────────────────────────────────────────────────
# The release swing continued: the blade sweeps from wherever the release left
# it onto the shot line while the stick carries FORWARD along that line and
# climbs to a high finish pointed at the target, then settles back to the ice
# by the end of the timer (a clean handoff to the aim IK). The forward carry
# (wrister_follow_through_reach) is what makes the finish read as the player
# reaching THROUGH the shot rather than the blade bobbing up and down over the
# release spot — a genuine continuation, not a canned pump. Reach and heights
# ride the shared asymmetric arc — fast rise through the release, slow settle —
# scaled by follow_through_power so a full-charge wrister finishes extended and
# high while a snap pass barely flicks. The blade stays a rigid stick_length
# from the top hand (the horizontal reach re-solves as the blade climbs), so
# the finish reads as the stick swinging up about the hands rather than the
# shaft stretching.
func apply_wrister_follow_through() -> void:
	var total: float = maxf(_sm.follow_through_duration_total, 0.001)
	var t: float = clampf(1.0 - _sm.follow_through_timer / total, 0.0, 1.0)
	var env: float = sin(PI * pow(t, _controller.follow_through_arc_skew)) \
			* _sm.follow_through_power
	# Blade direction: ease from the release angle onto the shot line (fast
	# ease-out, so the sweep-through happens in the front half of the timer).
	# shot_dir is world-space; re-derive its body-local angle each frame so the
	# finish stays pointed at the target while the torso uncoils underneath.
	# Whiffed releases (shot_dir zero) hold the release angle.
	var dir_angle: float = _controller._blade_relative_angle
	var shot_local: Vector3 = _skater.upper_body.global_transform.basis.inverse() * _sm.shot_dir
	shot_local.y = 0.0
	if shot_local.length_squared() > 0.0001:
		var sweep: float = 1.0 - (1.0 - t) * (1.0 - t)
		dir_angle = lerp_angle(dir_angle, atan2(shot_local.x, -shot_local.z), sweep)
	var local_dir := Vector3(sin(dir_angle), 0.0, -cos(dir_angle))
	var hand_pos := _skater.shoulder.position
	# Carry the whole stick FORWARD along the shot line as it climbs — the
	# hands reach through the shot instead of the blade bobbing in place. Both
	# endpoints translate by the same offset so the rigid stick_length solve
	# below is untouched; env scales it so a snap pass barely reaches while a
	# full-charge wrister finishes extended out over the shot line.
	var carry: float = env * _controller.wrister_follow_through_reach
	hand_pos.x += local_dir.x * carry
	hand_pos.z += local_dir.z * carry
	hand_pos.y = _controller.hand_rest_y + env * _controller.wrister_follow_through_hand_y
	# Sample the ice height at the rest reach, lift the blade off it, then
	# re-solve the horizontal reach so hand→blade stays one stick long.
	var probe: Vector3 = hand_pos + local_dir * _ik.stick_horiz()
	var blade_y: float = _ik.blade_y_lean_corrected(probe.x, probe.z) \
			+ env * _controller.wrister_follow_through_blade_lift
	var drop: float = hand_pos.y - blade_y
	var horiz: float = sqrt(maxf(
			_controller.stick_length * _controller.stick_length - drop * drop, 0.0001))
	var intended_target: Vector3 = hand_pos + local_dir * horiz
	intended_target.y = blade_y
	# Bridge from the captured release pose onto the authored swing (see
	# begin_follow_through) — smoothstepped over the takeover window so the
	# wound-up stick flows into the sweep instead of teleporting to rest.
	# Blended BEFORE the wall/net clamps so the clamps see the final pose.
	if _ft_start_valid:
		var takeover: float = clampf(
				t / maxf(_controller.follow_through_takeover_frac, 0.001), 0.0, 1.0)
		takeover = takeover * takeover * (3.0 - 2.0 * takeover)
		if takeover < 1.0:
			hand_pos = _ft_start_hand.lerp(hand_pos, takeover)
			intended_target = _ft_start_blade.lerp(intended_target, takeover)
	var local_target: Vector3 = _skater.clamp_blade_to_walls(intended_target)
	var clamp_delta_xz := Vector3(
		local_target.x - intended_target.x, 0.0, local_target.z - intended_target.z)
	if clamp_delta_xz.length_squared() > 0.0:
		hand_pos.x += clamp_delta_xz.x
		hand_pos.z += clamp_delta_xz.z
	var net_world: Vector3 = _ik.clamp_blade_from_net(_skater.upper_body_to_global(local_target))
	var net_local: Vector3 = _skater.upper_body_to_local(net_world)
	hand_pos.x += net_local.x - local_target.x
	hand_pos.z += net_local.z - local_target.z
	local_target = net_local
	_skater.set_top_hand_position(hand_pos)
	_skater.set_blade_position(local_target)

# ── Slapper Follow-Through ────────────────────────────────────────────────────
# A real swing in two phases. Downswing (the first slapper_follow_through_
# contact_frac of the timer): the blade falls from wherever the wind-up
# actually left it — re-derived from the charge timer so an early release
# starts from the half-coiled pose instead of popping to full wind-up — down to
# the contact point, accelerating like a swing under gravity, hands riding down
# from the wind-up grip. Finish (the rest): the blade releases through contact,
# arcs out along the shot line and up into a high finish, hands rising with it,
# then settles back to the ice by the end of the timer for a clean handoff to
# the aim IK. The shot line is re-derived body-local each frame so the finish
# stays on target while the torso rotates through the swing.
func apply_slapper_follow_through() -> void:
	var total: float = maxf(_sm.follow_through_duration_total, 0.001)
	var t: float = clampf(1.0 - _sm.follow_through_timer / total, 0.0, 1.0)
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	# Whiffed swings (shot never fired) follow the direction locked at charge.
	var dir_world: Vector3 = _sm.shot_dir
	if dir_world.length_squared() <= 0.0001:
		dir_world = Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
	var dir_local: Vector3 = _skater.upper_body.global_transform.basis.inverse() * dir_world
	dir_local.y = 0.0
	if dir_local.length_squared() > 0.0001:
		dir_local = dir_local.normalized()
	else:
		dir_local = Vector3.FORWARD
	var contact := Vector3(
			_skater.shoulder.position.x + blade_side_sign * _controller.slapper_blade_x,
			0.0,
			_skater.shoulder.position.z + _controller.slapper_blade_z)
	var hand_pos := Vector3(
			_skater.shoulder.position.x, _controller.hand_rest_y, _skater.shoulder.position.z)
	var blade_pos: Vector3
	var cf: float = clampf(_controller.slapper_follow_through_contact_frac, 0.05, 0.9)
	if t < cf:
		# Downswing: quadratic ease-in — the blade accelerates into the ice.
		var u: float = t / cf
		u *= u
		# Where the wind-up actually was at release (mirrors
		# apply_slapper_blade_position: eased XZ/hand, raw-t height).
		var wind_up_t: float = clampf(
				_aiming.slapper_charge_timer / _controller.slapper_wind_up_time, 0.0, 1.0)
		var wind_up_eased: float = sqrt(wind_up_t)
		var start_x: float = _skater.shoulder.position.x + blade_side_sign * lerpf(
				_controller.slapper_blade_x, _controller.slapper_wind_up_blade_x, wind_up_eased)
		var start_z: float = _skater.shoulder.position.z + lerpf(
				_controller.slapper_blade_z, _controller.slapper_wind_up_blade_z, wind_up_eased)
		var start_y: float = lerpf(
				_ik.blade_y_lean_corrected(start_x, start_z),
				_controller.slapper_wind_up_height, wind_up_t)
		blade_pos = Vector3(
				lerpf(start_x, contact.x, u),
				lerpf(start_y, _ik.blade_y_lean_corrected(contact.x, contact.z), u),
				lerpf(start_z, contact.z, u))
		var wind_hand := Vector3(
				_skater.shoulder.position.x
					- blade_side_sign * _controller.slapper_wind_up_hand_inward * wind_up_eased,
				_controller.hand_rest_y + _controller.slapper_wind_up_hand_up * wind_up_eased,
				_skater.shoulder.position.z
					+ _controller.slapper_wind_up_hand_back * wind_up_eased
					- _controller.slapper_wind_up_hand_forward * wind_up_eased)
		hand_pos = wind_hand.lerp(hand_pos, u)
	else:
		# Finish: out along the shot line and up into the high finish, then
		# settle. Shares the wrister's asymmetric arc so both shots snap
		# through contact and relax out of the pose.
		var v: float = (t - cf) / (1.0 - cf)
		var env: float = sin(PI * pow(v, _controller.follow_through_arc_skew)) \
				* _sm.follow_through_power
		var reach: float = env * _controller.slapper_follow_through_arc_dist
		blade_pos = contact + dir_local * reach
		blade_pos.y = _ik.blade_y_lean_corrected(blade_pos.x, blade_pos.z) \
				+ env * _controller.slapper_follow_through_height
		hand_pos.y += env * _controller.slapper_follow_through_hand_y
		var hand_follow: float = reach * _controller.slapper_follow_through_hand_follow
		hand_pos.x += dir_local.x * hand_follow
		hand_pos.z += dir_local.z * hand_follow
	blade_pos = _skater.clamp_blade_to_walls(blade_pos)
	blade_pos = _skater.upper_body_to_local(_ik.clamp_blade_from_net(_skater.upper_body_to_global(blade_pos)))
	_skater.set_top_hand_position(hand_pos)
	_skater.set_blade_position(blade_pos)
