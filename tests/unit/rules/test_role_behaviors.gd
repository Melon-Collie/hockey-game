extends GutTest

# Phase 1 scaffolding tests for the role-behavior dispatch infrastructure.
# Per-role utility tests land in subsequent phases as their modules go
# in.

# ─── RoleDecision defaults ────────────────────────────────────────────────

func test_role_decision_defaults_are_neutral() -> void:
	var d := RoleDecision.new()
	assert_eq(d.target_position, Vector3.ZERO)
	assert_false(d.has_aim_override)
	assert_false(d.shoot_intent)
	assert_false(d.pass_intent)
	assert_eq(d.pass_target_peer_id, -1)
