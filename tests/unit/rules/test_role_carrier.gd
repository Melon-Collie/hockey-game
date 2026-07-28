extends GutTest

# AIRoleCarrier owns _pick_action's hysteresis state, scratch buffers,
# and cooldown counter. The geometric scoring (score_shoot, score_pass,
# path_clearance, position_potential) is already covered in
# test_ai_action_scoring; these tests cover the lifecycle methods
# (reset / clear_intent / cooldown) and verify that decide() produces
# a sensible RoleDecision shape.

const OUR_NET_Z: float = 26.65
const OPP_NET_Z: float = -OUR_NET_Z
const TEAM_ID: int = 0


func _make_ctx(self_pos: Vector3, skaters: Array = []) -> RoleContext:
	# Default snapshot: self at self_pos, no opponents, no goalie.
	# Opponent-empty means score_pass / score_shoot evaluations don't
	# blow up on missing data; carrier handles missing goalie via
	# _goalie_now's null-fallback.
	var snap := WorldSnapshot.new()
	if skaters.is_empty():
		var s := SkaterNetworkState.new()
		s.position = self_pos
		s.facing = Vector2(0.0, -1.0)  # facing -Z (toward opp goal)
		snap.skater_states[1] = s
	else:
		for entry: Array in skaters:
			var sk := SkaterNetworkState.new()
			sk.position = entry[2]
			sk.facing = Vector2(0.0, -1.0)
			sk.is_ghost = entry[3] if entry.size() > 3 else false
			sk.velocity = entry[4] if entry.size() > 4 else Vector3.ZERO
			snap.skater_states[entry[0]] = sk

	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = 1   # we're carrying
	puck.position = self_pos
	puck.velocity = Vector3.ZERO
	snap.puck_state = puck

	var team_map: Dictionary = {1: TEAM_ID}
	if not skaters.is_empty():
		team_map.clear()
		for entry: Array in skaters:
			team_map[entry[0]] = entry[1]

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.self_velocity = Vector3.ZERO
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, OPP_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.anchor = Vector3.ZERO
	ctx.team_id_by_peer = team_map
	return ctx


# ─── breakout: pressured carrier picks the open outlet ──────────────────────

func test_pressured_carrier_in_own_zone_passes_to_open_outlet() -> void:
	# Carrier deep in our own zone, pressured by two forecheckers up-ice; a
	# teammate is a wide-open outlet up the strong-side wall. With carry
	# poke-safety collapsing under pressure, the carrier should rate that
	# outlet as its best pass and choose PASS over carrying into the box.
	# (Verifies the breakout outlet, once well-positioned, actually gets the
	# puck out — no dump needed.)
	var self_pos := Vector3(3, 0, 20)         # off-center, clear of our own slot
	var outlet := Vector3(11, 0, 11)          # open up the strong wall
	var skaters: Array = [
			[1, TEAM_ID, self_pos],               # us, carrying
			[2, TEAM_ID, outlet],                 # open outlet
			[3, 1, Vector3(1.5, 0, 18.0)],        # forechecker pressuring us
			[4, 1, Vector3(3.0, 0, 17.5)],        # second forechecker
	]
	var ctx := _make_ctx(self_pos, skaters)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.debug_pass_peer_id, 2, "best pass targets the open up-wall outlet")
	assert_gt(c.debug_pass_score, 0.0, "the breakout pass has positive value")
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"pressured carrier passes out rather than carrying into the box")


func test_forechecker_closing_the_breakout_lane_devalues_the_pass() -> void:
	# The pass a bot fires is a charged wrister — it leaves the blade ~135 ms
	# after the intent commits — so the lane it threads is the lane as it exists
	# at RELEASE, not at decision time. A forechecker skating hard into a breakout
	# lane has closed real ground (position AND the extra closing time) during that
	# windup; scoring the lane at his CURRENT spot read those feeds as open and
	# shipped the puck into the closing stick (own-zone turnover → goal against).
	# The outlet pass is on with the defender standing clear; the SAME defender
	# skating into the lane devalues it (the release-time projection prices the
	# windup — see _scratch_opponents_release). (Whether the drop flips the whole
	# decision depends on the alternatives; the release-time lane pricing itself is
	# guarded at the primitive level in test_ai_action_scoring.)
	var self_pos := Vector3(4.0, 0.0, 20.0)          # own zone, off-center (clear of our slot)
	var outlet := Vector3(4.0, 0.0, 7.0)             # open outlet straight up the wall

	# Stationary forechecker, 2.6 m off the lane — a full stick clear, so the
	# outlet feed is on.
	var still: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, outlet],
			[11, 1, Vector3(6.6, 0.0, 13.5)],        # beside the lane, standing
	]
	var sc := _make_ctx(self_pos, still)
	var s := AIRoleCarrier.new()
	s.decide(sc)
	assert_eq(s.intended_action, AIRoleCarrier.INTENT_PASS,
			"a defender standing clear of the lane leaves the outlet pass on")
	assert_eq(s.pass_target_peer_id, 2)
	assert_gt(s.debug_pass_score, 0.0)

	# Same start spot, now skating toward the lane (-X). The release-time
	# projection puts him ~1 m closer before the puck even leaves the blade, and
	# he keeps closing over the flight — the feed is worth materially less.
	var closing: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, outlet],
			[11, 1, Vector3(6.6, 0.0, 13.5), false, Vector3(-8.0, 0.0, 0.0)],
	]
	var cc := _make_ctx(self_pos, closing)
	var c := AIRoleCarrier.new()
	c.decide(cc)
	assert_lt(c.debug_pass_score, s.debug_pass_score * 0.9,
			"a forechecker skating into the lane during the windup materially drops the pass value")


func test_forechecker_on_the_hip_contests_the_pass_release() -> void:
	# The cough-up loss mode: a forechecker ON the carrier — off the passing
	# lane, off the receiver — pokes the carried puck during the ~135 ms
	# windup. Before the release contest, he was invisible to the pass EV
	# (lane / miss / reception all miss him), so a swarmed defenseman kept
	# firing "clean" breakout feeds straight into pokes. Same geometry with
	# him a stick clear of the blade leaves the feed's value intact.
	var self_pos := Vector3(4.0, 0.0, 20.0)          # own zone, off-center
	var outlet := Vector3(4.0, 0.0, 7.0)             # open outlet up the wall
	var clear_of_blade: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, outlet],
			[11, 1, self_pos + Vector3(2.6, 0.0, 1.0)],   # near, but stick-clear
	]
	var sc := _make_ctx(self_pos, clear_of_blade)
	var s := AIRoleCarrier.new()
	s.decide(sc)
	var on_hip: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, outlet],
			[11, 1, self_pos + Vector3(1.0, 0.0, 0.4)],   # on the carrier's hip
	]
	var hc := _make_ctx(self_pos, on_hip)
	var h := AIRoleCarrier.new()
	h.decide(hc)
	assert_gt(s.debug_pass_score, 0.0, "the stick-clear feed is a real option")
	assert_lt(h.debug_pass_score, s.debug_pass_score * 0.9,
			"a stick on the carrier contests the release and the same feed "
			+ "is worth materially less; hip=%f clear=%f"
			% [h.debug_pass_score, s.debug_pass_score])


func test_retreating_receiver_is_worth_less_than_a_streaking_one() -> void:
	# Receiver momentum in the post-catch value: the drive-in credit now runs
	# the calibrated arrival model from the receiver's REAL velocity, so a
	# man retreating toward our net pays the full reversal (brake + ramp)
	# before his catch turns into an attack, while the same man in stride
	# toward the opponent net carries his pace into it. Before this, both
	# priced identically (reach / max_speed) — the over-valued backpass to a
	# back-pedalling teammate was exactly this blindness.
	var self_pos := Vector3(3.0, 0.0, 4.0)           # NZ carrier (own net +Z)
	var spot := Vector3(-4.0, 0.0, 6.0)              # teammate slightly behind us
	var streaking: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, spot, false, Vector3(0.0, 0.0, -7.0)],   # in stride, up-ice
	]
	var st := _make_ctx(self_pos, streaking)
	var a := AIRoleCarrier.new()
	a.decide(st)
	var retreating: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, spot, false, Vector3(0.0, 0.0, 7.0)],    # back-pedalling home
	]
	var rt := _make_ctx(self_pos, retreating)
	var b := AIRoleCarrier.new()
	b.decide(rt)
	assert_gt(a.debug_pass_score, b.debug_pass_score + 0.01,
			"the feed to the man in stride out-values the backpass to the "
			+ "retreating one; streak=%f retreat=%f"
			% [a.debug_pass_score, b.debug_pass_score])


func test_turning_receiver_devalues_the_pass_and_the_blind_tier_ignores_it() -> void:
	# Receiver-commitment read: a moving teammate mid-cut curves off the
	# straight-line lead, so the feed to one is priced as riskier. A
	# commitment-blind tier (Easy) is deaf to it and prices the turning receiver
	# exactly like a settled one — it chucks the feed.
	var self_pos := Vector3(3, 0, 20)
	var outlet := Vector3(11, 0, 11)
	var recv_vel := Vector3(0, 0, -6)   # streaking up-ice at 6 m/s
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, outlet, false, recv_vel],
			[3, 1, Vector3(1.5, 0, 18.0)],
			[4, 1, Vector3(3.0, 0, 17.5)],
	]
	# Settled receiver (no heading rotation injected → omega 0).
	var settled_ctx := _make_ctx(self_pos, skaters)
	var cs := AIRoleCarrier.new()
	cs.decide(settled_ctx)
	var settled_score: float = cs.debug_pass_score
	assert_eq(cs.debug_pass_peer_id, 2, "the only teammate is the feed target")
	assert_gt(settled_score, 0.0, "the feed to a settled streaker is on")

	# Same play, receiver now mid-cut (hard heading rotation).
	var turning_ctx := _make_ctx(self_pos, skaters)
	turning_ctx.heading_omega_by_peer = {2: 4.0}
	var ct := AIRoleCarrier.new()
	ct.decide(turning_ctx)
	assert_lt(ct.debug_pass_score, settled_score,
			"a turning receiver is priced as a riskier feed")

	# Commitment-blind tier: same turn, ignored — priced like the settled feed.
	var blind_ctx := _make_ctx(self_pos, skaters)
	blind_ctx.heading_omega_by_peer = {2: 4.0}
	blind_ctx.reads_receiver_commitment = false
	var cb := AIRoleCarrier.new()
	cb.decide(blind_ctx)
	assert_almost_eq(cb.debug_pass_score, settled_score, 0.0001,
			"a commitment-blind bot chucks it — same price as the settled feed")


func test_passes_to_the_open_backdoor_man_over_forcing_a_carry() -> void:
	# The carrier is at a poor wide angle with a wide-open teammate at the far-
	# post backdoor — a feed the goalie's re-square genuinely cannot beat (the
	# arc race across the crease is longer than the pass flight). The pass to
	# him must win over grinding a carry from the bad angle. (Goalie squared
	# to the carrier, as the live keeper is. A DEAD-SLOT stationary man is no
	# longer a good feed under arrival-honest arcs — the keeper re-sets over
	# the flight — so the open man has to be somewhere his shot is real.)
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(6.0, 0.0, -20.0)             # wide angle, poor look
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(-2.5, 0.0, -23.5)],     # far-post backdoor, clear lane
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"feeds the open backdoor man instead of forcing a carry from a bad angle")
	assert_eq(c.pass_target_peer_id, 2)


func test_neutral_zone_hits_the_ahead_man_with_a_clearer_path() -> void:
	# The carrier's own path up the middle is contested (two defenders clogging the
	# lane ahead), but a teammate up-ice on the wing has a clear passing lane AND a
	# clear path to keep advancing. The receiver drive-in credit (in NZ/DZ currency:
	# position potential of where they'd advance to) makes that ahead man out-score
	# the carrier's own stalled carry — so the puck moves up to the clearer path.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(0.0, 0.0, 16.0)              # own end / DZ, carrying
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(-8.0, 0.0, 6.0)],       # winger ahead, clear lane + path
			[11, 1, Vector3(-1.0, 0.0, 10.0)],           # clogs the middle carry
			[12, 1, Vector3(2.0, 0.0, 9.0)],             # clogs the middle carry
	]
	var ctx := _make_ctx(self_pos, skaters)
	var g := GoalieNetworkState.new()
	g.position_x = 0.0
	g.position_z = net.z + 1.3
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"moves the puck up to the ahead man on the clearer path")
	assert_eq(c.pass_target_peer_id, 2)


func test_lightly_impeded_carrier_moves_it_to_the_open_man() -> void:
	# A defender sits in the carrier's forward path — not on the puck, but between it
	# and the zone, so advancing means beating him. With a genuinely open teammate
	# available, a pressured carrier should move the puck rather than grind forward,
	# even conceding a little real estate (the forward-pressure discount). The SAME
	# defender moved OFF to the side leaves the lane clear and the carry stands — the
	# discount is directional, not a blanket pass-always.
	#
	# "GENUINELY OPEN" IS LOAD-BEARING, and it did not used to be. The mate here
	# sat 3.6 m off the same defender and still won the compete, because the
	# forward-pressure read was a 2 m corridor occupancy test: it scored the
	# carrier's space at exactly 0.000 (one man 7 m ahead, the whole width of the
	# ice free) while the mate, being outside that corridor, was credited a clean
	# 1.000. Now both sides are read as controlled space
	# (AIActionScoring.controlled_space) and the mate has to actually be clear —
	# see the tightly-covered contrast at the bottom, which is the same fixture
	# geometry this test used to assert a pass on.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var carrier := Vector3(0.0, 0.0, 2.0)
	var mate := Vector3(7.0, 0.0, -8.0)          # ahead AND wide — a real entry man
	var g := GoalieNetworkState.new()
	g.position_x = 0.0
	g.position_z = net.z + 1.3

	# Defender 7 m ahead, squarely in the path to the zone.
	var ahead: Array = [
			[1, TEAM_ID, carrier], [2, TEAM_ID, mate], [11, 1, Vector3(0.0, 0.0, -5.0)]]
	var ac := _make_ctx(carrier, ahead)
	ac.snapshot.goalie_states[1 - TEAM_ID] = g
	var a := AIRoleCarrier.new()
	a.decide(ac)
	assert_eq(a.intended_action, AIRoleCarrier.INTENT_PASS,
			"a carrier impeded on its path forward moves it to the open man")

	# The discount is DIRECTIONAL: the same defender moved off to the side leaves the
	# forward lane clear, so the carry keeps more of its value than when the
	# defender blocks the path ahead.
	var beside: Array = [
			[1, TEAM_ID, carrier], [2, TEAM_ID, mate], [11, 1, Vector3(7.0, 0.0, -2.0)]]
	var bc := _make_ctx(carrier, beside)
	bc.snapshot.goalie_states[1 - TEAM_ID] = g
	var b := AIRoleCarrier.new()
	b.decide(bc)
	assert_gt(b.debug_carry_score, a.debug_carry_score,
			"a side defender leaves the carry worth more than a forward one blocking the path")

	# …and the pass has to be EARNED. Same carrier, same defender, but the mate
	# tucked 3.6 m off that defender instead of 7.6: he is not an upgrade, and
	# feeding him is not better than beating the man yourself. Asserted as a
	# comparison rather than an argmax — the two spots differ by ~50% of pass EV,
	# which is the robust claim; which side of the carry they land on is a
	# knife-edge in this geometry and not what the model promises.
	var covered: Array = [
			[1, TEAM_ID, carrier], [2, TEAM_ID, Vector3(3.0, 0.0, -3.0)],
			[11, 1, Vector3(0.0, 0.0, -5.0)]]
	var cc := _make_ctx(carrier, covered)
	cc.snapshot.goalie_states[1 - TEAM_ID] = g
	var cov := AIRoleCarrier.new()
	cov.decide(cc)
	assert_lt(cov.debug_pass_score, a.debug_pass_score,
			"a mate tucked in tight to the same defender is worth less than an open one")


func test_ahead_man_on_a_blocked_path_is_not_credited_a_deep_drive() -> void:
	# The drive-in reach is the REACHABLE extent, not a free deep credit: a teammate
	# ahead but with a defender squarely in their forward path can't skate it in, so
	# the reach strips early and they earn little — the carrier keeps the puck rather
	# than dumping it to a covered man. Guards the reachable-set gate.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(0.0, 0.0, 16.0)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(0.0, 0.0, 10.0)],       # ahead, but…
			[11, 1, Vector3(0.0, 0.0, 4.0)],             # …a defender squarely in their drive path
	]
	var ctx := _make_ctx(self_pos, skaters)
	var g := GoalieNetworkState.new()
	g.position_x = 0.0
	g.position_z = net.z + 1.3
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"a man whose path forward is blocked isn't worth a pass over keeping the puck")


