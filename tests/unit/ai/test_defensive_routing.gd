extends GutTest

# ── How a defender GETS to his stand ─────────────────────────────────────────
# The gap ladder, the angling shade and the cover geometry all describe WHERE a
# defensive stand is. None of them describes the route to it, and for a long time
# nothing did: the steering flew every anchor as a parked point — full thrust at
# the spot, arrival-brake to a stop on it — which is correct for a station and
# wrong for every defensive stand, because a gap point, a cover point and a
# backchecker's hip all RIDE an opponent and sweep toward our net at his pace.
#
# The symptom was a defender who could only defend from ice he was already
# standing on. Starting near his man he tracked back fine; starting deep, with a
# real trip to make, he sprinted at the stand, braked to a stop on it, and was
# standing still when the rush arrived — beaten by any lateral cut, which is
# every rush. Same role, same ladder, same stand: the route was the whole
# difference. AISteering's moving-frame pursuit is the fix.
#
# The quantity this file measures is TIME IN SHAPE: the share of the rush, from
# our blue line in, that the defender spends both within a working gap of his man
# AND travelling with him rather than at him. It is a share of time rather than a
# reading at one instant on purpose — the defect was never a bad snapshot, it was
# a route that only worked from some starting positions, and a single frame
# cannot tell a defender who is converging from one who is about to be walked
# around. Two components, and both have to be true at once:
#
#   GAP — is he close enough to contest at all. A defender matched in velocity at
#     15 m is not defending anybody.
#   RELATIVE SPEED — how fast he is moving with respect to the man. Neither
#     position nor gap can see this: a defender parked exactly on his gap reads a
#     perfect stand and is about to be beaten by the first cut. Near zero means
#     he is travelling WITH him, gapped up and in shape.
#
# Alongside it, the INSIDE OFFSET at the zone entry — his position off the
# carrier→net line, signed toward the middle of the ice. Positive means he has
# taken the middle away and is steering the man to the boards, which is what
# angling IS.
#
# Reference readings over the 16-start sweep (start depth x attack lane), and
# from the defence-pair scenario below:
#
#                                  parked-point route   moving-frame route
#   mean share of time in shape            17%                 84%
#   deep starts (z <= -14)                  0%                 96%
#   in-zone time with nobody goal-side      5% (worst 48%)      0% (worst 0%)
#
# The inside offset does NOT improve and is not claimed to: the parked-point
# route reads a LARGER shade (+1.65 m vs +0.79 m) because it is measured off a
# body standing still a long way off the man, and a wide shade on someone you are
# not with is not angling. It is asserted only as a floor — a defender must end
# up on the middle side of his man, never trailing him to it.
#
# WHAT THE HARNESS DOES NOT MODEL: body collisions (the carrier skates through
# the defender), so "did he stop the rush" is not a question it can answer and is
# never asserted. What it answers faithfully is where the bodies are and how fast
# they are going, which is the whole of the defect.

const Duel := preload("res://tests/unit/ai/duel_harness.gd")

const DT: float = 1.0 / 120.0
const SECS: float = 4.0
# Team 1 defends -Z here, so the rush travels in -Z and our blue line is at
# -BLUE_LINE_Z.
const ENTRY_Z: float = -GameRules.BLUE_LINE_Z

# A defender is MEETING THE RUSH rather than travelling with it above this
# relative speed. Sized on the reversal it implies: a skater sheds speed at
# AISteering.ARRIVAL_BRAKE_DECEL_M_S2 (~10 m/s²), so 4 m/s of relative speed is
# ~0.4 s of pure braking before he can travel with the play at all — and a rush
# covers 3 m in that time, which is the whole gap.
const IN_SHAPE_REL_M_S: float = 4.0
# And close enough to contest. The gap ladder tops out at 3 sticks; add the
# anticipation lead the stand is built off (AIRoleHelpers.DEFENSIVE_ANTICIPATION_
# MAX_M) and one more stick of tolerance, since what is being bounded is "is he
# defending this man at all", not the ladder itself.
const IN_SHAPE_GAP_M: float = 3.0 * SkaterAgentStateMachine.BLADE_REACH_M \
		+ AIRoleHelpers.DEFENSIVE_ANTICIPATION_MAX_M \
		+ SkaterAgentStateMachine.BLADE_REACH_M
const MIN_SHARE_IN_SHAPE: float = 0.6


# The signed offset of `body` off the carrier→our-net line, positive toward the
# middle of the ice. This is the angling read: a defender shading the inside is
# steering the man to the boards.
static func _inside_offset(body: Vector3, carrier: Vector3, net: Vector3) -> float:
	var to_net: Vector3 = net - carrier
	to_net.y = 0.0
	if to_net.length() < 0.001:
		return 0.0
	to_net = to_net.normalized()
	var perp := Vector3(-to_net.z, 0.0, to_net.x)
	if perp.x * -signf(carrier.x) < 0.0:
		perp = -perp
	return (body - carrier).dot(perp)




