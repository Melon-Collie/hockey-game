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


# ── _shade_intercept_goal_side (static, pure geometry) ───────────────────────
# Full coverage lives in test_ai_chase_angling.gd; this is the slice's smoke
# check that the shade pulls the intercept toward the defended net by one
# blade reach.

func test_shade_intercept_pulls_toward_our_net() -> void:
	var target := Vector3(3, 0, -10)
	var our_net := Vector3(0, 0, GameRules.GOAL_LINE_Z)
	var shaded: Vector3 = Agent._shade_intercept_goal_side(target, our_net)
	assert_almost_eq(
			Vector2(shaded.x - target.x, shaded.z - target.z).length(),
			Agent.BLADE_REACH_M, 0.0001)
	assert_gt(shaded.z, target.z, "shade moves the point toward the +Z net")


# ── _lead_intercept (speed-capped kinematic reachability) ────────────────────

func test_lead_intercept_stationary_puck_targets_puck() -> void:
	# A stationary puck's trajectory never moves; the intercept must be the
	# puck itself regardless of which constraint binds first.
	var out: Vector3 = sm._lead_intercept(
			Vector3.ZERO, Vector3.ZERO, Vector3(6, 0, 0), Vector3.ZERO)
	assert_almost_eq(out.x, 6.0, 0.001)
	assert_almost_eq(out.z, 0.0, 0.001)


func test_lead_intercept_receding_fast_puck_respects_speed_cap() -> void:
	# From rest, a puck receding at 8 m/s from 6 m ahead. The accel-only
	# model (½·A·T² reach) claimed an intercept ~1.9 s out — arrival speed
	# would be ~22 m/s, far past the cap — so the bot aimed at a point it
	# physically could not make. With the cruise bound the chosen point
	# must lie at or beyond what an accel-then-cruise sprint actually
	# covers by the time the puck is there.
	var puck_pos := Vector3(0, 0, 6)
	var puck_vel := Vector3(0, 0, 8)
	var out: Vector3 = sm._lead_intercept(Vector3.ZERO, Vector3.ZERO, puck_pos, puck_vel)
	# Old model's pick sat near z≈21 (T≈1.87 s). The speed-honest model
	# must aim meaningfully deeper (or at the window's end).
	assert_gt(out.z, 22.0,
			"speed cap rejects the accel-only phantom intercept at z≈21")


func test_lead_intercept_moving_with_puck_picks_early_point() -> void:
	# Already at top speed right behind a slower puck: the chase is nearly
	# won and the intercept should resolve within the first few steps.
	var out: Vector3 = sm._lead_intercept(
			Vector3.ZERO, Vector3(0, 0, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S),
			Vector3(0, 0, 2), Vector3(0, 0, 2))
	assert_lt(out.z, 6.0, "closing chase resolves to a near intercept")


func test_cruise_distance_matches_closed_form() -> void:
	# From rest at A=12, V=9: t_acc = 0.75 s. At t=0.5 (accel phase):
	# ½·12·0.25 = 1.5 m. At t=2.0: ½·12·0.5625 + 9·1.25 = 14.625 m.
	sm._chase_max_accel = 12.0
	sm._self_max_speed = 9.0
	assert_almost_eq(sm._cruise_distance(0.0, 0.5), 1.5, 0.001)
	assert_almost_eq(sm._cruise_distance(0.0, 2.0), 14.625, 0.001)
	# Moving AWAY (v0 negative) covers strictly less ground.
	assert_lt(sm._cruise_distance(-4.0, 2.0), sm._cruise_distance(0.0, 2.0))


# ── Slice 2: mouse / aim motion geometry ─────────────────────────────────────
# Pure motion model — no snapshot, no role state. The output is the smooth
# _mouse_pos (per-tick cursor noise no longer exists; execution error is a
# per-release sample that never touches raw agents), so exact assertions hold.

func _self_state(facing: Vector2) -> SkaterNetworkState:
	var st := SkaterNetworkState.new()
	st.facing = facing
	return st


const ARC_MAX_STEP := Agent.MOUSE_ARC_RATE_RAD_S * Agent.MOUSE_TICK_DELTA
const STEP_MAX := Agent.MOUSE_MAX_SPEED_M_S * Agent.MOUSE_TICK_DELTA


func test_arc_step_degenerate_target_returns_target() -> void:
	# final_target on top of self → no direction to define; return it as-is.
	assert_eq(sm._arc_step_mouse_target(Vector3.ZERO, Vector3.ZERO, _self_state(Vector2(0, 1)), Agent.MOUSE_ARC_RATE_RAD_S),
			Vector3.ZERO)


func test_arc_step_result_lies_on_aim_ring() -> void:
	sm._mouse_pos_initialized = false
	var r: Vector3 = sm._arc_step_mouse_target(Vector3.ZERO, Vector3(10, 0, 0), _self_state(Vector2(0, 1)), Agent.MOUSE_ARC_RATE_RAD_S)
	assert_almost_eq(r.distance_to(Vector3.ZERO), Agent.CARRY_BLADE_AIM_FORWARD_M, 0.0001)


func test_arc_step_caps_angular_rate() -> void:
	# Seed from facing +z (bearing 0), desired due east (bearing PI/2):
	# the step is clamped to one tick of MOUSE_ARC_RATE_RAD_S.
	sm._mouse_pos_initialized = false
	var r: Vector3 = sm._arc_step_mouse_target(Vector3.ZERO, Vector3(10, 0, 0), _self_state(Vector2(0, 1)), Agent.MOUSE_ARC_RATE_RAD_S)
	assert_almost_eq(atan2(r.x, r.z), ARC_MAX_STEP, 1e-5)


func test_arc_step_seeds_from_mouse_when_initialized() -> void:
	# Mouse parked due east; facing points +z; target points +z. If the seed
	# came from facing the result would barely move from +z — instead it steps
	# from the east seed, proving mouse-offset precedence.
	sm._mouse_pos = Vector3(2, 0, 0)
	sm._mouse_pos_initialized = true
	var r: Vector3 = sm._arc_step_mouse_target(Vector3.ZERO, Vector3(0, 0, 10), _self_state(Vector2(0, 1)), Agent.MOUSE_ARC_RATE_RAD_S)
	assert_almost_eq(atan2(r.x, r.z), PI / 2.0 - ARC_MAX_STEP, 1e-5)


func test_arc_step_converges_within_cap() -> void:
	# Desired bearing inside one tick of travel → reached exactly.
	sm._mouse_pos_initialized = false
	var desired := 0.03  # < ARC_MAX_STEP
	var ft := Vector3(sin(desired), 0, cos(desired)) * 5.0
	var r: Vector3 = sm._arc_step_mouse_target(Vector3.ZERO, ft, _self_state(Vector2(0, 1)), Agent.MOUSE_ARC_RATE_RAD_S)
	assert_almost_eq(atan2(r.x, r.z), desired, 1e-5)


