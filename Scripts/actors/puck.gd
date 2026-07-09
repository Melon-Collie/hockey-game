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
@export var nudge_cooldown: float = 0.30  # short re-grab denial after a self nudge tap
@export var ice_height: float = 0.0175  # = Puck.tscn cylinder half-height (0.035/2); disc bottom rests on y=0
@export var pickup_max_speed: float = 8.0
# ABSOLUTE puck-speed threshold for catch-vs-deflect (world frame — reception
# deliberately ignores the receiver's own velocity; see CLAUDE.md, "reception
# is purely reactive"). Sits above every pass-shaped launch (snap 14, AI
# charged passes ramp to 20, soft-sweep wristers under 20 by gesture) so a
# pass is receivable at ANY blade angle; the alignment bonus extends the
# ceiling to 28 m/s for a perfectly squared blade — reaching into the shot
# bands (wrister max 33 base / slapper 40), which otherwise always deflect.
# See PuckReceptionRules.should_receive.
@export var deflect_min_speed: float = 20.0
@export var alignment_receive_bonus: float = 8.0
# How reflective a deflection is: 0 = pass-through with a nudge, 1 = pure bounce
# off the blade face. Higher = the puck follows your blade angle more directly,
# so deliberate redirects are more aim-able (and the angle cap below keeps the
# near-head-on caroms it would otherwise reintroduce in check).
@export var deflect_blend: float = 0.75
# Speed-dependent deflection feel (tune to taste). Both effects ease from their
# soft-puck value toward their hard-puck value as puck speed climbs to
# deflect_speed_ref — a soft pass is steerable, a hard shot only glances.
#   retain: energy kept. Hard pucks shed more so deflections don't pinball.
@export var deflect_speed_retain: float = 0.7       # soft-puck (low speed)
@export var deflect_speed_retain_min: float = 0.5   # hard-puck (at/above ref); < 0 disables falloff
#   angle: cap on how far the puck bends off its incoming line.
@export var deflect_max_angle_deg: float = 70.0     # soft-puck — sharp, steerable redirect
@export var deflect_max_angle_deg_min: float = 30.0 # hard-puck — shallow glancing tip; < 0 disables falloff
@export var deflect_speed_ref: float = 30.0         # speed (m/s) at which both falloffs bottom out
@export var deflect_cooldown: float = 0.3
@export var deflect_elevation_angle: float = 35.0
# Poke exit speed now scales with the blade-contest momentum (see
# PuckCollisionRules.poke_strip_velocity): a soft poke floors at min, a hard sweep
# squirts the puck up to max. Old behavior was a flat 6.0 regardless of how hard
# the poke was.
@export var poke_strip_min_speed: float = 3.0
@export var poke_strip_max_speed: float = 9.0
@export var poke_carrier_vel_blend: float = 0.5
@export var poke_checker_cooldown: float = 0.1
# Delivered victim-impulse (BodyCheckRules.puck_strip_impulse: attacker transfer ×
# both masses × closing speed) needed to knock the puck off the carrier. 2.7 keeps
# the pre-Physical baseline strip point (~6 m/s closing, medium build) while now
# letting Physical/mass move it: an enforcer strips at lower closing speed, a
# low-Physical hit needs much more.
@export var body_check_strip_threshold: float = 2.7
@export var body_check_puck_speed: float = 3.0           # soft-strip trickle pace along the hit line
@export var body_check_loose_speed: float = 0.8          # forward carry a full-strength hit leaves (puck drops loose at contact)
@export var body_check_strip_ref_impulse: float = 11.0   # delivered impulse that fully deadens the strip (puck jarred dead)
@export var hit_pickup_cooldown: float = 0.6              # seconds victim cannot pick up after a hard hit
@export var hit_pickup_cooldown_threshold: float = 2.7    # delivered victim-impulse needed to apply hit pickup cooldown (see body_check_strip_threshold)
@export var body_block_dampen: float = 0.5
@export var body_block_cooldown: float = 0.1
# Vertical clamp: the puck's Y is capped at ice_height + max_height in
# _integrate_forces. Must stay BELOW the rink's collision top
# (HockeyRink.COLLISION_OVERGLASS_TOP, 3.2 m) — otherwise an elevated deflection
# that pegs this clamp sits above the boards and escapes the rink. If you raise
# this, raise COLLISION_OVERGLASS_TOP to keep the margin.
@export var max_height: float = 3.0

