class_name Skater
extends CharacterBody3D

# ── Character ─────────────────────────────────────────────────────────────────
@export var is_left_handed: bool = true

# ── Blade Tuning ──────────────────────────────────────────────────────────────
# Shoulder anchor offset from body center. The shoulder (top-hand anchor)
# sits on the OPPOSITE side of the body from the blade: a left-handed shooter
# (blade on −X) has the top hand on the right shoulder (+X), and vice versa.
# Baseline ~0.22 m (half of adult shoulder-to-shoulder breadth).
@export var shoulder_offset: float = 0.22
# Shoulder Y in upper-body-local space. Positions the arm's anchor high on
# the torso (near the top of the upper body mesh) so the visible arm spans
# from the shoulder down to the hand. Vertical drop from shoulder to hand at
# rest = shoulder_height − hand_rest_y (currently 0.35 − (−0.17) = 0.52 m).
# If rom_backhand_reach_max is raised, verify sqrt(drop² + reach²) stays
# under upper_arm_length + forearm_length to avoid visible arm stretch.
@export var shoulder_height: float = 0.35
# Blade length (heel to toe). The Blade Marker3D represents the heel (where
# the shaft meets the blade); the blade mesh extends forward by this distance.
# The puck plays at the contact point, which is blade_length * 0.5 forward
# of the Marker3D along its local forward axis (-Z in local, which
# set_blade_position() orients via look_at each tick). Must match the blade
# mesh Z size in Scenes/Skater.tscn.
@export var blade_length: float = GameRules.DEFAULT_BLADE_LENGTH_M
@export var wall_squeeze_threshold: float = 0.3
# How far the blade mesh visually shifts perpendicular to the stick toward the
# forehand or backhand face during carry. Player's cursor stays at the puck;
# the visible blade renders just to one side of the puck on the appropriate
# face. Pure cosmetic — IK math, pickup distance, shot release all use the
# centered blade contact.
@export var carry_blade_offset: float = 0.07
# Hysteresis distance (in upper-body-local X) the blade must travel past
# center to flip carry side. Larger = more deliberate switches; smaller =
# more responsive but jitters near center. While carrying, the side is
# always ±1 — never centered.
@export var carry_side_switch_threshold: float = 0.10
# How fast the rendered carry factor lerps toward the discrete ±1 side.
# Higher = snappier flip, lower = visible swing through center. ~12/s ≈ 80 ms
# to traverse 95% of the transition.
@export var carry_side_lerp_speed: float = 12.0
# Peak Y lift (world meters) applied to the blade during a forehand/backhand
# flip — peaks when the smoothed factor is at 0 (mid-flip), falls to 0 when
# fully on either side. Reads as the blade rising over the puck as it
# switches sides, like a real stickhandle. Set to 0 to disable.
@export var carry_transit_lift: float = 0.10

# ── Arm Tuning ────────────────────────────────────────────────────────────────
# Two-bone arm IK: shoulder → elbow → top_hand. Sum must exceed
# sqrt(drop² + rom_backhand_reach_max²) where drop = shoulder_height − hand_rest_y.
@export var upper_arm_length: float = 0.44
@export var forearm_length: float = 0.46
# Pole direction for the elbow (upper-body local).
@export var arm_pole_local: Vector3 = Vector3(0.2, -1.0, 0.0)
# Base size of the arm bone meshes. scale.z is set per tick to the bone's
# actual length; X/Y control arm thickness.
@export var arm_mesh_thickness: float = 0.10

# ── Body Check Tuning ─────────────────────────────────────────────────────────
@export var weight: float = 1.0
@export var body_check_restitution: float = 0.25
@export var body_check_transfer: float = 0.45
@export var body_check_brace_resistance: float = 0.4

# ── Body Block Tuning ─────────────────────────────────────────────────────────
@export var body_block_radius: float = 0.5
@export var block_body_radius: float = 0.9
@export var block_crouch_depth: float = 0.35

# ── Node References ───────────────────────────────────────────────────────────
@onready var mesh_root: Node3D = $MeshRoot
@onready var lower_body: Node3D = $MeshRoot/LowerBody
@onready var upper_body: Node3D = $MeshRoot/UpperBody
@onready var blade: Marker3D = $MeshRoot/UpperBody/Blade
@onready var shoulder: Marker3D = $MeshRoot/UpperBody/Shoulder
@onready var stick_mesh: MeshInstance3D = $MeshRoot/UpperBody/StickMesh
# Made public so SkaterUniformCoordinator can colour the head mesh.
@onready var direction_indicator: MeshInstance3D = $MeshRoot/UpperBody/DirectionIndicator

