class_name AISteering

# Pure potential-field steering. Stateless, side-effect-free, GUT-testable.
# Used by SkaterAgent to convert world state into a move_vector that
# SkaterController._apply_movement consumes.
#
# Convention: move_vector is world-space XZ packed as Vector2(x, z), unit
# magnitude or less. SkaterMovementRules.apply_movement does
#   thrust_dir = Vector3(move.x, 0, move.y)
# i.e. it treats Vector2.y as world Z. Do NOT pre-rotate by facing.

# Teammate spacing. Deliberately below OPPONENT_REPEL_WEIGHT: holding space
# against a checker matters more than against your own formation.
const TEAMMATE_REPEL_WEIGHT: float = 0.55
const TEAMMATE_REPEL_RADIUS: float = 4.0
# How far ahead a teammate's momentum is projected when the repel reads their
# SWEPT PATH instead of their freeze-frame body (the teammate-velocity branch in
# compute_move_vector). One stride — "where they're skating into next," not a
# route prophecy — so two bots on crossing paths feel each other's line and bend
# apart before the bodies meet. Zero teammate velocity collapses the sweep to the
# body point, reducing the field to plain proximity.
const TEAMMATE_REPEL_LEAD_S: float = 0.4
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
# Crease repel. Weighted above every other repel: a bot parked in the blue paint
# is the score-by-stacking exploit, so this must win the sum outright.
const CREASE_REPEL_WEIGHT: float = 0.9
const CREASE_REPEL_EXTENSION: float = 0.5
# Net detour. The field carries no obstacle for the net frame itself — the crease
# repel zeroes out behind the goal line — so without this the anchor pull drags a
# body behind a net straight into the cage, and into its own mesh with the puck.
# Bots never INTEND to be back there (carry candidates are clamped to the
# goal-line buffer); this fires on an overshoot or a loose-puck pickup.
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

# ── Velocity-matched seek ────────────────────────────────────────────────────
# Only the CROSS component of our own velocity is cancelled — never the
# along-line speed — for two physical reasons. (1) Carry anchors are WAYPOINTS
# re-picked every re-eval and skated THROUGH at pace (the arrival brake skips
# them for the same reason); bleeding forward speed pacifies the carrier so it
# never drives a duel. (2) Subtracting the full velocity weakens thrust as the
# bot nears top speed, so friction drags it below max and the carry visibly
# slows. With no cross-drift the term reduces to the plain seek.

# ── Moving-frame pursuit (a stand that rides a man) ──────────────────────────
# Below this the anchor is not really riding anything and the seeks above are
# used instead. Passing `anchor_velocity` at all is opt-in per role (Vector3.ZERO
# is the default), so stations, carry waypoints and puck chases are untouched.
const MOVING_FRAME_MIN_SPEED: float = 0.05

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

