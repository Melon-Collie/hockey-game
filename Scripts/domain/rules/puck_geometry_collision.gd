class_name PuckGeometryCollision

# Analytic puck-vs-goal-frame collision for the determinism migration
# (docs/netcode-determinism-migration.md). Replaces Jolt's PhysicsMaterial restitution
# bounce off the goal FRAME (posts, crossbar, top net panel) with deterministic analytic
# reflections so those bounces are client-reproducible. The goalie response stays in
# GoalieSaveRules; the back/side net panels are resolved separately.
#
# Geometry (from HockeyGoal, NHL-regulation): posts are vertical cylinders at
# x = ±GameRules.NET_HALF_WIDTH, z = ±GameRules.GOAL_LINE_Z, radius GameRules.NET_POST_RADIUS,
# spanning y ∈ [0, NET_HEIGHT]; the crossbar is a horizontal pipe joining the post tops at
# y = NET_HEIGHT; the top net panel is the mesh roof behind it. The crossbar and top panel
# sit above the LAUNCHED loft ceiling (a clean loft shot tops ~1.14 m, under the 1.19 m
# crossbar underside) — but deflections and goalie rebounds can carry the puck higher
# (Puck.max_height is 3.0), so these are reachable in live play, not dead code. A post hit is 2D in XZ (circle vs circle); the
# crossbar is 2D in Y-Z; the top panel is a horizontal-plane bounce.
#
# Pure / static — headless-testable, allocation-free on the per-tick path (fills a caller-
# owned Result rather than returning a fresh object).

# Restitution off a goal pipe — mirrors Physics/goal_pipe.tres `bounce`. Kept as named
# constants here because the analytic path no longer reads the Jolt material; a puck-side
# mirror guard (like GameRules.PUCK_BOARD_BOUNCE ↔ boards.tres) should pin the pairs.
const POST_RESTITUTION: float = 0.55  # goal pipe (posts + crossbar)
const NET_RESTITUTION: float = 0.05   # net panels — mirrors Physics/goal_net.tres `bounce`


class Result:
	var hit: bool = false
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO


# General 3D reflection: rebound the INTO-surface velocity component with `restitution`,
# keep the tangential. `normal` points away from the surface (toward the puck); only an
# approaching puck (v·n < 0) is reflected — a separating one is returned unchanged, so
# re-testing a puck already ejected off a surface never re-reflects it. Used for the
# crossbar (a YZ-plane bounce) and top net panel (a Y bounce), where the horizontal-only
# deflect_velocity can't carry the vertical rebound.
static func reflect_3d(vel: Vector3, normal: Vector3, restitution: float) -> Vector3:
	var n: Vector3 = normal.normalized()
	var vn: float = vel.dot(n)
	if vn >= 0.0:
		return vel
	return vel - (1.0 + restitution) * vn * n


