extends GutTest

# AIRoleContain — TRANS_OD-only last man back: gap control on the carrier.
# Target is goal-side of the carrier on the carrier→our-net line, at a gap
# that tightens as the carrier nears the net. Tests cover:
#   - Loose puck → contain its spot (don't freeze).
#   - Target is goal-side of the carrier (between carrier and our net).
#   - Gap tightens as the carrier closes on the net.
#   - Never retreats behind our own goal line.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65


func _make_ctx(self_pos: Vector3, skaters: Array = [],
		carrier_pid: int = -1) -> RoleContext:
	var snap := WorldSnapshot.new()
	if skaters.is_empty():
		var s := SkaterNetworkState.new()
		s.position = self_pos
		snap.skater_states[1] = s
	else:
		for entry: Array in skaters:
			var sk := SkaterNetworkState.new()
			sk.position = entry[2]
			sk.velocity = entry[3] if entry.size() > 3 else Vector3.ZERO
			snap.skater_states[entry[0]] = sk
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	if carrier_pid != -1:
		for entry: Array in skaters:
			if entry[0] == carrier_pid:
				puck.position = entry[2]
				break
	else:
		puck.position = Vector3.ZERO
	snap.puck_state = puck

	var team_map: Dictionary = {1: TEAM_ID}
	if not skaters.is_empty():
		team_map.clear()
		for entry: Array in skaters:
			team_map[entry[0]] = entry[1]

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -OUR_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = team_map
	return ctx


# ── Loose puck: contain its spot, don't freeze ─────────────────────────────

func test_contains_loose_puck_instead_of_freezing() -> void:
	# Loose puck at origin — CONTAIN holds a gap goal-side of the puck spot
	# (toward our +Z net), not self_pos.
	var self_pos := Vector3(0, 0, -6)   # up-ice (offensive side)
	var ctx: RoleContext = _make_ctx(self_pos)   # loose puck at origin
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_ne(d.target_position, self_pos,
			"loose puck → hold a gap toward our net, don't freeze")
	assert_gt(d.target_position.z, 0.0,
			"target is goal-side (+Z) of the loose puck; got z=%f" % d.target_position.z)


# ── Gap control geometry ───────────────────────────────────────────────────

func test_target_is_goal_side_of_carrier_on_net_line() -> void:
	# Carrier in NZ at z=0; our net at +26.65. The gap target sits goal-side
	# of the carrier (between carrier and net), on the carrier→net line (x≈0).
	var carrier_pos := Vector3(0, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],   # us, deep
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters, 200)
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_gt(d.target_position.z, carrier_pos.z,
			"target is goal-side of carrier; got z=%f" % d.target_position.z)
	assert_lt(d.target_position.z, OUR_NET_Z,
			"target stays in front of the net; got z=%f" % d.target_position.z)
	assert_almost_eq(d.target_position.x, 0.0, 0.01,
			"target sits on the carrier→net line; got x=%f" % d.target_position.x)


func test_gap_matches_the_rush_pace() -> void:
	# The gap is a reaction cushion against the rush's PACE: a charging
	# carrier is stood off deep (committed speed is what beats a defender
	# clean); a gliding one is met tight — "gapping up", which the old
	# distance-fraction gap never did (six metres off any blue-line carrier
	# however slowly the rush came on).
	#
	# Each defender is staged ON the gap its pace earns, so this reads the
	# steady-state cushion (does CONTAIN HOLD the right gap?) rather than the
	# approach to it — the last-man step-up clamp governs how fast a defender
	# still up-ice of its stand may close on it, and would otherwise be what
	# these numbers measured. The approach is pinned by its own tests below.
	var carrier := Vector3(0, 0, 4)
	var charge_stand := Vector3(0, 0, carrier.z
			+ 9.0 * AIRoleHelpers.DEFENSIVE_ANTICIPATION_S
			+ AIRoleContain.gap_for_pace(9.0))
	var glide_stand := Vector3(0, 0, carrier.z
			+ 2.0 * AIRoleHelpers.DEFENSIVE_ANTICIPATION_S
			+ AIRoleContain.gap_for_pace(2.0))
	var charging: Array = [
		[1, TEAM_ID, charge_stand, Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier, Vector3(0, 0, 9)],
	]
	var gliding: Array = [
		[1, TEAM_ID, glide_stand, Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier, Vector3(0, 0, 2)],
	]
	var charge_t: Vector3 = AIRoleContain.decide(
			_make_ctx(charge_stand, charging, 200)).target_position
	var glide_t: Vector3 = AIRoleContain.decide(
			_make_ctx(glide_stand, gliding, 200)).target_position
	var charge_gap: float = carrier.distance_to(charge_t)
	var glide_gap: float = carrier.distance_to(glide_t)
	assert_lt(glide_gap, charge_gap - 2.0,
			"a gliding carrier is met tight, a charging one stood off deep;"
			+ " glide=%f charge=%f" % [glide_gap, charge_gap])
	assert_almost_eq(glide_t.z - (carrier.z + 2.0
			* AIRoleHelpers.DEFENSIVE_ANTICIPATION_S),
			AIRoleContain.gap_for_pace(2.0), 0.3,
			"the tight gap is the pace cushion off the led carrier")


