class_name Puck
extends RigidBody3D

signal puck_released()
signal puck_stripped(ex_carrier: Skater)
signal puck_touched_loose(skater: Skater)  # blade redirect (deflection, tip-in)
signal puck_body_blocked(skater: Skater)   # puck absorbed by a player's body
signal puck_touched_goalie(goalie: Goalie)  # puck contacted a goalie StaticBody3D part while uncarried
signal puck_touched_post  # puck contacted any HockeyGoal geometry while uncarried
signal puck_hit_boards     # uncarried puck struck rink boards at meaningful speed
signal puck_hit_goal_body  # uncarried puck struck net panel or skirt (non-pipe goal geometry)

@export var max_speed: float = 38.0
@export var reattach_cooldown: float = 0.5
@export var ice_height: float = 0.0175
@export var pickup_max_speed: float = 8.0
@export var deflect_min_speed: float = 14.0
@export var alignment_receive_bonus: float = 8.0
@export var deflect_blend: float = 0.5
@export var deflect_speed_retain: float = 0.7
@export var deflect_cooldown: float = 0.3
@export var deflect_elevation_angle: float = 35.0
@export var poke_strip_speed: float = 6.0
@export var poke_carrier_vel_blend: float = 0.5
@export var poke_checker_cooldown: float = 0.1
@export var body_check_strip_threshold: float = 6.0  # weight × approach_speed needed to strip
@export var body_check_puck_speed: float = 5.0
@export var hit_pickup_cooldown: float = 0.6              # seconds victim cannot pick up after a hard hit
@export var hit_pickup_cooldown_threshold: float = 6.0    # weight × approach needed to apply hit pickup cooldown
@export var body_block_dampen: float = 0.5
@export var body_block_cooldown: float = 0.1
@export var max_height: float = 3.0

var carrier: Skater = null
var pickup_locked: bool = false
# Per-skater puck pickup cooldowns. Keyed by Skater.get_instance_id() rather
# than the Skater object directly so that the typed Dictionary's erase()
# validator doesn't reject freed-instance keys when a skater is queue_freed
# (e.g. tutorial puppet bot teardown) before the per-tick cleanup loop drops
# its stale entry. Public API still takes a Skater; the int conversion is
# internal.
var _cooldown_timers: Dictionary[int, float] = {}
var _is_server: bool = false
var _pending_reset: bool = false
var _pending_reset_xz: Vector2 = Vector2.ZERO
var _clamp_at_goal_line: bool = false
# Full velocity stored by release() for every shot, applied by _integrate_forces.
# Jolt does not preserve linear_velocity set on a frozen body when it activates
# as dynamic — state.linear_velocity on the first dynamic step is zero. Storing
# and applying the full vector here ensures XYZ reach the simulation correctly.
# For elevated shots (y > 0) _integrate_forces also writes the elevated Y position.
var _pending_elevation_vel: Vector3 = Vector3.ZERO
# Belt-and-suspenders for _physics_process: skip is_airborne() zeroing the
# same frame as release() so _pending_elevation_vel reaches _integrate_forces.
var _pending_elevation: bool = false
# Callable (Skater) -> int team_id, or -1 if the skater isn't registered. Set
# by GameManager at spawn time so Puck doesn't reach upward for team checks.
var _team_resolver: Callable = Callable()

func set_team_resolver(resolver: Callable) -> void:
	_team_resolver = resolver

func _ready() -> void:
	# Puck body sits on its own layer so goal sensors can detect it.
	# Mask = LAYER_WALLS only: bounces off boards + goalie bodies, not skater bodies.
	collision_layer = Constants.LAYER_PUCK
	collision_mask  = Constants.MASK_PUCK
	continuous_cd = true
	process_physics_priority = 1  # Run after Skater.move_and_slide so blade world pos is current
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)

	var vfx := PuckVFX.new()
	vfx.name = "VFX"
	add_child(vfx)

# ── Server Mode ───────────────────────────────────────────────────────────────
func set_server_mode(is_server: bool) -> void:
	_is_server = is_server
	if not is_server:
		freeze = true

func set_client_prediction_mode(active: bool) -> void:
	if _is_server:
		return
	freeze = not active
	if not active:
		linear_velocity = Vector3.ZERO
		_clamp_at_goal_line = false

func set_goal_line_clamp(enabled: bool) -> void:
	_clamp_at_goal_line = enabled