# Arrival brake. Station-keeping bots approach a POINT that can stop moving, and
# nothing else in the field slows them: the anchor attraction is full-strength
# until the deadband, and at 9 m/s friction alone needs ~11 m to stop. Same
# stopping-distance law as the offside brake, applied to a point — when the
# CLOSING speed toward the anchor can no longer be shed inside the remaining
# distance, press the real brake. Evaluated fresh every tick, so a target still
# moving away never engages it and one that stops engages it exactly one
# stopping-distance out. Hysteresis: once braking, the release margin exceeds the
# engage margin, so shedding speed (which collapses stop_dist quadratically)
# can't strobe the brake key.
#
# Deliberately NOT applied to waypoint-style anchors — carry steps re-picked
# every re-eval, loose-puck chases (arrive at speed; momentum wins contested
# pickups), body-check commits (drive THROUGH the man) — the caller opts in per
# call site.
const ARRIVAL_BRAKE_DECEL_M_S2: float = 10.0
const ARRIVAL_BRAKE_ENGAGE_MARGIN_M: float = 0.5
const ARRIVAL_BRAKE_RELEASE_MARGIN_M: float = 1.5
const ARRIVAL_BRAKE_MIN_SPEED_M_S: float = 3.0

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
#
# `opponent_velocities` (index-matched to `opponent_positions`) switches the
# opponent repel into the CARRIER threat-gated mode — see `_carrier_threat_repel`.
# Empty (the default) keeps the plain proximity field for off-puck bots.
static func compute_move_vector(
		self_pos: Vector3,
		anchor: Vector3,
		teammate_positions: Array[Vector3],
		opponent_positions: Array[Vector3],
		shot_lane_start: Vector3,
		shot_lane_end: Vector3,
		rink_half_x: float,
		rink_half_z: float,
		opponent_repel_weight: float = OPPONENT_REPEL_WEIGHT,
		opponent_velocities: Array[Vector3] = [],
		teammate_velocities: Array[Vector3] = [],
		self_velocity: Vector3 = Vector3.ZERO,
		velocity_match_speed: float = 0.0,
		anchor_velocity: Vector3 = Vector3.ZERO) -> Vector2:
	var force_x: float = 0.0
	var force_z: float = 0.0

	# Attract to anchor. Three seams, most specific first: MOVING-FRAME pursuit
	# when the anchor rides a man (anchor_velocity supplied); the velocity-matched
	# seek when only our own cross-drift needs cancelling; the plain SEEK
	# otherwise.
	var to_anchor: Vector3 = anchor - self_pos
	var anchor_dist: float = Vector2(to_anchor.x, to_anchor.z).length()
	var moving_frame: bool = velocity_match_speed > 0.0 \
			and Vector2(anchor_velocity.x, anchor_velocity.z).length() \
					> MOVING_FRAME_MIN_SPEED \
			and is_rideable_anchor(anchor)
	if moving_frame:
		# NO deadband: holding station on a frame that is moving is itself work,
		# and a bot that stops thrusting once it is ON the stand immediately falls
		# off the back of it. The seeks below keep theirs — a spot on the ice
		# genuinely needs no thrust to stay on.
		var pursue: Vector2 = _moving_frame_pursuit(
				to_anchor, anchor_dist, anchor_velocity, self_velocity,
				velocity_match_speed)
		force_x += pursue.x
		force_z += pursue.y
	elif anchor_dist > ANCHOR_DEADBAND:
		var inv: float = 1.0 / anchor_dist
		if velocity_match_speed > 0.0:
			# Full thrust along the line to the anchor, minus the PERPENDICULAR
			# component of our velocity, renormalised to unit weight.
			var dir_x: float = to_anchor.x * inv
			var dir_z: float = to_anchor.z * inv
			var v_along: float = self_velocity.x * dir_x + self_velocity.z * dir_z
			var vp_x: float = self_velocity.x - dir_x * v_along
			var vp_z: float = self_velocity.z - dir_z * v_along
			var sx: float = dir_x - vp_x / velocity_match_speed
			var sz: float = dir_z - vp_z / velocity_match_speed
			var slen: float = sqrt(sx * sx + sz * sz)
			if slen > 1.0:
				sx /= slen
				sz /= slen
			force_x += sx
			force_z += sz
		else:
			force_x += to_anchor.x * inv
			force_z += to_anchor.z * inv

	# Repel from teammates within radius, linear falloff. With velocities supplied
	# (index-matched) the repel reads the closest point on the momentum-swept
	# segment [tp, tp + vel × TEAMMATE_REPEL_LEAD_S] instead of the body point.
	var have_tm_vels: bool = teammate_velocities.size() == teammate_positions.size()
	for i: int in teammate_positions.size():
		var tp: Vector3 = teammate_positions[i]
		var cx: float = tp.x
		var cz: float = tp.z
		if have_tm_vels:
			var sweep_x: float = teammate_velocities[i].x * TEAMMATE_REPEL_LEAD_S
			var sweep_z: float = teammate_velocities[i].z * TEAMMATE_REPEL_LEAD_S
			var sweep_len_sq: float = sweep_x * sweep_x + sweep_z * sweep_z
			if sweep_len_sq > 0.0001:
				var t: float = clampf(((self_pos.x - tp.x) * sweep_x
						+ (self_pos.z - tp.z) * sweep_z) / sweep_len_sq, 0.0, 1.0)
				cx = tp.x + sweep_x * t
				cz = tp.z + sweep_z * t
		var dx: float = self_pos.x - cx
		var dz: float = self_pos.z - cz
		var d: float = sqrt(dx * dx + dz * dz)
		if d > 0.001 and d < TEAMMATE_REPEL_RADIUS:
			var falloff: float = (TEAMMATE_REPEL_RADIUS - d) / TEAMMATE_REPEL_RADIUS
			var inv_d: float = 1.0 / d
			force_x += dx * inv_d * falloff * TEAMMATE_REPEL_WEIGHT
			force_z += dz * inv_d * falloff * TEAMMATE_REPEL_WEIGHT

	# Repel from opponents. Carrier mode (velocities supplied): threat-gated,
	# route-around — see `_carrier_threat_repel`. Otherwise the plain proximity
	# field within OPPONENT_REPEL_RADIUS (off-puck bots maintaining formation
	# space against checkers).
	if not opponent_velocities.is_empty() \
			and opponent_velocities.size() == opponent_positions.size():
		var opp_force: Vector2 = _carrier_threat_repel(
				self_pos, to_anchor, anchor_dist,
				opponent_positions, opponent_velocities, opponent_repel_weight)
		force_x += opp_force.x
		force_z += opp_force.y
	else:
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
	# Pushes inward proportionally to how close the bot is to the wall —
	# scaled by the ANCHOR's own distance from that wall: an anchor
	# deliberately AT the boards (rim reception, wall retrieval, board
	# battles) is a spot the body must actually occupy, and the unscaled
	# field held an equilibrium a step inside the wall so the blade never
	# reached the rim line. An anchor clear of the boards keeps the full
	# anti-hug field; the scale is per-axis so a wall anchor doesn't also
	# disable the END-boards repel (and vice versa).
	var x_to_wall: float = rink_half_x - absf(self_pos.x)
	if x_to_wall < BOARD_REPEL_DISTANCE and x_to_wall > 0.0:
		var anchor_x_gap: float = clampf(
				(rink_half_x - absf(anchor.x)) / BOARD_REPEL_DISTANCE, 0.0, 1.0)
		var falloff_x: float = 1.0 - x_to_wall / BOARD_REPEL_DISTANCE
		force_x -= signf(self_pos.x) * BOARD_REPEL_WEIGHT * falloff_x * anchor_x_gap
	var z_to_wall: float = rink_half_z - absf(self_pos.z)
	if z_to_wall < BOARD_REPEL_DISTANCE and z_to_wall > 0.0:
		var anchor_z_gap: float = clampf(
				(rink_half_z - absf(anchor.z)) / BOARD_REPEL_DISTANCE, 0.0, 1.0)
		var falloff_z: float = 1.0 - z_to_wall / BOARD_REPEL_DISTANCE
		force_z -= signf(self_pos.z) * BOARD_REPEL_WEIGHT * falloff_z * anchor_z_gap

	# Repel from own shot lane — keep off-puck bots out of the line from
	# our carrier to the attacking goal so they don't block teammate shots.
	# Either lane endpoint being zero disables the force.
	if shot_lane_start != Vector3.ZERO or shot_lane_end != Vector3.ZERO:
		var lane: Vector2 = _shot_lane_repel(self_pos, shot_lane_start, shot_lane_end)
		force_x += lane.x
		force_z += lane.y

	# Repel from either crease — universal, no team check.
	var crease: Vector2 = _crease_repel(self_pos)
	force_x += crease.x
	force_z += crease.y

	# Net detour — round the post when stuck behind a goal line.
	var detour: Vector2 = _net_detour(self_pos, anchor)
	force_x += detour.x
	force_z += detour.y

	# Clamp to unit length so move_vector behaves like a joystick.
	var v := Vector2(force_x, force_z)
	if v.length() > 1.0:
		v = v.normalized()
	return v