func test_pass_is_devalued_when_the_receiver_is_blanketed() -> void:
	# A teammate with a clean passing LANE but a defender skating stride-for-stride
	# beside him — off the lane (lane_clear never sees it) and off his forward-to-
	# net cone (his own shot pressure never sees it), yet close enough to strip the
	# catch the instant it arrives. The reception-pressure term must price that:
	# the feed to the blanketed man scores strictly LOWER than the identical feed
	# to the same spot with no one draped on him.
	var self_pos := Vector3(0.0, 0.0, 8.0)
	var receiver := Vector3(0.0, 0.0, -4.0)

	var clean: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, receiver],
	]
	var c_clean := AIRoleCarrier.new()
	c_clean.decide(_make_ctx(self_pos, clean))
	var clean_score: float = c_clean.debug_pass_score

	var blanketed: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, receiver],
			[9, 1, receiver + Vector3(1.8, 0.0, 0.0)],   # defender draped beside him
	]
	var c_cov := AIRoleCarrier.new()
	c_cov.decide(_make_ctx(self_pos, blanketed))
	var covered_score: float = c_cov.debug_pass_score

	assert_gt(clean_score, 0.0, "the open feed has real value")
	assert_lt(covered_score, clean_score,
			"a blanketed receiver's feed is worth less — reception pressure is priced in")


func test_open_receiver_in_a_poor_spot_is_not_over_credited() -> void:
	# The drive-in credit must not turn EVERY open teammate into a must-pass: a man
	# open but in a genuinely poor spot (wide, no drive that improves the look) stays
	# low-value, so the carrier keeps the puck rather than dumping it wide. Guards
	# against the fix over-passing.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(0.0, 0.0, -12.0)             # decent central carrier
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(9.0, 0.0, -14.0)],      # open but wide/poor angle
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"a wide, low-value open man is not worth passing to over keeping the puck")


func test_close_pass_is_a_crisp_charged_wrister() -> void:
	# Every pass is a paced wrister now — no fixed-power quick snap. A short feed to
	# a close open teammate charges (pass_should_charge) and fires at the MAGNET
	# pace (~20 m/s closing in the receiver's frame), not the old floaty soft touch:
	# crisp enough to be a real threat and to keep its hang time short, still
	# catchable when the receiver squares up. NZ carrier with a defender clogging the
	# straight carry/shot lane so the close lateral feed wins.
	var self_pos := Vector3(-4, 0, 2)
	var outlet := Vector3(1, 0, -1)                   # ~5.8 m — a close feed, up-ice
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, outlet],
			[11, 1, Vector3(-4, 0, -2)],              # clogs the straight-ahead carry/shot
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS, "picks the close outlet")
	assert_eq(c.pass_target_peer_id, 2)
	assert_true(c.pass_should_charge, "a pass is always a charged wrister now")
	assert_gt(c.pass_target_speed, AIActionScoring.PASS_SPEED_M_S,
			"a close feed now fires crisp — above the old quick-snap floor")
	# Backs out of the target arrival at this distance (friction-compensated).
	assert_almost_eq(c.pass_target_speed,
			AIActionScoring.pass_launch_speed(self_pos.distance_to(outlet),
					GameRules.DEFAULT_WRISTER_POWER_MAX_M_S), 0.1,
			"fires at the friction-compensated magnet pace")


# ─── pressure: make a safe play, don't drive into the box ───────────────────

func test_board_pincer_makes_a_safe_play_not_a_turnover() -> void:
	# Carrier pinned on the right wall, two forecheckers converging. There's no
	# separate pass-out-of-pressure bonus: the clean per-action EV resolves this by
	# the carry/pass alternatives' OWN strip cost (carrying into the box goes
	# negative). The bot makes a possession-preserving play — either the lateral
	# outlet pass or a safe evade-carry AWAY from the closing box. What it must NOT
	# do is drive up the wall into the pincer and cough it up. (Pre-removal this
	# asserted the specific outlet pass a relief bonus forced; the evade-carry is an
	# equally valid resolution and what the clean EV prefers here.)
	var self_pos := Vector3(6, 0, 9)                    # right-center, NZ
	var outlet := Vector3(-3, 0, 6)                     # left-center, forward, open
	var d3 := Vector3(4, 0, 4)
	var d4 := Vector3(9, 0, 5)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],                         # us, carrying
			[2, TEAM_ID, outlet],                           # open outlet
			[3, 1, d3, false, Vector3(1.5, 0, 5)],          # inside forechecker closing fast
			[4, 1, d4, false, Vector3(-3, 0, 5)],           # outside forechecker closing (pincer)
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	if c.intended_action == AIRoleCarrier.INTENT_PASS:
		assert_eq(c.debug_pass_peer_id, 2, "if it passes, it feeds the open outlet")
	else:
		# Evade-carry: the destination backs away from the converging pincer rather
		# than driving up-ice into it.
		var pincer_mid: Vector3 = (d3 + d4) * 0.5
		assert_gt(c.debug_carry_pos.distance_to(pincer_mid), self_pos.distance_to(pincer_mid),
				"an evade-carry moves away from the pincer, not into it")


func test_light_pressure_keeps_the_puck_over_a_covered_backpass() -> void:
	# Carrier LIGHTLY pressured with space ahead; the only pass option is a deeper,
	# covered teammate. With no pass-out-of-pressure bonus, the backpass is just its
	# own weak EV (low receiver value, real turnover cost) and loses to keeping the
	# puck and skating. The "don't panic-backpass under light pressure" read.
	var self_pos := Vector3(2, 0, 12)                    # NZ, our side, space ahead (toward -Z)
	var covered := Vector3(0, 0, 19)                     # deeper teammate, in our end
	var skaters: Array = [
			[1, TEAM_ID, self_pos],                          # us, carrying
			[2, TEAM_ID, covered],                           # deeper outlet — but covered
			[3, 1, Vector3(2, 0, 8), false, Vector3(0, 0, 2)],   # light pressure, slow close
			[4, 1, Vector3(0.6, 0, 19.5)],                       # defender sitting on the outlet
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"light pressure + a covered backpass is not an escape — keep the puck")


# ─── breakout: the risky ground-losing backpass loses to keeping the puck ────

func test_risky_backpass_deep_in_own_zone_loses_to_keeping_the_puck() -> void:
	# Carrier deep in our own zone with a forechecker charging at it. The
	# only pass option is a teammate even DEEPER — a low-upside backpass
	# whose execution-miss mode (pass_miss_prob, loss point past the
	# receiver, right in front of our net) makes its EV worse than just
	# keeping the puck and skating. Before the miss-risk term this
	# backpass scored as risk-free (clear lane → zero cost) and won the
	# fire-vs-carry tiebreak; the occasional real miss surrendered all
	# the ice behind the carrier.
	var self_pos := Vector3(2, 0, 21)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(-3, 0, 24)],                          # deep valve (backpass bait)
			[3, 1, Vector3(2, 0, 17.5), false, Vector3(0, 0, 5)],      # forechecker charging us
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"a low-upside backpass toward our own net must not beat keeping the puck")


# ─── stand-still pays turnover cost: pressured carrier never freezes ─────────

func test_pressured_carrier_skates_clear_instead_of_freezing() -> void:
	# Carrier deep in our zone with a single forechecker charging straight
	# at it, the flanks OPEN. Stand-still used to be the only carry candidate
	# that paid NO turnover cost, so freezing stayed positive while every
	# escape route went EV-negative — the bot planted itself and ate the
	# check. With the strip probability (1 - poke_safety) now feeding
	# turnover_cost, freezing under a converging forechecker prices its own
	# turnover and loses to the open skating lane; the carrier beats the
	# forecheck up the wall. (A FULL surround with no open lane is a genuine
	# pin — that reads as a DUMP, see test_pinned_dz_carrier_dumps_to_clear.)
	var self_pos := Vector3(2, 0, 21)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(2, 0, 18), false, Vector3(0, 0, 5)],  # charging forechecker
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"an open lane beats both freezing and dumping — this is a carry read")
	assert_ne(c.last_carry_anchor, self_pos,
			"a carrier with a forechecker bearing down must skate clear, not freeze")


# ─── zone entry: open ice at the blue line must beat standing still ──────────

func test_open_carrier_at_blue_line_drives_in_instead_of_freezing() -> void:
	# Carrier at REST just outside the offensive blue line, wide open —
	# no opponents, clear path to the net. Before the potential-
	# realization discount, stand-still held its position_potential
	# undecayed while every movement candidate paid travel decay; the
	# potential gradient out here is shallower than that decay, so
	# stand-still strictly won and the bot PLANTED at the blue line
	# instead of attacking. Now potential pays its realization decay
	# uniformly and open ice ahead always wins the carry argmax.
	var self_pos := Vector3(0.0, 0.0, -6.5)  # ~20 m from opp goal, just outside shot range
	var ctx: RoleContext = _make_ctx(self_pos)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"nothing to fire from out here — this is a carry read")
	assert_ne(c.last_carry_anchor, self_pos,
			"a wide-open carrier at the blue line must take the space, not freeze")
	assert_lt(c.last_carry_anchor.z, self_pos.z,
			"…and take it TOWARD the attacking net")
	assert_true(
			AIActionScoring.in_offensive_zone(c.last_carry_anchor, ctx.attacking_goal_pos),
			"…all the way across the blue line, entering the offensive zone")


# ─── zone valve: once in the O-zone, don't carry back out ────────────────────

func test_carrier_in_ozone_never_carries_back_out() -> void:
	# Carrier just inside the offensive blue line, swarmed from the front and
	# sides so the safest escape is a RETREAT back across the line. That exit is
	# exactly what the one-way valve forbids: establishing the zone is worth
	# keeping. Every carry candidate that leaves the O-zone is pruned, so the best
	# carry (worst case, stand-still) stays inside it.
	var self_pos := Vector3(0, 0, -9)                      # in the O-zone, near the line
	var skaters: Array = [
			[1, TEAM_ID, self_pos],                           # us, carrying
			[3, 1, Vector3(0, 0, -11), false, Vector3(0, 0, -3)],  # forechecker in front
			[4, 1, Vector3(3, 0, -10)],                       # right pincer
			[5, 1, Vector3(-3, 0, -10)],                      # left pincer
	]
	var ctx: RoleContext = _make_ctx(self_pos, skaters)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_true(
			AIActionScoring.in_offensive_zone(c.last_carry_anchor, ctx.attacking_goal_pos),
			"the best carry keeps the puck in the offensive zone, never retreats out")


# ─── zone valve: once in the O-zone, don't pass back out ─────────────────────

func test_carrier_in_ozone_never_passes_out_to_a_neutral_zone_teammate() -> void:
	# Carrier in the O-zone with its shot screened, and the only pass option is a
	# teammate back in the neutral zone on a wide-open lane — tempting bait. The
	# valve excludes any receiver outside the zone, so that pass is never on the
	# board: the carrier holds/cycles rather than surrendering the blue line.
	var self_pos := Vector3(0, 0, -12)                     # in the O-zone
	var nz_mate := Vector3(6, 0, 0)                        # neutral zone, open lane
	var skaters: Array = [
			[1, TEAM_ID, self_pos],                           # us, carrying
			[2, TEAM_ID, nz_mate],                            # NZ teammate — bait
			[3, 1, Vector3(0, 0, -15)],                       # screens our shot to the net
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"a carrier in the O-zone won't pass the puck back out to the neutral zone")
	assert_eq(c.debug_pass_score, 0.0,
			"the out-of-zone teammate is excluded, so there is no pass on the board")

	# Contrast: a teammate INSIDE the zone, on a clean lane and in scoring ice, is
	# a legal receiver — confirming it was the zone exclusion suppressing the pass
	# above, not a bad lane.
	#
	# The control needs a scene worth something to control FOR. It used to place
	# the in-zone mate at (6, 0, -14) — level with the carrier, off the same dead
	# lane, with no goalie in the snapshot at all — and passed on a pass score of
	# 0.00004, four orders of magnitude under FIRE_MIN_VALUE. That is numerical
	# dust, not a legal pass target: any downstream change of a few percent
	# flipped its sign. A real keeper and a mate in real scoring ice give the
	# assertion something to measure.
	var g := GoalieNetworkState.new()
	g.position_x = 0.0
	g.position_z = -GameRules.GOAL_LINE_Z + 1.3
	var oz_mate := Vector3(6, 0, -19)                      # in the zone, scoring ice
	var skaters_in: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, oz_mate],
			[3, 1, Vector3(0, 0, -15)],
	]
	var ctx_in: RoleContext = _make_ctx(self_pos, skaters_in)
	ctx_in.snapshot.goalie_states[1 - TEAM_ID] = g
	var c2 := AIRoleCarrier.new()
	c2.decide(ctx_in)
	assert_gt(c2.debug_pass_score, AIRoleCarrier.FIRE_MIN_VALUE,
			"an in-zone teammate in scoring ice IS a legal pass target, worth firing")


# ─── O-zone shot selection: don't fire the long shot on entry ────────────────

func test_carrier_entering_ozone_drives_the_slot_over_a_long_shot() -> void:
	# Carrier just inside the blue line, wide open, with a defending goalie set at a
	# realistic challenge depth. The long shot from the top of the zone is
	# low-danger (foreshortened net, long flight the goalie has time to react to),
	# while driving to the slot is a real look. In the O-zone the bot prices
	# positions by pure xG — there is NO establishment floor inflating a weak shot —
	# so it must CARRY toward the net, not fire from range the moment it crosses the
	# line. This is the guard on "don't shoot as soon as you enter the zone."
	var self_pos := Vector3(0, 0, -9)              # ~2 m inside the blue line
	var ctx := _make_ctx(self_pos)
	var g := GoalieNetworkState.new()
	g.position_x = 0.0
	g.position_z = -24.65                          # challenging ~2 m off the goal line
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"a long shot from the top of the zone loses to driving the slot")
	assert_lt(c.last_carry_anchor.z, self_pos.z,
			"…and the drive heads toward the net")


# ─── O-zone shot selection: get the shot off before running the goalie over ──

func test_bot_driving_the_net_gets_a_shot_off_before_the_goalie() -> void:
	# 1-on-1 drive at the net: as a bot carries straight in on the goalie, there
	# must be a distance at which it commits to the shot — and it must be clear
	# of the goalie, out in the slot, not point-blank in the crease where it would
	# just run the goalie over and get dispossessed. xG peaks around the slot and
	# falls as the goalie's shadow eats the angle point-blank, so carrying closer
	# stops paying and the bot fires. The goalie sits 1 m out — the live keeper's
	# rush BACKFLOW retreats him toward the crease at the carrier's pace, so this
	# is the realistic 1-on-1 depth. (Parked dead-square 2 m out he genuinely
	# walls off the straight fire — the honest read there is the lateral cut /
	# doorstep window, covered by test_1v1_lateral_cut_beats_the_aggressive_goalie
	# below, not a head-on shot.)
	# This drive is DEAD-CENTRE at a square keeper — the zero-angle line no
	# keeper at any depth concedes a corner from (the old model's head-on
	# release here was the phantom in-tight roof window, i.e. the
	# shot-into-the-chest bug). Since carry candidates price ARRIVING AT
	# PACE, the honest finish is a small lateral redirection off his centre
	# line, then fire — a committed finish either way. What must NEVER
	# happen on the drive is the failure this test exists for: carrying
	# straight in and running the keeper over (a near-centre anchor
	# at/inside his depth — the smother).
	var goalie_out: float = 1.0                          # backflowed 1 m off the line
	var goalie_z: float = -GameRules.GOAL_LINE_Z + goalie_out
	var finish_committed: bool = false
	for dist: float in [10.0, 9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0]:
		var self_pos := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z + dist)
		var ctx := _make_ctx(self_pos)
		ctx.self_velocity = Vector3(0.0, 0.0, -6.0)      # driving hard at the net
		var g := GoalieNetworkState.new()
		g.position_x = 0.0
		g.position_z = goalie_z
		ctx.snapshot.goalie_states[1 - TEAM_ID] = g
		var c := AIRoleCarrier.new()
		c.decide(ctx)
		if c.intended_action == AIRoleCarrier.INTENT_SHOOT:
			# A release on the drive must come clear of the goalie, not from
			# point-blank inside his reach.
			assert_gt(dist, goalie_out + 1.0,
					"the drive's release comes clear of the goalie, not inside him")
			finish_committed = true
		elif c.intended_action == AIRoleCarrier.INTENT_CARRY and dist <= 7.0:
			# In tight, a carry commit on the drive must be the deke — a
			# genuine lateral redirection — never a straight-in anchor at the
			# keeper (the run-him-over smother).
			var straight_in: bool = absf(c.last_carry_anchor.x) < 1.2 \
					and c.last_carry_anchor.z <= goalie_z + 0.5
			assert_false(straight_in,
					"drive commit at %.0f m must be a shot or a lateral deke, "
					% dist + "not a straight carry into the smother")
			if absf(c.last_carry_anchor.x) >= 1.5:
				finish_committed = true
	assert_true(finish_committed,
			"somewhere on the drive the 1-on-1 commits a finish (shot or deke cut)")


