class_name PuckObstacleCollision

# Analytic puck-vs-drill-obstacle collision: oriented boxes registered at runtime
# that the loose puck bounces off, on top of the fixed geometry set (boards, goal
# frame, net panels, goalie) the analytic sim otherwise knows about.
#
# This exists for the tutorial/drill saucer board — the knee-high wall laid across
# a lane so a flat shot or pass can't get through, giving LOW loft a reason to
# exist. The puck never reaches the engine solver, so a StaticBody3D across the
# lane stops nothing; the obstacle has to be described to the analytic step the
# same way the net and the goalie are.
#
# The list is empty in a match. Both step paths test `is_empty()` before entering
# here, so an obstacle-free tick costs one array read and no allocation.
#
# Pure / static — headless-testable, allocation-free on the per-tick path (fills a
# caller-owned Result rather than returning a fresh object).

# Restitution for the drill board. Below the goal pipe's 0.55: this is a padded
# practice barrier, not iron — a flat shot into it should drop and sit shootable
# rather than rocket back at the shooter.
const BOARD_RESTITUTION: float = 0.35


# One oriented box. `transform` is the world transform of the box CENTRE (matching
# SweptDiscOBB's convention), `half_extents` its BoxShape3D size × 0.5. Mutable
# and reused by the registering node — a drill re-stages the same wall each round.
class Obstacle:
	var transform: Transform3D = Transform3D.IDENTITY
	var half_extents: Vector3 = Vector3.ZERO
	var restitution: float = BOARD_RESTITUTION


class Result:
	var hit: bool = false
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO


# Resolve the swept segment prev→pos against every obstacle, nearest contact first.
# Returns false (leaving `result` echoing the inputs) when nothing is hit.
#
# On a hit the puck is placed at the contact point ejected clear of the box and its
# velocity reflected about the contact normal. Only the NEAREST contact is resolved
# per call; a puck that would clip a second box in the same segment resolves it on
# the next sub-step, exactly as the net panels' corner case does.
#
# `scratch` is a caller-owned SweptDiscOBB.Result.
static func resolve(prev: Vector3, pos: Vector3, vel: Vector3, puck_radius: float,
		obstacles: Array, scratch: SweptDiscOBB.Result, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	if obstacles.is_empty():
		return false
	var best_toi: float = INF
	var best_point: Vector3 = Vector3.ZERO
	var best_normal: Vector3 = Vector3.ZERO
	var best_depth: float = 0.0
	var best_restitution: float = BOARD_RESTITUTION
	for obstacle: Obstacle in obstacles:
		if obstacle == null:
			continue
		if not SweptDiscOBB.contact(prev, pos, puck_radius,
				obstacle.transform, obstacle.half_extents, scratch):
			continue
		if scratch.toi >= best_toi:
			continue
		best_toi = scratch.toi
		best_point = scratch.point
		best_normal = scratch.normal
		best_depth = scratch.depth
		best_restitution = obstacle.restitution
	if best_toi == INF:
		return false
	# A separating puck is left alone — the same guard reflect_3d applies. Without
	# it, a puck resting against the board re-reflects every sub-step and buzzes
	# along the face instead of sitting still.
	if vel.dot(best_normal) >= 0.0:
		# Still eject a resting puck out of the box so it can't sink into it.
		if best_depth > 0.0:
			result.hit = true
			result.position = best_point + best_normal * best_depth
			return true
		return false
	# `depth` already measures penetration into the radius-expanded box, so the
	# contact point pushed out along the normal by it is the puck resting ON the
	# face — adding a further puck_radius would double-count.
	result.hit = true
	result.position = best_point + best_normal * best_depth
	result.velocity = PuckGeometryCollision.reflect_3d(vel, best_normal, best_restitution)
	return true