func test_leads_a_laterally_cutting_carrier() -> void:
	# A carrier cutting hard across the ice: the gap point is defined off
	# where the rush is GOING (lead_threat), not the freeze-frame — so a
	# lateral cut shifts CONTAIN's target toward the cut side instead of
	# leaving it back-pedalling on a stale carrier→net line.
	var carrier_pos := Vector3(0, 0, 4)
	var still_skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var cutting_skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3(7, 0, 0)],   # cutting toward +X
	]
	var still_t: Vector3 = AIRoleContain.decide(
			_make_ctx(Vector3(0, 0, 18), still_skaters, 200)).target_position
	var cutting_t: Vector3 = AIRoleContain.decide(
			_make_ctx(Vector3(0, 0, 18), cutting_skaters, 200)).target_position
	assert_gt(cutting_t.x, still_t.x + 0.3,
			"a +X cut shifts the gap point toward +X; still x=%f cutting x=%f" \
			% [still_t.x, cutting_t.x])


func test_never_retreats_behind_goal_line() -> void:
	# Even with the carrier right at the net mouth, the gap target stays in
	# front of (not past) our goal line.
	var carrier_pos := Vector3(0, 0, 25.5)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 24), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var d: RoleDecision = AIRoleContain.decide(_make_ctx(Vector3(0, 0, 24), skaters, 200))
	assert_lt(d.target_position.z, OUR_NET_Z + 0.01,
			"never projects behind our goal line; got z=%f" % d.target_position.z)


func test_stands_up_at_the_blue_line_with_support_behind() -> void:
	# Carrier 3 m outside our blue line, driving in, with a teammate home BEHIND
	# CONTAIN (deeper, near our net): the raw distance-fraction gap (~6 m) would
	# put CONTAIN six metres BEHIND the line — a conceded entry. Backed by the
	# safety layer, the line-stand cap plants it one stride inside the line
	# instead, so the carrier meets a set defender at the entry moment.
	var carrier := Vector3(0, 0, GameRules.BLUE_LINE_Z - 3.0)   # z ≈ 4.29, outside our +Z zone
	var ctx := _make_ctx(Vector3(0, 0, 12), [
			[1, TEAM_ID, Vector3(0, 0, 12)],
			[2, TEAM_ID, Vector3(0, 0, 20)],   # safety home behind CONTAIN
			[200, 1, carrier, Vector3(0, 0, 8)],   # driving the line at pace
	], 200)
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_almost_eq(d.target_position.z,
			GameRules.BLUE_LINE_Z + AIRoleContain.LINE_STAND_INSIDE_M, 0.3,
			"CONTAIN plants a stride inside the blue line for the entry;"
			+ " got z=%f" % d.target_position.z)