# ── Contract for PuckController ───────────────────────────────────────────────
func get_puck_position() -> Vector3:
	return global_position

func get_puck_velocity() -> Vector3:
	return linear_velocity

func set_puck_position(pos: Vector3) -> void:
	global_position = pos

func set_puck_velocity(vel: Vector3) -> void:
	linear_velocity = vel

# Used by client-side prediction release (notify_local_release). Applies the
# same _pending_elevation_vel treatment as release() so Jolt's first dynamic
# integration step gets the full XYZ vector instead of starting at zero.
func apply_release_velocity(vel: Vector3) -> void:
	linear_velocity = vel
	if vel.y > 0.0:
		_pending_elevation_vel = vel
		_pending_elevation = true

func get_carrier() -> Skater:
	return carrier

# Returns linear_velocity, OR _pending_elevation_vel when release() has just
# fired and Jolt hasn't yet applied it (Jolt zeroes velocity on the first
# dynamic step after unfreeze, so release() stores the full vector here for
# _integrate_forces to write next tick). Use this from same-frame consumers
# of the puck_released signal — `linear_velocity` reads zero in that window.
func get_release_velocity() -> Vector3:
	if not _pending_elevation_vel.is_zero_approx():
		return _pending_elevation_vel
	return linear_velocity

func set_carrier(skater: Skater) -> void:
	carrier = skater
	freeze = true

func clear_carrier() -> void:
	carrier = null
	freeze = false

# ── Cooldown Helpers ──────────────────────────────────────────────────────────
func is_on_cooldown(skater: Skater) -> bool:
	return _cooldown_timers.get(skater.get_instance_id(), 0.0) > 0.0

func _set_cooldown(skater: Skater, duration: float) -> void:
	# Take the max with any existing entry so a shorter cooldown set immediately
	# after a longer one (e.g. body_block_cooldown 0.1s right after reattach 0.5s)
	# never shortens the in-flight cooldown.
	var id: int = skater.get_instance_id()
	_cooldown_timers[id] = maxf(_cooldown_timers.get(id, 0.0), duration)

func set_skater_cooldown(skater: Skater, duration: float) -> void:
	_set_cooldown(skater, duration)

func remove_skater_cooldown(skater: Skater) -> void:
	_cooldown_timers.erase(skater.get_instance_id())

# ── Physics ───────────────────────────────────────────────────────────────────
func apply_blade_deflect(skater: Skater) -> void:
	# Reflect off the blade face — angle depends on how the player has angled
	# their stick, not just where the puck contacted.
	var contact_normal: Vector3 = skater.get_blade_face_normal(linear_velocity)

	var new_vel: Vector3 = PuckCollisionRules.deflect_velocity(
			linear_velocity, contact_normal, deflect_blend, deflect_speed_retain)

	if skater.is_elevated:
		var new_dir: Vector3 = PuckCollisionRules.apply_deflection_elevation(
				new_vel.normalized(), deflect_elevation_angle)
		new_vel = new_dir * new_vel.length()

	linear_velocity = new_vel
	_set_cooldown(skater, deflect_cooldown)
	puck_touched_loose.emit(skater)

func on_body_block(blocker: Skater, dampen_override: float = -1.0) -> void:
	if not _is_server:
		return
	if pickup_locked:
		return
	if blocker.is_ghost:
		return
	if carrier != null:
		return  # only deflect loose/airborne pucks, not carried ones
	var body_world: Vector3 = blocker.global_position
	body_world.y = 0.0
	var puck_pos: Vector3 = global_position
	puck_pos.y = 0.0
	var contact_normal: Vector3 = puck_pos - body_world
	if contact_normal.length() < 0.001:
		contact_normal = -blocker.global_transform.basis.z
	contact_normal = contact_normal.normalized()
	var effective_dampen: float = dampen_override if dampen_override >= 0.0 else body_block_dampen
	linear_velocity = PuckCollisionRules.body_block_velocity(
			linear_velocity, contact_normal, effective_dampen)
	_set_cooldown(blocker, body_block_cooldown)
	puck_body_blocked.emit(blocker)

func on_body_check(checker: Skater, victim: Skater, impact_force: float, hit_direction: Vector3) -> void:
	if not _is_server:
		return
	if checker.is_ghost or victim.is_ghost:
		return
	if impact_force < hit_pickup_cooldown_threshold:
		return
	# Hard hits temporarily deny the victim a pickup, even if they weren't carrying.
	_set_cooldown(victim, hit_pickup_cooldown)
	if carrier == null or carrier != victim:
		return
	if pickup_locked:
		return
	if impact_force < body_check_strip_threshold:
		return
	_body_check_strip(checker, hit_direction)

