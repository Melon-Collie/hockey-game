extends GutTest

# Do the 5v5 defencemen actually get to the offensive blue line?
#
# The reported failure is that they do not — the forwards end up cycling alone
# while both D sit well back, so the attack is outnumbered in the zone.
#
# The station target runs through AIRoleHelpers.offensive_station_target, which
# is the pinch read (plan §13): hold the forward stand while we have real
# control and either support behind us or nobody behind us; otherwise back off
# to the numbers layer; and if the puck is not ours at all, retreat to structure.
# _decide_point's own stand is line_z = -own_dir * (BLUE_LINE_Z + POINT_INSET_M),
# so for team 0 (attacking -z) a held point sits at z = -9.29.
#
# This measures where they really end up over a settled offensive-zone
# possession, so the question stops being read off the code and starts being a
# number.

const Harness := preload("res://tests/unit/ai/duel_harness.gd")

# Team 0 attacks -z. Slots 0-2 are forwards, 3+ are defence
# (PlayerRules.FIRST_DEFENSE_SLOT).
const OUR_F1 := 1
const OUR_F2 := 2
const OUR_F3 := 3
const OUR_D1 := 4
const OUR_D2 := 5
const THEIR := [11, 12, 13, 14, 15]

# Where a held point stands, and how close counts as "at the line".
var _point_z: float = -(GameRules.BLUE_LINE_Z + 2.0)
const AT_LINE_TOL_M: float = 3.0
# Seconds of cycle each assertion measures — see _run_cycle's shelf-life note.
const CYCLE_S: float = 3.0


class Sample:
	var d1_z: float = 0.0
	var d2_z: float = 0.0
	var best_d1: float = INF
	var best_d2: float = INF
	var ours: int = 0
	var loose: int = 0
	var theirs: int = 0
	var ticks: int = 0
	# In-zone tick counts, bucketed by who had the puck at the time.
	var in_ours: int = 0
	var in_loose: int = 0
	var in_theirs: int = 0


# A settled offensive-zone cycle: our three forwards low in their end, our two D
# starting at the line, their five collapsed in their own zone. Our carrier works
# the puck along the wall — the situation the points exist for.
#
# Their five are scripted CONTAINERS holding a wide gap, not live forecheckers.
# That is deliberate: the pinch read's first question is whether the puck is
# genuinely ours, so a fixture where live opponents strip it inside a second
# measures the retreat (which is correct behaviour) instead of the hold. Holding
# possession is the precondition of the question, so the fixture has to grant it.
#
# THE GRANT HAS A SHELF LIFE, and CYCLE_S is it. The containers hold their gap
# forever, but our own five do not hold the puck forever: our share of it decays
# down the run (roughly 64% at 2 s, 42% at 3 s, ~30% past 4 s) as the cycle turns
# into passes and scrambles between our own players. Past that the fixture is no
# longer measuring a settled possession, and what it reports is a broken cycle —
# D1 chasing deep and D2 sagging out behind him, which both do eventually in ANY
# build. Measure inside the grant; a longer window is a different question.
func _run_cycle(seconds: float, live_opponents: bool = false) -> Sample:
	var h = Harness.new()
	h.team_size = 5
	h.positions = {
		OUR_F1: 0, OUR_F2: 1, OUR_F3: 2, OUR_D1: 3, OUR_D2: 4,
		THEIR[0]: 0, THEIR[1]: 1, THEIR[2]: 2, THEIR[3]: 3, THEIR[4]: 4,
	}
	h.add_skater(OUR_F1, 0, Vector3(7.5, 0.0, -21.0))    # strong-side wall, carrier
	h.add_skater(OUR_F2, 0, Vector3(-6.0, 0.0, -20.0))   # weak side
	h.add_skater(OUR_F3, 0, Vector3(0.5, 0.0, -16.0))    # high slot
	h.add_skater(OUR_D1, 0, Vector3(6.0, 0.0, _point_z))
	h.add_skater(OUR_D2, 0, Vector3(-6.0, 0.0, _point_z))
	var their_spots: Array = [
		Vector3(6.5, 0.0, -22.5), Vector3(-4.0, 0.0, -22.0),
		Vector3(0.0, 0.0, -19.0), Vector3(2.5, 0.0, -24.5),
		Vector3(-2.0, 0.0, -17.5)]
	for i: int in 5:
		if live_opponents:
			h.add_skater(THEIR[i], 1, their_spots[i])
		else:
			h.add_puppet_container(THEIR[i], 1, their_spots[i], 5.0, their_spots[i].z)
	h.start(OUR_F1)

	var s := Sample.new()
	var steps: int = int(seconds / Harness.DT)
	var our_ids := [OUR_F1, OUR_F2, OUR_F3, OUR_D1, OUR_D2]
	for _i: int in steps:
		h.step()
		s.ticks += 1
		var c: int = h.carrier()
		var z_d1: float = h.skater_pos(OUR_D1).z
		var z_d2: float = h.skater_pos(OUR_D2).z
		# Count a point as "up" when it is inside the offensive zone.
		var line_z: float = -GameRules.BLUE_LINE_Z
		var up: int = (1 if z_d1 < line_z else 0) + (1 if z_d2 < line_z else 0)
		if c == -1:
			s.loose += 1
			s.in_loose += up
		elif c in our_ids:
			s.ours += 1
			s.in_ours += up
		else:
			s.theirs += 1
			s.in_theirs += up
		var z1: float = h.skater_pos(OUR_D1).z
		var z2: float = h.skater_pos(OUR_D2).z
		# "Best" = deepest into the offensive zone (most negative) reached.
		s.best_d1 = minf(s.best_d1, z1)
		s.best_d2 = minf(s.best_d2, z2)
	s.d1_z = h.skater_pos(OUR_D1).z
	s.d2_z = h.skater_pos(OUR_D2).z
	return s


