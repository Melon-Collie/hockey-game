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
# Pure/static, engine-free, unit-testable. Callers own the Constraints instance
# (rebuilt in place each tick) so the hot path allocates nothing.

class Constraints:
	# Buckley depth-chart radius for the current threat distance — the baseline.
	var chart_radius: float = 0.0
	# Lateral-pressure retreat: the chart radius already reduced by the pull.
	# INF when no lateral overspeed binds.
	var lateral_cap: float = INF
	# Backdoor re-square race cap (GoalieBehaviorRules.backdoor_depth_cap).
	# INF when no weak-side one-timer threat binds.
	var backdoor_cap: float = INF
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
	var target: float = c.chart_radius
	if c.lateral_cap < target:
		target = maxf(c.lateral_cap, c.floor_radius)
	if c.backdoor_cap < target:
		target = maxf(c.backdoor_cap, c.floor_radius)
	var rate: float = 0.0
	if c.rush_radius < target:
		target = c.rush_radius
		rate = c.rush_rate
	# The backflow is RATE-MATCHED to the attacker's closing speed, so while it is
	# retreating him it owns the motion and bypasses both the settle and the rate
	# cap (that is the whole point of F5 — the challenge gap is a modeled read, not
	# a smoothing artifact). Any other direction, or no backflow, uses the settle.
	if rate > 0.0 and target < current:
		return move_toward(current, target, rate * delta)
	return approach(current, target, delta, c.settle_speed, c.max_speed)


# Move toward `target` with an exponential settle shaped by `settle_speed`, rate
# capped at `max_speed` — skating speed in and out of the crease is a physical
# quantity, not a lerp artifact. Shared by the standing family and the recovery
# fade, so both obey the same cap.
static func approach(current: float, target: float, delta: float,
		settle_speed: float, max_speed: float) -> float:
	var next: float = lerpf(current, target, settle_speed * delta)
	var max_step: float = max_speed * delta
	return current + clampf(next - current, -max_step, max_step)
