class_name RoleContext
extends RefCounted

# Read-only inputs that every role-behavior decide() function consumes.
# Built once per off-puck (and eventually carry) tick by the
# SkaterAgentStateMachine and passed into the role's static decide().
# Roles may not mutate these fields.

var snapshot: WorldSnapshot = null
var self_pos: Vector3 = Vector3.ZERO
var self_velocity: Vector3 = Vector3.ZERO
var team_id: int = 0
var peer_id: int = 0
# Net the bot is attacking (offensive goal). Y is 0.
var attacking_goal_pos: Vector3 = Vector3.ZERO
# Net the bot is defending (own goal). Y is 0.
var defending_goal_pos: Vector3 = Vector3.ZERO
# +1 if own goal sits at +GOAL_LINE_Z (Team 0), -1 otherwise. "Forward"
# (toward attacking goal) along Z is `-own_goal_dir`.
var own_goal_dir: float = 1.0
# TeamBrain anchor for this bot's current slot. May be Vector3.ZERO when
# unassigned (first ticks); roles fall back to self_pos in that case.
var anchor: Vector3 = Vector3.ZERO
# TeamBrain reference for queries like get_slot(other_peer_id).
var team_brain: TeamBrain = null
# Peer -> team_id lookup for opponent / teammate filtering. Live dict
# owned by PlayerRegistry; roles read with `dict.get(pid, -1)`. Used to
# be a `Callable`; downgraded to a Dictionary because role decide() and
# its helpers iterate skaters at AI dispatch rate and the Callable.call
# overhead showed up in profiles. Empty dict = nothing resolves (the
# decide() helpers all default to -1 unknown).
var team_id_by_peer: Dictionary = {}
