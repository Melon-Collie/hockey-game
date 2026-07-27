class_name XGBaseline

# A PUBLIC-STYLE expected-goals model: location + angle + shot type, nothing
# else. The deliberate counterpart to AIActionScoring.expected_goals (which sees
# the real goalie), and the BASELINE our goalie-aware model has to beat before
# its extra complexity is worth anything.
#
# ── Why this exists ──────────────────────────────────────────────────────────
# Public NHL xG models are regressions over sparse tracking data: they know
# where the shot came from and roughly what kind it was, and nothing about the
# goalie. That looks like a weakness, but it means both halves of beating a
# goalie — getting him moving AND finishing — are priced into the fitted
# average. Our geometric model measures the open net AT RELEASE, which prices
# only the second half of the first step: a deke that yawns the net open reads
# ~0.9 even when the actual shot (moving, backhand, mid-move) rarely goes in.
# This model is immune to that by construction, so it's the cross-check.
#
# ── Provenance, honestly ─────────────────────────────────────────────────────
# The FORM is the standard one (a logistic in log-distance and angle, plus
# shot-type log-odds bumps). The coefficients are not copied from any published
# fit — they are solved to reproduce well-known NHL aggregates:
#   ~0.40 in tight (3 m, centred) · ~0.12 mid-slot (8 m) · ~0.03 from the point
#   (20 m) · roughly halved at 60° off-centre · ~0.08 average per unblocked shot
# So treat the SHAPE as sound and the absolute level as NHL-calibrated.
#
# ── The Mitts caveat ─────────────────────────────────────────────────────────
# NHL shooting is ~9-10% on goal; Mitts is arcade — beatable goalies, 3v3 space,
# and observed shooting well above that. So this model will UNDER-predict Mitts
# scoring. It is not "the right answer" either. It brackets the truth from the
# low side while the geometric model brackets it from the high side; the real
# number is between them, and logged outcomes decide where.
#
# Pure static math on values already carried by every ShotEvent (x, z, team,
# type) — no new capture, no wire field, no stored column.

# Logistic in natural-log distance (metres): z = A - B*ln(d).
# Solved through 3 m -> 0.40 and 15 m -> 0.045 (see the aggregates above).
const A: float = 1.40
const B: float = 1.65
# Log-odds penalty per radian off the centre line. Calibrated so a 60° shot is
# about half the value of the same distance straight on.
const ANGLE_PENALTY: float = 0.80
# Shot-type log-odds bumps. Modest: distance already carries most of why a tip
# or a one-timer is dangerous (they happen in tight).
const ONE_TIMER_BONUS: float = 0.30
const TIP_BONUS: float = 0.40
# Distance floor — ln() diverges at the goal mouth, and a shot from inside 0.5 m
# is a tap-in whose value the floor's ~0.85 already represents.
const MIN_DISTANCE_M: float = 0.5


# The attacking goal's z for a team: team 0 defends +Z and attacks -Z.
static func attacking_goal_z(team_id: int) -> float:
	return GameRules.GOAL_LINE_Z if team_id == 1 else -GameRules.GOAL_LINE_Z


# Expected goals for a shot released at (x, z) by `team_id`, of `shot_type`
# (ShotEvent.ShotType). Returns a probability in (0, 1).
static func for_shot(x: float, z: float, team_id: int, shot_type: int) -> float:
	return sigmoid(logit_for_shot(x, z, team_id, shot_type))


# The LOG-ODDS behind for_shot, exposed so a model can extend this form with
# extra features instead of re-declaring its coefficients. AIShotValue adds a
# keeper-displacement term to exactly this logit, which is what makes "the
# public form plus one feature" a structural fact rather than a comment: at
# zero displacement the two are identical by construction, and the unit tests
# assert it.
static func logit_for_shot(x: float, z: float, team_id: int,
		shot_type: int) -> float:
	var goal_z: float = attacking_goal_z(team_id)
	var along: float = absf(z - goal_z)          # straight-out distance from the line
	var across: float = absf(x)                  # lateral offset from the mouth's centre
	var dist: float = maxf(sqrt(along * along + across * across), MIN_DISTANCE_M)
	# Angle off the centre line, 0 straight on -> PI/2 along the goal line.
	var angle: float = atan2(across, maxf(along, 0.001))
	var logit: float = A - B * log(dist) - ANGLE_PENALTY * angle
	match shot_type:
		ShotEvent.ShotType.ONE_TIMER:
			logit += ONE_TIMER_BONUS
		ShotEvent.ShotType.TIP:
			logit += TIP_BONUS
	return logit


static func sigmoid(logit: float) -> float:
	return 1.0 / (1.0 + exp(-logit))


# Convenience for a stored event.
static func for_event(e: ShotEvent) -> float:
	return for_shot(e.x, e.z, e.team_id, e.shot_type)


# Summed baseline xG over a team's UNBLOCKED attempts — the Fenwick convention
# the geometric xGF counter also uses, so the two totals compare like for like.
static func team_total(events: Array[ShotEvent], team_id: int) -> float:
	var total: float = 0.0
	for e: ShotEvent in events:
		if e.team_id == team_id and e.outcome != ShotEvent.Outcome.BLOCKED:
			total += for_event(e)
	return total