func test_1v1_lateral_cut_beats_the_aggressive_goalie() -> void:
	# The penalty-shot guarantee: against a keeper challenging way out (2 m,
	# squared), the straight-in fire is correctly walled off — the play is to go
	# HORIZONTAL. The honest 1v1 unfolds in two beats:
	#   1. Cut starting, keeper still square: the drive-side window is already a
	#      real chance, but EXTENDING the cut reads better still — the carrier
	#      keeps driving laterally (never a stall, never a dump).
	#   2. Mid-cut, keeper beaten (lagging the arc race his accel-capped push
	#      lost): the shot commits, and it's a real chance.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z + 3.0)
	var cutting := _make_ctx(self_pos)
	cutting.self_velocity = Vector3(6.0, 0.0, 0.0)
	cutting.snapshot.skater_states[1].velocity = cutting.self_velocity
	cutting.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 2.0)
	var c := AIRoleCarrier.new()
	c.decide(cutting)
	assert_gt(c.debug_shoot_score, 0.3,
			"the cut's drive-side window is a real chance; got %f" % c.debug_shoot_score)
	if c.intended_action == AIRoleCarrier.INTENT_CARRY:
		assert_gt(c.last_carry_anchor.x, 1.0,
				"…and if the bot holds the fire, it's to EXTEND the cut, not stall")
	else:
		assert_eq(c.intended_action, AIRoleCarrier.INTENT_SHOOT)

	# Mid-cut with the keeper beaten: fire commits. (At a slightly longer cut
	# with the keeper closer behind, the compete legitimately prefers another
	# beat of carry — the projected release is past the apex while the current
	# spot still reads richer — so this snapshot is the unambiguous "window is
	# NOW" beat: the keeper a full step behind the arc race.)
	var beaten := _make_ctx(Vector3(1.8, 0.0, -GameRules.GOAL_LINE_Z + 3.0))
	beaten.self_velocity = Vector3(6.0, 0.0, 0.0)
	beaten.snapshot.skater_states[1].velocity = beaten.self_velocity
	var lagged := GoalieNetworkState.new()
	lagged.position_x = 0.7   # still chasing — lost the arc race to the cut
	lagged.position_z = -GameRules.GOAL_LINE_Z + 2.0
	beaten.snapshot.goalie_states[1 - TEAM_ID] = lagged
	var cb := AIRoleCarrier.new()
	cb.decide(beaten)
	assert_eq(cb.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"once the cut has beaten the keeper, the 1v1 commits the shot")
	assert_gt(cb.debug_shoot_score, 0.3,
			"…and it's a real chance, not a floor-scraper; got %f" % cb.debug_shoot_score)

	# Flat-footed vs the same 2 m over-challenge: the keeper is only ~1 m off
	# the puck, so a blade-reach relocation swings the arc faster than his push
	# covers — the release-offset sampler prices the pull-around and the 1v1
	# finishes BY HAND instead of needing to skate the cut first. The commit
	# must carry the relocation: the straight fire into his chest is smothered.
	var flat := _make_ctx(self_pos)
	flat.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 2.0)
	var c2 := AIRoleCarrier.new()
	c2.decide(flat)
	assert_eq(c2.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"flat-footed vs an overcommitted challenge, the pull-around fires")
	assert_gt(c2.shot_release_offset.length(), 0.3,
			"…and it is the relocated release, never a straight fire into the smother")


func test_mid_cut_hold_never_out_prices_the_same_instants_fire() -> void:
	# Stand-still's shot branch shares the shoot-now score (see _best_carry), so
	# a mid-cut carrier can never conclude "holding here beats firing from
	# here". Before the share, stand-still priced its shot at the CURRENT spot
	# (pre-apex of the cut) while the fire priced the projected release (past
	# the apex) — the hold read richer than the fire from the same instant and
	# the bot carried through its own shooting window. If CARRY wins mid-cut it
	# must be a genuine relocation, never the in-place hold.
	for gx: float in [0.4, 0.7, 1.0]:
		var pos := Vector3(2.4, 0.0, -GameRules.GOAL_LINE_Z + 3.0)
		var ctx := _make_ctx(pos)
		ctx.self_velocity = Vector3(6.0, 0.0, 0.0)
		ctx.snapshot.skater_states[1].velocity = ctx.self_velocity
		var g := GoalieNetworkState.new()
		g.position_x = gx
		g.position_z = -GameRules.GOAL_LINE_Z + 2.0
		ctx.snapshot.goalie_states[1 - TEAM_ID] = g
		var c := AIRoleCarrier.new()
		c.decide(ctx)
		assert_gt(c.debug_shoot_score, 0.3,
				"the mid-cut window (goalie at x=%.1f) is a real chance" % gx)
		if c.intended_action == AIRoleCarrier.INTENT_CARRY:
			assert_gt(c.last_carry_anchor.distance_to(pos), 0.5,
					"mid-cut CARRY (goalie at x=%.1f) must be a relocation, not the hold"
					% gx)


func test_standstill_1v1_winds_up_the_cut() -> void:
	# Re-anchored by the #27 compete restructure: IN TIGHT (3 m, keeper at a
	# 1.3 m challenge) the calibrated make-probability surface is honest that
	# a free release with the relocation sampler beats the challenge — the
	# 1v1 FIRES, same doctrine as the 2 m over-challenge pull-around test
	# above. (The old expectation of a setup carry here was written under the
	# soft-make curve that under-priced direct windows in tight.) The wind-up
	# bootstrap this test pins lives AT RANGE below, where no direct window
	# exists and the carry must still commit a real advancing plan.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z + 3.0)
	var ctx := _make_ctx(self_pos)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"in tight, the honest window past a 1.3 m challenge is taken")
	assert_gt(c.debug_shoot_score, 0.3,
			"…and it is a real chance, not a floor-scraper; got %f"
			% c.debug_shoot_score)

	# Ever-receding-cut guard at RANGE: no phantom IMMEDIATE window out there
	# (the reach budget covers the keeper's full deploy), and what the carry
	# prices is the honest plan — work in to the mid-range quick-release band
	# and fire — not an orbit around a window that never arrives. So: the
	# direct shot stays a floor-scraper, the carry beats it, and the committed
	# anchor ADVANCES toward the net.
	var far_pos := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z + 9.0)
	var far := _make_ctx(far_pos)
	far.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(far_pos, net, 1.3)
	var cf := AIRoleCarrier.new()
	cf.decide(far)
	assert_eq(cf.intended_action, AIRoleCarrier.INTENT_CARRY,
			"at range vs a set keeper the play is still the carry")
	# Compared to the SAME release in tight, above — not to an absolute bar.
	# The currency's ceiling is a property of whichever shot model is wired in;
	# "no real window at range" is a statement about range, so it has to be
	# measured against a range that DOES open one.
	assert_lt(cf.debug_shoot_score, c.debug_shoot_score * 0.5,
			"…because range opens a fraction of the window 3 m does; %f vs %f"
			% [cf.debug_shoot_score, c.debug_shoot_score])
	assert_gt(cf.debug_carry_score, cf.debug_shoot_score,
			"…and the priced plan (drive to the shooting band) beats flinging it")
	assert_lt(cf.last_carry_anchor.z, far_pos.z,
			"…with an anchor that advances toward the net, not an orbit")


func test_wing_carrier_with_a_step_curls_toward_the_middle() -> void:
	# The reported bug: a carrier who beat his man down the wing kept gliding
	# the wall to the goal line and turned at 90° — bizarre-looking, and it
	# forfeits every shooting angle. Re-anchored by the #27 compete
	# restructure: the momentum-aware plan may hold ONE full-speed stride
	# down the wall first (the honest cut geometry at 8.5 m/s), so the pin is
	# two-fold — the first committed target never rides to the goal-line
	# corner, and the follow-up decision from that spot bends hard off the
	# wall toward the middle while there is still angle to use.
	var self_pos := Vector3(9.0, 0.0, -14.0)
	var ctx: RoleContext = _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[10, 1 - TEAM_ID, Vector3(9.0, 0.0, -10.0)],   # beaten man, trailing
			[11, 1 - TEAM_ID, Vector3(-2.0, 0.0, -23.0)],  # far-side low cover
	])
	ctx.self_velocity = Vector3(0.0, 0.0, -8.5)            # driving the wing
	ctx.snapshot.skater_states[1].velocity = ctx.self_velocity
	ctx.snapshot.skater_states[10].velocity = Vector3(0.0, 0.0, -8.5)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(
			self_pos, Vector3(0.0, 0.0, OPP_NET_Z), 1.2)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"still a carry read from the wing")
	# The reported bug was gliding the wall ALL the way to the goal line and
	# turning 90° there — forfeiting every angle. Under the momentum-honest
	# nominal-reach read the carrier may hold ONE full-speed stride down the
	# wall before curling, so the robust pin is that the committed target
	# never rides to the deep goal-line corner: it stays high with real angle
	# left to use, never a drift into the dead corner.
	assert_gt(c.debug_carry_pos.z, -20.0,
			"the committed carry stays off the deep goal-line corner; got %s"
			% c.debug_carry_pos)
	assert_lt(c.debug_carry_pos.z, self_pos.z - 0.5,
			"…while still advancing on the rush, not stalling; got %s"
			% c.debug_carry_pos)
	assert_gt(c.debug_carry_pos.z, OPP_NET_Z + 4.0,
			"…and stays above the goal line (a curl, not a corner dump); got %s"
			% c.debug_carry_pos)


func _squared_goalie(self_pos: Vector3, net: Vector3, depth: float) -> GoalieNetworkState:
	# Goalie arc-matched to the carrier (as the live keeper is — it tracks the
	# current puck-holder), sitting `depth` out from the net.
	var to_sh: Vector3 = self_pos - net
	to_sh.y = 0.0
	var g: Vector3 = net + to_sh.normalized() * depth
	var gs := GoalieNetworkState.new()
	gs.position_x = g.x
	gs.position_z = g.z
	return gs


# ─── release-offset sampling (see AIRoleCarrier.RELEASE_SAMPLE_FRACS) ────────

func test_release_sampling_relocates_toward_the_open_side() -> void:
	# Goalie displaced onto the carrier's BACKHAND side (RH default: forehand is
	# +x when attacking -z; mirrored carrier at -1.2 with the goalie at -1.1):
	# the full-reach FOREHAND relocation opens the far side wider than the
	# simple release sees, at no pace penalty — the sampler should pick it.
	var pos := Vector3(-1.2, 0.0, -23.5)
	var ctx := _make_ctx(pos)
	var g := GoalieNetworkState.new()
	g.position_x = -0.8
	g.position_z = -25.0
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_gt(c._shot_sample_offset.x, 0.3,
			"the winning sample relocates the release toward the open (forehand) side")
	assert_false(c._shot_sample_backhand, "…on the forehand, at full pace")
	# "A genuine chance" stated as behaviour rather than as a number: the
	# relocated look has to WIN the compete against every carry and pass
	# alternative from this spot. That is the same claim, and it survives the
	# shot model being swapped underneath it.
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"…and the relocated look is a genuine chance — it is taken")



func test_release_sampling_finds_the_backhand_tuck_beside_the_net() -> void:
	# Carrier tight beside the net at a dead-sharp angle, goalie holding the near
	# post: the simple release has nothing, but relocating the puck a blade-reach
	# toward the front of the crease — a BACKHAND-side move for this wing —
	# opens the tuck. The classic wraparound-y finish, priced at backhand pace.
	var pos := Vector3(2.4, 0.0, -25.6)
	var ctx := _make_ctx(pos)
	var g := GoalieNetworkState.new()
	g.position_x = 0.85
	g.position_z = -26.1
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_true(c._shot_sample_backhand, "the tuck is a backhand-side relocation")
	assert_gt(c._shot_sample_offset.z, 0.3,
			"…moving the release out in front of the crease")
	assert_lt(c._shot_sample_speed, ctx.self_wrister_shot_speed - 0.01,
			"…priced at the backhand's penalized pace")
	assert_gt(c.debug_shoot_score, AIRoleCarrier.FIRE_MIN_VALUE,
			"…and it turns a nothing angle into a committable look; got %f"
			% c.debug_shoot_score)


func test_release_sampling_commit_carries_the_winning_offset() -> void:
	# The mid-cut fire (same snapshot as the 1v1 beaten beat): whatever sample
	# wins the sweep is exactly what the commit exposes to the state machine —
	# offset, or ZERO for the simple release. The executed shot must be the
	# scored one.
	var pos := Vector3(1.8, 0.0, -GameRules.GOAL_LINE_Z + 3.0)
	var ctx := _make_ctx(pos)
	ctx.self_velocity = Vector3(6.0, 0.0, 0.0)
	ctx.snapshot.skater_states[1].velocity = ctx.self_velocity
	var g := GoalieNetworkState.new()
	g.position_x = 0.7
	g.position_z = -GameRules.GOAL_LINE_Z + 2.0
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_SHOOT, "the mid-cut window fires")
	assert_eq(c.shot_release_offset, c._shot_sample_offset,
			"the commit exposes exactly the winning sample's offset")


func test_wide_angle_shot_is_not_taken_against_a_squared_goalie() -> void:
	# A shot from a wide angle vs a squared keeper should be a nothing look.
	# Un-pended by the dead-angle post-play extension (#28): the carrier's
	# release sampler derives the predicted seal, and past the erasure
	# threshold (net window narrower than a keeper on the near post) the
	# whole look dies — no phantom far-side window to fire at.
	var self_pos := Vector3(7.0, 0.0, -24.0)               # ~69° off the normal
	var ctx := _make_ctx(self_pos)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(
			self_pos, Vector3(0.0, 0.0, OPP_NET_Z), 1.2)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_lt(c.debug_shoot_score, 0.3,
			"the wide-angle look reads near-nothing; got %f" % c.debug_shoot_score)
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"…so the carrier does not fire it")


func test_slot_look_is_calibrated_and_displacement_beats_the_set_keeper() -> void:
	# CALIBRATED (shot-outcome instrument): the dead-slot quick release beats
	# a STANDING set keeper's drop — a first-class look, not the old "modest
	# window". Displacement is asserted where the surface has gradient: at
	# the 8.5 m knife band a keeper squared to the OLD spot (beaten by the
	# cross-ice relocation) concedes strictly more than one squared to the
	# shooter.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var slot := Vector3(0.0, 0.0, -22.0)
	var sctx := _make_ctx(slot)
	sctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(slot, net, 1.3)
	var sc := AIRoleCarrier.new()
	sc.decide(sctx)
	var band := Vector3(0.0, 0.0, -18.15)               # the 8.5 m gradient band
	var wide := Vector3(9.0, 0.0, -22.0)
	var bctx := _make_ctx(band)
	bctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(band, net, 1.3)
	var bc := AIRoleCarrier.new()
	bc.decide(bctx)
	# "First-class look, not a modest window" against the 8.5 m band this test
	# already scores — a RATIO, so it says something about the shape of the
	# surface rather than about where the currency happens to top out.
	assert_gt(sc.debug_shoot_score, bc.debug_shoot_score * 2.0,
			"the dead slot is worth multiples of the mid-range band; %f vs %f"
			% [sc.debug_shoot_score, bc.debug_shoot_score])
	var dctx := _make_ctx(band)
	dctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(wide, net, 1.3)
	var dc := AIRoleCarrier.new()
	dc.decide(dctx)
	assert_gt(dc.debug_shoot_score, bc.debug_shoot_score,
			"a keeper still squared to the old spot concedes more than a set one")


# ─── breakout: wall-exit carry route when the middle is clogged ──────────────

func test_wall_exit_carry_wins_when_middle_is_clogged() -> void:
	# Carrier wheeling up the weak-side wall with momentum, forecheck set
	# up through the middle (one opponent pinching the local up-ice steps,
	# another sitting in the diagonal slot-drive lane from this wide start).
	# No teammates → no pass bailout. The zone-exit wall candidate — a real
	# "skate it out along the boards" plan — should win the carry argmax over
	# the myopic 3 m steps and the through-the-middle slot drive.
	var self_pos := Vector3(-10.5, 0, 21)
	var skaters: Array = [
			[1, TEAM_ID, self_pos, false, Vector3(0, 0, -5)],  # us, skating up-ice
			[3, 1, Vector3(-7.5, 0, 16.5)],                    # pinching the up-ice step
			[4, 1, Vector3(-6.5, 0, 6)],                       # sits in the slot-drive lane
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.self_velocity = Vector3(0, 0, -5)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"nothing to shoot at or pass to — this is a carry read")
	# Hugs the boards on OUR side (away from the clogged middle), heading up-ice
	# toward the exit. The bot skates the wall out step-by-step (re-picking each
	# tick) rather than committing to the far exit anchor in one shot — the
	# near boards step decays less, and it's the same "skate it out" behaviour.
	assert_lt(c.last_carry_anchor.x, -10.0,
			"the winning carry anchor hugs our (left) boards, not the clogged middle")
	assert_lt(c.last_carry_anchor.z, self_pos.z,
			"…and moves up-ice toward the zone exit, not deeper or across")


