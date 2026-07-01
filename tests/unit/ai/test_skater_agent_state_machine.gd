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


# ── Slice 2: mouse / aim motion geometry ─────────────────────────────────────
# Pure motion model — no snapshot, no role state. The output carries no noise
# (MOUSE_NOISE_STD_M == 0), so the returned point equals the smooth _mouse_pos
# and exact assertions hold.

func _self_state(facing: Vector2) -> SkaterNetworkState:
	var st := SkaterNetworkState.new()
	st.facing = facing
	return st


const ARC_MAX_STEP := Agent.MOUSE_ARC_RATE_RAD_S * Agent.MOUSE_TICK_DELTA
const STEP_MAX := Agent.MOUSE_MAX_SPEED_M_S * Agent.MOUSE_TICK_DELTA


func test_arc_step_degenerate_target_returns_target() -> void:
	# final_target on top of self → no direction to define; return it as-is.
	assert_eq(sm._arc_step_mouse_target(Vector3.ZERO, Vector3.ZERO, _self_state(Vector2(0, 1))),
			Vector3.ZERO)


func test_arc_step_result_lies_on_aim_ring() -> void:
	sm._mouse_pos_initialized = false
	var r: Vector3 = sm._arc_step_mouse_target(Vector3.ZERO, Vector3(10, 0, 0), _self_state(Vector2(0, 1)))
	assert_almost_eq(r.distance_to(Vector3.ZERO), Agent.CARRY_BLADE_AIM_FORWARD_M, 0.0001)


func test_arc_step_caps_angular_rate() -> void:
	# Seed from facing +z (bearing 0), desired due east (bearing PI/2):
	# the step is clamped to one tick of MOUSE_ARC_RATE_RAD_S.
	sm._mouse_pos_initialized = false
	var r: Vector3 = sm._arc_step_mouse_target(Vector3.ZERO, Vector3(10, 0, 0), _self_state(Vector2(0, 1)))
	assert_almost_eq(atan2(r.x, r.z), ARC_MAX_STEP, 1e-5)


func test_arc_step_seeds_from_mouse_when_initialized() -> void:
	# Mouse parked due east; facing points +z; target points +z. If the seed
	# came from facing the result would barely move from +z — instead it steps
	# from the east seed, proving mouse-offset precedence.
	sm._mouse_pos = Vector3(2, 0, 0)
	sm._mouse_pos_initialized = true
	var r: Vector3 = sm._arc_step_mouse_target(Vector3.ZERO, Vector3(0, 0, 10), _self_state(Vector2(0, 1)))
	assert_almost_eq(atan2(r.x, r.z), PI / 2.0 - ARC_MAX_STEP, 1e-5)


func test_arc_step_converges_within_cap() -> void:
	# Desired bearing inside one tick of travel → reached exactly.
	sm._mouse_pos_initialized = false
	var desired := 0.03  # < ARC_MAX_STEP
	var ft := Vector3(sin(desired), 0, cos(desired)) * 5.0
	var r: Vector3 = sm._arc_step_mouse_target(Vector3.ZERO, ft, _self_state(Vector2(0, 1)))
	assert_almost_eq(atan2(r.x, r.z), desired, 1e-5)


func test_step_toward_first_call_snaps_and_caches() -> void:
	var r: Vector3 = sm._step_mouse_toward(Vector3(3, 0, 4))
	assert_true(sm._mouse_pos_initialized, "first call initializes the mouse")
	assert_almost_eq(sm._mouse_pos.x, 3.0, 1e-6)
	assert_almost_eq(sm._mouse_pos.z, 4.0, 1e-6)
	assert_eq(r, Vector3(3, 0, 4), "no noise → output equals mouse pos")
	assert_true(sm._has_cached_aim_target)
	assert_eq(sm._cached_aim_target, Vector3(3, 0, 4))
	assert_false(sm._cached_aim_uses_arc, "_step_mouse_toward is the no-arc path")