# ── Save-rebound control (host-authoritative) ─────────────────────────────────
# A real goalie controls rebounds instead of caroming every shot back into the
# slot. On a controlled save (chest/glove catch at any speed, or an easy pad/
# blocker save) the rebound is deadened to a crawl the goalie's crease-sweep then
# clears; hard pad saves and stick contacts keep the live restitution rebound
# (the beatable scramble chance). See GoalieSaveRules. Deadening is pose-neutral
# rebound control, correct under every ruleset — a whistle-on-cover would be a
# separate, ruleset-gated layer on top. Tunable so feel can be dialed in-editor.
@export var save_deaden_pad_max_speed: float = 28.0  # pad/blocker saves faster than this stay live (≈63 mph — above a solid wrister, below hard shots/slappers)
@export var save_deaden_drop_speed: float = 1.2      # deadened exit-speed ceiling (m/s)
@export var save_deaden_glove_retain: float = 0.0    # glove catch — kill it dead
@export var save_deaden_chest_retain: float = 0.12
@export var save_deaden_pad_retain: float = 0.35
@export var save_deaden_blocker_retain: float = 0.45

var carrier: Skater = null
var pickup_locked: bool = false
# Per-skater puck pickup cooldowns. Keyed by Skater.get_instance_id() rather
# than the Skater object directly so that the typed Dictionary's erase()
# validator doesn't reject freed-instance keys when a skater is queue_freed
# (e.g. tutorial puppet bot teardown) before the per-tick cleanup loop drops
# its stale entry. Public API still takes a Skater; the int conversion is
# internal.
var _cooldown_timers: Dictionary[int, float] = {}
# Reused scratch for the per-tick cooldown expiry sweep — cleared (capacity
# retained) each tick instead of reallocated, since cooldowns are active through
# most of live play (every touch arms a ~0.5s reattach window).
var _expired_cooldowns: Array[int] = []
var _is_server: bool = false
var _pending_reset: bool = false
var _pending_reset_xz: Vector2 = Vector2.ZERO
var _clamp_at_goal_line: bool = false
# Last known-finite puck position, cached each physics step so the non-finite
# guard in _integrate_forces can restore a sane position rather than crash Jolt.
var _last_finite_position: Vector3 = Vector3.ZERO
# Full velocity stored by release() for every shot, applied by _integrate_forces.
# Jolt does not preserve linear_velocity set on a frozen body when it activates
# as dynamic — state.linear_velocity on the first dynamic step is zero. Storing
# and applying the full vector here ensures XYZ reach the simulation correctly.
# For elevated shots (y > 0) _integrate_forces also writes the elevated Y position.
var _pending_elevation_vel: Vector3 = Vector3.ZERO
# Belt-and-suspenders for _physics_process: skip is_airborne() zeroing the
# same frame as release() so _pending_elevation_vel reaches _integrate_forces.
var _pending_elevation: bool = false
# Velocity the puck carried into this physics step (cached at the end of
# _integrate_forces), read by the save-deaden classifier as the pre-bounce
# incoming velocity — linear_velocity in _on_body_entered may already reflect the
# restitution response for the step.
var _pre_contact_velocity: Vector3 = Vector3.ZERO
# Queued controlled-save deaden, applied on the next _integrate_forces step so it
# definitively overrides the engine's restitution rebound (host-only; set in
# _on_body_entered). Mirrors the _pending_elevation_vel apply pattern.
var _pending_save_deaden: Vector3 = Vector3.ZERO
var _pending_save_deaden_active: bool = false
# Built once from the save-deaden exports (rebuilt only on demand — exports don't
# change at runtime), so the per-save classification allocates nothing.
var _deaden_cfg: GoalieSaveRules.DeadenConfig = null
# Callable (Skater) -> int team_id, or -1 if the skater isn't registered. Set
# by GameManager at spawn time so Puck doesn't reach upward for team checks.
var _team_resolver: Callable = Callable()

func set_team_resolver(resolver: Callable) -> void:
	_team_resolver = resolver