func test_step_toward_first_call_snaps_and_caches() -> void:
	var r: Vector3 = sm._step_mouse_toward(Vector3(3, 0, 4))
	assert_true(sm._mouse_pos_initialized, "first call initializes the mouse")
	assert_almost_eq(sm._mouse_pos.x, 3.0, 1e-6)
	assert_almost_eq(sm._mouse_pos.z, 4.0, 1e-6)
	assert_eq(r, Vector3(3, 0, 4), "no noise → output equals mouse pos")
	assert_true(sm._has_cached_aim_target)
	assert_eq(sm._cached_aim_target, Vector3(3, 0, 4))
	assert_eq(sm._cached_aim_mode, Agent._STEP_DIRECT, "_step_mouse_toward is the direct path")


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
	assert_eq(sm._cached_aim_mode, Agent._STEP_ARC, "_step_mouse_aim is the arc path")


func test_body_face_snaps_cursor_straight_at_an_in_cone_target() -> void:
	# Off-puck body facing must NOT be gated by the bot's Hands blade slew. Like a
	# human flicking the mouse, _step_mouse_face places the cursor DIRECTLY at the
	# in-cone target and snaps to it in a single tick (no per-tick slew) — the body
	# then turns toward it at facing_drag_speed downstream. Even with a very low
	# Hands blade slew applied, the FACE cursor still snaps straight to the target.
	var slow := AISkaterCaps.new()
	slow.blade_speed = 5.0            # low Hands → slow blade slew (must not matter)
	sm.apply_capabilities(slow)
	sm._current_self_pos = Vector3.ZERO
	sm._current_self_state = _self_state(Vector2(0, 1))
	var target := Vector3(4, 0, 3)    # ~53° off +Z, well inside the reach cone
	# A prior cursor parked elsewhere — the snap must ignore it (no slew from it).
	sm._mouse_pos = Vector3(-2, 0, 0)
	sm._mouse_pos_initialized = true
	var r: Vector3 = sm._step_mouse_face(target)
	assert_eq(sm._cached_aim_mode, Agent._STEP_FACE)
	assert_almost_eq(Vector2(r.x, r.z).length(), Agent.CARRY_BLADE_AIM_FORWARD_M, 1e-4,
			"cursor sits on the body ring in one tick, ignoring the low blade slew")
	assert_almost_eq(Vector2(r.x, r.z).angle(), Vector2(4, 3).angle(), 1e-4,
			"…pointing straight at the in-cone target, no slew")


func test_body_face_clamps_a_behind_target_to_the_reach_cone() -> void:
	# A target in the back wedge (directly behind) would freeze the pose IK gate if
	# the cursor snapped there. Instead it's clamped to the cone edge on one side,
	# so facing can rotate toward it and walk around. Facing +Z, target behind (−Z).
	sm._current_self_pos = Vector3.ZERO
	sm._current_self_state = _self_state(Vector2(0, 1))
	sm._mouse_pos_initialized = false
	var r: Vector3 = sm._step_mouse_face(Vector3(0, 0, -5))
	var off_angle: float = absf(Vector2(0, 1).angle_to(Vector2(r.x, r.z)))
	assert_lt(off_angle, sm._self_reach_cone_half_angle + 1e-4,
			"clamped inside the reachable cone — the gate never freezes")
	assert_almost_eq(off_angle,
			sm._self_reach_cone_half_angle - Agent.FACE_GATE_MARGIN_RAD, 1e-4,
			"…parked right at the cone edge, so the body turns as far as it can")


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
	sm._cached_aim_mode = Agent._STEP_DIRECT
	var input := InputState.new()
	sm.dispatch(input, s)
	assert_eq(input.move_vector, Vector2(0.3, -0.4), "throttled tick reuses cached move")
	assert_true(input.sprint_held, "throttled tick reuses cached sprint")
	assert_eq(sm._dispatch_skip_counter, 0, "skip counter decremented")
	assert_eq(sm.get_state(), Agent.State.OFF_PUCK, "no re-decision on a skip tick")
	# Mouse re-stepped toward the cached target (no-arc → first call snaps).
	assert_almost_eq(input.mouse_world_pos.x, 1.0, 1e-6)
	assert_almost_eq(input.mouse_world_pos.z, 2.0, 1e-6)


# ── Slice 5: press-state handlers + transitions ──────────────────────────────
# The fire states (SHOOT_PRESSED / ONE_TIMER_PRESSED / PASS_PRESSED) are
# entered by the carrier from CARRY, but once entered they run
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


# ── press-state dispatch throttle ────────────────────────────────────────────

func test_press_state_ignores_dispatch_throttle() -> void:
	# A non-press state with a pending skip counter would reuse its cached
	# decision; a press state must always dispatch full (charge timing is
	# tick-sensitive). Exercised via the dump's one-tick quick release.
	sm._state = Agent.State.PASS_PRESSED
	sm._dump_target = Vector3(12, 0, 0)
	sm._dispatch_skip_counter = 5
	var i := InputState.new()
	sm.dispatch(i, _self_snap(Vector3.ZERO, true))
	assert_true(i.quick_shot_pressed, "press states are never throttled")
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
	assert_true(i.quick_shot_pressed, "quick pass fires the dedicated quick-shot edge")
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


func test_pass_pressed_dump_clear_chips_high_and_clears() -> void:
	# A DZ clear-out: dump_target set, not soft. PASS_PRESSED fires a one-tick
	# quick release aimed at the location, lifted HIGH to chip over sticks into
	# the neutral zone — never a charged wind-up.
	sm._state = Agent.State.PASS_PRESSED
	sm._pass_should_charge = true         # a charge flag must NOT survive a dump
	sm._dump_target = Vector3(12, 0, 0)   # a location, no receiver
	sm._dump_is_soft = false
	var i := InputState.new()
	sm.dispatch(i, _self_snap(Vector3.ZERO, true))
	assert_true(i.quick_shot_pressed, "a dump fires the one-tick quick release")
	assert_eq(i.elevation_level, ShotMechanics.ELEVATION_HIGH, "a clear-out chips HIGH")
	assert_eq(sm.get_state(), Agent.State.CARRY, "the dump is a one-tick press")
	assert_false(sm._dump_target.is_finite(), "firing clears the dump target")


func test_pass_pressed_dump_in_is_a_soft_low_flip() -> void:
	# A dump-in past centre: soft flip to the corner → LOW loft, still a one-tick
	# quick release (no wind-up to be stripped through).
	sm._state = Agent.State.PASS_PRESSED
	sm._dump_target = Vector3(-11, 0, -20)
	sm._dump_is_soft = true
	var i := InputState.new()
	sm.dispatch(i, _self_snap(Vector3.ZERO, true))
	assert_true(i.quick_shot_pressed, "a dump-in fires the one-tick quick release")
	assert_eq(i.elevation_level, ShotMechanics.ELEVATION_LOW, "a dump-in flips LOW")
	assert_false(sm._dump_target.is_finite(), "firing clears the dump target")