func test_last_man_contains_instead_of_standing_up() -> void:
	# Same entry, but CONTAIN is the genuine LAST man back — no teammate deeper
	# than it. Stepping up to the line trades a denied entry for a possible
	# breakaway, so CONTAIN holds the deeper contain gap and skates the rush in
	# rather than challenging at the line. Its stand sits meaningfully deeper
	# (larger +Z) than the with-support line plant.
	var carrier := Vector3(0, 0, GameRules.BLUE_LINE_Z - 3.0)   # z ≈ 4.29
	var supported := _make_ctx(Vector3(0, 0, 12), [
			[1, TEAM_ID, Vector3(0, 0, 12)],
			[2, TEAM_ID, Vector3(0, 0, 20)],   # safety home behind → stand up
			[200, 1, carrier, Vector3(0, 0, 8)],
	], 200)
	var last_man := _make_ctx(Vector3(0, 0, 12), [
			[1, TEAM_ID, Vector3(0, 0, 12)],
			[2, TEAM_ID, Vector3(0, 0, -10)],  # partner caught up-ice → last man
			[200, 1, carrier, Vector3(0, 0, 8)],
	], 200)
	var supported_z: float = AIRoleContain.decide(supported).target_position.z
	var last_man_z: float = AIRoleContain.decide(last_man).target_position.z
	assert_gt(last_man_z, supported_z + 1.0,
			"the last man contains deeper instead of stepping up to the line;"
			+ " last_man z=%f supported z=%f" % [last_man_z, supported_z])


func test_gap_cap_releases_once_the_zone_is_gained() -> void:
	# Same rush, carrier now 3 m INSIDE our zone: the line stand is over and
	# the normal protect-the-net gap ramp resumes (well deeper than the line).
	var carrier := Vector3(0, 0, GameRules.BLUE_LINE_Z + 3.0)
	var ctx := _make_ctx(Vector3(0, 0, 16), [
			[1, TEAM_ID, Vector3(0, 0, 16)],
			[200, 1, carrier, Vector3(0, 0, 8)],
	], 200)
	var d: RoleDecision = AIRoleContain.decide(ctx)
	var led: Vector3 = AIRoleHelpers.lead_threat(carrier, Vector3(0, 0, 8))
	var expected_gap: float = AIRoleContain.gap_for_pace(8.0)
	assert_almost_eq(d.target_position.z, led.z + expected_gap, 0.3,
			"inside the zone the normal pace-cushion gap resumes")


func test_never_advances_past_recovery_toward_a_distant_carrier() -> void:
	# Turnover twin of the forecheck-F3 bug: carrier still deep in HIS end with
	# a trailer streaking through center. The carrier-relative gap point sits
	# ~35 m up-ice — chasing it would vacate the middle for the 2-on-1. CONTAIN
	# instead waits at the edge of recoverability: its stand's distance from our
	# net never exceeds the race-home radius against the fastest opponent.
	var carrier := Vector3(0, 0, -20)                # deep in their end
	var trailer := Vector3(2, 0, 2)                  # streaking through center
	var ctx := _make_ctx(Vector3(0, 0, 5), [
			[1, TEAM_ID, Vector3(0, 0, 5)],
			[200, 1, carrier],
			[210, 1, trailer, Vector3(0, 0, 7)],     # burning toward our net
	], 200)
	# Gate off the pass-lane fan: this test pins the race-home DEPTH clamp in
	# isolation (the fan may legitimately trade the pure race radius for lane
	# ownership — covered by the odd-man tests below).
	ctx.plays_rush_pass_lanes = false
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_gt(d.target_position.z, 0.0,
			"CONTAIN waits at the edge of recoverability — on OUR side of"
			+ " center, not chasing the distant gap point; got %s"
			% d.target_position)
	assert_lt(d.target_position.z, trailer.z + 12.0,
			"…and sags to even with the trailer, not into a full retreat to"
			+ " the crease; got %s" % d.target_position)


