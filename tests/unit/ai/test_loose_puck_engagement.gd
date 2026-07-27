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
# A floor of ~15% is expected and correct: the bot skill profile's reaction
# delay, plus the ticks between a puck coming free and the transition landing.

const Harness := preload("res://tests/unit/ai/duel_harness.gd")

# SkaterAgentStateMachine.State.CHASE_PUCK. The enum is private to the state
# machine; the harness exposes the live agents, so read the ordinal.
const CHASE_PUCK := 1


# Runs the sim and returns team_id -> percent of live-loose ticks with nobody
# on that team in CHASE_PUCK.
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
	for _i: int in int(secs / Harness.DT):
		h.step()
		if h.carrier_id != -1:
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


func test_somebody_forechecks_a_dump_in() -> void:
	# Team 0 (defending +z) dumps into team 1's corner and changes ends. Every
	# one of team 0 is goal-side of the pickup, so the counter is contained
	# without a chaser and the honest read is to go forecheck it.
	#
	# Before the containment gate this measured 100% — the puck was dumped in,
	# every bot on the dumping team read the race as lost to the defence, and
	# NOBODY chased it for the entire loose window.
	var idle: Dictionary = _idle_chase_pct([
		[0, Vector3(-4, 0, 2)], [0, Vector3(4, 0, 4)], [0, Vector3(0, 0, 14)],
		[1, Vector3(-6, 0, -14)], [1, Vector3(6, 0, -16)], [1, Vector3(0, 0, -22)],
	], Vector3(0, 0, -8), Vector3(-6, 0, -14), 4.0)
	assert_lt(idle[0], 40.0,
			"the dumping team forechecks its own dump-in (idle %.0f%%)" % idle[0])
	assert_lt(idle[1], 40.0,
			"the defending team retrieves it (idle %.0f%%)" % idle[1])


func test_somebody_pursues_a_rim_up_the_wall() -> void:
	# Puck rimmed up the wall into team 0's end with all of team 1 behind it.
	# Team 1 is chasing from behind and will probably lose the race — but with
	# their whole side goal-side of the pickup there is nothing to pre-contain,
	# so backchecking is free and standing still is not a read.
	#
	# Before the fixes this measured 77% for team 1: a flat-footed body off the
	# rim's line read as the winner of a race it was not running, and the
	# elected chaser retreated to the pre-contain point instead.
	var idle: Dictionary = _idle_chase_pct([
		[0, Vector3(-10, 0, 4)], [0, Vector3(2, 0, 10)], [0, Vector3(0, 0, 20)],
		[1, Vector3(6, 0, -6)], [1, Vector3(-4, 0, -12)], [1, Vector3(0, 0, -20)],
	], Vector3(-12, 0, -6), Vector3(0, 0, 9), 4.0)
	assert_lt(idle[1], 40.0,
			"the trailing team pursues the rim (idle %.0f%%)" % idle[1])


func test_somebody_goes_for_an_offensive_zone_rebound() -> void:
	# Loose rebound in the slot with both teams collapsed around it. Nobody has
	# anything better to do than get it; before the fixes team 0 stood off it
	# 61% of the loose window.
	var idle: Dictionary = _idle_chase_pct([
		[0, Vector3(-2, 0, -20)], [0, Vector3(3, 0, -18)], [0, Vector3(0, 0, -10)],
		[1, Vector3(-1, 0, -23)], [1, Vector3(2, 0, -22)], [1, Vector3(0, 0, -14)],
	], Vector3(1, 0, -21), Vector3(3, 0, 4), 3.0)
	assert_lt(idle[0], 40.0, "attackers go for the rebound (idle %.0f%%)" % idle[0])
	assert_lt(idle[1], 40.0, "defenders go for the rebound (idle %.0f%%)" % idle[1])
