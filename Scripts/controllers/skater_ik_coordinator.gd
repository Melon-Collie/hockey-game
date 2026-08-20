class_name SkaterIKCoordinator
extends RefCounted

# Owns the per-tick blade and arm IK pipeline:
# - Mouse → top-hand IK + blade placement (asymmetric ROM intersected with the
#   open ice via _board_reach_limit, then wall/goalie/net clamps).
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
# World-XZ blade position after the per-tick speed cap, which is applied to the
# RESOLVED (ROM-clamped) target rather than the raw cursor — see step 2 of
# apply_blade_from_mouse.
var _smoothed_blade_world: Vector3 = Vector3.ZERO
var _smoothed_blade_initialized: bool = false
# Dangle velocity (world XZ, relative to the skater) — the second-order blade's
# state when max_blade_accel > 0 (see the arrive-law branch in
# apply_blade_from_mouse). Kept coherent through the first-order and
# wrister-aim paths so mode transitions never hand the inertia model a stale
# velocity. Reset with the smoothing baseline.
var _blade_dangle_vel: Vector3 = Vector3.ZERO
# Skater world position (XZ) at the previous smoothing tick — the blade-speed cap
# is applied RELATIVE to the skater (step 2 of apply_blade_from_mouse).
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
var _net_result := NetBladeCollision.Result.new()
var _rigid_result := TopHandIK.Result.new()
# Native IK solvers (null = extension absent, GDScript fallback). Config
# properties sync inside the cached-config builders — the same rebuild moment —
# so invalidate_configs() covers both representations.
var _native_top: RefCounted = null
var _native_bottom: RefCounted = null
# Native blade-dangle smoother (null = extension absent, GDScript fallback).
# In native mode it OWNS the cross-tick smoothing state (_prev_skater_pos,
# _blade_dangle_vel, the init flag) — only _smoothed_blade_world is mirrored
# back, because the hand solve below the block reads it.
var _native_dangle: RefCounted = null

func setup(skater: Skater, controller: SkaterController) -> void:
	_skater = skater
	_controller = controller
	if ClassDB.class_exists(&"NativeTopHandIK"):
		_native_top = ClassDB.instantiate(&"NativeTopHandIK")
		# Stale-binary guard, one level finer than NativeKernels' class census:
		# max_blade_reach was ADDED to an existing kernel, so a binary predating it
		# still registers the class and passes that check. Writing the property
		# would then quietly no-op and the boards would stop bounding blade reach —
		# wrong behaviour that looks like working behaviour. Fall back to GDScript,
		# which is slower and correct, rather than fast and silently wrong.
		if not _native_top.has_method(&"set_max_blade_reach"):
			push_warning("NativeTopHandIK predates max_blade_reach — "
					+ "using the GDScript solver. Rebuild native/ (bash native/build.sh).")
			_native_top = null
		else:
			_native_bottom = ClassDB.instantiate(&"NativeBottomHandIK")
	if ClassDB.class_exists(&"NativeBladeDangle"):
		_native_dangle = ClassDB.instantiate(&"NativeBladeDangle")
		_sync_dangle_config()

# Drop the cached configs so the next solve rebuilds them from the controller
# exports. Called by SkaterController.apply_attributes (stick length, ROM, and
# hand heights all scale with attributes).
func invalidate_configs() -> void:
	_cached_top_cfg = null
	_cached_bottom_cfg = null
	_sync_dangle_config()

# The dangle tunables are plain controller @exports (not part of the cached IK
# configs), so they sync here — covered by the same invalidate_configs moment
# that rebuilds the config objects on apply_attributes.
func _sync_dangle_config() -> void:
	if _native_dangle != null:
		_native_dangle.set_config(
				_controller.max_blade_speed,
				_controller.wrister_on_axis_blade_speed,
				_controller.max_blade_accel)

