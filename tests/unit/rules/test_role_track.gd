extends GutTest

# AIRoleTrack — the backcheck (docs/transition-defense-plan.md §5, §7).
# Team 0 defends +Z; peer 1 is the bot under test, peer 10 the opposing carrier.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65


func _ctx(self_pos: Vector3, skaters: Array, carrier_pid: int,
		self_vel: Vector3 = Vector3.ZERO) -> RoleContext:
	var snap := WorldSnapshot.new()
	var s := SkaterNetworkState.new()
	s.position = self_pos
	s.velocity = self_vel
	s.stamina = 1.0
	snap.skater_states[1] = s
	var team_map: Dictionary = {1: TEAM_ID}
	for e: Array in skaters:
		var sk := SkaterNetworkState.new()
		sk.position = e[2]
		sk.velocity = e[3] if e.size() > 3 else Vector3.ZERO
		sk.stamina = 1.0
		snap.skater_states[e[0]] = sk
		team_map[e[0]] = e[1]
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	puck.position = snap.skater_states[carrier_pid].position \
			if snap.skater_states.has(carrier_pid) else Vector3.ZERO
	snap.puck_state = puck

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.self_velocity = self_vel
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -OUR_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = team_map
	ctx.team_size = 5
	ctx.strong_x = 1.0
	var read := AIRushRead.new()
	read.fill(snap, TEAM_ID, OUR_NET_Z, team_map, {}, {})
	ctx.rush_read = read
	return ctx


# ── The urgency fix: recovering is a MODE, not a position ────────────────────

func test_a_beaten_tracker_sprints_instead_of_positioning() -> void:
	# The reported symptom: a human collects the puck in the NZ and skates past
	# bots "lazily marking men". A peer still up-ice runs NO argmax — he gets a
	# lane point and a forced sprint.
	var ctx: RoleContext = _ctx(Vector3(-6.0, 0.0, -14.0), [
		[10, 1, Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 7.0)],
		[11, 1, Vector3(5.0, 0.0, 3.0), Vector3(0.0, 0.0, 7.0)],
	], 10)
	var d: RoleDecision = AIRoleTrack.decide(
			ctx, AIRoleSlots.Slot.TRACK_MID_STRONG)
	assert_true(d.sprint_override,
			"a tracker behind the play sprints, unconditionally")
	assert_true(d.arrive_at_speed, "and does not brake into his lane point")


func test_a_recovering_tracker_heads_home_not_at_his_man() -> void:
	# He is 20 m up-ice with an attacker beside him. The old MARK would compute
	# a cover position on that man; the tracker must head for our end instead.
	var ctx: RoleContext = _ctx(Vector3(-6.0, 0.0, -14.0), [
		[10, 1, Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 7.0)],
		[11, 1, Vector3(-5.0, 0.0, -13.0), Vector3(0.0, 0.0, 7.0)],  # right there
	], 10)
	var d: RoleDecision = AIRoleTrack.decide(
			ctx, AIRoleSlots.Slot.TRACK_MID_STRONG)
	assert_gt(d.target_position.z, 0.0,
			"the recovery target is toward our end, not on the adjacent man; got %s"
			% d.target_position)


func test_recovering_tracker_comes_back_through_the_middle() -> void:
	# The researched lane: F2/F3 come back THROUGH mid-ice, not up their own
	# wall behind the play.
	var ctx: RoleContext = _ctx(Vector3(-12.0, 0.0, -14.0),
			[[10, 1, Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 7.0)]], 10)
	var d: RoleDecision = AIRoleTrack.decide(
			ctx, AIRoleSlots.Slot.TRACK_MID_STRONG)
	assert_lt(absf(d.target_position.x), 6.0,
			"the recovery lane is mid-ice; got %s" % d.target_position)


func test_a_home_tracker_stops_at_the_circle_tops() -> void:
	# "F2 and F3 come back through mid ice and stop just inside the tops of the
	# circles" — not at the goal line, and not chasing further.
	var ctx: RoleContext = _ctx(Vector3(2.0, 0.0, 20.0),
			[[10, 1, Vector3(0.0, 0.0, 10.0), Vector3(0.0, 0.0, 6.0)]], 10)
	var d: RoleDecision = AIRoleTrack.decide(
			ctx, AIRoleSlots.Slot.TRACK_MID_STRONG)
	assert_false(d.sprint_override, "a tracker who is home stops sprinting")
	var depth: float = OUR_NET_Z - d.target_position.z
	assert_almost_eq(depth, AIZoneCoverage.HOUSE_TOP_DEPTH_M
			- AIRoleTrack.CIRCLE_TOP_INSET_M, 1.0,
			"holds just inside the circle tops; got %s" % d.target_position)


