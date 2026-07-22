class_name SkaterIKCoordinator
extends RefCounted

# Owns the per-tick blade and arm IK pipeline:
# - Mouse → top-hand IK + blade placement (asymmetric ROM, wall/goalie/net clamps).
# - Bottom-hand IK from the placed top hand + blade.
# - Geometry helpers shared with SkaterShotPoseCoordinator: blade_y_local,
#   blade_y_lean_corrected, stick_horiz.
# - Net exclusion zone and goalie body / butterfly box clamps. Both clamps
#   strip the puck on contact via _controller._do_release.
#
# Stateless rule layers (TopHandIK, BottomHandIK) live in domain/rules/. This
# class is the controller-facing dispatcher that builds configs from the
# controller's @export tunables and writes blade/hand positions onto Skater.

const State = SkaterStateMachine.State

# ── References ────────────────────────────────────────────────────────────────
var _skater: Skater = null
var _controller: SkaterController = null  # tunables, _do_release, _game_state, has_puck

# ── Blade Smoothing State ─────────────────────────────────────────────────────
# World-XZ blade position after applying the per-tick speed cap. The cap is
# applied to the RESOLVED (ROM-clamped) blade target, not the raw cursor: each
# tick the cursor is first solved to the reachable blade position the player is
# actually reaching for, then the smoothed blade steps toward that at most
# max_blade_speed * delta. Capping the resolved blade (rather than the intent)
# keeps blade traversal speed consistent regardless of how far past ROM the
# cursor sits — a distant cursor no longer spends the dangle budget sliding the
# intent point through unreachable space while the blade crawls.
var _smoothed_blade_world: Vector3 = Vector3.ZERO
var _smoothed_blade_initialized: bool = false
# Dangle velocity (world XZ, relative to the skater) — the second-order blade's
# state when max_blade_accel > 0 (see the arrive-law branch in
# apply_blade_from_mouse). Kept coherent through the first-order and
# wrister-aim paths so mode transitions never hand the inertia model a stale
# velocity. Reset with the smoothing baseline.
var _blade_dangle_vel: Vector3 = Vector3.ZERO
# Skater world position (XZ) at the previous smoothing tick. The blade-speed cap
# is applied RELATIVE to the skater: each tick the smoothed blade is first
# carried along by the skater's own translation, so skating velocity doesn't eat
# the dangle-speed budget. (A pure world-space cap makes the blade drag while
# skating, and lag the cursor forever once skating speed exceeds the cap.)
var _prev_skater_pos: Vector3 = Vector3.ZERO

# World-XZ ROM-clamped blade TARGET for this tick — the closed-form
# TopHandIK.project_blade result, captured BEFORE the speed-cap smoothing below.
# Wrister charge (SkaterController._update_wrister_charge) and the tap-direction
# release read this rather than the smoothed/capped blade: it stays gated by
# reachable space (cursor past the reach limit pins the target → zero travel →
# no charge) while being a deterministic closed-form clamp of (mouse, body, ROM),
# so host and client agree on charge without replaying the stateful smoother. y = 0.
var last_target_blade_world: Vector3 = Vector3.ZERO

# ── Cached Solver Objects ─────────────────────────────────────────────────────
# The IK configs read only controller @exports, which change exclusively in
# SkaterController.apply_attributes — so they're built once and invalidated
# from there. Per-tick fields (blade_y, hand_y, backhand_angle) are written
# into the cached instance each use. Building fresh configs per solve was the
# hottest allocation site in the game (~7 RefCounted/Dictionary allocs per
# skater per physics tick across the 3-pass loop).
var _cached_top_cfg: TopHandIK.Config = null
var _cached_bottom_cfg: BottomHandIK.Config = null
var _ik_result := TopHandIK.Result.new()

func setup(skater: Skater, controller: SkaterController) -> void:
	_skater = skater
	_controller = controller

# Drop the cached configs so the next solve rebuilds them from the controller
# exports. Called by SkaterController.apply_attributes (stick length, ROM, and
# hand heights all scale with attributes).
func invalidate_configs() -> void:
	_cached_top_cfg = null
	_cached_bottom_cfg = null

