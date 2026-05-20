class_name AISteering

# Pure potential-field steering. Stateless, side-effect-free, GUT-testable.
# Used by SkaterAgent to convert world state into a move_vector that
# SkaterController._apply_movement consumes.
#
# Convention: move_vector is world-space XZ packed as Vector2(x, z), unit
# magnitude or less. SkaterMovementRules.apply_movement does
#   thrust_dir = Vector3(move.x, 0, move.y)
# i.e. it treats Vector2.y as world Z. Do NOT pre-rotate by facing.
#
# Forces (playtest-tunable weights):
#   - Attract to anchor              (1.0)
#   - Repel from teammates           (0.4 over 3 m)
#   - Repel from opponents           (0.6 over 4 m, inverse-square falloff)
#   - Repel from boards              (0.5 within 1.5 m)
#   - Repel from own shot lanes      (0.3 within 2 m of segment)
# Sum, clamp to unit length.

const TEAMMATE_REPEL_WEIGHT: float = 0.4
const TEAMMATE_REPEL_RADIUS: float = 3.0
const OPPONENT_REPEL_WEIGHT: float = 0.6
const OPPONENT_REPEL_RADIUS: float = 4.0
const BOARD_REPEL_WEIGHT: float = 0.5
const BOARD_REPEL_DISTANCE: float = 2.0
const SHOT_LANE_REPEL_WEIGHT: float = 0.3
const SHOT_LANE_REPEL_RADIUS: float = 2.0
# Crease repel — pushes bots out of either goalie's crease + a small
# extension radius. Strong weight: bots crashing the crease was the
# main "score-by-spamming" exploit. Falloff reaches zero outside the
# arc + CREASE_REPEL_EXTENSION; inside the arc the falloff is full
# strength so the bot is pushed firmly out. Outward direction from
# CreaseRules so the push is geometrically correct (rounds the arc
# rather than snapping to an axis).
const CREASE_REPEL_WEIGHT: float = 0.9
const CREASE_REPEL_EXTENSION: float = 0.5
# Below this distance to anchor we stop attracting and let friction settle
# the bot — prevents jittering across the anchor at high speed.
const ANCHOR_DEADBAND: float = 0.5

# Brake-pivot threshold. When the bot wants to head one direction but is
# carrying meaningful speed in roughly the opposite direction (angle
# between velocity and desired direction exceeds BRAKE_PIVOT_ANGLE_DEG),
# the steering output flips to push opposite the velocity — i.e. brake
# first, then accelerate toward the new direction once speed has dropped
# below BRAKE_PIVOT_MIN_SPEED. Cuts the wide arcs bots used to trace on
# near-180° transitions (puck flip, opp turnover) down to a tight pivot.
# Threshold is well past 90° so normal course corrections (a defender
# stepping to angle, anchor drifting cross-ice) don't trigger it.
const BRAKE_PIVOT_ANGLE_DEG: float = 120.0
const BRAKE_PIVOT_MIN_SPEED: float = 3.0


