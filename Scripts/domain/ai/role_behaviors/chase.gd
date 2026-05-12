class_name AIRoleChase

# CHASE role behavior — NEUTRAL only. The closest peer to a loose
# puck. Job: race to the puck for retrieval.
#
# Trivial. The bot's state machine transitions to CHASE_PUCK once
# they're closest to a loose puck, taking over actual retrieval
# (lead-intercept math, soft-hands reception, etc.). This role
# just provides the "where to be" hint while the brain re-tick is
# pending — the target is the puck's current position.
#
# No utility AI here — there are no options to score. Race to the
# puck is the right answer regardless of game state.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		d.target_position = ctx.self_pos
		return d
	d.target_position = ctx.snapshot.puck_state.position
	return d