# Drop the smoothed-blade baseline so the next solve re-seeds it deterministically
# from the first replayed input (the init branch in apply_blade_from_mouse snaps
# the smoothed blade to that input's ROM-clamped target). Called by
# LocalController at reconcile entry so replay starts from a deterministic blade
# baseline rather than carrying the live smoothed value across the snap.
func reset_blade_smoothing() -> void:
	_smoothed_blade_initialized = false
	_blade_dangle_vel = Vector3.ZERO

# Seed the smoothed-blade baseline to a specific world position so the next solve
# steps toward the cursor FROM there rather than from a stale value. Called by
# SkaterController when handing off from the follow-through to normal skating:
# the blade smoother was frozen at the wound-back release position while the FT
# choreographed the blade directly, so without re-seeding the blade would snap
# back to that stale spot and dangle forward again. Seeding it to the FT's final
# blade lets the normal dangle continue from where the finish left it.
func seed_blade_smoothing(world_pos: Vector3) -> void:
	_smoothed_blade_world = Vector3(world_pos.x, 0.0, world_pos.z)
	_prev_skater_pos = Vector3(_skater.global_position.x, 0.0, _skater.global_position.z)
	_smoothed_blade_initialized = true
	# The follow-through choreographed the blade directly; the dangle resumes
	# from rest at the seeded position.
	_blade_dangle_vel = Vector3.ZERO