func test_pass_pressed_dump_lost_puck_clears_target() -> void:
	# Puck knocked loose before the dump fires — bail clears the dump target so a
	# later PASS/DUMP starts fresh.
	sm._state = Agent.State.PASS_PRESSED
	sm._dump_target = Vector3(12, 0, 0)
	sm.dispatch(InputState.new(), _self_snap(Vector3.ZERO, false))  # no puck
	assert_ne(sm.get_state(), Agent.State.PASS_PRESSED, "lost puck bails")
	assert_false(sm._dump_target.is_finite(), "bail clears the dump target")


# ── Slice 6: CARRY handler + carrier-driven transitions ──────────────────────
# _state_carry is the one handler that runs the AIRoleCarrier scoring behavior.
# We swap in a stub carrier (a subclass that publishes a scripted intent instead
# of scoring) so the CARRY handler's own logic — the puck-loss bail, the
# intent→State mapping, the pre-aim-then-fire commit, the hysteresis hold, and
# the timeout — is tested in isolation from the scorer. The stub also spies on
# clear_intent / reset so we can assert the handler drives the carrier's
# re-eval lifecycle as documented.

# Stub carrier: publishes `next_intent` (+ anchor / pass target) into the mirror
# fields the SM reads after decide(), and counts the lifecycle calls. Subclasses
# the real carrier so it satisfies the SM's typed `_carrier` field; super() on
# the lifecycle methods keeps the real field-clearing so SM invariants hold.
class _CarrierStub extends AIRoleCarrier:
	var decide_calls: int = 0
	var clear_intent_calls: int = 0
	var reset_calls: int = 0
	var next_intent: int = AIRoleCarrier.INTENT_CARRY
	var next_anchor: Vector3 = Vector3.ZERO
	var next_pass_target: int = -1
	var next_dump_target: Vector3 = Vector3.INF
	var next_dump_is_soft: bool = false

	func decide(_ctx: RoleContext) -> RoleDecision:
		decide_calls += 1
		intended_action = next_intent
		last_carry_anchor = next_anchor
		pass_target_peer_id = next_pass_target
		dump_target = next_dump_target
		dump_is_soft = next_dump_is_soft
		return RoleDecision.new()

	func clear_intent() -> void:
		clear_intent_calls += 1
		super()

	func reset() -> void:
		reset_calls += 1
		super()


func _stub_carry(intent: int, anchor: Vector3 = Vector3.ZERO,
		pass_target: int = -1) -> _CarrierStub:
	var stub := _CarrierStub.new()
	stub.next_intent = intent
	stub.next_anchor = anchor
	stub.next_pass_target = pass_target
	sm._carrier = stub
	sm._state = Agent.State.CARRY
	return stub


func test_carry_lost_puck_bails_and_resets_carrier() -> void:
	var stub := _stub_carry(AIRoleCarrier.INTENT_CARRY)
	sm._intended_action = Agent.State.SHOOT_PRESSED  # some stale intent to clear
	sm._pass_target_peer_id = TEAMMATE_ID
	var s := _self_snap(Vector3.ZERO, false)  # no puck
	sm.dispatch(InputState.new(), s)
	assert_ne(sm.get_state(), Agent.State.CARRY, "no puck leaves CARRY")
	assert_eq(sm.get_state(), sm._post_puck_lost_state(s))
	assert_eq(sm._intended_action, Agent.State.CARRY, "stale intent cleared on bail")
	assert_eq(sm._pass_target_peer_id, -1, "pass target cleared on bail")
	assert_eq(stub.reset_calls, 1, "the carrier is reset when the puck is lost")


func test_carry_intent_carry_stays_and_steers_to_anchor() -> void:
	# CARRY intent → no transition; steer toward the carrier's anchor.
	_stub_carry(AIRoleCarrier.INTENT_CARRY, Vector3(6, 0, 0))
	var i := InputState.new()
	sm.dispatch(i, _self_snap(Vector3.ZERO, true))
	assert_eq(sm.get_state(), Agent.State.CARRY, "carry intent holds CARRY")
	assert_eq(sm._intended_action, Agent.State.CARRY)
	assert_gt(i.move_vector.x, 0.0, "steers toward the carry anchor at +X")


func test_carry_shoot_intent_commits_to_shoot_pressed() -> void:
	_stub_carry(AIRoleCarrier.INTENT_SHOOT)
	var s := _self_snap(Vector3.ZERO, true)
	# Point facing at the attacking goal (−Z for team 0) so pre-aim converges fast.
	s.skater_states[SELF_ID].facing = Vector2(0, -1)
	var committed := false
	for _n in range(sm._intent_max_wait_ticks + 2):
		sm.dispatch(InputState.new(), s)
		if sm.get_state() == Agent.State.SHOOT_PRESSED:
			committed = true
			break
		assert_eq(sm.get_state(), Agent.State.CARRY, "still pre-aiming until convergence")
	assert_true(committed, "shoot intent pre-aims then commits to SHOOT_PRESSED")


func test_carry_intent_maps_to_matching_press_state() -> void:
	# The intent→State mapping for each fire kind. Manipulate the pre-aim lock +
	# tick budget so the commit fires on the first dispatch regardless of aim
	# geometry (timeout path), isolating the mapping.
	var cases := {
		AIRoleCarrier.INTENT_SHOOT: Agent.State.SHOOT_PRESSED,
		AIRoleCarrier.INTENT_PASS: Agent.State.PASS_PRESSED,
	}
	for intent: int in cases:
		before_each()  # fresh SM per case
		var stub := _stub_carry(intent, Vector3.ZERO, TEAMMATE_ID)
		var s := _self_snap(Vector3.ZERO, true)
		_add_skater(s, TEAMMATE_ID, Vector3(4, 0, 0))
		# Force the timeout branch on the first pre-aim tick: after tick-0 sets
		# _intended_action, the convergence gate sees wait >= max and commits.
		sm._intent_max_wait_ticks = 0
		var landed: int = -1
		for _n in range(3):
			sm.dispatch(InputState.new(), s)
			if sm.get_state() != Agent.State.CARRY:
				landed = sm.get_state()
				break
		assert_eq(landed, cases[intent], "intent %d maps to its press state" % intent)
		assert_eq(stub.clear_intent_calls, 1, "commit forces a carrier re-eval")


