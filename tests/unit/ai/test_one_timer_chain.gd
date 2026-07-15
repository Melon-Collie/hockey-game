extends GutTest

# The one-timer chain, end to end, on a canonical settled OZONE cycle:
# FINISHER readiness at its argmax spot → the carrier valuing the feed →
# zone-entry trigger → ONE_TIMER_PRESSED holding through the pickup → release.
#
# Regression guard for the "bots never go for one-timers" bug cluster: the
# carrier-reaction debounce window right after a pass release (puck reads
# held-but-fast) used to (a) flip the FINISHER's role decision into reactive
# tip mode, (b) fail the ready-preserve's loose-puck gate — tearing down
# readiness on every feed — and (c) block _puck_in_one_timer_zone outright,
# so the camped one-timer never fired at any difficulty tier.

const Agent := preload("res://Scripts/ai/skater_agent_state_machine.gd")

# Team 0 attacks -Z (attacking goal at z = -26.65).
const FINISHER_ID := 1
const CARRIER_ID := 2
const OPP_MARK := 11
const OPP_PRESSURE := 12
var _team_map := {1: 0, 2: 0, 11: 1, 12: 1}

var _brain: TeamBrain


func before_each() -> void:
	_brain = TeamBrain.new(0, _team_map)


func _add_skater(s: WorldSnapshot, pid: int, pos: Vector3,
		vel: Vector3 = Vector3.ZERO, facing: Vector2 = Vector2(0, -1)) -> void:
	var st := SkaterNetworkState.new()
	st.position = pos
	st.velocity = vel
	st.facing = facing
	s.skater_states[pid] = st


func _add_goalie(s: WorldSnapshot, team_id: int, pos: Vector3) -> void:
	var g := GoalieNetworkState.new()
	g.position_x = pos.x
	g.position_z = pos.z
	s.goalie_states[team_id] = g


# Settled OZONE cycle: carrier (peer 2) on the right half-wall, FINISHER
# (peer 1) camped weak-side, the MARK defender caught low at the net-front
# (the cross-seam window), PRESSURE on the carrier.
func _cycle_snap(finisher_pos: Vector3) -> WorldSnapshot:
	var s := WorldSnapshot.new()
	_add_skater(s, FINISHER_ID, finisher_pos)
	_add_skater(s, CARRIER_ID, Vector3(8.0, 0.0, -18.0))
	_add_skater(s, OPP_MARK, Vector3(-1.0, 0.0, -25.0))
	_add_skater(s, OPP_PRESSURE, Vector3(7.0, 0.0, -16.5))
	_add_goalie(s, 1, Vector3(0.8, 0.0, -25.3))  # squared toward the carrier side
	s.puck_state = PuckNetworkState.new()
	s.puck_state.position = Vector3(8.0, 0.0, -18.0)
	s.puck_state.carrier_peer_id = CARRIER_ID
	s.real_puck_carrier_peer_id = CARRIER_ID
	return s


func test_finisher_flags_ready_at_its_own_argmax_spot() -> void:
	var sm: SkaterAgentStateMachine = Agent.new()
	sm.setup(FINISHER_ID, 0, _brain, _team_map, false)
	var probe := Vector3(-4.0, 0.0, -21.65)
	var s: WorldSnapshot = _cycle_snap(probe)
	_brain.tick(1.0, s)
	var ctx: RoleContext = sm._build_role_context(s, probe, s.skater_states[FINISHER_ID])
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	# Re-run with the bot standing exactly at the argmax — readiness must latch.
	var s2: WorldSnapshot = _cycle_snap(d.target_position)
	var ctx2: RoleContext = sm._build_role_context(
			s2, d.target_position, s2.skater_states[FINISHER_ID])
	var d2: RoleDecision = AIRoleFinisher.decide(ctx2)
	assert_true(d2.is_one_timer_ready, "camped at the argmax spot → one-timer ready")