# Returns a unit-or-shorter Vector2 in world XZ.
#
# `teammate_positions` and `opponent_positions` should NOT include the
# bot's own position.
#
# `shot_lane_start` / `shot_lane_end` define the carrier→net segment our
# off-puck bots want to stay out of. Pass `Vector3.ZERO` for both to
# disable (e.g. when no own-team carrier exists). Carrier-side bots
# pass zero too — they don't need to repel out of their own lane.
static func compute_move_vector(
		self_pos: Vector3,
		anchor: Vector3,
		teammate_positions: Array[Vector3],
		opponent_positions: Array[Vector3],
		shot_lane_start: Vector3,
		shot_lane_end: Vector3,
		rink_half_x: float,
		rink_half_z: float) -> Vector2:
	var force_x: float = 0.0
	var force_z: float = 0.0

	# Attract to anchor (unit-magnitude direction, deadband near anchor).
	var to_anchor: Vector3 = anchor - self_pos
	var anchor_dist: float = Vector2(to_anchor.x, to_anchor.z).length()
	if anchor_dist > ANCHOR_DEADBAND:
		var inv: float = 1.0 / anchor_dist
		force_x += to_anchor.x * inv
		force_z += to_anchor.z * inv

	# Repel from teammates within radius. Linear falloff with distance.
	for tp: Vector3 in teammate_positions:
		var dx: float = self_pos.x - tp.x
		var dz: float = self_pos.z - tp.z
		var d: float = sqrt(dx * dx + dz * dz)
		if d > 0.001 and d < TEAMMATE_REPEL_RADIUS:
			var falloff: float = (TEAMMATE_REPEL_RADIUS - d) / TEAMMATE_REPEL_RADIUS
			var inv_d: float = 1.0 / d
			force_x += dx * inv_d * falloff * TEAMMATE_REPEL_WEIGHT
			force_z += dz * inv_d * falloff * TEAMMATE_REPEL_WEIGHT

	# Repel from opponents within radius. Stronger weight + larger radius
	# than teammate repel — bots actively maintain space against checkers.
	for op: Vector3 in opponent_positions:
		var dx: float = self_pos.x - op.x
		var dz: float = self_pos.z - op.z
		var d: float = sqrt(dx * dx + dz * dz)
		if d > 0.001 and d < OPPONENT_REPEL_RADIUS:
			var falloff: float = (OPPONENT_REPEL_RADIUS - d) / OPPONENT_REPEL_RADIUS
			var inv_d: float = 1.0 / d
			force_x += dx * inv_d * falloff * OPPONENT_REPEL_WEIGHT
			force_z += dz * inv_d * falloff * OPPONENT_REPEL_WEIGHT

	# Repel from boards: only kicks in within BOARD_REPEL_DISTANCE of a wall.
	# Pushes inward proportionally to how close the bot is to the wall.
	var x_to_wall: float = rink_half_x - absf(self_pos.x)
	if x_to_wall < BOARD_REPEL_DISTANCE and x_to_wall > 0.0:
		var falloff_x: float = 1.0 - x_to_wall / BOARD_REPEL_DISTANCE
		force_x -= signf(self_pos.x) * BOARD_REPEL_WEIGHT * falloff_x
	var z_to_wall: float = rink_half_z - absf(self_pos.z)
	if z_to_wall < BOARD_REPEL_DISTANCE and z_to_wall > 0.0:
		var falloff_z: float = 1.0 - z_to_wall / BOARD_REPEL_DISTANCE
		force_z -= signf(self_pos.z) * BOARD_REPEL_WEIGHT * falloff_z

	# Repel from own shot lane — keep off-puck bots out of the line from
	# our carrier to the attacking goal so they don't block teammate shots.
	# Either lane endpoint being zero disables the force.
	if shot_lane_start != Vector3.ZERO or shot_lane_end != Vector3.ZERO:
		var lane: Vector2 = _shot_lane_repel(self_pos, shot_lane_start, shot_lane_end)
		force_x += lane.x
		force_z += lane.y

	# Repel from either crease — universal, no team check. Bots crashing
	# the crease and spamming was the main score-by-stacking exploit.
	var crease: Vector2 = _crease_repel(self_pos)
	force_x += crease.x
	force_z += crease.y

	# Clamp to unit length so move_vector behaves like a joystick.
	var v := Vector2(force_x, force_z)
	if v.length() > 1.0:
		v = v.normalized()
	return v


