extends GutTest

# StateBufferManager — historical rewind buffer for lag compensation.
# `capture()` needs real controllers, so these tests drive the interpolation
# path directly: allocate a skater ring, write two known slots, and query
# get_state_at() between / at / past them. This is the layer the claim resolvers
# rewind through, and it was previously untested — which is how the dropped
# shot_state copy (below) shipped: no integration test exercised the geometry
# path and the domain suite doesn't reach this glue.

const EPSILON: float = 1e-6
const PEER: int = 7

var sbm: StateBufferManager


func before_each() -> void:
	sbm = StateBufferManager.new()
	sbm._alloc_skater(PEER)


# Writes two consecutive skater slots and points the ring at them so the two
# are the only logical entries (oldest = slot 0, newest = slot 1).
func _seed_two_slots(
		ts_a: float, state_a: SkaterNetworkState,
		ts_b: float, state_b: SkaterNetworkState) -> void:
	var buf: Array = sbm._skater_buffers[PEER]
	state_a.host_timestamp = ts_a
	state_b.host_timestamp = ts_b
	buf[0] = state_a
	buf[1] = state_b
	sbm._skater_ptrs[PEER] = 2          # next write slot
	sbm._skater_counts[PEER] = 2


func _slot(shot_state: int, is_ghost: bool, pos: Vector3) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.shot_state = shot_state
	s.is_ghost = is_ghost
	s.position = pos
	return s


# ── shot_state on the INTERPOLATED path (the fixed bug) ──────────────────────

func test_interpolated_snapshot_carries_shot_state_from_newer_endpoint() -> void:
	# Query lands strictly between the two samples → interpolation. shot_state is
	# a discrete enum (not lerp-able), so it must come from the newer endpoint,
	# exactly like is_ghost. Before the fix this returned SKATING_WITHOUT_PUCK (0),
	# silently killing the pickup resolver's follow-through / shot-block gate on
	# every link where the blade rewind interpolates.
	_seed_two_slots(
		10.0, _slot(SkaterStateMachine.State.SKATING_WITH_PUCK, false, Vector3.ZERO),
		10.1, _slot(SkaterStateMachine.State.FOLLOW_THROUGH, false, Vector3.ONE))
	var snap: WorldSnapshot = sbm.get_state_at(10.05)
	var s: SkaterNetworkState = snap.get_skater_state(PEER)
	assert_not_null(s)
	assert_eq(s.shot_state, SkaterStateMachine.State.FOLLOW_THROUGH as int,
		"interpolated rewind must carry the newer endpoint's shot_state")


func test_interpolated_snapshot_carries_movement_intent() -> void:
	# The stage-3 hit-claim rewind forward-integrates the victim from this
	# snapshot with its broadcast movement intent. Intent is discrete (like
	# shot_state) — newer endpoint. Before the fix the interpolated path left
	# all three fields at their defaults (ZERO/false/false), so the host
	# integrated every victim as a friction coast while the client rendered
	# the real thrust — breaking render == rewind on any link where the
	# rewind interpolates (the normal case).
	var older := _slot(0, false, Vector3.ZERO)
	var newer := _slot(0, false, Vector3.ONE)
	newer.move_intent = Vector2(0.0, 1.0)
	newer.brake_intent = true
	newer.sprint_active = true
	_seed_two_slots(10.0, older, 10.1, newer)
	var snap: WorldSnapshot = sbm.get_state_at(10.05)
	var s: SkaterNetworkState = snap.get_skater_state(PEER)
	assert_not_null(s)
	assert_eq(s.move_intent, Vector2(0.0, 1.0),
		"interpolated rewind must carry the newer endpoint's move_intent")
	assert_true(s.brake_intent, "brake_intent must survive interpolation")
	assert_true(s.sprint_active, "sprint_active must survive interpolation")


func test_interpolated_snapshot_still_interpolates_position() -> void:
	# Guard against a regression that swaps the whole result for a passthrough:
	# position must still be the lerp midpoint at t = 0.5.
	_seed_two_slots(
		10.0, _slot(SkaterStateMachine.State.SKATING_WITH_PUCK, false, Vector3.ZERO),
		10.1, _slot(SkaterStateMachine.State.FOLLOW_THROUGH, false, Vector3(2.0, 0.0, 0.0)))
	var snap: WorldSnapshot = sbm.get_state_at(10.05)
	var s: SkaterNetworkState = snap.get_skater_state(PEER)
	assert_almost_eq(s.position.x, 1.0, 1e-4)


func test_shot_block_gate_state_survives_interpolation() -> void:
	# The other gated state — a crouched shot-blocker — must also survive.
	_seed_two_slots(
		20.0, _slot(SkaterStateMachine.State.SHOT_BLOCKING, false, Vector3.ZERO),
		20.1, _slot(SkaterStateMachine.State.SHOT_BLOCKING, false, Vector3.ZERO))
	var snap: WorldSnapshot = sbm.get_state_at(20.05)
	var s: SkaterNetworkState = snap.get_skater_state(PEER)
	assert_eq(s.shot_state, SkaterStateMachine.State.SHOT_BLOCKING as int)


# ── passthrough path (query at/after newest) already carried shot_state ──────

func test_passthrough_snapshot_returns_newest_shot_state() -> void:
	# ts >= newest → the resolver receives the real newest slot verbatim, which
	# always carried shot_state. Pin it so the two paths stay consistent.
	_seed_two_slots(
		10.0, _slot(SkaterStateMachine.State.SKATING_WITH_PUCK, false, Vector3.ZERO),
		10.1, _slot(SkaterStateMachine.State.FOLLOW_THROUGH, false, Vector3.ONE))
	var snap: WorldSnapshot = sbm.get_state_at(10.5)
	var s: SkaterNetworkState = snap.get_skater_state(PEER)
	assert_eq(s.shot_state, SkaterStateMachine.State.FOLLOW_THROUGH as int)


# ── is_ghost anchor (unchanged, proves the endpoint convention) ──────────────

func test_interpolated_snapshot_carries_is_ghost_from_newer_endpoint() -> void:
	_seed_two_slots(
		10.0, _slot(SkaterStateMachine.State.SKATING_WITH_PUCK, false, Vector3.ZERO),
		10.1, _slot(SkaterStateMachine.State.SKATING_WITH_PUCK, true, Vector3.ONE))
	var snap: WorldSnapshot = sbm.get_state_at(10.05)
	var s: SkaterNetworkState = snap.get_skater_state(PEER)
	assert_true(s.is_ghost)