# ── Blade From Mouse (Top-Hand IK) ────────────────────────────────────────────
# Input is treated as a desired blade position. The top hand is solved as a
# consequence, clamped to an asymmetric ROM. See domain/rules/top_hand_ik.gd.
func apply_blade_from_mouse(input: InputState, delta: float) -> void:
	var mouse_world: Vector3 = input.mouse_world_pos
	mouse_world.y = 0.0

	var skater_pos: Vector3 = _skater.global_position
	skater_pos.y = 0.0

	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0

	# Advance the sticky carry-side state and its smoothed factor before
	# reading the forehand factor. When not carrying the discrete side resets
	# to 0 and the smoothed factor lerps back to center; when carrying it
	# holds the current side until the blade crosses past
	# carry_side_switch_threshold on the opposite side, then flips and lerps
	# through center over carry_side_lerp_speed.
	_skater.update_carry_side(_controller.has_puck, delta)

	var shoulder_world: Vector3 = _skater.upper_body_to_global(_skater.shoulder.position)
	shoulder_world.y = 0.0
	if (mouse_world - shoulder_world).length() < 0.01:
		return

	# 1. Resolve the RAW cursor to the blade the player is actually reaching for:
	#    convert to upper-body-local, apply the carry offset, then ROM-clamp via
	#    the iterative top-hand IK. This is the TARGET the speed cap chases. ROM
	#    clamping the target up front (rather than after the cap) is the whole
	#    point: the cap then limits the speed of the REACHABLE blade, not the
	#    intent point far out past ROM. A distant cursor maps to a point on the
	#    ROM boundary, so sweeping it laterally slides the target along that
	#    boundary at cursor speed — and the cap bounds the blade's actual travel
	#    rather than being spent dragging the intent through unreachable space.
	var mouse_local: Vector3 = _skater.upper_body_to_local(mouse_world)
	var target_blade_xz := Vector2(mouse_local.x, mouse_local.z)
	target_blade_xz = _apply_carry_offset(target_blade_xz)
	# Closed-form ROM projection — no iteration, no hand work. Only the blade
	# position is needed to cap against; the capped result is re-solved at full
	# precision (hand + lean blade_y) below. Uses rest blade_y for the projection:
	# the sub-cm lean refinement the iterative solve adds is irrelevant to a point
	# that's about to be capped and re-solved.
	var target_blade_local: Vector3 = TopHandIK.project_blade(
			_skater.shoulder.position, target_blade_xz, blade_side_sign,
			_ik_config(blade_y_local()))
	var target_blade_world: Vector3 = _skater.upper_body_to_global(target_blade_local)
	target_blade_world.y = 0.0
	last_target_blade_world = target_blade_world

	# 2. Speed-cap the smoothed blade toward the resolved target, RELATIVE TO THE
	#    SKATER. max_blade_speed bounds how fast the blade traverses its ROM in
	#    front of the player (dangle speed). The blade's WORLD position drifts at
	#    the skater's skating velocity (the camera follows the player), so capping
	#    in world space would bleed skating speed into the budget — the blade
	#    would drag while skating and, once skating speed exceeds the cap, never
	#    catch up. So carry the smoothed blade along with the skater's translation
	#    first, then cap only the residual dangle relative to the player.
	if not _smoothed_blade_initialized:
		_smoothed_blade_world = target_blade_world
		_prev_skater_pos = skater_pos
		_smoothed_blade_initialized = true
		_blade_dangle_vel = Vector3.ZERO
	_smoothed_blade_world += skater_pos - _prev_skater_pos
	_smoothed_blade_world.y = 0.0
	_prev_skater_pos = skater_pos
	var step: Vector3 = target_blade_world - _smoothed_blade_world
	step.y = 0.0
	var max_step: float = _controller.max_blade_speed * delta
	if max_step > 0.0:
		# During a wrister aim, uncap blade motion ALONG the shot axis — the
		# wind-back-and-snap that makes the shot feel responsive regardless of
		# Hands — while keeping the PERPENDICULAR component capped at the normal
		# dangle budget (max_step). Lateral blade sweep IS dangling; capping only
		# that axis fixes low-Hands shot feel without letting "shoot mode" become
		# a way to dangle at full blade speed. The axis is skater→smoothed-blade
		# (the current aim line). Reading the LAGGED smoothed blade (not the raw
		# target) self-stabilizes the split: a fast lateral whip can't drag the
		# axis along with it (off-axis is capped, so the axis can only rotate as
		# fast as that cap allows), while a slow re-aim turns the axis naturally.
		# The on-axis budget is flat (Hands-independent) so shooting feels the
		# same for everyone — Hands still gates the off-axis dangle.
		var axis_vec: Vector3 = _smoothed_blade_world - skater_pos
		axis_vec.y = 0.0
		if _controller.get_shot_state() == State.WRISTER_AIM and axis_vec.length_squared() > 0.0001:
			var axis: Vector3 = axis_vec.normalized()
			var on_axis: Vector3 = axis * step.dot(axis)
			var off_axis: Vector3 = step - on_axis
			var on_max: float = _controller.wrister_on_axis_blade_speed * delta
			var on_len: float = on_axis.length()
			if on_len > on_max:
				on_axis *= on_max / on_len
			var off_len: float = off_axis.length()
			if off_len > max_step:
				off_axis *= max_step / off_len
			_smoothed_blade_world += on_axis + off_axis
			# Keep the dangle-velocity state coherent through the aim mode so
			# exiting a wrister aim doesn't hand the inertia model a stale
			# velocity from before the wind-up.
			_blade_dangle_vel = (on_axis + off_axis) / delta
		elif _controller.max_blade_accel > 0.0:
			# SECOND-ORDER BLADE (attributes v4 hands model): the stick has
			# inertia. Dangle velocity chases an arrive-law target — speed
			# toward the target is bounded by both the tip-speed cap and
			# sqrt(2·A·dist) (the fastest approach that can still stop on the
			# target), and the velocity itself may only change at A per second.
			# Traverse speed is barely touched (the caps are tuned to bind only
			# at gesture extremes); direction REVERSALS pay the inertia — the
			# lever seesaw's whole point. No spring, no overshoot: the arrive
			# law decays approach speed to zero at the target, and the landing
			# snap below catches the final sub-tick step exactly like the
			# first-order path did.
			var accel: float = _controller.max_blade_accel
			var dist: float = step.length()
			var desired := Vector3.ZERO
			if dist > 0.00001:
				var arrive_speed: float = minf(
						_controller.max_blade_speed, sqrt(2.0 * accel * dist))
				desired = step * (arrive_speed / dist)
			_blade_dangle_vel = _blade_dangle_vel.move_toward(desired, accel * delta)
			var move: Vector3 = _blade_dangle_vel * delta
			if move.length() >= dist and _blade_dangle_vel.dot(step) >= 0.0:
				_smoothed_blade_world = target_blade_world
			else:
				_smoothed_blade_world += move
		else:
			# First-order path (max_blade_accel 0 = inertia disabled — the
			# pre-v4 servo, kept bit-exact as the escape hatch).
			var step_len: float = step.length()
			if step_len > max_step:
				# Target is beyond the dangle-speed budget this tick — step toward it.
				_smoothed_blade_world += step * (max_step / step_len)
				_blade_dangle_vel = step * (max_step / step_len) / delta
			else:
				# Within budget this tick — the blade can reach the target.
				_smoothed_blade_world = target_blade_world
				_blade_dangle_vel = step / delta if delta > 0.0 else Vector3.ZERO
	# else (delta == 0): no wall-clock elapsed, so the blade traverses no ROM.
	# This is the reconcile final re-apply path (LocalController.reconcile passes
	# delta 0.0 to re-place the blade in the post-snap body frame). Snapping to
	# the target here would zero out the hands speed cap on every reconcile —
	# clients reconcile constantly, the host never does, so the host would feel
	# the clamp at full strength while clients barely felt it. Keep the replayed
	# (already clamped) smoothed blade instead of snapping.

	# 3. Solve the hand (and lean-corrected blade_y) for the CAPPED blade. The
	#    smoothed blade is already within ROM (it stepped from one in-ROM point
	#    toward another), so this resolves the matching hand/stick pose at the
	#    capped position rather than the raw target.
	var capped_blade_local: Vector3 = _skater.upper_body_to_local(_smoothed_blade_world)
	var capped_blade_xz := Vector2(capped_blade_local.x, capped_blade_local.z)
	var ik: TopHandIK.Result = _solve_top_hand(capped_blade_xz, blade_side_sign)
	var hand_local: Vector3 = ik.hand
	var blade_local: Vector3 = ik.blade

	# Carry transit lift: while carrying, raise the blade over the puck during
	# a forehand/backhand flip. (1 − |smoothed|) peaks at 1 when the smoothed
	# factor is mid-flip and falls to 0 when fully on either side. cos(p)*cos(r)
	# divisor converts world-Y target into upper-body-local Y so the lift lands
	# at the intended height in world space (matches the lean-correction math).
	if _controller.has_puck and _skater.carry_transit_lift > 0.0:
		var transit: float = 1.0 - absf(_skater.get_carry_forehand_factor())
		if transit > 0.0001:
			var lift_world: float = transit * _skater.carry_transit_lift
			var cpcr: float = maxf(
					cos(_skater.upper_body.rotation.x) * cos(_skater.upper_body.rotation.z),
					0.01)
			blade_local.y += lift_world / cpcr

	# Wall clamp on the solved blade. Wall-pin auto-release (when carrying).
	var intended_blade: Vector3 = blade_local
	var wall_clamped: Vector3 = _skater.clamp_blade_to_walls(blade_local)

	if _controller.has_puck:
		var squeeze: float = _skater.get_wall_squeeze(intended_blade, wall_clamped)
		if ShotMechanics.should_release_on_wall_pin(squeeze, _skater.wall_squeeze_threshold):
			# Lose it ALONG the boards in the carrier's travel direction, not straight
			# out into the slot — the wall normal points inward, so releasing along it
			# would fire the puck away from the wall (an unnatural giveaway). A small
			# inward bias peels it a touch off the boards so it doesn't hug them.
			var wall_normal: Vector3 = _skater.get_blade_wall_normal()
			var release_dir: Vector3 = ShotMechanics.wall_pin_release_direction(
					wall_normal, _skater.velocity, _skater.wall_pin_inward_bias)
			if release_dir.length() > 0.0:
				_controller._do_release(release_dir, 3.0)
			else:
				# Fully degenerate: no wall normal and no along-wall momentum. A squeeze
				# past the threshold implies a wall normal, so this is essentially
				# unreachable — but keep a sane free by shoving the puck back toward the
				# body (blade → body center), falling to facing if that's degenerate too.
				var blade_world: Vector3 = _skater.upper_body_to_global(wall_clamped)
				var back: Vector3 = _skater.global_position - blade_world
				back.y = 0.0
				if back.length_squared() < 0.0001:
					back = -_skater.global_transform.basis.z
				_controller._do_release(back.normalized(), 3.0)

	# When the blade got pulled back by the wall clamp, slide the hand by the
	# same horizontal offset so |hand − blade| stays at stick_horiz. Prevents
	# the stick mesh from compressing; reads as "pulling the stick back".
	var clamp_delta_xz := Vector3(
			wall_clamped.x - intended_blade.x, 0.0, wall_clamped.z - intended_blade.z)
	if clamp_delta_xz.length_squared() > 0.0:
		hand_local.x += clamp_delta_xz.x
		hand_local.z += clamp_delta_xz.z

	# Goalie body clamp (strips puck on contact) + net exclusion zone.
	# All work in world space; convert back once at the end.
	var heel_world: Vector3 = _skater.upper_body_to_global(wall_clamped)
	var clamped_heel: Vector3 = heel_world
	if _controller.has_puck:
		clamped_heel = clamp_blade_from_goalies(clamped_heel)
	# Compute the puck contact point (mid-blade) and clamp that against the net,
	# not the heel. This is geometrically correct regardless of blade angle.
	var hand_world: Vector3 = _skater.upper_body_to_global(hand_local)
	var shaft: Vector3 = clamped_heel - hand_world
	shaft.y = 0.0
	var contact_world: Vector3 = clamped_heel
	if shaft.length() > 0.001:
		contact_world = clamped_heel + shaft.normalized() * _skater.blade_length * 0.5
	var clamped_contact: Vector3 = clamp_blade_from_net(contact_world)
	if clamped_contact != contact_world:
		var net_offset: Vector3 = clamped_contact - contact_world
		clamped_heel += net_offset
		if _controller.has_puck:
			_controller._do_release(net_offset.normalized(), _controller.goalie_strip_power)
	if clamped_heel != heel_world:
		var clamped_local: Vector3 = _skater.upper_body_to_local(clamped_heel)
		hand_local.x += clamped_local.x - wall_clamped.x
		hand_local.z += clamped_local.z - wall_clamped.z
		wall_clamped = clamped_local

	_skater.set_top_hand_position(hand_local)
	_skater.set_blade_position(wall_clamped)

	# Store the blade's bearing from the shoulder for follow-through.
	var bearing: Vector3 = wall_clamped - _skater.shoulder.position
	if Vector2(bearing.x, bearing.z).length() > 0.001:
		_controller._blade_relative_angle = atan2(bearing.x, -bearing.z)

