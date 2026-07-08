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


# Cubic-Hermite position along the start→target path, launched from the skater's
# live planar velocity `v0` (m/s) and arriving at rest on the dot. When v0 is
# zero this reduces exactly to the smoothstep ease-in-out (h00·start + h01·target),
# so a snap-from-rest start (bench intro / post-goal staging) is unchanged; a
# non-zero v0 (period / stoppage skate-in) flows out of the player's momentum
# instead of hard-stopping at the whistle. `duration` scales the start tangent
# (m0 = v0·duration in path units). t is clamped to [0, 1]. The start tangent is
# clamped to the chord length so a fast v0 can't overshoot past the dot — its
# lateral component still curves the path in from the side, which reads as the
# skater carrying speed and rounding into the dot.
static func path_position(start: Vector3, target: Vector3, t01: float,
		v0: Vector3 = Vector3.ZERO, duration: float = 1.0) -> Vector3:
	var t: float = clampf(t01, 0.0, 1.0)
	var t2: float = t * t
	var t3: float = t2 * t
	var h00: float = 2.0 * t3 - 3.0 * t2 + 1.0
	var h10: float = t3 - 2.0 * t2 + t
	var h01: float = -2.0 * t3 + 3.0 * t2
	# m1 = 0 (arrive at rest), so its h11 term drops out.
	var m0: Vector3 = v0 * duration
	var chord: float = start.distance_to(target)
	if m0.length() > chord and chord > 0.0:
		m0 = m0.normalized() * chord
	return h00 * start + h10 * m0 + h01 * target


# Facing for a skater travelling in world-XZ direction `travel_dir` at progress t:
# hold the travel heading for the first FACING_SETTLE_START of the path, then
# blend toward settle_facing (the squared-up dot facing) over the remainder.
# Returns a normalized Vector2, or settle_facing when travel_dir is ~zero
# (stationary). settle_facing is assumed normalized (PlayerRules.faceoff_facing).
static func facing_along(travel_dir: Vector2, t01: float,
		settle_facing: Vector2) -> Vector2:
	if travel_dir.length() < STATIONARY_EPSILON_M:
		return settle_facing
	var dir: Vector2 = travel_dir.normalized()
	if settle_facing == Vector2.ZERO:
		return dir
	var t: float = clampf(t01, 0.0, 1.0)
	if t <= FACING_SETTLE_START:
		return dir
	var blend: float = smoothstep(FACING_SETTLE_START, 1.0, t)
	var mixed: Vector2 = dir.lerp(settle_facing, blend)
	if mixed.length() < STATIONARY_EPSILON_M:
		# travel_dir and settle_facing are near-opposite; snap to the target
		# facing rather than returning a zero vector the caller can't use.
		return settle_facing
	return mixed.normalized()


# Convenience for a straight (v0 = 0) path: facing derived from the chord
# start→target. Used at t=0 to point a snap-start skater down its path.
static func path_facing(start: Vector3, target: Vector3, t01: float,
		settle_facing: Vector2) -> Vector2:
	return facing_along(
			Vector2(target.x - start.x, target.z - start.z), t01, settle_facing)