func test_step_toward_caps_travel_per_tick() -> void:
	sm._mouse_pos = Vector3.ZERO
	sm._mouse_pos_initialized = true
	sm._step_mouse_toward(Vector3(100, 0, 0))  # far east
	assert_almost_eq(sm._mouse_pos.x, STEP_MAX, 1e-5)
	assert_almost_eq(sm._mouse_pos.z, 0.0, 1e-6)


func test_step_toward_within_cap_snaps_to_target() -> void:
	sm._mouse_pos = Vector3.ZERO
	sm._mouse_pos_initialized = true
	sm._step_mouse_toward(Vector3(0.2, 0, 0.1))  # ~0.22 m < STEP_MAX
	assert_almost_eq(sm._mouse_pos.x, 0.2, 1e-6)
	assert_almost_eq(sm._mouse_pos.z, 0.1, 1e-6)


func test_step_aim_projects_target_onto_ring() -> void:
	sm._current_self_pos = Vector3.ZERO
	sm._current_self_state = _self_state(Vector2(0, 1))
	sm._mouse_pos_initialized = false
	sm._step_mouse_aim(Vector3(10, 0, 0))  # far east; arced onto the 2 m ring
	assert_almost_eq(Vector2(sm._mouse_pos.x, sm._mouse_pos.z).length(),
			Agent.CARRY_BLADE_AIM_FORWARD_M, 1e-4)
	assert_true(sm._cached_aim_uses_arc, "_step_mouse_aim is the arc path")


# ── Slice 3: shot wind-up geometry ───────────────────────────────────────────
# Pure trig on the aim direction — no snapshot, no goalie. Right-handed bot
# (is_left_handed = false → _handedness_perp_sign = 1.0).

func test_compensated_aim_is_unit_rotation_by_theta() -> void:
	var aim := Vector3(0, 0, 1)
	var dist := 5.0
	var c: Vector3 = sm._aim_dir_compensated_for_side_offset(aim, dist, 1.0)
	var theta := asin(Agent.BOT_WRISTER_SIDE_OFFSET_M / dist)
	assert_almost_eq(c.length(), 1.0, 1e-5, "compensation is a rotation, preserves length")
	assert_almost_eq(c.dot(aim), cos(theta), 1e-5, "angle off aim == asin(offset/dist)")


func test_compensated_aim_degenerate_returns_raw() -> void:
	# aim_distance <= side offset → unreachable setup; return raw aim.
	var aim := Vector3(0, 0, 1)
	assert_eq(sm._aim_dir_compensated_for_side_offset(aim, 0.1, 1.0), aim)


func test_compensated_aim_approaches_raw_at_long_range() -> void:
	var aim := Vector3(0, 0, 1)
	var c: Vector3 = sm._aim_dir_compensated_for_side_offset(aim, 1000.0, 1.0)
	assert_almost_eq(c.dot(aim), 1.0, 1e-4, "theta → 0 as distance grows")


func test_wind_up_sweep_length_equals_charge() -> void:
	var ep: Dictionary = sm._wind_up_endpoint_offsets(Vector3(0, 0, 1), 15.0, 0.7, 1.0)
	var sweep: Vector3 = ep["target"] - ep["start"]
	assert_almost_eq(sweep.length(), 0.7, 1e-5, "blade travels target_charge_m end to end")


func test_wind_up_midpoint_is_side_offset() -> void:
	var ep: Dictionary = sm._wind_up_endpoint_offsets(Vector3(0, 0, 1), 15.0, 0.7, 1.0)
	var mid: Vector3 = (ep["start"] + ep["target"]) * 0.5
	assert_almost_eq(mid.length(), Agent.BOT_WRISTER_SIDE_OFFSET_M, 1e-5,
			"both endpoints share the lateral release offset")


func test_wind_up_sweep_is_parallel_to_compensated_aim() -> void:
	var aim := Vector3(0, 0, 1)
	var ep: Dictionary = sm._wind_up_endpoint_offsets(aim, 15.0, 0.7, 1.0)
	var comp: Vector3 = sm._aim_dir_compensated_for_side_offset(aim, 15.0, 1.0)
	var sweep_dir: Vector3 = (ep["target"] - ep["start"]).normalized()
	assert_almost_eq(sweep_dir.dot(comp), 1.0, 1e-5)


