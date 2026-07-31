extends GutTest

# ── Loose-puck ENGAGEMENT scenarios ──────────────────────────────────────────
# The failure these pin is not "the bot chose the wrong pursuit angle" — it is
# NOBODY GOING AT ALL: a puck dumped into the corner, or rimmed up the wall,
# that both teams stand and watch. It is the single most visible way the AI
# reads as broken, and no single-dispatch unit test catches it, because each
# bot's decision is individually defensible (a teammate has a better ETA; an
# opponent "wins" the race) — the failure is only visible in the aggregate,
# over time, across the whole team.
#
# So these measure exactly that aggregate: over a multi-second sim on the real
# decision stack, what fraction of the ticks with a live loose puck did a team
# have NOBODY in CHASE_PUCK? Thresholds are deliberately coarse (per the
# harness's assertion philosophy) — they bound the pathology, not the tuning.
#
# Two things make the number mean that and not something else, each with its own
# block below: the dispatch head is netted out of every loose window
# (DISPATCH_LATENCY_TICKS), and every scenario runs as a perturbation FAMILY
# rather than as one chaotic sample (JITTERS / _family_idle). With both, a
# healthy team sits at 0-3%.

const Harness := preload("res://tests/unit/ai/duel_harness.gd")

# SkaterAgentStateMachine.State.CHASE_PUCK. The enum is private to the state
# machine; the harness exposes the live agents, so read the ordinal.
const CHASE_PUCK := 1

# Ticks at the START of each loose window that are not counted. A bot cannot be
# in CHASE_PUCK over a puck that came free less than one dispatch ago — it has
# not been asked yet — so those ticks measure the dispatch cadence rather than
# apathy, and the pathology this file exists to bound (a puck lying loose while
# both teams stand and watch it) cannot occur inside one.
#
# It matters because the denominator is loose TICKS, not loose EPISODES, and the
# two come apart whenever a change makes possession stickier: the same number of
# scrambles resolve faster, which shrinks the denominator while the fixed
# per-episode latency stays put, so the ratio climbs on an improvement. Measured
# while chasing exactly that on the OZ-rebound fixture — loose episodes 28 -> 31
# (flat) but their mean length 6.8 -> 2.8 ticks, i.e. windows averaging 23 ms,
# most of which no bot had been dispatched in yet.
#
# Netting the head out is what makes the number mean what the thresholds were
# written about. It also TIGHTENS them: on the fixtures as they stand the four
# team readings fall from ~15% to 0-1%, so a real case of nobody going now has
# the whole band to show up in instead of sharing it with the read latency.
const DISPATCH_LATENCY_TICKS: int = SkaterAgentStateMachine.DISPATCH_PERIOD_TICKS + 1


# Runs the sim and returns team_id -> percent of live-loose ticks with nobody
# on that team in CHASE_PUCK. Ticks inside a loose window's dispatch head are
# excluded (see DISPATCH_LATENCY_TICKS).
func _idle_chase_pct(spots: Array, puck: Vector3, puck_vel: Vector3,
		secs: float) -> Dictionary:
	var h = Harness.new()
	var pid: int = 100
	for spot: Array in spots:
		h.add_skater(pid, spot[0], spot[1])
		pid += 1
	h.start(-1, puck)
	h.puck_vel = puck_vel
	var idle := {0: 0, 1: 0}
	var live: int = 0
	var loose_age: int = 0
	for _i: int in int(secs / Harness.DT):
		h.step()
		if h.carrier_id != -1:
			loose_age = 0
			continue
		loose_age += 1
		if loose_age <= DISPATCH_LATENCY_TICKS:
			continue
		live += 1
		var chasing := {0: 0, 1: 0}
		for s in h.skaters:
			if s.agent != null and s.agent._state == CHASE_PUCK:
				chasing[s.team_id] += 1
		for tid: int in [0, 1]:
			if chasing[tid] == 0:
				idle[tid] += 1
	return {
		0: 100.0 * idle[0] / maxf(live, 1.0),
		1: 100.0 * idle[1] / maxf(live, 1.0),
	}


# ── Why every scenario runs as a FAMILY, not as one fixture ──────────────────
# Each of these is a 6-body sim over several seconds, and it is CHAOTIC: a
# millimetre of difference in where a blade holds the puck re-orders every
# collision after it, and by two seconds in you are comparing two unrelated
# games. One fixture therefore measures a sample, not a behavior.
#
# Measured, not assumed. Perturbing the OZ-rebound scenario's start spots and
# rebound velocity across 30 variants, THREE of them exceeded the old 40% bound
# on code that was otherwise healthy — so the single-fixture assertion was
# bounding one lucky roll. It gates unrelated work at random in both directions:
# an in-flight carrier change tipped the shipped fixture from 1% to 55% while the
# family mean moved 2.5% -> 4.0% (i.e. nothing), and it took a 30-fixture
# ensemble to tell those apart. A regression that only shows up as one fixture
# crossing a line is indistinguishable from noise and must not fail the suite.
#
# So the family is the unit. Two assertions, because the pathology has two
# shapes: MEAN idle bounds systematic apathy (the real failure — 53-100% idle
# when nobody goes at all), and the OVER-BOUND COUNT catches "most situations are
# fine but a class of them is broken" without letting one chaotic outlier fail
# the run.
#
# Perturbations are a fixed table, never random: bot decisions must be
# replay-safe, and a flaky engagement test is worse than none.
const JITTERS: Array[Vector3] = [
	Vector3.ZERO,
	Vector3(0.7, 0.0, 0.4),
	Vector3(-0.6, 0.0, 0.5),
	Vector3(-0.9, 0.0, -0.3),
]
# Small bearing changes on the delivery — the puck's line is what decides who is
# on it, so rotating it is the perturbation that most changes the read.
const VEL_ROTATIONS_RAD: Array[float] = [0.0, 0.20, -0.20]

