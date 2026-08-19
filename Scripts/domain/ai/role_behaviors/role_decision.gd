class_name RoleDecision
extends RefCounted

# Output of a role-behavior decide() function. The state machine reads
# this to drive steering, mouse aim, and any fire-intent transitions.

# Where steering should aim. For off-puck roles this is the move target;
# for CARRIER it's the chosen carry destination.
var target_position: Vector3 = Vector3.ZERO

# How fast `target_position` is ITSELF moving, world m/s. Set only by roles whose
# stand rides an opponent, which is what lets the steering fly the route in the
# stand's own frame. Vector3.ZERO (the default) means a spot on the ice.
#
# It is the STAND's velocity, not the man's — usually the same, but a stand whose
# geometry is doing something else (a shade tightening, a gap closing) is
# entitled to say so. Publish it only for a stand the role really produced: a
# ride has no terminating condition, so a "hold where you are" fallback that also
# rides a man matches his velocity forever.
var target_velocity: Vector3 = Vector3.ZERO

# Optional aim override: `aim_world_pos` replaces the state machine's default
# mouse target (the ready-stance look-at toward `target_position`). Used by
# FINISHER's tip path to point the blade at the goal during a deflection.
var aim_world_pos: Vector3 = Vector3.ZERO
var has_aim_override: bool = false

# Raise the blade off the ice (stick_lift_held) this tick, so it can reach an
# airborne puck. Off-puck only — the controller ignores voluntary lifts while
# carrying — and consumed by the state machine's OFF_PUCK handler.
var lift_blade: bool = false

# Fire-intent flags, mutually exclusive in practice — the state machine consumes
# whichever is true to drive its transition into SHOOT_PRESSED / PASS_PRESSED.
var shoot_intent: bool = false
var pass_intent: bool = false
# Receiver peer_id when pass_intent is set; -1 otherwise.
var pass_target_peer_id: int = -1

# Off-puck one-timer readiness — camped at the chosen staging spot with mouse and
# facing pre-aimed at the open net. The state machine forwards it to TeamBrain so
# the carrier can reward the pass, and gates the CHASE_PUCK fire-on-zone-entry
# transition on it when the puck arrives.
var is_one_timer_ready: bool = false

# Body-check commit. The state machine steers at `check_target` (the body
# intercept) and forces sprint so the bot drives THROUGH the carrier at max
# closing velocity — the emergent collision delivers the hit. `target_position`
# carries the same point so steering and sprint agree even if a consumer ignores
# the flag.
var commit_check: bool = false
var check_target: Vector3 = Vector3.ZERO

# The opponent this decision is deliberately CLOSING ON, or -1. Steering drops
# him from the off-puck proximity repel, because that force models "keep
# formation space against a checker" and this bot has been told the exact
# distance to hold instead. Left in, the two fight: the repel reaches 4 m at
# weight 0.6 against an anchor pull of 1.0 while the in-zone gap ladder asks for
# ~2.7 m, so the whole gap sits inside a force pushing the defender off it. One
# axis, one controller; the role owns the gap.
#
# Only the ENGAGED man is dropped — every other opponent still repels, so a
# defender closing his man does not skate through anybody else.
var engaged_peer_id: int = -1

# The opponent this decision soft-locked onto (5v5 zone defense), or -1.
# The state machine round-trips it into RoleContext.prev_locked_man on the
# next dispatch so the lock is sticky without per-role state.
var locked_man_pid: int = -1

# Arrive AT SPEED instead of braking to a stop at `target_position`. Off-puck
# roles normally want the arrival brake (station-keeping); a role pacing a MOVING
# waypoint sets this, or the bot reads its advancing target as a station it is
# about to overshoot and brakes, killing momentum. The body-level offside brake
# still applies, so arriving at speed never carries the bot offside.
var arrive_at_speed: bool = false

# FORCE the sprint on, bypassing the state machine's gap gate. That gate keeps a
# bot camped near its station off the throttle; a backchecker is the opposite
# case — he is behind the play and the whole job is closing that distance, so
# easing off as the gap narrows is exactly wrong. The hard exhaustion lockout
# still applies, so this can never sprint a gassed bot.
var sprint_override: bool = false

# An offensive station kept its forward stand this dispatch (the pinch read said
# we have control). Round-tripped into RoleContext.prev_held_forward_stand so the
# control threshold gets enter/hold hysteresis — a station flickering between the
# blue line and a sag is worse than either choice.
var held_forward_stand: bool = false