# Resolve a puck against the two goal posts at whichever end it's near. On contact, eject the
# disc flush against the post and reflect the into-post velocity with POST_RESTITUTION
# (tangential kept — pipes are near-frictionless). Returns true and fills `result` on a hit;
# returns false and leaves the puck untouched otherwise. Testing only the near end keeps this
# to two circle checks on the per-tick path.
static func resolve_posts(pos: Vector3, vel: Vector3, puck_radius: float, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	var end_z: float = GameRules.GOAL_LINE_Z if pos.z >= 0.0 else -GameRules.GOAL_LINE_Z
	# Cheap early-out: the puck is nowhere near this end's goal line.
	if absf(pos.z - end_z) > 1.0 + puck_radius + GameRules.NET_POST_RADIUS:
		return false
	# The pipes end at the crossbar — above it there is no post to hit (an airborne
	# puck over the bar is crossbar / top-net territory, not a phantom pipe ping).
	if pos.y > GameRules.NET_HEIGHT + puck_radius:
		return false
	# Nearer post first (per-tick path: two explicit checks, no per-call array).
	var first_x: float = GameRules.NET_HALF_WIDTH if pos.x >= 0.0 else -GameRules.NET_HALF_WIDTH
	if _resolve_one_post(pos, vel, puck_radius, first_x, end_z, result):
		return true
	return _resolve_one_post(pos, vel, puck_radius, -first_x, end_z, result)


static func _resolve_one_post(pos: Vector3, vel: Vector3, puck_radius: float,
		post_x: float, end_z: float, result: Result) -> bool:
	var combined_r: float = puck_radius + GameRules.NET_POST_RADIUS
	var post_xz := Vector2(post_x, end_z)
	var offset := Vector2(pos.x, pos.z) - post_xz
	var d: float = offset.length()
	if d >= combined_r or d < 1e-6:
		return false
	# Contact: surface normal points from the post out toward the puck.
	var n := offset / d
	var n3 := Vector3(n.x, 0.0, n.y)
	# Eject flush against the post, then reflect the horizontal velocity with restitution
	# (deflect_velocity is horizontal-only, so carry the vertical channel through unchanged).
	var ejected: Vector2 = post_xz + n * combined_r
	var reflected_h: Vector3 = PuckCollisionRules.deflect_velocity(vel, n3, POST_RESTITUTION)
	result.position = Vector3(ejected.x, pos.y, ejected.y)
	result.velocity = Vector3(reflected_h.x, vel.y, reflected_h.z)
	result.hit = true
	return true


# Resolve a puck against the CROSSBAR — a horizontal pipe (axis along X) at y = NET_HEIGHT,
# z = ±GOAL_LINE_Z, spanning |x| <= NET_CROWN_HALF_WIDTH. The test is 2D in the Y-Z plane:
# circle (puck) vs circle (pipe). Reflects the Y-Z velocity at POST_RESTITUTION, keeping the
# along-bar X channel. Launched loft tops out under the bar (~1.14 m vs the 1.19 m
# underside), but deflections / goalie rebounds can arrive higher, so this does fire in
# live play. Puck treated as a sphere of
# puck_radius here (the flat disc is oblate in Y-Z, so this is slightly generous vertically —
# harmless for a top-corner edge case).
static func resolve_crossbar(pos: Vector3, vel: Vector3, puck_radius: float, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	if absf(pos.x) > GameRules.NET_CROWN_HALF_WIDTH:
		return false
	var end_z: float = GameRules.GOAL_LINE_Z if pos.z >= 0.0 else -GameRules.GOAL_LINE_Z
	var combined_r: float = puck_radius + GameRules.NET_POST_RADIUS
	var dyz := Vector2(pos.y - GameRules.NET_HEIGHT, pos.z - end_z)
	var d: float = dyz.length()
	if d >= combined_r or d < 1e-6:
		return false
	var n := dyz / d  # (y, z)
	var ejected: Vector2 = Vector2(GameRules.NET_HEIGHT, end_z) + n * combined_r
	result.position = Vector3(pos.x, ejected.x, ejected.y)
	result.velocity = reflect_3d(vel, Vector3(0.0, n.x, n.y), POST_RESTITUTION)
	result.hit = true
	return true


# Resolve a puck against the TOP NET PANEL — a horizontal mesh plane at y = NET_HEIGHT over
# the net roof (|x| <= NET_CROWN_HALF_WIDTH, |z| in [GOAL_LINE_Z, GOAL_LINE_Z + NET_TOP_DEPTH]).
# Vertical contact uses the puck's half-height (the flat disc's vertical reach), and the
# vertical channel rebounds at NET_RESTITUTION (twine absorbs), keeping horizontal motion.
# Also unreachable at current loft tuning — authored for the same future-proofing reason as
# the crossbar.
static func resolve_top_net(pos: Vector3, vel: Vector3, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	if absf(pos.x) > GameRules.NET_CROWN_HALF_WIDTH:
		return false
	var az: float = absf(pos.z)
	if az < GameRules.GOAL_LINE_Z or az > GameRules.GOAL_LINE_Z + GameRules.NET_TOP_DEPTH:
		return false
	if absf(pos.y - GameRules.NET_HEIGHT) >= GameRules.PUCK_COLLISION_HALF_HEIGHT:
		return false
	# Normal points from the plane toward the puck; on-plane exactly → treat as the underside.
	var side: float = signf(pos.y - GameRules.NET_HEIGHT)
	if side == 0.0:
		side = -1.0
	result.position = Vector3(pos.x, GameRules.NET_HEIGHT + side * GameRules.PUCK_COLLISION_HALF_HEIGHT, pos.z)
	result.velocity = reflect_3d(vel, Vector3(0.0, side, 0.0), NET_RESTITUTION)
	result.hit = true
	return true


# The trapezoid half-width of the net cavity at |z| = az (mesh surface, no radius margin):
# NET_HALF_WIDTH at the mouth widening to NET_BACK_HALF_WIDTH at the back.
static func _cavity_half_width(az: float) -> float:
	var depth_t: float = clampf((az - GameRules.GOAL_LINE_Z) / GameRules.NET_DEPTH, 0.0, 1.0)
	return lerpf(GameRules.NET_HALF_WIDTH, GameRules.NET_BACK_HALF_WIDTH, depth_t)


# True when a puck at `p` is on the INTERIOR side of the netting — inside the cavity, or in
# front of the goal line within the open mouth (about to enter the way a scored puck does).
# The sub-stepped drive keeps the previous sample within ~4 cm of any crossing, so this
# local classification of the segment START decides which face of the twine the puck is on.
static func _interior_or_mouth(p: Vector3, puck_radius: float) -> bool:
	if p.y > GameRules.NET_HEIGHT:
		return false
	var az: float = absf(p.z)
	if az <= GameRules.GOAL_LINE_Z:
		# In front of the goal-line plane: the only interior entry is the open mouth.
		return absf(p.x) <= GameRules.NET_HALF_WIDTH
	if az >= GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH + puck_radius:
		return false
	return absf(p.x) < _cavity_half_width(az)


# Resolve a puck against the back and side net-mesh panels — TWO-SIDED, like the twine it
# models. Which face applies is classified from the segment START (`prev`, see
# _interior_or_mouth): a puck that entered through the open mouth (a scored puck, a
# bounce-out) plays the INTERIOR faces — clamped inside the trapezoid cavity (depth
# NET_DEPTH, widening from NET_HALF_WIDTH at the mouth to NET_BACK_HALF_WIDTH at the back;
# the mouth itself is open so it can bounce back out). A puck OUTSIDE the netting (a
# wraparound rounding the cage, a rim pressing the back mesh) plays the EXTERIOR faces and
# is reflected away — it must never be pulled through the twine into the cavity (the
# pre-fix one-sided clamp teleported exactly those pucks inside). Rebounds absorb hard
# (NET_RESTITUTION); the existing NET_STUCK / settle logic drops a dead puck to the ice.
# Both a back and a side contact can apply in one interior tick (a shot into the corner).
static func resolve_net_panels(prev: Vector3, pos: Vector3, vel: Vector3,
		puck_radius: float, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	var az: float = absf(pos.z)
	# Nowhere near the netting: past the goal line out to the back mesh (+ radius),
	# under the roof (the top panel owns y ≥ NET_HEIGHT).
	if az <= GameRules.GOAL_LINE_Z or az > GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH + puck_radius:
		return false
	if absf(pos.x) > GameRules.NET_BACK_HALF_WIDTH + puck_radius or pos.y > GameRules.NET_HEIGHT:
		return false
	var p: Vector3 = pos
	var v: Vector3 = vel
	var hit: bool = false
	var end_sign: float = signf(pos.z)
	if _interior_or_mouth(prev, puck_radius):
		# INTERIOR faces (a puck that came in through the mouth).
		var back_limit: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH - puck_radius
		if absf(p.z) > back_limit:
			p.z = end_sign * back_limit
			v = reflect_3d(v, Vector3(0.0, 0.0, -end_sign), NET_RESTITUTION)
			hit = true
		var side_limit: float = _cavity_half_width(absf(p.z)) - puck_radius
		if absf(p.x) > side_limit:
			var x_sign: float = signf(p.x)
			p.x = x_sign * side_limit
			v = reflect_3d(v, Vector3(-x_sign, 0.0, 0.0), NET_RESTITUTION)
			hit = true
	else:
		# EXTERIOR faces (a puck outside the netting). Resolve the face whose plane
		# the segment is crossing from ITS side; a diagonal corner case resolves one
		# face now and the other on the next ≤4 cm sub-step.
		var back_plane: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH
		if absf(prev.z) >= back_plane and az < back_plane + puck_radius:
			# Behind the back mesh, pressing toward the goal line: reflect off the
			# exterior back face.
			p.z = end_sign * (back_plane + puck_radius)
			v = reflect_3d(v, Vector3(0.0, 0.0, end_sign), NET_RESTITUTION)
			hit = true
		else:
			var side_surface_prev: float = _cavity_half_width(absf(prev.z))
			var side_surface: float = _cavity_half_width(az)
			if absf(prev.x) >= side_surface_prev and absf(p.x) < side_surface + puck_radius:
				# Beside the cage, pressing inward: reflect off the exterior side face.
				var x_sign: float = 1.0 if prev.x >= 0.0 else -1.0
				p.x = x_sign * (side_surface + puck_radius)
				v = reflect_3d(v, Vector3(x_sign, 0.0, 0.0), NET_RESTITUTION)
				hit = true
	if hit:
		result.hit = true
		result.position = p
		result.velocity = v
	return hit