# Drop the smoothed-blade baseline so the next solve re-seeds it deterministically
# from the first replayed input (the init branch in apply_blade_from_mouse snaps
# the smoothed blade to that input's ROM-clamped target). Called by
# LocalController at reconcile entry so replay starts from a deterministic blade
# baseline rather than carrying the live smoothed value across the snap.
func reset_blade_smoothing() -> void:
	_smoothed_blade_initialized = false
	_blade_dangle_vel = Vector3.ZERO
	if _native_dangle != null:
		_native_dangle.reset_smoothing()

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
	if _native_dangle != null:
		_native_dangle.seed(world_pos, _skater.global_position)

# ── Blade From Mouse (Top-Hand IK) ────────────────────────────────────────────
# Input is treated as a desired blade position. The top hand is solved as a
# consequence, clamped to an asymmetric ROM. See domain/rules/top_hand_ik.gd.
func apply_blade_from_mouse(input: InputState, delta: float, hold_blade: bool = false,
		hold_target_world: Vector3 = Vector3.INF) -> void:
	var mouse_world: Vector3 = input.mouse_world_pos
	mouse_world.y = 0.0

	var skater_pos: Vector3 = _skater.global_position
	skater_pos.y = 0.0

	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0

	# The carry-side state this pipeline reads (get_carry_forehand_factor, via
	# _apply_carry_offset below) is advanced in Skater._update_carry_contact —
	# on the physics tick, for every peer — not here: the push model keys it
	# off blade motion, which remote skaters have and this pipeline does not run
	# for them.

	# FREEZE (hold_blade, set for the WRISTER_AIM state): during a wrister
	# charge, hold the blade at its current body-local pose instead of chasing the
	# cursor. The puck pins to this held blade (get_carry_target_global), so it
	# sits still AT the shot origin while the torso still coils toward the cursor
	# (apply_upper_body preserves the blade world across the coil). Target ==
	# current blade → the speed-cap/translation bookkeeping below runs with a
	# ~zero step, keeping _smoothed_blade coherent so resuming normal tracking
	# after the shot doesn't pop.
	var target_blade_world: Vector3
	if hold_blade:
		# A finite hold_target_world is a bot's scored release spot: hold the blade
		# toward it (the speed cap below eases the puck out over the coil) instead of
		# pinning the centered carry pose. The scored offset is a reachable blade
		# offset by construction (the scorer models the bot's reach), so it needs no
		# ROM re-projection. Humans (and uncommitted bots) pass INF → hold current pose.
		if hold_target_world.is_finite():
			target_blade_world = hold_target_world
		else:
			target_blade_world = _skater.upper_body_to_global(_skater.get_blade_position())
		target_blade_world.y = 0.0
		last_target_blade_world = target_blade_world
	else:
		var shoulder_world: Vector3 = _skater.upper_body_to_global(_skater.shoulder.position)
		shoulder_world.y = 0.0
		if (mouse_world - shoulder_world).length() < 0.01:
			return

		# 1. Resolve the RAW cursor to the blade the player is actually reaching for:
		#    convert to upper-body-local, apply the carry offset, then clamp to the
		#    reachable set — ROM intersected with the open ice (see
		#    _board_reach_limit; every consumer of this resolved target, from the
		#    speed cap below to the wrister charge gate that reads
		#    last_target_blade_world, inherits the boards for free because the limit
		#    lands here rather than on the solved pose). This is the TARGET the
		#    speed cap chases. ROM
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
		var target_reach: float = _board_reach_limit(target_blade_xz, shoulder_world)
		var target_blade_local: Vector3
		if _native_top != null:
			_ik_config(blade_y_local(), target_reach)
			target_blade_local = _native_top.project_blade(
					_skater.shoulder.position, target_blade_xz, blade_side_sign)
		else:
			target_blade_local = TopHandIK.project_blade(
					_skater.shoulder.position, target_blade_xz, blade_side_sign,
					_ik_config(blade_y_local(), target_reach))
		target_blade_world = _skater.upper_body_to_global(target_blade_local)
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
	if _native_dangle != null:
		# Native port of the block below (native/src/native_blade_dangle.cpp).
		# It owns the smoothing state; the returned smoothed blade is mirrored
		# because the hand solve below reads _smoothed_blade_world.
		_smoothed_blade_world = _native_dangle.advance(
				target_blade_world, skater_pos, delta,
				_controller.get_shot_state() == State.WRISTER_AIM)
		_smoothed_blade_initialized = true
	else:
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
			# that axis fixes slow-blade shot feel without letting "shoot mode" become
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
				# first-order path does.
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
				# First-order path: max_blade_accel 0 disables the inertia model
				# and the blade steps straight toward the target at the cap.
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
	# Commit stance: ease the blade OFF the cursor toward a body-local "loaded"
	# pose while committing (empty-handed), so the stick settles into a distinct
	# ready-to-hit silhouette instead of tracking. Blended by _commit_lift_blend
	# (0 except during a commit), so it lerps in as Ctrl is held and back to cursor
	# tracking on release — the underlying _smoothed_blade keeps tracking beneath the
	# override, so there's no pop. Gameplay-inert (the blade is withdrawn from puck
	# play while committed); the Y lift rides blade_y_local. Only the hand solve
	# reads this local copy — _smoothed_blade state is untouched, staying coherent
	# for the exit.
	var commit_t: float = _skater.get_commit_lift_blend()
	if commit_t > 0.0:
		# Swept off the shoulder being thrown: the leading shoulder is driving
		# into the contact, and a stick planted on that side swings through it.
		var loaded := Vector2(
				_controller.hit_commit_blade_local_x * blade_side_sign
						- _skater.get_check_lead() * _controller.hit_commit_blade_sweep_m,
				_controller.hit_commit_blade_local_z)
		capped_blade_xz = capped_blade_xz.lerp(loaded, commit_t)
	# The board limit is re-derived for the CAPPED aim line, not reused from the
	# target above: the smoothed blade lags the target (and is carried along by
	# the skater's own translation), so the two can point at different stretches
	# of wall. Without it the FAR regime would extend this solve back out past the
	# boards, which is exactly what the clamp below then has to undo.
	var ik: TopHandIK.Result = _solve_top_hand(
			capped_blade_xz, blade_side_sign,
			_board_reach_limit(capped_blade_xz, _skater.upper_body_to_global(
					_skater.shoulder.position)))
	var hand_local: Vector3 = ik.hand
	var blade_local: Vector3 = ik.blade

	# Carry transit lift: while carrying, raise the blade over the puck during
	# a pushing-face flip. One sin-envelope hop per flip (Skater
	# .get_carry_transit_factor) rather than (1 − |smoothed factor|): under a
	# fast dangle the smoothed factor lives near zero, which would hold the
	# blade permanently mid-air — the hop bounces once per stroke instead.
	# cos(p)*cos(r) divisor converts world-Y target into upper-body-local Y so
	# the lift lands at the intended height in world space (matches the
	# lean-correction math).
	if _controller.has_puck and _skater.carry_transit_lift > 0.0:
		var transit: float = _skater.get_carry_transit_factor()
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

	# Goalie body clamp (strips puck on contact) + the net.
	# All work in world space; convert back once at the end.
	var heel_world: Vector3 = _skater.upper_body_to_global(wall_clamped)
	var clamped_heel: Vector3 = heel_world
	if _controller.has_puck:
		clamped_heel = clamp_blade_from_goalies(clamped_heel)
	# The net is pure collision here — no strip, no legality. The blade stops on
	# iron and sinks into twine; whether the PUCK survives that is the puck's own
	# collision to resolve (SkaterController._collide_pinned_puck_with_net), which
	# is the only place that can answer it correctly since the puck rides a pin
	# OFF the blade. The blade is a segment here, so heel and toe are tested
	# directly rather than through a mid-blade contact-point proxy.
	clamped_heel += resolve_blade_against_net(clamped_heel).offset
	if clamped_heel != heel_world:
		wall_clamped = _skater.upper_body_to_local(clamped_heel)

	# Rebuild the arm for the FINAL blade whenever a clamp moved it. The blade is
	# authoritative from here (gameplay decided it — net legality, goalie contact,
	# the board surface), so the arm is solved to reach it and the stick chokes up
	# to make up the difference. Sliding the hand by the clamp offset instead
	# preserves stick length at the cost of arm length, which is what walked the
	# hand behind the shoulder against the boards and stretched it across the net.
	# Skipped when nothing moved: the reconstruction is an exact inverse of the
	# solve there, so it would only redo work.
	if wall_clamped != intended_blade:
		hand_local = TopHandIK.hand_for_clamped_blade(
				_skater.shoulder.position,
				Vector2(wall_clamped.x, wall_clamped.z),
				wall_clamped.y,
				blade_side_sign,
				_ik_config(blade_y_local()))
		# The rebuild bounds the ARM but leaves stick length free, so a clamp that
		# puts the blade past arm + stick has nowhere to put the difference except
		# the shaft — which is a stretched stick, the one thing a rigid object
		# cannot do. Reaching in through the open mouth is where that bites here:
		# the reach limit deliberately leaves the mouth unbounded (net-front play
		# depends on it), so the twine is free to move the blade a long way. Inert
		# whenever the blade is reachable, which is every ordinary tick.
		var rigid: TopHandIK.Result = rigid_stick(
				hand_local, wall_clamped, blade_side_sign)
		hand_local = rigid.hand
		wall_clamped = rigid.blade

	_skater.set_top_hand_position(hand_local)
	_skater.set_blade_position(wall_clamped)