func _body_check_strip(checker: Skater, hit_direction: Vector3) -> void:
	var ex_carrier: Skater = carrier
	clear_carrier()
	linear_velocity = PuckCollisionRules.body_check_strip_velocity(hit_direction, body_check_puck_speed)
	_set_cooldown(ex_carrier, reattach_cooldown)
	_set_cooldown(checker, poke_checker_cooldown)
	puck_stripped.emit(ex_carrier)
	puck_released.emit()

func apply_poke_check(checker_skater: Skater) -> void:
	var ex_carrier: Skater = carrier  # capture before clear_carrier()
	var fallback_dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	clear_carrier()
	linear_velocity = PuckCollisionRules.poke_strip_velocity(
			checker_skater.blade_world_velocity,
			ex_carrier.blade_world_velocity,
			ex_carrier.global_position,
			checker_skater.global_position,
			poke_carrier_vel_blend,
			poke_strip_speed,
			fallback_dir)
	_set_cooldown(ex_carrier, reattach_cooldown)
	_set_cooldown(checker_skater, poke_checker_cooldown)
	puck_stripped.emit(ex_carrier)
	puck_released.emit()

# Stick-lift strip: unlike a poke (which squirts the puck off the blade contact),
# a lifted stick just leaves the puck where it was being carried — so it keeps
# travelling in the carrier's direction at the carrier's speed, as if the carry
# simply continued without the stick on it. Horizontal only; a stationary
# carrier's puck stays put (the reattach cooldown still denies an instant
# re-grab). Same cooldowns + signals as apply_poke_check so the carrier-clear,
# stats, and victim-notify paths fire identically.
func apply_stick_lift_strip(checker_skater: Skater) -> void:
	var ex_carrier: Skater = carrier  # capture before clear_carrier()
	clear_carrier()
	linear_velocity = Vector3(ex_carrier.velocity.x, 0.0, ex_carrier.velocity.z)
	_set_cooldown(ex_carrier, reattach_cooldown)
	_set_cooldown(checker_skater, poke_checker_cooldown)
	puck_stripped.emit(ex_carrier)
	puck_released.emit()
# blade_world_velocity / cooldown table entry), so it gets its own entry
# point. Strip velocity uses the goalie's blade position + the controller's
# computed blade velocity as the checker inputs.
#
# No checker-side cooldown — the goalie's lunge cooldown already prevents
# spam pokes, and adding the goalie to the per-skater cooldown table would
# fight every other system that filters by Skater identity.
func apply_goalie_poke_check(blade_pos: Vector3, blade_vel: Vector3) -> void:
	var ex_carrier: Skater = carrier
	var fallback_dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	clear_carrier()
	linear_velocity = PuckCollisionRules.poke_strip_velocity(
			blade_vel,
			ex_carrier.blade_world_velocity,
			ex_carrier.global_position,
			blade_pos,
			poke_carrier_vel_blend,
			poke_strip_speed,
			fallback_dir)
	_set_cooldown(ex_carrier, reattach_cooldown)
	puck_stripped.emit(ex_carrier)
	puck_released.emit()


func release(direction: Vector3, power: float) -> void:
	var ex_carrier: Skater = carrier
	# Set position while still frozen so Jolt activates from the correct state.
	# Slapshot wind-up: the blade is overhead and pulled back, but the puck has
	# been pinned to a stable ice offset via get_carry_target_global. Read from
	# that pin instead of the elevated blade contact so the shot fires from
	# where the puck visibly is.
	if ex_carrier != null:
		if ex_carrier.is_slapshot_pinning():
			global_position = ex_carrier.get_carry_target_global()
		else:
			global_position = ex_carrier.get_blade_contact_global()
	if direction.y > 0:
		global_position.y = ice_height + 0.1
		_pending_elevation = true
	else:
		global_position.y = ice_height
	_pending_elevation_vel = direction * power
	clear_carrier()
	if ex_carrier != null:
		_set_cooldown(ex_carrier, reattach_cooldown)
	puck_released.emit()

func drop() -> void:
	var ex_carrier: Skater = carrier
	clear_carrier()
	linear_velocity = Vector3.ZERO
	if ex_carrier != null:
		_set_cooldown(ex_carrier, reattach_cooldown)
	puck_released.emit()

