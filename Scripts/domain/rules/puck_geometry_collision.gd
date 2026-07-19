class_name PuckGeometryCollision

# Analytic puck-vs-goal-frame collision for the determinism migration
# (docs/netcode-determinism-migration.md). Replaces Jolt's PhysicsMaterial restitution
# bounce off the goal PIPES with a deterministic swept-circle reflection so the "ping off
# the post" is client-reproducible. The goalie response stays in GoalieSaveRules; the net
# panels are resolved separately.
#
# Geometry (from HockeyGoal, NHL-regulation): the posts are vertical cylinders at
# x = ±GameRules.NET_HALF_WIDTH, z = ±GameRules.GOAL_LINE_Z, radius GameRules.NET_POST_RADIUS,
# spanning y ∈ [0, NET_HEIGHT]. Because the post spans the whole reachable puck-height range
# (loft tops out ~1.14 m, well under the 1.22 m crossbar — the crossbar is unreachable and
# not modeled), a post hit is purely 2D in XZ: circle (puck radius) vs circle (post radius).
#
# Pure / static — headless-testable, allocation-free on the per-tick path (fills a caller-
# owned PostResult rather than returning a fresh object).

# Restitution off a goal pipe — mirrors Physics/goal_pipe.tres `bounce`. Kept as a named
# constant here because the analytic path no longer reads the Jolt material; a puck-side
# mirror guard (like GameRules.PUCK_BOARD_BOUNCE ↔ boards.tres) should pin the pair.
const POST_RESTITUTION: float = 0.55


class PostResult:
	var hit: bool = false
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO


# Resolve a puck against the two goal posts at whichever end it's near. On contact, eject the
# disc flush against the post and reflect the into-post velocity with POST_RESTITUTION
# (tangential kept — pipes are near-frictionless). Returns true and fills `result` on a hit;
# returns false and leaves the puck untouched otherwise. Testing only the near end keeps this
# to two circle checks on the per-tick path.
static func resolve_posts(pos: Vector3, vel: Vector3, puck_radius: float, result: PostResult) -> bool:
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
