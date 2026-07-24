extends GutTest

# Directly verifies TeamBrain.build_view freezes the brain's outputs into a
# TeamBrainView that mirrors the live brain (AI threading Phase 3a). The agent
# dispatch reads this frozen view instead of the live brain so Phase 3c can run
# dispatch off the physics thread; if the freeze drops or mis-copies a field the
# bots would read stale strategy, so this pins the mirror explicitly.

const HOME := 0
const P1 := 10001   # our team
const P2 := 10002   # our team
const OPP := 10011  # their team


func _make_brain() -> TeamBrain:
	var team_id_by_peer := {P1: HOME, P2: HOME, OPP: 1}
	return TeamBrain.new(HOME, team_id_by_peer, {}, 3, {})


func _make_snapshot(puck_pos: Vector3) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	var puck := PuckNetworkState.new()
	puck.position = puck_pos
	snap.puck_state = puck
	return snap


func test_view_mirrors_slots_and_flags() -> void:
	var brain := _make_brain()
	brain.slot_assignments[P1] = AIRoleSlots.Slot.FINISHER
	brain.slot_assignments[P2] = AIRoleSlots.Slot.SUPPORT
	brain.set_one_timer_ready(P1, true)
	brain._strong_x = -1.0
	brain.threat_shoot_base_by_opp[OPP] = 0.42

	brain.build_view(_make_snapshot(Vector3(3.0, 0.0, 5.0)))
	var view: TeamBrainView = brain.get_view()

	assert_not_null(view, "build_view populated the view")
	assert_eq(view.get_slot(P1), brain.get_slot(P1), "P1 slot frozen")
	assert_eq(view.get_slot(P2), brain.get_slot(P2), "P2 slot frozen")
	assert_true(view.is_one_timer_ready(P1), "P1 one-timer-ready frozen")
	assert_false(view.is_one_timer_ready(P2), "P2 not ready")
	assert_eq(view.strong_x(), -1.0, "strong-side frozen")
	assert_eq(view.get_team_size(), 3, "team size frozen")
	assert_almost_eq(view.get_threat_shoot_base_by_opp().get(OPP, 0.0), 0.42, 0.0001,
			"threat memo frozen")


func test_view_anchor_matches_live_brain() -> void:
	var brain := _make_brain()
	brain.slot_assignments[P1] = AIRoleSlots.Slot.FINISHER
	var snap := _make_snapshot(Vector3(-2.0, 0.0, 8.0))

	var live_anchor: Vector3 = brain.get_anchor(P1, snap)
	brain.build_view(snap)
	var frozen_anchor: Vector3 = brain.get_view().get_anchor(P1, snap)

	assert_eq(frozen_anchor, live_anchor, "frozen anchor matches the live compute")


func test_view_is_reused_across_builds() -> void:
	# The view object is reused (refilled), not reallocated, each build.
	var brain := _make_brain()
	brain.slot_assignments[P1] = AIRoleSlots.Slot.SUPPORT
	var snap := _make_snapshot(Vector3.ZERO)
	brain.build_view(snap)
	var first: TeamBrainView = brain.get_view()
	brain.build_view(snap)
	assert_same(first, brain.get_view(), "same view instance is refilled, not replaced")


func test_stale_slot_cleared_on_rebuild() -> void:
	# A peer that loses its slot must drop out of the frozen view's ping/anchor
	# maps (those are cleared and refilled from the current slot set each build).
	var brain := _make_brain()
	brain.slot_assignments[P1] = AIRoleSlots.Slot.FINISHER
	var snap := _make_snapshot(Vector3(1.0, 0.0, 3.0))
	brain.build_view(snap)
	assert_true(brain.get_view().anchor_by_peer.has(P1), "P1 anchor present while slotted")

	brain.slot_assignments.erase(P1)
	brain.build_view(snap)
	assert_false(brain.get_view().anchor_by_peer.has(P1), "P1 anchor dropped after losing its slot")