func test_trailer_race_reads_the_trailer_real_speed_cap() -> void:
	# The recovery clamp races each trailer at ITS real Speed cap: a slow
	# build's trailer takes longer to get home, so CONTAIN may stand
	# meaningfully farther out before the race is at risk. (The hand-filled
	# trailer list used to size-mismatch the caps scratch buffer, silently
	# demoting every trailer to league-reference speed — a plodder forced
	# the same deep sag a burner did.)
	var carrier := Vector3(0, 0, -20)
	var trailer := Vector3(2, 0, 2)
	var skaters: Array = [
			[1, TEAM_ID, Vector3(0, 0, 5)],
			[200, 1, carrier],
			[210, 1, trailer, Vector3(0, 0, 7)],
	]
	var our_net := Vector3(0, 0, OUR_NET_Z)

	# Gate off the pass-lane fan — this test pins the race clamp's caps read
	# in isolation (see the note in the recovery test above).
	var ctx_default: RoleContext = _make_ctx(Vector3(0, 0, 5), skaters, 200)
	ctx_default.plays_rush_pass_lanes = false
	var default_stand: float = AIRoleContain.decide(
			ctx_default).target_position.distance_to(our_net)

	var slow_caps := AISkaterCaps.new()
	slow_caps.max_speed = 4.0
	var ctx_slow: RoleContext = _make_ctx(Vector3(0, 0, 5), skaters, 200)
	ctx_slow.plays_rush_pass_lanes = false
	ctx_slow.caps_by_peer = {210: slow_caps}
	var slow_stand: float = AIRoleContain.decide(
			ctx_slow).target_position.distance_to(our_net)

	assert_gt(slow_stand, default_stand + 2.0,
			"a slow trailer lets CONTAIN stand farther from home;"
			+ " slow=%.1f default=%.1f" % [slow_stand, default_stand])


# ── Odd-man pass-lane read ("play the pass") ────────────────────────────────

# In-zone 2-on-1: opp carrier drives the middle, partner streaks abreast on
# +X, our markers hopelessly caught up-ice, our goalie challenged out on the
# carrier's line (what the live goalie AI does on a rush — which is exactly
# what leaves the far side open to the one-timer). The lane fan should rotate
# the stand off the carrier→net line toward the open feed lane.
func _two_on_one_ctx() -> RoleContext:
	var skaters: Array = [
			[1, TEAM_ID, Vector3(0, 0, 20)],
			[2, TEAM_ID, Vector3(0, 0, -12)],    # markers caught up-ice
			[3, TEAM_ID, Vector3(4, 0, -15)],
			[200, 1, Vector3(0, 0, 14)],         # opp carrier, in our zone
			[210, 1, Vector3(8, 0, 16)],         # 2-on-1 partner, wide +X
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 20), skaters, 200)
	var goalie := GoalieNetworkState.new()
	goalie.position_x = 0.0
	goalie.position_z = 24.6   # challenged toward the carrier
	ctx.snapshot.goalie_states[TEAM_ID] = goalie
	return ctx


func test_two_on_one_splits_toward_the_open_feed_lane() -> void:
	var d: RoleDecision = AIRoleContain.decide(_two_on_one_ctx())
	assert_gt(d.target_position.x, 1.0,
			"an uncovered 2-on-1 partner pulls the stand toward his feed lane;"
			+ " got %s" % d.target_position)
	# Depth discipline is preserved: the fan rotates AT the gap distance —
	# CONTAIN neither lunges at the carrier nor abandons the retreat. The
	# expected depth is the normal protect-the-net ramp (the trailer's
	# counter path is contained from there, so no extra sag applies).
	var ramp_gap: float = AIRoleContain.gap_for_pace(0.0)
	var gap_dist: float = d.target_position.distance_to(Vector3(0, 0, 14))
	assert_between(gap_dist, ramp_gap - 0.3, 9.5,
			"lane candidates keep the gap depth; got %.2f m off the carrier" % gap_dist)


func test_two_on_one_lane_yields_when_receiver_is_covered() -> void:
	# Same rush, but a marker is already home on the partner: his pass threat
	# is suppressed through the shared surfaces (coverage is continuous, not a
	# boolean), so the classic carrier-line retreat wins again.
	var skaters: Array = [
			[1, TEAM_ID, Vector3(0, 0, 20)],
			[2, TEAM_ID, Vector3(7.5, 0, 17.5)],  # marker home, sealing the partner
			[3, TEAM_ID, Vector3(4, 0, -15)],
			[200, 1, Vector3(0, 0, 14)],
			[210, 1, Vector3(8, 0, 16)],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 20), skaters, 200)
	var goalie := GoalieNetworkState.new()
	goalie.position_x = 0.0
	goalie.position_z = 24.6
	ctx.snapshot.goalie_states[TEAM_ID] = goalie
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_lt(absf(d.target_position.x), 1.0,
			"a covered partner puts CONTAIN back on the carrier line;"
			+ " got %s" % d.target_position)


