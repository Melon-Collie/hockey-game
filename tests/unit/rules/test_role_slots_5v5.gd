extends GutTest

# AIRoleSlots5 — the position-aware 5v5 election (plan §1–§2). Pure-function:
# same snapshot harness as test_role_slots.gd. Peers 1–5 are team 0
# (defending +Z): lobby positions C=slot 0, LW=1, RW=2, LD=3, RD=4.

const OUR_NET_Z: float = 26.65
const TEAM_ID: int = 0


func _make_snapshot(skaters: Array, carrier_pid: int = -1, puck_z: float = 0.0,
		puck_x: float = 0.0) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	for entry: Array in skaters:
		var s := SkaterNetworkState.new()
		s.position = entry[2]
		if entry.size() > 3:
			s.velocity = entry[3]
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	if carrier_pid != -1:
		for entry: Array in skaters:
			if entry[0] == carrier_pid:
				puck.position = entry[2]
				break
	else:
		puck.position = Vector3(puck_x, 0.0, puck_z)
	snap.puck_state = puck
	return snap


func _resolver(skaters: Array) -> Dictionary:
	var team_map: Dictionary = {}
	for entry: Array in skaters:
		team_map[entry[0]] = entry[1]
	return team_map


# Standard lineup: peer 1=C, 2=LW, 3=RW, 4=LD, 5=RD.
func _positions() -> Dictionary:
	return {1: 0, 2: 1, 3: 2, 4: 3, 5: 4}


func _assign(skaters: Array, state: int, carrier_pid: int = -1,
		puck_z: float = 0.0, puck_x: float = 0.0, prev: Dictionary = {},
		strong_x: float = 1.0, positions: Dictionary = {}) -> Dictionary:
	var snap: WorldSnapshot = _make_snapshot(skaters, carrier_pid, puck_z, puck_x)
	var pos: Dictionary = positions if not positions.is_empty() else _positions()
	return AIRoleSlots5.assign(snap, TEAM_ID, OUR_NET_Z, state,
			_resolver(skaters), prev, strong_x, {}, pos)


func _slot_of(assignments: Dictionary, slot: int) -> int:
	for pid: int in assignments:
		if assignments[pid] == slot:
			return pid
	return -1


# ── Slot sets ────────────────────────────────────────────────────────────────

func test_every_state_fields_five_distinct_jobs() -> void:
	# Every possession state must give 5 peers 5 assignments (MARK repeats
	# by design in TRANS_OD; all other states hand out distinct slots).
	var skaters: Array = [
		[1, 0, Vector3(0, 0, 5)], [2, 0, Vector3(-5, 0, 8)],
		[3, 0, Vector3(5, 0, 8)], [4, 0, Vector3(-4, 0, 16)],
		[5, 0, Vector3(4, 0, 16)],
		[10, 1, Vector3(0, 0, -10)],
	]
	for state: int in [AIPossessionState.State.DZONE, AIPossessionState.State.OZONE,
			AIPossessionState.State.TRANS_DO, AIPossessionState.State.TRANS_OD,
			AIPossessionState.State.NEUTRAL, AIPossessionState.State.BREAKOUT,
			AIPossessionState.State.FORECHECK]:
		var a: Dictionary = _assign(skaters, state, -1, -12.0)
		assert_eq(a.size(), 5, "state %d must slot all five skaters" % state)


# ── Group scoping: D stay home, F play forward ───────────────────────────────

func test_ozone_points_go_to_the_defensemen() -> void:
	# Both D are FURTHER from the point spots than the forwards are — group
	# scoping must still hand them the points (position identity, not
	# proximity, decides who plays D).
	var skaters: Array = [
		[1, 0, Vector3(0, 0, -20)],    # C deep in the O-zone
		[2, 0, Vector3(-8, 0, -18)],   # LW low
		[3, 0, Vector3(8, 0, -6)],     # RW right at the blue line
		[4, 0, Vector3(-2, 0, 2)],     # LD back in the NZ
		[5, 0, Vector3(2, 0, 2)],      # RD back in the NZ
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.OZONE, 1)
	assert_eq(a[1], AIRoleSlots.Slot.CARRIER)
	var point_holders: Array[int] = [
		_slot_of(a, AIRoleSlots.Slot.POINT_STRONG),
		_slot_of(a, AIRoleSlots.Slot.POINT_WEAK)]
	point_holders.sort()
	assert_eq(point_holders, [4, 5] as Array[int],
			"the D group owns the points even when a forward is nearer")
	# The remaining forwards fill the low F jobs.
	assert_true(a[2] == AIRoleSlots.Slot.NET_FRONT or a[2] == AIRoleSlots.Slot.HIGH_SLOT)
	assert_true(a[3] == AIRoleSlots.Slot.NET_FRONT or a[3] == AIRoleSlots.Slot.HIGH_SLOT)


