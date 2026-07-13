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
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var carrier := Vector3(0.0, 0.0, 2.0)
	var mate := Vector3(3.0, 0.0, -3.0)                  # open, reasonable spot
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
	# forward lane clear, so the carry keeps far more of its value than when the
	# defender blocks the path ahead.
	var beside: Array = [
			[1, TEAM_ID, carrier], [2, TEAM_ID, mate], [11, 1, Vector3(7.0, 0.0, -2.0)]]
	var bc := _make_ctx(carrier, beside)
	bc.snapshot.goalie_states[1 - TEAM_ID] = g
	var b := AIRoleCarrier.new()
	b.decide(bc)
	assert_gt(b.debug_carry_score, a.debug_carry_score * 1.3,
			"a side defender leaves the carry worth much more than a forward one blocking the path")


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
	# whose execution-miss mode (PASS_MISS_PROB, loss point past the
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

	# Contrast: the SAME teammate, moved INTO the zone on a comparable lane, is a
	# legal receiver again — confirming it was the zone exclusion suppressing the
	# pass, not a bad lane.
	var oz_mate := Vector3(6, 0, -14)                      # now in the O-zone
	var skaters_in: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, oz_mate],
			[3, 1, Vector3(0, 0, -15)],
	]
	var c2 := AIRoleCarrier.new()
	c2.decide(_make_ctx(self_pos, skaters_in))
	assert_gt(c2.debug_pass_score, 0.0,
			"an in-zone teammate on the same kind of lane IS a legal pass target")


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
	# The bootstrap: a flat-footed carrier alone with a keeper at a NORMAL
	# challenge depth (1.3 m — deep enough that a blade-reach relocation alone
	# doesn't beat him; the 2 m over-challenge dies to the pull-around, test
	# above) has no direct shot worth taking — but the carry candidates price
	# ARRIVING AT PACE (the two-phase keeper in _score_move_candidate), so
	# "skate the cut, then fire" reads as a real plan and the bot commits
	# to a LATERAL wind-up instead of dithering over an all-zero candidate
	# ring. Once moving, the mid-cut fire takes over (test above).
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var self_pos := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z + 3.0)
	var ctx := _make_ctx(self_pos)
	ctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(self_pos, net, 1.3)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"no direct shot flat-footed — the play is the setup carry")
	assert_gt(absf(c.last_carry_anchor.x), 2.0,
			"…and the setup is a LATERAL wind-up, not a drive into the smother")
	assert_gt(c.debug_carry_score, 0.2,
			"the priced cut is a real plan, not argmax-over-noise; got %f"
			% c.debug_carry_score)

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
	assert_lt(cf.debug_shoot_score, 0.05,
			"…because range opens no real direct window; got %f"
			% cf.debug_shoot_score)
	assert_gt(cf.debug_carry_score, cf.debug_shoot_score,
			"…and the priced plan (drive to the shooting band) beats flinging it")
	assert_lt(cf.last_carry_anchor.z, far_pos.z,
			"…with an anchor that advances toward the net, not an orbit")


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
	var pos := Vector3(-1.2, 0.0, -22.65)
	var ctx := _make_ctx(pos)
	var g := GoalieNetworkState.new()
	g.position_x = -1.1
	g.position_z = -25.2
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_gt(c._shot_sample_offset.x, 0.3,
			"the winning sample relocates the release toward the open (forehand) side")
	assert_false(c._shot_sample_backhand, "…on the forehand, at full pace")
	assert_gt(c.debug_shoot_score, 0.5,
			"…and the relocated look is a genuine chance; got %f" % c.debug_shoot_score)

	# Mirrored geometry (goalie on the FOREHAND side): the same relocation is
	# now a BACKHAND-side move, so it pays the pace penalty and the blade-travel
	# time — and the simple release already sees the opening the goalie's
	# displacement concedes. The honesty terms keep the simple release on top.
	var mpos := Vector3(1.2, 0.0, -22.65)
	var mctx := _make_ctx(mpos)
	var mg := GoalieNetworkState.new()
	mg.position_x = 1.1
	mg.position_z = -25.2
	mctx.snapshot.goalie_states[1 - TEAM_ID] = mg
	var mc := AIRoleCarrier.new()
	mc.decide(mctx)
	assert_almost_eq(mc._shot_sample_offset.length(), 0.0, 0.001,
			"mirrored: the backhand relocation's pace/time cost keeps the simple release")
	assert_gt(mc.debug_shoot_score, 0.5,
			"…which already sees the conceded far side; got %f" % mc.debug_shoot_score)


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
	# A shot from a wide angle (off to the side, out toward the boards) is not a real
	# chance when the goalie has tracked the carrier and is square — the net is
	# foreshortened and the keeper covers the near side. The direct shot must be
	# scored against that SQUARED goalie (he read the carry the whole way), not a
	# react-then-slide keeper left a step behind — otherwise the bot fires from
	# nowhere. A dead-slot look at the same SET keeper is the modest quick-release
	# window (the puck beats his drop to his body) — real, but well short of the
	# genuine chance the same slot offers against a keeper who is OFF the line
	# (still squared to where the carrier used to be).
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var wide := Vector3(9.0, 0.0, -22.0)                  # ~10 m out, sharp angle
	var wctx := _make_ctx(wide)
	wctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(wide, net, 1.3)
	var wc := AIRoleCarrier.new()
	wc.decide(wctx)
	assert_lt(wc.debug_shoot_score, AIRoleCarrier.FIRE_MIN_VALUE,
			"a wide-angle shot vs a squared goalie is below the fire floor; got %f"
			% wc.debug_shoot_score)

	var slot := Vector3(0.0, 0.0, -22.0)                 # same range, dead slot
	var sctx := _make_ctx(slot)
	sctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(slot, net, 1.3)
	var sc := AIRoleCarrier.new()
	sc.decide(sctx)
	assert_between(sc.debug_shoot_score, AIRoleCarrier.FIRE_MIN_VALUE, 0.3,
			"a dead-slot look at a SET goalie is a real but modest option; got %f"
			% sc.debug_shoot_score)

	var dctx := _make_ctx(slot)
	# Keeper still squared to the WIDE spot — the carrier's cross-ice relocation
	# beat his re-square; the same slot look is now a genuine chance.
	dctx.snapshot.goalie_states[1 - TEAM_ID] = _squared_goalie(wide, net, 1.3)
	var dc := AIRoleCarrier.new()
	dc.decide(dctx)
	assert_gt(dc.debug_shoot_score, AIRoleCarrier.FIRE_MIN_VALUE * 3.0,
			"the slot look vs a displaced keeper clears the floor comfortably; got %f"
			% dc.debug_shoot_score)
	assert_gt(dc.debug_shoot_score, sc.debug_shoot_score,
			"…and displacement is always worth more than the set-keeper window")


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
	# so the next decide() re-evaluates.
	var c := AIRoleCarrier.new()
	var ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, -22.0))

	c.decide(ctx)  # tick 0: runs _pick_action
	# Drain the cooldown.
	for i in range(AIRoleCarrier.PICK_ACTION_PERIOD_TICKS):
		c.decide(ctx)
	# Force-flip and call once more: should re-run _pick_action and
	# overwrite our flip.
	c.intended_action = AIRoleCarrier.INTENT_PASS
	c.decide(ctx)

	# After re-eval the carrier picks based on the snapshot. The exact
	# winning intent depends on scoring math (covered in
	# test_ai_action_scoring); the contract here is just "_pick_action
	# ran and overwrote our manual flip."
	assert_ne(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"decide() should re-run _pick_action after cooldown elapses, replacing the manually-set intent")


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
	var pos := Vector3(0.0, 0.0, -15.0)
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
	return ctx