# ── Board Reach Limit ─────────────────────────────────────────────────────────
# How far the blade may sit from the shoulder along the aim toward
# `target_blade_xz` before it runs into the boards, in metres (INF on open ice).
# Fed to TopHandIK as max_blade_reach so the reachable blade set is the ROM
# envelope INTERSECTED with the rink, rather than ROM alone with the wall
# discovered afterwards.
#
# `target_blade_xz` is upper-body-local and the boards live in world space, so
# the aim direction is rotated through the torso basis before the cast; the
# returned scalar is then compared against an upper-body-local radius inside the
# solver, so the two disagree by the lean's cosine (sub-centimetre at the reach
# where this binds). The exact heel/toe clamp downstream remains the backstop —
# this limit exists so that clamp has almost nothing left to correct.
func _board_reach_limit(target_blade_xz: Vector2, shoulder_world: Vector3) -> float:
	var aim_local := Vector3(
			target_blade_xz.x - _skater.shoulder.position.x,
			0.0,
			target_blade_xz.y - _skater.shoulder.position.z)
	if aim_local.length_squared() < 0.000001:
		return INF
	var aim_world: Vector3 = _skater.upper_body.global_transform.basis * aim_local
	var dir := Vector2(aim_world.x, aim_world.z)
	if dir.length_squared() < 0.000001:
		return INF
	var origin := Vector2(shoulder_world.x, shoulder_world.z)
	var unit: Vector2 = dir.normalized()
	# The net is the second obstacle on this aim line, and it earns the same
	# treatment as the boards: bound the REACH so the stick is never aimed through
	# the mesh, instead of letting it solve full reach and clamping the pose back.
	# NetGeometry.ray_to_solid_face leaves the open mouth unlimited, so reaching in
	# from the front — the whole of net-front play — is untouched.
	return minf(
			GameRules.ray_to_rink_inner(origin, unit),
			NetGeometry.ray_to_net(
					origin, unit, _controller.blade_height,
					_controller.net_blade_half_thickness))

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
func _solve_top_hand(desired_blade_xz: Vector2, blade_side_sign: float,
		max_blade_reach: float = INF) -> TopHandIK.Result:
	var blade_y: float = blade_y_local()
	var ik: TopHandIK.Result = _ik_result
	for i in 3:
		if _native_top != null:
			_ik_config(blade_y, max_blade_reach)
			_native_top.solve(_skater.shoulder.position, desired_blade_xz, blade_side_sign)
			ik.hand = _native_top.get_hand()
			ik.blade = _native_top.get_blade()
		else:
			TopHandIK.solve(
					_skater.shoulder.position,
					desired_blade_xz,
					blade_side_sign,
					_ik_config(blade_y, max_blade_reach),
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
	var bh: Vector3
	if _native_bottom != null:
		_native_bottom.hand_y = grip_y
		bh = _native_bottom.solve(
				_skater.bottom_shoulder.position, grip_target_xz, cfg.backhand_angle)
	else:
		bh = BottomHandIK.solve(
				_skater.bottom_shoulder.position,
				grip_target_xz,
				cfg)
	_skater.set_bottom_hand_position(bh)

# Rigid-stick correction for a POSED hand/blade pair — this skater's shoulder and
# cached config wrapped around the pure rule (TopHandIK.enforce_rigid_stick).
# Shared with SkaterShotPoseCoordinator, which runs every pose it authors through
# this and runs it again once the obstacle clamps have had their say, so no shot
# pose can draw a shaft longer than the stick. The returned Result is shared and
# overwritten by the next call: consume it before correcting again.
#
# The tracked path does not need it — it authors its pose through TopHandIK, which
# is rigid by construction, and rebuilds through the exact inverse.
func rigid_stick(hand_local: Vector3, blade_local: Vector3,
		blade_side_sign: float) -> TopHandIK.Result:
	TopHandIK.enforce_rigid_stick(
			_skater.shoulder.position, hand_local, blade_local, blade_side_sign,
			_ik_config(blade_local.y), _rigid_result)
	return _rigid_result

# ── Net Collision ─────────────────────────────────────────────────────────────
# Resolves the blade SEGMENT (heel → toe) against the net for a proposed heel,
# and returns the correction to apply. Pure collision: iron stops the stick, the
# twine lets it sink in and stops it there, and neither strips the puck — see
# NetBladeCollision, and docs/net-play-plan.md §3 for why there is no legality
# concept on this path any more.
#
# The returned Result is shared and overwritten by the next call, like _ik_result:
# consume it before resolving again.
func resolve_blade_against_net(heel_world: Vector3) -> NetBladeCollision.Result:
	NetBladeCollision.resolve(
			_skater.get_prev_blade_contact_global(),
			heel_world,
			_blade_toe_for(heel_world),
			_controller.net_blade_half_thickness,
			_controller.net_mesh_give,
			_net_result)
	return _net_result

# The blade's far end for a hypothetical heel, using the blade node's CURRENT
# forward. Same approximation Skater.clamp_blade_to_walls makes for the boards:
# this tick's orientation applied to the position the solve is proposing.
func _blade_toe_for(heel_world: Vector3) -> Vector3:
	var forward: Vector3 = -_skater.blade.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.000001:
		return heel_world
	return heel_world + forward.normalized() * _skater.blade_length

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
# the skater's body origin sits above the ice.
func blade_y_local() -> float:
	# Add the eased stick-lift offset so a lifted blade (and the hand/stick the
	# IK solves from it) rises off the ice. blend is 0 in all shot/carry states
	# (blade_up is gated off then), so this is a no-op except during a lift.
	# The lift TARGET follows the deflect mode: MID plays the low air, every
	# other lifted state (HIGH deflect, stick-lift, forced pop) the high plane.
	var lift_target: float = _controller.blade_lift_height_mid \
			if _skater.elevation_level == ShotMechanics.ELEVATION_MID \
			else _controller.blade_lift_height
	var lift: float = _skater.get_blade_lift_blend() * lift_target
	# Plus the commit-stance stick raise: a body-check commit pulls the stick off
	# the ice as a readable tell. Gameplay-inert (the blade is already withdrawn
	# from puck play while committed), so this is a pure cosmetic overlay; 0 except
	# during an empty-handed commit.
	lift += _skater.get_commit_lift_blend() * _controller.hit_commit_blade_lift_m
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

# The stick length every arm solve must use THIS instant: the rigid shaft minus
# however far the top hand has slid down it. Zero choke outside a check commit,
# so this is _controller.stick_length everywhere else.
#
# One accessor rather than three readers of _controller.stick_length: two sites
# solving the same frame from different lengths draw two different sticks, and
# the shot poses reconstruct their own hand/blade pair (a one-timer wind-up can
# be charged empty-handed with the Hit button down, so they DO overlap a commit).
func solve_stick_length() -> float:
	return _controller.stick_length - _skater.grip_choke()


# Horizontal projection of the stick onto the XZ plane, given the fixed
# vertical drop from hand to blade. Used by follow-through to keep stick
# length consistent with the IK solver.
func stick_horiz() -> float:
	var drop: float = _controller.hand_rest_y - blade_y_local()
	var length: float = solve_stick_length()
	return sqrt(maxf(length * length - drop * drop, 0.0001))

# ── Config Builders ───────────────────────────────────────────────────────────
# Cached: export-derived fields are filled once (until invalidate_configs);
# only the per-tick fields are written per call.
func _ik_config(blade_y: float, max_blade_reach: float = INF) -> TopHandIK.Config:
	if _cached_top_cfg == null:
		_cached_top_cfg = TopHandIK.Config.new()
		_cached_top_cfg.hand_rest_y = _controller.hand_rest_y
		_cached_top_cfg.hand_y_max = _controller.hand_y_max
		_cached_top_cfg.rom_forehand_angle_max = deg_to_rad(_controller.rom_forehand_angle_max_deg)
		_cached_top_cfg.rom_backhand_angle_max = deg_to_rad(_controller.rom_backhand_angle_max_deg)
		_cached_top_cfg.rom_forehand_reach_max = _controller.rom_forehand_reach_max
		_cached_top_cfg.rom_backhand_reach_max = _controller.rom_backhand_reach_max
		if _native_top != null:
			_native_top.hand_rest_y = _cached_top_cfg.hand_rest_y
			_native_top.hand_y_max = _cached_top_cfg.hand_y_max
			_native_top.rom_forehand_angle_max = _cached_top_cfg.rom_forehand_angle_max
			_native_top.rom_backhand_angle_max = _cached_top_cfg.rom_backhand_angle_max
			_native_top.rom_forehand_reach_max = _cached_top_cfg.rom_forehand_reach_max
			_native_top.rom_backhand_reach_max = _cached_top_cfg.rom_backhand_reach_max
	# All three per-tick fields are written on EVERY call, never left to carry
	# over: max_blade_reach is a property of the aim line being solved, so a stale
	# one would silently constrain an unrelated later solve this tick, and the
	# choked stick_length below is a property of this instant's grip.
	_cached_top_cfg.blade_y = blade_y
	_cached_top_cfg.max_blade_reach = max_blade_reach
	_cached_top_cfg.stick_length = solve_stick_length()
	if _native_top != null:
		_native_top.blade_y = blade_y
		_native_top.max_blade_reach = max_blade_reach
		_native_top.stick_length = _cached_top_cfg.stick_length
	return _cached_top_cfg

func _bottom_hand_ik_config() -> BottomHandIK.Config:
	if _cached_bottom_cfg == null:
		_cached_bottom_cfg = BottomHandIK.Config.new()
		_cached_bottom_cfg.hand_y = _controller.bh_hand_y
		_cached_bottom_cfg.release_angle_max = deg_to_rad(_controller.bh_release_angle_deg)
		_cached_bottom_cfg.release_angle_band = deg_to_rad(_controller.bh_release_angle_band_deg)
		if _native_bottom != null:
			_native_bottom.release_angle_max = _cached_bottom_cfg.release_angle_max
			_native_bottom.release_angle_band = _cached_bottom_cfg.release_angle_band
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