# Repel from a line segment. Only applies when the bot's projection onto
# the segment falls between the endpoints (t ∈ [0,1]) and within
# SHOT_LANE_REPEL_RADIUS perpendicular distance. Force pushes
# perpendicular-out-of-the-line.
static func _shot_lane_repel(self_pos: Vector3, lane_start: Vector3, lane_end: Vector3) -> Vector2:
	var dx: float = lane_end.x - lane_start.x
	var dz: float = lane_end.z - lane_start.z
	var len_sq: float = dx * dx + dz * dz
	if len_sq < 0.01:
		return Vector2.ZERO
	var to_self_x: float = self_pos.x - lane_start.x
	var to_self_z: float = self_pos.z - lane_start.z
	var t: float = (to_self_x * dx + to_self_z * dz) / len_sq
	if t <= 0.0 or t >= 1.0:
		return Vector2.ZERO
	var closest_x: float = lane_start.x + t * dx
	var closest_z: float = lane_start.z + t * dz
	var perp_x: float = self_pos.x - closest_x
	var perp_z: float = self_pos.z - closest_z
	var perp_dist: float = sqrt(perp_x * perp_x + perp_z * perp_z)
	if perp_dist < 0.001 or perp_dist > SHOT_LANE_REPEL_RADIUS:
		return Vector2.ZERO
	var falloff: float = (SHOT_LANE_REPEL_RADIUS - perp_dist) / SHOT_LANE_REPEL_RADIUS
	var inv_d: float = 1.0 / perp_dist
	return Vector2(
			perp_x * inv_d * falloff * SHOT_LANE_REPEL_WEIGHT,
			perp_z * inv_d * falloff * SHOT_LANE_REPEL_WEIGHT)


# Repel out of either crease + a small extension. Outward direction comes
# from CreaseRules so the force rounds the arc correctly (no axis snap
# at the corners). Returns zero outside the extended crease.
static func _crease_repel(self_pos: Vector3) -> Vector2:
	var xz := Vector2(self_pos.x, self_pos.z)
	# Quick rough cull — only check the half closest to the bot.
	var goal_z_sign: float = signf(xz.y)
	if goal_z_sign == 0.0:
		return Vector2.ZERO
	var goal_z: float = goal_z_sign * GameRules.GOAL_LINE_Z
	# Distance from goal center on this half.
	var dy_inward: float = (xz.y - goal_z) * -goal_z_sign
	if dy_inward < -CREASE_REPEL_EXTENSION:
		# Behind the goal line by more than the extension — leave alone.
		return Vector2.ZERO
	var d_to_center: float = sqrt(xz.x * xz.x + dy_inward * dy_inward)
	var threshold: float = CreaseRules.ARC_RADIUS + CREASE_REPEL_EXTENSION
	if d_to_center >= threshold:
		return Vector2.ZERO
	# Inside the threshold. Push along outward direction with falloff
	# scaled by how deep we are (0 at threshold, full at goal center).
	var dir: Vector2 = CreaseRules.outward_direction(xz)
	var falloff: float = 1.0 - (d_to_center / threshold)
	return dir * (CREASE_REPEL_WEIGHT * falloff)


# Decides between obeying the steering output or braking against current
# velocity. When the desired direction is roughly opposite (>=
# BRAKE_PIVOT_ANGLE_DEG) the current heading and we're carrying speed
# (>= BRAKE_PIVOT_MIN_SPEED), it's faster to plant and reverse than to
# carve a wide arc. Returns the original desired vector when no brake is
# needed; otherwise returns a vector opposite to velocity at the same
# magnitude as desired so the controller treats it like a normal joystick
# input. Once the brake drops speed below BRAKE_PIVOT_MIN_SPEED on a
# subsequent tick, this returns desired again and the bot accelerates
# normally toward the new direction.
static func brake_pivot(desired: Vector2, velocity_xz: Vector2) -> Vector2:
	var speed: float = velocity_xz.length()
	if speed < BRAKE_PIVOT_MIN_SPEED:
		return desired
	var desired_len: float = desired.length()
	if desired_len < 0.01:
		return desired
	var vel_dir: Vector2 = velocity_xz / speed
	var desired_dir: Vector2 = desired / desired_len
	var threshold_dot: float = cos(deg_to_rad(BRAKE_PIVOT_ANGLE_DEG))
	if vel_dir.dot(desired_dir) >= threshold_dot:
		return desired
	return -vel_dir * desired_len