func test_developing_feed_zero_without_brain() -> void:
	var ctx := _make_ctx(Vector3(4, 0, -18))
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_eq(carrier._best_developing_feed(ctx), 0.0,
			"no team brain → nothing to wait for")


func test_developing_feed_zero_when_finisher_already_ready() -> void:
	# Already-flagged finisher is fed by normal scoring — not something to hold for.
	var ctx := _ctx_with_finisher(Vector3(-3, 0, -19), true)
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_eq(carrier._best_developing_feed(ctx), 0.0)


func test_developing_feed_positive_for_staging_cross_seam_finisher() -> void:
	var ctx := _ctx_with_finisher(Vector3(-3, 0, -19), false)
	var carrier := AIRoleCarrier.new()
	carrier._scratch_teammate_ids = [2]
	assert_gt(carrier._best_developing_feed(ctx), 0.0,
			"a staging cross-seam finisher gives a positive developing feed")


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
	driving.snapshot.skater_states[2].velocity = Vector3(-0.5, 0, -7.0)
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
	var fin_pos := Vector3(-5, 0, -15.0)
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
			[2, TEAM_ID, Vector3(-5, 0, -15.0), false, Vector3(2.0, 0, -7.5)],
			[3, TEAM_ID, Vector3(6, 0, -6.3)],       # support high at the line
			[11, 1, Vector3(-1.5, 0, -20.0)],        # set D box
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
	var ctx := _ctx_with_finisher(Vector3(-3, 0, -19), false)
	var carrier := AIRoleCarrier.new()
	var d := carrier.decide(ctx)
	assert_not_null(d)
	assert_true(carrier.intended_action == AIRoleCarrier.INTENT_CARRY \
			or carrier.intended_action == AIRoleCarrier.INTENT_SHOOT \
			or carrier.intended_action == AIRoleCarrier.INTENT_PASS,
			"decide() yields a valid intent with a staging finisher in play")