func test_low_danger_receiver_does_not_pull_contain_off_the_shooter() -> void:
	# Same rush shape as the 2-on-1, but the uncovered partner is jammed wide on
	# a near-goal-line sharp angle — an open lane that the textbook says to
	# concede (the goalie's post play walls the sharp-angle one-timer).
	# Un-pended by the post-clamped keeper prediction: a look inside the
	# dead-angle seal region has no arc to square on, so the predicted keeper
	# collapses TO THE POST over the feed's flight — the wide-deep one-timer
	# fires into that wall and honestly measures below the bar. The premise
	# check mirrors CONTAIN's own production read (predicted keeper + derived
	# seal over the feed flight).
	var partner := Vector3(13, 0, 20)   # wide + deep = brutal shooting angle
	var our_net := Vector3(0, 0, OUR_NET_Z)
	var feed_speed: float = AIActionScoring.expected_pass_speed(
			Vector3(0, 0, 14), partner)
	var feed_flight: float = Vector3(0, 0, 14).distance_to(partner) / feed_speed
	var recv_goalie: Vector3 = AIActionScoring.predict_goalie_pos(
			Vector3(0, 0, 24.6), our_net, feed_flight, partner)
	var partner_seal: float = AIActionScoring.derive_post_seal_x_sign(
			partner, our_net)
	assert_ne(partner_seal, 0.0,
			"premise: the wide-deep spot is inside the predicted post seal")
	var recv_danger: float = AIActionScoring.score_shoot(
			partner, our_net, recv_goalie,
			GameRules.NET_HALF_WIDTH, [] as Array[Vector3],
			AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			AIActionScoring.goalie_unsettled(
					Vector3(0, 0, 24.6), our_net, feed_flight, partner),
			[], -1.0, false, partner_seal, true)
	assert_lt(recv_danger, AIRoleContain.LANE_PLAY_DANGER_BAR,
			"premise: the wide sharp-angle partner is not an immediate finish"
			+ " threat; got danger=%f" % recv_danger)
	var skaters: Array = [
			[1, TEAM_ID, Vector3(0, 0, 22)],
			[2, TEAM_ID, Vector3(0, 0, -12)],   # markers caught up-ice
			[3, TEAM_ID, Vector3(4, 0, -15)],
			[200, 1, Vector3(0, 0, 14)],        # opp carrier, in our zone
			[210, 1, partner],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 22), skaters, 200)
	var goalie := GoalieNetworkState.new()
	goalie.position_x = 0.0
	goalie.position_z = 24.6
	ctx.snapshot.goalie_states[TEAM_ID] = goalie
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_lt(absf(d.target_position.x), 1.0,
			"a non-threat receiver leaves CONTAIN on the carrier line; got %s"
			% d.target_position)


func test_two_on_one_gate_keeps_lower_tiers_on_the_carrier_line() -> void:
	# plays_rush_pass_lanes=false (Easy): CONTAIN sees only the carrier and
	# retreats on the exact carrier→net line — the newcomer's cross-crease
	# feed stays open by design.
	var ctx: RoleContext = _two_on_one_ctx()
	ctx.plays_rush_pass_lanes = false
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_almost_eq(d.target_position.x, 0.0, 0.001,
			"gated tiers hold the pure retreat line")


# ── Retreat floor + teammate-covered trailers ──────────────────────────────

