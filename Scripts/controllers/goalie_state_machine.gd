class_name GoalieStateMachine
extends RefCounted

# Owns the goalie's current AI state. RECOVERING is the stand-up window after
# butterfly (vulnerable beat where the goalie can't drop/RVH/react); SLIDING is
# the committed butterfly slide (push off, translate to seal). COILING sits
# between BUTTERFLY and SLIDING: the goalie has committed to a slide and is
# rotating around the planted (pivot) foot before the push-off translates it.
# READY is the half-down active stance when the puck is in the goalie's
# defensive half — distinct from STANDING so animation can show engagement.
# VH_LEFT / VH_RIGHT are the post-integrated stance for a sharp-angle SHOT
# threat still in FRONT of the goal line (post pad vertical for short-side-high
# coverage); RVH_* stays the at/below-goal-line seal (wraps, walkouts). New
# values are APPENDED so existing numeric values — duplicated in
# domain/ai/role_behaviors/carrier.gd and on the wire as state_enum (u8) —
# are preserved.
# COVERING is the smother: the goalie collapses over a loose puck in the
# crease when every sweep lane is covered — the real cover/freeze, resolved by
# ruleset (NHL: whistle + defensive-zone faceoff; ARCADE: short hold, then a
# live release). Appended last to preserve wire numbering.
enum State {
	STANDING, BUTTERFLY, RECOVERING, RVH_LEFT, RVH_RIGHT, READY, SLIDING, COILING,
	VH_LEFT, VH_RIGHT, COVERING,
}

signal transitioned(prev: State, new: State)

var current: State = State.STANDING
# Counts up while in RECOVERING; reset on entry. The controller checks it
# against `recovery_duration` to decide when to return to READY/STANDING.
var recovery_timer: float = 0.0

func reset() -> void:
	current = State.STANDING
	recovery_timer = 0.0

func is_butterfly() -> bool:
	return current == State.BUTTERFLY

# "On the ice" — the three down states share the butterfly pose shape (pads
# splayed). Use for code that should treat the goalie as "in a butterfly-ish
# stance" regardless of whether they're coiled, mid-slide, or stationary.
func is_down() -> bool:
	return current == State.BUTTERFLY \
			or current == State.COILING \
			or current == State.SLIDING

# Upright = goalie can drop to butterfly / engage RVH from this state. Both
# STANDING and READY qualify; RECOVERING does not (it's the vulnerable
# stand-up window).
func is_upright() -> bool:
	return current == State.STANDING or current == State.READY

func is_rvh() -> bool:
	return current == State.RVH_LEFT or current == State.RVH_RIGHT

func is_vh() -> bool:
	return current == State.VH_LEFT or current == State.VH_RIGHT

# Post-integrated — hugging a post in either family (RVH at/below the goal
# line, VH for the in-front sharp-angle shot threat). Use for code that gates
# on "the goalie is committed to a post", regardless of which stance.
func is_post_integrated() -> bool:
	return is_rvh() or is_vh()

# Sets the state and emits `transitioned(prev, new)`. Returns true if the
# state actually changed (no-op when new_state == current).
func transition_to(new_state: State) -> bool:
	if new_state == current:
		return false
	var prev: State = current
	current = new_state
	transitioned.emit(prev, new_state)
	return true