# A stand is only a FRAME to hold station in while it is somewhere a skater can
# legally stand. Off the playing surface it is not a stand at all, and holding
# station on it means matching the man's velocity with no arrival to end the
# approach — a body chasing a man off the ice rather than a defender.
#
# The failure is silent and permanent when it happens: a point seek at least
# stops at the anchor, while an unbounded ride has no terminating condition and
# no repel in the field is weighted to out-muscle a full-unit anchor term.
# Falling back to the seek recovers the ordinary behavior.
#
# Deliberately the RINK surface and not AIRoleHelpers.is_legal_position — this
# asks "can a body be here", not "should a stand be chosen here" (that one also
# excludes the crease and the goal-line buffer, which are perfectly good ice to
# be routed ACROSS).
static func is_rideable_anchor(anchor: Vector3) -> bool:
	var xz := Vector2(anchor.x, anchor.z)
	return GameRules.clamp_to_rink_inner(xz).is_equal_approx(xz)


# Track a stand that RIDES A MAN: the anchor term becomes a VELOCITY the bot
# tracks rather than a point it visits.
#
#     desired = anchor_velocity + toward_anchor * closing(dist)
#
# The frame's own velocity plus a closing term that is spent by the time we
# arrive; the return is the thrust that corrects our velocity onto it. Far out
# the closing term dominates and the heading is straight pursuit; as the gap
# closes the heading rotates onto the anchor's own velocity, so the defender
# turns and runs WITH the play; at the stand the desired velocity IS the man's
# and the relative speed is zero. Unit magnitude while there is any real error:
# `move_vector` is a joystick and the physics scales it, so the intelligence is
# in the DIRECTION — full effort along the heading that fixes the error. The
# residual ripple as the error goes to zero is one tick of thrust (≈0.09 m/s at
# league accel), well under the friction the bot is fighting to hold the pace.
#
# Pure value math, no allocation.
static func _moving_frame_pursuit(to_anchor: Vector3, anchor_dist: float,
		anchor_velocity: Vector3, self_velocity: Vector3,
		v_max: float) -> Vector2:
	var des_x: float = anchor_velocity.x
	var des_z: float = anchor_velocity.z
	if anchor_dist > 0.001:
		var inv_d: float = 1.0 / anchor_dist
		# How fast the frame is eating the gap from ITS side — the component of its
		# velocity pointing back down the line at us. This is the term that makes a
		# defensive stand different from a station, and leaving it out is the whole
		# of the old charge: shedding `v` takes v/B seconds, during which the gap
		# closes by v²/2B from our side AND by c·v/B from the frame's, so a profile
		# that only prices the first half arrives with speed it has no ice left to
		# shed. Solving v²/2B + c·v/B = dist for the positive root:
		var c: float = -(anchor_velocity.x * to_anchor.x
				+ anchor_velocity.z * to_anchor.z) * inv_d
		var closing: float = maxf(
				sqrt(c * c + 2.0 * ARRIVAL_BRAKE_DECEL_M_S2 * anchor_dist) - c, 0.0)
		# A frame RUNNING AWAY (c < 0) buys extra room by the same arithmetic and
		# the root grants it, which is what lets a backchecker's hip be chased down.
		var inv: float = closing * inv_d
		des_x += to_anchor.x * inv
		des_z += to_anchor.z * inv
	# We cannot skate faster than we can skate. Clamping the SUM (rather than the
	# closing term) keeps the best available heading: flat out along the line that
	# serves both errands, which as the gap closes rotates off pursuit and onto the
	# frame's own velocity.
	var des_len: float = sqrt(des_x * des_x + des_z * des_z)
	if des_len > v_max and des_len > 0.001:
		var k: float = v_max / des_len
		des_x *= k
		des_z *= k
	var err_x: float = des_x - self_velocity.x
	var err_z: float = des_z - self_velocity.z
	var err_len: float = sqrt(err_x * err_x + err_z * err_z)
	if err_len < 0.001:
		return Vector2.ZERO
	var inv_err: float = 1.0 / err_len
	return Vector2(err_x * inv_err, err_z * inv_err)