func test_the_points_hold_the_offensive_blue_line_during_a_cycle() -> void:
	var s: Sample = _run_cycle(CYCLE_S)
	gut.p("  point stand is z=%.2f (blue line %.2f)" % [_point_z, -GameRules.BLUE_LINE_Z])
	gut.p("  D1 ended z=%.2f (best %.2f) | D2 ended z=%.2f (best %.2f)"
			% [s.d1_z, s.best_d1, s.d2_z, s.best_d2])
	gut.p("  D1 is %.2f m off the stand | D2 is %.2f m off"
			% [absf(s.d1_z - _point_z), absf(s.d2_z - _point_z)])
	gut.p("  puck: ours %.0f%% | loose %.0f%% | theirs %.0f%%"
			% [100.0 * s.ours / s.ticks, 100.0 * s.loose / s.ticks,
			100.0 * s.theirs / s.ticks])
	# Points-in-zone as a share of the two available, per possession state. This
	# is the team-level number the complaint is really about: any single decision
	# can be defensible while the aggregate leaves the forwards alone.
	gut.p("  points in zone: ours %.0f%% | loose %.0f%% | theirs %.0f%%"
			% [100.0 * s.in_ours / maxf(2.0 * s.ours, 1.0),
			100.0 * s.in_loose / maxf(2.0 * s.loose, 1.0),
			100.0 * s.in_theirs / maxf(2.0 * s.theirs, 1.0)])
	# Asserted as "in the zone", not "on the stand": a point that goes DEEPER
	# than its stand is activating, not sagging, and the strong point
	# legitimately does that here (it wins a loose puck). The failure this
	# guards is the one reported — points out of the attack entirely.
	var line: float = -GameRules.BLUE_LINE_Z
	assert_lt(s.d1_z, line, "the strong point stays in the offensive zone")
	assert_lt(s.d2_z, line, "the weak point stays in the offensive zone")
	assert_lt(absf(s.d2_z - _point_z), AT_LINE_TOL_M,
			"and the weak-side point holds its blue-line stand")


func test_a_loose_puck_is_when_the_points_leave() -> void:
	# The measured asymmetry, pinned. With possession granted, the points are in
	# the offensive zone on EVERY tick — whether a teammate is holding the puck or
	# it is loose between our own players. So the station model positions them
	# correctly; what moves them is the read above it.
	var s: Sample = _run_cycle(CYCLE_S)
	var in_ours: float = 100.0 * s.in_ours / maxf(2.0 * s.ours, 1.0)
	var in_loose: float = 100.0 * s.in_loose / maxf(2.0 * s.loose, 1.0)
	gut.p("  in zone: ours %.0f%% | loose %.0f%%" % [in_ours, in_loose])
	assert_gt(in_ours, 95.0, "points hold the zone while a teammate carries")
	assert_gt(in_loose, 95.0,
			"and while the puck is loose between our own players")


func test_what_a_live_forecheck_does_to_the_points() -> void:
	# The same cycle with their five LIVE instead of scripted. This is the shape
	# the complaint is actually observed in, and it separates two very different
	# diagnoses: are the points mis-positioned while we hold the puck, or do they
	# simply never get to hold it? Report-only — what "should" happen once the
	# puck is genuinely theirs is a doctrine call, not something to assert here.
	var s: Sample = _run_cycle(4.0, true)
	gut.p("  LIVE opponents —")
	gut.p("    puck: ours %.0f%% | loose %.0f%% | theirs %.0f%%"
			% [100.0 * s.ours / s.ticks, 100.0 * s.loose / s.ticks,
			100.0 * s.theirs / s.ticks])
	gut.p("    points in zone: ours %.0f%% | loose %.0f%% | theirs %.0f%%"
			% [100.0 * s.in_ours / maxf(2.0 * s.ours, 1.0),
			100.0 * s.in_loose / maxf(2.0 * s.loose, 1.0),
			100.0 * s.in_theirs / maxf(2.0 * s.theirs, 1.0)])
	gut.p("    D1 ended z=%.2f | D2 ended z=%.2f" % [s.d1_z, s.d2_z])
	assert_gt(s.ticks, 0, "the live-forecheck cycle ran")
