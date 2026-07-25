class_name SkaterRagdollCoordinator
extends RefCounted

# Owns the knockdown ragdoll: the verlet body, its rig-derived config, and the
# seed bookkeeping. Sister to SkaterPoseCoordinator / SkaterSkatingCoordinator —
# a collaborator on SkaterController, not a node.
#
# The solve itself is RagdollRules (pure, unit-tested headless). This class is
# the application seam: when to seed, how far to advance, and what the rig
# writers should read.
#
# ── Driven by the timer, not by delta ────────────────────────────────────────
# The sim is advanced to `knockdown_total − knockdown_timer` seconds of elapsed
# time, in fixed 120 Hz steps, every time it is polled. That makes the pose a
# pure function of the REPLICATED knockdown_timer rather than of local frame
# pacing, which buys four things at once:
#   - every peer renders the same fall, with no per-frame ragdoll sync;
#   - goal replays, which re-drive cosmetics from recorded state, reproduce the
#     fall exactly as it was seen live;
#   - a client that observes the knockdown late (packet loss, or joining mid-
#     fall) catches up to the state everyone else is already in;
#   - reconcile snapping knockdown_timer simply re-targets the sim — there is no
#     separate ragdoll state for replay to get wrong.
# It also means polling at render rate is safe: the step count comes from the
# timer, so a 30 fps and a 240 fps machine converge to the same pose.
#
# ── Why the rig may be simulated at all ──────────────────────────────────────
# SkaterPoseCoordinator._apply_lean documents that the blade markers hang under
# upper_body, so torso rotation moves the blade's WORLD position — gameplay
# geometry that must agree across machines. While the victim is down that stops
# being true: is_knocked_down gates the skater out of every blade-based path
# (pickup election, provisional carry, contest scan, local prediction) and
# collision is the CharacterBody3D capsule, not the mesh. The ragdoll therefore
# writes only pose, never position, and only inside that window. Nothing it
# touches reaches the wire: fill_network_state exports top_hand_position and the
# blade's LOCAL transform, neither of which the ragdoll drives.

const _DT: float = 1.0 / 120.0

var _skater: Skater = null
var _controller: SkaterController = null

var _body: RagdollRules.Body = null
var _cfg: RagdollRules.Config = null
var _height_mult: float = 1.0

# Seed inputs. Constant for the whole knockdown window, which is what lets a
# late-observing peer reproduce the fall from any single packet.
var _hit_dir_body: Vector2 = Vector2(0.0, 1.0)  # x = right, y = forward (matches stagger_recoil_dir)
var _total: float = 0.0                          # full down duration of the current knockdown
var _elapsed: float = 0.0                        # seconds already simulated

# Cached solved pose, refreshed by update(). Read by the rig writers.
var _torso_lean: Vector2 = Vector2.ZERO
var _leg_l: Vector3 = Vector3.ZERO
var _leg_r: Vector3 = Vector3.ZERO
var _drop: float = 0.0


func setup(skater: Skater, controller: SkaterController) -> void:
	_skater = skater
	_controller = controller
	_body = RagdollRules.Body.new()


# ── Config ────────────────────────────────────────────────────────────────────
# Rebuilt on apply_attributes: SkaterAppearanceCoordinator scales every leg pivot
# by the build's height multiplier, so a ragdoll built from neutral constants
# would detach from a tall or short mesh.
func invalidate_config(height_mult: float) -> void:
	_height_mult = height_mult
	_cfg = null


func _config() -> RagdollRules.Config:
	if _cfg != null:
		return _cfg
	var cfg := RagdollRules.Config.new()
	# Segment lengths come from the LIVE (already attribute-scaled) leg pivots.
	var leg_l: Node3D = _skater.lower_body.get_node_or_null("LegL") as Node3D
	var shin_l: Node3D = _skater.lower_body.get_node_or_null("LegL/ShinL") as Node3D
	var skate_l: Node3D = _skater.lower_body.get_node_or_null("LegL/ShinL/SkateL") as Node3D
	if leg_l != null and shin_l != null and skate_l != null:
		cfg.hip_half_width = absf(leg_l.position.x)
		cfg.thigh_len = absf(shin_l.position.y)
		cfg.shin_len = absf(skate_l.position.y)
		# Standing hip height above the ice. The body roots sit at
		# FACEOFF_SPAWN_HEIGHT and scale about the ice plane by height_mult (see
		# Skater.set_skeleton_root_offset), so the scaled root height is
		# FACEOFF_SPAWN_HEIGHT × height_mult; the hip hangs below it by the leg
		# pivot's own (already scaled) offset. base_lower_body_y is used rather
		# than the live position so the crouch drop — which this coordinator
		# drives — can't feed back into its own config.
		cfg.stand_pelvis_y = GameRules.FACEOFF_SPAWN_HEIGHT * _height_mult \
				+ _skater.base_lower_body_y() + leg_l.position.y
	# Torso proportions ride height the same way.
	cfg.spine_len *= _height_mult
	cfg.neck_len *= _height_mult
	cfg.hit_contact_height *= _height_mult
	# Feel tunables mirror the controller's @exports, the same way
	# BodyCheckRules.Config mirrors the stagger ones (the controller is the
	# authoritative source; the domain defaults exist so the solver unit-tests
	# standalone).
	cfg.hit_speed = _controller.ragdoll_hit_speed
	cfg.hit_lift = _controller.ragdoll_hit_lift
	cfg.leg_drag_frac = _controller.ragdoll_leg_drag_frac
	cfg.ice_friction = _controller.ragdoll_ice_friction
	cfg.linear_damping = _controller.ragdoll_damping
	_cfg = cfg
	return _cfg