# Top hand: the moving IK output. Positioned by the controller each tick.
var top_hand: Marker3D = null

# Bottom shoulder: anchor for the bottom (off-stick) hand. Sits on the OPPOSITE
# side from `shoulder` — the blade side.
var bottom_shoulder: Marker3D = null

# Bottom hand: the reactive IK output for the bottom grip on the stick shaft.
var bottom_hand: Marker3D = null

# Arm visual meshes (shoulder → elbow → top_hand).
var upper_arm_mesh: MeshInstance3D = null
var forearm_mesh: MeshInstance3D = null
var bottom_upper_arm_mesh: MeshInstance3D = null
var bottom_forearm_mesh: MeshInstance3D = null

# Sleeve cuff stripe meshes. Created by SkaterUniformCoordinator.apply_stripes()
# and consumed by _update_cuff_transform() here so they stay perpendicular to
# the forearm bone as the arm moves.
var top_cuff_mesh: MeshInstance3D = null
var bot_cuff_mesh: MeshInstance3D = null

signal body_checked_player(victim: Skater, impact_force: float, hit_direction: Vector3)
signal body_check_impulse_applied(impulse: Vector3)
signal body_block_hit(body: Node3D)
# Mirrors SkaterStateMachine.State for the current carrier. Updated each tick
# by Local/RemoteController so the goalie AI can read shot-state tells (e.g.
# SLAPPER_CHARGE_WITH_PUCK windup) without reaching across controller boundaries.
var current_shot_state: int = 0
# Resolves the skater's current team_id by deferring to the registry. Set by
# PlayerRegistry on spawn so the goalie / VFX / other Skater-holding code can
# query team affiliation without growing a cached field that has to be
# manually re-synced whenever a mid-game slot swap happens. -1 (unknown) is
# returned when no resolver has been installed (e.g. tutorial dummy).
var _team_id_resolver: Callable = Callable()


func set_team_id_resolver(resolver: Callable) -> void:
	_team_id_resolver = resolver


func get_team_id() -> int:
	if not _team_id_resolver.is_valid():
		return -1
	return _team_id_resolver.call() as int
# ── Runtime ───────────────────────────────────────────────────────────────────
var _facing: Vector2 = Vector2.DOWN
var is_elevated: bool = false
var is_ghost: bool = false
var is_braking: bool = false
var is_braced: bool = false
var shot_charge: float = 0.0
var slapper_aim_dir: Vector3 = Vector3.ZERO
var blade_world_velocity: Vector3 = Vector3.ZERO
var _prev_blade_world_pos: Vector3 = Vector3.ZERO
var _prev_blade_contact: Vector3 = Vector3.ZERO
var _last_wall_normal: Vector3 = Vector3.ZERO
var _body_block_area: Area3D = null
var _body_block_sphere: SphereShape3D = null
var _blade_area: Area3D = null
var _slapper_zone_area: Area3D = null
var _slapper_zone_sphere: SphereShape3D = null
var _default_upper_body_y: float = 0.0
# Sticky carry side: 0 when not carrying, +1 forehand, -1 backhand.
# Advanced by update_carry_side() each tick from the IK pipeline.
var _carry_side: int = 0
# Smoothed rendered carry factor — lerps toward _carry_side at
# carry_side_lerp_speed. This is what get_carry_forehand_factor() returns so
# the visible flip animates through center instead of teleporting.
var _carry_side_smoothed: float = 0.0
# Visual-only offset applied to MeshRoot each frame. Set by LocalController
# during reconcile blending to ease the visible correction over a few ticks.
# Physics body (CharacterBody3D) is always at the authoritative position.
var visual_offset: Vector3 = Vector3.ZERO:
	set(v):
		visual_offset = v
		if mesh_root != null:
			mesh_root.position = global_transform.basis.inverse() * v

var _uniform: SkaterUniformCoordinator
var _hud: SkaterHUDCoordinator


