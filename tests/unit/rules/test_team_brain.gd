extends GutTest

# Phase 3 added force_retick() to TeamBrain. This test verifies the
# rate-limit-bypass contract:
#   - tick(delta < TICK_PERIOD) is a no-op (existing behavior).
#   - force_retick() followed by tick(any_delta) computes regardless.
#   - After a forced tick, the natural cadence resumes (next tick
#     fires TICK_PERIOD seconds later, not earlier).

const OUR_NET_Z: float = 26.65
const TEAM_ID: int = 0


func _make_snapshot(carrier_pid: int, puck_pos: Vector3) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	# Two teammates + opp carrier so possession + assignment have
	# something to compute.
	for entry: Array in [[100, 0, Vector3(0.0, 0.0, 22.0)],
			[110, 0, Vector3(-2.0, 0.0, 22.65)],
			[120, 0, Vector3(2.0, 0.0, 22.0)],
			[200, 1, puck_pos]]:
		var s := SkaterNetworkState.new()
		s.position = entry[2]
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	puck.position = puck_pos
	snap.puck_state = puck
	return snap


func _make_brain() -> TeamBrain:
	var team_map: Dictionary = {100: 0, 110: 0, 120: 0, 200: 1}
	return TeamBrain.new(TEAM_ID, team_map)


func test_tick_below_period_is_noop() -> void:
	var brain: TeamBrain = _make_brain()
	var snap: WorldSnapshot = _make_snapshot(200, Vector3(0.0, 0.0, 22.0))
	# 100 ms — well below the 167 ms TICK_PERIOD. Should NOT compute.
	brain.tick(0.1, snap)
	assert_true(brain.slot_assignments.is_empty(),
			"tick() under TICK_PERIOD should be a no-op (no assignments yet)")


func test_force_retick_bypasses_rate_limit() -> void:
	var brain: TeamBrain = _make_brain()
	var snap: WorldSnapshot = _make_snapshot(200, Vector3(0.0, 0.0, 22.0))
	brain.force_retick()
	# Even with a tiny delta the next tick should compute because
	# _force_tick_pending was set.
	brain.tick(0.001, snap)
	assert_false(brain.slot_assignments.is_empty(),
			"force_retick() + tick() should compute regardless of accumulator")
	assert_eq(brain.state, AIPossessionState.State.DZONE,
			"opp carrier deep in our DZ → DZONE")


func test_natural_cadence_resumes_after_forced_tick() -> void:
	var brain: TeamBrain = _make_brain()
	var snap: WorldSnapshot = _make_snapshot(200, Vector3(0.0, 0.0, 22.0))
	brain.force_retick()
	brain.tick(0.001, snap)  # forced tick — accumulator reset to 0
	var assignments_after_forced: Dictionary = brain.slot_assignments.duplicate()

	# Next call within TICK_PERIOD should be a no-op (no double-tick
	# burst). Mutate snapshot so a re-tick would be detectable.
	var snap2: WorldSnapshot = _make_snapshot(100, Vector3(0.0, 0.0, -22.0))  # we now carry
	brain.tick(0.05, snap2)
	assert_eq_deep(brain.slot_assignments, assignments_after_forced,
			"tick() within TICK_PERIOD of a forced tick should not re-compute")

	# After enough delta to clear TICK_PERIOD, the natural cadence
	# fires and assignments update to reflect the new snapshot.
	brain.tick(0.2, snap2)  # 200 ms, > TICK_PERIOD
	assert_eq(brain.state, AIPossessionState.State.OZONE,
			"after natural tick fires, possession state reflects new carrier")


# ── Man-on-threat partition (DZONE) ──────────────────────────────────────────

# 3-on-3 in our DZONE: opp carrier (200) deep with two receivers (210, 220);
# our three (100/110/120) fill PRESSURE + MARK×2. The two MARKs should be
# partitioned across the two NON-carrier opponents — distinct men, neither
# assigned the carrier, and PRESSURE left unassigned.
# SET coverage, not merely "the puck is in our zone": DZONE is now gated on
# coverage readiness (docs/transition-defense-plan.md §9), so a fixture that
# wants the zone shape has to actually look like an established structure —
# a body containing the carrier and each receiver fronted goal-side inside the
# cover envelope. A loose shape correctly reads as a rush still being defended.
func _make_dzone_3v3() -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	for entry: Array in [
			[100, 0, Vector3(0.0, 0.0, 22.5)],     # us — on the carrier
			[110, 0, Vector3(-4.5, 0.0, 21.5)],    # us — fronting 210
			[120, 0, Vector3(4.5, 0.0, 21.5)],     # us — fronting 220
			[200, 1, Vector3(0.0, 0.0, 20.0)],     # opp carrier
			[210, 1, Vector3(-6.0, 0.0, 18.0)],    # opp receiver
			[220, 1, Vector3(6.0, 0.0, 18.0)]]:    # opp receiver
		var s := SkaterNetworkState.new()
		s.position = entry[2]
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = 200
	puck.position = Vector3(0.0, 0.0, 20.0)
	snap.puck_state = puck
	return snap