func test_carry_dump_intent_commits_and_freezes_target() -> void:
	# INTENT_DUMP maps to PASS_PRESSED (the reused release path) and the dump
	# target is captured at commit. Force the timeout branch so the commit lands
	# on the first pre-aim tick, isolating the mapping + freeze from aim geometry.
	var stub := _stub_carry(AIRoleCarrier.INTENT_CARRY)
	stub.next_intent = AIRoleCarrier.INTENT_DUMP
	stub.next_dump_target = Vector3(12, 0, 5)
	stub.next_dump_is_soft = false
	sm._intent_max_wait_ticks = 0
	var s := _self_snap(Vector3.ZERO, true)
	var landed: int = -1
	for _n in range(3):
		sm.dispatch(InputState.new(), s)
		if sm.get_state() != Agent.State.CARRY:
			landed = sm.get_state()
			break
	assert_eq(landed, Agent.State.PASS_PRESSED, "a dump commits to the PASS_PRESSED release path")
	assert_eq(sm._dump_target, Vector3(12, 0, 5), "the dump target is frozen at commit")
	assert_eq(stub.clear_intent_calls, 1, "commit forces a carrier re-eval")


func test_carry_holds_intent_against_carrier_flip() -> void:
	# Hysteresis: once a fire intent is locked and the bot is pre-aiming, a
	# carrier that flips back to CARRY must NOT cancel the pending shot.
	var stub := _stub_carry(AIRoleCarrier.INTENT_CARRY)  # carrier now wants CARRY
	sm._intended_action = Agent.State.SHOOT_PRESSED       # but we're mid-pre-aim
	sm._intent_wait_ticks = 0
	# Freeze the cursor far from the aim so convergence can't fire this tick.
	sm._mouse_max_speed_m_s = 0.0001
	sm._mouse_pos = Vector3(50, 0, 50)
	sm._mouse_pos_initialized = true
	sm.dispatch(InputState.new(), _self_snap(Vector3.ZERO, true))
	assert_eq(sm._intended_action, Agent.State.SHOOT_PRESSED,
			"a carrier CARRY flip does not cancel the pending shot")
	assert_eq(sm.get_state(), Agent.State.CARRY, "still pre-aiming, not yet committed")
	assert_gt(sm._intent_wait_ticks, 0, "the pre-aim wait counter advances")


func test_carry_pre_aim_times_out_and_fires() -> void:
	# Even with the cursor never converging, the pre-aim commits once the wait
	# counter reaches the timeout — the safety hatch against a never-arriving aim.
	_stub_carry(AIRoleCarrier.INTENT_SHOOT)
	sm._intended_action = Agent.State.SHOOT_PRESSED
	sm._intent_wait_ticks = sm._intent_max_wait_ticks  # at the timeout threshold
	sm._mouse_max_speed_m_s = 0.0001
	sm._mouse_pos = Vector3(50, 0, 50)  # nowhere near the aim
	sm._mouse_pos_initialized = true
	sm.dispatch(InputState.new(), _self_snap(Vector3.ZERO, true))
	assert_eq(sm.get_state(), Agent.State.SHOOT_PRESSED, "timeout commits the shot anyway")


# ── Wrister wind-up handedness (regression: the perp sign was inverted, so bots
# charged every wrister/pass on the backhand side and paid the backhand penalty).
# Authoritative reference: _try_shot_reception (~:1581) defines RH forehand as
# -left_dir where left_dir = Vector3(aim.z, 0, -aim.x); LH mirrors. The wind-up
# midpoint offset = perp * SIDE_OFFSET (the ±aim*half endpoints cancel), so its
# projection onto the forehand direction must be positive on the forehand side. ─

func _windup_midpoint(agent: SkaterAgentStateMachine, aim_dir: Vector3, side_sign: float) -> Vector3:
	# aim_distance well past SIDE_OFFSET so the compensation tilt is tiny and the
	# degenerate guard doesn't fire; target_charge arbitrary positive.
	var e: Dictionary = agent._wind_up_endpoint_offsets(aim_dir, 10.0, 0.5, side_sign)
	return (e.start as Vector3 + e.target as Vector3) * 0.5

func _forehand_dir(aim_dir: Vector3, is_left_handed: bool) -> Vector3:
	var left_dir := Vector3(aim_dir.z, 0.0, -aim_dir.x)
	return left_dir if is_left_handed else -left_dir

func test_windup_forehand_side_right_handed() -> void:
	# sm from before_each is right-handed. For several aim directions the wind-up
	# must sit on the forehand side (positive dot with the reception forehand dir).
	for aim: Vector3 in [Vector3(0, 0, -1), Vector3(1, 0, -1).normalized(), Vector3(-1, 0, -1).normalized()]:
		var mid: Vector3 = _windup_midpoint(sm, aim, 1.0)
		assert_gt(mid.dot(_forehand_dir(aim, false)), 0.0,
				"RH wind-up on the forehand side for aim %s" % aim)

func test_windup_forehand_side_left_handed() -> void:
	var lh := Agent.new()
	lh.setup(SELF_ID, 0, TeamBrain.new(0, _team_map), _team_map, true)  # left-handed
	for aim: Vector3 in [Vector3(0, 0, -1), Vector3(1, 0, -1).normalized(), Vector3(-1, 0, -1).normalized()]:
		var mid: Vector3 = _windup_midpoint(lh, aim, 1.0)
		assert_gt(mid.dot(_forehand_dir(aim, true)), 0.0,
				"LH wind-up on the forehand side for aim %s" % aim)

func test_windup_side_flip_moves_to_backhand() -> void:
	# The defender-driven side flip (side_sign = -1) must move the wind-up to the
	# opposite (backhand) side, i.e. negative dot with the forehand dir.
	var aim := Vector3(0, 0, -1)
	var mid: Vector3 = _windup_midpoint(sm, aim, -1.0)
	assert_lt(mid.dot(_forehand_dir(aim, false)), 0.0,
			"side-flip moves the RH wind-up to the backhand side")


# ── _aim_needs_no_rotation: commit-then-aim reach cone (Aim-B2) ──────────────
# The carrier commits to the charge WITHOUT a body turn when the aim already
# sits inside the blade reach cone (minus the commit safety margin) of the
# current facing. Default cone 157° − 25° margin = 132° immediate-commit half-
# angle. Pure geometry, unit-tested here (the full pre-aim transition is driven
# from a live snapshot elsewhere).

func _aim_dir(deg: float) -> Vector2:
	# Direction `deg` off +Z (the facing axis used below), XZ as (x, z).
	var r: float = deg_to_rad(deg)
	return Vector2(sin(r), cos(r))


func test_forward_aim_needs_no_rotation() -> void:
	assert_true(sm._aim_needs_no_rotation(Vector2(0, 1), _aim_dir(0.0)),
			"an aim dead ahead never needs a body turn")


func test_lateral_in_cone_aim_needs_no_rotation() -> void:
	# A 100° off-wing / lateral pass is inside the 132° commit cone — the blade
	# reaches it with the body frozen, so no pre-aim rotation.
	assert_true(sm._aim_needs_no_rotation(Vector2(0, 1), _aim_dir(100.0)),
			"a 100° lateral aim is reachable without turning the body")
	assert_true(sm._aim_needs_no_rotation(Vector2(0, 1), _aim_dir(-100.0)),
			"symmetric on the other side")