func _ready() -> void:
	add_to_group("skaters")

	var top_hand_side_sign: float = 1.0 if is_left_handed else -1.0
	shoulder.position = Vector3(top_hand_side_sign * shoulder_offset, shoulder_height, 0.0)

	top_hand = upper_body.get_node_or_null("TopHand") as Marker3D
	if top_hand == null:
		top_hand = Marker3D.new()
		top_hand.name = "TopHand"
		upper_body.add_child(top_hand)
	top_hand.position = Vector3(shoulder.position.x, 0.0, 0.0)

	bottom_shoulder = upper_body.get_node_or_null("BottomShoulder") as Marker3D
	if bottom_shoulder == null:
		bottom_shoulder = Marker3D.new()
		bottom_shoulder.name = "BottomShoulder"
		upper_body.add_child(bottom_shoulder)
	bottom_shoulder.position = Vector3(-top_hand_side_sign * shoulder_offset, shoulder_height, 0.0)

	bottom_hand = upper_body.get_node_or_null("BottomHand") as Marker3D
	if bottom_hand == null:
		bottom_hand = Marker3D.new()
		bottom_hand.name = "BottomHand"
		upper_body.add_child(bottom_hand)
	bottom_hand.position = Vector3(bottom_shoulder.position.x, 0.0, 0.0)

	_prev_blade_world_pos = upper_body.to_global(blade.position)
	_default_upper_body_y = upper_body.position.y

	collision_layer = Constants.LAYER_SKATER_BODIES
	collision_mask  = Constants.MASK_SKATER

	_blade_area = Area3D.new()
	_blade_area.name = "BladeArea"
	_blade_area.collision_layer = Constants.LAYER_BLADE_AREAS
	_blade_area.collision_mask = 0
	# Offset the pickup sphere forward by half the blade length so it centers
	# on mid-blade (the contact point) rather than the heel (Marker3D origin).
	_blade_area.position = Vector3(0.0, 0.0, -blade_length * 0.5)
	var blade_shape := CollisionShape3D.new()
	var blade_sphere := SphereShape3D.new()
	blade_sphere.radius = 0.3
	blade_shape.shape = blade_sphere
	_blade_area.add_child(blade_shape)
	blade.add_child(_blade_area)

	# Slapper one-timer zone: ice-level sphere on the skater body. Activated
	# only during SLAPPER_CHARGE_WITHOUT_PUCK via set_slapper_zone().
	_slapper_zone_area = Area3D.new()
	_slapper_zone_area.name = "SlapperZoneArea"
	_slapper_zone_area.collision_layer = 0
	_slapper_zone_area.collision_mask = 0
	var zone_shape := CollisionShape3D.new()
	_slapper_zone_sphere = SphereShape3D.new()
	_slapper_zone_sphere.radius = 1.0
	zone_shape.shape = _slapper_zone_sphere
	_slapper_zone_area.add_child(zone_shape)
	add_child(_slapper_zone_area)

	_body_block_area = Area3D.new()
	_body_block_area.name = "BodyBlockArea"
	_body_block_area.collision_layer = 0
	_body_block_area.collision_mask = Constants.LAYER_PUCK
	var block_shape := CollisionShape3D.new()
	_body_block_sphere = SphereShape3D.new()
	_body_block_sphere.radius = body_block_radius
	block_shape.shape = _body_block_sphere
	_body_block_area.add_child(block_shape)
	add_child(_body_block_area)
	_body_block_area.body_entered.connect(func(body: Node3D) -> void: body_block_hit.emit(body))

	upper_arm_mesh = _resolve_or_create_bone_mesh("UpperArmMesh")
	forearm_mesh = _resolve_or_create_bone_mesh("ForearmMesh")
	bottom_upper_arm_mesh = _resolve_or_create_bone_mesh("BottomUpperArmMesh")
	bottom_forearm_mesh = _resolve_or_create_bone_mesh("BottomForearmMesh")

	_uniform = SkaterUniformCoordinator.new()
	_uniform.setup(self)

	_hud = SkaterHUDCoordinator.new()
	_hud.setup(self)

	var vfx := SkaterVFX.new()
	vfx.name = "VFX"
	add_child(vfx)