# The carrier's opponent avoidance reads THREAT, not proximity, and routes
# AROUND, not away. Per defender: project his body along his momentum over the
# evasion horizon; his stick can touch anywhere within the league reach of that
# swept segment, so the repel points away from the CLOSEST POINT of the sweep and
# its strength is how deep inside that reach (plus a stick of margin) the carrier
# sits. A beaten man whose momentum carries him away exerts nothing; a jockeying
# defender keeps his full push. The summed force then loses any component
# opposing the anchor direction — pressure bends the carry line, it never
# reverses it. Retreat is the carry DELIBERATION's call (the anchor itself
# moves); it must never be a reflex here, so a defender parked dead on the line
# repels ~nothing and driving at him is the aggressive read the poke-evade owns.
# Pure value math, no allocation. `to_anchor` / `anchor_dist` are the
# already-computed anchor pull inputs, passed through to avoid recomputing.
static func _carrier_threat_repel(self_pos: Vector3, to_anchor: Vector3,
		anchor_dist: float, opponent_positions: Array[Vector3],
		opponent_velocities: Array[Vector3], repel_weight: float) -> Vector2:
	# League-default reach off the momentum line — same double-integrator model
	# as AIActionScoring.reach_clearance (reaction-gated maneuver + stick), the
	# single source for those measurements. Steering doesn't carry per-peer
	# caps; the league reach is the right fidelity for a soft field force.
	var t_over: float = maxf(
			0.0, AIActionScoring.EVADE_HORIZON_S - AIActionScoring.EVADE_REACTION_S)
	var reach: float = 0.5 * t_over * t_over * AIActionScoring.MANEUVER_ACCEL_M_S2 \
			+ AIActionScoring.EVADE_STICK_REACH_M
	var force := Vector2.ZERO
	for i: int in opponent_positions.size():
		var op: Vector3 = opponent_positions[i]
		var sweep_x: float = opponent_velocities[i].x * AIActionScoring.EVADE_HORIZON_S
		var sweep_z: float = opponent_velocities[i].z * AIActionScoring.EVADE_HORIZON_S
		# Closest point to the carrier on the swept segment [op, op + sweep].
		var t: float = 0.0
		var sweep_len_sq: float = sweep_x * sweep_x + sweep_z * sweep_z
		if sweep_len_sq > 0.0001:
			t = clampf(((self_pos.x - op.x) * sweep_x
					+ (self_pos.z - op.z) * sweep_z) / sweep_len_sq, 0.0, 1.0)
		var dx: float = self_pos.x - (op.x + sweep_x * t)
		var dz: float = self_pos.z - (op.z + sweep_z * t)
		var d: float = sqrt(dx * dx + dz * dz)
		# Full push inside his reach, fading to zero a stick-length outside it —
		# the same "a stick of clear room reads as safe" ramp as
		# AIActionScoring.clearance_to_safety.
		var threat: float = 1.0 - clampf(
				(d - reach) / AIActionScoring.EVADE_SAFE_MARGIN_M, 0.0, 1.0)
		if threat <= 0.0:
			continue
		if d > 0.001:
			force += Vector2(dx / d, dz / d) * (threat * repel_weight)
		elif sweep_len_sq > 0.0001:
			# Standing ON his sweep line: sidestep perpendicular to his travel,
			# on whichever side doesn't fight the anchor pull.
			var inv_sweep: float = 1.0 / sqrt(sweep_len_sq)
			var perp := Vector2(-sweep_z * inv_sweep, sweep_x * inv_sweep)
			if perp.x * to_anchor.x + perp.y * to_anchor.z < 0.0:
				perp = -perp
			force += perp * (threat * repel_weight)
	# Route AROUND: strip the component opposing the anchor direction so the
	# summed pressure can bend the carry line but never push the carrier
	# backwards off it.
	if anchor_dist > ANCHOR_DEADBAND:
		var a := Vector2(to_anchor.x / anchor_dist, to_anchor.z / anchor_dist)
		var along: float = force.dot(a)
		if along < 0.0:
			force -= a * along
	return force


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