func test_back_wedge_aim_needs_rotation() -> void:
	# 150° is past the 132° commit cone (in the back wedge) — the body must
	# rotate until the aim swings into the cone.
	assert_false(sm._aim_needs_no_rotation(Vector2(0, 1), _aim_dir(150.0)),
			"a 150° back-wedge aim still needs a body turn")


func test_commit_cone_boundary() -> void:
	# Just inside 132° commits without a turn; just outside does not.
	assert_true(sm._aim_needs_no_rotation(Vector2(0, 1), _aim_dir(130.0)))
	assert_false(sm._aim_needs_no_rotation(Vector2(0, 1), _aim_dir(134.0)))


func test_commit_cone_tracks_the_bots_real_reach() -> void:
	# A lower-reach build (smaller cone) shrinks the immediate-commit window, so
	# an aim that a full-reach bot commits to may need a turn for the smaller one.
	var caps := AISkaterCaps.new()
	caps.reach_cone_half_angle = deg_to_rad(120.0)   # commit cone → 95°
	sm.apply_capabilities(caps)
	assert_true(sm._aim_needs_no_rotation(Vector2(0, 1), _aim_dir(90.0)),
			"90° still inside the reduced 95° commit cone")
	assert_false(sm._aim_needs_no_rotation(Vector2(0, 1), _aim_dir(110.0)),
			"110° now past the reduced cone — needs a turn")


func test_degenerate_facing_or_aim_needs_rotation() -> void:
	assert_false(sm._aim_needs_no_rotation(Vector2.ZERO, _aim_dir(0.0)),
			"no facing → fall back to the safe (rotate) path")
	assert_false(sm._aim_needs_no_rotation(Vector2(0, 1), Vector2.ZERO),
			"no aim direction → fall back to the safe path")


# ── Poke-evade deke trigger: relative closing (angled/stationary defender) ──────

func test_poke_evade_fires_driving_at_a_stationary_defender() -> void:
	# The deke's closing gate is RELATIVE: a carrier skating into a waiting / angled
	# defender closes the gap, so the deke fires. The old defender-only closing left
	# the bot skating straight into a static poke without cutting around it.
	var snap := WorldSnapshot.new()
	var me := SkaterNetworkState.new()
	me.position = Vector3(0, 0, 0)
	me.velocity = Vector3(0, 0, -6)          # skating hard at the defender
	snap.skater_states[SELF_ID] = me
	var opp := SkaterNetworkState.new()
	opp.position = Vector3(0, 0, -3.5)       # ~1.5 m ahead of the puck (2 m forward)
	opp.velocity = Vector3.ZERO              # stationary — NOT closing on its own
	opp.blade_contact_world = Vector3(0, 0, -3.5)
	snap.skater_states[OPP_ID] = opp
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.carrier_peer_id = SELF_ID
	snap.puck_state.position = me.position
	sm._poke_evade_active_ticks = 0
	sm._poke_evade_cooldown_ticks = 0
	var input := InputState.new()
	sm._poke_evade_modulate_steering(input, snap, me.position)
	assert_gt(sm._poke_evade_active_ticks, 0,
			"driving at a stationary defender within poke reach triggers the deke")


func test_poke_evade_skips_a_defender_neither_side_is_closing_on() -> void:
	# Guard: if the carrier is NOT moving toward the defender (drifting away) and the
	# defender is static, nothing is closing, so no deke — the relative gate still
	# filters the genuinely-idle case.
	var snap := WorldSnapshot.new()
	var me := SkaterNetworkState.new()
	me.position = Vector3(0, 0, 0)
	me.velocity = Vector3(0, 0, 6)           # skating AWAY from the defender ahead
	snap.skater_states[SELF_ID] = me
	var opp := SkaterNetworkState.new()
	opp.position = Vector3(0, 0, -3.0)
	opp.velocity = Vector3.ZERO
	opp.blade_contact_world = Vector3(0, 0, -3.0)
	snap.skater_states[OPP_ID] = opp
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.carrier_peer_id = SELF_ID
	snap.puck_state.position = me.position
	sm._poke_evade_active_ticks = 0
	sm._poke_evade_cooldown_ticks = 0
	var input := InputState.new()
	sm._poke_evade_modulate_steering(input, snap, me.position)
	assert_eq(sm._poke_evade_active_ticks, 0,
			"a defender behind the direction of travel, neither closing, gets no deke")


# ── Reception: pass anticipation ────────────────────────────────────────────────

func _pass_snap(puck_pos: Vector3, puck_vel: Vector3, carrier: int) -> WorldSnapshot:
	var s := WorldSnapshot.new()
	s.puck_state = PuckNetworkState.new()
	s.puck_state.position = puck_pos
	s.puck_state.velocity = puck_vel
	s.puck_state.carrier_peer_id = carrier
	return s


func test_incoming_pass_to_me_fires_for_a_fast_pass_heading_at_us() -> void:
	# Loose puck at (0,0,10) ripping toward -Z at magnet pace; self at the origin is
	# on its line, ahead of it — a pass at us.
	var s := _pass_snap(Vector3(0, 0, 10), Vector3(0, 0, -21), -1)
	assert_true(sm._incoming_pass_to_me(s, Vector3.ZERO))


func test_incoming_pass_to_me_ignores_slow_carried_or_away_pucks() -> void:
	# Too slow to be a pass.
	assert_false(sm._incoming_pass_to_me(
			_pass_snap(Vector3(0, 0, 10), Vector3(0, 0, -10), -1), Vector3.ZERO),
			"a slow loose puck isn't a pass to receive")
	# Carried — not loose.
	assert_false(sm._incoming_pass_to_me(
			_pass_snap(Vector3(0, 0, 10), Vector3(0, 0, -21), OPP_ID), Vector3.ZERO),
			"a carried puck is not an incoming pass")
	# Heading AWAY (we're behind its travel).
	assert_false(sm._incoming_pass_to_me(
			_pass_snap(Vector3(0, 0, 0), Vector3(0, 0, -21), -1), Vector3(0, 0, 10)),
			"a puck travelling away from us is not incoming")
	# On the line but too far to the side.
	assert_false(sm._incoming_pass_to_me(
			_pass_snap(Vector3(0, 0, 10), Vector3(0, 0, -21), -1),
			Vector3(Agent.RECEIVE_TRIGGER_LATERAL_M + 2.0, 0, 0)),
			"a pass whose line runs well wide of us is not ours to receive")


