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
# Loft mode (0 flat / 1 low saucer / 2 high), from the skater's input frame.
# Replicated so AI off-puck bots (e.g., FINISHER) can read teammate loft
# directly instead of inferring from puck physics.
var elevation_level: int = 0
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
# Body-check stagger: seconds of thrust-penalty recovery remaining on the victim.
# Replicated for the same reason as stamina — the local player's reconcile snaps
# it to the host baseline before replay and it decays deterministically forward
# (see BodyCheckRules / SkaterController._apply_movement). Host-authoritative: only
# the host sets it on a hit; clients receive the resolved value off the wire.
var stagger_timer: float = 0.0
# Body-check knockdown: seconds of full movement lockout remaining. Replicated for
# the same reason as stagger_timer — the local victim's reconcile snaps it to the
# host baseline and it decays deterministically forward. Host-authoritative.
var knockdown_timer: float = 0.0
# Movement INTENT: the raw WASD vector (world frame, 8-way quantized on the
# wire) and the brake hold. Originally cosmetic-only (the gait reads what the
# player is TRYING to do — crossover intent, deliberate hockey stop, no-keys
# glide — a beat before velocity responds); since stage-3 forward prediction
# these are LOAD-BEARING: they drive SkaterMovementRules.integrate_forward on
# both the client render (RemoteController) and the host claim rewind
# (LagCompRewind.forward_predict_skater), so render == rewind depends on them
# surviving the rewind snapshot (StateBufferManager copies them). One byte on
# the wire (v15).
var move_intent: Vector2 = Vector2.ZERO
var brake_intent: bool = false
# Resolved sprint-boost state (held + moving + stamina available), from
# SkaterController.sprint_active on the simulating machine. Drives the sprint
# gait read (longer strides, deeper sit, forward lean) on client-rendered
# remotes, which never resolve sprint themselves — and, since stage-3, the
# sprint term of the forward prediction (load-bearing, like move_intent
# above). Bit 5 of the intent byte (v16).
var sprint_active: bool = false
# Resolved hit-commit (the Hit button held + stamina available), from
# SkaterController.hit_committed on the simulating machine. Replicated so the body-
# check resolver reads a REMOTE victim's brace and a remote attacker's full-vs-
# passive delivery correctly on a client (host knows all locally) — the brace moved
# off brake onto the hit button. Bit 6 of the intent byte (no block growth).
var hit_committed: bool = false
# Which side of the still puck the frozen blade addresses during a wrister aim
# (face-normal sign, ±1) — the re-address tell, so render-only clients show the
# shooter's blade on the side the shot will push from. Meaningful ONLY while
# shot_state == WRISTER_AIM (validity is implicit in the state, so the wire
# spends one bit); garbage otherwise, and consumers must gate on the state.
var wrister_address_side: int = 1
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
		elevation_level,
		blade_up,
		stamina,
		sprint_locked,
		stagger_timer,
		move_intent,
		brake_intent,
		sprint_active,
		knockdown_timer,
		hit_committed,
		wrister_address_side,
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
	elevation_level = s.elevation_level
	blade_up = s.blade_up
	shot_state = s.shot_state
	shot_charge = s.shot_charge
	stamina = s.stamina
	sprint_locked = s.sprint_locked
	stagger_timer = s.stagger_timer
	knockdown_timer = s.knockdown_timer
	move_intent = s.move_intent
	brake_intent = s.brake_intent
	sprint_active = s.sprint_active
	hit_committed = s.hit_committed
	wrister_address_side = s.wrister_address_side
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
		state.elevation_level = data[12]
	if data.size() > 13:
		state.blade_up = data[13]
	if data.size() > 15:
		state.stamina = data[14]
		state.sprint_locked = data[15]
	if data.size() > 16:
		state.stagger_timer = data[16]
	if data.size() > 18:
		state.move_intent = data[17]
		state.brake_intent = data[18]
	if data.size() > 19:
		state.sprint_active = data[19]
	if data.size() > 20:
		state.knockdown_timer = data[20]
	if data.size() > 21:
		state.hit_committed = data[21]
	if data.size() > 22:
		state.wrister_address_side = data[22]
	return state