func test_wall_exit_candidates_absent_in_offensive_half() -> void:
	# Wall exits are own-half candidates only. An OZ carrier's anchor must
	# come from the local steps / slot anchor — never a point back at our
	# blue line (own_goal_dir * z > 0 for team 0 is z > 0; the exit z sits
	# at +(BLUE_LINE_Z - lead), which would be BEHIND an OZ carrier).
	var self_pos := Vector3(-8, 0, -15)  # offensive half, wide
	var ctx := _make_ctx(self_pos)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_lt(c.last_carry_anchor.z, 0.0,
			"an offensive-half carrier never targets the own-half wall-exit point")


# ─── stagger: don't wind up a shot off-balance ──────────────────────────────

func test_staggered_carrier_holds_instead_of_firing() -> void:
	# Reuse the pressured-breakout setup that reliably fires a PASS: carrier
	# boxed by forecheckers with an open up-wall outlet.
	var self_pos := Vector3(3, 0, 20)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(11, 0, 11)],     # open outlet
			[3, 1, Vector3(1.5, 0, 18.0)],        # forechecker
			[4, 1, Vector3(3.0, 0, 17.5)],        # forechecker
	]

	# Not staggered → commits the fire (the breakout pass).
	var c1 := AIRoleCarrier.new()
	c1.decide(_make_ctx(self_pos, skaters))
	assert_ne(c1.intended_action, AIRoleCarrier.INTENT_CARRY,
			"pressured carrier commits a fire (breakout pass) when not staggered")

	# Staggered → holds the puck rather than flailing a release off-balance,
	# even though the fire would otherwise win.
	var ctx_staggered: RoleContext = _make_ctx(self_pos, skaters)
	ctx_staggered.self_stagger_timer = 0.5
	var c2 := AIRoleCarrier.new()
	c2.decide(ctx_staggered)
	assert_eq(c2.intended_action, AIRoleCarrier.INTENT_CARRY,
			"staggered carrier holds instead of committing the fire")


# ─── settle window: a fresh possession only carries until the beat drains ────

func _settle_skaters(self_pos: Vector3) -> Array:
	# The pressured-breakout setup that reliably fires a PASS on tick one.
	return [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(11, 0, 11)],     # open outlet
			[3, 1, Vector3(1.5, 0, 18.0)],        # forechecker
			[4, 1, Vector3(3.0, 0, 17.5)],        # forechecker
	]


func test_settle_window_holds_the_fire_then_releases_it() -> void:
	var self_pos := Vector3(3, 0, 20)
	var ctx := _make_ctx(self_pos, _settle_skaters(self_pos))
	ctx.carry_settle_delay_s = 0.2   # 24 ticks at 120 Hz
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"a fresh possession may only carry inside the settle window")
	assert_gt(c.debug_pass_score, 0.0,
			"scores keep computing during the window — only the commit waits")
	# Drain the window in real ticks (decide() steps ctx.dispatch_period_ticks
	# = 1 tick per call); a re-eval lands within PICK_ACTION_PERIOD_TICKS of
	# the drain, so 40 calls comfortably covers 0.2 s + one cadence.
	for _i: int in range(40):
		c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"the held-back breakout pass releases once the window drains")


func test_settle_window_rearms_on_reset_but_not_on_clear_intent() -> void:
	var self_pos := Vector3(3, 0, 20)
	var ctx := _make_ctx(self_pos, _settle_skaters(self_pos))
	ctx.carry_settle_delay_s = 0.2
	var c := AIRoleCarrier.new()
	for _i: int in range(41):
		c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS, "sanity: window drained")

	# clear_intent (press-state handoff / bail) is the SAME possession — the
	# next decide may re-commit immediately, no fresh settle beat.
	c.clear_intent()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"a press bail back to CARRY re-fires without re-settling")

	# reset (puck lost) marks the next decide as a NEW possession — the
	# settle window re-arms and holds the fire again.
	c.reset()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"regaining the puck starts a fresh settle beat")


func test_zero_settle_delay_is_the_hard_baseline() -> void:
	# ctx default (0.0) must reproduce the pre-knob behavior exactly: the
	# pressured carrier fires on its first decide.
	var self_pos := Vector3(3, 0, 20)
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, _settle_skaters(self_pos)))
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"no settle delay → the tick-one fire is unchanged")


# ─── poise under pressure: the SHOOT settle beat is pressure-scaled ──────────

func test_unpressured_shot_bypasses_the_settle_beat() -> void:
	# The in-tight 1v1 (test_standstill_1v1_winds_up_the_cut) with NO opposing
	# skaters near the shooter — current_safety ≈ 1. A fresh-possession settle
	# beat that flat-gated every commit used to hold this look and CARRY through
	# it; with the shot beat pressure-scaled, an unpressured carrier finishes the
	# instant it gains the puck (the open backdoor tap-in). This is the fix.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z + 3.0)
	var ctx := _make_ctx(self_pos)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	ctx.carry_settle_delay_s = 0.3   # a full Normal-ish beat
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"an unpressured shot fires on tick one despite the settle beat")


func test_pressured_shot_still_pays_the_settle_beat() -> void:
	# Same in-tight look, but a defender draped tight on the shooter (behind the
	# puck, so it doesn't screen the puck→net line — the shot still scores) tanks
	# current_safety. The pressure-scaled beat now holds the shot on tick one, then
	# releases it once the countdown drains below base × safety — poise: rushed
	# hands can't settle-and-snipe the instant they gain the puck.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z + 3.0)
	# Poise reads the clearance where the carrier STANDS (not the evade seam), so a
	# single checker draped ON the puck is enough — a stick bearing down rushes the
	# release even though a lane exists. Same z as the shooter → along-sightline
	# distance ~0, no screen registers, the shot still scores.
	var checker_pos := Vector3(0.25, 0.0, -GameRules.GOAL_LINE_Z + 3.0)
	var ctx := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[9, 1 - TEAM_ID, checker_pos],
	])
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	ctx.carry_settle_delay_s = 0.3
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_lt(c._phase_pos_safety, 1.0,
			"sanity: a stick on the puck lowers the current-spot poise safety below 1")
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"a hounded fresh carrier can't fire on tick one — it pays the beat")
	# Drain the pressure-scaled window; the held shot then commits.
	for _i: int in range(60):
		c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"once the settle beat drains, the pressured shot releases")


# ─── reset() ──────────────────────────────────────────────────────────────

func test_reset_clears_all_persistent_state() -> void:
	var c := AIRoleCarrier.new()
	c.intended_action = AIRoleCarrier.INTENT_PASS
	c.pass_target_peer_id = 42
	c.pass_should_charge = true
	c.pass_should_saucer = true
	c.shot_loft_level = ShotMechanics.ELEVATION_HIGH
	c.last_carry_anchor = Vector3(5.0, 0.0, -10.0)

	c.reset()

	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY)
	assert_eq(c.pass_target_peer_id, -1)
	assert_false(c.pass_should_charge)
	assert_false(c.pass_should_saucer)
	assert_eq(c.shot_loft_level, ShotMechanics.ELEVATION_FLAT)
	assert_eq(c.last_carry_anchor, Vector3.ZERO)


# ─── clear_intent() ───────────────────────────────────────────────────────

func test_clear_intent_resets_intent_but_preserves_carry_anchor() -> void:
	var c := AIRoleCarrier.new()
	c.intended_action = AIRoleCarrier.INTENT_SHOOT
	c.pass_target_peer_id = 42
	c.pass_should_charge = true
	c.pass_should_saucer = true
	c.last_carry_anchor = Vector3(5.0, 0.0, -10.0)

	c.clear_intent()

	# Intent + pass target reset; carry anchor preserved (state machine
	# may still be reading it during the press cycle).
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY)
	assert_eq(c.pass_target_peer_id, -1)
	assert_false(c.pass_should_charge)
	assert_false(c.pass_should_saucer)
	assert_eq(c.last_carry_anchor, Vector3(5.0, 0.0, -10.0))


# ─── decide() cooldown ────────────────────────────────────────────────────

func test_decide_throttles_pick_action_at_period_ticks() -> void:
	# First decide() runs _pick_action (cooldown was 0). Subsequent
	# calls within PICK_ACTION_PERIOD_TICKS should NOT re-run
	# _pick_action — last_carry_anchor and intended_action stay
	# fixed. We verify this by mutating intended_action between
	# decides and confirming the second call doesn't overwrite it
	# (because it's still in cooldown).
	var c := AIRoleCarrier.new()
	var ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, -22.0))  # in slot

	c.decide(ctx)  # tick 0: runs _pick_action, sets cooldown to PERIOD_TICKS

	# Force-flip the persistent intent. If the next decide() ran
	# _pick_action again, it would overwrite this.
	c.intended_action = AIRoleCarrier.INTENT_PASS

	for i in range(AIRoleCarrier.PICK_ACTION_PERIOD_TICKS - 1):
		c.decide(ctx)

	# Still inside cooldown — intent must be the artificially-set value.
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"decide() should NOT re-run _pick_action within the cooldown window")


func test_decide_re_evaluates_after_cooldown_expires() -> void:
	# Same as above, but tick exactly PICK_ACTION_PERIOD_TICKS times
	# so the next decide() re-evaluates. A steady-state re-eval is
	# TIME-SLICED across two dispatches (fire phase, then carry + commit —
	# see the slice doc above _commit_phase_pending), so the new intent
	# lands on the second decide() after the cooldown expires.
	var c := AIRoleCarrier.new()
	var ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, -22.0))

	c.decide(ctx)  # tick 0: runs _pick_action (first eval = single-call)
	# Drain the cooldown the code actually ARMS, not the nominal period. This
	# fixture is an empty rink and the compete resolves to CARRY, which is the
	# open-ice LOD case in _arm_pick_cooldown: with no opponent inside
	# OPEN_ICE_LOD_RADIUS_M and the argmax answering CARRY, the re-eval is
	# re-armed at a third of the rate. Draining only the nominal period leaves
	# the carrier still in cooldown and the flip below survives — which reads
	# as "the re-eval never ran" when the truth is "it was not due yet".
	for i in range(AIRoleCarrier.PICK_ACTION_PERIOD_TICKS
			* AIRoleCarrier.OPEN_ICE_LOD_PERIOD_MULT):
		c.decide(ctx)
	# Force-flip and run the sliced re-eval to its commit: fire phase on the
	# first call, carry + commit (which overwrites our flip) on the second.
	c.intended_action = AIRoleCarrier.INTENT_PASS
	c.decide(ctx)
	c.decide(ctx)

	# After re-eval the carrier picks based on the snapshot. The exact
	# winning intent depends on scoring math (covered in
	# test_ai_action_scoring); the contract here is just "the re-eval
	# ran and overwrote our manual flip."
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"decide() should re-run the compete after cooldown elapses, replacing the manually-set intent")


# ─── decide() return shape ────────────────────────────────────────────────

func test_decide_returns_role_decision_with_target_position() -> void:
	var c := AIRoleCarrier.new()
	var ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, -22.0))
	var d: RoleDecision = c.decide(ctx)
	# target_position mirrors last_carry_anchor; one of the carry
	# candidates (or stand-still) wins, so it must be a valid Vector3.
	assert_eq(d.target_position, c.last_carry_anchor)


func test_in_motion_toward_slot_scores_higher_than_stationary() -> void:
	# Anticipation: score_shoot is evaluated at the projected RELEASE
	# position (current pos + horizontal_velocity × charge_lookahead).
	# A bot rushing into the slot should score the spot they'll release
	# from — meaning a moving bot OUT of slot range should outscore a
	# stationary bot at the same current pos.
	#
	# Both bots stand at z = -15 (~12 m from opp goal at z = -26.65 —
	# outside ideal but inside SHOT_RANGE_FALLOFF_M). The moving bot
	# travels toward the goal at 8 m/s. With BOT_WRISTER_LOOKAHEAD_S
	# = 0.25, the projected release pos is z ≈ -17 → ~10 m from goal,
	# noticeably better dist_response than 12 m.
	var pos := Vector3(0.0, 0.0, -18.0)
	var stationary_ctx: RoleContext = _make_ctx(pos)
	stationary_ctx.self_velocity = Vector3.ZERO
	var moving_ctx: RoleContext = _make_ctx(pos)
	moving_ctx.self_velocity = Vector3(0.0, 0.0, -8.0)

	var stationary := AIRoleCarrier.new()
	stationary.decide(stationary_ctx)
	var moving := AIRoleCarrier.new()
	moving.decide(moving_ctx)

	assert_gt(moving.debug_shoot_score, stationary.debug_shoot_score,
			"in-motion bot rushing into slot should score the release-pos spot, beating the stationary same-pos shot")


func test_decide_carry_intent_clears_fire_flags() -> void:
	# Force CARRY intent, verify decide() returns a RoleDecision with
	# all fire flags false.
	var c := AIRoleCarrier.new()
	var ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, -22.0))
	c.decide(ctx)  # let _pick_action run once
	c.intended_action = AIRoleCarrier.INTENT_CARRY  # force CARRY
	# Don't trigger another _pick_action — bump cooldown back up so
	# the next decide() is a pure cached return.
	# (We can't access _pick_action_cooldown directly; just trust that
	# the next decide() runs another _pick_action which re-decides.
	# Instead, construct a fresh AIRoleCarrier and inspect after one
	# decide, then check the returned decision's flags directly.)
	var d: RoleDecision = c.decide(ctx)
	# Whichever intent wins, the corresponding flag must be set
	# correctly and the other flags must be false.
	if d.shoot_intent:
		assert_false(d.pass_intent)
	elif d.pass_intent:
		assert_false(d.shoot_intent)
	else:
		# CARRY case — both fire flags must be false.
		assert_false(d.shoot_intent)
		assert_false(d.pass_intent)


func test_zero_value_fire_does_not_win_in_own_zone() -> void:
	# Carrier buried deep in its own end (z = +22, ~48 m from the opp
	# goal at z = -26.65). Shoot/quick-shot score 0 (far past
	# SHOT_RANGE_FALLOFF_M) and there are no teammates to pass to, so
	# every fire option is 0. Before the positive-value gate the bot
	# fired on the 0-0 fire-vs-carry tie (FIRE WINS TIES); now a zero
	# fire can't win, so it must keep the puck (CARRY).
	var c := AIRoleCarrier.new()
	var ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, 22.0))
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"a negligible-value fire must not beat holding the puck deep in our own zone")
	assert_lt(c.debug_shoot_score, 0.02,
			"sanity: shoot is negligible from ~48 m (net subtends almost nothing)")


func test_positive_shot_scores_above_zero_in_slot() -> void:
	# Regression guard for the positive-value fire gate. The gate
	# (fire_score >= carry_score AND fire_score > 0) only changes
	# behavior at fire_score == 0; a positive fire is scored exactly as
	# before. We assert the precondition the gate keys on — a slot shot
	# scores well above 0 — rather than that fire WINS the action pick:
	# with an empty net (no goalie/defenders in this minimal ctx) a
	# carry toward the open net legitimately outscores a slot shot, so
	# which action wins is scenario-dependent and not what this gate
	# governs. The zero-case is covered by
	# test_zero_value_fire_does_not_win_in_own_zone.
	var c := AIRoleCarrier.new()
	var ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, -22.0))  # in slot
	c.decide(ctx)
	assert_gt(c.debug_shoot_score, 0.0,
			"a slot shot scores positive, so the >0 gate never blocks it")


# ─── principled hold: the developing cross-seam EV (no magic numbers) ────────
# _best_developing_feed is the value the carrier weighs against firing now —
# P(keep) × this × decay(held) competes directly in the action max.

func _ctx_with_finisher(fin_pos: Vector3, ready: bool) -> RoleContext:
	# Carrier strong-side in the OZ; a FINISHER-slotted teammate staging at fin_pos.
	var self_pos := Vector3(4, 0, -18)
	var ctx := _make_ctx(self_pos, [[1, TEAM_ID, self_pos], [2, TEAM_ID, fin_pos]])
	var brain := TeamBrain.new(TEAM_ID, ctx.team_id_by_peer)
	brain.slot_assignments[2] = AIRoleSlots.Slot.FINISHER
	if ready:
		brain.set_one_timer_ready(2, true)
	ctx.team_brain = brain
	# A live keeper challenged on the carrier's line: the cross-seam feed's
	# whole value is the traverse he can't finish inside the flight — a
	# keeper parked on the goal line (the fixture default) has no traverse
	# to lose and reads every developing spot as dead.
	var g := GoalieNetworkState.new()
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var dir: Vector3 = (self_pos - net).normalized()
	g.position_x = net.x + dir.x * 1.3
	g.position_z = net.z + dir.z * 1.3
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	return ctx


