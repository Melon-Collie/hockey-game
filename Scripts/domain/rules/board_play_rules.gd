class_name BoardPlayRules

# Pure geometry for a carrier working the boards.
#
# A player pinned on the wall does not keep squaring up to the puck and reaching
# through the glass — they turn parallel to the boards and shield the puck with
# their body. Modelling that as a FACING bias reproduces the posture without
# taking aim away: the torso still twists toward the cursor (up to
# upper_body_max_twist_deg) and the blade IK still tracks it, so only the stance
# rotates. Turning parallel is also what genuinely lengthens the reach available
# along the wall, which is why a real player does it — the shield and the
# mechanical payoff are the same motion.

# Inward board normal scaled by closeness, for a skater at `pos_xz`. Zero when
# nothing is within `probe`; otherwise a vector pointing away from the nearest
# board surface whose length runs 0 (boards exactly `probe` away) → 1 (against
# them).
#
# Derived from the boundary clamp rather than a distance formula: projecting
# onto a boundary inset by `probe` yields the inward normal AND the penetration
# depth in one step, and inherits the rounded corners exactly.
static func board_proximity(pos_xz: Vector2, probe: float) -> Vector2:
	if probe <= 0.0:
		return Vector2.ZERO
	var correction: Vector2 = GameRules.clamp_to_rink_inner(pos_xz, probe) - pos_xz
	var depth: float = correction.length()
	if depth < 0.0001:
		return Vector2.ZERO
	return correction * (clampf(depth / probe, 0.0, 1.0) / depth)

# Rotates `desired` (unit, world XZ) away from the boards toward the along-wall
# direction it already leans to, by at most `max_turn_rad`, ramped by how close
# the boards are. `proximity` is a board_proximity() result.
#
# Only a facing that points INTO the wall is turned — skating out of the corner
# is never fought — and the turn stops at parallel, so the stance can shield but
# never ends up facing away from the play.
static func board_shield_facing(
		desired: Vector2, proximity: Vector2, max_turn_rad: float) -> Vector2:
	var closeness: float = proximity.length()
	if closeness < 0.0001 or max_turn_rad <= 0.0 or desired.length_squared() < 0.0001:
		return desired
	var inward: Vector2 = proximity / closeness
	if desired.dot(inward) >= 0.0:
		return desired
	# The two along-wall directions are ±perpendicular to the inward normal; take
	# the one the skater is already closer to so the shield turn is the short way
	# round and never spins them through the boards.
	var along := Vector2(-inward.y, inward.x)
	if desired.dot(along) < 0.0:
		along = -along
	var turn: float = desired.angle_to(along)
	return desired.rotated(clampf(turn, -max_turn_rad, max_turn_rad) * closeness).normalized()
