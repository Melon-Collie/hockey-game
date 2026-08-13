extends GutTest

# Parity fuzz: NativePuckStep (C++ GDExtension, native/src/) against the
# GDScript loose-puck analytic step it ports — PuckAuthorityRules.
# step_frame_substep / frame_substeps (which pull in AITrajectory.step_puck_3d,
# GameRules.clamp_to_rink_inner, and the PuckGeometryCollision resolvers) and
# SweptDiscOBB.contact.
#
# This kernel is determinism-critical: host drive and client prediction agree
# by construction BECAUSE they run the same step, so the native port must track
# the reference through every regime — grounded slide, airborne ballistic,
# board caroms with friction, post/crossbar pings, and both faces of the net
# twine. The fuzz biases positions toward the goal frame to keep those
# branches hot, and the rollout test walks long multi-step trajectories so a
# regime-transition slip compounds into a visible failure.
#
# Goes pending when the extension isn't built.

const TOLERANCE: float = 0.001
const SEED: int = 0x5055434B  # "PUCK"

var _rng := RandomNumberGenerator.new()


func before_each() -> void:
	_rng.seed = SEED


func _native_missing() -> bool:
	if ClassDB.class_exists(&"NativePuckStep"):
		return false
	NativeParityGuard.report_missing(self, "NativePuckStep")
	return true


func _make_native() -> RefCounted:
	var native: RefCounted = ClassDB.instantiate(&"NativePuckStep")
	native.set_rink_geometry(
			GameRules.INNER_HALF_WIDTH, GameRules.INNER_HALF_LENGTH,
			GameRules.INNER_CORNER_RADIUS,
			GameRules.CORNER_CENTER_X, GameRules.CORNER_CENTER_Z)
	native.set_puck_params(
			GameRules.PUCK_BOARD_BOUNCE, GameRules.PUCK_BOARD_FRICTION,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.GRAVITY_M_S2,
			AITrajectory.PUCK_REST_HEIGHT_M)
	native.set_net_geometry(
			GameRules.GOAL_LINE_Z, GameRules.NET_HALF_WIDTH,
			GameRules.NET_POST_RADIUS, GameRules.NET_DEPTH,
			GameRules.NET_BACK_HALF_WIDTH, GameRules.NET_HEIGHT,
			GameRules.NET_CROWN_HALF_WIDTH, GameRules.NET_MOUTH_CORNER_RADIUS,
			GameRules.NET_TOP_DEPTH,
			GameRules.PUCK_COLLISION_HALF_HEIGHT,
			PuckGeometryCollision.POST_RESTITUTION,
			PuckGeometryCollision.NET_RESTITUTION)
	native.set_substep_params(
			PuckAuthorityRules.FRAME_SUBSTEP_RANGE_Z,
			PuckAuthorityRules.FRAME_SUBSTEP_M,
			PuckAuthorityRules.MAX_FRAME_SUBSTEPS)
	return native