# While carrying, offset the IK target perpendicular to the shoulder→target
# direction so the blade marker (and therefore the visible blade + stick
# attachment) sits on the forehand or backhand side of the cursor. The puck
# pins to Skater.get_carry_target_global() (contact − same offset), which lands
# at the cursor — visually: cursor = puck, blade beside it. No-op when not
# carrying.
func _apply_carry_offset(desired_blade_xz: Vector2) -> Vector2:
	if not _controller.has_puck:
		return desired_blade_xz
	var to_target: Vector2 = desired_blade_xz - Vector2(
			_skater.shoulder.position.x, _skater.shoulder.position.z)
	if to_target.length() > 0.001:
		var stick_dir: Vector2 = to_target.normalized()
		# 90° rotation in XZ: (X, Z) → (−Z, X). Sign matched in
		# Skater.get_carry_target_global so subtraction inverts cleanly.
		var face_normal_xz := Vector2(-stick_dir.y, stick_dir.x)
		desired_blade_xz += face_normal_xz \
				* _skater.get_carry_forehand_factor() * _skater.carry_blade_offset
	return desired_blade_xz

# Iterative IK to land the blade on world-space ice while preserving stick
# length, ROM-clamped to the asymmetric envelope. The lean correction depends on
# blade_local_z (forward extension), which depends on stick_horiz_at_rest, which
# depends on blade_y, which is what we're solving for — a fixed-point in two
# variables. Three passes bring the residual world-Y error below ~3mm at max
# reach + max lean. Using the SOLVED blade XZ from each pass (not the raw target)
# converges to the right answer even when the target is past ROM. Writes into and
# returns the shared _ik_result — callers must consume it before the next solve.
func _solve_top_hand(desired_blade_xz: Vector2, blade_side_sign: float) -> TopHandIK.Result:
	var blade_y: float = blade_y_local()
	var ik: TopHandIK.Result = _ik_result
	for i in 3:
		TopHandIK.solve(
				_skater.shoulder.position,
				desired_blade_xz,
				blade_side_sign,
				_ik_config(blade_y),
				ik)
		blade_y = blade_y_lean_corrected(ik.blade.x, ik.blade.z)
	return ik