func test_developing_feed_zero_without_brain() -> void:
	var ctx := _make_ctx(Vector3(4, 0, -18))
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_eq(carrier._best_developing_feed(ctx), 0.0,
			"no team brain → nothing to wait for")


func test_developing_feed_zero_when_finisher_already_ready() -> void:
	# Already-flagged finisher is fed by normal scoring — not something to hold for.
	var ctx := _ctx_with_finisher(Vector3(-2.5, 0, -21.5), true)
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_eq(carrier._best_developing_feed(ctx), 0.0)


func test_developing_feed_positive_for_staging_cross_seam_finisher() -> void:
	var ctx := _ctx_with_finisher(Vector3(-2.5, 0, -21.5), false)
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_gt(carrier._best_developing_feed(ctx), 0.0,
			"a staging cross-seam finisher gives a positive developing feed")


func test_developing_hold_self_extinguishes_as_it_is_held() -> void:
	# Upper-bound guard for READ_VALIDITY_TAU_S: the reason to HOLD for a developing
	# feed decays as the hold drags on (delay_discount(_hold_elapsed_s)), so a wait
	# that never pays off self-terminates rather than dithering forever. A longer
	# hold is worth strictly less than a fresh one against the SAME developing feed.
	# (The parameter-level patient-edge guard is
	# test_delay_discount_bounds_patience in test_ai_action_scoring.)
	var ctx := _ctx_with_finisher(Vector3(-2.5, 0, -21.5), false)
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	var feed: float = carrier._best_developing_feed(ctx)
	assert_gt(feed, 0.0, "sanity: there is a developing feed to hold for")
	var fresh_hold: float = feed * AIActionScoring.delay_discount(0.0)
	var stale_hold: float = feed * AIActionScoring.delay_discount(1.5)
	assert_lt(stale_hold, fresh_hold,
			"holding longer is worth less — the wait self-extinguishes, no dithering")


func test_developing_feed_invisible_without_the_cognition_gate() -> void:
	# Same staging finisher the test above values positively — but a tier that
	# doesn't hold for developing plays (Easy) sees nothing: it plays only what
	# exists right now.
	var ctx := _ctx_with_finisher(Vector3(-2.5, 0, -21.5), false)
	ctx.holds_for_developing_feeds = false
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_eq(carrier._best_developing_feed(ctx), 0.0,
			"the developing play is invisible to a tier without the hold read")


func test_goalie_motion_blind_reads_the_keeper_as_always_set() -> void:
	# Goalie parked well off the shooter's arc with a short release window —
	# the re-square race is live, so a motion-reading bot sees a positive
	# unsettled window (the cross-seam one-timer value). A motion-blind tier
	# models him as always set: the same read returns exactly 0.
	var self_pos := Vector3(0.0, 0.0, -18.0)
	var ctx := _make_ctx(self_pos)
	var gs := GoalieNetworkState.new()
	gs.position_x = -2.5                          # ~2.5 m off the square line
	gs.position_z = OPP_NET_Z + 1.2
	ctx.snapshot.goalie_states[1 - TEAM_ID] = gs
	var carrier := AIRoleCarrier.new()
	assert_gt(carrier._goalie_unsettled_at(ctx, 0.2, self_pos), 0.0,
			"an off-square keeper on a short release reads unsettled")
	ctx.reads_goalie_motion = false
	assert_eq(carrier._goalie_unsettled_at(ctx, 0.2, self_pos), 0.0,
			"a motion-blind tier reads the same keeper as set")


func test_developing_feed_zero_for_ghosted_finisher() -> void:
	# An offside (ghosted) finisher can't legally receive — the live pass
	# scoring skips ghosts, so the hold must too, or the carrier waits
	# for a feed it's never allowed to make.
	var self_pos := Vector3(4, 0, -18)
	var ctx := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(-3, 0, -19), true]])  # staging spot, but ghosted
	var brain := TeamBrain.new(TEAM_ID, ctx.team_id_by_peer)
	brain.slot_assignments[2] = AIRoleSlots.Slot.FINISHER
	ctx.team_brain = brain
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_eq(carrier._best_developing_feed(ctx), 0.0,
			"a ghosted finisher isn't a developing play — nothing to hold for")


func test_developing_feed_zero_when_finisher_out_of_offensive_zone() -> void:
	# Finisher back in the neutral zone (z = -5 > -BLUE_LINE_Z) → not a cross-seam.
	var ctx := _ctx_with_finisher(Vector3(-3, 0, -5), false)
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_eq(carrier._best_developing_feed(ctx), 0.0,
			"a finisher outside the OZ isn't a developing cross-seam")


func test_developing_feed_counts_a_finisher_still_crossing_the_line() -> void:
	# A finisher a stride OUTSIDE the blue line driving hard into the zone IS
	# the developing cross-seam — the old current-position gate read exactly 0
	# here, so a carrier fresh off the entry saw nothing worth waiting for and
	# settled for the weak from-the-top shot. Parked at the same spot he still
	# reads 0: the gate opens on where he's GETTING to, not a slot label.
	var fin_pos := Vector3(-5, 0, -(GameRules.BLUE_LINE_Z - 1.0))
	var parked := _ctx_with_finisher(fin_pos, false)
	var c1 := AIRoleCarrier.new()
	c1._scratch_teammate_ids = [2]
	assert_eq(c1._best_developing_feed(parked), 0.0,
			"parked outside the line: nothing developing")
	var driving := _ctx_with_finisher(fin_pos, false)
	driving.snapshot.skater_states[2].velocity = Vector3(1.0, 0, -8.5)
	var c2 := AIRoleCarrier.new()
	c2._scratch_teammate_ids = [2]
	assert_gt(c2._best_developing_feed(driving), 0.0,
			"driving in: the entering finisher is a developing play")


func test_developing_feed_values_the_spot_the_finisher_is_driving_to() -> void:
	# A finisher high in the zone skating hard for the house is priced at the
	# spot he's driving to (velocity projection, same primitive as the
	# developing outlet) — worth more than the same man parked high. The drive
	# heads for the net-front (that's what "driving to the house" is): a drive
	# that stays high and wide reaches a spot the body-occlusion shot model
	# honestly prices at ~0.
	var fin_pos := Vector3(-5, 0, -12.0)
	var parked := _ctx_with_finisher(fin_pos, false)
	var c1 := AIRoleCarrier.new()
	c1._scratch_teammate_ids = [2]
	var feed_parked: float = c1._best_developing_feed(parked)
	var driving := _ctx_with_finisher(fin_pos, false)
	driving.snapshot.skater_states[2].velocity = Vector3(2.5, 0, -6.5)
	var c2 := AIRoleCarrier.new()
	c2._scratch_teammate_ids = [2]
	assert_gt(c2._best_developing_feed(driving), feed_parked,
			"the feed is valued at the spot the finisher is getting to")


func test_fresh_entry_holds_for_the_driving_finisher_over_the_top_shot() -> void:
	# The playtest read: seconds after a zone entry, box set, carry strangled —
	# the carrier settled for a weak shot from above the circle because
	# nothing else scored. The mate driving to the house IS the something
	# else: the developing feed must out-value the marginal top shot so the
	# hold (feed × keep × decay) wins the compete instead of the giveaway.
	var self_pos := Vector3(2, 0, -14.5)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(-5, 0, -15.0), false, Vector3(0.8, 0, -7.5)],
			[3, TEAM_ID, Vector3(6, 0, -6.3)],       # support high at the line
			[11, 1, Vector3(-0.5, 0, -20.5)],        # set D box
			[12, 1, Vector3(2.5, 0, -19.0)],
			[13, 1, Vector3(0.5, 0, -11.3)],         # high man choking the carry
	]
	var ctx := _make_ctx(self_pos, skaters)
	var g := GoalieNetworkState.new()
	g.position_x = 0.45                              # tracking, not dead-set centre
	g.position_z = -26.65 + 1.3
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var brain := TeamBrain.new(TEAM_ID, ctx.team_id_by_peer)
	brain.slot_assignments[2] = AIRoleSlots.Slot.FINISHER
	brain.slot_assignments[3] = AIRoleSlots.Slot.SUPPORT
	ctx.team_brain = brain
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"the marginal top shot is not taken while the play develops")
	assert_gt(c._best_developing_feed(ctx), c.debug_shoot_score,
			"the developing feed out-values the from-the-top shot")


# ─── developing breakout outlet: hold instead of forcing the backpass ────────
# A BREAKOUT_STRONG / OUTLET teammate skating its route is a developing
# feed: _developing_outlet_feed projects it OUTLET_DEVELOP_WINDOW_S along
# its velocity and prices the pass to that spot through the same _pass_ev
# as the live scoring.

func _ctx_with_outlet(outlet_pos: Vector3, outlet_vel: Vector3,
		ghost: bool = false) -> RoleContext:
	# Carrier deep in our own zone; teammate 2 slotted BREAKOUT_STRONG.
	var self_pos := Vector3(2, 0, 20)
	var ctx := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, outlet_pos, ghost, outlet_vel]])
	var brain := TeamBrain.new(TEAM_ID, ctx.team_id_by_peer)
	brain.slot_assignments[2] = AIRoleSlots.Slot.BREAKOUT_STRONG
	ctx.team_brain = brain
	return ctx


func test_developing_feed_positive_for_outlet_skating_its_route() -> void:
	# Outlet on the strong wall, skating hard up-ice toward the blue line.
	var ctx := _ctx_with_outlet(Vector3(9, 0, 16), Vector3(1.2, 0, -6))
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_gt(carrier._best_developing_feed(ctx), 0.0,
			"an outlet skating up its route is a developing feed worth holding for")


func test_developing_feed_zero_for_stationary_outlet() -> void:
	# A parked outlet offers exactly the spot it's at — the live pass
	# scoring already prices that; nothing is developing.
	var ctx := _ctx_with_outlet(Vector3(9, 0, 16), Vector3.ZERO)
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_eq(carrier._best_developing_feed(ctx), 0.0,
			"a stationary outlet isn't developing anything")


func test_developing_feed_zero_for_ghosted_outlet() -> void:
	var ctx := _ctx_with_outlet(Vector3(9, 0, 16), Vector3(1.2, 0, -6), true)
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_eq(carrier._best_developing_feed(ctx), 0.0,
			"a ghosted outlet can't receive — no developing feed")


func test_developing_outlet_beats_the_spot_it_left_behind() -> void:
	# The whole point of the hold: the pass the outlet is CREATING
	# (projected up its route, toward open ice) out-values the pass to
	# where it currently stands. Compare the developing feed of a moving
	# outlet against one parked at the same spot but projected nowhere.
	var moving := _ctx_with_outlet(Vector3(9, 0, 16), Vector3(1.2, 0, -6))
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	var developing: float = carrier._best_developing_feed(moving)

	# The same feed valued AT the outlet's current spot: reuse _pass_ev
	# directly so both sides run identical pricing.
	var spot := Vector3(9, 0, 16)
	var dist: float = moving.self_pos.distance_to(spot)
	var pass_speed: float = AIActionScoring.pass_launch_speed(
			dist, moving.self_wrister_shot_speed, moving.pass_speed_scale)
	var flight_t: float = clampf(dist / pass_speed, 0.0, AIRoleCarrier.PASS_LEAD_MAX_S)
	var carrier2 := AIRoleCarrier.new()
	carrier2._scratch_teammate_ids = [2]
	var stay_put: float = carrier2._pass_ev(
			moving, spot, pass_speed, flight_t,
			flight_t + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, flight_t,
			moving.defending_goal_pos)

	assert_gt(developing, stay_put,
			"the projected up-ice spot out-values the spot the outlet is leaving")


func test_pressured_carrier_never_forces_the_backpass_when_outlet_develops() -> void:
	# The user-facing behavior: carrier pressured deep in our zone, a
	# close backpass valve available, and the strong-side outlet skating
	# its route. Acceptable reads are "keep the puck while the breakout
	# develops" or "headman it up-ice to the outlet" — what must never
	# happen is forcing the ground-losing backpass to the deep valve.
	var self_pos := Vector3(2, 0, 20)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(9, 0, 16), false, Vector3(1.2, 0, -6)],  # outlet en route
			[5, TEAM_ID, Vector3(-3, 0, 24)],                             # deep valve (bait)
			[3, 1, Vector3(2, 0, 17.5), false, Vector3(0, 0, 5)],         # forechecker charging
	]
	var ctx := _make_ctx(self_pos, skaters)
	var brain := TeamBrain.new(TEAM_ID, ctx.team_id_by_peer)
	brain.slot_assignments[2] = AIRoleSlots.Slot.BREAKOUT_STRONG
	brain.slot_assignments[5] = AIRoleSlots.Slot.BREAKOUT_WEAK
	ctx.team_brain = brain
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	if c.intended_action == AIRoleCarrier.INTENT_PASS:
		assert_eq(c.pass_target_peer_id, 2,
				"if the carrier passes under pressure, it's up-ice to the outlet — never the deep valve")
	else:
		assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
				"otherwise the carrier keeps the puck while the breakout develops")


func test_decide_runs_the_hold_path_with_a_staging_finisher() -> void:
	# Smoke: the principled hold (developing feed × keep_prob × decay) executes
	# end-to-end in decide() with a staging-finisher brain and yields a valid intent.
	var ctx := _ctx_with_finisher(Vector3(-2.5, 0, -21.5), false)
	var carrier := AIRoleCarrier.new()
	var d := carrier.decide(ctx)
	assert_not_null(d)
	assert_true(carrier.intended_action == AIRoleCarrier.INTENT_CARRY \
			or carrier.intended_action == AIRoleCarrier.INTENT_SHOOT \
			or carrier.intended_action == AIRoleCarrier.INTENT_PASS,
			"decide() yields a valid intent with a staging finisher in play")


# ─── dumping: last-resort relief in two specific spots ───────────────────────

func test_swarmed_own_zone_carrier_squeezes_out_with_possession() -> void:
	# Deep in our slot with the forecheck converging. Re-anchored by the
	# measured meeting-strip band: at BLADE-CONTACT range (all three men
	# ~1.5 m off the puck, flanks OPPOSED so the protect budget splits to
	# nothing) every escape route honestly dies at its crossing — the duel
	# physics strip a carrier at that range — so the clear fires as the true
	# last resort. Loosen the same swarm a stride and a protected route
	# survives, so the compete flips back to fighting for possession. The
	# FLIP is the pin: the clear stays a last resort, never the default.
	# (The clear's GEOMETRY stays pinned by the direct _best_dump test below.)
	var self_pos := Vector3(6, 0, 24)                      # deep slot, swarmed
	var tight: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(6, 0, 22.2), false, Vector3(0, 0, 5)],
			[4, 1, Vector3(4.6, 0, 24.6)],
			[5, 1, Vector3(7.4, 0, 24.6)],
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, tight))
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_DUMP,
			"on-blade opposed swarm: no route survives the measured band — clear it")

	var loose: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(6, 0, 20.0), false, Vector3(0, 0, 5)],
			[4, 1, Vector3(3.2, 0, 24.6)],
			[5, 1, Vector3(8.8, 0, 24.6)],
	]
	var c2 := AIRoleCarrier.new()
	c2.decide(_make_ctx(self_pos, loose))
	assert_ne(c2.intended_action, AIRoleCarrier.INTENT_DUMP,
			"a stride of air and the carrier fights for possession instead")


func test_best_dump_geometry_in_own_zone_is_a_hard_rim_out() -> void:
	# Direct pin on the DZ clear's GEOMETRY (the compete around it is covered
	# above): from our own zone the dump is a hard flat fling off the
	# strong-side boards, out of the zone.
	var self_pos := Vector3(6, 0, 24)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(6, 0, 22)],
	]
	var ctx: RoleContext = _make_ctx(self_pos, skaters)
	var c := AIRoleCarrier.new()
	c._build_action_opponents_lists(ctx)
	var dump: Array = c._best_dump(ctx, AIRoleHelpers.resolve_our_goalie_pos(ctx))
	assert_false(dump[2], "a DZ clear is a hard flat fling, not a soft flip")
	assert_gt(dump[1].x, 0.0, "cleared off the strong-side boards (carrier's side)")
	assert_false(
			AIActionScoring.in_offensive_zone(dump[1], ctx.defending_goal_pos),
			"the clear takes the puck out of our defensive zone")


