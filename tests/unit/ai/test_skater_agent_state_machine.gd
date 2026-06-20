extends GutTest

# SkaterAgentStateMachine — first slice: the snapshot-driven spatial predicates
# that gate loose-puck chase and opponent awareness. These read only a
# fabricated WorldSnapshot plus the bot's identity (_peer_id / _team_id /
# _team_id_by_peer set by setup), so they run headlessly with no live actors,
# goalie state, role behaviors, or mouse/aim state. The heavier aim/charge/
# state-transition surface is deferred to later slices.

const Agent := preload("res://Scripts/ai/skater_agent_state_machine.gd")

# peer 1 = self (team 0), peer 2 = teammate (team 0), peers 11/12 = team 1.
const SELF_ID := 1
const TEAMMATE_ID := 2
const OPP_ID := 11
var _team_map := {1: 0, 2: 0, 11: 1, 12: 1}

var sm: SkaterAgentStateMachine


func before_each() -> void:
	sm = Agent.new()
	sm.setup(SELF_ID, 0, TeamBrain.new(0, _team_map), _team_map, false)


# ── Snapshot builders ────────────────────────────────────────────────────────

func _loose_puck_snap(puck_pos: Vector3) -> WorldSnapshot:
	var s := WorldSnapshot.new()
	s.puck_state = PuckNetworkState.new()
	s.puck_state.position = puck_pos
	s.puck_state.carrier_peer_id = -1
	return s


func _add_skater(s: WorldSnapshot, peer_id: int, pos: Vector3, ghost: bool = false) -> void:
	var st := SkaterNetworkState.new()
	st.position = pos
	st.is_ghost = ghost
	s.skater_states[peer_id] = st


# ── _should_chase_loose_puck ─────────────────────────────────────────────────

func test_should_chase_false_when_no_puck_state() -> void:
	var s := WorldSnapshot.new()  # puck_state stays null
	assert_false(sm._should_chase_loose_puck(s, Vector3.ZERO))


func test_should_chase_false_when_puck_is_carried() -> void:
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	s.puck_state.carrier_peer_id = OPP_ID
	_add_skater(s, SELF_ID, Vector3(4, 0, 0))
	assert_false(sm._should_chase_loose_puck(s, Vector3(4, 0, 0)),
			"a held puck is never chased even if we're nearest")


func test_should_chase_true_when_nearest_teammate() -> void:
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	_add_skater(s, SELF_ID, Vector3(4, 0, 0))
	_add_skater(s, TEAMMATE_ID, Vector3(10, 0, 0))
	assert_true(sm._should_chase_loose_puck(s, Vector3(4, 0, 0)))


func test_should_chase_false_when_teammate_is_nearer() -> void:
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	_add_skater(s, SELF_ID, Vector3(4, 0, 0))         # 1.0 m away
	_add_skater(s, TEAMMATE_ID, Vector3(4.5, 0, 0))   # 0.5 m away
	assert_false(sm._should_chase_loose_puck(s, Vector3(4, 0, 0)))


# ── _is_closest_teammate_to_puck_at: cache vs. live scan ─────────────────────

func test_closest_cache_overrides_geometry() -> void:
	# When the per-team cache is populated it is authoritative — geometry is
	# not consulted, so a far-away self still "wins" if the cache names it.
	var s := _loose_puck_snap(Vector3(0, 0, 0))
	_add_skater(s, SELF_ID, Vector3(50, 0, 0))        # nowhere near the puck
	s.closest_to_puck_by_team = {0: SELF_ID}
	assert_true(sm._is_closest_teammate_to_puck_at(s, Vector3(50, 0, 0)))
	s.closest_to_puck_by_team = {0: TEAMMATE_ID}
	assert_false(sm._is_closest_teammate_to_puck_at(s, Vector3(50, 0, 0)))


func test_closest_live_scan_ignores_opponents() -> void:
	# An opponent sitting on the puck must not block our chase — only
	# same-team skaters count toward "closest teammate".
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	_add_skater(s, SELF_ID, Vector3(4, 0, 0))
	_add_skater(s, OPP_ID, Vector3(5, 0, 0))          # opponent right on the puck
	assert_true(sm._is_closest_teammate_to_puck_at(s, Vector3(4, 0, 0)))


# ── _post_puck_lost_state ────────────────────────────────────────────────────

func test_post_lost_off_puck_when_no_puck() -> void:
	assert_eq(sm._post_puck_lost_state(WorldSnapshot.new()), Agent.State.OFF_PUCK)