# ── Bottom Hand ───────────────────────────────────────────────────────────────
# Recompute the bottom hand pose from the current top_hand + blade positions.
# Purely reactive — does not affect blade or top-hand placement. Caller must
# have already written the top hand and blade for this tick before calling.
func update_bottom_hand() -> void:
	var blade_local: Vector3 = _skater.get_blade_position()
	var hand_local: Vector3 = _skater.get_top_hand_position()
	var grip_target_xz := Vector2(
			lerpf(hand_local.x, blade_local.x, _controller.bottom_hand_grip_fraction),
			lerpf(hand_local.z, blade_local.z, _controller.bottom_hand_grip_fraction))
	# Derive grip Y from the stick shaft so the hand stays on the stick regardless
	# of pitch lean or reach. bh_hand_y offsets for fine-tuning.
	var grip_y: float = lerpf(hand_local.y, blade_local.y, _controller.bottom_hand_grip_fraction) + _controller.bh_hand_y
	var cfg: BottomHandIK.Config = _bottom_hand_ik_config()
	cfg.hand_y = grip_y
	var bh: Vector3 = BottomHandIK.solve(
			_skater.bottom_shoulder.position,
			grip_target_xz,
			cfg)
	_skater.set_bottom_hand_position(bh)

# ── Net Exclusion Clamp ───────────────────────────────────────────────────────
# Clamps `point` (either the puck contact point or the blade heel during
# follow-through) out of the net, which NetClampRules treats as a solid object
# with only its front face (the mouth) open. The point escapes through the
# nearest solid face — never the front.
#
# Tuck-in: while CARRYING, the front face is open, so a blade whose swept path
# (prev contact → this contact) came IN through the mouth is left unclamped and
# carries the puck across the line (wraparounds / jams). Entry from a side or the
# back is still blocked — the stick can't reach through the mesh, no matter where
# the skater's body is. Because a legal tuck leaves the contact UNCLAMPED, the
# caller's "clamp moved the contact → auto-release" path (see apply_blade_from_
# mouse) doesn't fire, so the puck rides in instead of being ejected. Follow-
# through / non-carry calls pass allow_front = false and behave exactly as before.
func clamp_blade_from_net(point: Vector3) -> Vector3:
	return NetClampRules.clamp_out_of_net(
			point,
			_skater.get_prev_blade_contact_global(),
			GameRules.GOAL_LINE_Z,
			GameRules.NET_HALF_WIDTH,
			GameRules.NET_POST_RADIUS,
			GameRules.NET_PUCK_BUFFER,
			GameRules.NET_DEPTH,
			GameRules.NET_HEIGHT,
			_controller.has_puck)

