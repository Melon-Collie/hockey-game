extends GutTest

# ── Does a five-man D-zone shape actually COVER the attack? ───────────────────
# The 5v5 counterpart of test_defensive_routing.gd, and it exists because that
# file cannot see this: its sims are a carrier plus two defencemen, so
# RUSH_D2's man-picker returns -1, the cover path is never entered, and its
# metrics came out byte-identical across changes that provably altered coverage.
# Everything about who-covers-whom was therefore pinned only by single-dispatch
# unit tests, which cannot see a body over time.
#
# What this pins, all of it over multi-second sims on the real decision stack:
#
#   DISTINCTNESS — no attacker is covered by two defenders at once. Structural
#     since the zone roles joined TeamBrain's matching (their AREA is now
#     eligibility rather than a private search), and asserted hard because a
#     regression here is silent: five roles each running their own argmax over
#     the deliberately overlapping areas double-covered somebody on 61% of
#     D-zone ticks and stacked 52% of every lock issued, three deep at times.
#     Every redundant lock is a man left open somewhere else.
#
#     Asserted as a SHARE rather than as zero, because the guarantee lives at
#     the brain and the bodies are one step behind it. The matcher cannot emit
#     a duplicate, but dispatch is throttled and phase-offset per bot, so during
#     a handoff two defenders can briefly act on assignments from different
#     brain ticks. That skew is not a coverage failure and is not worth chasing.
#
# Read off each defender's OWN decision (RoleDecision.locked_man_pid, round-
# tripped as the agent's _prev_locked_man_pid), never off the brain's published
# partition. That distinction is the difference between a real guard and a
# tautology: the matcher hands out distinct men by construction, so asking IT
# whether two bodies share a man can only ever answer no. Asking the bodies
# works whoever made the choice, which is what lets this file fail if the
# per-role argmaxes ever come back.
#   UNATTENDED MEN — how many attackers INSIDE THE ZONE no defender has. This
#     is the claim the file is really making, and it is asserted directly
#     because the obvious proxy is not the same statement. Breadth — the count
#     of distinct men covered — is still reported, but it silently divides by
#     however many attackers happen to be in the zone, so it moves when the
#     ATTACK changes with the coverage untouched. It did exactly that: a
#     reception fix upstream turned the point-shot fixture from a scramble
#     (puck loose 51% of its life) into a real possession sequence, one attacker
#     left the zone, and breadth fell 2.43 -> 2.02 through a 2.2 floor while the
#     number of men going unattended barely moved. A count of men nobody has is
#     denominator-free and says what the assertion message says.
#   OPEN DANGER — the finish-danger of the most dangerous unattended man. The
#     outcome reading: the count above counts bodies, this counts what they
#     are worth.
#
# The bounds are PINNED MEASUREMENTS. The double-lock ceiling was chosen to sit
# between what the matching produces and what the five private argmaxes it
# replaced produced, run on these same three fixtures through the same bodies:
#
#                        matched            per-role argmaxes
#   double-locked        9% / 0% / 0%       15% / 49% / 23%
#   covered per tick     2.70 / 2.43 / 2.90 2.62 / 1.44 / 2.05
#
# The covered-per-tick row is kept for context only — it is the retired metric,
# and the argmax column CANNOT be re-derived under the unattended-men count
# (that model is gone from the tree, and its own in-zone attacker counts went
# with it). So the unattended ceiling is calibrated differently, against
# measured readings on these three fixtures:
#
#   unattended/tick   1.74 / 1.71 / 1.87   when the matching landed
#                     1.59 / 1.79 / 2.28   with the reception rendezvous
#                     1.59 / 1.57 / 2.00   with the gap-ladder / pinch fixes
#
# A regression to the argmaxes still breaks the double-lock ceiling, which is
# the guard that separated the two models sharply in the first place.
#
# Those three rows are also the argument for counting unattended men rather than
# covered ones, because the two middle changes moved the fixtures in opposite
# directions and only one metric read both honestly. The reception rendezvous
# cost the crossing cutter real coverage (1.87 -> 2.28) while breadth there
# stayed clear of its floor; the gap-ladder work then took the puck away from
# the attack in the point-shot fixture, which shrank its D-zone window from 360
# ticks to 260 and dragged BREADTH down through the same floor for a strictly
# better outcome — a hole the covered-per-tick metric could only be talked out
# of with a per-fixture exemption. Counting the men nobody has needs no
# exemption: it read the first as the regression it was and the second as the
# improvement it was (1.79 -> 1.57), because it never divides by how many
# attackers happen to be standing in the zone.
#
# The margins are deliberately modest; when one fails the question is "did the
# behaviour change on purpose", not "which bound do I loosen". Open danger is a
# much looser guard (it barely separated the two models) and is really there to
# catch a collapse.
#
# Worth knowing before reading too much into the old column: an earlier probe
# put the private argmaxes at 61% double-locked, but that sampled each role's
# picker fresh every tick. The BODIES were never that bad, because they only
# re-decide on their throttled dispatch. 15-49% is what actually reached the
# ice.
#
# WHAT THE HARNESS DOES NOT MODEL: body collisions. Attackers skate through
# defenders, so "did the coverage stop the play" is not a question this can
# answer and is never asserted. What it answers faithfully is who is standing
# on whom.
#
# Team 1 defends -Z (same convention as test_defensive_routing).