# ── 1v1: the route itself ────────────────────────────────────────────────────

# One clean 1v1: an attacker carrying at the -Z net, one defender in that zone.
# No teammates, so the carrier's compete resolves to CARRY and what is measured
# is the defensive route and nothing else. Sampling starts at our blue line and
# ends when possession changes — a strip is the rush being killed, and the ticks
# after it belong to a different play.
func _rush(d_start: Vector3, c_start: Vector3) -> Dictionary:
	var duel := Duel.new()
	duel.add_skater(1, 0, c_start, BotSkillProfile.hard(), Vector3(0.0, 0.0, -7.0))
	duel.add_skater(2, 1, d_start, BotSkillProfile.hard())
	duel.start(1)

	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var in_shape: int = 0
	var samples: int = 0
	var entry_inside: float = 0.0
	for _t: int in int(SECS / DT):
		duel.step()
		if duel.carrier_id != 1:
			break
		var car: Object = duel._skater(1)
		if car.pos.z > ENTRY_Z:
			continue
		var dm: Object = duel._skater(2)
		if samples == 0:
			entry_inside = _inside_offset(dm.pos, car.pos, net)
		samples += 1
		if dm.pos.distance_to(car.pos) < IN_SHAPE_GAP_M \
				and (dm.vel - car.vel).length() < IN_SHAPE_REL_M_S:
			in_shape += 1
	return {"share": float(in_shape) / float(maxi(samples, 1)),
			"samples": samples, "inside": entry_inside}


func test_a_defender_with_a_trip_to_make_still_arrives_in_shape() -> void:
	# The sweep is over START DEPTH first, because that is the variable the
	# parked-point route was sensitive to and the moving-frame route is not: a
	# defender already in the frame had no trip to make, so he was always fine.
	# What is pinned is that a defender 20 m from his stand ends up in the same
	# shape as one who started on it.
	var share_sum: float = 0.0
	var inside_sum: float = 0.0
	var deep_sum: float = 0.0
	var deep_n: int = 0
	var poor: Array[String] = []
	var killed: int = 0
	var n: int = 0
	for dz: float in [2.0, -8.0, -14.0, -20.0]:
		var row: String = "  D z=%6.1f :" % dz
		for cx: float in [-8.0, -3.0, 3.0, 8.0]:
			var r: Dictionary = _rush(Vector3(cx * 0.45, 0.0, dz),
					Vector3(cx, 0.0, 8.0))
			if r["samples"] < 20:
				# The rush never really entered — the defender killed it in the
				# neutral zone, which is a fine outcome and not a route reading.
				killed += 1
				row += "  x%+5.1f  killed at the line" % cx
				continue
			n += 1
			share_sum += r["share"]
			inside_sum += r["inside"]
			if dz <= -14.0:
				deep_sum += r["share"]
				deep_n += 1
			if r["share"] < MIN_SHARE_IN_SHAPE:
				poor.append("z%.0f/x%.0f" % [dz, cx])
			row += "  x%+5.1f shape%4.0f%% in%+5.1f" % [
					cx, r["share"] * 100.0, r["inside"]]
		gut.p(row)
	gut.p("  → mean share in shape %.0f%% | deep starts %.0f%% | mean inside %+.2f m | %d rushes killed at the line" % [
			share_sum / float(n) * 100.0,
			deep_sum / float(maxi(deep_n, 1)) * 100.0,
			inside_sum / float(n), killed])

	# The aggregate is the assertion. A 1v1 with no body contact is a chaotic
	# sim, so no single start is pinned to a value; what is pinned is that the
	# population travels WITH the play rather than into it.
	assert_gt(share_sum / float(n), MIN_SHARE_IN_SHAPE,
			"defenders are not holding a gap on the man they are defending")
	assert_lt(poor.size(), n / 2,
			"most starts never got into shape — the route is a charge: %s"
					% str(poor))
	# The whole defect: deep starts behaved differently from shallow ones. They
	# must not any more, so the deep half is held to the same bar as the mean.
	assert_gt(deep_sum / float(maxi(deep_n, 1)), MIN_SHARE_IN_SHAPE,
			"a defender with a long trip to his stand still never settles into it")
	# And he arrives on the INSIDE of the man, not trailing him to the middle.
	assert_gt(inside_sum / float(n), 0.5,
			"defenders are not angling the carrier off the middle")


# ── The layer: attackers vs a defence pair ───────────────────────────────────

