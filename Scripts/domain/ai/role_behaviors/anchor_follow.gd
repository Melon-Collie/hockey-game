class_name AIRoleAnchorFollow

# Trivial role behavior: skate toward the TeamBrain anchor with no aim
# override and no fire intent. Used as the dispatch fallback for any
# slot that does not yet have its own utility module (NEUTRAL roles
# CHASE / FLANK_L / FLANK_R) and for unassigned peers.
#
# When the brain hasn't yet assigned a slot, ctx.anchor is Vector3.ZERO;
# the state machine treats Vector3.ZERO as "stay put" by snapping the
# target to self_pos before applying steering.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	d.target_position = ctx.anchor if ctx.anchor != Vector3.ZERO else ctx.self_pos
	return d
