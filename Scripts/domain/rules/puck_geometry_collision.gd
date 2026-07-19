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
# are ABOVE the current loft ceiling (the puck tops ~1.14 m, under the 1.19 m crossbar
# underside) so they never fire at today's tuning — they're authored anyway so raising the
# loft ceiling later needs no new collision. A post hit is 2D in XZ (circle vs circle); the
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
	var combined_r: float = puck_radius + GameRules.NET_POST_RADIUS
	var puck_xz := Vector2(pos.x, pos.z)
	for post_x: float in [GameRules.NET_HALF_WIDTH, -GameRules.NET_HALF_WIDTH]:
		var post_xz := Vector2(post_x, end_z)
		var offset := puck_xz - post_xz
		var d: float = offset.length()
		if d >= combined_r or d < 1e-6:
			continue
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
	return false


# Resolve a puck against the CROSSBAR — a horizontal pipe (axis along X) at y = NET_HEIGHT,
# z = ±GOAL_LINE_Z, spanning |x| <= NET_CROWN_HALF_WIDTH. The test is 2D in the Y-Z plane:
# circle (puck) vs circle (pipe). Reflects the Y-Z velocity at POST_RESTITUTION, keeping the
# along-bar X channel. NOTE: unreachable at current tuning — the loft ceiling tops the puck
# at ~1.14 m, under the 1.19 m crossbar underside — so this never fires today; it's authored
# so raising the loft ceiling later needs no new collision. Puck treated as a sphere of
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