# BLOWN BY is defined the way it reads from the bench: an attacker is inside our
# zone and NOBODY is between him and the net — every defender is farther from our
# goal than he is, measured radially (not in Z, which credits a body on the far
# boards as being in front of a rush he is nowhere near). Counted in ticks,
# because one frame of it during a crossover is noise and half a second of it is
# a breakaway.
#
# `attackers` is a list of [start, velocity]; the first carries the puck.
func _layer_rush(attackers: Array) -> Dictionary:
	var duel := Duel.new()
	for i: int in attackers.size():
		duel.add_skater(1 + i, 0, attackers[i][0], BotSkillProfile.hard(),
				attackers[i][1])
	var d_ids: Array[int] = [50, 51]
	duel.add_skater(50, 1, Vector3(-5.0, 0.0, -17.0), BotSkillProfile.hard())
	duel.add_skater(51, 1, Vector3(5.0, 0.0, -20.0), BotSkillProfile.hard())
	duel.start(1)

	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var beaten: int = 0
	var samples: int = 0
	var closest: float = INF
	for _t: int in int(SECS / DT):
		duel.step()
		if duel.carrier_id != 1:
			break   # possession changed — the rush this measures is over
		var carrier: Object = duel._skater(1)
		if carrier.pos.z > ENTRY_Z:
			continue
		samples += 1
		var d_depths: Array[float] = []
		for pid: int in d_ids:
			d_depths.append(duel._skater(pid).pos.distance_to(net))
		# Nobody goal-side of ANY attacker who is inside the line.
		for i: int in attackers.size():
			var a: Object = duel._skater(1 + i)
			if a.pos.z > ENTRY_Z:
				continue
			var a_depth: float = a.pos.distance_to(net)
			closest = minf(closest, a_depth)
			if d_depths[0] > a_depth and d_depths[1] > a_depth:
				beaten += 1
				break
	return {"beaten": beaten, "samples": samples, "closest": closest}


func test_two_defencemen_are_not_blown_by_a_neutral_zone_rush() -> void:
	# The shape the whole rush-defense structure exists for, and the one a 1v1
	# cannot express: with two bodies back the question stops being "is this
	# defender gapped" and becomes "does the LAYER hold". The pair can each be
	# individually well-gapped and still both be beaten if they route the same
	# way at the same time.
	#
	# Lanes across the width, at a walking entry (the gap-up case) and a flying
	# one (the case the gap ladder exists for).
	var beaten_sum: float = 0.0
	var worst: float = 0.0
	var offenders: Array[String] = []
	var n: int = 0
	for cx: float in [-9.0, -4.0, 0.0, 4.0, 9.0]:
		for speed: float in [4.0, 7.5]:
			var r: Dictionary = _layer_rush(
					[[Vector3(cx, 0.0, 6.0), Vector3(0.0, 0.0, -speed)]])
			n += 1
			var frac: float = float(r["beaten"]) / float(maxi(r["samples"], 1))
			beaten_sum += frac
			worst = maxf(worst, frac)
			if frac > 0.25:
				offenders.append("x%.0f/%.1f" % [cx, speed])
			gut.p("  x%+5.1f v%4.1f : nobody goal-side %3d/%3d (%3.0f%%)  closest to net %5.1f m" % [
					cx, speed, r["beaten"], r["samples"], frac * 100.0, r["closest"]])
	gut.p("  → mean share of in-zone time with nobody goal-side: %.0f%% (worst %.0f%%)" % [
			beaten_sum / float(n) * 100.0, worst * 100.0])

	# A rush that gets inside the layer for a beat happens — a defender loses a
	# step on a cut and recovers, and the harness has no body contact to stop the
	# carrier skating through him. What must not happen is an attacker spending
	# the rush unaccompanied, which is what "blown by" means.
	assert_lt(beaten_sum / float(n), 0.25,
			"attackers spend most of the zone with nobody between them and the net")
	assert_eq(offenders.size(), 0,
			"a defence pair was blown by on these entries: %s" % str(offenders))


