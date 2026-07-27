extends GutTest

# The offensive stations' pinch read (docs/transition-defense-plan.md §13).
# Replaces the counter-channel race for every station holding forward ice while
# we have the puck. Team 0 defends +Z (net at +26.65) and attacks -Z.
#
# The doctrine being pinned:
#   "The only time a defenseman should be standing on the offensive blue line is
#    when his team has complete control of the puck."
#   "A defenceman can only pinch when they have a supporting player in position
#    to back them up."
#   "The first rule defensemen are taught is to count numbers."
#   "Better to stay safe with a 3 on 2, rather than pinch and end up with a
#    3 on 1" — the retreat target is a numbers layer, not your own net.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65
const OPP_BLUE_Z: float = -7.29


# `ours` / `theirs` are [peer_id, pos, vel] rows. Peer 1 is the bot under test.
func _ctx(self_pos: Vector3, ours: Array, theirs: Array, carrier: int,
		is_defense: bool = true, offsides: bool = true) -> RoleContext:
	var snap := WorldSnapshot.new()
	var team_map: Dictionary = {}
	var s0 := SkaterNetworkState.new()
	s0.position = self_pos
	s0.stamina = 1.0
	snap.skater_states[1] = s0
	team_map[1] = TEAM_ID
	for e: Array in ours:
		var sk := SkaterNetworkState.new()
		sk.position = e[1]
		sk.velocity = e[2] if e.size() > 2 else Vector3.ZERO
		sk.stamina = 1.0
		snap.skater_states[e[0]] = sk
		team_map[e[0]] = TEAM_ID
	for e: Array in theirs:
		var sk := SkaterNetworkState.new()
		sk.position = e[1]
		sk.velocity = e[2] if e.size() > 2 else Vector3.ZERO
		sk.stamina = 1.0
		snap.skater_states[e[0]] = sk
		team_map[e[0]] = 1
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier
	puck.position = snap.skater_states[carrier].position if carrier != -1 \
			else Vector3(0.0, 0.0, -20.0)
	snap.puck_state = puck

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -OUR_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = team_map
	ctx.team_size = 5
	ctx.self_is_defense = is_defense
	ctx.self_home_side = 1.0
	ctx.offsides_enforced = offsides
	var read := AIRushRead.new()
	read.fill(snap, TEAM_ID, OUR_NET_Z, team_map, {}, {}, offsides)
	ctx.rush_read = read
	return ctx


# ── Control: hold the line only with complete control ────────────────────────

func test_clean_possession_holds_the_line() -> void:
	# Our carrier cycling low with nobody near him, no opponent behind our point:
	# the point holds its stand. This is the reported bug's inverse — the old
	# model retreated here as though the puck were already lost.
	var stand := Vector3(6.71, 0.0, OPP_BLUE_Z - 1.0)
	var ctx: RoleContext = _ctx(stand,
			[[2, Vector3(8.0, 0.0, -22.0)]],
			[[10, Vector3(-6.0, 0.0, -20.0)], [11, Vector3(0.0, 0.0, -14.0)]], 2)
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, stand, false)
	assert_almost_eq(t.z, stand.z, 0.5,
			"clean control holds the offensive blue line; got %s" % t)


func test_contested_control_alone_does_not_send_a_station_home() -> void:
	# Two opponents right on our carrier, but NOBODY behind our point. Backing off
	# here would buy no coverage and cost the attack a body — which is the exact
	# "out of the play" failure being fixed. Contested control instead tightens the
	# support triangle (see the leash tests below).
	var stand := Vector3(6.71, 0.0, OPP_BLUE_Z - 1.0)
	var ctx: RoleContext = _ctx(stand,
			[[2, Vector3(8.0, 0.0, -22.0)]], [
				[10, Vector3(8.6, 0.0, -21.4), Vector3(0.0, 0.0, 4.0)],
				[11, Vector3(7.2, 0.0, -22.6), Vector3(0.0, 0.0, 4.0)],
			], 2)
	assert_lt(ctx.rush_read.pressure_eta_s, 0.6,
			"scenario check: the carrier is genuinely pressured; got %.2f s"
			% ctx.rush_read.pressure_eta_s)
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, stand, false)
	assert_almost_eq(t.z, stand.z, 0.5,
			"pressure with nobody behind us does not vacate the stand; got %s" % t)