func test_retreat_floors_at_the_net_front_stand_not_the_goal_line() -> void:
	# A trailer already at the doorstep makes every stand on the retreat line
	# infeasible — the honest sag. But the sag must terminate at the NET-FRONT
	# stand (top of the crease repel skirt), never converge onto the goal-line
	# net point: a skater there duplicates the goalie, fights his own crease
	# repel, and body overshoot carries him behind his own goal line.
	var carrier := Vector3(0, 0, 22)
	var ctx := _make_ctx(Vector3(0, 0, 10), [
			[1, TEAM_ID, Vector3(0, 0, 10)],
			[200, 1, carrier],
			[210, 1, Vector3(0.3, 0, 26.6)],   # trailer parked at the net mouth
	], 200)
	ctx.plays_rush_pass_lanes = false
	var d: RoleDecision = AIRoleContain.decide(ctx)
	var floor_z: float = OUR_NET_Z \
			- (CreaseRules.ARC_RADIUS + AISteering.CREASE_REPEL_EXTENSION)
	assert_lt(d.target_position.z, floor_z + 0.1,
			"the sag terminates at the net-front stand, not the net point;"
			+ " got z=%f" % d.target_position.z)
	assert_gt(d.target_position.z, floor_z - 0.4,
			"…and it IS the deep net-front stand (the sag was real);"
			+ " got z=%f" % d.target_position.z)


func test_line_stand_holds_when_the_trailer_is_marked() -> void:
	# The doorstep trailer that would force a full sag has a MARKER home on
	# him (goal-side, within cover reach) — his counter channel is the
	# marker's problem, not CONTAIN's. With the channel owned, the blue-line
	# stand holds: CONTAIN meets the entry instead of conceding every rush to
	# the crease. (This is the 5v5 failure: pricing itself as the sole
	# defender against every body on the ice, no stand ever contained.)
	var carrier := Vector3(0, 0, GameRules.BLUE_LINE_Z - 3.0)
	var ctx := _make_ctx(Vector3(0, 0, 12), [
			[1, TEAM_ID, Vector3(0, 0, 12)],
			[2, TEAM_ID, Vector3(1.5, 0, 26.2)],   # marker home on the trailer
			[200, 1, carrier, Vector3(0, 0, 8)],   # driving the line at pace
			[210, 1, Vector3(1, 0, 25.8)],         # doorstep trailer, marked
	], 200)
	ctx.plays_rush_pass_lanes = false
	# OFF ruleset: the doorstep trailer is a LIVE channel (with offsides on,
	# the offside-clamp already defuses him at the blue line and the test
	# would pass without the marker read).
	ctx.offsides_enforced = false
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_almost_eq(d.target_position.z,
			GameRules.BLUE_LINE_Z + AIRoleContain.LINE_STAND_INSIDE_M, 0.3,
			"with the trailer's channel owned by his marker, CONTAIN plants"
			+ " at the blue-line stand; got z=%f" % d.target_position.z)


func test_unmarked_trailer_still_sags_the_stand() -> void:
	# Same doorstep trailer, marker caught UP-ICE of him (not goal-side) —
	# the channel is genuinely CONTAIN's problem and the honest sag stands.
	var carrier := Vector3(0, 0, GameRules.BLUE_LINE_Z - 3.0)
	var ctx := _make_ctx(Vector3(0, 0, 12), [
			[1, TEAM_ID, Vector3(0, 0, 12)],
			[2, TEAM_ID, Vector3(1.5, 0, 20.0)],   # deep, but NOT goal-side of the man
			[200, 1, carrier, Vector3(0, 0, 8)],   # driving the line at pace
			[210, 1, Vector3(1, 0, 25.8)],         # doorstep trailer, unmarked
	], 200)
	ctx.plays_rush_pass_lanes = false
	ctx.offsides_enforced = false   # live cherry-picker (see the marked twin)
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_gt(d.target_position.z, 20.0,
			"an unmarked doorstep trailer still sags the stand deep;"
			+ " got z=%f" % d.target_position.z)


