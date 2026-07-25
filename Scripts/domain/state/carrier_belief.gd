class_name CarrierBelief
extends RefCounted

# The bots' shared belief about WHO CONTROLS THE PUCK, lagged behind the truth by
# a reaction delay. Owned by GameManager, which writes `perceived` onto the AI
# snapshot so the team brains and role behaviors read a possession signal a human
# could plausibly have — you cannot re-read a play the instant the puck changes
# hands.
#
# SCOPE — this is TEAM SHAPE only. It answers "are we still on offense?", which
# is deliberately slow and sticky. It must NOT be used to decide whether a bot
# goes and gets a live puck: that is individual reactivity, it runs on the
# agent's own clock against the REAL carrier (SkaterAgentStateMachine
# ._loose_elapsed_s), and conflating the two is what made bots skate past loose
# pucks for the whole reaction window.
#
# COMMIT RULE — divergence time accumulates from the FIRST tick the truth differs
# from the belief, and resets only when the truth matches it again. So:
#   • a blip that REVERTS inside the window is absorbed (the revert resets it) —
#     a puck grazing a stick causes no twitch, which is the point of the delay;
#   • a genuine run of DISTINCT carriers still commits on schedule.
# The earlier rule restarted on every change, which met the de-twitch goal but
# inverted under load: through a scramble the clock reset on each new toucher, so
# the belief could stall far past `delay` — precisely when a possession read
# matters most. Bounded commit is what makes the delay a difficulty lever rather
# than an open-ended stall.
#
# Stateful (a per-match object, not a static rule) so the hot path carries no
# per-tick allocation: GameManager holds one and calls update() each frame.

# The lagged belief consumers read. -1 = nobody.
var perceived: int = -1
# Seconds the truth has been continuously DIFFERENT from `perceived`. Counting up
# from zero (rather than down from `delay`) means there is no arming step: a
# freshly constructed or reset belief behaves identically to a settled one, and
# the delay can change between ticks (difficulty swap) without stranding a
# half-spent countdown.
var _diverged_for: float = 0.0


# Match start / world teardown — drop any belief carried in from a previous game.
func reset() -> void:
	perceived = -1
	_diverged_for = 0.0


# Advance one tick and return the belief. `delay` <= 0 is the perfect-reaction
# case (difficulty with no lag): the belief tracks truth exactly.
func update(real_carrier: int, delay: float, delta: float) -> int:
	if delay <= 0.0:
		perceived = real_carrier
		_diverged_for = 0.0
		return perceived
	if real_carrier == perceived:
		_diverged_for = 0.0     # nothing pending, or a blip reverted
	else:
		_diverged_for += delta
		if _diverged_for >= delay:
			# Commit to the CURRENT truth, not whatever opened the window — after
			# the reaction time you see what is actually happening now, not the
			# intermediate you missed.
			perceived = real_carrier
			_diverged_for = 0.0
	return perceived
