class_name AIPossessionState

# Pure-function team possession state, from puck zone × possession. Roles are
# driven by this state rather than by closest-to-puck, following the three
# principles: sprint-by, play off heels, simple 2v1.
#
# State table (per team) — symmetric in puck zone × possession:
#                  we possess        opp possesses
#   their DZ       OZONE             FORECHECK
#   neutral zone   TRANS_OFFENSE          TRANS_DEFENSE
#   our DZ         BREAKOUT          DZONE
#
#   OZONE     — we possess in their DZ (push / cycle)
#   FORECHECK — opp possesses in their DZ (pin them in, recover deep)
#   TRANS_OFFENSE  — we possess in the NZ (D→O rush)
#   TRANS_DEFENSE  — opp possesses in the NZ (O→D retreat)
#   BREAKOUT  — we possess in our DZ (break it out)
#   DZONE     — opp possesses in our DZ (in-zone defense)
#
# Both splits exist because possession alone doesn't name the job — puck
# position decides it, and collapsing either pair inverts the behavior:
#
#   FORECHECK vs TRANS_DEFENSE — both are "opp possesses, not in our DZ". Deep in
#     their end the job is to forecheck (pin them, force a turnover); once the
#     puck reaches the NZ it's a retreat (TRANS_DEFENSE's Sprinting-Through
#     backcheck). One bucket for both retreats from a sloppy opponent deep in
#     his own zone — the exact opposite of a forecheck.
#   BREAKOUT vs TRANS_OFFENSE — both are "we possess, not in their DZ". Deep in our
#     own end the job is to break out safely (supports present strong-side-wall
#     + weak-side-reverse outlets); in the NZ it's a rush, where TRANS_OFFENSE's
#     stretch OUTLET at the far blue line makes sense. One bucket for both fires
#     that OUTLET from deep in our own zone.
#
# There is deliberately no RETRIEVAL state for a loose puck in our DZ we have
# clearly won: it gates no breakout the team does not already make straight from
# DZONE, and it churns the shape. Read docs/breakout-plan.md Phase A before
# adding one.
#
# Loose-puck handling: possession is sticky. `prev_carrier_team` carries
# over until a new carrier sets it. The 6 Hz brain tick smooths sub-tick
# oscillation (e.g., stick-on-stick contact during a strip) naturally —
# we sample at the brain tick, not every physics tick.

enum State { DZONE, OZONE, TRANS_OFFENSE, TRANS_DEFENSE, NEUTRAL, BREAKOUT, FORECHECK }

# ── Coverage readiness (docs/transition-defense-plan.md §9) ──────────────────
# DZONE is a SHAPE, not a location, so the brain holds the rush/recovery shape
# until the bodies the coverage assumes have arrived (AIRushRead.coverage_ready).
# The raw table above flips to DZONE the instant the puck crosses our blue line
# with the opponent carrying, which would re-slot bots 25 m up-ice onto zone
# posts and dissolve the backcheck at the line. Get back, get set, THEN take
# your man.
#
# The asymmetry this constant expresses: it is EASY to become set and HARD to
# stop being set. Becoming unset is available instantly — the accounting is false
# the moment men are unaccounted for. Going the other way, a settled structure
# must not be dumped into scramble mode by one bad tick (a body straddling the
# blue line to pressure the point is not a broken structure), so leaving coverage
# takes a sustained stretch.
#
# There must be NO time-floor fallback beside it. A home-ness predicate is
# monotone in recovering bodies, so it clears on its own; a floor beside one that
# cannot clear becomes the only path into the zone.
const COVERAGE_HOLD_TICKS: int = 6


# True when the team should be running D-zone COVERAGE rather than the rush /
# recovery shape. `ready` is AIRushRead.coverage_ready (the backcheck is home);
# `unready_ticks` counts consecutive brain ticks it has been FALSE; `was_set` is
# last tick's answer.
static func coverage_read(ready: bool, unready_ticks: int,
		was_set: bool) -> bool:
	if was_set:
		return unready_ticks < COVERAGE_HOLD_TICKS
	return ready


class Result:
	var state: int           # AIPossessionState.State enum value
	var carrier_team: int    # -1 if no carrier ever seen

	static func make(s: int, ct: int) -> Result:
		var r := Result.new()
		r.state = s
		r.carrier_team = ct
		return r

# Below this puck speed, carrier-less puck is treated as NEUTRAL (a
# fresh faceoff drop, basically). High-speed loose pucks (passes in
# flight, stripped-puck contact) keep the prior possession state.
const NEUTRAL_PUCK_SPEED_M_S: float = 1.0


# `team_id` is the team this brain represents (0 or 1).
# `own_goal_z` is the z-coordinate of this team's defended net (+ for
# team 0, − for team 1).
# `team_id_by_peer` is `Dictionary[int, int]` mapping peer_id -> team_id;
# unknown peers should resolve to -1 (`dict.get(pid, -1)`).
# `prev_carrier_team` is the last-known team in possession, used for
# sticky loose-puck handling. Pass -1 if unknown.
static func compute(
		snapshot: WorldSnapshot,
		team_id: int,
		own_goal_z: float,
		team_id_by_peer: Dictionary,
		prev_carrier_team: int) -> Result:
	if snapshot == null or snapshot.puck_state == null:
		# Degenerate — no puck info. Default to NEUTRAL.
		return Result.make(State.NEUTRAL, prev_carrier_team)

	# Possession: current carrier's team if any, else sticky to prev.
	var carrier: int = snapshot.puck_state.carrier_peer_id
	var carrier_team: int = prev_carrier_team
	if carrier != -1:
		carrier_team = team_id_by_peer.get(carrier, -1)

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
		return Result.make(State.DZONE, carrier_team)

	# NEUTRAL override: outside our DZ, a slow loose puck is treated
	# as NEUTRAL (e.g., faceoff drop in NZ / opp DZ). High-speed loose
	# pucks (passes in flight, stripped-puck contact) keep the prior
	# possession state via sticky resolution below.
	if carrier == -1:
		var v: Vector3 = snapshot.puck_state.velocity
		var speed: float = sqrt(v.x * v.x + v.z * v.z)
		if speed < NEUTRAL_PUCK_SPEED_M_S:
			return Result.make(State.NEUTRAL, carrier_team)

	var our_possession: bool = (carrier_team == team_id)

	var state: State
	if our_possession:
		if in_their_dz:
			state = State.OZONE
		elif in_our_dz:
			state = State.BREAKOUT
		else:
			state = State.TRANS_OFFENSE
	else:
		if in_our_dz:
			state = State.DZONE
		elif in_their_dz:
			state = State.FORECHECK
		else:
			state = State.TRANS_DEFENSE

	return Result.make(state, carrier_team)


# True for either TRANS state.
static func is_transition(state: State) -> bool:
	return state == State.TRANS_OFFENSE or state == State.TRANS_DEFENSE
