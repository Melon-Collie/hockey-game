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

	brain.build_view()
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


func test_view_is_reused_across_builds() -> void:
	# The view object is reused (refilled), not reallocated, each build.
	var brain := _make_brain()
	brain.slot_assignments[P1] = AIRoleSlots.Slot.SUPPORT
	var snap := _make_snapshot(Vector3.ZERO)
	brain.build_view()
	var first: TeamBrainView = brain.get_view()
	brain.build_view()
	assert_same(first, brain.get_view(), "same view instance is refilled, not replaced")


func test_view_mirrors_ping_chase_peer() -> void:
	# GET_PUCK is team-scoped (one ordered chaser), so it freezes as a scalar
	# rather than a per-peer dict. It was the one ping type the original freeze
	# missed, leaving _should_chase_loose_puck reading the live brain from the
	# worker while main-thread apply_ping / advance mutated the same dictionary.
	var brain := _make_brain()
	var snap := _make_snapshot(Vector3(1.0, 0.0, 2.0))
	brain.build_view()
	assert_eq(brain.get_view().ping_chase_peer(), -1, "no order -> -1")

	brain.apply_ping(PingRules.Type.GET_PUCK, P2, P1, P1, Vector3.ZERO)
	brain.build_view()
	assert_eq(brain.get_view().ping_chase_peer(), brain.ping_chase_peer(),
			"chase order frozen to match the live brain")
	assert_eq(brain.get_view().ping_chase_peer(), P1, "P1 is the ordered chaser")


# Lines in the agent state machine that touch the LIVE TeamBrain. Every one of
# these must be main-thread-only, because the AI worker runs dispatch() against
# the frozen TeamBrainView while the main thread freely mutates the live brain
# (pings, force-retick, spawn/despawn) — see docs/ai-threading-plan.md.
#
#   team_brain.gd:788   _strategy() — reads the view POINTER; build_view only
#                       swaps it while the worker is idle (AICoordinator).
#   1592 / 1625         debug_role / debug_pass_slot — called only from
#                       AIController._refresh_debug_label, on the main thread.
#   4046                push_one_timer_ready — main-thread collection step.
#
# If you are adding a line here, prove it cannot run on the worker. Reads
# reachable from dispatch() belong on TeamStrategyView and must be frozen into
# TeamBrainView by TeamBrain.build_view instead.
const _SM_PATH := "res://Scripts/ai/skater_agent_state_machine.gd"
const _ALLOWED_LIVE_BRAIN_LINES: Array[String] = [
	"var v: TeamBrainView = _team_brain.get_view()",
	'return "%s: %s" % [_team_state_label(_team_brain.state), _slot_label(_team_brain.get_slot(_peer_id))]',
	"return _slot_label(_team_brain.get_slot(debug_pass_peer_id))",
	"_team_brain.set_one_timer_ready(_peer_id, _is_one_timer_ready)",
]


func test_agent_never_reads_live_brain_off_thread() -> void:
	var f: FileAccess = FileAccess.open(_SM_PATH, FileAccess.READ)
	assert_not_null(f, "opened the agent state machine source")
	if f == null:
		return
	var unexpected: Array[String] = []
	var line_no: int = 0
	while not f.eof_reached():
		line_no += 1
		var raw: String = f.get_line()
		var line: String = raw.strip_edges()
		if line.begins_with("#") or not line.contains("_team_brain."):
			continue
		if _ALLOWED_LIVE_BRAIN_LINES.has(line):
			continue
		unexpected.append("%d: %s" % [line_no, line])
	f.close()
	assert_eq(unexpected, [] as Array[String],
			"new live-TeamBrain read(s) in the agent SM — these race the AI worker. "
			+ "Freeze the field into TeamBrainView, or add the line to "
			+ "_ALLOWED_LIVE_BRAIN_LINES with proof it is main-thread-only.")


func test_stale_slot_cleared_on_rebuild() -> void:
	# A peer that loses its slot must drop out of the frozen view's ping maps
	# (those are cleared and refilled from the current slot set each build).
	var brain := _make_brain()
	brain.slot_assignments[P1] = AIRoleSlots.Slot.FINISHER
	brain.build_view()
	assert_true(brain.get_view().ping_move_by_peer.has(P1),
			"P1 ping present while slotted")

	brain.slot_assignments.erase(P1)
	brain.build_view()
	assert_false(brain.get_view().ping_move_by_peer.has(P1),
			"P1 ping dropped after losing its slot")