func _physics_process(delta: float) -> void:
	_prev_blade_contact = get_blade_contact_global()
	var blade_world_pos: Vector3 = upper_body.to_global(blade.position)
	blade_world_velocity = (blade_world_pos - _prev_blade_world_pos) / delta
	_prev_blade_world_pos = blade_world_pos
	var vel_before: Vector3 = velocity
	move_and_slide()
	var vel_after_slide: Vector3 = velocity
	_resolve_player_collisions(vel_before)
	var body_check_delta: Vector3 = velocity - vel_after_slide
	if body_check_delta.length_squared() > 0.0001:
		body_check_impulse_applied.emit(body_check_delta)
	_hud.update(delta)


func _resolve_player_collisions(vel_before: Vector3) -> void:
	for i: int in get_slide_collision_count():
		var col := get_slide_collision(i)
		if not col.get_collider() is Skater:
			continue
		var other := col.get_collider() as Skater
		# Use horizontal normal only — skater collisions are on the XZ plane.
		var raw_normal: Vector3 = col.get_normal()
		var normal := Vector3(raw_normal.x, 0.0, raw_normal.z)
		if normal.length() < 0.001:
			continue
		normal = normal.normalized()
		var vel_horiz := Vector3(vel_before.x, 0.0, vel_before.z)
		# Use relative closing velocity along the contact normal so perpendicular
		# victim motion doesn't subtract from impact and head-on hits register harder.
		var other_vel_horiz := Vector3(other.velocity.x, 0.0, other.velocity.z)
		var approach: float = (vel_horiz - other_vel_horiz).dot(-normal)
		if approach <= 0.0:
			continue
		velocity += normal * approach * body_check_restitution
		var effective_transfer: float = body_check_transfer * (other.body_check_brace_resistance if other.is_braced else 1.0)
		var other_vel_before: Vector3 = other.velocity
		var weight_ratio: float = weight / maxf(other.weight, 0.001)
		other.velocity -= normal * approach * weight_ratio * effective_transfer
		var other_delta: Vector3 = other.velocity - other_vel_before
		if other_delta.length_squared() > 0.0001:
			other.body_check_impulse_applied.emit(other_delta)
		body_checked_player.emit(other, weight * approach, -normal)


# ── Facing ────────────────────────────────────────────────────────────────────
func set_facing(facing: Vector2) -> void:
	_facing = facing
	rotation.y = atan2(-_facing.x, -_facing.y)


func set_lower_body_lag(angle: float) -> void:
	lower_body.rotation.y = angle


func get_facing() -> Vector2:
	return _facing


# ── Blade ─────────────────────────────────────────────────────────────────────
func set_blade_position(pos: Vector3) -> void:
	blade.position = pos
	var blade_world: Vector3 = upper_body.to_global(pos)
	var hand_world: Vector3 = upper_body.to_global(top_hand.position)
	var shaft_horiz: Vector3 = blade_world - hand_world
	shaft_horiz.y = 0.0
	if shaft_horiz.length() > 0.001:
		blade.look_at(blade_world + shaft_horiz.normalized(), Vector3.UP)


func get_blade_position() -> Vector3:
	return blade.position


# World position where the puck plays on the blade — mid-blade by default.
func get_blade_contact_global() -> Vector3:
	var heel_world: Vector3 = upper_body.to_global(blade.position)
	var forward: Vector3 = -blade.global_transform.basis.z
	forward.y = 0.0
	if forward.length() < 0.001:
		return heel_world
	return heel_world + forward.normalized() * (blade_length * 0.5)


# Smoothed rendered factor in [−1, +1]. Discrete _carry_side is sticky
# (forehand/backhand never centered while carrying); this lerps toward it
# so flips animate through center over carry_side_lerp_speed instead of
# teleporting. Public so future work (e.g. replacing the
# wrister_start_blade_local_x heuristic for shot bias) can consume it directly.
#
# Sign convention is mirrored between handednesses so the visual offset
# direction (applied by SkaterIKCoordinator and get_carry_target_global)
# lands on the same side of the body relative to the player for both
# lefties and righties — without this flip, a righty's puck rendered on
# the opposite face of the blade from a lefty's, even though both were
# "on forehand" per _carry_side.
func get_carry_forehand_factor() -> float:
	var handedness_sign: float = 1.0 if is_left_handed else -1.0
	return _carry_side_smoothed * handedness_sign


