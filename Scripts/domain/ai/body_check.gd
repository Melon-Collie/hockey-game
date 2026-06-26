class_name AIBodyCheck

# Pure decision: should an on-puck defensive bot COMMIT to a body check on the
# carrier right now, and where's the body-intercept to drive at?
#
# Body checks are emergent — there is no hit button. A bot "delivers" one by
# driving its body into an intercept on the carrier at speed; the collision in
# Skater._resolve_player_collisions converts the closing velocity + attributes
# into the transfer impulse, identical to a human hit. So this rule decides only
# WHEN to commit and returns the intercept POINT to steer at; the state machine
# points steering there and forces sprint (max closing velocity = harder hit).
#
# Committing is a real risk — miss and you're out of the play — so the gate is
# deliberately conservative and only fired by pressurers WITH support behind
# them (PRESSURE / FORECHECK F1), never the last-man gap defender. Three checks:
#
#   1. Range — the carrier is within CHECK_RANGE_M (don't hunt from afar).
#   2. Reachable intercept — solving the lead (AITrajectory.intercept_time), can
#      I actually get my body there before the carrier skates past? A carrier
#      fleeing faster than me saturates the solve and is rejected.
#   3. Real hit — the PREDICTED victim impulse clears COMMIT_IMPULSE_M_S (a
#      separating hit, well above BodyCheckRules' 3 m/s "a bump lands" floor).
#      Impulse = approach × (self_weight / victim_weight) × self_body_check_transfer,
#      mirroring the collision math: a soft bump that won't separate man from
#      puck isn't worth leaving position for.
#
# Attribute expression falls out of (3): a high-Size/Physical bot's predicted
# impulse clears the bar at lower closing speeds, so it hunts hits; a
# light/low-Physical bot rarely clears it and won't whiff checks it'd bounce off.
# A carrier skating TOWARD the checker raises the closing speed (bigger hit, more
# likely to commit); one skating away lowers it. No RNG — replay-safe.
#
# Victim weight is the league baseline here (opponent attributes aren't modeled
# yet); the attacker's own weight + transfer — which dominate the hit and ARE
# known — carry the decision. Opponent modeling can later pass a real victim
# weight to avoid bouncing off a heavy / braced target.

# Only hunt a hit when the carrier is this close — beyond it, contain instead.
const CHECK_RANGE_M: float = 6.0

# Lead-solve horizon for the body intercept (seconds).
const MAX_LEAD_S: float = 0.6

# Predicted victim impulse (m/s velocity delta) required to commit. Above
# BodyCheckRules' min_impulse (3.0 = "a bump lands nothing much") and below
# ref_impulse (9.0 = full-strength check): 5 m/s is a solid separating hit, so
# the bot only commits to checks that actually do something.
const COMMIT_IMPULSE_M_S: float = 5.0

# League-average victim mass (Skater.weight default) — the weight_ratio
# denominator until opponent attributes are modeled.
const LEAGUE_VICTIM_WEIGHT: float = 1.0

# Slack on the reachability test so a borderline-reachable intercept isn't
# rejected by float noise.
const REACH_SLACK_M: float = 0.5


class Result:
	var commit: bool = false
	var target: Vector3 = Vector3.ZERO


# `self_*` describe the checker; `carrier_*` the puck carrier it might hit.
# `self_max_speed` is the closing-speed proxy (the bot will sprint in, so this
# is conservative — sprint runs a touch faster). Returns commit=false with a
# zero target when no hit should be committed.
static func evaluate(
		self_pos: Vector3,
		self_max_speed: float,
		self_weight: float,
		self_body_check_transfer: float,
		self_stagger_timer: float,
		carrier_pos: Vector3,
		carrier_vel: Vector3) -> Result:
	var r := Result.new()

	# Don't commit while staggered — off-balance, can't deliver a hit.
	if self_stagger_timer > 0.0:
		return r
	if self_max_speed <= 0.0:
		return r

	# 1. Range.
	if self_pos.distance_to(carrier_pos) > CHECK_RANGE_M:
		return r

	# 2. Reachable intercept. Solve the lead against the carrier's motion, then
	# check I can cover the gap to that point at my top speed within the solved
	# time (a fleeing carrier saturates the solve → gap exceeds my reach).
	var t: float = AITrajectory.intercept_time(
			self_pos, carrier_pos, carrier_vel, Vector3.ZERO, self_max_speed, MAX_LEAD_S)
	var intercept: Vector3 = AITrajectory.predict_at(carrier_pos, carrier_vel, t, 6)
	var gap: float = self_pos.distance_to(intercept)
	if gap > self_max_speed * t + REACH_SLACK_M:
		return r

	# 3. Real hit. Predict the victim impulse from the closing velocity I'd
	# bring driving at the intercept, my weight ratio, and my transfer.
	var approach: float = _predicted_approach(self_pos, self_max_speed, intercept, carrier_vel)
	var weight_ratio: float = self_weight / maxf(LEAGUE_VICTIM_WEIGHT, 0.001)
	var predicted_impulse: float = approach * weight_ratio * self_body_check_transfer
	if predicted_impulse < COMMIT_IMPULSE_M_S:
		return r

	r.commit = true
	r.target = intercept
	return r


# Closing speed (m/s) along the checker→intercept line: the bot drives at the
# intercept at `self_speed`, the carrier moves at `carrier_vel`; the approach is
# the relative velocity projected onto the closing direction (clamped to >= 0 —
# a carrier outrunning the closing line yields no hit). Matches the `approach`
# term the collision resolver uses.
static func _predicted_approach(self_pos: Vector3, self_speed: float,
		intercept: Vector3, carrier_vel: Vector3) -> float:
	var dir: Vector3 = intercept - self_pos
	dir.y = 0.0
	var l: float = dir.length()
	if l < 0.001:
		return self_speed
	dir /= l
	var rel: Vector3 = dir * self_speed - carrier_vel
	return maxf(rel.x * dir.x + rel.z * dir.z, 0.0)