# ── Slice 4: dispatch guards + decision throttle ─────────────────────────────
# The dispatch() entry guards and the throttle skip-path both return before the
# state-handler `match` (which runs role behavior), so they're testable without
# mocking the role carrier. A snapshot that can't be acted on resets the bot to
# OFF_PUCK; a throttled tick reuses the last decision instead of re-deciding.

func test_dispatch_null_snapshot_resets_off_puck() -> void:
	sm._state = Agent.State.CARRY
	sm.dispatch(InputState.new(), null)
	assert_eq(sm.get_state(), Agent.State.OFF_PUCK)


func test_dispatch_null_puck_state_resets_off_puck() -> void:
	sm._state = Agent.State.CARRY
	sm.dispatch(InputState.new(), WorldSnapshot.new())  # puck_state stays null
	assert_eq(sm.get_state(), Agent.State.OFF_PUCK)


func test_dispatch_empty_skater_states_resets_off_puck() -> void:
	sm._state = Agent.State.CARRY
	var s := WorldSnapshot.new()
	s.puck_state = PuckNetworkState.new()
	sm.dispatch(InputState.new(), s)
	assert_eq(sm.get_state(), Agent.State.OFF_PUCK)


func test_dispatch_missing_self_resets_off_puck() -> void:
	# Snapshot has skaters but not this bot (pre-dates its spawn) → freeze.
	sm._state = Agent.State.CARRY
	var s := _loose_puck_snap(Vector3.ZERO)
	_add_skater(s, TEAMMATE_ID, Vector3.ZERO)
	sm.dispatch(InputState.new(), s)
	assert_eq(sm.get_state(), Agent.State.OFF_PUCK)


func test_dispatch_throttled_tick_reuses_cached_decision() -> void:
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	_add_skater(s, SELF_ID, Vector3.ZERO)
	sm._state = Agent.State.OFF_PUCK  # non-press → eligible to skip
	sm._dispatch_skip_counter = 1
	sm._cached_move_vector = Vector2(0.3, -0.4)
	sm._cached_sprint_held = true
	sm._has_cached_aim_target = true
	sm._cached_aim_target = Vector3(1, 0, 2)
	sm._cached_aim_uses_arc = false
	var input := InputState.new()
	sm.dispatch(input, s)
	assert_eq(input.move_vector, Vector2(0.3, -0.4), "throttled tick reuses cached move")
	assert_true(input.sprint_held, "throttled tick reuses cached sprint")
	assert_eq(sm._dispatch_skip_counter, 0, "skip counter decremented")
	assert_eq(sm.get_state(), Agent.State.OFF_PUCK, "no re-decision on a skip tick")
	# Mouse re-stepped toward the cached target (no-arc → first call snaps).
	assert_almost_eq(input.mouse_world_pos.x, 1.0, 1e-6)
	assert_almost_eq(input.mouse_world_pos.z, 2.0, 1e-6)


# ── wants_direct_aim: skip the second-stage cursor lerp during committed shot ──

func test_wants_direct_aim_true_in_shot_states() -> void:
	sm._state = Agent.State.SHOOT_PRESSED
	assert_true(sm.wants_direct_aim(), "charging a wrister tracks the cursor directly")
	sm._state = Agent.State.QUICK_SHOT_PRESSED
	assert_true(sm.wants_direct_aim(), "quick shot tracks directly")
	sm._state = Agent.State.ONE_TIMER_PRESSED
	assert_true(sm.wants_direct_aim(), "one-timer tracks directly")


func test_wants_direct_aim_true_when_pre_aiming_a_shot() -> void:
	sm._state = Agent.State.CARRY
	sm._intended_action = Agent.State.SHOOT_PRESSED
	assert_true(sm.wants_direct_aim(), "shot pre-aim (still in CARRY) tracks directly")


func test_wants_direct_aim_false_for_carry_and_pass() -> void:
	sm._state = Agent.State.CARRY
	sm._intended_action = Agent.State.CARRY
	assert_false(sm.wants_direct_aim(), "plain carry keeps the second-stage lerp")
	sm._intended_action = Agent.State.PASS_PRESSED
	assert_false(sm.wants_direct_aim(), "pass pre-aim keeps the softening lerp")