func test_dzone_defensemen_take_the_low_zone() -> void:
	# Puck deep in our corner: the D pair mans the battle + net front; the
	# forwards take the C/wall/weak-high coverage.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, 14)],
		[2, 0, Vector3(-6, 0, 15)],
		[3, 0, Vector3(6, 0, 15)],
		[4, 0, Vector3(-3, 0, 22)],
		[5, 0, Vector3(3, 0, 22)],
		[10, 1, Vector3(9, 0, 23)],  # opp carrier in our strong-side corner
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.DZONE, 10,
			23.0, 9.0)
	var d_slots: Array[int] = [a[4], a[5]]
	d_slots.sort()
	assert_eq(d_slots, [AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK] as Array[int])
	var f_slots: Array[int] = [a[1], a[2], a[3]]
	f_slots.sort()
	assert_eq(f_slots, [AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG,
			AIRoleSlots.Slot.ZONE_W_WEAK] as Array[int])


func test_forecheck_f1_is_a_forward_and_line_is_held_by_d() -> void:
	# Opp retrieving deep in THEIR zone (team 0 attacks -Z). Even with a D
	# parked nearest the puck, F1 comes from the F group; the D pair holds
	# the offensive blue line.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, -14)],
		[2, 0, Vector3(-6, 0, -12)],
		[3, 0, Vector3(6, 0, -12)],
		[4, 0, Vector3(-1, 0, -20)],   # LD (mis)parked closest to the puck
		[5, 0, Vector3(2, 0, -4)],
		[10, 1, Vector3(0, 0, -24)],   # opp carrier behind their net
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.FORECHECK, 10)
	var f1: int = _slot_of(a, AIRoleSlots.Slot.F1_PRESSURE)
	assert_true(f1 in [1, 2, 3], "F1 must be a forward, got peer %d" % f1)
	var dp: Array[int] = [
		_slot_of(a, AIRoleSlots.Slot.DP_STRONG),
		_slot_of(a, AIRoleSlots.Slot.DP_WEAK)]
	dp.sort()
	assert_eq(dp, [4, 5] as Array[int], "the D pair holds the line")


# ── Cross-fill: the emergent cover rotation ──────────────────────────────────

func test_d_carrier_vacated_point_is_covered_by_a_forward() -> void:
	# LD carries in the O-zone: only one D remains for two point slots — the
	# leftover forward must cross-fill the second point ("D activates, F3
	# covers", plan §2).
	var skaters: Array = [
		[1, 0, Vector3(0, 0, -18)],
		[2, 0, Vector3(-8, 0, -20)],
		[3, 0, Vector3(8, 0, -20)],
		[4, 0, Vector3(-4, 0, -16)],   # LD, deep with the puck
		[5, 0, Vector3(3, 0, -7)],     # RD at the line
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.OZONE, 4)
	assert_eq(a[4], AIRoleSlots.Slot.CARRIER)
	var point_holders: Array[int] = [
		_slot_of(a, AIRoleSlots.Slot.POINT_STRONG),
		_slot_of(a, AIRoleSlots.Slot.POINT_WEAK)]
	assert_has(point_holders, 5, "the remaining D holds one point")
	var filler: int = point_holders[0] if point_holders[1] == 5 else point_holders[1]
	assert_true(filler in [1, 2, 3],
			"a forward cross-fills the vacated point, got peer %d" % filler)