func test_contained_past_center_with_open_backfield_regroups() -> void:
	# Carrier past centre, denied at the blue line, nothing to pass — but the
	# ice BEHIND is open: the real play is curling back to regroup. Un-pended
	# by restaging the wall as a GENUINE denial: the old fixture (one
	# back-pedalling D + one static D wide) left honest routes around, and
	# under the #27 reach pricing the compete rightly took them — the test
	# was the broken thing, not the behavior. A real stand-up line — set,
	# shaded to the carrier, head D at proper gap, flankers bracketing both
	# swing lanes — kills every crossing, and the regroup emerges from the
	# existing pricing with no dedicated model. Probed boundaries (both
	# honest): a static head D INSIDE ~1.2 m gets stepped around (too tight
	# to deny), and a line RETREATING from a tight gap concedes the blue
	# line and gets blown through; this fixture sits three ladder steps
	# inside the deny plateau (identical anchor across head-gap 1.4-2.0 m).
	var self_pos := Vector3(2, 0, -4)                      # attacking half (attack -Z), pre-blue
	var walled: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(-4, 0, -6)],                     # weak-side flanker
			[4, 1, Vector3(2, 0, -5.5)],                    # head D, set at gap
			[5, 1, Vector3(8, 0, -6)],                      # strong-side flanker
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, walled))
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_DUMP,
			"an open backfield beats conceding the puck")
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY, "regroups with possession")
	assert_gt(c.last_carry_anchor.z, self_pos.z + 2.0,
			"the regroup carries back toward centre, creating space")

	# Contrast pin: the OLD fixture's loose pair is NOT a wall — the compete
	# honestly attacks the seam instead of ceding ice to two beatable bodies.
	var loose: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(2, 0, -5), false, Vector3(0, 0, -4)],  # D backing off us
			[4, 1, Vector3(-1, 0, -5.5)],                      # D wide of the lane
	]
	var c2 := AIRoleCarrier.new()
	c2.decide(_make_ctx(self_pos, loose))
	assert_eq(c2.intended_action, AIRoleCarrier.INTENT_CARRY,
			"two beatable bodies are not denial")
	assert_lt(c2.last_carry_anchor.z, self_pos.z - 2.0,
			"…and the carrier takes the ice they concede")


func test_best_dump_geometry_past_center_is_a_soft_flip_to_the_far_corner() -> void:
	# Direct pin on the dump-in's GEOMETRY (the compete around it is covered
	# by the pincer/regroup tests): past centre, the dump target is a soft
	# flip into the far offensive corner, away from the carrier's side.
	var self_pos := Vector3(2, 0, -4)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(2, 0, -5)],
	]
	var ctx: RoleContext = _make_ctx(self_pos, skaters)
	var c := AIRoleCarrier.new()
	c._build_action_opponents_lists(ctx)
	var dump: Array = c._best_dump(ctx, AIRoleHelpers.resolve_our_goalie_pos(ctx))
	assert_true(dump[2], "a dump-in is a soft flip to the corner")
	assert_true(
			AIActionScoring.in_offensive_zone(dump[1], ctx.attacking_goal_pos),
			"the dump target is in the offensive zone")
	assert_lt(dump[1].x, 0.0, "the FAR corner, opposite the carrier's side")


func test_carrier_with_a_clean_outlet_does_not_dump() -> void:
	# Un-pended by the meeting-strip crossing band (measured, protection-
	# aware): the head-on forecheck meeting prices as the strip it is even
	# for a protecting carrier, so retention is honestly hopeless and the
	# outlet wins the compete.
	# Same pinned DZ spot, but now a teammate is wide open up the strong wall. A
	# real breakout out-scores conceding — pass, don't dump.
	var self_pos := Vector3(8, 0, 20)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(11, 0, 11)],                  # open outlet up the wall
			[3, 1, Vector3(8, 0, 17), false, Vector3(0, 0, 4)],
			[4, 1, Vector3(5.5, 0, 19)],
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_DUMP,
			"a clean breakout outlet beats a dump")
	# The compete must stay transitive here: when retention is hopeless (raw
	# carry below the dump), the pass competes against the DUMP, not against
	# the floored keep-the-puck carry that already lost — so the pinned
	# carrier moves the puck to the live outlet instead of flinging it to
	# space past him.
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"the pinned carrier hits the outlet rather than concede")
	assert_eq(c.pass_target_peer_id, 2, "the outlet up the wall is the target")


func test_no_dump_in_own_side_neutral_zone() -> void:
	# Between our own blue line and centre — not our DZ, not past the red line. No
	# dump applies here even under pressure (it would be icing to fire it in, and
	# there's no need to clear from mid-ice).
	var self_pos := Vector3(0, 0, 4)                       # own-side NZ (own net +Z)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(0, 0, 1), false, Vector3(0, 0, 4)],
			[4, 1, Vector3(3, 0, 2)],
			[5, 1, Vector3(-3, 0, 2)],
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_DUMP,
			"no dump from the own-side neutral zone")


func test_no_dump_once_in_the_offensive_zone() -> void:
	# Already established in the OZ — the valve keeps the puck in, and there's no
	# dump. Even swarmed, it cycles/holds rather than dumping it away.
	var self_pos := Vector3(0, 0, -12)                     # in the OZ (attack -Z)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(0, 0, -14), false, Vector3(0, 0, -4)],
			[4, 1, Vector3(3, 0, -13)],
			[5, 1, Vector3(-3, 0, -13)],
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_DUMP,
			"no dumping once the zone is established")


# ─── _facing_rotation_time: the blade reach cone (Aim-B / B1) ────────────────
# The carrier prices a shot/pass by the body ROTATION it costs. The blade
# reaches anywhere inside the ±reach-cone (ROM + torso twist, ~157°) from the
# current facing, so an in-cone aim fires with NO turn; only the narrow back
# wedge past the cone pays, at the bot's Agility-scaled turn rate. These pin the
# grounded geometry directly (the recursive pass-EV path can't isolate it).

const _CONE_157: float = deg_to_rad(157.0)


func _rot_time(facing_deg: float, target_deg: float, cone: float,
		rate: float) -> float:
	# facing/target given as degrees off +Z (CCW in XZ). Self at origin.
	var c := AIRoleCarrier.new()
	var f := deg_to_rad(facing_deg)
	var t := deg_to_rad(target_deg)
	var facing_xz := Vector2(sin(f), cos(f))
	var target := Vector3(sin(t) * 10.0, 0.0, cos(t) * 10.0)
	return c._facing_rotation_time(facing_xz, Vector3.ZERO, target, cone, rate)


func test_in_cone_aim_costs_no_rotation() -> void:
	# A 120° off-facing target is well inside the ±157° reach cone, so the blade
	# fires from the current facing — zero body-turn cost. Under the OLD ±90° cone
	# this same aim would have paid; widening the cone is the core of B1.
	assert_almost_eq(_rot_time(0.0, 120.0, _CONE_157, 6.0), 0.0, 0.0001,
			"an in-cone (≤157°) aim requires no body rotation")
	assert_almost_eq(_rot_time(0.0, 155.0, _CONE_157, 6.0), 0.0, 0.0001,
			"just inside the cone is still free")


func test_back_wedge_aim_pays_only_the_overshoot() -> void:
	# Directly behind (180°) is 23° past the 157° cone, rotated at 6 rad/s.
	var expected: float = deg_to_rad(180.0 - 157.0) / 6.0
	assert_almost_eq(_rot_time(0.0, 180.0, _CONE_157, 6.0), expected, 0.0001,
			"only the overshoot past the cone costs time")


func test_nimbler_bot_prices_a_back_wedge_turn_cheaper() -> void:
	# Same back-wedge geometry, a faster (higher-Agility) turn rate → less time.
	var slow: float = _rot_time(0.0, 180.0, _CONE_157, 6.0)
	var fast: float = _rot_time(0.0, 180.0, _CONE_157, 12.0)
	assert_lt(fast, slow,
			"a higher facing turn rate resolves the back-wedge turn sooner")
	assert_almost_eq(fast, slow * 0.5, 0.0001,
			"double the turn rate halves the rotation cost")


func test_wider_cone_frees_a_lateral_aim() -> void:
	# The same 120° aim: free under the true ±157° cone, penalized under the old
	# ±90°. This is exactly the behavioural shift B1 introduces.
	var wide: float = _rot_time(0.0, 120.0, _CONE_157, 6.0)
	var narrow: float = _rot_time(0.0, 120.0, deg_to_rad(90.0), 6.0)
	assert_eq(wide, 0.0, "wide cone frees the lateral aim")
	assert_gt(narrow, 0.0, "the old narrow cone would have penalized it")


# ─── Shot measured from the puck, not the body ──────────────────────────────

func test_shot_is_measured_from_the_puck_not_the_body() -> void:
	# The carried puck rides the blade, up to a stick's reach from the body — the
	# shot's view of the net is from the PUCK. Same body position, puck extended
	# toward the net → the release ref moves with it → wider real angles → higher
	# shoot score. (The fixture default puts the puck AT the body, so every other
	# scenario in this file is unchanged.)
	var self_pos := Vector3(0, 0, -17.65)   # 9 m out
	var ctx_body: RoleContext = _make_ctx(self_pos)
	var c1 := AIRoleCarrier.new()
	c1.decide(ctx_body)
	var body_score: float = c1.debug_shoot_score

	var ctx_blade: RoleContext = _make_ctx(self_pos)
	ctx_blade.snapshot.puck_state.position = self_pos + Vector3(0, 0, -1.1)
	var c2 := AIRoleCarrier.new()
	c2.decide(ctx_blade)
	assert_gt(c2.debug_shoot_score, body_score,
			"a puck extended toward the net measures a wider view than the chest")


# ─── Blue line: free entry over tiki-taka ────────────────────────────────────

func test_blue_line_entry_carries_past_a_symmetric_set_defense() -> void:
	# Carrier and a mate level at the blue line, defenders set INSIDE the zone at
	# a normal contain gap — symmetric coverage. The receiver used to escape the
	# forward-pressure discount the carrier paid, so each winger rated the other
	# man's future above his own present and the puck ping-ponged along the line.
	# With the symmetric discount, the man with the puck takes the entry.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(-4, 0, -(GameRules.BLUE_LINE_Z - 1.0))
	var skaters: Array = [
			[1, TEAM_ID, self_pos, false, Vector3(0, 0, -6)],
			[2, TEAM_ID, Vector3(4, 0, self_pos.z), false, Vector3(0, 0, -6)],
			[11, 1, Vector3(-3.5, 0, -12.0)],
			[12, 1, Vector3(3.5, 0, -12.0)],
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.self_velocity = Vector3(0, 0, -6)
	var g := GoalieNetworkState.new()
	g.position_x = 0.0
	g.position_z = net.z + 1.3
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"symmetric coverage at the line → the puck-carrier takes the entry")


# ─── Post-seal stances: the carrier reads the VH wall ────────────────────────

func test_post_seal_x_sign_decodes_the_wire_convention() -> void:
	# Convention lock: the controller enters *_LEFT when puck_local_x =
	# (puck.x − goal.x) · −sign(−goal_z) < 0 — i.e. the sealed post sits at
	# world-x sign(−goal_z). Both nets, both stance families.
	var g := GoalieNetworkState.new()
	g.state_enum = GoalieStateMachine.State.VH_LEFT as int
	assert_eq(g.post_seal_x_sign(-26.65), 1.0, "net at −z: LEFT seals the +x post")
	assert_eq(g.post_seal_x_sign(26.65), -1.0, "net at +z: LEFT seals the −x post")
	assert_true(g.is_post_seal_tall(), "VH is the tall seal")
	g.state_enum = GoalieStateMachine.State.RVH_RIGHT as int
	assert_eq(g.post_seal_x_sign(-26.65), -1.0, "net at −z: RIGHT seals the −x post")
	assert_false(g.is_post_seal_tall(), "RVH is the compressed seal")
	g.state_enum = GoalieStateMachine.State.READY as int
	assert_eq(g.post_seal_x_sign(-26.65), 0.0, "no post stance, no seal")


func test_sharp_angle_shot_into_a_vh_seal_is_never_worth_firing() -> void:
	# The observed over-fire: from a sharp angle the arc-square model read a
	# near-goal-line keeper as roughly centred (his deep arc-x sits near 0),
	# conceding a phantom short side — while the real goalie is parked at the
	# post in VH with the whole near column walled off. With the seal read
	# from the replicated state, the shot from the seal side collapses below
	# the fire floor: whatever the carrier does here, it is never "fire into
	# the VH wall."
	var self_pos := Vector3(4.5, 0, -26.0)   # sharp angle, seal side, in tight
	var ctx_vh := _make_ctx(self_pos)
	var g_vh := GoalieNetworkState.new()
	g_vh.position_x = 0.85                    # parked at the +x post
	g_vh.position_z = -26.55                  # post-seal depth ~0.10
	g_vh.state_enum = GoalieStateMachine.State.VH_LEFT as int   # seals +x here
	ctx_vh.snapshot.goalie_states[1 - TEAM_ID] = g_vh
	var vh := AIRoleCarrier.new()
	vh.decide(ctx_vh)
	# Not exactly zero: the model honestly keeps the thin cross-net window at
	# the FAR post (see the aim test in test_ai_action_scoring) — but the
	# near column is walled off, so nothing here rates as a real chance.
	assert_lt(vh.debug_shoot_score, 0.10,
			"the sealed sharp angle offers no real chance; got %f" % vh.debug_shoot_score)

	# Same carrier, same replicated goalie placement, but STANDING: under the
	# body-occlusion shot model the goalie's DEPTH walls the cross-net lane from
	# a spot this sharp with or without the seal — the obscenely-tight-angle fire
	# is never a real chance, which is exactly the read the seal used to be
	# needed for. (The seal still matters where the angle leaves real lanes —
	# see the VH/RVH hole tests in test_ai_action_scoring.)
	var ctx_up := _make_ctx(self_pos)
	var g_up := GoalieNetworkState.new()
	g_up.position_x = 0.85
	g_up.position_z = -26.55
	g_up.state_enum = GoalieStateMachine.State.STANDING as int
	ctx_up.snapshot.goalie_states[1 - TEAM_ID] = g_up
	var up := AIRoleCarrier.new()
	up.decide(ctx_up)
	assert_lt(up.debug_shoot_score, 0.10,
			"upright from the same sharp spot is no chance either — body depth walls it")


# ─── attacking blue-line keep-out bands ──────────────────────────────────────
# The offside puck-line is the TRUE blue line while the carrier reasons in
# body positions: the pass windup swings the carried puck a stick's reach
# behind the body, and reception plays the puck a reach around the receiver.
# Both bands (OZ_RETREAT_LINE_BUFFER_M / OZ_RECEIVE_LINE_BUFFER_M) exist so
# blue-line slop can't turn a completed play into a zone exit / offside.

func test_oz_valve_prunes_carry_candidates_in_the_blue_line_band() -> void:
	# Carrier established in the OZ (team 0 attacks -Z; OZ is z < -7.29).
	# A retreat candidate INSIDE the keep-out band (on the zone side of the
	# line but within windup reach of it) is pruned outright; a candidate
	# past the band scores normally.
	var self_pos := Vector3(0.0, 0.0, -12.0)
	var ctx := _make_ctx(self_pos)
	var c := AIRoleCarrier.new()
	c._build_action_opponents_lists(ctx)
	var in_band := Vector3(0.0, 0.0,
			-(GameRules.BLUE_LINE_Z + AIRoleCarrier.OZ_RETREAT_LINE_BUFFER_M * 0.5))
	var past_band := Vector3(0.0, 0.0,
			-(GameRules.BLUE_LINE_Z + AIRoleCarrier.OZ_RETREAT_LINE_BUFFER_M + 1.0))
	assert_eq(c._score_move_candidate(ctx, in_band, ctx.defending_goal_pos), -INF,
			"a retreat to within windup reach of the blue line is pruned")
	assert_gt(c._score_move_candidate(ctx, past_band, ctx.defending_goal_pos), -INF,
			"a retreat that keeps the windup envelope inside the zone stays legal")


func test_nz_carrier_may_target_entry_candidates_near_the_line() -> void:
	# The valve (and its band) only binds a carrier ALREADY in the zone —
	# an entry candidate just across the line must stay legal or the
	# carrier could never enter at all.
	var self_pos := Vector3(0.0, 0.0, -5.0)   # neutral zone
	var ctx := _make_ctx(self_pos)
	var c := AIRoleCarrier.new()
	c._build_action_opponents_lists(ctx)
	var just_inside := Vector3(0.0, 0.0, -(GameRules.BLUE_LINE_Z + 0.7))
	assert_gt(c._score_move_candidate(ctx, just_inside, ctx.defending_goal_pos), -INF,
			"an entry candidate in the band is not pruned from outside the zone")


