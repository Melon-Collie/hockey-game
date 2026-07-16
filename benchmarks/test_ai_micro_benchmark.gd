extends GutTest

# ── Evaluator micro-benchmark (report-only; NOT in the default suite) ────────
# Times each role behavior's decide() and the hot scoring primitives on one
# frozen, realistic 5v5 scene, so evaluator costs rank against each other.
# Complements the scenario benchmark (test_ai_perf_benchmark.gd): that one
# says how much AI costs; this one says WHERE a decide's budget goes.
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks
#
# Numbers are per-call µs on this machine — compare relatively, and against
# the cadence each evaluator actually runs at (role decides ~30 Hz/bot,
# carrier compete ~30 Hz, primitives many times per decide).

const REPS: int = 400

const OUR_NET_Z: float = 26.65
const TEAM_ID: int = 0

var _results: Array[Dictionary] = []


# One frozen 5v5 scene: opp carrier cycling our strong corner, full lineups.
# Peer 1 = the bot under test (team 0); 100-series = opponents.
func _make_ctx(self_pos: Vector3, carrier_pid: int = 100) -> RoleContext:
	var snap := WorldSnapshot.new()
	var placements: Array = [
		[1, 0, self_pos],
		[2, 0, Vector3(-6.0, 0.0, 15.0)],
		[3, 0, Vector3(6.0, 0.0, 15.0)],
		[4, 0, Vector3(-3.0, 0.0, 22.0)],
		[5, 0, Vector3(3.0, 0.0, 22.0)],
		[100, 1, Vector3(9.0, 0.0, 23.0)],
		[101, 1, Vector3(-2.0, 0.0, 24.0)],
		[102, 1, Vector3(0.0, 0.0, 18.0)],
		[103, 1, Vector3(-7.0, 0.0, 14.0)],
		[104, 1, Vector3(7.0, 0.0, 12.0)],
	]
	var team_map: Dictionary = {}
	for entry: Array in placements:
		var s := SkaterNetworkState.new()
		s.position = entry[2]
		s.velocity = Vector3(0.5, 0.0, -0.5)  # mild drift so leads/ETAs compute
		snap.skater_states[entry[0]] = s
		team_map[entry[0]] = entry[1]
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	if snap.skater_states.has(carrier_pid):
		puck.position = snap.skater_states[carrier_pid].position
	snap.puck_state = puck
	snap.real_puck_carrier_peer_id = carrier_pid
	for tid: int in [0, 1]:
		var g := GoalieNetworkState.new()
		g.position_x = 0.0
		g.position_z = (1.0 if tid == 0 else -1.0) * (GameRules.GOAL_LINE_Z - 0.8)
		snap.goalie_states[tid] = g

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.self_velocity = Vector3(0.5, 0.0, -0.5)
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -OUR_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = team_map
	ctx.strong_x = 1.0
	ctx.team_size = 5
	ctx.self_is_defense = false
	return ctx


func _bench(label: String, fn: Callable) -> void:
	fn.call()  # warm (first-call inits, scratch growth)
	var t0: int = Time.get_ticks_usec()
	for _i: int in REPS:
		fn.call()
	var us_per_call: float = float(Time.get_ticks_usec() - t0) / float(REPS)
	_results.append({"label": label, "us": us_per_call})