# Idle share must average below this across a family. Generous against the
# pathology it bounds (nobody going reads 53-100%) and far above the 0-3% a
# healthy family sits at, so it fails on behavior rather than on chaos.
const FAMILY_MEAN_IDLE_PCT: float = 20.0
# …and no more than this share of the family may individually blow past the
# single-fixture bound. One chaotic outlier is expected; a class of broken
# situations is not.
const FAMILY_OVER_BOUND_PCT: float = 40.0
const FAMILY_OVER_SHARE: float = 0.25


# Runs a scenario FAMILY (base + fixed perturbations) and returns, per team, the
# mean idle share and the fraction of variants above FAMILY_OVER_BOUND_PCT.
func _family_idle(spots: Array, puck: Vector3, puck_vel: Vector3,
		secs: float) -> Dictionary:
	var sum := {0: 0.0, 1: 0.0}
	var over := {0: 0, 1: 0}
	var n: int = 0
	for jitter: Vector3 in JITTERS:
		for rot: float in VEL_ROTATIONS_RAD:
			# Alternate the jitter's sign down the roster so the shape deforms
			# rather than translating — a translated scene is the same scene.
			var moved: Array = []
			for i: int in spots.size():
				var d: Vector3 = jitter if i % 2 == 0 else -jitter
				moved.append([spots[i][0], spots[i][1] + d])
			var idle: Dictionary = _idle_chase_pct(
					moved, puck, puck_vel.rotated(Vector3.UP, rot), secs)
			for tid: int in [0, 1]:
				sum[tid] += idle[tid]
				if idle[tid] > FAMILY_OVER_BOUND_PCT:
					over[tid] += 1
			n += 1
	return {
		"n": n,
		"mean": {0: sum[0] / n, 1: sum[1] / n},
		"over": {0: float(over[0]) / n, 1: float(over[1]) / n},
	}


# Asserts a team's family result and reports the numbers either way.
func _assert_family(r: Dictionary, tid: int, what: String) -> void:
	gut.p("  %s: mean idle %.1f%% over %d variants, %.0f%% of them above %.0f%%"
			% [what, r["mean"][tid], r["n"], 100.0 * r["over"][tid],
			FAMILY_OVER_BOUND_PCT])
	assert_lt(r["mean"][tid], FAMILY_MEAN_IDLE_PCT,
			"%s — family mean idle %.1f%%" % [what, r["mean"][tid]])
	assert_lte(r["over"][tid], FAMILY_OVER_SHARE,
			"%s — %.0f%% of variants idle past %.0f%%"
			% [what, 100.0 * r["over"][tid], FAMILY_OVER_BOUND_PCT])


func test_somebody_forechecks_a_dump_in() -> void:
	# Team 0 (defending +z) dumps into team 1's corner and changes ends. Every
	# one of team 0 is goal-side of the pickup, so the counter is contained
	# without a chaser and the honest read is to go forecheck it.
	#
	# Before the containment gate this measured 100% — the puck was dumped in,
	# every bot on the dumping team read the race as lost to the defence, and
	# NOBODY chased it for the entire loose window.
	var r: Dictionary = _family_idle([
		[0, Vector3(-4, 0, 2)], [0, Vector3(4, 0, 4)], [0, Vector3(0, 0, 14)],
		[1, Vector3(-6, 0, -14)], [1, Vector3(6, 0, -16)], [1, Vector3(0, 0, -22)],
	], Vector3(0, 0, -8), Vector3(-6, 0, -14), 4.0)
	_assert_family(r, 0, "the dumping team forechecks its own dump-in")
	_assert_family(r, 1, "the defending team retrieves it")


func test_somebody_pursues_a_rim_up_the_wall() -> void:
	# Puck rimmed up the wall into team 0's end with all of team 1 behind it.
	# Team 1 is chasing from behind and will probably lose the race — but with
	# their whole side goal-side of the pickup there is nothing to pre-contain,
	# so backchecking is free and standing still is not a read.
	#
	# Before the fixes this measured 77% for team 1: a flat-footed body off the
	# rim's line read as the winner of a race it was not running, and the
	# elected chaser retreated to the pre-contain point instead.
	var r: Dictionary = _family_idle([
		[0, Vector3(-10, 0, 4)], [0, Vector3(2, 0, 10)], [0, Vector3(0, 0, 20)],
		[1, Vector3(6, 0, -6)], [1, Vector3(-4, 0, -12)], [1, Vector3(0, 0, -20)],
	], Vector3(-12, 0, -6), Vector3(0, 0, 9), 4.0)
	_assert_family(r, 1, "the trailing team pursues the rim")


func test_somebody_goes_for_an_offensive_zone_rebound() -> void:
	# Loose rebound in the slot with both teams collapsed around it. Nobody has
	# anything better to do than get it; before the fixes team 0 stood off it
	# 61% of the loose window.
	var r: Dictionary = _family_idle([
		[0, Vector3(-2, 0, -20)], [0, Vector3(3, 0, -18)], [0, Vector3(0, 0, -10)],
		[1, Vector3(-1, 0, -23)], [1, Vector3(2, 0, -22)], [1, Vector3(0, 0, -14)],
	], Vector3(1, 0, -21), Vector3(3, 0, 4), 3.0)
	_assert_family(r, 0, "attackers go for the rebound")
	_assert_family(r, 1, "defenders go for the rebound")