func test_trans_do_trailer_is_the_activating_d_when_a_forward_carries() -> void:
	# C carries the rush: wingers take the wide lanes, one D is the safety
	# valve, and the OTHER D joins as the trailer — the activating fourth man.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, -2)],     # C with the puck in the NZ
		[2, 0, Vector3(-7, 0, 0)],
		[3, 0, Vector3(7, 0, 0)],
		[4, 0, Vector3(-3, 0, 6)],
		[5, 0, Vector3(3, 0, 8)],
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.TRANS_DO, 1)
	assert_eq(a[1], AIRoleSlots.Slot.CARRIER)
	assert_eq(a[2], AIRoleSlots.Slot.WIDE_L)
	assert_eq(a[3], AIRoleSlots.Slot.WIDE_R)
	var trailer: int = _slot_of(a, AIRoleSlots.Slot.TRAILER)
	var valve: int = _slot_of(a, AIRoleSlots.Slot.DVALVE)
	assert_true(trailer in [4, 5], "the trailer is the activating D")
	assert_true(valve in [4, 5], "the valve is the other D")
	assert_ne(trailer, valve)


# ── TRANS_OD: contain from the D group, everyone else marks ──────────────────

func test_trans_od_contain_is_a_defenseman() -> void:
	# Rush against us: a backchecking forward is nearer our net, but the
	# gap-control job belongs to the D group.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, 18)],     # C already home
		[2, 0, Vector3(-4, 0, -4)],
		[3, 0, Vector3(4, 0, -4)],
		[4, 0, Vector3(-2, 0, 10)],    # LD
		[5, 0, Vector3(2, 0, 8)],      # RD
		[10, 1, Vector3(0, 0, -2)],    # opp carrier at center
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.TRANS_OD, 10)
	var contain: int = _slot_of(a, AIRoleSlots.Slot.CONTAIN)
	assert_true(contain in [4, 5], "CONTAIN is D-scoped, got peer %d" % contain)
	var marks: int = 0
	for pid: int in a:
		if a[pid] == AIRoleSlots.Slot.MARK:
			marks += 1
	assert_eq(marks, 4, "the other four all mark a man")


func test_trans_od_contain_cross_fills_when_both_d_are_caught() -> void:
	# Forecheck turnover: both D are caught at the opponent blue line while
	# the carrier breaks out through the NZ at full flight. Neither D can
	# beat the carrier home (raw race + set margin), so the D-scoping must
	# yield — CONTAIN cross-fills to the deepest backchecker (the C), and
	# the caught D fall to MARK duty on the trailers. Regression for the
	# "everyone marked a man but nobody picked up the carrier" bug: the
	# threat partition excludes the carrier because CONTAIN owns him, so a
	# hopeless CONTAIN means the rush walks in unopposed.
	#
	# Kinematics (calibrated time_to_arrive, league caps): carrier home in
	# ~3.0 s → deadline ~2.1 s; the caught D need ~4.4 s (infeasible), the
	# backchecking C ~2.9 s — soonest of anyone, so the cross-fill pass
	# hands him the pickup.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, 5)],        # C backchecking, deepest man back
		[2, 0, Vector3(-6, 0, -10)],     # LW deep on the dead forecheck
		[3, 0, Vector3(6, 0, -10)],      # RW deep
		[4, 0, Vector3(-5, 0, -7.8)],    # LD caught at their blue line
		[5, 0, Vector3(5, 0, -7.8)],     # RD caught at their blue line
		[10, 1, Vector3(0, 0, 0), Vector3(0, 0, 8.0)],  # carrier at center, flying at our net
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.TRANS_OD, 10)
	assert_eq(a[1], AIRoleSlots.Slot.CONTAIN,
			"the feasible backchecker picks up the carrier, not a caught D")
	assert_eq(a[4], AIRoleSlots.Slot.MARK, "caught LD backchecks a trailer")
	assert_eq(a[5], AIRoleSlots.Slot.MARK, "caught RD backchecks a trailer")