func test_incoming_pass_to_me_defers_to_a_closer_teammate() -> void:
	# A fast puck heading down the line, but a teammate is nearer to where it crosses
	# our level — they anticipate it, not us, so a shot/pass past several bots doesn't
	# pull them all out of position.
	var s := _pass_snap(Vector3(0, 0, 10), Vector3(0, 0, -21), -1)
	_add_skater(s, SELF_ID, Vector3(3, 0, 0))          # 3 m off the line at our level
	_add_skater(s, TEAMMATE_ID, Vector3(1, 0, 0))      # closer to the line
	assert_false(sm._incoming_pass_to_me(s, Vector3(3, 0, 0)),
			"a teammate nearer the puck's crossing point is the one who receives")
	# Remove the closer teammate → now it's ours.
	s.skater_states.erase(TEAMMATE_ID)
	assert_true(sm._incoming_pass_to_me(s, Vector3(3, 0, 0)))


# ── _blade_gate_on_puck_line ─────────────────────────────────────────────────
# The gate: park the blade at the earliest point on an incoming puck's travel
# line the blade can touch, instead of chasing the puck's position (which the
# Hands-capped cursor can't keep up with — the pass transits reach untouched).

func _gate_reach() -> float:
	# Mirror of the helper's comfortable extension: pickup buffer stripped back
	# off _blade_reach, then the side-stand inset.
	return maxf(sm._blade_reach - Agent.BLADE_REACH_BUFFER_M
			- Agent.RECEIVE_BODY_INSET_M, 0.4)


func test_blade_gate_parks_on_the_line_at_the_entry_point() -> void:
	# Puck at origin travelling +X at 20; bot 1 m off the line at x=10. The gate
	# must sit ON the line (z = 0), BEFORE the perpendicular foot (x < 10) — the
	# front edge of reach, so the puck is met at the earliest touchable point —
	# and at the comfortable extension from the body.
	var self_pos := Vector3(10, 0, 1)
	var gate: Vector3 = sm._blade_gate_on_puck_line(
			self_pos, Vector3.ZERO, Vector3(20, 0, 0))
	assert_almost_eq(gate.z, 0.0, 0.001, "gate sits on the puck's travel line")
	assert_lt(gate.x, 10.0, "gate sits ahead of the perpendicular foot (early contact)")
	assert_almost_eq(self_pos.distance_to(gate), _gate_reach(), 0.001,
			"gate sits at the blade's comfortable extension")


func test_blade_gate_head_on_parks_in_front() -> void:
	# Bot standing exactly on the line: the gate is a full comfortable reach IN
	# FRONT of the body, toward the incoming puck — blade out to meet it.
	var gate: Vector3 = sm._blade_gate_on_puck_line(
			Vector3(10, 0, 0), Vector3.ZERO, Vector3(20, 0, 0))
	assert_almost_eq(gate.z, 0.0, 0.001)
	assert_almost_eq(gate.x, 10.0 - _gate_reach(), 0.001,
			"head-on gate is one comfortable reach toward the puck")


func test_blade_gate_reaches_toward_the_line_when_still_closing() -> void:
	# Line runs 3 m to the side — outside reach. Best effort: the perpendicular
	# foot (nearest point of the line), held while the body closes.
	var gate: Vector3 = sm._blade_gate_on_puck_line(
			Vector3(10, 0, 3), Vector3.ZERO, Vector3(20, 0, 0))
	assert_almost_eq(gate.x, 10.0, 0.001)
	assert_almost_eq(gate.z, 0.0, 0.001,
			"out-of-reach line → aim at its nearest point while closing")


func test_blade_gate_chases_a_puck_already_past() -> void:
	# Puck at x=15 moving +X; bot at x=10 is BEHIND its travel — no gate exists
	# ahead, so fall back to the puck itself (chase from behind).
	var puck_pos := Vector3(15, 0, 0)
	var gate: Vector3 = sm._blade_gate_on_puck_line(
			Vector3(10, 0, 1), puck_pos, Vector3(20, 0, 0))
	assert_eq(gate, puck_pos, "a puck already past our level is chased, not gated")


func test_blade_gate_stationary_puck_is_the_puck() -> void:
	var puck_pos := Vector3(5, 0, 5)
	var gate: Vector3 = sm._blade_gate_on_puck_line(
			Vector3(10, 0, 1), puck_pos, Vector3.ZERO)
	assert_eq(gate, puck_pos, "no travel line without velocity — aim at the puck")


# ── Receive in stride vs settle ──────────────────────────────────────────────
# The side-stand reception only settles (arrival brake) when arriving AND
# stopping both fit before the puck; a tight window takes the feed in stride.

func _receive_snap(puck_pos: Vector3, puck_vel: Vector3,
		self_pos: Vector3, self_vel: Vector3) -> WorldSnapshot:
	var s := _loose_puck_snap(puck_pos)
	s.puck_state.velocity = puck_vel
	_add_skater(s, SELF_ID, self_pos)
	s.skater_states[SELF_ID].velocity = self_vel
	return s


func test_receive_takes_the_feed_in_stride_when_roughly_synced() -> void:
	# Puck closing at 20 with the crossing ~0.7 s out; bot 4 m off the line at
	# 6 m/s arrives inside its own blade window of the puck — running through
	# the reception keeps the blade on the line when the puck gets there, so no
	# brake: full speed through the catch (stride is the DEFAULT now).
	var s := _receive_snap(Vector3.ZERO, Vector3(20, 0, 0),
			Vector3(14, 0, 4), Vector3(0, 0, -6))
	var input := InputState.new()
	assert_true(sm._pass_receive_aim_and_steer(input, s, Vector3(14, 0, 4)),
			"scenario commits the reception")
	assert_false(input.brake, "synced arrival → take it in stride, no arrival brake")


func test_receive_settles_only_when_genuinely_early() -> void:
	# Bot already sitting ON the anchor at 4 m/s with the puck still a full
	# second away — far outside the blade window its motion covers, so waiting
	# is forced and it brakes to hold the gate.
	var self_pos := Vector3(14, 0, 1.4)
	var s := _receive_snap(Vector3(-6, 0, 0), Vector3(20, 0, 0),
			self_pos, Vector3(0, 0, -4))
	var input := InputState.new()
	assert_true(sm._pass_receive_aim_and_steer(input, s, self_pos),
			"scenario commits the reception")
	assert_true(input.brake, "genuinely early → brake and hold the gate")


# ── Pass lead origin = the carried puck ──────────────────────────────────────