const Duel := preload("res://tests/unit/ai/duel_harness.gd")

const DT: float = 1.0 / 120.0
const SECS: float = 4.0
const NET_Z: float = -GameRules.GOAL_LINE_Z

const ZONE_SLOTS: Array[int] = [
	AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK,
	AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG,
	AIRoleSlots.Slot.ZONE_W_WEAK,
]

# Attackers in the zone that no defender has, per tick. See the header: pins the
# current measured readings (1.59 / 1.57 / 2.00), not a bound derived from the
# model it replaced. It sat at 2.4 for one commit to accept a crossing-cutter
# cost the reception rendezvous charged; the gap-ladder work paid that back, so
# the slack comes back out rather than sitting there hiding the next one.
const UNCOVERED_CEILING: float = 2.2
# The man nobody has should not routinely be a prime scoring threat. A loose
# guard — it separated the two models weakly — against a collapse.
const OPEN_DANGER_CEILING: float = 0.25
# Ceiling on the share of ticks with a man double-covered. See the table above.
const DOUBLE_LOCK_SHARE_CEILING: float = 0.12
# Fixture sanity: the sim has to actually spend time in D-zone coverage for any
# of the above to mean anything.
const MIN_DZONE_TICKS: int = 120


class Result:
	var dzone_ticks: int = 0
	var double_locked_ticks: int = 0
	var covered_sum: int = 0
	var in_zone_sum: int = 0
	var uncovered_sum: int = 0
	var open_danger_sum: float = 0.0
	var open_danger_worst: float = 0.0


# Runs a 5v5 sim with team 0 attacking and team 1 defending -Z, and reads team
# 1's coverage every tick it is actually in D-zone shape.
func _run(attackers: Array, defenders: Array, carrier: int) -> Result:
	var duel := Duel.new()
	duel.team_size = 5
	for i: int in attackers.size():
		duel.add_skater(1 + i, 0, attackers[i], BotSkillProfile.hard())
		duel.positions[1 + i] = i
	for i: int in defenders.size():
		duel.add_skater(50 + i, 1, defenders[i], BotSkillProfile.hard())
		duel.positions[50 + i] = i
	duel.start(carrier)

	var r := Result.new()
	var brain: TeamBrain = duel.brains[1]
	var our_net := Vector3(0.0, 0.0, NET_Z)
	var no_defenders: Array[Vector3] = []
	for _t: int in int(SECS / DT):
		duel.step()
		var snap: WorldSnapshot = duel._build_snapshot()
		if snap.puck_state == null \
				or brain.state != AIPossessionState.State.DZONE:
			continue
		r.dzone_ticks += 1

		# Who has whom, as each DEFENDER decided (see the header).
		var covered: Dictionary = {}
		var doubled: bool = false
		for pid: int in brain.slot_assignments:
			if not ZONE_SLOTS.has(brain.slot_assignments[pid]):
				continue
			var agent: Object = duel._skater(pid).agent
			var man: int = agent._prev_locked_man_pid if agent != null else -1
			if man == -1:
				continue
			if covered.has(man):
				doubled = true
			covered[man] = true
		if doubled:
			r.double_locked_ticks += 1
		r.covered_sum += covered.size()

		# The attackers IN THE ZONE that nobody has, and the most dangerous of
		# them. The carrier is excluded from both — the area that owns the puck is
		# pressuring him, not covering a man.
		var carrier_pid: int = snap.puck_state.carrier_peer_id
		var worst: float = 0.0
		for opp: int in snap.skater_states:
			if duel.team_map.get(opp, -1) == 1 or opp == carrier_pid:
				continue
			if snap.skater_states[opp].position.z >= -GameRules.BLUE_LINE_Z:
				continue   # not in the zone — nobody's to cover
			r.in_zone_sum += 1
			if covered.has(opp):
				continue
			r.uncovered_sum += 1
			worst = maxf(worst, AIActionScoring.score_shoot_threat_fielded(
					snap.skater_states[opp].position, our_net, our_net,
					GameRules.NET_HALF_WIDTH, no_defenders))
		r.open_danger_sum += worst
		r.open_danger_worst = maxf(r.open_danger_worst, worst)
	return r