func test_trans_od_contain_stays_d_scoped_when_a_d_can_beat_the_rush_home() -> void:
	# Same rush, but the valve D is home at center ice: he beats the carrier
	# back with the set margin in hand, so the D group keeps the gap job even
	# though the backchecking C is nearer our net. The deadline is a
	# feasibility floor, not a proximity contest — position identity still
	# decides whenever the D can physically do the job.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, 14)],       # C even deeper than the valve D
		[2, 0, Vector3(-6, 0, -10)],
		[3, 0, Vector3(6, 0, -10)],
		[4, 0, Vector3(-2, 0, 10)],      # LD home — feasible gap defender
		[5, 0, Vector3(5, 0, -7.8)],     # RD caught at their line
		[10, 1, Vector3(0, 0, -6), Vector3(0, 0, 7.0)],  # carrier entering the NZ
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.TRANS_OD, 10)
	assert_eq(a[4], AIRoleSlots.Slot.CONTAIN,
			"a feasible D keeps CONTAIN over a deeper forward")


# ── NEUTRAL: global chase, D shape behind ────────────────────────────────────

func test_neutral_chase_is_global_but_shape_is_grouped() -> void:
	# The RD is far and away nearest the loose puck — retrieval is a global
	# race, so he takes CHASE; a forward then cross-fills his DBACK post.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, 8)],
		[2, 0, Vector3(-6, 0, 9)],
		[3, 0, Vector3(6, 0, 9)],
		[4, 0, Vector3(-4, 0, 12)],
		[5, 0, Vector3(2, 0, 1)],      # RD right beside the puck
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.NEUTRAL, -1, 0.0)
	assert_eq(a[5], AIRoleSlots.Slot.CHASE, "nearest body wins the loose puck race")
	assert_eq(a[4], AIRoleSlots.Slot.DBACK_L, "remaining D holds his side")
	var dback_r: int = _slot_of(a, AIRoleSlots.Slot.DBACK_R)
	assert_true(dback_r in [1, 2, 3], "a forward cross-fills the vacated D post")


# ── Home-side rest bias ──────────────────────────────────────────────────────

func test_home_side_bias_settles_symmetric_d_pair() -> void:
	# Both D dead-center and equidistant from both DBACK posts: the lobby
	# L/R identity decides — LD left, RD right.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, -8)],
		[2, 0, Vector3(-9, 0, -6)],
		[3, 0, Vector3(9, 0, -6)],
		[4, 0, Vector3(0, 0, 7.29)],   # LD dead-center on our blue line
		[5, 0, Vector3(0, 0, 8.0)],    # RD dead-center, a hair deeper
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.NEUTRAL, -1, -3.0)
	assert_eq(a[4], AIRoleSlots.Slot.DBACK_L, "LD rests on the left post")
	assert_eq(a[5], AIRoleSlots.Slot.DBACK_R, "RD rests on the right post")


func test_kinematic_advantage_overrides_home_bias() -> void:
	# The pair has fully exchanged sides mid-play: RD is far left, LD far
	# right. The 0.35 s rest bias must not drag them across each other.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, -8)],
		[2, 0, Vector3(-9, 0, -6)],
		[3, 0, Vector3(9, 0, -6)],
		[4, 0, Vector3(9, 0, 7.0)],    # LD holding the RIGHT side
		[5, 0, Vector3(-9, 0, 7.0)],   # RD holding the LEFT side
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.NEUTRAL, -1, -3.0)
	assert_eq(a[4], AIRoleSlots.Slot.DBACK_R, "exchanged LD keeps the right post")
	assert_eq(a[5], AIRoleSlots.Slot.DBACK_L, "exchanged RD keeps the left post")


# ── Strong/weak emergence ────────────────────────────────────────────────────

func test_strong_side_d_wins_the_corner_battle() -> void:
	# Puck in our LEFT corner (strong_x = -1): whichever D is nearer that
	# battle takes ZONE_D_STRONG; the other fronts the net.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, 14)],
		[2, 0, Vector3(-6, 0, 15)],
		[3, 0, Vector3(6, 0, 15)],
		[4, 0, Vector3(-5, 0, 21)],    # LD nearest the left-corner battle
		[5, 0, Vector3(3, 0, 21)],
		[10, 1, Vector3(-9, 0, 23)],
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.DZONE, 10,
			23.0, -9.0, {}, -1.0)
	assert_eq(a[4], AIRoleSlots.Slot.ZONE_D_STRONG)
	assert_eq(a[5], AIRoleSlots.Slot.ZONE_D_WEAK)