func _ready() -> void:
	# Puck body sits on its own layer so goal sensors can detect it.
	# Mask bounces it off boards (LAYER_BOARDS) + goalie bodies/nets/ice
	# (LAYER_WALLS) + goalie stick, but not skater bodies.
	collision_layer = Constants.LAYER_PUCK
	collision_mask  = Constants.MASK_PUCK
	continuous_cd = true
	process_physics_priority = 1  # Run after Skater.move_and_slide so blade world pos is current
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)
	_last_finite_position = global_position
	_build_deaden_cfg()

	var vfx := PuckVFX.new()
	vfx.name = "VFX"
	add_child(vfx)

	# Ice-pinned tracking shadow so the small disc stays readable and airborne
	# pucks show their landing spot. Cosmetic; renders on every peer.
	var shadow := PuckShadow.new()
	shadow.name = "Shadow"
	add_child(shadow)

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
			linear_velocity, contact_normal, deflect_blend,
			deflect_speed_retain, deflect_speed_retain_min,
			deflect_max_angle_deg, deflect_max_angle_deg_min, deflect_speed_ref)

	# Deliberate-deflect tips ride the loft mode too: half the tip angle at
	# LOW, full at HIGH — same scaling as the blade-scoop visual.
	if skater.elevation_level > 0:
		var new_dir: Vector3 = PuckCollisionRules.apply_deflection_elevation(
				new_vel.normalized(),
				deflect_elevation_angle * float(skater.elevation_level) * 0.5)
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
	# Gate on the impulse actually DELIVERED to the victim (folds in the attacker's
	# Physical/transfer, both skaters' mass, and the closing speed) rather than the
	# raw attacker-weight × speed impact_force — so the same hit dislodges the puck
	# for an enforcer but not for a low-Physical player. Matches the stagger's
	# hardness measure; see BodyCheckRules.puck_strip_impulse.
	var strip_impulse: float = BodyCheckRules.puck_strip_impulse(
			impact_force, checker.body_check_transfer,
			victim.weight, victim.body_check_brace_resistance, victim.is_braced)
	if strip_impulse < hit_pickup_cooldown_threshold:
		return
	# Hard hits temporarily deny the victim a pickup, even if they weren't carrying.
	_set_cooldown(victim, hit_pickup_cooldown)
	if carrier == null or carrier != victim:
		return
	if pickup_locked:
		return
	if strip_impulse < body_check_strip_threshold:
		return
	# 0..1 hardness from the strip threshold (barely strips) up to ref (jarred dead),
	# so a bigger hit deadens the loose puck more — see body_check_strip_velocity.
	var strip_intensity: float = clampf(
			(strip_impulse - body_check_strip_threshold)
			/ maxf(body_check_strip_ref_impulse - body_check_strip_threshold, 0.001),
			0.0, 1.0)
	_body_check_strip(checker, hit_direction, strip_intensity)

func _body_check_strip(checker: Skater, hit_direction: Vector3, strip_intensity: float) -> void:
	var ex_carrier: Skater = carrier
	clear_carrier()
	linear_velocity = PuckCollisionRules.body_check_strip_velocity(
			hit_direction, body_check_puck_speed, body_check_loose_speed, strip_intensity)
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
			poke_strip_min_speed,
			poke_strip_max_speed,
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
			poke_strip_min_speed,
			poke_strip_max_speed,
			fallback_dir)
	_set_cooldown(ex_carrier, reattach_cooldown)
	puck_stripped.emit(ex_carrier)
	puck_released.emit()


# Goalie loose-puck sweep / clear. The poke check (apply_goalie_poke_check)
# strips a CARRIED puck; this is its loose-puck counterpart — the goalie
# sweeps an uncarried puck out of the crease toward the corner. There's no
# carrier to clear and nobody was dispossessed, so it fires no strip/release
# signals; it just imparts the clearing velocity. No-op on a carried puck
# (the poke path owns that case). Host-only — the authoritative velocity
# replicates to clients through the normal puck sync.
func apply_goalie_sweep(sweep_velocity: Vector3) -> void:
	if carrier != null:
		return
	sleeping = false
	linear_velocity = sweep_velocity


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

# Nudge: a soft self-pass off the carrier's own blade. Unlike release()
# (a shot, direction × power from the blade) the velocity is a full vector the
# controller computed from the carrier's momentum + a small stick-direction
# push. Grounded only (a nutmeg lives on the ice), and the ex-carrier gets only
# the short nudge_cooldown so they can re-collect the puck after it slips the
# gap. Reuses _pending_elevation_vel so Jolt's first dynamic step keeps the
# velocity (a frozen-body linear_velocity write is otherwise zeroed on unfreeze).
func nudge(velocity: Vector3) -> void:
	var ex_carrier: Skater = carrier
	if ex_carrier != null:
		global_position = ex_carrier.get_blade_contact_global()
	global_position.y = ice_height
	_pending_elevation = false
	var v := velocity
	v.y = 0.0
	_pending_elevation_vel = v
	clear_carrier()
	if ex_carrier != null:
		_set_cooldown(ex_carrier, nudge_cooldown)
	puck_released.emit()

