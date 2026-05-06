extends GutTest

# Phase 1 scaffolding tests for the role-behavior dispatch infrastructure.
# Per-role utility tests land in subsequent phases as their modules go
# in.

func _make_ctx(anchor: Vector3, self_pos: Vector3 = Vector3.ZERO) -> RoleContext:
	var ctx := RoleContext.new()
	ctx.self_pos = self_pos
	ctx.anchor = anchor
	return ctx


# ─── AIRoleAnchorFollow ────────────────────────────────────────────────────

func test_anchor_follow_targets_anchor_when_assigned() -> void:
	var ctx: RoleContext = _make_ctx(Vector3(3.0, 0.0, -8.0))
	var d: RoleDecision = AIRoleAnchorFollow.decide(ctx)
	assert_eq(d.target_position, Vector3(3.0, 0.0, -8.0))
	assert_false(d.has_aim_override)
	assert_false(d.shoot_intent)
	assert_false(d.pass_intent)


func test_anchor_follow_falls_back_to_self_pos_when_unassigned() -> void:
	# Vector3.ZERO from TeamBrain means "no slot assignment yet" — the
	# fallback should point at self_pos so we don't skate to (0, 0, 0).
	var ctx: RoleContext = _make_ctx(Vector3.ZERO, Vector3(5.0, 0.0, 5.0))
	var d: RoleDecision = AIRoleAnchorFollow.decide(ctx)
	assert_eq(d.target_position, Vector3(5.0, 0.0, 5.0))


# ─── RoleDecision defaults ────────────────────────────────────────────────

func test_role_decision_defaults_are_neutral() -> void:
	var d := RoleDecision.new()
	assert_eq(d.target_position, Vector3.ZERO)
	assert_false(d.has_aim_override)
	assert_false(d.shoot_intent)
	assert_false(d.slapper_intent)
	assert_false(d.pass_intent)
	assert_eq(d.pass_target_peer_id, -1)