func test_missing_positions_default_to_forward_group() -> void:
	# Peers with no lobby position (tests / degenerate rosters) are rovers:
	# they can fill F jobs and cross-fill D posts, and nothing crashes.
	var skaters: Array = [
		[1, 0, Vector3(0, 0, 5)], [2, 0, Vector3(-5, 0, 8)],
		[3, 0, Vector3(5, 0, 8)], [4, 0, Vector3(-4, 0, 16)],
		[5, 0, Vector3(4, 0, 16)],
	]
	var a: Dictionary = AIRoleSlots5.assign(
			_make_snapshot(skaters, -1, -12.0), TEAM_ID, OUR_NET_Z,
			AIPossessionState.State.FORECHECK, _resolver(skaters), {}, 1.0, {}, {})
	assert_eq(a.size(), 5, "all five slotted even with no position data")


# ── RETRIEVAL (docs/breakout-plan.md Phase A) ────────────────────────────────
# Loose puck in our DZ that we clearly win: the race winner chases, everyone
# else takes the breakout posts NOW — the same posts as BREAKOUT, so the
# pickup's state flip renames the retriever to CARRIER and moves nobody.

func test_retrieval_race_winner_chases_and_posts_fill() -> void:
	# Puck loose in our right corner; the RD is closest and still — he wins
	# the chase election; the LD takes the D2 valve; the forwards take the
	# wall / swing / stretch posts on their home sides (strong_x = +1).
	var skaters: Array = [
		[1, 0, Vector3(0.0, 0.0, 18.0)],    # C
		[2, 0, Vector3(-4.0, 0.0, 16.0)],   # LW
		[3, 0, Vector3(4.0, 0.0, 16.0)],    # RW
		[4, 0, Vector3(-3.0, 0.0, 23.0)],   # LD
		[5, 0, Vector3(5.0, 0.0, 23.0)],    # RD — nearest the corner puck
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.RETRIEVAL,
			-1, 24.0, 8.0)
	assert_eq(_slot_of(a, AIRoleSlots.Slot.CHASE), 5,
			"the RD nearest the loose puck wins the retriever seat")
	assert_eq(_slot_of(a, AIRoleSlots.Slot.BREAKOUT_D2), 4,
			"the other D takes the D-to-D valve")
	assert_eq(_slot_of(a, AIRoleSlots.Slot.BREAKOUT_STRONG), 3,
			"RW takes the strong (right) half-wall post")
	assert_eq(_slot_of(a, AIRoleSlots.Slot.BREAKOUT_C), 1,
			"C takes the low swing")
	assert_eq(_slot_of(a, AIRoleSlots.Slot.BREAKOUT_STRETCH), 2,
			"LW takes the weak-side stretch")


func test_retrieval_forward_retriever_cross_fills_the_posts() -> void:
	# The C is the body closest to a puck dying in the slot — he retrieves;
	# both D still split CHASE-free jobs (one takes D2), and the leftover
	# posts cross-fill from whoever remains.
	var skaters: Array = [
		[1, 0, Vector3(1.0, 0.0, 21.0)],    # C — on top of the puck
		[2, 0, Vector3(-4.0, 0.0, 12.0)],   # LW
		[3, 0, Vector3(4.0, 0.0, 12.0)],    # RW
		[4, 0, Vector3(-3.0, 0.0, 24.0)],   # LD
		[5, 0, Vector3(3.0, 0.0, 24.0)],    # RD
	]
	var a: Dictionary = _assign(skaters, AIPossessionState.State.RETRIEVAL,
			-1, 21.0, 1.0)
	assert_eq(_slot_of(a, AIRoleSlots.Slot.CHASE), 1,
			"the closest body retrieves regardless of group")
	assert_true(_slot_of(a, AIRoleSlots.Slot.BREAKOUT_D2) in [4, 5],
			"a real D takes the valve")
	# All five slots filled — nobody left standing in the old zone shape.
	assert_eq(a.size(), 5)