func test_pass_aim_leads_from_the_puck_not_the_body() -> void:
	# Receiver cutting PERPENDICULAR to the pass line (so the intercept solve
	# doesn't saturate the lead cap). The lead scales with flight time, and the
	# flight starts at the PUCK — a puck carried out ahead of the body shortens
	# the flight, so the led aim trails the body-origin lead by a real margin.
	var receiver_pos := Vector3(8, 0, 0)
	var receiver_vel := Vector3(0, 0, 4)

	var make := func(puck_pos: Vector3) -> WorldSnapshot:
		var s := WorldSnapshot.new()
		s.puck_state = PuckNetworkState.new()
		s.puck_state.carrier_peer_id = SELF_ID
		s.puck_state.position = puck_pos
		_add_skater(s, SELF_ID, Vector3.ZERO)
		_add_skater(s, TEAMMATE_ID, receiver_pos)
		s.skater_states[TEAMMATE_ID].velocity = receiver_vel
		return s

	sm._pass_target_peer_id = TEAMMATE_ID
	sm._pass_target_speed = 20.0
	var aim_body: Vector3 = sm._pass_aim_point(
			make.call(Vector3.ZERO), Vector3.ZERO)
	var aim_blade: Vector3 = sm._pass_aim_point(
			make.call(Vector3(3, 0, 0)), Vector3.ZERO)
	assert_lt(aim_blade.z, aim_body.z - 0.3,
			"a puck 3 m out front shortens the flight and the lead follows")


# ── Contest read + live-bot execution error ─────────────────────────────────

func test_opponent_within_of_reads_contest_range() -> void:
	var s := _loose_puck_snap(Vector3(5, 0, 0))
	_add_skater(s, SELF_ID, Vector3(3, 0, 0))
	_add_skater(s, OPP_ID, Vector3(6.5, 0, 0))   # 1.5 m from the puck
	assert_true(sm._opponent_within_of(s, Vector3(5, 0, 0), Agent.ENGAGEMENT_PROXIMITY_M),
			"an opponent inside blade-on-puck range is a live contest")
	s.skater_states[OPP_ID].position = Vector3(9, 0, 0)   # 4 m away
	assert_false(sm._opponent_within_of(s, Vector3(5, 0, 0), Agent.ENGAGEMENT_PROXIMITY_M),
			"an opponent out of reach is not a contest")
	# Teammates never make a contest.
	s.skater_states.erase(OPP_ID)
	_add_skater(s, TEAMMATE_ID, Vector3(5.5, 0, 0))
	assert_false(sm._opponent_within_of(s, Vector3(5, 0, 0), Agent.ENGAGEMENT_PROXIMITY_M),
			"a teammate near the puck is not an opposing contest")


func test_aim_error_off_raw_on_after_profile() -> void:
	# A bare state machine is bit-deterministic (tests, replay tooling); a LIVE
	# bot wired through apply_profile gets the per-tier execution error pair
	# plus the timing/sway humanisers.
	assert_almost_eq(sm._shot_aim_error_m, 0.0, 1e-9,
			"raw agents stay error-free on shots")
	assert_almost_eq(sm._pass_aim_error_m, 0.0, 1e-9,
			"raw agents stay error-free on passes")
	assert_almost_eq(sm._shot_timing_error_s, 0.0, 1e-9,
			"raw agents release tick-perfect")
	assert_almost_eq(sm._carry_sway_m, 0.0, 1e-9,
			"raw agents carry rail-steady")
	sm.apply_profile(BotSkillProfile.hard())
	assert_almost_eq(sm._shot_aim_error_m, BotSkillProfile.hard().shot_aim_error_m, 1e-9,
			"profiled (live) agents carry the shot aim error")
	assert_almost_eq(sm._pass_aim_error_m, BotSkillProfile.hard().pass_aim_error_m, 1e-9,
			"profiled (live) agents carry the pass aim error")
	assert_almost_eq(sm._shot_timing_error_s, BotSkillProfile.hard().shot_timing_error_s, 1e-9,
			"profiled (live) agents carry the release timing variance")
	assert_almost_eq(sm._carry_sway_m, BotSkillProfile.hard().carry_sway_m, 1e-9,
			"profiled (live) agents carry the natural sway amplitude")


func test_press_entry_samples_release_error_per_budget() -> void:
	# Each press entry draws ONE aim error for the whole release: shots and
	# one-timers on the (larger) shot budget, passes on the pass budget. The
	# sample is uniform ± budget over the 2 m aim arm — bound it, and check a
	# fresh entry re-samples rather than reusing the previous release's error.
	sm.apply_profile(BotSkillProfile.easy())
	var shot_bound: float = BotSkillProfile.easy().shot_aim_error_m \
			/ Agent.CARRY_BLADE_AIM_FORWARD_M
	var pass_bound: float = BotSkillProfile.easy().pass_aim_error_m \
			/ Agent.CARRY_BLADE_AIM_FORWARD_M
	var samples: Array[float] = []
	for i: int in 16:
		sm._set_state(Agent.State.SHOOT_PRESSED)
		assert_lte(absf(sm._committed_aim_error_rad), shot_bound,
				"shot error stays inside the shot budget")
		samples.append(sm._committed_aim_error_rad)
		sm._set_state(Agent.State.CARRY)
	var all_equal: bool = true
	for v: float in samples:
		if absf(v - samples[0]) > 1e-12:
			all_equal = false
	assert_false(all_equal, "each release draws a fresh error sample")
	sm._set_state(Agent.State.PASS_PRESSED)
	assert_lte(absf(sm._committed_aim_error_rad), pass_bound,
			"pass error stays inside the (smaller) pass budget")
	sm._set_state(Agent.State.CARRY)
	sm._set_state(Agent.State.ONE_TIMER_PRESSED)
	assert_lte(absf(sm._committed_aim_error_rad), shot_bound,
			"a one-timer samples on the shot budget")
	sm._set_state(Agent.State.OFF_PUCK)


func test_shot_entry_samples_release_hold_inside_timing_budget() -> void:
	# The late-release hold is bounded by the tier's timing variance, and a
	# raw (zero-variance) agent always releases on the intended tick.
	assert_eq(sm._sample_release_hold_ticks(), 0,
			"raw agents never hold the release")
	sm.apply_profile(BotSkillProfile.normal())
	var max_ticks: int = int(round(
			BotSkillProfile.normal().shot_timing_error_s / Agent.MOUSE_TICK_DELTA))
	for i: int in 16:
		sm._set_state(Agent.State.SHOOT_PRESSED)
		assert_between(sm._shoot_release_hold_ticks, 0, max_ticks,
				"sampled hold stays inside the timing budget")
		sm._set_state(Agent.State.CARRY)
	sm._set_state(Agent.State.OFF_PUCK)


# ── Cognition gates (difficulty-tiered hockey IQ) ────────────────────────────