# ── Goalie Body / Butterfly Clamp ─────────────────────────────────────────────
# Pushes blade_world out of every goalie's collision zone and strips the puck
# on contact. Standing/RVH use an XZ cylinder; butterfly uses an oriented box
# around the leg pads. Returns the adjusted world position.
func clamp_blade_from_goalies(blade_world: Vector3) -> Vector3:
	if not _controller._game_state.has_method("get_goalie_data"):
		return blade_world
	var goalie_data: Array[Dictionary] = _controller._game_state.get_goalie_data()
	var result: Vector3 = blade_world
	for data: Dictionary in goalie_data:
		var gpos: Vector3 = data["position"]
		if data["is_butterfly"]:
			var prev: Vector3 = result
			result = _clamp_blade_butterfly_box(result, gpos, data["rotation_y"])
			if result != prev and _controller.has_puck:
				break
		else:
			var to_blade := Vector2(result.x - gpos.x, result.z - gpos.z)
			var dist: float = to_blade.length()
			if dist < _controller.goalie_block_radius:
				var push_dir: Vector2 = to_blade.normalized() if dist > 0.001 else Vector2(0.0, -sign(gpos.z) if gpos.z != 0.0 else 1.0)
				result.x = gpos.x + push_dir.x * _controller.goalie_block_radius
				result.z = gpos.z + push_dir.y * _controller.goalie_block_radius
				if _controller.has_puck:
					_controller._do_release(Vector3(push_dir.x, 0.0, push_dir.y), _controller.goalie_strip_power)
					break
	return result

