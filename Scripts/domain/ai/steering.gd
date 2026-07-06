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

# Teammate spacing. Bumped from the original 0.4 / 3.0 m — bots
# clumped in puck battles where several role search-centers converge
# on the same area, so the soft field now pushes apart sooner (larger
# radius) and harder (higher weight). Still kept below the opponent
# repel weight (0.6): maintaining space against a checker matters more
# than against your own formation. Tuning: raise the weight toward the
# opponent value if bots still bunch; lower toward 0.4 if formation
# spacing feels too loose (give-and-go support drifting wide).
const TEAMMATE_REPEL_WEIGHT: float = 0.55
const TEAMMATE_REPEL_RADIUS: float = 3.5
const OPPONENT_REPEL_WEIGHT: float = 0.6
# Carrier-specific opponent repel weight. Bots with the puck weight
# defender proximity much more heavily than off-puck bots — a defender
# 3 m away is a poke threat to a carrier, but just a body-in-the-way
# to a teammate maintaining formation. Doubling the weight means the
# carrier curves AROUND nearby defenders instead of brushing past
# them on the way to the slot.
const OPPONENT_REPEL_WEIGHT_CARRY: float = 1.2
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
# Net detour — route a bot that's behind a goal line back around the
# post instead of letting the anchor pull drag its body straight
# through the net frame. The potential field has no obstacle for the
# net itself (crease repel zeroes out behind the goal line), so a
# carrier that ends up behind a net — its own or the opponent's —
# drives straight at it, jams the body, and (when it's the own net)
# shoves the puck into the mesh. Bots never INTEND to be behind the
# line: carry candidates are clamped to the goal-line buffer, so this
# only ever fires on an overshoot or a loose-puck pickup, where the
# correct play is to skate out past the post and come around the
# front. While behind the line and laterally within the post span,
# push hard toward the nearer post side (with a slight outward bias so
# the body keeps its depth and rounds the post rather than pressing
# into the frame as the inward anchor pull fights it). Releases the
# instant the bot clears the post laterally, gets in front of the
# line, or its target is itself behind the line (a deliberate
# loose-puck retrieval needs no detour).
const NET_DETOUR_LATERAL_WEIGHT: float = 1.5
const NET_DETOUR_BACK_WEIGHT: float = 0.5
# Lateral clearance past the post before the detour releases.
const NET_DETOUR_POST_MARGIN: float = 0.4
# How far in front of the goal line the detour still engages — the body
# has depth, so start rounding a touch before the line, not only behind.
const NET_DETOUR_FRONT_MARGIN: float = 0.3
# Below this distance to anchor we stop attracting and let friction settle
# the bot — prevents jittering across the anchor at high speed.
const ANCHOR_DEADBAND: float = 0.5

# Brake-pivot thresholds. When the bot wants to head one direction but is
# carrying meaningful speed in roughly the opposite direction (angle
# between velocity and desired direction exceeds BRAKE_PIVOT_ANGLE_DEG),
# it presses the BRAKE input — stop hard first, then accelerate toward the
# new direction once speed has dropped below BRAKE_PIVOT_MIN_SPEED. Cuts
# the wide arcs bots used to trace on near-180° transitions (puck flip,
# opp turnover) down to a tight pivot. The engage threshold is well past
# 90° so normal course corrections (a defender stepping to angle, anchor
# drifting cross-ice) don't trigger it; the release threshold sits below
# it as hysteresis so a wobbling steering field can't strobe the brake.
const BRAKE_PIVOT_ANGLE_DEG: float = 120.0
const BRAKE_PIVOT_RELEASE_ANGLE_DEG: float = 100.0
const BRAKE_PIVOT_MIN_SPEED: float = 3.0

# Offside brake. In ARCADE an attacking non-carrier whose body-center
# crosses the attacking blue line before the puck is ghosted instantly
# (single tick, no tolerance). The role-level target filter
# (AIRoleOutlet._is_offside) only keeps the chosen TARGET legal — it
# can't hold a momentum-driven body to a hard line, and the steering
# field can push the body across regardless. This is the body-level
# guard, applied to the actual move output every tick.
#
# OFFSIDE_BRAKE_DECEL_M_S2 is the braking deceleration assumed when
# estimating stopping distance — set a touch below skater thrust accel
# so the bot starts braking early enough to stop short rather than
# crossing. OFFSIDE_BRAKE_MARGIN_M is the safety gap the projected stop
# must clear the line by, since one tick over is already a ghost.
const OFFSIDE_BRAKE_DECEL_M_S2: float = 10.0
const OFFSIDE_BRAKE_MARGIN_M: float = 0.35


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
		rink_half_z: float,
		opponent_repel_weight: float = OPPONENT_REPEL_WEIGHT) -> Vector2:
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
			force_x += dx * inv_d * falloff * opponent_repel_weight
			force_z += dz * inv_d * falloff * opponent_repel_weight

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

	# Net detour — round the post when stuck behind a goal line. The
	# crease repel above zeroes out behind the line, so without this the
	# anchor pull drags the body straight through the net frame.
	var detour: Vector2 = _net_detour(self_pos, anchor)
	force_x += detour.x
	force_z += detour.y

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


