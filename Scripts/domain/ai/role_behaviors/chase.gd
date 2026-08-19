class_name AIRoleChase

# CHASE role behavior — NEUTRAL only. The closest peer to a loose puck.
#
# The whole decision is the shared "go get the puck" verb: race it, or hold the
# pre-contain stand when an opponent has already won it. Racing is not the right
# answer regardless of game state — pushing after a puck somebody else reaches
# first skates the chaser out of the play while the counter develops.
#
# The state machine's CHASE_PUCK takes over the actual retrieval (lead-intercept
# math, blade gate, contest drive-through); this is the "where to be" hint while
# the brain re-tick is pending.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	AIRoleHelpers.chase_puck(ctx, d)
	return d