func test_carrier_feeds_the_camped_one_timer_man() -> void:
	# With the cross-seam lane open, the carrier's best action is the feed to
	# the ready FINISHER at its staging spot — not holding a dead carry.
	var finisher_pos := Vector3(-4.0, 0.0, -21.65)
	var s: WorldSnapshot = _cycle_snap(finisher_pos)
	_brain.tick(1.0, s)
	_brain.set_one_timer_ready(FINISHER_ID, true)
	var sm: SkaterAgentStateMachine = Agent.new()
	sm.setup(CARRIER_ID, 0, _brain, _team_map, false)
	# Park the FINISHER on its own argmax spot (live steering takes it there).
	var sm_f: SkaterAgentStateMachine = Agent.new()
	sm_f.setup(FINISHER_ID, 0, _brain, _team_map, false)
	var fctx: RoleContext = sm_f._build_role_context(
			s, finisher_pos, s.skater_states[FINISHER_ID])
	var fd: RoleDecision = AIRoleFinisher.decide(fctx)
	s.skater_states[FINISHER_ID].position = fd.target_position
	var carrier_pos: Vector3 = s.skater_states[CARRIER_ID].position
	var ctx: RoleContext = sm._build_role_context(
			s, carrier_pos, s.skater_states[CARRIER_ID])
	var carrier := AIRoleCarrier.new()
	carrier.decide(ctx)
	assert_eq(carrier.intended_action, AIRoleCarrier.INTENT_PASS,
			"the open cross-seam feed to the ready man wins the compete")
	assert_eq(carrier.pass_target_peer_id, FINISHER_ID)


func test_zone_trigger_reads_the_real_carrier_through_the_debounce() -> void:
	# Pass in flight 1.5 m from the camped FINISHER while the DEBOUNCED carrier
	# signal still names the old carrier — the pre-armed trigger must see the
	# real (loose) puck. A genuinely held puck still gates it off.
	var finisher_pos := Vector3(-4.0, 0.0, -21.65)
	var s: WorldSnapshot = _cycle_snap(finisher_pos)
	s.puck_state.position = Vector3(-2.6, 0.0, -20.9)
	s.puck_state.velocity = Vector3(-18.0, 0.0, -6.0)
	s.real_puck_carrier_peer_id = -1           # really loose (pass in flight)
	s.puck_state.carrier_peer_id = CARRIER_ID  # bot hasn't "noticed" yet
	var sm: SkaterAgentStateMachine = Agent.new()
	sm.setup(FINISHER_ID, 0, _brain, _team_map, false)
	assert_true(sm._puck_in_one_timer_zone(s, finisher_pos),
			"debounce window must not hide the feed from the pre-armed trigger")
	s.real_puck_carrier_peer_id = CARRIER_ID
	assert_false(sm._puck_in_one_timer_zone(s, finisher_pos),
			"a genuinely held puck is never one-timed")