func test_gaps_up_when_it_has_beaten_the_rush_home() -> void:
	# The "beaten to the slot" gap-up: CONTAIN is deep with clear inside position
	# on the whole rush (goal-side of the carrier AND the trailer). It STEPS UP to
	# challenge the carrier instead of sagging to cover the trailer — because a man
	# it's already this far ahead of can't burn it. Contrast: the same carrier with
	# the trailer PAST it (a doorstep cherry-picker) is a genuinely contested race,
	# so the conservative sag stands.
	#
	# Both defenders stand on the tight (won-race) cushion, so this reads which
	# gap each READ earns — the challenge cushion vs. the trailer sag — instead
	# of the last-man step-up clamp's approach budget (see
	# test_gap_matches_the_rush_pace).
	var carrier := Vector3(0, 0, 10.0)
	var cvel := Vector3(0, 0, 5.0)              # driving our net
	var stand := Vector3(0, 0, carrier.z
			+ cvel.z * AIRoleHelpers.DEFENSIVE_ANTICIPATION_S
			+ AIRoleContain.GAP_MIN_M
			+ cvel.z * AIRoleContain.WON_RACE_CUSHION_REACT_S)
	# Won the race: trailer up-ice, CONTAIN goal-side of both.
	var won := _make_ctx(stand, [
			[1, TEAM_ID, stand],
			[200, 1, carrier, cvel],
			[210, 1, Vector3(4, 0, 7.0), Vector3(3, 0, 6)],   # unmarked trailer, UP-ICE
	], 200)
	won.offsides_enforced = false
	# Contested: same, but the trailer is a doorstep man DEEPER than CONTAIN.
	var contested := _make_ctx(stand, [
			[1, TEAM_ID, stand],
			[200, 1, carrier, cvel],
			[210, 1, Vector3(1, 0, 24.0), Vector3.ZERO],      # doorstep cherry-picker
	], 200)
	contested.offsides_enforced = false
	var won_t: Vector3 = AIRoleContain.decide(won).target_position
	var contested_t: Vector3 = AIRoleContain.decide(contested).target_position
	# own_goal_dir = +1, so a SMALLER z is more forward/up-ice (gapped up); larger
	# z is sagged deep toward our net.
	assert_lt(won_t.z, contested_t.z - 2.0,
			"beaten-the-rush-home stands up to challenge; a deeper trailer sags it"
			+ " back — won z=%f contested z=%f" % [won_t.z, contested_t.z])
	assert_lt(won_t.distance_to(carrier), 5.0,
			"the won-race stand is a real challenge gap, not a deep contain;"
			+ " gap=%f" % won_t.distance_to(carrier))


func test_lone_charger_still_gets_the_full_pace_standoff() -> void:
	# The gap-up is trailer-earned: with NO trailer (a pure 1-on-1), a charging
	# carrier CONTAIN has beaten home still gets the full pace cushion — you don't
	# lunge at a lone rusher just because you have inside position. Staged ON that
	# cushion (see test_gap_matches_the_rush_pace) so this reads the standing gap,
	# not the clamped approach to it.
	var carrier := Vector3(0, 0, 6.0)
	var stand_z: float = carrier.z + 9.0 * AIRoleHelpers.DEFENSIVE_ANTICIPATION_S \
			+ AIRoleContain.gap_for_pace(9.0)
	var charging := _make_ctx(Vector3(0, 0, stand_z), [
			[1, TEAM_ID, Vector3(0, 0, stand_z)],
			[200, 1, carrier, Vector3(0, 0, 9.0)],   # flying in, no trailer
	], 200)
	var t: Vector3 = AIRoleContain.decide(charging).target_position
	var led_carrier_z: float = carrier.z + 9.0 * AIRoleHelpers.DEFENSIVE_ANTICIPATION_S
	assert_almost_eq(t.z - led_carrier_z, AIRoleContain.gap_for_pace(9.0), 0.3,
			"a lone charger keeps the full pace standoff (no trailer to recover from);"
			+ " got gap=%f" % (t.z - led_carrier_z))


# ── Last-man step-up: arrive set, never lunge ───────────────────────────────