# ── Slice 5: press-state handlers + transitions ──────────────────────────────
# The fire states (SHOOT_PRESSED / QUICK_SHOT_PRESSED / ONE_TIMER_PRESSED /
# PASS_PRESSED) are entered by the carrier from CARRY, but once entered they run
# to completion off pre-set fields — no carrier needed. They read only the
# snapshot + this bot's identity, and every helper they touch (steering,
# shot-aim, goalie prediction) has a headless fallback (empty per-team cache →
# live partition, null goalie → aim at the net). So they're drivable through
# dispatch() directly, which also exercises the press-state throttle bypass.
#
# have_puck is read from `snapshot.real_puck_carrier_peer_id == _peer_id`
# (proprioception), NOT the reaction-delayed `puck_state.carrier_peer_id`.

func _self_snap(self_pos: Vector3, have_puck: bool) -> WorldSnapshot:
	var s := WorldSnapshot.new()
	s.puck_state = PuckNetworkState.new()
	s.puck_state.position = self_pos
	var owner: int = SELF_ID if have_puck else -1
	s.puck_state.carrier_peer_id = owner
	s.real_puck_carrier_peer_id = owner
	_add_skater(s, SELF_ID, self_pos)
	return s


# ── QUICK_SHOT_PRESSED (one-tick release) ────────────────────────────────────

func test_quick_shot_fires_and_returns_to_carry() -> void:
	sm._state = Agent.State.QUICK_SHOT_PRESSED
	var i := InputState.new()
	sm.dispatch(i, _self_snap(Vector3.ZERO, true))
	assert_true(i.shoot_pressed, "quick shot fires the press edge")
	assert_true(i.shoot_held, "quick shot holds so the controller reads a release next tick")
	assert_eq(sm.get_state(), Agent.State.CARRY, "quick shot is a one-tick press")


func test_quick_shot_without_puck_routes_to_lost_state() -> void:
	sm._state = Agent.State.QUICK_SHOT_PRESSED
	var s := _self_snap(Vector3.ZERO, false)
	sm.dispatch(InputState.new(), s)
	assert_ne(sm.get_state(), Agent.State.QUICK_SHOT_PRESSED, "no puck leaves the fire state")
	assert_eq(sm.get_state(), sm._post_puck_lost_state(s), "routes to the puck-lost state")


func test_press_state_ignores_dispatch_throttle() -> void:
	# A non-press state with a pending skip counter would reuse its cached
	# decision; a press state must always dispatch full (charge timing is
	# tick-sensitive).
	sm._state = Agent.State.QUICK_SHOT_PRESSED
	sm._dispatch_skip_counter = 5
	var i := InputState.new()
	sm.dispatch(i, _self_snap(Vector3.ZERO, true))
	assert_true(i.shoot_pressed, "press states are never throttled")
	assert_eq(sm.get_state(), Agent.State.CARRY)


# ── SHOOT_PRESSED (multi-tick wrister charge) ────────────────────────────────

func test_shoot_pressed_charges_then_releases_into_carry() -> void:
	sm._state = Agent.State.SHOOT_PRESSED
	var s := _self_snap(Vector3.ZERO, true)
	# Tick 0 fires the shoot_pressed edge and begins holding the charge.
	var i0 := InputState.new()
	sm.dispatch(i0, s)
	assert_true(i0.shoot_pressed, "tick 0 fires the shoot_pressed edge")
	assert_true(i0.shoot_held, "tick 0 holds the charge")
	assert_eq(sm.get_state(), Agent.State.SHOOT_PRESSED, "still charging after tick 0")
	# The edge is a one-tick event — later charge ticks don't re-press.
	var i1 := InputState.new()
	sm.dispatch(i1, s)
	assert_false(i1.shoot_pressed, "shoot_pressed is a tick-0-only edge")
	assert_true(i1.shoot_held, "still holding the charge")
	# Drive to release: shoot_held drops on the final tick and we return to CARRY.
	var released := false
	for _n in range(Agent.BOT_WRISTER_CHARGE_TICKS + 2):
		var i := InputState.new()
		sm.dispatch(i, s)
		if sm.get_state() == Agent.State.CARRY:
			assert_false(i.shoot_held, "release tick drops shoot_held for the wrister")
			released = true
			break
		assert_true(i.shoot_held, "held high through the whole charge")
	assert_true(released, "the charge releases into CARRY within the charge budget")