func test_support_behind_lets_the_pinch_stand() -> void:
	# "A defenceman can only pinch when they have a supporting player in position
	# to back them up." Same lurker, but this time a teammate is home behind the
	# stand — F3 high — so the pinch holds.
	var stand := Vector3(6.71, 0.0, OPP_BLUE_Z - 1.0)
	var lurker: Array = [[10, Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 7.0)]]
	var alone: RoleContext = _ctx(stand,
			[[2, Vector3(8.0, 0.0, -22.0)]], lurker, 2)
	var backed: RoleContext = _ctx(stand, [
				[2, Vector3(8.0, 0.0, -22.0)],
				[3, Vector3(0.0, 0.0, 6.0)],       # F3 high, behind the stand
			], lurker, 2)
	var t_alone: Vector3 = AIRoleHelpers.offensive_station_target(alone, stand, false)
	var t_backed: Vector3 = AIRoleHelpers.offensive_station_target(backed, stand, false)
	assert_gt(t_alone.z, stand.z, "unsupported, the lurker pulls the point back")
	assert_almost_eq(t_backed.z, stand.z, 0.5,
			"with support behind, the pinch holds; got %s" % t_backed)


# ── Numbers: the retreat target ──────────────────────────────────────────────

func test_retreat_stops_at_the_numbers_layer_not_at_home() -> void:
	# "Better to stay safe with a 3 on 2, rather than pinch and end up with a
	# 3 on 1." Backing off restores the layer and STOPS — the old floor was this
	# defenseman's own blue line, 30 m from the play.
	var stand := Vector3(6.71, 0.0, OPP_BLUE_Z - 1.0)
	# Centre ice, drifting home — his layer is well up-ice of our own blue line,
	# so "restore the numbers" and "get to your home post" are far apart here.
	var lurker := Vector3(0.0, 0.0, -4.0)
	var lurker_vel := Vector3(0.0, 0.0, 5.0)
	var ctx: RoleContext = _ctx(stand,
			[[2, Vector3(8.0, 0.0, -22.0)]],
			[[10, lurker, lurker_vel]], 2)
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, stand, false)
	var net := Vector3(0.0, 0.0, OUR_NET_Z)
	# Compare against his LED point — the read leads threats, so that is the
	# layer the floor is actually built off.
	var led: Vector3 = AIRoleHelpers.lead_threat(lurker, lurker_vel, 1.0)
	assert_lt(t.distance_to(net), stand.distance_to(net),
			"the station does retreat toward home")
	assert_gt(t.distance_to(net), led.distance_to(net) - 4.0,
			"but stops at the numbers layer, not deeper; got %s" % t)
	var home: Vector3 = AIRoleHelpers.station_retreat_floor(ctx, stand)
	assert_gt(t.distance_to(net), home.distance_to(net) + 4.0,
			"and nowhere near the old home-post floor; got %s vs home %s" % [t, home])


func test_a_body_level_with_the_point_is_not_behind_him() -> void:
	# The regression the old model was written to catch, re-armed for the new
	# read: a defending winger COVERING the point sits level with him. He must
	# not read as a man who has beaten him.
	var stand := Vector3(6.71, 0.0, OPP_BLUE_Z - 1.0)
	var ctx: RoleContext = _ctx(stand,
			[[2, Vector3(8.0, 0.0, -22.0)]],
			[[10, Vector3(5.0, 0.0, -9.0)]], 2)   # covering the point, level
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, stand, false)
	assert_almost_eq(t.z, stand.z, 0.5,
			"puckless coverage level with the point does not move him; got %s" % t)


func test_an_offside_lurker_is_not_a_threat() -> void:
	# An opponent already inside our zone ahead of the puck cannot legally
	# receive, so he must not drag a station out of the play.
	var stand := Vector3(6.71, 0.0, OPP_BLUE_Z - 1.0)
	var ctx: RoleContext = _ctx(stand,
			[[2, Vector3(8.0, 0.0, -22.0)]],
			[[10, Vector3(0.0, 0.0, 14.0), Vector3(0.0, 0.0, 7.0)]], 2)
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, stand, false)
	assert_almost_eq(t.z, stand.z, 0.5,
			"an illegally-positioned lurker is not a counter threat; got %s" % t)