func test_the_two_mid_trackers_do_not_stack() -> void:
	var skaters: Array = [[10, 1, Vector3(0.0, 0.0, 10.0), Vector3(0.0, 0.0, 6.0)]]
	var strong: RoleDecision = AIRoleTrack.decide(
			_ctx(Vector3(2.0, 0.0, 20.0), skaters, 10),
			AIRoleSlots.Slot.TRACK_MID_STRONG)
	var weak: RoleDecision = AIRoleTrack.decide(
			_ctx(Vector3(-2.0, 0.0, 20.0), skaters, 10),
			AIRoleSlots.Slot.TRACK_MID_WEAK)
	assert_gt(strong.target_position.distance_to(weak.target_position), 2.0,
			"F2 and F3 recover on separate lanes")


# ── TRACK_PUCK ───────────────────────────────────────────────────────────────

func test_track_puck_chases_the_carrier_at_full_pace() -> void:
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, -6.0),
			[[10, 1, Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 7.0)]], 10)
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_PUCK)
	assert_true(d.sprint_override, "F1 back runs the carrier down")
	assert_true(d.has_aim_override, "stick on the puck, not on open ice")


func test_track_puck_targets_the_goal_side_hip() -> void:
	# Arrive BETWEEN him and the net, not alongside — riding his outside hip
	# just escorts him to the slot.
	var carrier := Vector3(0.0, 0.0, 0.0)
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, -6.0),
			[[10, 1, carrier, Vector3.ZERO]], 10)
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_PUCK)
	assert_gt(d.target_position.z, carrier.z,
			"the tracking target is goal-side of the carrier; got %s"
			% d.target_position)


func test_track_puck_will_not_hunt_a_check_from_up_ice() -> void:
	# A backchecker taking a run at the play from behind removes himself from
	# it. The check is only available once he is genuinely goal-side.
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, -3.0),
			[[10, 1, Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 6.0)]], 10,
			Vector3(0.0, 0.0, 9.0))
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_PUCK)
	assert_false(d.commit_check,
			"no check commit while still up-ice of the carrier")


func test_a_loose_puck_is_still_tracked() -> void:
	# No carrier: F1 back keeps running at the puck rather than freezing, so a
	# missed pass in transition doesn't leave the backcheck standing still.
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 10.0), [], -1)
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_PUCK)
	assert_lt(d.target_position.z, 10.0, "tracks toward the loose puck")


func test_no_puck_at_all_leaves_the_tracker_in_place() -> void:
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 10.0), [], -1)
	ctx.snapshot.puck_state = null
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_PUCK)
	assert_eq(d.target_position, Vector3(0.0, 0.0, 10.0))


# ── The lone 3v3 mid tracker ─────────────────────────────────────────────────

func test_lone_mid_tracker_holds_the_centre_lane() -> void:
	# 3v3 has no D pair to split around, so the single mid tracker sits dead
	# centre rather than on a side of it.
	var ctx: RoleContext = _ctx(Vector3(1.0, 0.0, 20.0),
			[[10, 1, Vector3(0.0, 0.0, 10.0), Vector3(0.0, 0.0, 6.0)]], 10)
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_MID)
	assert_almost_eq(d.target_position.x, 0.0, 0.6,
			"the lone mid tracker holds centre; got %s" % d.target_position)


func test_lone_mid_tracker_owns_both_halves() -> void:
	# The 5v5 pair filters to its own half and hands off at the seam. With only
	# one body in the middle there is nobody to hand off TO, so he must pick up a
	# man on either side — filtering him to half the ice would leave the other
	# half uncovered.
	var carrier := Vector3(0.0, 0.0, 12.0)
	for man_x: float in [-4.0, 4.0]:
		var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 20.0), [
			[10, 1, carrier, Vector3(0.0, 0.0, 6.0)],
			[11, 1, Vector3(man_x, 0.0, 14.0), Vector3(0.0, 0.0, 6.0)],
		], 10)
		var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_MID)
		assert_lt(absf(d.target_position.x - man_x), 5.0,
				("a man at x=%.1f must be picked up by the lone tracker; got %s")
				% [man_x, d.target_position])