# ── The neutral zone: does the shape leave a man home? ───────────────────────
#
# A different failure from the two above, and a TEAM one: the individual routes
# can all be good and the shape still lose, because every station stepped up at
# once. NEUTRAL's flank stand is a rigid offset off the puck, so both flanks
# follow it wherever it goes; and the bound on that stand only asked whether a
# man had ALREADY got behind them, which in a neutral-zone puck race is nobody —
# both teams are converging on a loose puck. So every station read clear, all
# three bodies ended up within a few metres of the puck, and whoever won it had
# beaten the whole team. `AIRoleHelpers.home_layer_behind_me` is the missing
# clause; `AIRoleFlank` supplies the layer's stand.
#
# WHAT IS MEASURED, and why it is the shape rather than the outcome. The obvious
# reading — the share of the following rush spent with nobody between their puck
# and our net — does not work. Over a 5 s six-body sim with no body contact that
# number is set by everything downstream of the shape (who wins the next battle,
# whether a feed connects) and swings 0-66% between starts of the SAME condition;
# measured both ways over six starts it read 19% before this bound and 21% after,
# which is noise, not a result. The turnover instant saturates in the other
# direction: an opponent first touches the puck while everyone is still deep, so
# it reads 3/3 either way.
#
# So the read is the SHAPE, during the loose-puck window that the bound governs:
# how far from our own net does our DEEPEST body get. A team with a layer keeps
# one back around its own blue line; a team that steps up as a group has its
# deepest man climbing with the other two, and the number is then just "where the
# puck is". That is the complaint stated literally, it is what this bound
# controls, and it is settled before the downstream variance starts.
#
#   Reference over the 8-start sweep:   no numbers half  →  with it
#     mean deepest-body drift                  21.8 m            20.2 m
#     worst single start                       24.0 m            22.0 m
#     starts with nobody left back              3/8               0/8
#
# The window is the FIRST 2.5 s, which is where the shape is set. Run it longer
# and a puck that rims into their end starts dragging the whole team after it,
# which is correct play and not this bound's business — the reading gets noisier
# without getting more informative.
#
# Be careful what this table is claiming. It is a measurement of the SHAPE, and
# the shape moves by about a stride and a half. What it is NOT is a measured
# improvement in goals or in rushes survived: over six-body sims with no body
# contact, that outcome is not resolvable at this sample size in either
# direction, and the honest attempt above is recorded so nobody re-derives it.
const LOOSE_SECS: float = 2.5
# How far off our own net the deepest body may drift while the puck is loose in
# neutral ice. Sized on the shape it is meant to leave standing: the NEUTRAL back
# post sits at our own blue line (AIZoneCoverage.defensive_anchor), which is
# GOAL_LINE_Z - BLUE_LINE_Z from the net, plus a stride of tolerance for a body
# that is still skating to it.
const LAYER_DRIFT_MAX_M: float = GameRules.GOAL_LINE_Z - GameRules.BLUE_LINE_Z + 3.0


# Team 0 attacks -Z; team 1 defends it. Returns how far from our own net our
# DEEPEST body gets while the puck is loose in neutral ice.
func _deepest_body_drift(puck_at: Vector3, their_edge: float) -> float:
	var duel := Duel.new()
	duel.add_skater(1, 0, Vector3(-4.0, 0.0, 6.0 - their_edge),
			BotSkillProfile.hard(), Vector3(0.0, 0.0, -4.0))
	duel.add_skater(2, 0, Vector3(3.0, 0.0, 9.0 - their_edge), BotSkillProfile.hard())
	duel.add_skater(3, 0, Vector3(9.0, 0.0, 12.0), BotSkillProfile.hard())
	duel.add_skater(11, 1, Vector3(-5.0, 0.0, -9.0), BotSkillProfile.hard())
	duel.add_skater(12, 1, Vector3(1.0, 0.0, -12.0), BotSkillProfile.hard())
	duel.add_skater(13, 1, Vector3(6.0, 0.0, -10.0), BotSkillProfile.hard())
	duel.start(-1, puck_at)

	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var worst: float = 0.0
	for _t: int in int(LOOSE_SECS / DT):
		duel.step()
		var deepest: float = INF
		for pid: int in [11, 12, 13]:
			deepest = minf(deepest, duel._skater(pid).pos.distance_to(net))
		worst = maxf(worst, deepest)
	return worst


func test_the_neutral_shape_leaves_a_man_home() -> void:
	var sum: float = 0.0
	var worst: float = 0.0
	var offenders: Array[String] = []
	var n: int = 0
	for puck_z: float in [4.0, 2.0, 0.0, -2.0]:
		var row: String = "  puck z%+5.1f :" % puck_z
		for edge: float in [0.0, 3.0]:
			var drift: float = _deepest_body_drift(
					Vector3(0.0, 0.0, puck_z), edge)
			n += 1
			sum += drift
			worst = maxf(worst, drift)
			if drift > LAYER_DRIFT_MAX_M:
				offenders.append("z%.0f/edge%.0f" % [puck_z, edge])
			row += "  edge%3.0f deepest %5.1f m" % [edge, drift]
		gut.p(row)
	gut.p("  → deepest body drifts a mean %.1f m off our own net while the puck is loose (worst %.1f)" % [
			sum / float(n), worst])

	assert_lt(sum / float(n), LAYER_DRIFT_MAX_M,
			"the neutral shape steps up as a group — nobody stays home")
	assert_eq(offenders.size(), 0,
			"no body stayed back on these loose pucks: %s" % str(offenders))