# Random puck state, biased toward the goal frame where the branchy geometry
# lives (~15% right at a mouth corner, ~45% elsewhere near a net, ~40% open ice),
# with a healthy airborne share. The corner bucket is explicit because the bend
# band is only ~10 cm on a side — the general near-net bias reaches it, but too
# rarely to fuzz a branch that decides top-corner goals.
func _random_state() -> Array:
	var pos: Vector3
	var roll: float = _rng.randf()
	if roll < 0.15:
		var corner_end: float = 1.0 if _rng.randf() < 0.5 else -1.0
		var corner_side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		pos = Vector3(
				corner_side * _rng.randf_range(
						GameRules.NET_CROWN_HALF_WIDTH - 0.15,
						GameRules.NET_HALF_WIDTH + 0.15),
				_rng.randf_range(
						GameRules.NET_HEIGHT - GameRules.NET_MOUTH_CORNER_RADIUS - 0.15,
						GameRules.NET_HEIGHT + 0.15),
				corner_end * _rng.randf_range(
						GameRules.GOAL_LINE_Z - 0.3, GameRules.GOAL_LINE_Z + 0.3))
	elif roll < 0.6:
		var end_sign: float = 1.0 if _rng.randf() < 0.5 else -1.0
		pos = Vector3(
				_rng.randf_range(-2.5, 2.5),
				0.0175 if _rng.randf() < 0.5 else _rng.randf_range(0.0175, 2.0),
				end_sign * _rng.randf_range(GameRules.GOAL_LINE_Z - 2.0,
						GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH + 0.5))
	else:
		pos = Vector3(
				_rng.randf_range(-12.8, 12.8),
				0.0175 if _rng.randf() < 0.7 else _rng.randf_range(0.0175, 2.5),
				_rng.randf_range(-29.8, 29.8))
	var speed: float = _rng.randf_range(0.0, 38.0)
	var dir: float = _rng.randf_range(-PI, PI)
	var vel := Vector3(sin(dir) * speed, 0.0, cos(dir) * speed)
	if pos.y > 0.02 or _rng.randf() < 0.3:
		vel.y = _rng.randf_range(-8.0, 8.0)
	return [pos, vel]


func test_frame_substeps_matches_native() -> void:
	if _native_missing():
		return
	var native: RefCounted = _make_native()
	for i: int in 2000:
		var pos_z: float = _rng.randf_range(-30.0, 30.0)
		var speed: float = _rng.randf_range(0.0, 60.0)
		var dt: float = 1.0 / 120.0
		var gd: int = PuckAuthorityRules.frame_substeps(pos_z, speed, dt)
		var cpp: int = native.frame_substeps(pos_z, speed, dt)
		if gd != cpp:
			fail_test("frame_substeps diverged at iter %d: gd=%d cpp=%d z=%f speed=%f" % [
					i, gd, cpp, pos_z, speed])
			return
	pass_test("2000 frame_substeps cases identical")


func test_step_frame_substep_matches_native() -> void:
	if _native_missing():
		return
	var native: RefCounted = _make_native()
	var scratch := PuckGeometryCollision.Result.new()
	var out := PuckAuthorityRules.TickResult.new()
	for i: int in 3000:
		var state: Array = _random_state()
		var pos: Vector3 = state[0]
		var vel: Vector3 = state[1]
		var sub_dt: float = (1.0 / 120.0) / float(_rng.randi_range(1, 16))

		out.touched_post = false
		out.touched_net = false
		PuckAuthorityRules.step_frame_substep(pos, vel, sub_dt,
				GameRules.PUCK_COLLISION_RADIUS, 38.0, 0.0175, 3.0, scratch, out)
		native.clear_touched()
		native.step_frame_substep(pos, vel, sub_dt,
				GameRules.PUCK_COLLISION_RADIUS, 38.0, 0.0175, 3.0)

		var pos_err: float = out.position.distance_to(native.get_position())
		var vel_err: float = out.velocity.distance_to(native.get_velocity())
		if pos_err > TOLERANCE or vel_err > TOLERANCE \
				or out.touched_post != native.get_touched_post() \
				or out.touched_net != native.get_touched_net():
			fail_test(("substep diverged at iter %d: pos_err=%f vel_err=%f " +
					"post gd=%s cpp=%s net gd=%s cpp=%s from pos=%s vel=%s") % [
					i, pos_err, vel_err, out.touched_post, native.get_touched_post(),
					out.touched_net, native.get_touched_net(), pos, vel])
			return
	pass_test("3000 step_frame_substep fuzz cases within %f" % TOLERANCE)