func test_evaluator_costs() -> void:
	# Off-puck defensive reads (we defend, opp carrier in our corner).
	var d_ctx: RoleContext = _make_ctx(Vector3(1.5, 0.0, 21.0))
	_bench("zone ZONE_D_STRONG (pressure owner)", func() -> void:
		AIRoleZoneDefense.decide(d_ctx, AIRoleSlots.Slot.ZONE_D_STRONG))
	_bench("zone ZONE_D_WEAK (soft lock)", func() -> void:
		AIRoleZoneDefense.decide(d_ctx, AIRoleSlots.Slot.ZONE_D_WEAK))
	_bench("zone ZONE_C", func() -> void:
		AIRoleZoneDefense.decide(d_ctx, AIRoleSlots.Slot.ZONE_C))
	_bench("zone ZONE_W_STRONG", func() -> void:
		AIRoleZoneDefense.decide(d_ctx, AIRoleSlots.Slot.ZONE_W_STRONG))
	_bench("zone ZONE_W_WEAK", func() -> void:
		AIRoleZoneDefense.decide(d_ctx, AIRoleSlots.Slot.ZONE_W_WEAK))
	_bench("PRESSURE", func() -> void: AIRolePressure.decide(d_ctx))
	_bench("MARK (unassigned fallback)", func() -> void: AIRoleMark.decide(d_ctx))
	_bench("CONTAIN", func() -> void: AIRoleContain.decide(d_ctx))

	# Off-puck offensive reads (our carrier deep in THEIR end).
	var o_ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, -17.0), 2)
	o_ctx.snapshot.skater_states[2].position = Vector3(8.0, 0.0, -22.0)
	o_ctx.snapshot.puck_state.position = Vector3(8.0, 0.0, -22.0)
	for pid: int in [100, 101, 102, 103, 104]:
		var st: SkaterNetworkState = o_ctx.snapshot.skater_states[pid]
		st.position = Vector3(st.position.x * 0.6, 0.0, -st.position.z)
	_bench("FINISHER", func() -> void: AIRoleFinisher.decide(o_ctx))
	_bench("SUPPORT", func() -> void: AIRoleSupport.decide(o_ctx))
	_bench("HIGH_SLOT", func() -> void: AIRoleHighSlot.decide(o_ctx))
	_bench("POINT_STRONG (walk the line)", func() -> void:
		AIRoleDefenseman.decide(o_ctx, AIRoleSlots.Slot.POINT_STRONG))
	_bench("DP_STRONG (line hold)", func() -> void:
		AIRoleDefenseman.decide(o_ctx, AIRoleSlots.Slot.DP_STRONG))
	_bench("DVALVE", func() -> void:
		AIRoleDefenseman.decide(o_ctx, AIRoleSlots.Slot.DVALVE))
	_bench("F2 strong lane", func() -> void: AIRoleForecheck.decide_f2(o_ctx, true))
	_bench("F2 weak lane", func() -> void: AIRoleForecheck.decide_f2(o_ctx, false))
	_bench("F3 high safety", func() -> void: AIRoleForecheck.decide(o_ctx, true))
	_bench("OUTLET", func() -> void: AIRoleOutlet.decide(o_ctx))
	_bench("BREAKOUT strong", func() -> void: AIRoleBreakout.decide(o_ctx, true))
	_bench("BREAKOUT_C", func() -> void: AIRoleBreakoutCenter.decide(o_ctx))
	_bench("WIDE lane", func() -> void: AIRoleWideLane.decide(o_ctx, -1.0))

	# The carrier compete — the single biggest per-call evaluator.
	var c_ctx: RoleContext = _make_ctx(Vector3(8.0, 0.0, -22.0), 1)
	var carrier := AIRoleCarrier.new()
	_bench("CARRIER compete (full)", func() -> void:
		carrier._pick_action_cooldown = 0  # defeat the ~30 Hz throttle: time the real compete
		carrier.decide(c_ctx))
	# Exposure-term share: same compete with the 5v5 gate closed.
	var carrier3 := AIRoleCarrier.new()
	_bench("CARRIER compete (no exposure)", func() -> void:
		c_ctx.team_size = 3
		carrier3._pick_action_cooldown = 0
		carrier3.decide(c_ctx)
		c_ctx.team_size = 5)

	# Primitives (costs inside the decides above).
	var opps: Array[Vector3] = [
		Vector3(1.0, 0.0, -20.0), Vector3(-3.0, 0.0, -18.0),
		Vector3(4.0, 0.0, -14.0), Vector3(0.0, 0.0, -10.0),
		Vector3(-6.0, 0.0, -8.0)]
	var net := Vector3(0.0, 0.0, -OUR_NET_Z)
	var goalie := Vector3(0.0, 0.0, -OUR_NET_Z + 0.8)
	var from := Vector3(6.0, 0.0, -18.0)
	_bench("score_shoot (5 defenders)", func() -> void:
		AIActionScoring.score_shoot(from, net, goalie, GameRules.NET_HALF_WIDTH, opps))
	_bench("lane_clear (5 defenders)", func() -> void:
		AIActionScoring.lane_clear(from, net, opps, 20.0))
	_bench("threat_surface_pass (5 def)", func() -> void:
		AIActionScoring.threat_surface_pass(from, Vector3(-4, 0, -19), net, goalie,
				GameRules.NET_HALF_WIDTH, opps))
	var opp_vels: Array[Vector3] = []
	var opp_caps: Array = []
	for _i: int in opps.size():
		opp_vels.append(Vector3.ZERO)
		opp_caps.append(null)
	var mates: Array[Vector3] = [Vector3(-5, 0, -8), Vector3(3, 0, -12),
			Vector3(0, 0, 2), Vector3(-2, 0, 10)]
	_bench("counter_rush_cost (4 tm, 5 opp)", func() -> void:
		AIActionScoring.counter_rush_cost(from, 0.5, Vector3(0, 0, OUR_NET_Z),
				Vector3(0, 0, OUR_NET_Z - 0.8), GameRules.NET_HALF_WIDTH,
				mates, from, 8.0, opps, opp_vels, opp_caps))

	gut.p("")
	gut.p("=== Evaluator micro-benchmark (µs per call, %d reps) ===" % REPS)
	var sorted_rows: Array[Dictionary] = _results.duplicate()
	sorted_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.us) > float(b.us))
	for row: Dictionary in sorted_rows:
		gut.p("  %8.1f  %s" % [row.us, row.label])
	assert_gt(_results.size(), 10, "benchmark ran")