# Pushes blade_world out of the goalie's butterfly leg-pad box in goalie local XZ.
# Strips the puck on contact. Returns the adjusted world position (unchanged if outside).
func _clamp_blade_butterfly_box(blade_world: Vector3, gpos: Vector3, rot_y: float) -> Vector3:
	var dx: float = blade_world.x - gpos.x
	var dz: float = blade_world.z - gpos.z
	var local_x: float = dx * cos(rot_y) + dz * sin(rot_y)
	var local_z: float = -dx * sin(rot_y) + dz * cos(rot_y)
	if abs(local_x) >= _controller.butterfly_pad_half_x or abs(local_z) >= _controller.butterfly_pad_half_z:
		return blade_world
	# Inside box — escape along shortest axis.
	var ox: float = _controller.butterfly_pad_half_x - abs(local_x)
	var oz: float = _controller.butterfly_pad_half_z - abs(local_z)
	var escaped_local_x: float
	var escaped_local_z: float
	if ox < oz:
		escaped_local_x = _controller.butterfly_pad_half_x * signf(local_x) if local_x != 0.0 else _controller.butterfly_pad_half_x
		escaped_local_z = local_z
	else:
		escaped_local_x = local_x
		escaped_local_z = _controller.butterfly_pad_half_z * signf(local_z) if local_z != 0.0 else _controller.butterfly_pad_half_z
	var world_dx: float = escaped_local_x * cos(rot_y) - escaped_local_z * sin(rot_y)
	var world_dz: float = escaped_local_x * sin(rot_y) + escaped_local_z * cos(rot_y)
	var result: Vector3 = blade_world
	result.x = gpos.x + world_dx
	result.z = gpos.z + world_dz
	if _controller.has_puck:
		var escape := Vector2(world_dx - dx, world_dz - dz)
		var push_dir: Vector2 = escape.normalized() if escape.length_squared() > 0.0001 else Vector2(world_dx, world_dz).normalized()
		_controller._do_release(Vector3(push_dir.x, 0.0, push_dir.y), _controller.goalie_strip_power)
	return result

# ── Geometry Helpers ──────────────────────────────────────────────────────────
# Converts the world-space blade_height to upper-body-local Y.
# Uses the upper body's world Y so the result is correct regardless of where
# the skater's CharacterBody3D origin sits above the ice.
func blade_y_local() -> float:
	# Add the eased stick-lift offset so a lifted blade (and the hand/stick the
	# IK solves from it) rises off the ice. blend is 0 in all shot/carry states
	# (blade_up is gated off then), so this is a no-op except during a lift.
	var lift: float = _skater.get_blade_lift_blend() * _controller.blade_lift_height
	return (_controller.blade_height + lift) - _skater.upper_body.global_position.y

