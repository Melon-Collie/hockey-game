class_name AIRoleChase

# CHASE role behavior — NEUTRAL only. The closest peer to a loose
# puck. Job: race to the puck for retrieval — WHEN the race is alive.
#
# The bot's state machine transitions to CHASE_PUCK once they're
# closest to a loose puck, taking over actual retrieval (lead-intercept
# math, blade gate, contest drive-through). This role provides the
# "where to be" hint while the brain re-tick is pending.
#
# The whole decision is the shared "go get the puck" verb
# (AIRoleHelpers.chase_puck): race it, or hold the pre-contain stand when an
# opponent has already won it. Racing is NOT the right answer regardless of
# game state — pushing after a puck somebody else reaches first just skates the
# chaser out of the play while the counter develops, the missed-pass "third man
# keeps pushing" failure.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	AIRoleHelpers.chase_puck(ctx, d)
	return d