func test_apply_profile_sets_cognition_gates() -> void:
	# Raw agents keep the perfect-bot defaults (all reads on).
	assert_true(sm._reads_goalie_motion, "raw agent reads goalie motion")
	assert_true(sm._holds_for_developing_feeds, "raw agent holds for developing plays")
	assert_true(sm._angles_the_chase, "raw agent angles its chase")
	sm.apply_profile(BotSkillProfile.easy())
	assert_false(sm._reads_goalie_motion, "Easy is goalie-motion blind")
	assert_false(sm._holds_for_developing_feeds, "Easy plays only what exists now")
	assert_false(sm._angles_the_chase, "Easy chases straight-line")
	sm.apply_profile(BotSkillProfile.normal())
	assert_true(sm._reads_goalie_motion,
			"Normal keeps the goalie-motion read — Hard/Normal differ by tuning only")
	assert_true(sm._holds_for_developing_feeds, "Normal keeps the developing-feed hold")
	assert_true(sm._angles_the_chase, "Normal keeps the chase angling")


func test_motion_blind_aim_ignores_the_goalie_slide() -> void:
	# Goalie on the shooter's arc but sliding hard +x: a motion-reading bot
	# projects the shadow along the slide and aims into the recovery arc
	# ("across the grain"); a motion-blind bot's aim is EXACTLY the aim
	# against the same goalie standing still — it shoots at where he IS.
	var s := WorldSnapshot.new()
	var gs := GoalieNetworkState.new()
	gs.position_x = 0.0
	gs.position_z = -GameRules.GOAL_LINE_Z + 1.2   # out on the challenge arc
	gs.velocity_x = 4.0                            # committed slide
	s.goalie_states[1] = gs                        # opp team (self is team 0)
	var self_pos := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z + 10.0)

	var aim_reading: Vector3 = sm._shot_aim_point(s, self_pos)
	sm._reads_goalie_motion = false
	var aim_blind: Vector3 = sm._shot_aim_point(s, self_pos)
	sm._reads_goalie_motion = true
	gs.velocity_x = 0.0
	var aim_still: Vector3 = sm._shot_aim_point(s, self_pos)

	assert_almost_eq(aim_blind.x, aim_still.x, 1e-6,
			"blind aim equals the still-goalie aim — where he IS, not where he'll be")
	assert_gt(absf(aim_reading.x - aim_blind.x), 0.05,
			"the motion read genuinely moves the aim into the recovery arc")


# ── Protect-side turn (carry arc direction) ──────────────────────────────────
# A carrier's turn-around picks which way the puck sweeps: shortest by default,
# the long way when the short sweep drags the puck through a defender's poke
# reach and the far side is clear. See PROTECT_TURN_* on the state machine.

func _protect_snap(self_pos: Vector3, opp_pos: Vector3) -> WorldSnapshot:
	var s := _loose_puck_snap(self_pos)
	s.puck_state.carrier_peer_id = SELF_ID
	_add_skater(s, SELF_ID, self_pos)
	_add_skater(s, OPP_ID, opp_pos)
	return s


func test_protect_turn_shortest_in_open_ice() -> void:
	var s := _protect_snap(Vector3.ZERO, Vector3(0, 0, -30))   # opponent far away
	# Facing +z (angle 0), target ~172° around via the +x side.
	assert_eq(sm._protect_turn_direction(Vector3.ZERO, 0.0, 3.0, s), 1.0,
			"open ice → the shortest way around")


func test_protect_turn_flips_away_from_short_side_defender() -> void:
	# Defender's blade sits right where the short (+x) sweep would carry the
	# puck; the long (−x) side is empty → sweep the long way.
	var s := _protect_snap(Vector3.ZERO, Vector3(2.0, 0, 0.2))
	assert_eq(sm._protect_turn_direction(Vector3.ZERO, 0.0, 3.0, s), -1.0,
			"short sweep through a poke threat → turn the long way, puck shielded")


func test_protect_turn_stays_short_when_both_sides_threatened() -> void:
	var s := _protect_snap(Vector3.ZERO, Vector3(2.0, 0, 0.2))
	_add_skater(s, 12, Vector3(-2.0, 0, 0.2))   # second defender mirrors the first
	assert_eq(sm._protect_turn_direction(Vector3.ZERO, 0.0, 3.0, s), 1.0,
			"nowhere safer to sweep → don't pay the long rotation for nothing")


func test_arc_step_commits_to_the_protected_direction() -> void:
	# Integration through _arc_step_mouse_target: with a defender on the short
	# side, successive arc steps walk the mouse the LONG way and stay committed.
	var self_pos := Vector3.ZERO
	var s := _protect_snap(self_pos, Vector3(2.0, 0, 0.2))
	sm._state = Agent.State.CARRY
	sm._current_snapshot = s
	sm._mouse_pos = Vector3(0, 0, 2.0)   # parked dead ahead (angle 0)
	sm._mouse_pos_initialized = true
	var target := self_pos + Vector3(sin(3.0), 0, cos(3.0)) * 5.0
	var stepped: Vector3 = sm._arc_step_mouse_target(
			self_pos, target, s.skater_states[SELF_ID], 5.0)
	var ang: float = atan2(stepped.x - self_pos.x, stepped.z - self_pos.z)
	assert_lt(ang, 0.0, "first step sweeps the long (−) way, away from the defender")
	assert_eq(sm._arc_protect_sign, -1.0, "…and the direction is latched")
	sm._mouse_pos = stepped
	var stepped2: Vector3 = sm._arc_step_mouse_target(
			self_pos, target, s.skater_states[SELF_ID], 5.0)
	var ang2: float = atan2(stepped2.x - self_pos.x, stepped2.z - self_pos.z)
	assert_lt(ang2, ang, "the commitment holds on the next step — no mid-sweep flip")


func test_arc_step_shortest_way_in_open_ice() -> void:
	var self_pos := Vector3.ZERO
	var s := _protect_snap(self_pos, Vector3(0, 0, -30))
	sm._state = Agent.State.CARRY
	sm._current_snapshot = s
	sm._mouse_pos = Vector3(0, 0, 2.0)
	sm._mouse_pos_initialized = true
	var target := self_pos + Vector3(sin(3.0), 0, cos(3.0)) * 5.0
	var stepped: Vector3 = sm._arc_step_mouse_target(
			self_pos, target, s.skater_states[SELF_ID], 5.0)
	var ang: float = atan2(stepped.x - self_pos.x, stepped.z - self_pos.z)
	assert_gt(ang, 0.0, "open ice keeps the shortest sweep")
	assert_eq(sm._arc_protect_sign, 0.0, "no long-way commitment latched")


# ── Aim slew arc rate projects onto the blade's real orbit radius ────────────

func test_aim_slew_arc_rate_uses_blade_orbit_radius() -> void:
	sm._apply_aim_slew(10.0, 1.6)
	assert_almost_eq(sm._mouse_arc_rate_rad_s, 6.25, 1e-6,
			"arc rate = blade speed / blade orbit span")
	# The IK-gate ceiling still caps a fast-hands build.
	sm._apply_aim_slew(40.0, 1.6)
	assert_almost_eq(sm._mouse_arc_rate_rad_s, Agent.MOUSE_ARC_RATE_RAD_S, 1e-6,
			"arc rate never exceeds the IK-gate ceiling")