func _make_brain_3v3() -> TeamBrain:
	var team_map: Dictionary = {100: 0, 110: 0, 120: 0, 200: 1, 210: 1, 220: 1}
	return TeamBrain.new(TEAM_ID, team_map)


func test_threat_partition_assigns_distinct_men() -> void:
	var brain: TeamBrain = _make_brain_3v3()
	brain.force_retick()
	brain.tick(0.001, _make_dzone_3v3())
	assert_eq(brain.state, AIPossessionState.State.DZONE, "opp carrier deep → DZONE")

	# Exactly the two MARK defenders get a man.
	assert_eq(brain.threat_assignments.size(), 2,
			"two backline defenders are assigned; got %s" % str(brain.threat_assignments))
	var men: Array = brain.threat_assignments.values()
	assert_ne(men[0], men[1], "defenders cover distinct men")
	assert_false(men.has(200), "no defender is assigned the carrier (PRESSURE owns it)")
	assert_true(men.has(210) and men.has(220),
			"both receivers are covered; got %s" % str(men))

	# The covered defenders are exactly the non-PRESSURE backline peers.
	for pid: int in brain.threat_assignments:
		var slot: int = brain.get_slot(pid)
		assert_eq(slot, AIRoleSlots.Slot.MARK,
				"assigned peer %d is MARK, got slot %d" % [pid, slot])


func test_the_partition_survives_the_puck_leaving_a_stick() -> void:
	# A pass is in flight: same six bodies, no carrier. Coverage must NOT
	# dissolve — a man is dangerous because of where he stands relative to our
	# net, which does not depend on anyone holding the puck. Requiring a live
	# carrier was measured at 36% of D-zone time with no man on ANY marker, and
	# team-wide all-or-nothing, because every pass / shot / rebound / dump hit
	# the same condition.
	var brain: TeamBrain = _make_brain_3v3()
	brain.force_retick()
	var snap: WorldSnapshot = _make_dzone_3v3()
	brain.tick(0.001, snap)
	var carried: Dictionary = brain.threat_assignments.duplicate()
	assert_eq(carried.size(), 2, "fixture sanity: both markers start with a man")

	# 200 releases it; the puck is now in flight toward 210.
	snap.puck_state.carrier_peer_id = -1
	snap.puck_state.position = Vector3(-3.0, 0.0, 19.0)
	brain.force_retick()
	brain.tick(0.001, snap)

	assert_eq(brain.threat_assignments.size(), 2,
			"coverage holds through the pass; got %s" % str(brain.threat_assignments))
	var men: Array = brain.threat_assignments.values()
	assert_ne(men[0], men[1], "still distinct men")
	for pid: int in brain.threat_assignments:
		assert_eq(brain.get_slot(pid), AIRoleSlots.Slot.MARK,
				"only MARK peers are assigned")


func test_a_released_carrier_becomes_a_markable_man() -> void:
	# With nobody carrying, PRESSURE owns nobody, so every opponent is a man —
	# the ex-carrier included. He is the most dangerous body on the ice in this
	# fixture (dead centre, 6.7 m out), so the partition must be free to take
	# him rather than treating him as somebody else's problem.
	var brain: TeamBrain = _make_brain_3v3()
	brain.force_retick()
	var snap: WorldSnapshot = _make_dzone_3v3()
	snap.puck_state.carrier_peer_id = -1
	snap.puck_state.position = Vector3(-3.0, 0.0, 19.0)
	brain.tick(0.001, snap)

	var men: Array = brain.threat_assignments.values()
	assert_true(men.has(200),
			"the released carrier is a coverable man; got %s" % str(men))


# ── Shared threat memo (threat_shoot_base_by_opp) ───────────────────────────

func test_threat_memo_published_while_markers_live() -> void:
	# DZONE slots MARK defenders, so the brain publishes the shared
	# per-opponent shoot-threat bases their unassigned fallback consumes
	# (see threat_shoot_base_by_opp). One base per opponent, carrier included.
	var brain: TeamBrain = _make_brain_3v3()
	brain.force_retick()
	brain.tick(0.001, _make_dzone_3v3())
	var has_mark: bool = false
	for pid: int in brain.slot_assignments:
		if brain.slot_assignments[pid] == AIRoleSlots.Slot.MARK:
			has_mark = true
	assert_true(has_mark, "fixture sanity: DZONE slots at least one MARK")
	for opp_pid: int in [200, 210, 220]:
		assert_true(brain.threat_shoot_base_by_opp.has(opp_pid),
				"memo carries a base for opponent %d" % opp_pid)
	assert_gt(brain.threat_shoot_base_by_opp[200], 0.0,
			"an opp carrier in our slot is a live threat surface")


func test_threat_memo_empty_without_markers() -> void:
	# We possess (OZONE) → no MARK slot → the memo must stay empty so
	# consumers fall back to the exact local computation, never a stale read.
	var brain: TeamBrain = _make_brain()
	brain.force_retick()
	brain.tick(0.001, _make_snapshot(100, Vector3(0.0, 0.0, -22.0)))
	assert_true(brain.threat_shoot_base_by_opp.is_empty(),
			"no MARK live → memo empty; got %s" % str(brain.threat_shoot_base_by_opp))