# Called once per tick from SkaterIKCoordinator.apply_blade_from_mouse —
# advances the sticky carry-side state and lerps the rendered factor.
# Hysteresis prevents flip-flopping near center; on first carry frame the
# side initializes from current blade position (defaults to forehand if
# exactly centered). On release the discrete target falls to 0, so the
# smoothed factor eases the visible offset back to center over the lerp.
func update_carry_side(has_puck: bool, delta: float) -> void:
	if not has_puck:
		_carry_side = 0
	else:
		var handedness_sign: float = -1.0 if is_left_handed else 1.0
		var blade_x_norm: float = blade.position.x * handedness_sign
		if _carry_side == 0:
			_carry_side = -1 if blade_x_norm < 0.0 else 1
		elif _carry_side > 0 and blade_x_norm < -carry_side_switch_threshold:
			_carry_side = -1
		elif _carry_side < 0 and blade_x_norm > carry_side_switch_threshold:
			_carry_side = 1
	_carry_side_smoothed = lerpf(
			_carry_side_smoothed, float(_carry_side), carry_side_lerp_speed * delta)


# Where the puck pins while carrying. The blade marker is shifted to the
# forehand/backhand side via the IK target (so the stick visibly attaches to
# the offset blade). The puck sits at the un-offset position — adjacent to
# the blade on the opposite face, where the cursor effectively is.
# Pure derivation: contact − face_normal × forehand_factor × carry_blade_offset.
# Returns get_blade_contact_global() (centered) when not carrying or when
# the geometry is degenerate, so existing non-carry consumers are unaffected.
func get_carry_target_global() -> Vector3:
	var contact: Vector3 = get_blade_contact_global()
	if top_hand == null:
		return contact
	var stick: Vector3 = contact - top_hand.global_position
	stick.y = 0.0
	if stick.length() < 0.001:
		return contact
	stick = stick.normalized()
	# Face normal: 90° rotation around Y of the stick direction. Sign mirrors
	# the IK-target offset applied in SkaterIKCoordinator.apply_blade_from_mouse,
	# so subtraction here lands on the un-offset puck position.
	var face_normal := Vector3(-stick.z, 0.0, stick.x)
	return contact - face_normal * get_carry_forehand_factor() * carry_blade_offset


func get_prev_blade_contact_global() -> Vector3:
	return _prev_blade_contact


# ── Top Hand ──────────────────────────────────────────────────────────────────
func set_top_hand_position(pos: Vector3) -> void:
	top_hand.position = pos


func get_top_hand_position() -> Vector3:
	return top_hand.position


# ── Bottom Hand ───────────────────────────────────────────────────────────────
func set_bottom_hand_position(pos: Vector3) -> void:
	bottom_hand.position = pos


func get_bottom_hand_position() -> Vector3:
	return bottom_hand.position


# ── Upper Body ────────────────────────────────────────────────────────────────
func set_upper_body_rotation(angle: float) -> void:
	upper_body.rotation.y = angle


func set_upper_body_lean(lean_x: float, lean_z: float = 0.0) -> void:
	upper_body.rotation.x = lean_x
	upper_body.rotation.z = lean_z


func set_lower_body_lean(lean_x: float, lean_z: float) -> void:
	lower_body.rotation.x = lean_x
	lower_body.rotation.z = lean_z


func set_head_angle(angle: float) -> void:
	direction_indicator.rotation.y = angle


func get_upper_body_rotation() -> float:
	return upper_body.rotation.y


# ── Wall Clamping ─────────────────────────────────────────────────────────────
# Analytic rink boundary check using the rounded-rectangle inner wall surface.
func clamp_blade_to_walls(local_pos: Vector3) -> Vector3:
	_last_wall_normal = Vector3.ZERO
	var blade_world: Vector3 = upper_body.to_global(local_pos)
	var blade_xz := Vector2(blade_world.x, blade_world.z)
	var clamped_xz: Vector2 = GameRules.clamp_to_rink_inner(blade_xz)
	if clamped_xz.distance_squared_to(blade_xz) < 0.0001:
		return local_pos
	_last_wall_normal = Vector3(
		clamped_xz.x - blade_xz.x,
		0.0,
		clamped_xz.y - blade_xz.y
	).normalized()
	var clamped_world := Vector3(clamped_xz.x, blade_world.y, clamped_xz.y)
	return upper_body.to_local(clamped_world)