# Lateral "round the post" force for a bot pinned behind a goal line.
# Returns ZERO unless the bot is at/behind a goal line AND laterally
# within the net's post span AND its anchor is on the rink side of that
# line (so it actually needs to come around). Otherwise pushes toward
# the nearer post side — at dead-center, around the side the anchor is
# on — with a small outward-Z bias so the body keeps depth and rounds
# the post instead of pressing into the frame while the inward anchor
# pull fights it. See NET_DETOUR_* constants for the rationale.
static func _net_detour(self_pos: Vector3, anchor: Vector3) -> Vector2:
	var goal_z_sign: float = signf(self_pos.z)
	if goal_z_sign == 0.0:
		return Vector2.ZERO
	var goal_z: float = goal_z_sign * GameRules.GOAL_LINE_Z
	# Inward distance from the goal line: positive in front of the net
	# (toward center ice), negative behind it.
	var inward: float = (self_pos.z - goal_z) * -goal_z_sign
	# Only engage at/behind the line (a hair in front allowed for body depth).
	if inward > NET_DETOUR_FRONT_MARGIN:
		return Vector2.ZERO
	# Already clear of the post laterally → let the anchor pull round the
	# corner on its own.
	var post_span: float = GameRules.NET_HALF_WIDTH + NET_DETOUR_POST_MARGIN
	if absf(self_pos.x) >= post_span:
		return Vector2.ZERO
	# Only detour toward a target on the rink side of this line. A target
	# also behind the line (a deliberate loose-puck retrieval / wraparound
	# setup) needs no detour.
	if (anchor.z - goal_z) * -goal_z_sign <= 0.0:
		return Vector2.ZERO
	# Push toward the nearer post side; at dead-center, go around the side
	# the play (anchor) is on.
	var side: float = signf(self_pos.x)
	if side == 0.0:
		side = signf(anchor.x)
		if side == 0.0:
			side = 1.0
	return Vector2(
			side * NET_DETOUR_LATERAL_WEIGHT,
			goal_z_sign * NET_DETOUR_BACK_WEIGHT)


# Decides whether to press the actual BRAKE input for a pivot. When the
# desired direction is roughly opposite (>= BRAKE_PIVOT_ANGLE_DEG) the
# current heading and we're carrying speed (>= BRAKE_PIVOT_MIN_SPEED),
# braking beats carving a wide arc: brake friction decelerates at least as
# hard as reverse thrust across the speed band (and unlike thrust it isn't
# scaled down by facing misalignment), and the caller keeps move_vector on
# the NEW direction — the same input shape a human uses (brake held + the
# exit direction on the stick), so the cosmetic layer reads a genuine
# hockey stop into a dig-in restart. This replaced the old `brake_pivot`
# reverse-thrust flip when bots learned the real brake key.
#
# `was_braking` is the previous tick's decision: once braking, the brake
# holds until the opposition relaxes past BRAKE_PIVOT_RELEASE_ANGLE_DEG
# (or speed drops below the pivot floor), so a steering wobble on the
# engage threshold can't strobe the brake key — a strobing brake bit
# would flicker the replicated stop pose on every client.
static func should_brake(desired: Vector2, velocity_xz: Vector2, was_braking: bool) -> bool:
	var speed: float = velocity_xz.length()
	if speed < BRAKE_PIVOT_MIN_SPEED:
		return false
	var desired_len: float = desired.length()
	if desired_len < 0.01:
		return false
	var angle_deg: float = BRAKE_PIVOT_RELEASE_ANGLE_DEG if was_braking else BRAKE_PIVOT_ANGLE_DEG
	return velocity_xz.dot(desired) / (speed * desired_len) < cos(deg_to_rad(angle_deg))


# Hard body-level guard against skating offside. Returns `desired`
# unchanged unless the bot is an attacking non-carrier moving toward its
# attacking blue line, the puck is still on the near side (entering
# would be offside), and the bot's stopping distance would carry it
# across within OFFSIDE_BRAKE_MARGIN_M. In that case it overrides the
# steering with a hard brake away from the line (full reverse thrust on
# the depth axis, lateral intent preserved), so the body stops short
# instead of ghosting. Releases the instant the puck crosses the line
# (offside risk gone) or the bot is already retreating.
#
# `own_goal_dir` is +1 when our net is at +Z (we attack -Z) and -1 when
# our net is at -Z (we attack +Z). The attacking blue line sits at
# `-own_goal_dir * BLUE_LINE_Z`; `attack_dir = -own_goal_dir` is the
# depth direction the team attacks.
static func offside_brake(
		desired: Vector2,
		self_pos: Vector3,
		self_velocity: Vector3,
		own_goal_dir: float,
		puck_z: float,
		is_carrier: bool) -> Vector2:
	if is_carrier:
		return desired
	var attack_dir: float = -own_goal_dir
	# Puck already across the attacking blue line → entering is legal now.
	if attack_dir * puck_z > GameRules.BLUE_LINE_Z:
		return desired
	# Only a concern when actually moving toward the attacking zone.
	var v_toward: float = attack_dir * self_velocity.z
	if v_toward <= 0.0:
		return desired
	# Signed distance from the body to the attacking blue line along the
	# attack direction (negative once already across).
	var dist_to_line: float = GameRules.BLUE_LINE_Z - attack_dir * self_pos.z
	var stop_dist: float = (v_toward * v_toward) / (2.0 * OFFSIDE_BRAKE_DECEL_M_S2)
	if stop_dist + OFFSIDE_BRAKE_MARGIN_M < dist_to_line:
		return desired  # plenty of room to stop before the line
	# Brake: full reverse thrust along the depth axis (back toward our
	# own end), keep lateral intent, clamp to unit length.
	var brake := Vector2(desired.x, -attack_dir)
	if brake.length() > 1.0:
		brake = brake.normalized()
	return brake