# ─── dumping: last-resort relief in two specific spots ───────────────────────

func test_pinned_dz_carrier_dumps_to_clear() -> void:
	# Deep in our slot, genuinely pinned: a forechecker charging up the middle
	# and both flanks sealed — no open skating lane, no pass outlet. The honest
	# strip-point carry pricing reads every route as a turnover in front of our
	# own net (raw carry below the safe-giveaway floor), so the DZ clear wins:
	# fling it off the strong-side boards, out of the zone, and race for it —
	# a hard flat clear, not a soft flip. This is the "would otherwise stand
	# there and be stripped" moment the dump exists for.
	var self_pos := Vector3(6, 0, 24)                      # deep slot, swarmed
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(6, 0, 21), false, Vector3(0, 0, 5)],
			[4, 1, Vector3(3, 0, 22.5)],
			[5, 1, Vector3(9, 0, 22.5)],
	]
	var ctx: RoleContext = _make_ctx(self_pos, skaters)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_DUMP,
			"a pinned own-zone carrier clears the puck rather than eat the strip")
	assert_false(c.dump_is_soft, "a DZ clear is a hard flat fling, not a soft flip")
	assert_gt(c.dump_target.x, 0.0, "cleared off the strong-side boards (carrier's side)")
	assert_false(
			AIActionScoring.in_offensive_zone(c.dump_target, ctx.defending_goal_pos),
			"the clear takes the puck out of our defensive zone")


func test_contained_past_center_with_no_outlet_dumps_in() -> void:
	# Carrier past centre, walled off short of the blue line with no outlet. Can't
	# carry in, nothing to pass — dump-and-chase into the far corner.
	var self_pos := Vector3(2, 0, -4)                      # attacking half (attack -Z), pre-blue
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(2, 0, -5), false, Vector3(0, 0, -4)],  # D stepping up on us
			[4, 1, Vector3(-1, 0, -5.5)],                      # D sealing the lane across
	]
	var ctx: RoleContext = _make_ctx(self_pos, skaters)
	var c := AIRoleCarrier.new()
	c.decide(ctx)
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_DUMP,
			"dumps in when the zone entry is walled off")
	assert_true(c.dump_is_soft, "a dump-in is a soft flip to the corner")
	assert_true(
			AIActionScoring.in_offensive_zone(c.dump_target, ctx.attacking_goal_pos),
			"the dump target is in the offensive zone")
	assert_lt(c.dump_target.x, 0.0, "the FAR corner, opposite the carrier's side")


func test_carrier_with_a_clean_outlet_does_not_dump() -> void:
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