func get_wall_squeeze(intended_pos: Vector3, clamped_pos: Vector3) -> float:
	return intended_pos.length() - clamped_pos.length()


func get_blade_wall_normal() -> Vector3:
	return _last_wall_normal


# ── Stick Mesh ────────────────────────────────────────────────────────────────
func update_stick_mesh() -> void:
	var stick_origin: Vector3 = top_hand.position
	var to_blade: Vector3 = blade.position - stick_origin
	stick_mesh.position = stick_origin + to_blade / 2.0
	stick_mesh.scale.z = to_blade.length()
	stick_mesh.look_at(upper_body.to_global(blade.position), Vector3.UP)


# ── Arm Mesh ──────────────────────────────────────────────────────────────────
func update_arm_mesh() -> void:
	var shoulder_w: Vector3 = upper_body.to_global(shoulder.position)
	var hand_w: Vector3 = upper_body.to_global(top_hand.position)
	var pole_local: Vector3 = arm_pole_local
	pole_local.x *= 1.0 if is_left_handed else -1.0
	var pole_w: Vector3 = upper_body.global_transform.basis * pole_local
	var elbow_w: Vector3 = TwoBoneIK.solve_elbow(
			shoulder_w, hand_w, upper_arm_length, forearm_length, pole_w)
	_update_bone_mesh(upper_arm_mesh, shoulder_w, elbow_w)
	_update_bone_mesh(forearm_mesh, elbow_w, hand_w)
	_update_cuff_transform(top_cuff_mesh, elbow_w, hand_w)


# ── Bottom Arm Mesh ───────────────────────────────────────────────────────────
func update_bottom_arm_mesh() -> void:
	var shoulder_w: Vector3 = upper_body.to_global(bottom_shoulder.position)
	var hand_w: Vector3 = upper_body.to_global(bottom_hand.position)
	var pole_local: Vector3 = arm_pole_local
	pole_local.x *= -1.0 if is_left_handed else 1.0
	var pole_w: Vector3 = upper_body.global_transform.basis * pole_local
	var elbow_w: Vector3 = TwoBoneIK.solve_elbow(
			shoulder_w, hand_w, upper_arm_length, forearm_length, pole_w)
	_update_bone_mesh(bottom_upper_arm_mesh, shoulder_w, elbow_w)
	_update_bone_mesh(bottom_forearm_mesh, elbow_w, hand_w)
	_update_cuff_transform(bot_cuff_mesh, elbow_w, hand_w)


func _update_bone_mesh(mesh: MeshInstance3D, a_world: Vector3, b_world: Vector3) -> void:
	if mesh == null:
		return
	var a_local: Vector3 = upper_body.to_local(a_world)
	var b_local: Vector3 = upper_body.to_local(b_world)
	var length: float = (b_local - a_local).length()
	mesh.position = (a_local + b_local) * 0.5
	mesh.scale = Vector3(1.0, 1.0, maxf(length, 0.001))
	if (b_world - a_world).length() > 0.0001:
		mesh.look_at(b_world, Vector3.UP)


func _update_cuff_transform(mesh: MeshInstance3D, elbow_w: Vector3, hand_w: Vector3) -> void:
	if mesh == null or not is_instance_valid(mesh):
		return
	mesh.position = upper_body.to_local(hand_w)
	var bone_dir: Vector3 = hand_w - elbow_w
	if bone_dir.length() > 0.0001:
		mesh.look_at(hand_w + bone_dir.normalized(), Vector3.UP)


func _resolve_or_create_bone_mesh(node_name: String) -> MeshInstance3D:
	var existing: MeshInstance3D = upper_body.get_node_or_null(node_name) as MeshInstance3D
	if existing != null:
		return existing
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	var box := BoxMesh.new()
	box.size = Vector3(arm_mesh_thickness, arm_mesh_thickness, 1.0)
	mesh_instance.mesh = box
	upper_body.add_child(mesh_instance)
	return mesh_instance


# ── Coordinate Helpers ────────────────────────────────────────────────────────
func upper_body_to_global(local_pos: Vector3) -> Vector3:
	return upper_body.to_global(local_pos)


func upper_body_to_local(world_pos: Vector3) -> Vector3:
	return upper_body.to_local(world_pos)