# ── Play connection: nobody completely out of the play ───────────────────────

func test_a_station_out_of_feed_range_is_pulled_into_the_play() -> void:
	# The bound that did not exist: every other bound pulls toward home, so
	# nothing could say "you have left the attack". A stand miles from the puck
	# gets pulled back to within a feedable distance.
	var far_stand := Vector3(0.0, 0.0, 20.0)     # deep in our OWN end
	var ctx: RoleContext = _ctx(far_stand,
			[[2, Vector3(0.0, 0.0, -22.0)]],
			[[10, Vector3(-6.0, 0.0, -20.0)]], 2)
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, far_stand, true)
	var puck := Vector3(0.0, 0.0, -22.0)
	assert_lt(t.distance_to(puck), far_stand.distance_to(puck),
			"a station outside feed range is pulled toward the play; got %s" % t)


func test_the_leash_does_not_undo_a_legitimate_retreat() -> void:
	# The leash is a HOLDING bound. Clamping a recovery back up-ice toward the
	# puck would undo the coverage the numbers read just called for.
	var stand := Vector3(6.71, 0.0, OPP_BLUE_Z - 1.0)
	var lurker := Vector3(0.0, 0.0, 4.0)
	var ctx: RoleContext = _ctx(stand,
			[[2, Vector3(8.0, 0.0, -22.0)]],
			[[10, lurker, Vector3(0.0, 0.0, 7.0)]], 2)
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, stand, false)
	var net := Vector3(0.0, 0.0, OUR_NET_Z)
	assert_lt(t.distance_to(net), lurker.distance_to(net) + 4.0,
			"the retreat reaches the lurker's layer, unclamped; got %s" % t)


# ── Forechecking stays aggressive ────────────────────────────────────────────

func test_a_bottled_opponent_does_not_trigger_a_retreat() -> void:
	# Forechecking is aggressive by design: possession alone is no reason to
	# bail. A carrier pinned deep with no speed reads REGROUP, so the line pair
	# keeps its forward stand.
	var stand := Vector3(6.71, 0.0, -16.0)
	var ctx: RoleContext = _ctx(stand, [[2, Vector3(4.0, 0.0, -18.0)]],
			[[10, Vector3(4.0, 0.0, -24.0)]], 10)
	assert_eq(ctx.rush_read.mode, AIRushRead.Mode.REGROUP,
			"scenario check: a still carrier deep in his end is not a rush")
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, stand, true)
	assert_almost_eq(t.z, stand.z, 0.5,
			"a bottled carrier is exactly who you pinch on; got %s" % t)


func test_a_breakout_at_pace_releases_the_stand() -> void:
	# "If the other team gains clear possession and is moving out of the zone
	# with multiple passing options — retreat."
	var stand := Vector3(6.71, 0.0, -16.0)
	var ctx: RoleContext = _ctx(stand, [[2, Vector3(4.0, 0.0, -18.0)]],
			[[10, Vector3(2.0, 0.0, -14.0), Vector3(0.0, 0.0, 7.0)]], 10)
	assert_eq(ctx.rush_read.mode, AIRushRead.Mode.RUSH,
			"scenario check: the carrier is exiting at pace")
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, stand, true)
	assert_gt(t.z, stand.z, "the stand is released; got %s" % t)


# ── Imminence itself ─────────────────────────────────────────────────────────

func test_pressure_eta_is_long_with_an_unpressured_carrier() -> void:
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 0.0),
			[[2, Vector3(0.0, 0.0, -22.0)]],
			[[10, Vector3(0.0, 0.0, 10.0)]], 2)
	assert_gt(ctx.rush_read.pressure_eta_s, 2.0,
			"an opponent 30 m away is not pressure; got %.2f s"
			% ctx.rush_read.pressure_eta_s)


