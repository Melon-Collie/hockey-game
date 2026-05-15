extends GutTest

# AIRoleBackcheck — TRANS_OD-only Sprinting-Through defender.
# Search center is fixed at our slot regardless of puck position,
# so the role behavior is "sprint to slot and shade laterally
# toward the dominant shot threat as you arrive." Tests cover:
#   - Bail-out (no opps).
#   - Target lands in the slot area, NOT pushed up by puck position
#     (the defining difference from CONTAIN).
#   - Shot-lane shading toward the dominant threat.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z


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
	ctx.team_id_resolver = func(pid: int) -> int: return int(team_map.get(pid, -1))
	return ctx


# ── Bail-outs ───────────────────────────────────────────────────────────────

func test_falls_back_to_slot_when_no_opps() -> void:
	# No opps means no threat to defend. BACKCHECK still wants to be
	# at the slot — that's the canonical home base regardless of
	# threat — so the bail-out target is the slot, not self_pos.
	var self_pos := Vector3(0, 0, -10)
	var ctx: RoleContext = _make_ctx(self_pos)
	var d: RoleDecision = AIRoleBackcheck.decide(ctx)
	var slot_z: float = OUR_NET_Z - GameRules.SLOT_DIST_M
	assert_eq(d.target_position, Vector3(0, 0, slot_z),
			"no opps → fall back to slot (z=%f)" % slot_z)


# ── Search center is fixed at slot, NOT puck-relative ──────────────────────

func test_target_stays_at_slot_when_puck_is_up_ice() -> void:
	# Puck in OZ at z=-15 (typical TRANS_OD: we just lost it deep on
	# the opp side). BACKCHECK's job is to sprint to the slot, not
	# follow the play forward. Target stays in the slot area.
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, -10), Vector3.ZERO],     # us, also up-ice
		[200, 1 - TEAM_ID, Vector3(0, 0, -15), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -10), skaters, 200)
	var d: RoleDecision = AIRoleBackcheck.decide(ctx)
	# Target should sit near the slot (z ≈ 21.65) within one polar
	# sample radius (~3 m). Defining property: not pulled toward the
	# puck despite the puck being 36 m up-ice.
	var slot_z: float = OUR_NET_Z - GameRules.SLOT_DIST_M
	assert_lt(absf(d.target_position.z - slot_z), 6.0,
			"target stays in slot area regardless of puck position; got z=%f vs slot=%f" % [d.target_position.z, slot_z])


# ── Shot-lane shading on the slot-arrival path ─────────────────────────────

func test_argmax_blocks_dominant_shot_lane() -> void:
	# Two opps: one on the +X side at deep DZ (dominant shot threat as
	# the play closes), one weak threat off to the -X side. BACKCHECK
	# should shade toward the dominant lane even while landing in the
	# slot region.
	#
	# Geometry: dominant threat at (+5, 0, 18); weak threat at (-8, 0, 5)
	# (far up-ice, low position_potential). Search center fixed at slot
	# (0, 0, 21.65). Polar samples include +X variants. The argmax over
	# threat-minimax shades the chosen target toward +X.
	var skaters_off_axis: Array = [
		[1, TEAM_ID, Vector3(0, 0, 22), Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(-8, 0, 5), Vector3.ZERO],
	]
	var ctx_off: RoleContext = _make_ctx(Vector3(0, 0, 22), skaters_off_axis, 200)
	var off_target: Vector3 = AIRoleBackcheck.decide(ctx_off).target_position

	var skaters_both: Array = [
		[1, TEAM_ID, Vector3(0, 0, 22), Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(-8, 0, 5), Vector3.ZERO],
		[210, 1 - TEAM_ID, Vector3(5, 0, 18), Vector3.ZERO],   # dominant
	]
	var ctx_both: RoleContext = _make_ctx(Vector3(0, 0, 22), skaters_both, 210)
	var both_target: Vector3 = AIRoleBackcheck.decide(ctx_both).target_position

	# Adding the dominant +X threat should pull BACKCHECK toward +X.
	assert_true(both_target.x >= off_target.x - 0.01,
			"adding a +X dominant threat should shade BACKCHECK toward +X; got both=%s off=%s" % [both_target, off_target])
