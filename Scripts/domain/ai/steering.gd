class_name AISteering

# Pure potential-field steering. Stateless, side-effect-free, GUT-testable.
# Used by SkaterAgent to convert (self_pos, anchor, teammates, rink) into a
# move_vector that SkaterController._apply_movement consumes.
#
# Convention: move_vector is world-space XZ packed as Vector2(x, z), unit
# magnitude or less. SkaterMovementRules.apply_movement does
#   thrust_dir = Vector3(move.x, 0, move.y)
# i.e. it treats Vector2.y as world Z. Do NOT pre-rotate by facing.
#
# Phase 3 cut: attract to anchor + repel teammates + repel boards. Opponent
# repel, shot-lane repel, and context-ring danger gating land in later
# phases.

# Tuning constants. Single global profile (not per-skill).
const TEAMMATE_REPEL_WEIGHT: float = 0.4
const TEAMMATE_REPEL_RADIUS: float = 3.0
const BOARD_REPEL_WEIGHT: float = 0.5
const BOARD_REPEL_DISTANCE: float = 1.5
# Below this distance to anchor we stop attracting and let friction settle
# the bot — prevents jittering across the anchor at high speed.
const ANCHOR_DEADBAND: float = 0.5


# Returns a unit-or-shorter Vector2 in world XZ.
# `teammate_positions` should NOT include the bot's own position.
static func compute_move_vector(
		self_pos: Vector3,
		anchor: Vector3,
		teammate_positions: Array[Vector3],
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

	# Clamp to unit length so move_vector behaves like a joystick.
	var v := Vector2(force_x, force_z)
	if v.length() > 1.0:
		v = v.normalized()
	return v