func test_oz_pass_skips_receiver_hugging_the_blue_line() -> void:
	# Carrier in the OZ; the only teammate is wide open but his tape sits
	# just inside the blue line — reception slop there takes the puck out
	# of the zone, so he is excluded as a target entirely. The same open
	# man past the keep-out band is a legal (positive) feed.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(6.0, 0.0, -20.0)
	var at_line := Vector3(-2.5, 0.0, -(GameRules.BLUE_LINE_Z + 0.5))
	var skaters_line: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, at_line],
	]
	var ctx_line := _make_ctx(self_pos, skaters_line)
	ctx_line.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	var c_line := AIRoleCarrier.new()
	c_line._build_action_opponents_lists(ctx_line)
	var res_line: Array = c_line._compute_best_pass(ctx_line, Vector2(0.0, -1.0), [2])
	assert_eq(res_line[1], 0.0,
			"a receiver hugging the blue line is not a pass target from inside the zone")

	# Same carrier, receiver now a genuinely valuable target well past the
	# band (the far-post backdoor the squared goalie can't re-square onto —
	# the same feed test_passes_to_the_open_backdoor_man… proves positive).
	var deep := Vector3(-2.5, 0.0, -23.5)
	var skaters_deep: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, deep],
	]
	var ctx_deep := _make_ctx(self_pos, skaters_deep)
	ctx_deep.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	var c_deep := AIRoleCarrier.new()
	c_deep._build_action_opponents_lists(ctx_deep)
	var res_deep: Array = c_deep._compute_best_pass(ctx_deep, Vector2(0.0, -1.0), [2])
	assert_gt(res_deep[1], 0.0,
			"the same open man past the keep-out band is a legal feed")


# ─── close-quarters saucer variant ───────────────────────────────────────────

func test_close_quarters_pass_saucers_over_a_mid_lane_stick() -> void:
	# An 8 m feed whose flat lane is contested by a stick-range mid-lane
	# defender (off the line by more than a body radius). The old fixed
	# 10 m saucer floor kept this grounded; under the kinematic model a
	# SOFT flip (launch capped by the receivability bound) clears the
	# stick and lands with runway — the saucer variant should win the
	# per-receiver EV compete.
	var self_pos := Vector3(0.0, 0.0, 10.0)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(0.0, 0.0, 2.0)],    # receiver 8 m up-ice
			[3, 1, Vector3(0.7, 0.0, 6.5)],          # mid-lane stick, body off the line
	]
	var ctx := _make_ctx(self_pos, skaters)
	var c := AIRoleCarrier.new()
	c._build_action_opponents_lists(ctx)
	var res: Array = c._compute_best_pass(ctx, Vector2(0.0, -1.0), [2])
	assert_gt(res[1], 0.0, "the lofted feed rates as a real pass")
	assert_true(res[2], "close-quarters contested lane picks the saucer variant")


func test_short_feed_below_saucer_floor_stays_grounded() -> void:
	# Same shape at 5.5 m: even the softest legal flip (min wrister pace)
	# can't land with runway that short, so no saucer variant exists and
	# the pass stays flat whatever the lane looks like.
	var self_pos := Vector3(0.0, 0.0, 10.0)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(0.0, 0.0, 4.5)],    # receiver 5.5 m up-ice
			[3, 1, Vector3(0.7, 0.0, 7.5)],          # mid-lane stick
	]
	var ctx := _make_ctx(self_pos, skaters)
	var c := AIRoleCarrier.new()
	c._build_action_opponents_lists(ctx)
	var res: Array = c._compute_best_pass(ctx, Vector2(0.0, -1.0), [2])
	assert_false(res[2], "below the physical saucer floor the feed stays grounded")


func test_committed_saucer_pass_caps_launch_at_the_receivability_bound() -> void:
	# Full decide(): a neutral-zone carrier with a 9 m ahead-man behind a
	# mid-lane stick commits the saucer PASS, and the committed launch
	# speed is capped at the receivability bound for the distance — the
	# genuinely soft flip — never the crisp magnet pace that would arrive
	# still airborne and sail over the receiver's blade. A PASS_TO_ME ping
	# biases the compete toward the feed so the test pins the COMMIT path
	# deterministically (the variant selection itself is covered by the
	# _compute_best_pass tests above); the ping is a bias inside the same
	# scoring, so the committed pass is still the winning saucer variant.
	var self_pos := Vector3(3.0, 0.0, 5.0)
	var receiver := Vector3(3.0, 0.0, -4.0)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, receiver],
			[3, 1, Vector3(3.7, 0.0, 0.5)],          # mid-lane stick on the feed
			[4, 1, Vector3(1.5, 0.0, 7.0)],          # forecheckers pressuring the carry
			[5, 1, Vector3(4.5, 0.0, 6.5)],
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.ping_pass_target_peer = 2
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"pressured carrier feeds the outlet")
	assert_true(c.pass_should_saucer, "the contested lane picks the saucer")
	var bound: float = AIActionScoring.saucer_max_launch_speed(
			self_pos.distance_to(receiver))
	assert_lt(c.pass_target_speed, bound + 0.01,
			"committed saucer launch is capped so the flip lands before the tape")
	assert_gt(c.pass_target_speed,
			GameRules.DEFAULT_WRISTER_POWER_MIN_M_S - 0.01,
			"committed saucer launch stays at/above the soft-touch floor")


# ─── puck-protect mirror (blade shielding read by the state machine) ─────────

func test_open_ice_carrier_feels_no_protect_gain() -> void:
	# Nobody near the presented forward carry spot: shielding buys nothing, so the
	# gain is 0 and the state machine keeps the plain forward carry aim.
	var ctx := _make_ctx(Vector3(0, 0, 5))
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.protect_gain, 0.0, "open ice: the forward carry is already safe")
	assert_true(c.evade_seam_world.is_finite(),
			"the evasion seam is published for the deke cut")


func test_frontal_stick_threat_pulls_the_puck_behind_the_body() -> void:
	# A defender's stick parked right on the forward carry spot (2 m toward the
	# attacking net, -Z): full protect pressure, and the protect offset pulls
	# the puck to the far side of the body (+Z — back hip, body as the shield).
	var self_pos := Vector3(0, 0, 5)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, self_pos + Vector3(0, 0, -2.2)],   # stick on the presented puck
	]
	var ctx := _make_ctx(self_pos, skaters)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_gt(c.protect_gain, 0.5,
			"a stick on the presented spot, with a safe hip to hide it, is a strong shield")
	assert_gt(c.protect_offset.z, 0.5, "the puck pulls to the protected side of the body")


func test_protect_read_is_gated_by_the_cognition_tier() -> void:
	# Same frontal threat, protects_the_puck false (the Easy tier): the mirror
	# stays zeroed — the naive forward carry, poke-checks work by design.
	var self_pos := Vector3(0, 0, 5)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, self_pos + Vector3(0, 0, -2.2)],
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.protects_the_puck = false
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.protect_gain, 0.0, "the beginner tier never shields")
	assert_eq(c.protect_offset, Vector3.ZERO, "no protect offset on the beginner tier")


func test_beaten_defender_behind_does_not_hold_the_shield() -> void:
	# The reported bug: a carrier keeps protecting the puck (body turned side-on)
	# AFTER it has beaten the man pressuring it. A defender trailing directly
	# behind is within stick-reach of the presented forward puck, so the
	# undirected reach read scored it as full pressure and the shield stayed on —
	# even though the carrier's own body already screens the forward puck from a
	# man behind it. The directional filter drops a beaten/behind defender, so the
	# shield disengages and the carrier is free to square to the net.
	var self_pos := Vector3(0, 0, -15)   # in the offensive zone, driving at -Z net
	var behind: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(0, 0, -14.0)],   # 1 m behind (toward our end) — beaten
	]
	var cb := AIRoleCarrier.new()
	cb.decide(_make_ctx(self_pos, behind))
	assert_eq(cb.protect_gain, 0.0,
			"a beaten defender behind the carrier is screened for free — no shield")

	# Sanity: a stick in FRONT (goal-side) covering the presented puck is a genuine
	# threat and still shields hard, so the filter cuts by direction, not by
	# turning shielding off. 2.2 m ahead — the forward puck is inside his reach,
	# with a safe hip to hide it to.
	var front: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(0, 0, -17.2)],   # 2.2 m ahead, reach over the presented puck
	]
	var cf := AIRoleCarrier.new()
	cf.decide(_make_ctx(self_pos, front))
	assert_gt(cf.protect_gain, 0.5,
			"a stick on the forward puck still earns a strong shield; got %f"
			% cf.protect_gain)


func test_beaten_side_defender_still_shields() -> void:
	# The filter must not fire too early: a defender even/beside the carrier (not
	# yet skated past) is still a live stick and must keep earning the shield —
	# only a man clearly behind is screened for free. Defender abreast with a
	# stick-reach to the side: the forward puck is covered and the far hip is
	# safer, so shielding buys real safety and the gain stays positive.
	var self_pos := Vector3(0, 0, -15)
	var beside: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(2.2, 0, -15.0)],   # abreast, off the strong-side hip
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, beside))
	assert_gt(c.protect_gain, 0.15,
			"a defender abreast is not beaten — the shield still engages; got %f"
			% c.protect_gain)


# ─── OZ possession retention: cycle out instead of crashing the net ──────────

func test_covered_oz_carrier_cycles_out_instead_of_crashing() -> void:
	# Un-pended by the make-probability recalibration: passes on merit.
		# Sharp-angle corner carrier, goalie set and sealing the angle, a defender
	# boxing out between him and the net: every shot in reach reads ~0. The
	# possession-retention floor (OZ_POSSESSION_VALUE) makes safe ice the
	# gradient — the carrier pulls up and out of the sealed corner with the
	# puck instead of grinding a worthless drive into the crease, and never
	# fires a giveaway.
	var net := Vector3(0.0, 0.0, OPP_NET_Z)
	var self_pos := Vector3(9.0, 0.0, -24.0)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(7.5, 0.0, -24.8)],   # boxing out the net-side path
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"nothing worth firing — keep possession")
	assert_gt(c.last_carry_anchor.z, self_pos.z + 1.0,
			"the carry pulls up out of the sealed corner (cycle), not into the crease")


# ─── behind-the-net: post walkouts ────────────────────────────────────────────

func test_oz_carrier_behind_the_net_walks_out_around_a_post() -> void:
	# Retrieval spot behind the attacking cage: every ordinary candidate's
	# straight route crosses the frame (net-path prune), the possession floor
	# is withheld behind the line, so the post WALKOUT is the play — carry it
	# out front around a post instead of grinding on the mesh.
	var self_pos := Vector3(0.4, 0.0, OPP_NET_Z - 1.9)   # behind the -Z cage
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos))
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"nothing to fire from behind the cage — carry it out")
	assert_gt(absf(c.last_carry_anchor.x), GameRules.NET_HALF_WIDTH,
			"the anchor rounds a post")
	assert_gt(c.last_carry_anchor.z, OPP_NET_Z,
			"…onto the rink side of the goal line")


func test_dz_carrier_behind_own_net_walks_out_around_a_post() -> void:
	# The DZ behind-the-net carry (the regroup they like taking): the way back
	# into the play is the same post walkout — wall exits and the slot anchor
	# all chord through the own cage and prune.
	var self_pos := Vector3(0.4, 0.0, OUR_NET_Z + 1.9)   # behind our +Z cage
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos))
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"a clean regroup keeps the puck")
	assert_gt(absf(c.last_carry_anchor.x), GameRules.NET_HALF_WIDTH,
			"the anchor rounds a post")
	assert_lt(c.last_carry_anchor.z, OUR_NET_Z,
			"…out in front of our own goal line")


# ─── space creation: retreat ring + pass optionality ─────────────────────────

func test_pass_option_prefers_the_spot_that_reopens_the_lane() -> void:
	# Pure option read: same cached receiver, two candidate spots — one whose
	# lane to him is walled by a defender, one with a clear lane. The clear
	# spot inherits (a discounted cut of) the receiver's value.
	var ctx := _make_ctx(Vector3.ZERO)
	var c := AIRoleCarrier.new()
	c._scratch_option_receiver_pos.append(Vector3(-8.0, 0.0, 0.0))
	c._scratch_option_receiver_val.append(0.12)
	c._scratch_opponents.append(Vector3(-4.0, 0.0, 0.0))    # parked on the direct lane
	c._scratch_opponent_vels.append(Vector3.ZERO)
	c._scratch_opponent_caps.append(null)
	var blocked: float = c._candidate_pass_option(ctx, Vector3.ZERO)
	var open: float = c._candidate_pass_option(ctx, Vector3(0.0, 0.0, 8.0))
	assert_gt(open, blocked + 0.02,
			"the spot with the reopened lane inherits real receiver value")
	assert_lt(open, 0.12, "the option is a discounted cut, never par with a live pass")


func test_pinched_carrier_peels_out_to_reopen_the_ice() -> void:
	# Un-pended by the meeting-strip crossing band (measured, protection-
	# aware): the OPPOSED wall splits the protect budget to nothing, so the
	# grind into the pinch prices as the strip it is.
	# Double-team pinch in the OZ: a GENUINE wall dead ahead (the two defenders
	# tight together, no splittable seam to the slot), a teammate open wide. The
	# best RESOLUTION is moving the puck to the open man while the carry argmax
	# peels OUT of the pinch. (A wall with a real 3.6 m gap up the middle is
	# correctly SPLIT to the slot instead — see the split test below.)
	var self_pos := Vector3(0.0, 0.0, -18.0)               # OZ, attacking -Z
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(-7.0, 0.0, -17.0)],        # open man out wide
			[3, 1, Vector3(-0.9, 0.0, -19.6)],              # tight wall dead center —
			[4, 1, Vector3(0.9, 0.0, -19.6)],               # no seam to split to the slot
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(
			self_pos, Vector3(0.0, 0.0, OPP_NET_Z), 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"the pinch is beaten by moving the puck to the open man")
	assert_eq(c.pass_target_peer_id, 2, "…the wide teammate is the outlet")
	assert_gt(c.debug_carry_pos.z, self_pos.z + 2.0,
			"and the carry argmax peels OUT of the pinch, never the grind into it")