func test_shoot_pressed_lost_puck_bails() -> void:
	sm._state = Agent.State.SHOOT_PRESSED
	var s := _self_snap(Vector3.ZERO, true)
	sm.dispatch(InputState.new(), s)  # tick 0 → charge begins
	assert_eq(sm.get_state(), Agent.State.SHOOT_PRESSED)
	# Puck stripped mid-charge.
	s.puck_state.carrier_peer_id = -1
	s.real_puck_carrier_peer_id = -1
	sm.dispatch(InputState.new(), s)
	assert_ne(sm.get_state(), Agent.State.SHOOT_PRESSED, "lost puck bails out of the charge")
	assert_eq(sm.get_state(), sm._post_puck_lost_state(s))


func test_shoot_pressed_stagger_cancels_via_block() -> void:
	# A body check mid-charge (stagger_timer set) cancels the wrister rather
	# than flailing it through the hit. Cancel is via block_held, not a release.
	sm._state = Agent.State.SHOOT_PRESSED
	var s := _self_snap(Vector3.ZERO, true)
	sm.dispatch(InputState.new(), s)  # tick 0 (bail only fires once charge_tick > 0)
	s.skater_states[SELF_ID].stagger_timer = 0.5
	var i := InputState.new()
	sm.dispatch(i, s)
	assert_eq(sm.get_state(), Agent.State.CARRY, "a check mid-charge cancels the wrister")
	assert_true(i.block_held, "cancel routes through block_held, not a shot release")


func test_shoot_pressed_front_pressure_cancels_via_block() -> void:
	# An opponent closing from the front (toward the attacking goal) within the
	# bail radius cancels the windup. Team 0 attacks −Z.
	sm._state = Agent.State.SHOOT_PRESSED
	var s := _self_snap(Vector3.ZERO, true)
	sm.dispatch(InputState.new(), s)  # tick 0
	_add_skater(s, OPP_ID, Vector3(0, 0, -1))  # 1 m ahead, inside BOT_WRISTER_BAIL_RADIUS_M
	var i := InputState.new()
	sm.dispatch(i, s)
	assert_eq(sm.get_state(), Agent.State.CARRY, "front pressure cancels the windup")
	assert_true(i.block_held)


func test_shoot_pressed_ignores_rear_pressure() -> void:
	# The bail is forward-only: a backchecker behind the shooter (toward our own
	# net, +Z for team 0) can't disrupt the windup and must not cancel a clean shot.
	sm._state = Agent.State.SHOOT_PRESSED
	var s := _self_snap(Vector3.ZERO, true)
	sm.dispatch(InputState.new(), s)  # tick 0
	_add_skater(s, OPP_ID, Vector3(0, 0, 1))  # 1 m behind
	sm.dispatch(InputState.new(), s)
	assert_eq(sm.get_state(), Agent.State.SHOOT_PRESSED, "rear pressure does not cancel the charge")


# ── ONE_TIMER_PRESSED (off-puck, fire on contact) ────────────────────────────

func test_one_timer_holds_until_puck_arrives() -> void:
	sm._state = Agent.State.ONE_TIMER_PRESSED
	var s := _self_snap(Vector3.ZERO, false)  # puck not here yet
	var i0 := InputState.new()
	sm.dispatch(i0, s)
	assert_true(i0.shoot_pressed, "tick 0 fires the press edge")
	assert_true(i0.shoot_held, "holds the charge while waiting for the puck")
	assert_eq(sm.get_state(), Agent.State.ONE_TIMER_PRESSED, "keeps waiting off-puck")
	# Puck contacts the blade → release fires.
	s.real_puck_carrier_peer_id = SELF_ID
	var i1 := InputState.new()
	sm.dispatch(i1, s)
	assert_false(i1.shoot_held, "release drops shoot_held on contact")
	assert_eq(sm.get_state(), Agent.State.CARRY)


