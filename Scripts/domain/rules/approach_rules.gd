class_name ApproachRules

# Pure math for the faceoff / intro skate-in "approach": moving a skater from a
# start point to its faceoff dot along a deterministic eased path over the
# FACEOFF_PREP window, instead of teleport-snapping. No engine or controller
# access — callers pass the endpoints and a normalized progress t, and feed the
# returned position into the body while deriving velocity from consecutive
# samples (so the existing velocity-driven gait strides naturally on top).
#
# Determinism is the whole point: position is a pure function of (start, target,
# t), so the host and every client compute the identical path with reconcile
# off during the locked phase. The authoritative teleport at the DROP guarantees
# convergence regardless of any start-point disagreement.

# Fraction of the path over which the body still faces its travel direction;
# past this the facing blends to the squared-up dot facing so the skater settles
# into the ready stance pointed at the puck.
const FACING_SETTLE_START: float = 0.72

# Below this planar start→target distance the skater is treated as already in
# place — no travel facing, just hold the settle facing (covers a player who
# spawns/stands on the dot).
const STATIONARY_EPSILON_M: float = 0.05


# Smoothstep-eased position along the straight start→target segment. Ease-in-out
# so the skater accelerates off the start and settles into the dot rather than
# translating at a constant slab velocity. t is clamped to [0, 1].
static func path_position(start: Vector3, target: Vector3, t01: float) -> Vector3:
	var t: float = clampf(t01, 0.0, 1.0)
	var eased: float = smoothstep(0.0, 1.0, t)
	return start.lerp(target, eased)


# Facing the skater should adopt at progress t: travel direction (XZ) for the
# first FACING_SETTLE_START of the path, then blended toward settle_facing (the
# team's dot facing) over the remainder. Returns a normalized Vector2, or
# settle_facing when the path is degenerate (start == target). settle_facing is
# assumed already normalized (PlayerRules.faceoff_facing output).
static func path_facing(start: Vector3, target: Vector3, t01: float,
		settle_facing: Vector2) -> Vector2:
	var travel: Vector2 = Vector2(target.x - start.x, target.z - start.z)
	if travel.length() < STATIONARY_EPSILON_M:
		return settle_facing
	var travel_dir: Vector2 = travel.normalized()
	if settle_facing == Vector2.ZERO:
		return travel_dir
	var t: float = clampf(t01, 0.0, 1.0)
	if t <= FACING_SETTLE_START:
		return travel_dir
	var blend: float = smoothstep(FACING_SETTLE_START, 1.0, t)
	var mixed: Vector2 = travel_dir.lerp(settle_facing, blend)
	if mixed.length() < STATIONARY_EPSILON_M:
		# travel_dir and settle_facing are near-opposite; snap to the target
		# facing rather than returning a zero vector the caller can't use.
		return settle_facing
	return mixed.normalized()