func drop() -> void:
	var ex_carrier: Skater = carrier
	clear_carrier()
	linear_velocity = Vector3.ZERO
	# A shot fired the same tick as a stoppage could leave a release velocity
	# queued (release() runs before the physics step); clear it so the dropped
	# puck doesn't inherit it and rocket off on the next _integrate_forces.
	_pending_elevation_vel = Vector3.ZERO
	_pending_elevation = false
	if ex_carrier != null:
		_set_cooldown(ex_carrier, reattach_cooldown)
	puck_released.emit()

func reset(at_xz: Vector2 = Vector2.ZERO) -> void:
	carrier = null
	freeze = false  # ensure _integrate_forces is called on the next step
	sleeping = false  # a slept body skips _integrate_forces, so it would ignore the teleport
	_cooldown_timers.clear()
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# Discard any release velocity queued this frame — a faceoff / whistle reset
	# must not inherit a shot fired on the same tick (would launch the dot puck).
	_pending_elevation_vel = Vector3.ZERO
	_pending_elevation = false
	_pending_reset = true
	_pending_reset_xz = at_xz
	puck_released.emit()

func is_airborne() -> bool:
	return position.y > ice_height + 0.05

# Drops a puck that settled on low net geometry (the back/skirt frame) straight
# down to the ice so it becomes playable again — it was only a few cm up but
# never touched the ice, so it read as airborne forever. Host-authoritative; the
# new position replicates through the normal state buffer.
func settle_to_ice() -> void:
	global_position.y = ice_height
	linear_velocity.y = 0.0
	angular_velocity = Vector3.ZERO

# One-shot spark burst at the puck for a stick-lift strip. Delegated to PuckVFX
# (child "VFX"); the burst anchors to the puck, which sits at the dislodge point.
func fire_stick_lift_vfx() -> void:
	var vfx := get_node_or_null("VFX") as PuckVFX
	if vfx != null:
		vfx.fire_stick_lift_burst()

# Ice-chip puff for a board hit; PuckVFX gates on speed and coalesces grinds.
func fire_board_impact_vfx(speed: float) -> void:
	var vfx := get_node_or_null("VFX") as PuckVFX
	if vfx != null:
		vfx.fire_board_impact_burst(speed)

# Spark snap for a shot off the post; PuckVFX skips soft touches.
func fire_post_ping_vfx(speed: float) -> void:
	var vfx := get_node_or_null("VFX") as PuckVFX
	if vfx != null:
		vfx.fire_post_ping_burst(speed)

func _on_body_entered(body: Node3D) -> void:
	if carrier != null:
		return
	var goalie: Goalie = _goalie_ancestor(body)
	if goalie != null:
		puck_touched_goalie.emit(goalie)
		# Host-authoritative rebound control: deaden a controlled save so it
		# doesn't carom into the slot. The deadened velocity replicates to clients
		# through the normal puck sync / reconciliation, same as pokes and sweeps.
		if _is_server:
			_resolve_save_rebound(body)
	elif body is HockeyGoal:
		puck_touched_post.emit()
	elif body.get_parent() is HockeyGoal:
		if linear_velocity.length() >= 1.0:
			puck_hit_goal_body.emit()
	elif body is HockeyRink and linear_velocity.length() >= 1.0:
		# Only the rink's perimeter boards (HockeyRink's own collider) fire the
		# board-hit thud / chip VFX / RPC. The ice surface is a SEPARATE
		# StaticBody3D child, so the old `body is StaticBody3D` also fired on every
		# grounded release and every landing — a board hit at the wrong spot.
		puck_hit_boards.emit()


# The goalie's save surfaces are StaticBody3D parts at different scene depths —
# pads/body/head/glove sit directly under the Goalie root, but the stick and
# blocker hang off the BlockArm rig. Walk ancestors so a paddle or blocker save
# reads as a goalie touch too (a single get_parent() check silently dropped
# those saves from SOG tracking and goalie reaction resets). Contact-frequency
# only, never per-tick.
func _goalie_ancestor(node: Node) -> Goalie:
	var n: Node = node.get_parent()
	while n != null:
		if n is Goalie:
			return n as Goalie
		n = n.get_parent()
	return null


# Build the cached deaden config from the exports. Called from _ready; the
# exports don't change at runtime so it never needs rebuilding mid-play.
func _build_deaden_cfg() -> void:
	_deaden_cfg = GoalieSaveRules.DeadenConfig.new()
	_deaden_cfg.pad_max_incoming_speed = save_deaden_pad_max_speed
	_deaden_cfg.drop_speed = save_deaden_drop_speed
	_deaden_cfg.glove_retain = save_deaden_glove_retain
	_deaden_cfg.chest_retain = save_deaden_chest_retain
	_deaden_cfg.pad_retain = save_deaden_pad_retain
	_deaden_cfg.blocker_retain = save_deaden_blocker_retain


