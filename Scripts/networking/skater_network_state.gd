class_name SkaterNetworkState

var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var blade_position: Vector3 = Vector3.ZERO
var top_hand_position: Vector3 = Vector3.ZERO
var upper_body_rotation_y: float = 0.0
var facing: Vector2 = Vector2.ZERO
var facing_angular_velocity: float = 0.0      # rad/s; used for Hermite interpolation on remotes
var upper_body_angular_velocity: float = 0.0  # rad/s
var shot_state: int = 0
var shot_charge: float = 0.0
var last_processed_host_timestamp: float = 0.0
var is_ghost: bool = false
# True when the skater is in elevated-shot mode (PlayerInput
# elevation_up held). Replicated so AI off-puck bots (e.g., FINISHER)
# can read teammate flags directly instead of inferring from puck
# physics.
var is_elevated: bool = false
# True when the blade is lifted off the ice (own Q held, or involuntarily
# popped up by an opponent's stick lift). Effective value: the receiver only
# needs the resolved "is the blade up" answer for rendering and the
# on-ice/off-ice interaction gate.
var blade_up: bool = false
# Sprint stamina (0..1 fraction of the full pool) and the exhaustion lockout
# flag. Both replicated so the local player's reconcile can snap them to the
# host's authoritative value before replaying inputs — same treatment as
# velocity. See StaminaRules / LocalController.reconcile.
var stamina: float = 1.0
var sprint_locked: bool = false
var host_timestamp: float = 0.0         # host-only, not serialized
var blade_contact_world: Vector3 = Vector3.ZERO  # host-only, not serialized
# World-space top-hand (grip) point. host-only, not serialized — paired with
# blade_contact_world to form the shaft segment for stick-lift claim
# resolution. The wire `top_hand_position` is upper-body-local, so it can't be
# used for host-side world-space geometry.
var top_hand_world: Vector3 = Vector3.ZERO  # host-only, not serialized

func to_array() -> Array:
	return [
		position,
		velocity,
		blade_position,
		top_hand_position,
		upper_body_rotation_y,
		facing,
		last_processed_host_timestamp,
		is_ghost,
		shot_state,
		shot_charge,
		facing_angular_velocity,
		upper_body_angular_velocity,
		is_elevated,
		blade_up,
		stamina,
		sprint_locked,
	]

func copy_from(s: SkaterNetworkState) -> void:
	position = s.position
	velocity = s.velocity
	blade_position = s.blade_position
	top_hand_position = s.top_hand_position
	upper_body_rotation_y = s.upper_body_rotation_y
	facing = s.facing
	facing_angular_velocity = s.facing_angular_velocity
	upper_body_angular_velocity = s.upper_body_angular_velocity
	last_processed_host_timestamp = s.last_processed_host_timestamp
	is_ghost = s.is_ghost
	is_elevated = s.is_elevated
	blade_up = s.blade_up
	shot_state = s.shot_state
	shot_charge = s.shot_charge
	stamina = s.stamina
	sprint_locked = s.sprint_locked
	host_timestamp = s.host_timestamp
	blade_contact_world = s.blade_contact_world
	top_hand_world = s.top_hand_world

static func from_array(data: Array) -> SkaterNetworkState:
	var state := SkaterNetworkState.new()
	state.position = data[0]
	state.velocity = data[1]
	state.blade_position = data[2]
	state.top_hand_position = data[3]
	state.upper_body_rotation_y = data[4]
	state.facing = data[5]
	state.last_processed_host_timestamp = data[6]
	state.is_ghost = data[7]
	state.shot_state = data[8]
	state.shot_charge = data[9]
	state.facing_angular_velocity = data[10]
	state.upper_body_angular_velocity = data[11]
	if data.size() > 12:
		state.is_elevated = data[12]
	if data.size() > 13:
		state.blade_up = data[13]
	if data.size() > 15:
		state.stamina = data[14]
		state.sprint_locked = data[15]
	return state
