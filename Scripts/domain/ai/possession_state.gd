class_name AIPossessionState

# Pure-function team possession state. Returns one of four states based on
# current puck zone + possession. Replaces the F1/F2/F3 closest-to-puck
# role assignment with a possession-state-driven model — see
# `docs/specs/AI_PLAN.md` (v2 model) and the article-distilled three
# principles (sprint-by, play off heels, simple 2v1).
#
# State table (per team):
#   OZONE    — we have the puck AND puck is in their DZ
#   DZONE    — opp has the puck AND puck is in our DZ
#   TRANS_DO — we have the puck AND puck is NOT in their DZ (D→O attack)
#   TRANS_OD — opp has the puck AND puck is NOT in our DZ (O→D defend)
#
# Loose-puck handling: possession is sticky. `prev_carrier_team` carries
# over until a new carrier sets it. The 6 Hz brain tick smooths sub-tick
# oscillation (e.g., stick-on-stick contact during a strip) naturally —
# we sample at the brain tick, not every physics tick.

enum State { DZONE, OZONE, TRANS_DO, TRANS_OD, NEUTRAL }

# Below this puck speed, carrier-less puck is treated as NEUTRAL (a
# fresh faceoff drop, basically). High-speed loose pucks (passes in
# flight, stripped-puck contact) keep the prior possession state.
const NEUTRAL_PUCK_SPEED_M_S: float = 1.0


# Returns [new_state, new_carrier_team]. `new_carrier_team` is -1 if no
# carrier has ever been seen (start of game).
#
# `team_id` is the team this brain represents (0 or 1).
# `own_goal_z` is the z-coordinate of this team's defended net (+ for
# team 0, − for team 1).
# `team_id_resolver` is `func(peer_id: int) -> int` — same callable the
# brain already holds.
# `prev_carrier_team` is the last-known team in possession, used for
# sticky loose-puck handling. Pass -1 if unknown.
static func compute(
		snapshot: WorldSnapshot,
		team_id: int,
		own_goal_z: float,
		team_id_resolver: Callable,
		prev_carrier_team: int) -> Array:
	if snapshot == null or snapshot.puck_state == null:
		# Degenerate — no puck info. Default to NEUTRAL.
		return [State.NEUTRAL, prev_carrier_team]

	# Possession: current carrier's team if any, else sticky to prev.
	var carrier: int = snapshot.puck_state.carrier_peer_id
	var carrier_team: int = prev_carrier_team
	if carrier != -1:
		carrier_team = int(team_id_resolver.call(carrier))

	# Zones: own_goal_dir * z > BLUE_LINE_Z means puck is in our DZ
	# (deep on our side). The opposite sign with the same magnitude
	# means puck is in their DZ.
	var own_goal_dir: float = signf(own_goal_z)
	var puck_z: float = snapshot.puck_state.position.z
	var in_our_dz: bool = own_goal_dir * puck_z > GameRules.BLUE_LINE_Z
	var in_their_dz: bool = -own_goal_dir * puck_z > GameRules.BLUE_LINE_Z

	# Loose-puck-in-own-DZ override: a loose puck in our DZ is ALWAYS
	# defensive priority — strips, dump-ins, faceoff drops in our zone
	# all need the team in DZONE shape (1-2 zone defense), not
	# offensive transition. Fires BEFORE the NEUTRAL slow-puck check
	# so that low-velocity loose pucks in our DZ (e.g., faceoff drops,
	# puck wedged near the goalie) still resolve as DZONE.
	if carrier == -1 and in_our_dz:
		return [State.DZONE, carrier_team]

	# NEUTRAL override: outside our DZ, a slow loose puck is treated
	# as NEUTRAL (e.g., faceoff drop in NZ / opp DZ). High-speed loose
	# pucks (passes in flight, stripped-puck contact) keep the prior
	# possession state via sticky resolution below.
	if carrier == -1:
		var v: Vector3 = snapshot.puck_state.velocity
		var speed: float = sqrt(v.x * v.x + v.z * v.z)
		if speed < NEUTRAL_PUCK_SPEED_M_S:
			return [State.NEUTRAL, carrier_team]

	var our_possession: bool = (carrier_team == team_id)

	var state: State
	if our_possession:
		state = State.OZONE if in_their_dz else State.TRANS_DO
	else:
		state = State.DZONE if in_our_dz else State.TRANS_OD

	return [state, carrier_team]


# Helper: returns true if `state` is a TRANS state (used by SPRINT_BY
# locking logic in role_slots).
static func is_transition(state: State) -> bool:
	return state == State.TRANS_DO or state == State.TRANS_OD