# ── Seeding ───────────────────────────────────────────────────────────────────
# Recorded by SkaterController._on_body_check_received on the host and the local
# victim. hit_dir_body matches stagger_recoil_dir's frame (x = right, y = forward)
# so the two always reel the same way.
func note_hit(hit_dir_body: Vector2, total_seconds: float) -> void:
	if total_seconds <= 0.0:
		return
	# Extend-never-shorten, mirroring knockdown_timer: a weaker follow-up hit
	# during an existing knockdown must not restart the fall from standing.
	if total_seconds <= _total and _body != null and _body.active:
		return
	_hit_dir_body = hit_dir_body if hit_dir_body.length_squared() > 0.0001 else Vector2(0.0, 1.0)
	_total = total_seconds
	_restart()


# Fed from the wire on client-rendered remotes, which never see the impulse.
func apply_wire_seed(hit_angle: float, total_seconds: float) -> void:
	if total_seconds <= 0.0:
		return
	if total_seconds <= _total and _body != null and _body.active:
		return
	_hit_dir_body = Vector2(cos(hit_angle), sin(hit_angle))
	_total = total_seconds
	_restart()


func _restart() -> void:
	_elapsed = 0.0
	if _body != null:
		_body.active = false


# ── Per-frame ─────────────────────────────────────────────────────────────────
# Poll from the render pose pass, BEFORE the rig writers run. Cheap no-op when
# the skater is upright, which is the overwhelmingly common case.
func update() -> void:
	if _body == null or _skater == null or _controller == null:
		return
	var timer: float = _controller.knockdown_timer
	if timer <= 0.0:
		if _body.active:
			_body.active = false
			_total = 0.0
			_elapsed = 0.0
		return
	if _total <= 0.0:
		# Down, but no seed arrived (a host-set knockdown on a path that never
		# recorded the hit). Fall back to the timer itself as the duration and
		# the default backward recoil, so the player still goes down.
		_total = timer
		_hit_dir_body = Vector2(0.0, 1.0)
		_restart()
	var cfg: RagdollRules.Config = _config()
	if not _body.active:
		_seed(cfg)
	# Target elapsed comes from the replicated timer, never from a local
	# accumulator — see the class doc block.
	var target: float = clampf(_total - timer, 0.0, _total)
	if target > _elapsed:
		RagdollRules.advance(_body, cfg, target - _elapsed, _DT)
		_elapsed = target
	_refresh_pose(cfg)


func _seed(cfg: RagdollRules.Config) -> void:
	var basis: Basis = _skater.global_transform.basis
	var facing_world: Vector3 = -basis.z
	var hit_world: Vector3 = basis * Vector3(_hit_dir_body.x, 0.0, _hit_dir_body.y)
	RagdollRules.seed_body(_body, cfg, facing_world, _skater.velocity, hit_world, _strength())
	_elapsed = 0.0


# 0..1 hit hardness, recovered from the down duration. knockdown_seconds_from_
# impulse maps the impulse linearly onto [min_knockdown_seconds,
# max_knockdown_seconds], so the duration IS the strength — inverting it here
# means the wire never has to carry the impulse separately.
func _strength() -> float:
	var lo: float = _controller.knockdown_min_seconds
	var hi: float = _controller.knockdown_max_seconds
	if hi <= lo:
		return 1.0
	return clampf((_total - lo) / (hi - lo), 0.0, 1.0)


func _refresh_pose(cfg: RagdollRules.Config) -> void:
	var basis: Basis = _skater.global_transform.basis
	_torso_lean = RagdollRules.torso_lean(_body, basis)
	_leg_l = RagdollRules.leg_angles(_body, basis, true)
	_leg_r = RagdollRules.leg_angles(_body, basis, false)
	_drop = RagdollRules.body_drop(_body, cfg)


# ── Readers (consumed by the rig writers) ─────────────────────────────────────
func is_active() -> bool:
	return _body != null and _body.active


func torso_lean() -> Vector2:
	return _torso_lean


func leg_left() -> Vector3:
	return _leg_l


func leg_right() -> Vector3:
	return _leg_r


func body_drop() -> float:
	return _drop


# Body-frame hit direction, so the wire encoder doesn't need its own copy.
func hit_dir_body() -> Vector2:
	return _hit_dir_body


func total_seconds() -> float:
	return _total


# Cleared alongside knockdown_timer by SkaterController._reset_transient_state.
func reset() -> void:
	_total = 0.0
	_elapsed = 0.0
	_hit_dir_body = Vector2(0.0, 1.0)
	_torso_lean = Vector2.ZERO
	_leg_l = Vector3.ZERO
	_leg_r = Vector3.ZERO
	_drop = 0.0
	if _body != null:
		_body.active = false