# Full OFF_PUCK → ONE_TIMER_PRESSED → release integration over a synthetic
# pass flight. `debounce_ticks` simulates GameManager's carrier reaction
# delay (puck_state.carrier_peer_id stays on the old carrier that long after
# the real release). Returns [pressed, released, power_t_at_release].
func _run_feed_sim(debounce_ticks: int, pass_speed: float) -> Array:
	var finisher_pos := Vector3(-4.0, 0.0, -21.65)
	var s: WorldSnapshot = _cycle_snap(finisher_pos)
	_brain.tick(1.0, s)
	var sm: SkaterAgentStateMachine = Agent.new()
	sm.setup(FINISHER_ID, 0, _brain, _team_map, false)
	# Park the FINISHER on its own argmax spot so readiness latches, exactly
	# as live steering would.
	var probe_ctx: RoleContext = sm._build_role_context(
			s, finisher_pos, s.skater_states[FINISHER_ID])
	var probe: RoleDecision = AIRoleFinisher.decide(probe_ctx)
	finisher_pos = probe.target_position
	s.skater_states[FINISHER_ID].position = finisher_pos
	var input := InputState.new()
	for i: int in 12:
		sm.dispatch(input, s)  # camped ticks — readiness publishes
	# Pass released toward the FINISHER's blade.
	var origin := Vector3(8.0, 0.0, -18.0)
	var dir: Vector3 = (finisher_pos - origin).normalized()
	var pressed: bool = false
	var released: bool = false
	var release_power: float = -1.0
	for tick: int in 120:
		var t: float = float(tick) / 120.0
		var puck_pos: Vector3 = origin + dir * pass_speed * t
		s.puck_state.position = puck_pos
		s.puck_state.velocity = dir * pass_speed
		s.real_puck_carrier_peer_id = -1
		s.puck_state.carrier_peer_id = CARRIER_ID if tick < debounce_ticks else -1
		if puck_pos.distance_to(finisher_pos) < 0.35:
			# Contact: reception attaches the puck to the blade.
			s.real_puck_carrier_peer_id = FINISHER_ID
			s.puck_state.velocity = Vector3.ZERO
		sm.dispatch(input, s)
		if sm.get_state() == Agent.State.ONE_TIMER_PRESSED:
			pressed = true
		elif pressed and not input.shoot_held:
			released = true
			release_power = input.bot_wrister_power_t
			break
	return [pressed, released, release_power]


func test_feed_fires_the_one_timer_at_every_debounce_tier() -> void:
	# 6 / 26 / 41 ticks ≈ the Hard / Normal / Easy carrier reaction delays.
	for debounce: int in [6, 26, 41]:
		var result: Array = _run_feed_sim(debounce, 20.3)
		assert_true(result[0], "one-timer press latches (debounce %d)" % debounce)
		assert_true(result[1], "…and releases on contact (debounce %d)" % debounce)
		assert_almost_eq(result[2], 1.0, 0.001,
				"…at the committed full one-timer pace, not a stale leak")


func test_no_one_timer_in_the_defensive_zone() -> void:
	# The reported "shouldn't be possible" bug: readiness preserved across a
	# turnover must NOT survive the bot leaving the attacking zone. Camp the
	# finisher until ready publishes, then relocate it to its OWN end with a
	# loose feed crossing — the zone guard drops readiness, no wind-up fires.
	var finisher_pos := Vector3(-4.0, 0.0, -21.65)
	var s: WorldSnapshot = _cycle_snap(finisher_pos)
	_brain.tick(1.0, s)
	var sm: SkaterAgentStateMachine = Agent.new()
	sm.setup(FINISHER_ID, 0, _brain, _team_map, false)
	var probe_ctx: RoleContext = sm._build_role_context(
			s, finisher_pos, s.skater_states[FINISHER_ID])
	var probe: RoleDecision = AIRoleFinisher.decide(probe_ctx)
	finisher_pos = probe.target_position
	s.skater_states[FINISHER_ID].position = finisher_pos
	var input := InputState.new()
	for i: int in 12:
		sm.dispatch(input, s)
	assert_true(_brain.is_one_timer_ready(FINISHER_ID),
			"camped finisher is one-timer ready in the attacking zone")
	# Relocate to team 0's own defensive zone (defends +Z) with a loose feed.
	s.skater_states[FINISHER_ID].position = Vector3(-4.0, 0.0, 21.65)
	s.puck_state.position = Vector3(-2.6, 0.0, 20.9)
	s.puck_state.velocity = Vector3(-18.0, 0.0, -6.0)
	s.puck_state.carrier_peer_id = -1
	s.real_puck_carrier_peer_id = -1
	sm.dispatch(input, s)
	assert_ne(sm.get_state(), Agent.State.ONE_TIMER_PRESSED,
			"a bot in its own defensive zone never winds up a one-timer")
	assert_false(_brain.is_one_timer_ready(FINISHER_ID),
			"readiness drops the moment the bot is out of the attacking zone")


