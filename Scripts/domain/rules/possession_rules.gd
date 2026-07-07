class_name PossessionRules
## Pure test for when a puck touch becomes ESTABLISHED possession — the
## stat-attribution notion of "control" (NHL scorer: the ability to make a
## deliberate play with the puck), distinct from the AI's team-level
## PossessionState. A momentary proximity-attach in a scramble is a touch,
## not possession; possession is established by holding the puck long enough
## to prove control, or instantly by making a deliberate play with it (a
## pass or shot from carry — a one-touch breakout pass IS control).
##
## Consumed by PossessionTracker (host-side), which feeds the establishment
## events to the stat trackers: takeaways/giveaways/faceoff wins credit only
## at establishment, and the assist chain breaks only on an opposing
## ESTABLISHED possession.

# Carrying the puck this long establishes possession on its own. Below this,
# a touch that ends in a strip or fumble was never possession at all.
const ESTABLISH_HOLD_S: float = 0.75


static func is_established(hold_seconds: float, made_deliberate_play: bool) -> bool:
	return made_deliberate_play or hold_seconds >= ESTABLISH_HOLD_S
