class_name GoalieDepthSolver

# Composition of the goalie's depth constraints — the one place that answers
# "given everything pulling on my depth at once, where do I stand, and how fast do
# I get there?"
#
# ── Why this exists (plan doc §3) ────────────────────────────────────────────
# Depth was decided by a hand-ordered sequence inside GoalieController._update_depth:
# the Buckley chart, then the lateral-pressure retreat, then the backdoor cap, then
# the rush backflow, then a floor, a rate cap and an exponential settle — some
# `min`, some `max`, one `move_toward` bypassing the others. Every individual model
# was grounded and tested; the COMPOSITION was neither, and the answer was whatever
# the statement order happened to produce. That is the mechanism by which a
# codebase full of good models still feels hand-tuned, and it is why adding the
# eighth constraint was going to be harder than the seventh.
#
# Expressed here, the rule is simple and states itself:
#   * every constraint is a MAXIMUM RADIUS the goalie may hold;
#   * the target is the tightest of them (floored, so no cap can bury him in the net);
#   * the approach RATE is the rush backflow's when it binds, otherwise the
#     ordinary settle.
# Ordering stops being load-bearing, and a ninth constraint is one more field.
#
# ── Why there is no distance CURVE any more ──────────────────────────────────
# The Buckley A/B/C/D zones are defined SITUATIONALLY, not by distance: A is for a
# play entering the zone, B for a settled shot, C when a lateral play is live, D on
# the post. The old static chart tried to reproduce them from threat distance
# alone, which put A (the most aggressive depth) in the slot and B out at the
# points — inverted, and a fifth mechanism contradicting the four situational
# models that already existed (rush backflow = A, backdoor cap = C, RVH/VH = D).
#
# Depth is now the SOLVE those models were already describing: go as far out as
# the races allow. The zones stop being authored and become emergent — nothing
# binding means a genuine 1v0 gets challenged aggressively (correct: there is no
# lateral option to punish it), a live receiver pulls him back via the re-square
# race, a closing rush hands him to the backflow, and the standoff keeps him off
# the puck in tight.
#
# NOT changed: he is not simply parked deeper. At this game's shot speeds the
# flight time inside ~7 m is SHORTER than the arm read (0.108 s at 5 m vs 0.18 s
# cold), so depth cannot buy usable reaction time in the slot — the original
# chart's "cutting the angle is what makes the save, not reflexes" reasoning holds
# for the game even though the chart's zone LAYOUT did not.
#
# Pure/static, engine-free, unit-testable. Callers own the Constraints instance
# (rebuilt in place each tick) so the hot path allocates nothing.

class Constraints:
	# CEILING — as far out as the goalie will ever challenge. No longer a distance
	# curve: depth is now solved as "the deepest radius the races allow", and this
	# is simply the upper bound on that solve (BPS "A", the aggressive depth).
	var ceiling_radius: float = 0.0
	# PHYSICAL STANDOFF — he must stay goal-side of the puck. Without this the
	# solve happily puts him level with (or past) an in-tight threat, which is
	# what "the goalie is right on top of me" felt like. Not a tuning curve: it is
	# body half-depth plus stick clearance.
	var standoff_cap: float = INF
	# Lateral TRACKING cap — the deepest radius from which he can still stay square
	# to a carrier moving the puck across (the anticipatory deke / walkout answer).
	# INF when nothing binds.
	var lateral_cap: float = INF
	# Backdoor re-square race cap (GoalieBehaviorRules.backdoor_depth_cap).
	# INF when no weak-side one-timer threat binds.
	var backdoor_cap: float = INF
	# Tuck-race cap (GoalieBehaviorRules.tuck_race_depth_cap) — the anticipatory
	# backside answer: no deeper than the skate-back-to-the-post race against the
	# carrier's live lateral drive stays winnable. INF when he isn't driving.
	var tuck_cap: float = INF
	# Rush-backflow curve anchor for a closing carrier. INF when not engaged.
	var rush_radius: float = INF
	# Retreat rate (m/s) that keeps him ON the backflow curve at the attacker's
	# closing speed. > 0 only while the backflow is actually driving.
	var rush_rate: float = 0.0
	# Floor the caps may not push him below — he never buries himself in the net
	# because of an anticipatory read.
	var floor_radius: float = 0.0
	# Exponential settle shaping (1/s) and the physical in/out rate cap (m/s).
	var settle_speed: float = 4.0
	var max_speed: float = 2.2


# Resolve this tick's depth from `current`.
#
# NOTE the rush radius is deliberately NOT floored, unlike the two caps. It cannot
# need the floor: `rush_retreat_depth` interpolates between the chart's own
# anchors, the deepest of which IS the floor, so it can never ask for less. Kept
# explicit so a future edit to the backflow anchors does not silently gain the
# ability to bury the goalie.
static func solve(current: float, delta: float, c: Constraints) -> float:
	var target: float = solve_target(c)
	var rate: float = 0.0
	if c.rush_radius < solve_caps(c):
		rate = c.rush_rate
	# The backflow is RATE-MATCHED to the attacker's closing speed, so while it is
	# retreating him it owns the motion and bypasses both the settle and the rate
	# cap (that is the whole point of F5 — the challenge gap is a modeled read, not
	# a smoothing artifact). Any other direction, or no backflow, uses the settle.
	if rate > 0.0 and target < current:
		return move_toward(current, target, rate * delta)
	return approach(current, target, delta, c.settle_speed, c.max_speed)


# The caps alone — everything except the rush backflow. Split out so `solve` can
# ask whether the backflow is the binding constraint (and therefore owns the rate)
# without recomputing.
static func solve_caps(c: Constraints) -> float:
	var target: float = c.ceiling_radius
	if c.standoff_cap < target:
		target = maxf(c.standoff_cap, c.floor_radius)
	if c.lateral_cap < target:
		target = maxf(c.lateral_cap, c.floor_radius)
	if c.backdoor_cap < target:
		target = maxf(c.backdoor_cap, c.floor_radius)
	if c.tuck_cap < target:
		target = maxf(c.tuck_cap, c.floor_radius)
	return target


# THE settled depth for a set of constraints — the tightest cap, floored, with the
# rush backflow applied. This is the SHARED model: the live controller integrates
# toward it via `solve`, and the bot planner reads it directly
# (AIActionScoring.planned_goalie_depth) so the two cannot drift.
#
# Keeping this a separate entry point matters. The planner has no per-tick state
# to integrate and wants the STEADY-STATE answer; the controller needs the
# approach rate as well. Sharing `solve_target` means a change to the depth model
# reaches both by construction instead of by a comment asking someone to remember.
static func solve_target(c: Constraints) -> float:
	var target: float = solve_caps(c)
	if c.rush_radius < target:
		target = c.rush_radius
	return target


# Move toward `target` with an exponential settle shaped by `settle_speed`, rate
# capped at `max_speed` — skating speed in and out of the crease is a physical
# quantity, not a lerp artifact. Shared by the standing family and the recovery
# fade, so both obey the same cap.
static func approach(current: float, target: float, delta: float,
		settle_speed: float, max_speed: float) -> float:
	var next: float = lerpf(current, target, settle_speed * delta)
	var max_step: float = max_speed * delta
	return current + clampf(next - current, -max_step, max_step)