func test_cross_seam_not_one_timed_when_not_squared_up() -> void:
	# The wonky-aim guard: a chasing bot still facing up-ice can't rotate square
	# to the net inside the reception window, so the redirect would lock a
	# "wherever I was looking" direction. It must CATCH (Mode B) instead of
	# converting to a bad one-timer. Same feed as the Mode A test below, but
	# facing away from the net.
	var finisher_pos := Vector3(-4.0, 0.0, -21.65)
	var s: WorldSnapshot = _cycle_snap(finisher_pos)
	s.skater_states[OPP_MARK].position = Vector3(-2.5, 0.0, -20.5)
	s.puck_state.position = Vector3(4.0, 0.0, -19.5)
	s.puck_state.velocity = Vector3(-19.0, 0.0, -4.0)
	s.puck_state.carrier_peer_id = -1
	s.real_puck_carrier_peer_id = -1
	# Facing back up-ice, away from the attacking net (beyond the square-up cone).
	s.skater_states[FINISHER_ID].facing = Vector2(0.0, 1.0)
	var sm: SkaterAgentStateMachine = Agent.new()
	sm.setup(FINISHER_ID, 0, _brain, _team_map, false)
	sm._state = Agent.State.CHASE_PUCK
	var input := InputState.new()
	sm.dispatch(input, s)
	assert_ne(sm.get_state(), Agent.State.ONE_TIMER_PRESSED,
			"a bot not squared to the net catches the feed instead of firing wonky")


func test_one_timer_aborts_when_it_cannot_square_to_the_net() -> void:
	# The "worried about missing the net" guard: a wind-up that can't square to
	# the net (net aim beyond the reach cone) must NOT fire wide — past the
	# aim-wait backstop it bails to catch instead. Camp the finisher on a live
	# feed but facing back up-ice so the net stays in the back wedge.
	var finisher_pos := Vector3(-4.0, 0.0, -21.65)
	var s: WorldSnapshot = _cycle_snap(finisher_pos)
	s.puck_state.position = Vector3(2.0, 0.0, -20.0)
	s.puck_state.velocity = Vector3(-18.0, 0.0, -6.0)
	s.puck_state.carrier_peer_id = -1
	s.real_puck_carrier_peer_id = -1
	s.skater_states[FINISHER_ID].facing = Vector2(0.0, 1.0)  # net dead behind
	var sm: SkaterAgentStateMachine = Agent.new()
	sm.setup(FINISHER_ID, 0, _brain, _team_map, false)
	sm._state = Agent.State.ONE_TIMER_PRESSED
	sm._one_timer_press_tick = Agent.ONE_TIMER_AIM_WAIT_MAX_TICKS
	var input := InputState.new()
	sm.dispatch(input, s)
	assert_false(input.slap_pressed, "an unsquarable one-timer is not fired wide")
	assert_ne(sm.get_state(), Agent.State.ONE_TIMER_PRESSED,
			"it aborts the wind-up and drops to catch the feed")


func test_cross_seam_reception_one_times_off_the_displaced_goalie() -> void:
	# Mode A (shot-aware reception): a lateral feed across the slot with the
	# goalie still parked on the passer's side — the chasing bot commits to
	# the one-time redirect instead of turning to catch.
	var finisher_pos := Vector3(-4.0, 0.0, -21.65)
	var s: WorldSnapshot = _cycle_snap(finisher_pos)
	s.skater_states[OPP_MARK].position = Vector3(-2.5, 0.0, -20.5)
	s.puck_state.position = Vector3(4.0, 0.0, -19.5)
	s.puck_state.velocity = Vector3(-19.0, 0.0, -4.0)
	s.puck_state.carrier_peer_id = -1
	s.real_puck_carrier_peer_id = -1
	var sm: SkaterAgentStateMachine = Agent.new()
	sm.setup(FINISHER_ID, 0, _brain, _team_map, false)
	sm._state = Agent.State.CHASE_PUCK
	var input := InputState.new()
	sm.dispatch(input, s)
	assert_eq(sm.get_state(), Agent.State.ONE_TIMER_PRESSED,
			"the cross-seam feed converts to a one-time redirect")