func reset(at_xz: Vector2 = Vector2.ZERO) -> void:
	carrier = null
	freeze = false  # ensure _integrate_forces is called on the next step
	_cooldown_timers.clear()
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_pending_reset = true
	_pending_reset_xz = at_xz
	puck_released.emit()

func is_airborne() -> bool:
	return position.y > ice_height + 0.05

# One-shot spark burst at the puck for a stick-lift strip. Delegated to PuckVFX
# (child "VFX"); the burst anchors to the puck, which sits at the dislodge point.
func fire_stick_lift_vfx() -> void:
	var vfx := get_node_or_null("VFX") as PuckVFX
	if vfx != null:
		vfx.fire_stick_lift_burst()

func _on_body_entered(body: Node3D) -> void:
	if carrier != null:
		return
	if body.get_parent() is Goalie:
		puck_touched_goalie.emit(body.get_parent() as Goalie)
	elif body is HockeyGoal:
		puck_touched_post.emit()
	elif body.get_parent() is HockeyGoal:
		if linear_velocity.length() >= 1.0:
			puck_hit_goal_body.emit()
	elif body is StaticBody3D and linear_velocity.length() >= 1.0:
		puck_hit_boards.emit()

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _pending_reset:
		_pending_reset = false
		state.transform = Transform3D(Basis(),
				Vector3(_pending_reset_xz.x, ice_height, _pending_reset_xz.y))
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		_pending_reset_xz = Vector2.ZERO
		return
	if not _pending_elevation_vel.is_zero_approx():
		# Write the full velocity vector directly into Jolt's physics state.
		# Jolt zeros state.linear_velocity on the first dynamic step after a
		# body unfreezes, so velocity set on a frozen body is lost without this.
		state.linear_velocity = _pending_elevation_vel
		if _pending_elevation_vel.y > 0.0:
			state.transform.origin.y = ice_height + 0.1
		_pending_elevation_vel = Vector3.ZERO
	if state.linear_velocity.length() > max_speed:
		state.linear_velocity = state.linear_velocity.normalized() * max_speed
	if state.transform.origin.y > ice_height + max_height:
		state.transform.origin.y = ice_height + max_height
		if state.linear_velocity.y > 0.0:
			state.linear_velocity.y = 0.0
	if _clamp_at_goal_line:
		var z: float = state.transform.origin.z
		var goal_z: float = GameRules.GOAL_LINE_Z
		if abs(z) >= goal_z and z * state.linear_velocity.z > 0.0 \
				and abs(state.transform.origin.x) <= GameRules.NET_HALF_WIDTH:
			state.transform.origin.z = goal_z * sign(z)
			state.linear_velocity = Vector3.ZERO

func _physics_process(delta: float) -> void:
	if not _is_server:
		return

	# Tick per-skater cooldowns regardless of carrier state. Keys are int
	# instance_ids; resolve back via instance_from_id and drop entries whose
	# skater has been freed (puppet bot teardown, etc.) alongside the
	# naturally-expired ones. The early-out + lazily-created expiry list keep
	# this allocation-free in the common no-cooldowns case (per-tick path).
	if not _cooldown_timers.is_empty():
		var _expired: Array[int] = []
		for id: int in _cooldown_timers:
			var skater: Skater = instance_from_id(id) as Skater
			if not is_instance_valid(skater):
				_expired.append(id)
				continue
			_cooldown_timers[id] -= delta
			if _cooldown_timers[id] <= 0.0:
				_expired.append(id)
		for id: int in _expired:
			_cooldown_timers.erase(id)

	if carrier != null:
		_pending_elevation = false
		_pending_elevation_vel = Vector3.ZERO
		freeze = true
		# Pin at the carry target — same as blade contact when blade is
		# centered, but inverse-offset from the blade's actual position when
		# the IK shifted the marker for forehand/backhand carry. Result: puck
		# stays at the cursor while the blade renders to one side.
		global_position = carrier.get_carry_target_global()
		global_position.y = ice_height
	elif _pending_elevation:
		# Elevated release this frame: skip is_airborne() so linear_velocity.y
		# is not zeroed before _integrate_forces can apply _pending_elevation_vel.
		_pending_elevation = false
	elif not is_airborne():
		# Max-speed clamp already runs every physics substep in _integrate_forces.
		linear_velocity.y = 0.0
		position.y = ice_height