# ── Bounds: a tracker defends his own ice ────────────────────────────────────

func test_the_mid_tracker_does_not_leave_the_structure_for_a_man_up_ice() -> void:
	# "Pick up whoever has entered my lane… never chase out of the structure."
	# The pick used to be the deepest attacker on my half of the RINK however far
	# up-ice, and the cover geometry then put the target goal-side of HIM — which
	# sent a mid tracker past the far blue line to cover a trailer who was no part
	# of anything yet. A man outside the pickup bound is not mine; hold the post.
	var carrier := Vector3(0.0, 0.0, 8.0)
	var far_man := Vector3(2.0, 0.0, -12.0)      # ~38 m off our net, up-ice
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0), [
		[10, 1, carrier, Vector3(0.0, 0.0, 7.0)],
		[11, 1, far_man, Vector3(0.0, 0.0, 8.0)],
	], 10)
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_MID)
	var our_net := Vector3(0.0, 0.0, OUR_NET_Z)
	assert_lt(d.target_position.distance_to(our_net), 14.5,
			"the mid tracker chased a man out of his own structure; target sat %.1f m off our net"
			% d.target_position.distance_to(our_net))


func test_the_mid_tracker_still_picks_up_a_man_who_has_arrived() -> void:
	# The bound must not turn into blindness: a man inside the tracker's ice is
	# exactly who the role exists to take, and he still gets covered.
	var carrier := Vector3(0.0, 0.0, 8.0)
	# ~12 m off our net (inside the pickup bound) and well off centre, so
	# covering him is visibly a different answer from holding the centre post.
	var near_man := Vector3(7.0, 0.0, 15.0)
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 18.0), [
		[10, 1, carrier, Vector3(0.0, 0.0, 7.0)],
		[11, 1, near_man, Vector3(0.0, 0.0, 5.0)],
	], 10)
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_MID)
	assert_gt(d.target_position.x, 2.0,
			"a man who has entered the tracker's ice is still picked up; got %s"
			% d.target_position)


func test_a_tracker_already_goal_side_holds_a_gap_instead_of_running_the_hip() -> void:
	# The hip is a CATCH-UP target: 0.8 m goal-side is where you take the puck
	# from a man you are chasing. For a tracker who is already goal-side it is a
	# step-up — the election hands this slot to whoever reaches the puck soonest,
	# which in a shape that is home means somebody in FRONT of the play. So the
	# hip's gap is bounded by the gap ladder, and the sprint override (which
	# exists because a backchecker is behind by definition) stands down.
	var carrier := Vector3(0.0, 0.0, 0.0)
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 20.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 7.0)]], 10)
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_PUCK)
	var led: Vector3 = AIRoleHelpers.lead_threat(
			carrier, Vector3(0.0, 0.0, 7.0), 1.0)
	var gap: float = d.target_position.distance_to(led)
	assert_gt(gap, AIRoleTrack.HIP_GOAL_SIDE_M * 2.0,
			"a tracker in front of the play still ran at the hip; gap %.2f m" % gap)
	assert_false(d.sprint_override,
			"a tracker who is already back is not sprinting a recovery")


func test_a_tracker_behind_the_play_still_runs_the_hip_down() -> void:
	# The other side of the same bound: a genuine backchecker is unchanged — the
	# depth term is nil, so he gets the hip and the sprint override.
	var carrier := Vector3(0.0, 0.0, 0.0)
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, -6.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 7.0)]], 10)
	var d: RoleDecision = AIRoleTrack.decide(ctx, AIRoleSlots.Slot.TRACK_PUCK)
	var led: Vector3 = AIRoleHelpers.lead_threat(
			carrier, Vector3(0.0, 0.0, 7.0), 1.0)
	assert_almost_eq(d.target_position.distance_to(led),
			AIRoleTrack.HIP_GOAL_SIDE_M, 0.1,
			"the backchecker's target is still the hip")
	assert_true(d.sprint_override, "and he is still sprinting to catch him")