# Repel out of either crease + CREASE_REPEL_EXTENSION. Outward direction comes
# from CreaseRules so the force rounds the arc correctly (no axis snap at the
# corners). Returns zero outside the extended crease.
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
# pull fights it.
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
	# A target ACROSS the cage (opposite x sign — the wheel's far-side exit)
	# keeps the detour alive for the whole behind-net traverse: without it,
	# a body starting outside the post span steered the straight line and
	# scraped the cage's back corner instead of rounding it.
	var traverse: bool = signf(anchor.x) != 0.0 \
			and signf(self_pos.x) != 0.0 \
			and signf(self_pos.x) != signf(anchor.x)
	# Already clear of the post laterally → let the anchor pull round the
	# corner on its own (unless mid-traverse — see above).
	var post_span: float = GameRules.NET_HALF_WIDTH + NET_DETOUR_POST_MARGIN
	if absf(self_pos.x) >= post_span and not traverse:
		return Vector2.ZERO
	# Only detour toward a target on the rink side of this line. A target
	# also behind the line (a deliberate loose-puck retrieval / wraparound
	# setup) needs no detour.
	if (anchor.z - goal_z) * -goal_z_sign <= 0.0:
		return Vector2.ZERO
	# Push toward the nearer post side; on a traverse, toward the TARGET's
	# side (crossing behind the cage); at dead-center, go around the side
	# the play (anchor) is on.
	var side: float = signf(anchor.x) if traverse else signf(self_pos.x)
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
# hockey stop into a dig-in restart.
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


