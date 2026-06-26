class_name RoleDecision
extends RefCounted

# Output of a role-behavior decide() function. The state machine reads
# this to drive steering, mouse aim, and any fire-intent transitions.

# Where steering should aim. For off-puck roles this is the move target;
# for CARRIER it's the chosen carry destination.
var target_position: Vector3 = Vector3.ZERO

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
# SHOOT_PRESSED / PASS_PRESSED / QUICK_SHOT_PRESSED.
var shoot_intent: bool = false
var pass_intent: bool = false
var quick_shot_intent: bool = false
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
