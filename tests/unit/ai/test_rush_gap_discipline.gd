extends GutTest

# ── The rush gap defender's STEP-UP discipline ───────────────────────────────
# The failure this pins is the one regime the gap ladder does not describe by
# itself: the defenseman already home in his own zone with the carrier still in
# NEUTRAL ICE. There the ladder names a stand 10-18 m up-ice — past the sprint
# engage gap — so RUSH_D1 charged it at a full stride, met the rush head-on
# carrying all that momentum the wrong way, and was walked around from every
# start depth and every lane. He then trailed the play home from behind, which
# is what "they aren't even trying" looks like from the bench.
#
# No single-dispatch test catches it. Each tick's target is individually
# defensible — it IS the gap the ladder asks for — and the pathology only exists
# in how the body gets there, over time. So this measures the body: on the real
# decision stack, over a sweep of start depths x attack lanes, how much up-ice
# speed is the defender carrying when the carrier reaches him, and how far off
# his own net did he wander to arrive that way.
#
# WHAT THE HARNESS DOES NOT MODEL: body collisions. The carrier skates THROUGH
# the defender here, so "did he stop the rush" is not a question this sim can
# answer and is deliberately not asserted. What it does answer faithfully is
# where both bodies are and how fast they are going, which is the whole of the
# defect.
#
# Thresholds are coarse on purpose (the harness's assertion philosophy) — they
# bound the pathology, not the tuning. Reference readings over the 35-start
# sweep, across the four models this has had: the unbounded ladder, the step-up
# PLAN that first bounded it, the approach-SPEED limit that replaced the plan,
# and the MOVING-FRAME ROUTE that retired all three:
#
#                              charging   step-up plan   approach limit   route
#   mean up-ice speed at meet   4.2 m/s      2.4 m/s        2.2 m/s       1.0 m/s
#   starts meeting at >3 m/s     27/35        12/35          12/35          5/35
#   mean excursion off own net   10.9 m       4.2 m          5.1 m         0.7 m
#   worst single excursion       28.5 m      10.8 m          9.2 m         2.0 m
#   separation at the meet       0.69 m      0.57 m         0.84 m        2.85 m
#
# The first three columns are all attempts to bound a CHARGE by placing the stand
# somewhere a charge would end set. The fourth removes the charge instead: the
# stand rides the carrier and the steering flies the route in its frame
# (AISteering, "moving-frame pursuit"), so the approach is a commanded velocity
# that decays onto the rush's own by arrival, and RUSH_D1 no longer runs a
# stand-placement bound at all (AIRoleRushD._settable_gap). The excursion
# collapsing to under a metre is the visible shape of that: a defender who
# understands the stand is coming to him does not go and fetch it. The separation
# rising to a genuine stick-and-a-half is the other half — he is holding a gap
# rather than repeatedly colliding with the man he could not slow down for.

const Duel := preload("res://tests/unit/ai/duel_harness.gd")

const DT: float = 1.0 / 120.0
const SECS: float = 4.0
# A defender is LUNGING if he still carries this much speed away from his own
# net when the carrier arrives. Sized as the pace at which the reversal costs
# more than the rush gives you: a skater sheds speed at ARRIVAL_BRAKE_DECEL,
# so 3 m/s is already ~0.4 s of pure braking before he can travel with the play
# at all — and a rush covers 3 m in that time.
const LUNGE_M_S: float = 3.0
# How far off his own net the gap defender may wander to meet a neutral-zone
# rush. The blue line is 19.4 m of ice from the goal line, so a D starting at
# home post depth still has room to stand up near his own line; what this bars
# is the excursion PAST it, into the neutral zone, chasing a stand he cannot
# hold. Sized between the two readings above (10.8 m worst / 28.5 m worst), and
# nearer the bounded one — this catches a single start reverting, not the mean.
const MAX_EXCURSION_M: float = 14.0
# Mean excursion across the sweep — the whole-team version of the same read.
const MAX_MEAN_EXCURSION_M: float = 7.0


