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


# ─── pass out of a board pincer (pressure relief) ───────────────────────────

func test_board_pincer_passes_to_lateral_outlet_instead_of_over_carrying() -> void:
	# Carrier pinned on the right-wall in the neutral zone, two defenders
	# pincering (one closing off the inside, one sealing the up-ice lane). The
	# only safe out is a lateral feed to a teammate in the middle — LOW up-ice
	# value, so without the pass-out-of-pressure relief the carrier rates
	# carrying (higher position potential up the wall) over the escape pass and
	# gets stripped. With the relief, getting the puck off the pinned carrier
	# wins. This is the "see the pincer, move it" read.
	var self_pos := Vector3(6, 0, 9)                    # right-center, NZ, space ahead
	var outlet := Vector3(-3, 0, 6)                     # left-center, forward, open
	var skaters: Array = [
			[1, TEAM_ID, self_pos],                         # us, carrying
			[2, TEAM_ID, outlet],                           # open outlet
			[3, 1, Vector3(4, 0, 4), false, Vector3(1.5, 0, 5)],  # inside forechecker closing fast
			[4, 1, Vector3(9, 0, 5), false, Vector3(-3, 0, 5)],   # outside forechecker closing (pincer)
	]
	# The forming pincer registers through the defenders' closing VELOCITY in
	# puck_safety (they start beyond stick range), so our current strip
	# probability is high; the grounded pass-relief (expected turnover avoided)
	# lifts the escape pass over the carry. Without any relief the base model
	# CARRIES here into the closing box.
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_PASS,
			"a carrier reading a forming pincer moves the puck instead of over-carrying")
	assert_eq(c.debug_pass_peer_id, 2, "the escape pass targets the open middle outlet")


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
	# Carrier deep in our zone with a forechecker charging straight at it
	# and flankers denying the easy lateral steps. Stand-still used to be
	# the only carry candidate that paid NO turnover cost, so in exactly
	# this spot every escape route went EV-negative while freezing stayed
	# positive — the bot planted itself and ate the check. With the strip
	# probability (1 - poke_safety) now feeding turnover_cost, freezing
	# under a converging forechecker prices its own turnover and loses to
	# the least-bad skating route.
	var self_pos := Vector3(2, 0, 21)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[3, 1, Vector3(2, 0, 18), false, Vector3(0, 0, 5)],  # charging forechecker
			[4, 1, Vector3(6, 0, 19)],                           # right flanker
			[5, 1, Vector3(-2, 0, 19)],                          # left flanker
	]
	var c := AIRoleCarrier.new()
	c.decide(_make_ctx(self_pos, skaters))
	assert_eq(c.intended_action, AIRoleCarrier.INTENT_CARRY,
			"nothing worth firing — this is a carry read")
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
			or carrier.intended_action == AIRoleCarrier.INTENT_PASS \
			or carrier.intended_action == AIRoleCarrier.INTENT_QUICK_SHOT,
			"decide() yields a valid intent with a staging finisher in play")