# Long rollouts through the full tick composition (frame_substeps × substep),
# comparing every tick — regime transitions (airborne→landing, carom chains,
# net entry) must line up over hundreds of consecutive steps.
func test_step_tick_rollouts_match_native() -> void:
	if _native_missing():
		return
	var native: RefCounted = _make_native()
	var scratch := PuckGeometryCollision.Result.new()
	var out := PuckAuthorityRules.TickResult.new()
	var dt: float = 1.0 / 120.0
	for rollout: int in 25:
		var state: Array = _random_state()
		var pos: Vector3 = state[0]
		var vel: Vector3 = state[1]
		for tick: int in 240:
			var n: int = PuckAuthorityRules.frame_substeps(pos.z, vel.length(), dt)
			var sub_dt: float = dt / float(n)
			out.touched_post = false
			out.touched_net = false
			var gp: Vector3 = pos
			var gv: Vector3 = vel
			for s: int in n:
				PuckAuthorityRules.step_frame_substep(gp, gv, sub_dt,
						GameRules.PUCK_COLLISION_RADIUS, 38.0, 0.0175, 3.0, scratch, out)
				gp = out.position
				gv = out.velocity

			native.clear_touched()
			native.step_tick(pos, vel, dt, GameRules.PUCK_COLLISION_RADIUS, 38.0, 0.0175, 3.0)

			var pos_err: float = gp.distance_to(native.get_position())
			var vel_err: float = gv.distance_to(native.get_velocity())
			if pos_err > TOLERANCE or vel_err > TOLERANCE \
					or out.touched_post != native.get_touched_post() \
					or out.touched_net != native.get_touched_net():
				fail_test("rollout %d tick %d diverged: pos_err=%f vel_err=%f" % [
						rollout, tick, pos_err, vel_err])
				return
			# Both continue from the GDScript state so a sub-tolerance residual
			# can't compound across the comparison.
			pos = gp
			vel = gv
	pass_test("25 rollouts x 240 ticks in lockstep within %f" % TOLERANCE)


func test_obb_contact_matches_native() -> void:
	if _native_missing():
		return
	var native: RefCounted = _make_native()
	var result := SweptDiscOBB.Result.new()
	for i: int in 3000:
		# Random box near the origin, random short sweep around it — mix of
		# clean hits, misses, parallel slabs, and start-inside contacts.
		var box_pos := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.0, 1.5),
				_rng.randf_range(-1.0, 1.0))
		var box_basis := Basis.from_euler(Vector3(
				_rng.randf_range(-PI, PI), _rng.randf_range(-PI, PI), _rng.randf_range(-PI, PI)))
		var xform := Transform3D(box_basis, box_pos)
		var half := Vector3(_rng.randf_range(0.05, 0.6), _rng.randf_range(0.05, 0.6),
				_rng.randf_range(0.05, 0.6))
		var prev := Vector3(_rng.randf_range(-2.0, 2.0), _rng.randf_range(0.0, 2.0),
				_rng.randf_range(-2.0, 2.0))
		var curr: Vector3 = prev
		if _rng.randf() < 0.9:
			curr = prev + Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.5, 0.5),
					_rng.randf_range(-1.0, 1.0))
		var radius: float = _rng.randf_range(0.02, 0.1)

		var gd_hit: bool = SweptDiscOBB.contact(prev, curr, radius, xform, half, result)
		var cpp_hit: bool = native.obb_contact(prev, curr, radius, xform, half)
		if gd_hit != cpp_hit:
			fail_test("obb hit mismatch at iter %d: gd=%s cpp=%s" % [i, gd_hit, cpp_hit])
			return
		if gd_hit:
			var toi_err: float = absf(result.toi - native.get_obb_toi())
			var point_err: float = result.point.distance_to(native.get_obb_point())
			var normal_err: float = result.normal.distance_to(native.get_obb_normal())
			var depth_err: float = absf(result.depth - native.get_obb_depth())
			if toi_err > TOLERANCE or point_err > TOLERANCE \
					or normal_err > TOLERANCE or depth_err > TOLERANCE:
				fail_test("obb contact diverged at iter %d: toi=%f point=%f normal=%f depth=%f" % [
						i, toi_err, point_err, normal_err, depth_err])
				return
	pass_test("3000 obb_contact fuzz cases within %f" % TOLERANCE)