func test_post_lost_off_puck_when_carried() -> void:
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	s.puck_state.carrier_peer_id = TEAMMATE_ID
	_add_skater(s, SELF_ID, Vector3(4, 0, 0))
	assert_eq(sm._post_puck_lost_state(s), Agent.State.OFF_PUCK)


func test_post_lost_off_puck_when_ghosted() -> void:
	# A ghosted (offside/icing) bot stays off-puck even if it's nearest.
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	_add_skater(s, SELF_ID, Vector3(4, 0, 0), true)
	assert_eq(sm._post_puck_lost_state(s), Agent.State.OFF_PUCK)


func test_post_lost_chase_when_nearest_and_live() -> void:
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	_add_skater(s, SELF_ID, Vector3(4, 0, 0))
	_add_skater(s, TEAMMATE_ID, Vector3(12, 0, 0))
	assert_eq(sm._post_puck_lost_state(s), Agent.State.CHASE_PUCK)


func test_post_lost_off_puck_when_not_nearest() -> void:
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	_add_skater(s, SELF_ID, Vector3(4, 0, 0))
	_add_skater(s, TEAMMATE_ID, Vector3(4.5, 0, 0))
	assert_eq(sm._post_puck_lost_state(s), Agent.State.OFF_PUCK)


# ── _opponent_within_forward ─────────────────────────────────────────────────

func test_opponent_within_forward_detects_opponent_ahead() -> void:
	var s := WorldSnapshot.new()
	_add_skater(s, SELF_ID, Vector3.ZERO)
	_add_skater(s, OPP_ID, Vector3(0, 0, 5))
	assert_true(sm._opponent_within_forward(s, Vector3.ZERO, Vector3(0, 0, 1), 10.0))


func test_opponent_within_forward_excludes_teammates() -> void:
	var s := WorldSnapshot.new()
	_add_skater(s, SELF_ID, Vector3.ZERO)
	_add_skater(s, TEAMMATE_ID, Vector3(0, 0, 5))  # teammate ahead — not an opponent
	assert_false(sm._opponent_within_forward(s, Vector3.ZERO, Vector3(0, 0, 1), 10.0))


func test_opponent_within_forward_ignores_opponent_behind() -> void:
	var s := WorldSnapshot.new()
	_add_skater(s, OPP_ID, Vector3(0, 0, -5))  # behind the forward vector
	assert_false(sm._opponent_within_forward(s, Vector3.ZERO, Vector3(0, 0, 1), 10.0))


func test_opponent_within_forward_ignores_opponent_outside_radius() -> void:
	var s := WorldSnapshot.new()
	_add_skater(s, OPP_ID, Vector3(0, 0, 50))  # ahead but far
	assert_false(sm._opponent_within_forward(s, Vector3.ZERO, Vector3(0, 0, 1), 10.0))


func test_opponent_within_forward_degenerate_dir_is_omnidirectional() -> void:
	# A zero forward vector falls through to a pure radius check, so an
	# opponent behind us still counts.
	var s := WorldSnapshot.new()
	_add_skater(s, OPP_ID, Vector3(0, 0, -5))
	assert_true(sm._opponent_within_forward(s, Vector3.ZERO, Vector3.ZERO, 10.0))


# ── _angle_intercept_inside (static, pure geometry) ──────────────────────────

func test_angle_intercept_passthrough_within_bias_band() -> void:
	# |carrier.x| <= CHASE_ANGLE_BIAS_M → target returned unchanged.
	var target := Vector3(3, 0, -10)
	assert_eq(Agent._angle_intercept_inside(target, Vector3(1.0, 0, 0)), target)


func test_angle_intercept_biases_toward_center_when_wide() -> void:
	var target := Vector3(3, 0, -10)
	# carrier on +X side → bias target by -CHASE_ANGLE_BIAS_M (toward center).
	var out_right: Vector3 = Agent._angle_intercept_inside(target, Vector3(5.0, 0, 0))
	assert_almost_eq(out_right.x, target.x - Agent.CHASE_ANGLE_BIAS_M, 0.0001)
	# carrier on -X side → bias the other way.
	var out_left: Vector3 = Agent._angle_intercept_inside(target, Vector3(-5.0, 0, 0))
	assert_almost_eq(out_left.x, target.x + Agent.CHASE_ANGLE_BIAS_M, 0.0001)
	assert_eq(out_right.z, target.z, "only X is biased")