# Classify a save surface by its StaticBody3D node name (LeftPad / RightPad /
# Body / Head / Glove / Blocker / Stick under Goalie.tscn). Unknown parts fall
# back to PAD (a live-on-hard, deaden-on-easy surface — the safe default).
func _classify_save_part(part_body: Node3D) -> int:
	match part_body.name:
		"Glove":
			return GoalieSaveRules.SavePart.GLOVE
		"Body", "Head":
			return GoalieSaveRules.SavePart.CHEST
		"Blocker":
			return GoalieSaveRules.SavePart.BLOCKER
		"Stick":
			return GoalieSaveRules.SavePart.STICK
	return GoalieSaveRules.SavePart.PAD


# Host-only: on a controlled save, queue a deadened rebound so the puck dies in
# the paint instead of caroming into the slot. The crease-sweep then clears it.
# Live saves (hard pad shots, stick redirects) return without queueing anything,
# so the engine's restitution rebound stands.
func _resolve_save_rebound(part_body: Node3D) -> void:
	if _deaden_cfg == null:
		return
	var part: int = _classify_save_part(part_body)
	var incoming: Vector3 = _pre_contact_velocity
	if not GoalieSaveRules.is_controlled_save(incoming.length(), part, _deaden_cfg):
		return
	_pending_save_deaden = GoalieSaveRules.deadened_velocity(incoming, part, _deaden_cfg)
	_pending_save_deaden_active = true

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _pending_reset:
		_pending_reset = false
		state.transform = Transform3D(Basis(),
				Vector3(_pending_reset_xz.x, ice_height, _pending_reset_xz.y))
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		_pending_reset_xz = Vector2.ZERO
		return
	# Backstop: a non-finite velocity or position handed to Jolt is a hard native
	# crash (the max_speed clamp below can't catch it — NaN > max_speed is false).
	# Sanitize at the seam and log the source. Should never fire.
	if not state.linear_velocity.is_finite():
		push_error("Puck: non-finite velocity %s in _integrate_forces — zeroing." % state.linear_velocity)
		state.linear_velocity = Vector3.ZERO
	if state.transform.origin.is_finite():
		_last_finite_position = state.transform.origin
	else:
		push_error("Puck: non-finite position %s — restoring %s." % [state.transform.origin, _last_finite_position])
		var fixed: Transform3D = state.transform
		fixed.origin = _last_finite_position
		state.transform = fixed
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
	if not _pending_elevation_vel.is_zero_approx():
		# Write the full velocity vector directly into Jolt's physics state.
		# Jolt zeros state.linear_velocity on the first dynamic step after a
		# body unfreezes, so velocity set on a frozen body is lost without this.
		state.linear_velocity = _pending_elevation_vel
		if _pending_elevation_vel.y > 0.0:
			state.transform.origin.y = ice_height + 0.1
		_pending_elevation_vel = Vector3.ZERO
	if _pending_save_deaden_active:
		# Controlled-save deaden queued last step in _on_body_entered — override
		# the engine's restitution rebound so the puck dies in the paint. Applied
		# a step late (invisible ~8 ms) so it wins over the collision response.
		state.linear_velocity = _pending_save_deaden
		state.angular_velocity = Vector3.ZERO
		_pending_save_deaden = Vector3.ZERO
		_pending_save_deaden_active = false
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
	# Cache the velocity the puck carries out of this step — the save-deaden
	# classifier reads it as the pre-bounce incoming velocity, since
	# linear_velocity in _on_body_entered may already carry the restitution
	# response. Taken after all writes so it reflects a same-step release too.
	_pre_contact_velocity = state.linear_velocity

func _physics_process(delta: float) -> void:
	if not _is_server:
		return

	# Tick per-skater cooldowns regardless of carrier state. Keys are int
	# instance_ids; resolve back via instance_from_id and drop entries whose
	# skater has been freed (puppet bot teardown, etc.) alongside the
	# naturally-expired ones. The early-out keeps this fully skipped in the
	# no-cooldowns case; the reused _expired_cooldowns scratch avoids a per-tick
	# allocation while cooldowns are active (per-tick path).
	if not _cooldown_timers.is_empty():
		_expired_cooldowns.clear()
		for id: int in _cooldown_timers:
			var skater: Skater = instance_from_id(id) as Skater
			if not is_instance_valid(skater):
				_expired_cooldowns.append(id)
				continue
			_cooldown_timers[id] -= delta
			if _cooldown_timers[id] <= 0.0:
				_expired_cooldowns.append(id)
		for id: int in _expired_cooldowns:
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