# Lean-corrected blade Y for a given blade local (X, Z). Computes the local Y
# that — after the upper body's pitch (X) and roll (Z) rotations under Godot's
# default YXZ Euler order — lands the blade at world Y = blade_height.
# Solving world_y = ub.y + (x*sin(r) + y*cos(r))*cos(p) - z*sin(p) for y gives:
#   y = (blade_y_local() + z*sin(p) - x*sin(r)*cos(p)) / (cos(p)*cos(r))
# A small-angle approximation (drop the cos divisors) drifts ~2cm at max reach
# with full reach lean (15° forward pitch); the exact form is used here so the
# IK can consume the correct blade_y up front and produce a hand consistent
# with stick_length, instead of post-IK overriding blade.y and stretching the
# visible stick mesh.
func blade_y_lean_corrected(blade_local_x: float, blade_local_z: float) -> float:
	var pitch: float = _skater.upper_body.rotation.x
	var roll: float = _skater.upper_body.rotation.z
	var cp: float = cos(pitch)
	var cr: float = cos(roll)
	# Guard against the degenerate near-90° case so the solver never divides
	# by zero. In practice the upper body never approaches 90° lean.
	if cp < 0.001:
		cp = 0.001
	if cr < 0.001:
		cr = 0.001
	var numerator: float = blade_y_local() + blade_local_z * sin(pitch) - blade_local_x * sin(roll) * cp
	return numerator / (cp * cr)

# Horizontal projection of the stick onto the XZ plane, given the fixed
# vertical drop from hand to blade. Used by follow-through to keep stick
# length consistent with the IK solver.
func stick_horiz() -> float:
	var drop: float = _controller.hand_rest_y - blade_y_local()
	var sq: float = _controller.stick_length * _controller.stick_length - drop * drop
	return sqrt(maxf(sq, 0.0001))

# ── Config Builders ───────────────────────────────────────────────────────────
# Cached: export-derived fields are filled once (until invalidate_configs);
# only the per-tick fields are written per call.
func _ik_config(blade_y: float) -> TopHandIK.Config:
	if _cached_top_cfg == null:
		_cached_top_cfg = TopHandIK.Config.new()
		_cached_top_cfg.stick_length = _controller.stick_length
		_cached_top_cfg.hand_rest_y = _controller.hand_rest_y
		_cached_top_cfg.hand_y_max = _controller.hand_y_max
		_cached_top_cfg.rom_forehand_angle_max = deg_to_rad(_controller.rom_forehand_angle_max_deg)
		_cached_top_cfg.rom_backhand_angle_max = deg_to_rad(_controller.rom_backhand_angle_max_deg)
		_cached_top_cfg.rom_forehand_reach_max = _controller.rom_forehand_reach_max
		_cached_top_cfg.rom_backhand_reach_max = _controller.rom_backhand_reach_max
	_cached_top_cfg.blade_y = blade_y
	return _cached_top_cfg

func _bottom_hand_ik_config() -> BottomHandIK.Config:
	if _cached_bottom_cfg == null:
		_cached_bottom_cfg = BottomHandIK.Config.new()
		_cached_bottom_cfg.hand_y = _controller.bh_hand_y
		_cached_bottom_cfg.release_angle_max = deg_to_rad(_controller.bh_release_angle_deg)
		_cached_bottom_cfg.release_angle_band = deg_to_rad(_controller.bh_release_angle_band_deg)
	_cached_bottom_cfg.backhand_angle = _bh_backhand_angle()
	return _cached_bottom_cfg

# Blade world angle toward the backhand side, in the skater's body frame.
# Returns a positive value when the blade is on the backhand side; 0 on forehand.
func _bh_backhand_angle() -> float:
	var blade_world: Vector3 = _skater.upper_body_to_global(_skater.get_blade_position())
	var to_blade: Vector3 = blade_world - _skater.global_position
	to_blade.y = 0.0
	if to_blade.length() < 0.01:
		return 0.0
	var skater_dir: Vector3 = _skater.global_transform.basis.inverse() * to_blade.normalized()
	var blade_angle: float = atan2(skater_dir.x, -skater_dir.z)
	# For a lefty the backhand side is +X (positive angle); negate blade_side_sign
	# so the result is always positive toward backhand regardless of handedness.
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	return blade_angle * -blade_side_sign
