extends GutTest

# AIRoleContain — TRANS_OD-only second defender that engages
# forward instead of camping the slot. Search center is the
# midpoint of carrier→our-slot, so the role tracks the play
# up-ice; exposure factor (foot-race-to-slot vs opps) penalises
# candidates too far forward to recover from. Tests cover:
#   - Bail-out (no carrier).
#   - Target sits between carrier and slot (the defining geometry).
#   - In NZ-puck TRANS_OD, CONTAIN sits meaningfully forward of
#     where DZONE ANCHOR would sit (engages, doesn't camp).

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


# ── Bail-outs ───────────────────────────────────────────────────────────────

func test_falls_back_to_self_pos_when_no_carrier() -> void:
	# Loose puck — nothing to CONTAIN. Brain re-tick will reassign;
	# meanwhile hold position.
	var self_pos := Vector3(0, 0, 10)
	var ctx: RoleContext = _make_ctx(self_pos)
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_eq(d.target_position, self_pos,
			"loose puck → fall back to self_pos")


# ── Target sits on the carrier→slot spine ──────────────────────────────────

func test_target_lies_between_carrier_and_slot() -> void:
	# Carrier in NZ at z=0. Our slot at z≈21.65. Search center is
	# midpoint = z≈10.83. With one opp, CONTAIN's chosen target
	# lands in the slot-side half-space of NZ — clearly between the
	# carrier and the slot.
	var carrier_pos := Vector3(0, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],   # us, deep
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters, 200)
	var d: RoleDecision = AIRoleContain.decide(ctx)
	# Carrier at z=0, slot at ~21.65 → target.z must be > carrier.z
	# (toward slot) and < slot.z (still engaged forward).
	assert_gt(d.target_position.z, carrier_pos.z,
			"target must be on slot-side of carrier; got z=%f vs carrier.z=%f" % [d.target_position.z, carrier_pos.z])
	assert_lt(d.target_position.z, OUR_NET_Z - GameRules.SLOT_DIST_M + 0.01,
			"target must not pass the slot; got z=%f vs slot=%f" % [d.target_position.z, OUR_NET_Z - GameRules.SLOT_DIST_M])


# ── CONTAIN engages forward of where DZONE ANCHOR would sit ────────────────

func test_contain_engages_forward_of_dzone_anchor() -> void:
	# TRANS_OD scenario: opp carrier in NZ at z=0, secondary opp also
	# in NZ. Both roles see the same world. CONTAIN's search center
	# is midpoint(carrier=0, slot=21.65) ≈ 10.83; ANCHOR's is
	# midpoint(carrier=0, our_net=26.65) ≈ 13.33. So CONTAIN sits
	# MEANINGFULLY further up-ice (lower z for Team 0) than ANCHOR.
	#
	# This is the role split — CONTAIN engages forward instead of
	# camping the slot.
	var carrier_pos := Vector3(0, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx_contain: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters, 200)
	var contain_target: Vector3 = AIRoleContain.decide(ctx_contain).target_position

	var ctx_anchor: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters, 200)
	var anchor_target: Vector3 = AIRoleAnchor.decide(ctx_anchor).target_position

	# Team 0 defends +Z, so "forward" = lower z. CONTAIN should sit at
	# lower z than ANCHOR (further up-ice toward the puck).
	assert_lt(contain_target.z, anchor_target.z,
			"CONTAIN engages forward of ANCHOR in NZ-puck transition; got contain=%s anchor=%s" % [contain_target, anchor_target])