func _report(label: String, r: Result) -> void:
	var n: float = float(maxi(r.dzone_ticks, 1))
	gut.p("      %-22s dzone %4d | double-locked %3d (%2d%%) | in zone/tick %.2f | covered %.2f | UNCOVERED %.2f | open danger mean %.4f worst %.4f"
			% [label, r.dzone_ticks, r.double_locked_ticks,
			roundi(100.0 * r.double_locked_ticks / n), r.in_zone_sum / n,
			r.covered_sum / n, r.uncovered_sum / n,
			r.open_danger_sum / n, r.open_danger_worst])


func _assert_shape(label: String, r: Result) -> void:
	assert_gt(r.dzone_ticks, MIN_DZONE_TICKS,
			"%s: fixture never settled into D-zone coverage" % label)
	var n: float = float(maxi(r.dzone_ticks, 1))
	assert_lt(r.double_locked_ticks / n, DOUBLE_LOCK_SHARE_CEILING,
			"%s: two defenders shared a man on %d of %d ticks — past the handoff skew"
			% [label, r.double_locked_ticks, r.dzone_ticks])
	assert_lt(r.uncovered_sum / n, UNCOVERED_CEILING,
			"%s: attackers in the zone are going unattended" % label)
	assert_lt(r.open_danger_sum / n, OPEN_DANGER_CEILING,
			"%s: a prime scoring threat is routinely uncovered" % label)


func test_a_low_cycle_is_covered() -> void:
	# The everyday D-zone look: puck worked low on the strong wall, a man at the
	# net front, a man in the slot, both points manned. Exercises the net-front
	# box, the slot seam and the low battle at once.
	gut.p("  ── 5v5 D-zone coverage ──")
	var r: Result = _run(
		[Vector3(9.0, 0.0, -22.0),    # carrier, strong wall low
		 Vector3(-1.5, 0.0, -24.0),   # net front
		 Vector3(0.5, 0.0, -20.0),    # slot
		 Vector3(6.0, 0.0, -14.0),    # strong point
		 Vector3(-6.0, 0.0, -14.0)],  # weak point
		[Vector3(4.0, 0.0, -22.0), Vector3(-2.0, 0.0, -24.5),
		 Vector3(0.0, 0.0, -19.0), Vector3(7.0, 0.0, -13.0),
		 Vector3(-7.0, 0.0, -13.0)],
		1)
	_report("low cycle", r)
	_assert_shape("low cycle", r)


func test_a_point_shot_setup_is_covered() -> void:
	# The puck up at the point with traffic below: the wingers own the high ice
	# and the D own the house, which is the split the areas are drawn for.
	var r: Result = _run(
		[Vector3(5.0, 0.0, -15.0),    # carrier at the strong point
		 Vector3(-0.5, 0.0, -24.5),   # net-front screen
		 Vector3(2.5, 0.0, -21.0),    # low slot
		 Vector3(-8.0, 0.0, -18.0),   # weak wall
		 Vector3(-5.0, 0.0, -15.0)],  # weak point
		[Vector3(1.0, 0.0, -23.0), Vector3(-1.5, 0.0, -24.5),
		 Vector3(0.5, 0.0, -19.5), Vector3(6.0, 0.0, -14.0),
		 Vector3(-6.0, 0.0, -14.5)],
		1)
	_report("point shot", r)
	_assert_shape("point shot", r)


func test_a_man_who_changes_areas_is_handed_off_not_dropped() -> void:
	# A cutter crossing from the weak side into the slot passes through two
	# areas. The handoff must not leave him uncovered for long, and must never
	# leave BOTH defenders on him — the release margin widens eligibility for
	# whoever holds him, so the seam is a handshake rather than a swap.
	var r: Result = _run(
		[Vector3(9.0, 0.0, -21.0),                                # carrier
		 Vector3(-7.0, 0.0, -19.0), Vector3(-1.0, 0.0, -24.0),
		 Vector3(6.0, 0.0, -14.0), Vector3(-6.0, 0.0, -14.0)],
		[Vector3(4.0, 0.0, -22.0), Vector3(-1.5, 0.0, -24.5),
		 Vector3(0.0, 0.0, -19.0), Vector3(7.0, 0.0, -13.5),
		 Vector3(-7.0, 0.0, -13.5)],
		1)
	_report("crossing cutter", r)
	_assert_shape("crossing cutter", r)
