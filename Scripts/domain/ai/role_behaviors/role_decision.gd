class_name RoleDecision
extends RefCounted

# Output of a role-behavior decide() function. The state machine reads
# this to drive steering, mouse aim, and any fire-intent transitions.

# Where steering should aim. For off-puck roles this is the move target;
# for CARRIER it's the chosen carry destination.
var target_position: Vector3 = Vector3.ZERO

# How fast `target_position` is ITSELF moving, world m/s. Set by the roles whose
# stand rides an opponent — a gap point, a cover point, a backchecker's hip —
# where the spot sweeps toward our net at the man's pace. The steering then flies
# the route in the stand's own frame instead of treating it as a parked point
# (AISteering, "moving-frame pursuit"), which is the difference between arriving
# matched to the play and arriving stopped in front of it.
#
# Vector3.ZERO (the default) means a spot on the ice: stations, zone anchors,
# carry waypoints and puck chases all leave it alone and steer exactly as before.
# It is the stand's velocity, NOT the man's — usually they are the same, but a
# stand whose geometry is doing something else (a shade tightening, a gap
# closing) is entitled to say so.
var target_velocity: Vector3 = Vector3.ZERO

# Optional aim override. When `has_aim_override` is true,
# `aim_world_pos` replaces the state machine's default mouse target
# (the ready-stance look-at toward `target_position`). Used by
# FINISHER's tip path to point the blade at the goal during a
# deflection, and by future event-reactive roles.
var aim_world_pos: Vector3 = Vector3.ZERO
var has_aim_override: bool = false

# Raise the blade off the ice (stick_lift_held) this tick. Set by
# FINISHER's reactive deflection routine when the incoming on-net shot is
# ELEVATED — a grounded blade flies under an airborne puck, so the bot
# lifts to tip it. Off-puck only (the controller ignores voluntary lifts
# while carrying). Consumed by the state machine's OFF_PUCK handler.
var lift_blade: bool = false

# Fire-intent flags. Set by CARRIER (and any role that opportunistically
# fires, like FINISHER on a tip). Mutually exclusive in practice — the
# state machine consumes whichever is true to drive its transition into
# SHOOT_PRESSED / PASS_PRESSED.
var shoot_intent: bool = false
var pass_intent: bool = false
# Receiver peer_id when pass_intent is set; -1 otherwise.
var pass_target_peer_id: int = -1

# Off-puck one-timer readiness — set by FINISHER when camped at its
# chosen `best_pos` with mouse + facing pre-aimed at the open net.
# Read by the state machine (forwards to TeamBrain so the carrier can
# reward the pass via no-charge goalie prediction; and gates the
# CHASE_PUCK fire-on-zone-entry transition when the puck arrives).
var is_one_timer_ready: bool = false

# Body-check commit — set by an on-puck defensive role (PRESSURE /
# FORECHECK F1) when AIBodyCheck says a hit on the carrier is worth
# committing to. When true, the state machine steers at `check_target`
# (the body intercept) and forces sprint so the bot drives THROUGH the
# carrier at max closing velocity — the emergent collision delivers the
# hit. `target_position` is set to the same point so steering/sprint
# agree even if a consumer ignores the flag.
var commit_check: bool = false
var check_target: Vector3 = Vector3.ZERO

# The opponent this decision soft-locked onto (5v5 zone defense), or -1.
# The state machine round-trips it into RoleContext.prev_locked_man on the
# next dispatch so the lock is sticky without per-role state.
var locked_man_pid: int = -1

# Arrive AT SPEED instead of braking to a stop at `target_position`. Off-puck
# roles normally opt into the arrival brake (station-keeping: stop on the
# spot). A role that is pacing a MOVING waypoint sets this so the state
# machine skips the arrival brake — otherwise the bot reads its advancing
# target as a station it's about to overshoot and brakes, killing momentum.
# Set by OUTLET when timing its entry to the carrier's rush so it hits the
# blue line in stride rather than parked. (The body-level offside brake still
# applies, so arriving at speed never carries the bot offside.)
var arrive_at_speed: bool = false

# FORCE the sprint on, bypassing the state machine's gap gate. The gate exists
# to keep a bot camped near its station off the throttle; a backchecker is the
# opposite case — he is behind the play and the whole job is closing that
# distance, so easing off as the gap narrows is exactly wrong. Set by the
# tracking roles (docs/transition-defense-plan.md §7); the hard exhaustion
# lockout still applies, so this can never sprint a gassed bot.
var sprint_override: bool = false

# An offensive station kept its forward stand this dispatch (the pinch read said
# we have control). Round-tripped into RoleContext.prev_held_forward_stand so the
# control threshold gets enter/hold hysteresis — a station flickering between the
# blue line and a sag is worse than either choice.
var held_forward_stand: bool = false