func test_threat_partition_cleared_when_we_possess() -> void:
	# When we carry the puck (OZONE/TRANS), there's no defensive man coverage.
	var brain: TeamBrain = _make_brain_3v3()
	brain.force_retick()
	brain.tick(0.001, _make_dzone_3v3())
	assert_false(brain.threat_assignments.is_empty(), "DZONE populates the partition")

	# Now WE carry deep in the offensive end → no longer DZONE.
	var snap := WorldSnapshot.new()
	for entry: Array in [
			[100, 0, Vector3(0.0, 0.0, -20.0)],
			[110, 0, Vector3(-3.0, 0.0, -18.0)],
			[120, 0, Vector3(3.0, 0.0, -18.0)],
			[200, 1, Vector3(0.0, 0.0, 22.0)],
			[210, 1, Vector3(-6.0, 0.0, 22.0)],
			[220, 1, Vector3(6.0, 0.0, 22.0)]]:
		var s := SkaterNetworkState.new()
		s.position = entry[2]
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = 100
	puck.position = Vector3(0.0, 0.0, -20.0)
	snap.puck_state = puck
	brain.tick(0.2, snap)
	assert_ne(brain.state, AIPossessionState.State.DZONE, "we possess → not DZONE")
	assert_true(brain.threat_assignments.is_empty(),
			"partition cleared outside defensive states")


# Helper — GUT doesn't have assert_eq for Dictionary by default; do
# a manual deep compare via string repr (sufficient for small dicts).
func assert_eq_deep(a: Dictionary, b: Dictionary, msg: String = "") -> void:
	assert_eq(str(a), str(b), msg)


# ── team_size branch (5v5) ───────────────────────────────────────────────────

func _make_5v5_snapshot(carrier_pid: int) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	for entry: Array in [
			[100, 0, Vector3(0.0, 0.0, 14.0)],
			[110, 0, Vector3(-6.0, 0.0, 15.0)],
			[120, 0, Vector3(6.0, 0.0, 15.0)],
			[130, 0, Vector3(-3.0, 0.0, 22.0)],
			[140, 0, Vector3(3.0, 0.0, 22.0)],
			[200, 1, Vector3(9.0, 0.0, 23.0)]]:
		var s := SkaterNetworkState.new()
		s.position = entry[2]
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	puck.position = Vector3(9.0, 0.0, 23.0)
	snap.puck_state = puck
	return snap


func test_brain_routes_to_5v5_slots_when_latched_at_5() -> void:
	# Opp carrier deep in our zone with a full 5v5 lineup (130/140 = D):
	# a team_size-5 brain must produce zone-coverage slots, not the 3v3 set.
	var team_map: Dictionary = {100: 0, 110: 0, 120: 0, 130: 0, 140: 0, 200: 1}
	var positions: Dictionary = {100: 0, 110: 1, 120: 2, 130: 3, 140: 4}
	var brain := TeamBrain.new(TEAM_ID, team_map, {}, 5, positions)
	brain.tick(1.0, _make_5v5_snapshot(200))
	assert_eq(brain.slot_assignments.size(), 5)
	var d_slots: Array[int] = [brain.get_slot(130), brain.get_slot(140)]
	d_slots.sort()
	assert_eq(d_slots, [AIRoleSlots.Slot.ZONE_D_STRONG,
			AIRoleSlots.Slot.ZONE_D_WEAK] as Array[int],
			"the lobby D pair owns the low zone")


func test_brain_keeps_legacy_slots_at_3() -> void:
	var brain: TeamBrain = _make_brain()
	brain.tick(1.0, _make_snapshot(200, Vector3(0.0, 0.0, 22.0)))
	for pid: int in brain.slot_assignments:
		var slot: int = brain.slot_assignments[pid]
		assert_true(slot == AIRoleSlots.Slot.PRESSURE or slot == AIRoleSlots.Slot.MARK,
				"3v3 DZONE stays {PRESSURE, MARK}, got %d" % slot)


func test_5v5_dzone_fills_the_five_zone_slots() -> void:
	# The 5v5 D-zone election must hand out the hybrid-zone set, one body each
	# — the 3v3 {PRESSURE, MARK} table is a different shape entirely.
	var team_map: Dictionary = {100: 0, 110: 0, 120: 0, 130: 0, 140: 0, 200: 1}
	var positions: Dictionary = {100: 0, 110: 1, 120: 2, 130: 3, 140: 4}
	var brain := TeamBrain.new(TEAM_ID, team_map, {}, 5, positions)
	var snap: WorldSnapshot = _make_5v5_snapshot(200)
	brain.tick(1.0, snap)
	var seen: Dictionary = {}
	for pid: int in [100, 110, 120, 130, 140]:
		seen[brain.get_slot(pid)] = true
	for slot: int in [AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK,
			AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG,
			AIRoleSlots.Slot.ZONE_W_WEAK]:
		assert_true(seen.has(slot), "5v5 DZONE left slot %d unfilled" % slot)