# One clean 1v1: an attacker carrying at the -Z net from neutral ice, one
# defender home in that zone. No teammates, so the carrier's compete resolves to
# CARRY and what is measured is the gap and nothing else.
func _rush(d_start: Vector3, carrier_start: Vector3) -> Dictionary:
	var duel := Duel.new()
	duel.add_skater(1, 0, carrier_start, BotSkillProfile.hard(),
			Vector3(0.0, 0.0, -7.0))
	duel.add_skater(2, 1, d_start, BotSkillProfile.hard())
	duel.start(1)

	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var max_net_dist: float = d_start.distance_to(net)
	var min_sep: float = INF
	var up_ice_at_meet: float = 0.0
	for _t: int in int(SECS / DT):
		duel.step()
		var dman: Object = duel._skater(2)
		var car: Object = duel._skater(1)
		max_net_dist = maxf(max_net_dist, dman.pos.distance_to(net))
		var sep: float = dman.pos.distance_to(car.pos)
		if sep < min_sep:
			min_sep = sep
			# Speed along "away from my own net" at the closest approach — the
			# momentum he has to reverse before he can defend anything.
			up_ice_at_meet = maxf(dman.vel.dot((dman.pos - net).normalized()), 0.0)
	return {"up_ice": up_ice_at_meet, "sep": min_sep,
			"excursion": max_net_dist - d_start.distance_to(net)}


func test_gap_defender_does_not_charge_a_neutral_zone_rush() -> void:
	var lunges: Array[String] = []
	var over_excursion: Array[String] = []
	var up_sum: float = 0.0
	var exc_sum: float = 0.0
	var sep_sum: float = 0.0
	var worst_exc: float = 0.0
	var n: int = 0
	for dz: float in [-22.0, -20.0, -18.0, -16.0, -14.0, -12.0, -10.0]:
		var row: String = "  D z=%6.1f :" % dz
		for cx: float in [-8.0, -4.0, 0.0, 4.0, 8.0]:
			# The D shades the carrier's lane (he is not caught on the far wall);
			# the carrier starts just inside neutral ice on that lane.
			var r: Dictionary = _rush(Vector3(cx * 0.4, 0.0, dz),
					Vector3(cx, 0.0, 2.0))
			n += 1
			up_sum += r["up_ice"]
			exc_sum += r["excursion"]
			sep_sum += r["sep"]
			worst_exc = maxf(worst_exc, r["excursion"])
			var tag: String = "z%.0f/x%.0f" % [dz, cx]
			if r["up_ice"] > LUNGE_M_S:
				lunges.append(tag)
			if r["excursion"] > MAX_EXCURSION_M:
				over_excursion.append(tag)
			row += "  x%+5.1f up%4.1f exc%+5.1f" % [cx, r["up_ice"], r["excursion"]]
		gut.p(row)
	gut.p("  → mean up-ice at meet %.1f m/s | over the lunge bar %d/%d | mean excursion %.1f m | worst %.1f m | mean separation %.2f m" % [
			up_sum / float(n), lunges.size(), n, exc_sum / float(n), worst_exc,
			sep_sum / float(n)])

	# The aggregate is the assertion: a defender meeting the rush with some speed
	# on is ordinary gap control (he closed the last metres as the budget opened
	# up), and a 1v1 with no body contact is a chaotic sim, so no single start is
	# pinned. What is pinned is that the population is not CHARGING — the
	# charging ladder put 27 of 35 starts over the lunge bar and averaged 4.2 m/s.
	assert_lt(up_sum / float(n), LUNGE_M_S,
			"the gap defender must meet a neutral-zone rush SET, not charging")
	assert_lt(lunges.size(), n / 2,
			"most starts met the rush at speed — the step-up is a charge: %s"
					% str(lunges))
	assert_lt(exc_sum / float(n), MAX_MEAN_EXCURSION_M,
			"the gap defenders are leaving their own zone to meet the rush")
	assert_eq(over_excursion.size(), 0,
			"the gap defender chased the stand out of his own zone: %s"
					% str(over_excursion))


func test_gap_defender_still_closes_on_a_stalled_carrier() -> void:
	# The bound must not turn into passivity: a carrier with no speed to beat
	# anyone with is the gap-up case, and the defender is supposed to take the
	# ice. Same geometry, carrier barely moving.
	var duel := Duel.new()
	duel.add_skater(1, 0, Vector3(0.0, 0.0, 2.0), BotSkillProfile.hard(),
			Vector3(0.0, 0.0, -0.5))
	duel.add_skater(2, 1, Vector3(0.0, 0.0, -18.0), BotSkillProfile.hard())
	duel.start(1)
	var closest: float = INF
	for _t: int in int(SECS / DT):
		duel.step()
		closest = minf(closest,
				duel._skater(2).pos.distance_to(duel._skater(1).pos))
	gut.p("  → stalled carrier: defender closed to %.1f m" % closest)
	assert_lt(closest, 4.0,
			"a carrier with no speed advantage must be attacked, not contained")
