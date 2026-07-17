class_name ShotArcRules

# Pure flight prediction for the practice-mode shot visualizer: given a shot's
# release origin + velocity, forward-simulate the path the way the live puck
# actually flies — gravity only while airborne (the puck RigidBody has no air
# drag or linear damp; see Puck.tscn), then a Coulomb slide on the ice after
# touchdown (GameRules.PUCK_ICE_DECEL_M_S2, the same single-sourced glide model
# AITrajectory uses) — filling a caller-owned point buffer. Rendering
# (ShotArcVisualizer) is infrastructure; this file owns only the math so the
# arc can be GUT-calibrated headless (apex = v_y²/2g, ballistic range, board
# truncation).
#
# The path TRUNCATES at the boards rather than modelling a bounce: the
# visualizer teaches the release (aim / power / loft), and a post-bounce tail
# is noise for that purpose. GameRules.clamp_to_rink_inner detects the exit
# the same way the AI trajectory clamp does.
#
# Deliberately unmodelled: Puck.max_speed (38 m/s — only a maxed-Shot wrister
# grazes it, a ~2% overshoot) and Puck.max_height (3 m — the loft levels top
# out at ~1.12 m). Both are actor-side safety clamps, not flight behavior.

# Defaults for callers: 60 Hz steps, and a short slide tail after touchdown —
# long enough to read the landing direction, short enough that the ghost stays
# a shot, not a route.
const DEFAULT_DT: float = 1.0 / 60.0
const DEFAULT_SLIDE_TAIL_S: float = 0.6

# Squared XZ deviation (m²) between a stepped point and its rink-clamped
# position that counts as board contact and ends the path.
const _BOARD_HIT_EPSILON_SQ: float = 0.0001

# Fills `points` (a caller-owned scratch, never resized here) with the
# predicted path and returns how many entries were written; points[0] is the
# origin. Simulation ends at the first of: buffer full, board contact, the
# slide tail elapsing, or the slide dying. Semi-implicit Euler at `dt`, so
# apex/range read a hair under the closed form — well inside visual tolerance.
static func fill_arc(
		origin: Vector3,
		velocity: Vector3,
		points: PackedVector3Array,
		ice_y: float,
		dt: float = DEFAULT_DT,
		slide_tail_s: float = DEFAULT_SLIDE_TAIL_S,
		gravity_m_s2: float = GameRules.GRAVITY_M_S2,
		ice_decel_m_s2: float = GameRules.PUCK_ICE_DECEL_M_S2) -> int:
	if points.size() == 0 or dt <= 0.0:
		return 0
	points[0] = origin
	var count: int = 1
	var pos: Vector3 = origin
	var vel: Vector3 = velocity
	var slide_left: float = slide_tail_s
	while count < points.size():
		if pos.y > ice_y + 0.0001 or vel.y > 0.0:
			# Airborne: pure ballistic step; pin to the ice on touchdown.
			vel.y -= gravity_m_s2 * dt
			pos += vel * dt
			if pos.y <= ice_y and vel.y <= 0.0:
				pos.y = ice_y
				vel.y = 0.0
		else:
			# Grounded: Coulomb friction decelerates opposite to travel.
			var speed: float = vel.length()
			if speed <= 0.001 or slide_left <= 0.0:
				break
			vel *= maxf(speed - ice_decel_m_s2 * dt, 0.0) / speed
			pos += vel * dt
			slide_left -= dt
		var clamped: Vector2 = GameRules.clamp_to_rink_inner(Vector2(pos.x, pos.z))
		if Vector2(pos.x, pos.z).distance_squared_to(clamped) > _BOARD_HIT_EPSILON_SQ:
			points[count] = Vector3(clamped.x, pos.y, clamped.y)
			return count + 1
		points[count] = pos
		count += 1
	return count