func test_one_timer_safety_bail_after_timeout() -> void:
	# If the puck never arrives within the press budget, release with no puck
	# (no shot fires) and drop to the puck-lost state.
	sm._state = Agent.State.ONE_TIMER_PRESSED
	sm._intent_max_wait_ticks = 2
	var s := _self_snap(Vector3.ZERO, false)
	var bailed := false
	for _n in range(5):
		var i := InputState.new()
		sm.dispatch(i, s)
		if sm.get_state() != Agent.State.ONE_TIMER_PRESSED:
			assert_false(i.shoot_held, "timeout releases without holding")
			assert_eq(sm.get_state(), sm._post_puck_lost_state(s))
			bailed = true
			break
	assert_true(bailed, "the press times out and bails")


func test_one_timer_seeks_moving_anchor() -> void:
	# Mode-A reception sets a net-forward anchor; the bot skates to it while
	# holding the shot (vs the FINISHER fast path, which brakes in place at INF).
	sm._state = Agent.State.ONE_TIMER_PRESSED
	sm._one_timer_anchor = Vector3(5, 0, 0)  # far to +X
	var i := InputState.new()
	sm.dispatch(i, _self_snap(Vector3.ZERO, false))
	assert_gt(i.move_vector.x, 0.0, "seeks the moving one-timer anchor")


# ── PASS_PRESSED ─────────────────────────────────────────────────────────────

func test_pass_pressed_quick_fires_and_clears_target() -> void:
	sm._state = Agent.State.PASS_PRESSED
	sm._pass_should_charge = false
	sm._pass_target_peer_id = TEAMMATE_ID
	var s := _self_snap(Vector3.ZERO, true)
	_add_skater(s, TEAMMATE_ID, Vector3(3, 0, 0))
	var i := InputState.new()
	sm.dispatch(i, s)
	assert_true(i.shoot_pressed, "quick pass fires the edge")
	assert_true(i.shoot_held)
	assert_eq(sm.get_state(), Agent.State.CARRY, "quick pass is a one-tick press")
	assert_eq(sm._pass_target_peer_id, -1, "quick pass clears its target for the next pick")


func test_pass_pressed_lost_puck_bails_and_clears() -> void:
	sm._state = Agent.State.PASS_PRESSED
	sm._pass_should_charge = true
	sm._pass_should_saucer = true
	sm._pass_target_peer_id = TEAMMATE_ID
	var s := _self_snap(Vector3.ZERO, false)  # no puck
	sm.dispatch(InputState.new(), s)
	assert_ne(sm.get_state(), Agent.State.PASS_PRESSED, "lost puck bails")
	assert_eq(sm.get_state(), sm._post_puck_lost_state(s))
	assert_eq(sm._pass_target_peer_id, -1, "bail clears the stale pass target")
	assert_false(sm._pass_should_charge, "bail clears the charge flag")
	assert_false(sm._pass_should_saucer, "bail clears the saucer flag")


func test_pass_pressed_charged_releases_after_windup() -> void:
	sm._state = Agent.State.PASS_PRESSED
	sm._pass_should_charge = true
	sm._pass_target_peer_id = TEAMMATE_ID
	var s := _self_snap(Vector3.ZERO, true)
	_add_skater(s, TEAMMATE_ID, Vector3(8, 0, 0))
	var released := false
	for _n in range(Agent.BOT_WRISTER_CHARGE_TICKS + 2):
		var i := InputState.new()
		sm.dispatch(i, s)
		if sm.get_state() == Agent.State.CARRY:
			assert_false(i.shoot_held, "charged pass releases by dropping shoot_held")
			released = true
			break
		assert_true(i.shoot_held, "held high through the charge")
	assert_true(released, "the charged pass releases within the charge budget")
	assert_eq(sm._pass_target_peer_id, -1, "release clears the pass target")