# ── Ghost Mode ────────────────────────────────────────────────────────────────
func set_ghost(ghost: bool) -> void:
	if is_ghost == ghost:
		return
	is_ghost = ghost
	if ghost:
		_blade_area.collision_layer = 0
		_slapper_zone_area.collision_layer = 0
		_body_block_area.collision_mask = 0
		collision_layer = 0
		collision_mask = Constants.LAYER_WALLS
	else:
		_blade_area.collision_layer = Constants.LAYER_BLADE_AREAS
		_body_block_area.collision_mask = Constants.LAYER_PUCK
		collision_layer = Constants.LAYER_SKATER_BODIES
		collision_mask = Constants.MASK_SKATER
	_uniform.apply_ghost(ghost)
	_hud.apply_ghost(ghost)


# ── Shot-Block Stance ─────────────────────────────────────────────────────────
func set_block_stance(active: bool) -> void:
	_body_block_sphere.radius = block_body_radius if active else body_block_radius
	upper_body.position.y = _default_upper_body_y - block_crouch_depth if active else _default_upper_body_y
	_blade_area.collision_layer = 0 if active else Constants.LAYER_BLADE_AREAS


# ── Slapper Zone ──────────────────────────────────────────────────────────────
func set_slapper_mode(active: bool) -> void:
	_blade_area.collision_layer = 0 if active else Constants.LAYER_BLADE_AREAS


func set_slapper_zone(active: bool, radius: float = 0.0, offset_x: float = 0.0, offset_z: float = 0.0) -> void:
	if active and radius > 0.0:
		_slapper_zone_sphere.radius = radius
		var blade_side_sign: float = -1.0 if is_left_handed else 1.0
		_slapper_zone_area.position = Vector3(blade_side_sign * offset_x, 0.0, offset_z)
	_slapper_zone_area.collision_layer = Constants.LAYER_BLADE_AREAS if active else 0


func is_slapper_zone_active() -> bool:
	return _slapper_zone_area.collision_layer != 0


func get_slapper_zone_global_position() -> Vector3:
	return _slapper_zone_area.global_position


func get_slapper_zone_radius() -> float:
	return _slapper_zone_sphere.radius


# ── Uniform / Appearance (delegate to SkaterUniformCoordinator) ───────────────
func set_player_color(
		jersey_color: Color,
		helmet_color: Color,
		pants_color: Color,
		socks_color: Color,
		blade_color: Color) -> void:
	_uniform.apply_colors(jersey_color, helmet_color, pants_color, socks_color, blade_color)


func set_jersey_info(p_name: String, number: int, text_color: Color) -> void:
	_uniform.apply_jersey_info(p_name, number, text_color)


func set_jersey_stripes(
		jersey_stripe_color: Color,
		pants_stripe_color: Color,
		socks_stripe_color: Color) -> void:
	_uniform.apply_stripes(jersey_stripe_color, pants_stripe_color, socks_stripe_color)


# ── HUD (delegate to SkaterHUDCoordinator) ────────────────────────────────────
func set_player_name(p_name: String) -> void:
	_hud.set_player_name(p_name)


func set_charge_ring_visible(should_show: bool) -> void:
	_hud.set_charge_ring_visible(should_show)


func trigger_charge_lost_flash() -> void:
	_hud.trigger_charge_lost_flash()


func set_slapper_indicator(active: bool, offset_x: float = 0.0, offset_z: float = 0.0, radius: float = 0.5) -> void:
	_hud.set_slapper_indicator(active, offset_x, offset_z, radius)


func set_slapshot_arrow(active: bool, offset_x: float = 0.0, offset_z: float = 0.0, radius: float = -1.0) -> void:
	_hud.set_slapshot_arrow(active, offset_x, offset_z, radius)


func update_slapshot_arrow_direction(world_dir: Vector3) -> void:
	_hud.update_slapshot_arrow_direction(world_dir)


func update_slapper_indicator_convergence(ratio: float) -> void:
	_hud.update_slapper_indicator_convergence(ratio)


func set_slapper_indicator_ready(_is_ready: bool) -> void:
	_hud.set_slapper_indicator_ready(_is_ready)


func update_slapper_indicator_window(_t: float) -> void:
	_hud.update_slapper_indicator_window(_t)