func test_carrier_splits_a_beatable_gap_to_the_slot() -> void:
	# Same OZ setup as the pinch above, but the two defenders leave a real gap up
	# the middle (a splittable seam). With the OZ possession floor riding
	# slot_progress, the slot-ward drive out-scores backing out — the carrier
	# attacks the seam toward the net instead of pacifying. This is the behaviour
	# the goal-line-drift feedback asked for.
	var self_pos := Vector3(0.0, 0.0, -18.0)               # OZ, attacking -Z
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(-7.0, 0.0, -17.0)],
			[3, 1, Vector3(-1.8, 0.0, -19.6)],              # 3.6 m gap up the middle
			[4, 1, Vector3(1.8, 0.0, -19.6)],
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(
			self_pos, Vector3(0.0, 0.0, OPP_NET_Z), 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_lt(c.last_carry_anchor.z, self_pos.z - 1.0,
			"drives the seam toward the net rather than backing out of it")


func test_carrier_does_not_park_at_the_dead_angle_goal_line() -> void:
	# The dead-angle SHOT now correctly reads ~0 (the #28 erasure + deployment
	# gate — see test_wide_angle_shot_is_not_taken, which un-pended on it). But
	# this fixture pins the CARRY not parking there, and the safe dead corner
	# still wins the carry compete: with no shot of its own it is credited as a
	# SAFE waypoint (the continuation value drives corner→slot), out-scoring the
	# contested middle drive past the inside defender.
	# Un-pended by the continuation RE-SET pricing: the second leg is read
	# against a defense that collapses onto the slot during the first leg's
	# dwell (_project_opponents_collapsing), so corner-then-slot no longer
	# inherits the slot's value for free and the honest middle drive wins.
	# The reported bug: enter the zone down the wing with a defender on the inside,
	# and the carrier drifts down the boards to the dead-angle goal-line corner and
	# does nothing — because the old, higher flat possession floor made the safe
	# corner read as good as the slot. With the floor dropped to a noise epsilon,
	# pure xG drives: the slot reads high and the dead-angle corner reads ~0, so the
	# carrier works toward the net instead of parking at the goal line.
	# A wing ENTRY carries net-ward momentum (not a standstill): the momentum-aware
	# ETA then reads the middle-ward cut as cheaply reachable and the boards drift as
	# a needless reversal, so it drives the puck to a real angle instead of drifting.
	var self_pos := Vector3(8.0, 0.0, -18.0)               # wing entry, OZ
	var vel := Vector3(-1.0, 0.0, -3.0)                    # driving in off the wing
	var skaters: Array = [
			[1, TEAM_ID, self_pos, false, vel],
			[3, 1, Vector3(3.0, 0.0, -20.0)],              # defender on the inside lane
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.self_velocity = vel
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(
			self_pos, Vector3(0.0, 0.0, OPP_NET_Z), 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	# Not parked down at the goal line: the winning carry keeps a real shooting
	# angle, well up off the dead corner the flat floor used to lure it to.
	assert_lt(absf(c.last_carry_anchor.z), GameRules.GOAL_LINE_Z - 3.0,
			"the carry stays off the goal line instead of drifting to the dead corner")
	assert_lte(absf(c.last_carry_anchor.x), self_pos.x + 0.01,
			"and works toward the middle, not further into the boards")


# ─── fake-then-cut deke mirror ────────────────────────────────────────────────

func test_patient_container_arms_the_deke_read() -> void:
	# A league-agility defender parked in the duel range dead ahead on the
	# objective line, nobody moving — the classic containment stalemate. The
	# carrier's re-eval should arm the deke: fake one way, cut the other
	# (the two committed directions oppose laterally by construction).
	var self_pos := Vector3(0.0, 0.0, -14.0)             # OZ, attacking -Z
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(0.0, 0.0, -17.6)],            # ~2.3 m off the carried puck
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.protects_the_puck = true
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_true(c.deke_go, "a patient container in range arms the manufactured-opening read")
	assert_lt(c.deke_fake_dir.dot(c.deke_cut_dir), 0.0,
			"the fake sells one side, the cut explodes the other")


func test_no_deke_read_against_a_committed_charger() -> void:
	# Same spot, but the defender is charging in hard — committed pressure is
	# the brake check / seam's moment, not a fake's (he's already biting).
	var self_pos := Vector3(0.0, 0.0, -14.0)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(0.0, 0.0, -17.6), false, Vector3(0, 0, 7)],
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.protects_the_puck = true
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_false(c.deke_go, "committed pressure never reads as a fake target")


# ─── carry continuation credit (the two-ply read) ─────────────────────────────
# A candidate is worth the best thing it lets the carrier DO next
# (_carry_continuation_value — the pass option's skating twin). Probe data
# behind these pins: one step deep, against a set goalie, the cut-in and the
# lateral escape both read ≈ the possession floor and safety alone picked the
# perimeter orbit; the slot drive FROM the cut-in read ~3× the one from the
# lateral spot — the transient opening a beaten man concedes only prices in
# on the step after the cut.


func test_spun_off_carrier_attacks_the_opening() -> void:
	# The moment after beating a man: carrier driving toward the net (momentum
	# net-ward, cutting off the wing to the middle), the beaten defender dead in
	# the water behind. The continuation credit turns that drive into a committed
	# route TOWARD the net instead of a safety orbit around the perimeter.
	# (Momentum matters: time_to_arrive charges the cost of shedding sideways
	# speed, so this is a carrier whose momentum already POINTS at the cut — a
	# carrier moving laterally AWAY couldn't reach the same cut without first
	# reversing, and the beaten man would recover into it; see the momentum-aware
	# ETA. That honest read is what test_continuation_credit_respects_live_
	# containment leans on below.)
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(6.0, 0.0, -15.0)
	var vel := Vector3(-2.0, 0.0, -4.0)
	var skaters: Array = [
			[1, TEAM_ID, self_pos, false, vel],
			[3, 1, Vector3(4.5, 0.0, -14.0), false, Vector3.ZERO],
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.self_velocity = vel
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"no direct shot from the wing vs a set keeper — the play is the route")
	assert_gt(self_pos.distance_to(net) - c.last_carry_anchor.distance_to(net), 1.0,
			"the committed anchor cuts IN toward the net, not around the perimeter")
	# The decisive ordering: the cut-in behind the beaten man out-scores the
	# lateral escape that used to win on safety alone.
	var our_goalie := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z)
	var cut_in: Vector3 = self_pos + (net - self_pos).normalized() * 3.0
	var lateral := Vector3(8.2, 0.0, -17.0)
	var cut_score: float = c._score_move_candidate(ctx, cut_in, our_goalie)
	assert_gt(cut_score, c._score_move_candidate(ctx, lateral, our_goalie),
			"the cut-in's continuation beats the lateral escape's marginal safety")
	# "Not argmax-over-noise" means the plan has to beat DOING NOTHING by a
	# real margin — stand-still is the noise floor, and it is in the compete
	# already. An absolute bar could only ever encode the currency's scale.
	var stand_score: float = c._score_move_candidate(ctx, self_pos, our_goalie)
	assert_gt(cut_score, stand_score * 2.0,
			"…and it is a real plan, not argmax-over-noise — multiples of standing still; %f vs %f"
			% [cut_score, stand_score])


func test_continuation_credit_respects_live_containment() -> void:
	# Same net-ward drive, but the defender is LIVE in the cut lane — ahead on the
	# inside, skating with the carrier to hold it. The continuation collapses
	# through the second leg's reach safety (no phantom aggression): the cut reads
	# contested and the compete keeps cycling to space instead of forcing it.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(6.0, 0.0, -15.0)
	var vel := Vector3(-2.0, 0.0, -4.0)
	var skaters: Array = [
			[1, TEAM_ID, self_pos, false, vel],
			[3, 1, Vector3(3.5, 0.0, -18.0), false, Vector3(-1.5, 0.0, -1.5)],
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.self_velocity = vel
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	var our_goalie := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z)
	var cut_in: Vector3 = self_pos + (net - self_pos).normalized() * 3.0
	var lateral := Vector3(8.2, 0.0, -17.0)
	assert_gt(c._score_move_candidate(ctx, lateral, our_goalie),
			c._score_move_candidate(ctx, cut_in, our_goalie),
			"a live defender in the cut lane still owns it — cycle, don't force")


# ─── Phase B (docs/breakout-plan.md): wheel, rim family, the Over ────────────

func test_behind_net_carrier_wheels_to_the_far_wall_in_5v5() -> void:
	# Retriever behind our own net with a committed chaser closing from the
	# +x side and the strong-side front covered — the wheel around the cage
	# to the far half-wall is the researched out, and only the two-leg apex
	# candidate can represent it (every straight far-side route crosses the
	# cage and prunes).
	# The wheel's real trigger: the retriever is already moving with a step
	# on his chaser, who trails in his wake (committed to the same line —
	# the escape gate reads him as beaten). The strong-side front is
	# covered, so turning up the near side means the wall battle.
	var self_pos := Vector3(2.0, 0, 27.6)
	var self_vel := Vector3(-4.0, 0, 0.4)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, false, self_vel],
		[3, 1, Vector3(4.6, 0, 27.4), false, Vector3(-4.2, 0, 0)],
		[4, 1, Vector3(4.5, 0, 22.0)],
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.self_velocity = self_vel
	ctx.team_size = 5
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"the wheel is a carry, not a panic release")
	assert_lt(c.last_carry_anchor.x, -5.0,
			"the carry exits on the FAR side of the cage")
	assert_lt(c.last_carry_anchor.z, 22.0,
			"...up the far wall, not a near-post step")


func test_wheel_is_5v5_exclusive() -> void:
	# The identical situation in 3v3 has no wheel candidate (plan §5:
	# possession-first 3v3 keeps its shipped option set).
	var self_pos := Vector3(2.0, 0, 27.6)
	var self_vel := Vector3(-4.0, 0, 0.4)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, false, self_vel],
		[3, 1, Vector3(4.6, 0, 27.4), false, Vector3(-4.2, 0, 0)],
		[4, 1, Vector3(4.5, 0, 22.0)],
	]
	var ctx := _make_ctx(self_pos, skaters)
	ctx.self_velocity = self_vel
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_false(c.last_carry_anchor.x < -5.0 and c.last_carry_anchor.z < 22.0,
			"no far-wall wheel exit exists in 3v3")


func _rim_ctx(team_size: int, wall_lane_blocked: bool) -> RoleContext:
	# Carrier pinned on our own wall by two forecheckers; the wall winger is
	# posted up the boards on the rim's path; the rest of the ice is deep.
	# The forecheck pins from the INSIDE shoulder (angling the carrier to
	# the wall — the real geometry), which is exactly what leaves the wall
	# lane itself as the one protected out.
	var self_pos := Vector3(10.5, 0, 24.0)
	var skaters: Array = [
		[1, TEAM_ID, self_pos],
		[2, TEAM_ID, Vector3(10.5, 0, 14.0)],
		[3, 1, Vector3(8.8, 0, 23.0)],
		[4, 1, Vector3(9.0, 0, 25.8)],
		[5, 1, Vector3(0.0, 0, 15.0)],
	]
	if wall_lane_blocked:
		skaters.append([6, 1, Vector3(11.7, 0, 12.0)])
	var ctx := _make_ctx(self_pos, skaters)
	ctx.team_size = team_size
	return ctx


func test_own_zone_clear_is_a_flat_rim_when_the_wall_lane_is_open() -> void:
	var ctx := _rim_ctx(5, false)
	var c := AIRoleCarrier.new()
	c._build_action_opponents_lists(ctx)
	var r: Array = c._best_dump(ctx, ctx.defending_goal_pos)
	assert_true(r[3], "open wall lane + posted winger → the clear is the FLAT rim")
	# The delivery out-prices the shipped zero-gain concession (3v3 shape).
	var ctx3 := _rim_ctx(3, false)
	var c3 := AIRoleCarrier.new()
	c3._build_action_opponents_lists(ctx3)
	var r3: Array = c3._best_dump(ctx3, ctx3.defending_goal_pos)
	assert_gt(r[0], r3[0],
			"a manned wall post makes the clear worth more than a giveaway")
	assert_false(r3[3], "3v3 keeps the shipped chip — no rim delivery")


func test_behind_net_clear_rides_the_boards_not_the_chord() -> void:
	# Retriever picks up BEHIND our net with the forecheck committed — the
	# breakout harness's compete moment. The chord from there to the
	# center-boards clear target threads the middle of our own zone
	# (blocked by the forecheck, loss point in front of our net) and
	# priced the clear at ~−0.4 exactly when doctrine says it's the right
	# play; the real rim rides the boards out of the corner. The routed
	# delivery must read as the good play it is: clearly positive.
	var self_pos := Vector3(2.0, 0, 28.2)
	var ctx := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(10.5, 0, 14.0)],      # wall winger posted
			[3, 1, Vector3(3.5, 0, 25.8)],             # F1 chasing net-front
			[4, 1, Vector3(6.5, 0, 22.0)],             # F2 inside shoulder
			[5, 1, Vector3(0.0, 0, 15.0)]])            # high man in the middle
	ctx.team_size = 5
	var c := AIRoleCarrier.new()
	c._build_action_opponents_lists(ctx)
	var r: Array = c._best_dump(ctx, ctx.defending_goal_pos)
	assert_gt(r[0], 0.0,
			"the boards-routed clear reads positive under a committed forecheck")
	assert_true(r[3], "and it is the flat rim — the wall path is the protected lane")


func test_rim_falls_back_to_the_chip_over_a_camped_wall_lane() -> void:
	var ctx := _rim_ctx(5, true)
	var c := AIRoleCarrier.new()
	c._build_action_opponents_lists(ctx)
	var r: Array = c._best_dump(ctx, ctx.defending_goal_pos)
	assert_false(r[3],
			"a stick camped on the wall lane kills the rim — chip over everything")


func test_developing_feed_watches_the_over_valve_in_5v5() -> void:
	# The OVER: the partner D swinging across the TOP of our zone (the legal
	# D-to-D lane over the slot box's upper edge) is a developing feed worth
	# a beat of protection — same primitive as the wall outlet, now watched
	# for BREAKOUT_D2 (5v5-inherent: the slot only exists there). The
	# behind-net Over remains unrepresentable by the own-goal-risk zeros
	# (lead-past-our-line + net-blocker) — pended in the plan doc.
	# Lane staged above the HOME-PLATE slot veto's upper edge (widened to
	# 2.75 × 6.0 in 534f534 — the watch prices the future feed through the
	# same veto, so a lane inside the deeper rect now honestly reads dead).
	var self_pos := Vector3(10.0, 0, 20.0)
	var ctx := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(-4.0, 0, 19.2), false, Vector3(-2.0, 0, 0.6)]])
	var brain := TeamBrain.new(TEAM_ID, ctx.team_id_by_peer)
	brain.slot_assignments[2] = AIRoleSlots.Slot.BREAKOUT_D2
	ctx.team_brain = brain
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_gt(carrier._best_developing_feed(ctx), 0.0,
			"a partner skating to the net-back valve is a developing Over")


func test_no_direct_shot_from_on_or_behind_the_goal_line() -> void:
	# The "skate past the goal line and clank the outer bar" bug: a carrier whose
	# body is BEHIND the goal line, skating out, had its velocity-projected blade
	# release land a hair in front and clamp to a phantom point-blank open net —
	# scoring a zero-angle rip off the outer pipe. The mouth faces up-ice; from back
	# there the only play is a wrap/walk-out carry, so the direct shot must not
	# score at all.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var behind := Vector3(0.6, 0.0, -(GameRules.GOAL_LINE_Z + 0.6))   # behind the net
	var ctx := _make_ctx(behind, [[1, TEAM_ID, behind]])
	ctx.self_velocity = Vector3(0.0, 0.0, 6.0)                        # skating out toward the line
	ctx.snapshot.puck_state.position = behind
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(behind, net, 1.0)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_lt(c.debug_shoot_score, 0.001,
			"no direct shot is scored from on/behind the goal line; got %f" \
			% c.debug_shoot_score)
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_SHOOT,
			"the behind-the-net carrier wraps/carries, never rips the outer pipe")


func test_in_front_shot_still_scores_through_the_gate() -> void:
	# The gate is position-specific, not a blanket shot kill: a carrier genuinely in
	# front (in tight, with the keeper beaten to one side) still gets a real shot.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var slot := Vector3(0.0, 0.0, -(GameRules.GOAL_LINE_Z - 5.0))     # 5 m out, dead slot
	var ctx := _make_ctx(slot, [[1, TEAM_ID, slot]])
	ctx.snapshot.puck_state.position = slot
	var g := GoalieNetworkState.new()
	g.position_x = 0.75                                              # beaten to the +x side
	g.position_z = net.z + 1.3
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_gt(c.debug_shoot_score, 0.0,
			"an in-tight look at a beaten keeper still scores a shot; got %f" \
			% c.debug_shoot_score)


# ── Behind the net: a carrier back there needs moves to choose between ───────
# The candidate rings used to prune everything past the goal line, which left a
# carrier behind the cage with two post walkouts and stand-still. Under pressure
# both walkouts read unsafe and the compete fell to stand-still — the bot planted
# itself on the end wall and got stripped. These pin the representation, not a
# preference: the lateral walk back there exists, and the cage is still a wall.

func test_behind_net_candidates_exist_for_a_carrier_behind_the_goal_line() -> void:
	# Behind the opposing cage: |z| is BEYOND the goal line, so z is more
	# negative than OPP_NET_Z.
	var behind := Vector3(3.0, 0.0, OPP_NET_Z - 1.6)
	var c := AIRoleCarrier.new()
	assert_true(c._candidate_ice_legal(
			Vector3(-3.0, 0.0, behind.z), true),
			"the walk across the back of the cage is a representable move")
	assert_true(c._candidate_ice_legal(
			Vector3(6.0, 0.0, behind.z + 1.0), true),
			"so is working out toward the corner")


func test_the_cage_itself_is_still_not_a_place_to_stand() -> void:
	var c := AIRoleCarrier.new()
	assert_false(c._candidate_ice_legal(
			Vector3(0.0, 0.0, OPP_NET_Z - GameRules.NET_DEPTH * 0.5), true),
			"inside the goal frame is not ice")


func test_behind_net_candidates_stay_on_the_playing_surface() -> void:
	var c := AIRoleCarrier.new()
	assert_false(c._candidate_ice_legal(
			Vector3(3.0, 0.0, -(GameRules.INNER_HALF_LENGTH + 0.5)), true),
			"through the end boards is not ice")
	assert_false(c._candidate_ice_legal(
			Vector3(GameRules.CORNER_CENTER_X + GameRules.INNER_CORNER_RADIUS,
					0.0, GameRules.CORNER_CENTER_Z + 3.0), true),
			"and the rounded corner is honoured, not a bounding box")


func test_a_carrier_out_front_keeps_the_old_goal_line_clamp() -> void:
	# Scoped change: nothing about front-of-net carrying moves.
	var c := AIRoleCarrier.new()
	assert_false(c._candidate_ice_legal(
			Vector3(3.0, 0.0, OPP_NET_Z - 1.6), false),
			"a carrier in front never plans a step past the goal line")
	assert_true(c._candidate_ice_legal(Vector3(3.0, 0.0, -18.0), false))