func test_last_man_does_not_charge_up_ice_at_a_rush_at_pace() -> void:
	# THE failure this clamp exists for. CONTAIN is home in front of its net; the
	# carrier is flying at it from centre ice, 20 m away. The pace gap alone puts
	# the stand ~14 m up-ice, and charging it means arriving with up-ice momentum
	# into a head-on carrier — the reversal is the whole rush (measured in the
	# duel harness: walked around, then trailing the play into its own net from
	# behind). As the last man back CONTAIN instead holds its ground and makes
	# the rush come to it: the step-up it takes now is a fraction of the raw gap
	# point's, and it never crosses to the carrier's side of the eventual stand.
	var carrier := Vector3(0, 0, -6.0)
	var self_pos := Vector3(0, 0, 14.0)
	var ctx := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[200, 1, carrier, Vector3(0, 0, 8.0)],   # flying in, no support home
	], 200)
	ctx.plays_rush_pass_lanes = false
	var t: Vector3 = AIRoleContain.decide(ctx).target_position
	var raw_gap_point_z: float = carrier.z \
			+ 8.0 * AIRoleHelpers.DEFENSIVE_ANTICIPATION_S \
			+ AIRoleContain.gap_for_pace(8.0)
	assert_lt(self_pos.z - t.z, (self_pos.z - raw_gap_point_z) * 0.5,
			"the last man takes well under half the raw step-up at rush pace;"
			+ " target z=%f raw gap point z=%f" % [t.z, raw_gap_point_z])
	assert_gt(t.z, raw_gap_point_z,
			"…and never past the stand the rush is skating into; got z=%f" % t.z)


func test_last_man_closes_all_the_way_on_a_stalled_carrier() -> void:
	# The other end of the same bound: a carrier who isn't closing has a stand
	# that isn't going anywhere, so there is no rendezvous to lose and the budget
	# is unbounded — CONTAIN closes right up to poke range. This is the "gap up"
	# the clamp must not cost: it only ever prices a step-up against a rush
	# whose stand is sweeping away from it.
	var carrier := Vector3(0, 0, -6.0)
	var self_pos := Vector3(0, 0, 14.0)
	var ctx := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[200, 1, carrier, Vector3.ZERO],   # stalled / regrouping
	], 200)
	ctx.plays_rush_pass_lanes = false
	var t: Vector3 = AIRoleContain.decide(ctx).target_position
	assert_almost_eq(t.z - carrier.z, AIRoleContain.GAP_MIN_M, 0.3,
			"a stalled carrier is met tight — the full step-up, no clamp;"
			+ " got gap=%f" % (t.z - carrier.z))


func test_step_up_clamp_yields_to_a_safety_layer_behind() -> void:
	# The clamp is the last man's discipline, gated exactly like the blue-line
	# stand: with a teammate home behind us a beaten challenge costs a chance
	# somebody can still answer, so the aggressive step-up stays available.
	var carrier := Vector3(0, 0, -6.0)
	var self_pos := Vector3(0, 0, 14.0)
	var last_man := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[200, 1, carrier, Vector3(0, 0, 8.0)],
	], 200)
	last_man.plays_rush_pass_lanes = false
	var supported := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(0, 0, 22.0)],   # safety home behind CONTAIN
			[200, 1, carrier, Vector3(0, 0, 8.0)],
	], 200)
	supported.plays_rush_pass_lanes = false
	var last_man_z: float = AIRoleContain.decide(last_man).target_position.z
	var supported_z: float = AIRoleContain.decide(supported).target_position.z
	assert_lt(supported_z, last_man_z - 2.0,
			"backed by a safety layer CONTAIN steps up meaningfully further;"
			+ " supported z=%f last man z=%f" % [supported_z, last_man_z])


func test_step_up_clamp_never_pushes_the_stand_up_ice() -> void:
	# The clamp is a bound on the step-up, not a mover: a stand already goal-side
	# of us is a retreat (it costs no reversal) and must come through untouched,
	# or CONTAIN would refuse to give ground it has to give.
	var carrier := Vector3(0, 0, 6.0)
	var self_pos := Vector3(0, 0, 10.0)          # still up-ice OF the gap point
	var ctx := _make_ctx(self_pos, [
			[1, TEAM_ID, self_pos],
			[200, 1, carrier, Vector3(0, 0, 8.0)],
	], 200)
	ctx.plays_rush_pass_lanes = false
	var t: Vector3 = AIRoleContain.decide(ctx).target_position
	var led_carrier_z: float = carrier.z + 8.0 * AIRoleHelpers.DEFENSIVE_ANTICIPATION_S
	assert_almost_eq(t.z - led_carrier_z, AIRoleContain.gap_for_pace(8.0), 0.3,
			"a retreat to the pace gap is untouched by the step-up clamp;"
			+ " got gap=%f" % (t.z - led_carrier_z))