# Should the bot press the brake to ARRIVE at `anchor` instead of overshooting
# it? See the ARRIVAL_BRAKE_* doc above. `was_braking` is the previous tick's
# decision (hysteresis). Pure and stateless beyond that flag.
#
# NOT for a stand that rides a man — the caller withholds it there. This brake is
# an actuator on OUR OWN velocity, and "overshoot" only means something when the
# target holds still; against a moving stand it fires on closing the ANCHOR is
# producing (a defender stopped dead in front of a rush reads 6.9 m/s of closing
# at a stand 1 m away, and braking does nothing to slow the rush). In the
# moving-frame path the closing profile IS the arrival law and the brake-PIVOT
# supplies the hard actuator whenever that command opposes the body's momentum.
static func should_arrival_brake(self_pos: Vector3, anchor: Vector3,
		velocity_xz: Vector2, was_braking: bool) -> bool:
	var speed: float = velocity_xz.length()
	if speed < ARRIVAL_BRAKE_MIN_SPEED_M_S:
		return false  # slow enough that friction + the deadband settle it
	var to_anchor := Vector2(anchor.x - self_pos.x, anchor.z - self_pos.z)
	var dist: float = to_anchor.length()
	if dist < 0.001:
		return true  # on top of the target at speed — stop
	# Closing speed: the velocity component toward the anchor. Moving away
	# or tangential → nothing to overshoot (reversals are the pivot
	# brake's job).
	var closing: float = velocity_xz.dot(to_anchor) / dist
	if closing <= 0.0:
		return false
	var stop_dist: float = (closing * closing) / (2.0 * ARRIVAL_BRAKE_DECEL_M_S2)
	var margin: float = ARRIVAL_BRAKE_RELEASE_MARGIN_M if was_braking \
			else ARRIVAL_BRAKE_ENGAGE_MARGIN_M
	return stop_dist + margin >= dist


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