func test_pressure_eta_is_zero_when_they_have_it() -> void:
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 0.0), [],
			[[10, Vector3(0.0, 0.0, -10.0)]], 10)
	assert_eq(ctx.rush_read.pressure_eta_s, 0.0,
			"their puck is already contested by definition")


func test_unwired_read_holds_the_shape() -> void:
	# With no perception at all, the honest default is the station's own geometry
	# — not a retreat. Otherwise a brainless context would give up every stand.
	var stand := Vector3(6.71, 0.0, OPP_BLUE_Z - 1.0)
	var ctx := RoleContext.new()
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	assert_false(ctx.rush_read.is_live)
	assert_eq(AIRoleHelpers.offensive_station_target(ctx, stand, false), stand)


# ── Who is the back layer ────────────────────────────────────────────────────

func test_a_lone_back_layer_retreats_to_the_defenseman_post() -> void:
	# 3v3 has no lobby positions, so every peer reads "forward" — but F3_HIGH with
	# three skaters and no D pair IS the whole back layer. He must floor on the D
	# post (the dot lane AT our blue line), not the shallower forward post 4 m
	# up-ice of it.
	var stand := Vector3(9.0, 0.0, OPP_BLUE_Z)
	var ctx: RoleContext = _ctx(stand, [], [[10, Vector3(0.0, 0.0, -20.0),
			Vector3(0.0, 0.0, 7.0)]], 10, false)
	var as_forward: Vector3 = AIRoleHelpers.station_retreat_floor(ctx, stand)
	var as_back: Vector3 = AIRoleHelpers.station_retreat_floor(ctx, stand, true)
	var net := Vector3(0.0, 0.0, OUR_NET_Z)
	assert_lt(as_back.distance_to(net), as_forward.distance_to(net) - 2.0,
			"the back layer floors deeper than a forward; back=%s fwd=%s"
			% [as_back, as_forward])
	assert_almost_eq(as_back.z, GameRules.BLUE_LINE_Z, 0.01,
			"and that is the dot lane at our own blue line")


func test_the_high_slot_holds_while_two_points_are_behind_it() -> void:
	# The 5v5 O-zone shape is 3 low / 2 high: the POINTS are the insurance, so F3
	# in the high slot is an attacking body, not a defensive layer. Verified rather
	# than assumed — with both points home he holds his float even with a man
	# behind him, because has_support_behind is true.
	var hs_stand := Vector3(0.0, 0.0, -OUR_NET_Z + 9.5)
	var ctx: RoleContext = _ctx(hs_stand, [
				[2, Vector3(8.0, 0.0, -22.0)],       # our carrier, cycling low
				[3, Vector3(6.7, 0.0, -9.29)],       # strong point
				[4, Vector3(-3.0, 0.0, -9.29)],      # weak point
			], [[10, Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 7.0)]], 2, false)
	assert_true(AIRoleHelpers.has_support_behind(ctx),
			"scenario check: the points are genuinely behind the high slot")
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, hs_stand, true)
	assert_almost_eq(t.z, hs_stand.z, 0.5,
			"with two points home the high slot keeps attacking; got %s" % t)


func test_the_high_slot_does_back_off_once_both_points_activate() -> void:
	# The other side of it: if both points have gone deep, the high slot IS the
	# rearmost body and the read has to fire. Keeping it turnover-aware costs
	# nothing in normal play (above) and closes this hole.
	var hs_stand := Vector3(0.0, 0.0, -OUR_NET_Z + 9.5)
	var ctx: RoleContext = _ctx(hs_stand, [
				[2, Vector3(8.0, 0.0, -22.0)],
				[3, Vector3(7.0, 0.0, -21.0)],       # point activated deep
				[4, Vector3(-6.0, 0.0, -20.0)],      # point activated deep
			], [[10, Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 7.0)]], 2, false)
	assert_false(AIRoleHelpers.has_support_behind(ctx),
			"scenario check: nobody is behind the high slot now")
	var t: Vector3 = AIRoleHelpers.offensive_station_target(ctx, hs_stand, true)
	assert_gt(t.z, hs_stand.z,
			"as the rearmost body it does back off; got %s" % t)
