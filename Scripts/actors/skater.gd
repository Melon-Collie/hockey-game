class_name Skater
extends CharacterBody3D

# ── Character ─────────────────────────────────────────────────────────────────
# Set before add_child() at spawn; can also be flipped at runtime (free-play
# picker) — the setter re-positions the four hand/shoulder Marker3Ds so the
# rig follows. Most other sign-flips (stick orientation, blade side, IK pole)
# read this at runtime and need no special handling.
@export var is_left_handed: bool = true:
	set(v):
		is_left_handed = v
		_position_hand_markers()

# ── Blade Tuning ──────────────────────────────────────────────────────────────
# Cosmetic blade tilt, applied to the blade *mesh* only — never the Blade marker
# the puck-contact math reads (set_blade_position / get_blade_contact_global).
# Toe-lift (lie) is handedness-neutral; the face-open loft flips sign with
# handedness, since the forehand face is on opposite sides for L/R shots. Applied
# from _position_hand_markers() so it tracks live handedness flips. Both are
# tunable — flip a sign here if a side looks wrong in the editor.
# Resting blade tilt. Toe-lift (about X, lie angle, handedness-neutral) is kept
# small; the face-open loft (about Z, handedness-signed — the forehand face is
# on opposite sides for L/R) is a tiny resting cup.
const _BLADE_TOE_LIFT_DEG: float = 4.0
const _BLADE_FACE_OPEN_DEG: float = 4.0
# Blended in while elevation mode is on (scroll-wheel ballistic aim): the loft
# opens the face upward to "scoop" the puck, so elevation keys off the Z loft
# far more than the X toe-lift. Eased via _blade_elevation_blend in
# _physics_process so it doesn't snap.
const _BLADE_ELEVATED_EXTRA_LOFT_DEG: float = 16.0   # about Z (handedness-signed)
const _BLADE_ELEVATED_EXTRA_LIFT_DEG: float = 4.0    # about X (small touch of toe-lift)
const _BLADE_ELEVATION_BLEND_SPEED: float = 6.0      # blend units/sec (full swing in ~0.17 s)

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
# Two-bone arm IK: shoulder → elbow → top_hand. ROM is derived from these
# values in SkaterController.apply_attributes (rom_backhand = arm × 0.875,
# rom_forehand = arm × 0.5625), so the IK margin is constant across sizes
# regardless of how aggressively arm length scales.
# Baseline lengths give one-arm = 0.75m, wingspan ≈ 1.94m on a 1.78m body
# (~108% of height, matching real-life NHL anthropometry).
@export var upper_arm_length: float = 0.37
@export var forearm_length: float = 0.38
# Pole direction for the elbow (upper-body local).
@export var arm_pole_local: Vector3 = Vector3(0.2, -1.0, 0.0)
# Base size of the arm bone meshes. scale.z is set per tick to the bone's
# actual length; X/Y control arm thickness.
@export var arm_mesh_thickness: float = 0.11
# Radius of the elbow joint spheres positioned per-tick at the IK elbow.
# Kept a touch larger than arm_mesh_thickness * 0.5 so the joint reads as a
# distinct bulge between the upper-arm and forearm cylinders.
@export var elbow_sphere_radius: float = 0.065
# Radius of the hand spheres positioned per-tick at the IK hand.
@export var hand_sphere_radius: float = 0.06
# Gap (along the bone direction, toward the elbow) between the hand-sphere
# center and the forward face of the glove cuff cylinder. Without this the
# cuff sits flush against the hand sphere and visually swallows it; a small
# pullback exposes the hand sphere as a distinct ball at the wrist.
@export var cuff_wrist_offset: float = 0.05

# ── Body Check Tuning ─────────────────────────────────────────────────────────
@export var weight: float = 1.0
@export var body_check_restitution: float = 0.25
@export var body_check_transfer: float = 0.45
@export var body_check_brace_resistance: float = 0.4

# Machine-authority flags, injected once at spawn by GameManager._on_player_spawned
# (collaborator pattern — the actor stays autoload-free). They gate the victim-side
# transfer in _resolve_player_collisions so it only mutates a body this machine
# authoritatively owns: the host owns every skater; a client owns only its local
# predicted skater. Remote-vs-remote contact on a client is non-authoritative
# (the host snapshot owns those bodies), so applying a transfer there is churn the
# next interpolation tick overwrites — and can read as micro-jitter.
var is_host_machine: bool = false
var is_local_skater: bool = false

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
@onready var helmet: MeshInstance3D = $MeshRoot/UpperBody/Helmet

# Top hand: the moving IK output. Positioned by the controller each tick.
var top_hand: Marker3D = null

# Bottom shoulder: anchor for the bottom (off-stick) hand. Sits on the OPPOSITE
# side from `shoulder` — the blade side.
var bottom_shoulder: Marker3D = null

# Bottom hand: the reactive IK output for the bottom grip on the stick shaft.
var bottom_hand: Marker3D = null

# Arm visual meshes (shoulder → elbow → top_hand). Each is a Node3D wrapper
# that gets position/scale/look_at applied by _update_bone_mesh(); the child
# "Cylinder" MeshInstance3D holds the actual geometry (rotated 90° around X
# so the cylinder's Y axis aligns with the wrapper's Z axis — see
# _resolve_or_create_bone_mesh()).
var upper_arm_mesh: Node3D = null
var forearm_mesh: Node3D = null
var bottom_upper_arm_mesh: Node3D = null
var bottom_forearm_mesh: Node3D = null

# Joint spheres positioned per-tick at the IK elbow / hand points.
var top_elbow_sphere: MeshInstance3D = null
var top_hand_sphere: MeshInstance3D = null
var bottom_elbow_sphere: MeshInstance3D = null
var bottom_hand_sphere: MeshInstance3D = null

# Glove cuff cylinders just past the wrist. Created by SkaterUniformCoordinator
# when the uniform is applied; consumed by _update_cuff_transform() here so
# they stay perpendicular to the forearm bone as the arm moves.
var top_cuff_mesh: MeshInstance3D = null
var bot_cuff_mesh: MeshInstance3D = null

# Butt-end knob cylinder at the top of the shaft (just past the top hand).
# Created by SkaterUniformCoordinator on uniform apply; positioned per-tick by
# update_stick_mesh() so it rides the butt end as the shaft swings.
var stick_knob_mesh: MeshInstance3D = null

signal body_checked_player(victim: Skater, impact_force: float, hit_direction: Vector3)
signal body_check_impulse_applied(impulse: Vector3)
# Fired ON THE VICTIM with the magnitude (m/s) of the transfer impulse it just
# absorbed. Distinct from body_check_impulse_applied (which fires for BOTH roles —
# the attacker's restitution bounce and the victim's transfer — and feeds the
# reconcile velocity buffer): this one is victim-only, so the controller can apply
# the stagger/stamina debuff without mistaking a delivered hit's bounce-back for
# being hit. Host-authoritative consumers gate on is_host; see
# SkaterController._on_body_check_received.
signal body_check_received(impulse_magnitude: float)
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
# Eased 0→1 toward is_elevated; drives the extra blade toe-lift (see
# _update_blade_elevation / _apply_blade_tilt).
var _blade_elevation_blend: float = 0.0
# True when the blade is lifted off the ice — own stick-lift (Q held while not
# carrying) or a forced pop from an opponent hooking under this stick. Set each
# tick by the controller; read host-side by PuckController's interaction gate
# and replicated so remotes/AI can read it. A lifted blade only meets airborne
# pucks (to tip them); it clears grounded pucks and sticks.
var blade_up: bool = false
# Eased 0→1 toward blade_up; drives the IK blade-lift offset (see
# SkaterIKCoordinator.blade_y_local). Mirrors _blade_elevation_blend.
var _blade_lift_blend: float = 0.0
# Counts down while an opponent's stick-lift has forcibly popped this skater's
# blade up. Set host-side by the stick-lift claim path; decremented every tick.
# The controller ORs this into the effective blade_up regardless of possession,
# so a forced lift dislodges a carried puck. Stays 0 on clients (they read the
# resolved blade_up off the wire).
var _forced_lift_timer: float = 0.0
var is_ghost: bool = false
var is_braking: bool = false
var is_braced: bool = false
var shot_charge: float = 0.0
var slapper_aim_dir: Vector3 = Vector3.ZERO
var blade_world_velocity: Vector3 = Vector3.ZERO
var _prev_blade_world_pos: Vector3 = Vector3.ZERO
var _prev_blade_contact: Vector3 = Vector3.ZERO
var _last_wall_normal: Vector3 = Vector3.ZERO
var _collision_cyl: CylinderShape3D = null
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
var _appearance: SkaterAppearanceCoordinator


func _ready() -> void:
	add_to_group("skaters")

	# Per-instance collision shape so SkaterController.apply_attributes
	# can scale this skater's hitbox without mutating the shared
	# SubResource referenced by every other Skater in the scene. Cache the
	# cylinder so the rink clamp can read the current (Size-scaled) radius each
	# tick without a node lookup; apply_attributes mutates this same instance.
	var col: CollisionShape3D = $CollisionShape3D
	if col != null and col.shape != null:
		col.shape = col.shape.duplicate()
		_collision_cyl = col.shape as CylinderShape3D

	top_hand = upper_body.get_node_or_null("TopHand") as Marker3D
	if top_hand == null:
		top_hand = Marker3D.new()
		top_hand.name = "TopHand"
		upper_body.add_child(top_hand)

	bottom_shoulder = upper_body.get_node_or_null("BottomShoulder") as Marker3D
	if bottom_shoulder == null:
		bottom_shoulder = Marker3D.new()
		bottom_shoulder.name = "BottomShoulder"
		upper_body.add_child(bottom_shoulder)

	bottom_hand = upper_body.get_node_or_null("BottomHand") as Marker3D
	if bottom_hand == null:
		bottom_hand = Marker3D.new()
		bottom_hand.name = "BottomHand"
		upper_body.add_child(bottom_hand)

	_position_hand_markers()

	_prev_blade_world_pos = upper_body.to_global(blade.position)
	_default_upper_body_y = upper_body.position.y

	collision_layer = Constants.LAYER_SKATER_BODIES
	collision_mask  = Constants.MASK_SKATER

	# Top-down game: the body never moves vertically (no gravity, velocity.y
	# pinned to 0). Locking the Y axis stops move_and_slide from nudging the
	# body up off the knife-edge ice contact every tick — the spurious vertical
	# bounce that a post-move `global_position.y` override used to mask. The
	# override re-embedded the cylinder bottom in the wall collider's Y=0 bottom
	# cap (backface-on) each tick, so against the boards move_and_slide couldn't
	# find a clean slide and the skater stuck. With the axis locked there is no Y
	# motion to undo, so no override and no re-embedding.
	axis_lock_linear_y = true

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

	top_elbow_sphere = _resolve_or_create_joint_sphere("TopElbowSphere", elbow_sphere_radius)
	top_hand_sphere = _resolve_or_create_joint_sphere("TopHandSphere", hand_sphere_radius)
	bottom_elbow_sphere = _resolve_or_create_joint_sphere("BottomElbowSphere", elbow_sphere_radius)
	bottom_hand_sphere = _resolve_or_create_joint_sphere("BottomHandSphere", hand_sphere_radius)

	_uniform = SkaterUniformCoordinator.new()
	_uniform.setup(self)

	_hud = SkaterHUDCoordinator.new()
	_hud.setup(self)

	_appearance = SkaterAppearanceCoordinator.new()
	_appearance.setup(self)

	var vfx := SkaterVFX.new()
	vfx.name = "VFX"
	add_child(vfx)


func _process(_delta: float) -> void:
	# Cosmetic mesh pass at render rate. The stick and arm meshes are pure
	# write-only functions of the marker positions (top_hand, blade, shoulder,
	# bottom_hand) that the physics-rate controllers and interpolators
	# maintain — nothing reads the mesh transforms back. Recomputing them at
	# the physics rate wasted ~75% of the work on poses that never rendered, and
	# reconcile re-ran them once per replayed input (a hitch exactly when the
	# network was already degraded). One pass per rendered frame, after all
	# physics ticks for the frame have finalized the markers, is exactly the
	# work the screen consumes.
	update_stick_mesh()
	update_arm_mesh()
	update_bottom_arm_mesh()


func _physics_process(delta: float) -> void:
	# _prev_blade_contact is captured by SkaterController._process_input before
	# the per-tick IK update runs (see Skater.capture_prev_blade_contact()).
	# Capturing it here would read post-IK and miss the swing within the tick.
	var blade_world_pos: Vector3 = upper_body.to_global(blade.position)
	blade_world_velocity = (blade_world_pos - _prev_blade_world_pos) / delta
	_prev_blade_world_pos = blade_world_pos
	var vel_before: Vector3 = velocity
	# Y is axis-locked (see _ready): move_and_slide leaves global_position.y
	# untouched, so live prediction, reconcile replay, and host authority all
	# agree on Y without a post-move override. Horizontal wall/skater collision
	# is unaffected.
	move_and_slide()
	var vel_after_slide: Vector3 = velocity
	_resolve_player_collisions(vel_before)
	var body_check_delta: Vector3 = velocity - vel_after_slide
	if body_check_delta.length_squared() > 0.0001:
		body_check_impulse_applied.emit(body_check_delta)
	# Boards are off the skater's physics mask (a CharacterBody cylinder wedges in
	# the concave corner mesh), so hold the body inside the rink analytically.
	# Runs AFTER the body-check delta is captured so a board slide never reads as
	# a hit, and after move_and_slide so the ice/skater/goalie collisions resolve
	# first. The reconcile replay calls the same method (see LocalController).
	clamp_body_to_rink()
	_update_blade_elevation(delta)
	_forced_lift_timer = maxf(_forced_lift_timer - delta, 0.0)
	_update_blade_lift(delta)
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
		# Victim-side transfer + emits only when `other` is authoritative on this
		# machine (host owns all; a client owns only its local skater). Skipping it
		# for remote-vs-remote contact on a client removes non-authoritative churn
		# the host snapshot would overwrite anyway. The local victim's predicted
		# push is preserved here (other.is_local_skater), and reconcile snaps it.
		if is_host_machine or other.is_local_skater:
			var effective_transfer: float = body_check_transfer * (other.body_check_brace_resistance if other.is_braced else 1.0)
			var other_vel_before: Vector3 = other.velocity
			var weight_ratio: float = weight / maxf(other.weight, 0.001)
			other.velocity -= normal * approach * weight_ratio * effective_transfer
			var other_delta: Vector3 = other.velocity - other_vel_before
			if other_delta.length_squared() > 0.0001:
				other.body_check_impulse_applied.emit(other_delta)
				other.body_check_received.emit(other_delta.length())
		# body_checked_player drives the host's credit/claim path and is NOT gated:
		# it must fire on the attacker's own machine (local skater) and on the host
		# so the hit can be lag-comp validated and broadcast (Lever A).
		body_checked_player.emit(other, weight * approach, -normal)


# Holds the body inside the rink by projecting its XZ onto the inner board
# boundary (the same GameRules.clamp_to_rink_inner the puck-OOB check, blade
# clamp, and reconcile replay use) and removing any velocity pointing into the
# boards, so the skater slides smoothly along them. Replaces physics collision
# with the concave board mesh, which pinned the CharacterBody cylinder in a
# vertical-only crease in the corners. Pure value-type math — no allocation, so
# it's hot-path safe at 120 Hz × actors. Called live after move_and_slide and
# re-used by LocalController's reconcile replay so both paths agree.
func clamp_body_to_rink() -> void:
	# Inset the boundary by the (Size-scaled) cylinder radius so the body's EDGE
	# stops at the boards, matching where physics collision used to halt it —
	# otherwise the center reaches the surface and the body clips in by its radius
	# (worse for bigger players).
	var radius: float = _collision_cyl.radius if _collision_cyl != null else 0.0
	var xz := Vector2(global_position.x, global_position.z)
	var clamped: Vector2 = GameRules.clamp_to_rink_inner(xz, radius)
	if xz.distance_squared_to(clamped) <= 1e-6:
		return
	var inward: Vector2 = (clamped - xz).normalized()
	var vel_xz := Vector2(velocity.x, velocity.z)
	var into_boards: float = vel_xz.dot(inward)
	if into_boards < 0.0:
		# Velocity points outward into the boards — strip that component, keep the
		# tangential slide.
		vel_xz -= into_boards * inward
		velocity.x = vel_xz.x
		velocity.z = vel_xz.y
	global_position.x = clamped.x
	global_position.z = clamped.y


# Re-positions the four hand/shoulder Marker3Ds based on the current
# is_left_handed value. Called from _ready() once the markers exist, and
# from the is_left_handed setter whenever the flag is flipped after spawn
# (free-play picker → free-play skater follows without a respawn). Safe
# to call before _ready() — exits early if the markers haven't been
# created yet.
func _position_hand_markers() -> void:
	if shoulder == null or top_hand == null or bottom_shoulder == null or bottom_hand == null:
		return
	var top_hand_side_sign: float = 1.0 if is_left_handed else -1.0
	shoulder.position        = Vector3( top_hand_side_sign * shoulder_offset, shoulder_height, 0.0)
	top_hand.position        = Vector3(shoulder.position.x, 0.0, 0.0)
	bottom_shoulder.position = Vector3(-top_hand_side_sign * shoulder_offset, shoulder_height, 0.0)
	bottom_hand.position     = Vector3(bottom_shoulder.position.x, 0.0, 0.0)
	_apply_blade_tilt()


# Sets the cosmetic toe-lift + handedness-signed face-open loft on the blade
# *mesh* (the Blade marker itself is untouched, so puck-contact math is
# unaffected). Idempotent: recomputed from identity each call, scale preserved,
# so the tape-band child rides along. Safe before _ready() — exits if the mesh
# isn't there yet.
func _apply_blade_tilt() -> void:
	if blade == null:
		return
	var blade_mesh: MeshInstance3D = blade.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if blade_mesh == null:
		return
	# Loft sign: opens the forehand face upward. Flipped from the usual
	# blade_side_sign convention so the cup tilts the right way for each hand.
	var blade_side_sign: float = 1.0 if is_left_handed else -1.0
	var toe_lift: float = _BLADE_TOE_LIFT_DEG + _blade_elevation_blend * _BLADE_ELEVATED_EXTRA_LIFT_DEG
	var loft: float = (_BLADE_FACE_OPEN_DEG + _blade_elevation_blend * _BLADE_ELEVATED_EXTRA_LOFT_DEG) * blade_side_sign
	var rot: Basis = Basis.IDENTITY \
			.rotated(Vector3.RIGHT, deg_to_rad(toe_lift)) \
			.rotated(Vector3.BACK, deg_to_rad(loft))
	var keep_scale: Vector3 = blade_mesh.transform.basis.get_scale()
	blade_mesh.transform.basis = rot.scaled(keep_scale)


# Eases the elevation blend toward is_elevated each tick and re-tilts the blade
# only while transitioning (move_toward lands exactly on the target, after which
# the early-out stops the per-tick basis churn). Called from _physics_process.
func _update_blade_elevation(delta: float) -> void:
	var target: float = 1.0 if is_elevated else 0.0
	if is_equal_approx(_blade_elevation_blend, target):
		return
	_blade_elevation_blend = move_toward(
			_blade_elevation_blend, target, _BLADE_ELEVATION_BLEND_SPEED * delta)
	_apply_blade_tilt()


# Blend units/sec for the blade-lift ease (~0.08 s for a full lift). Snappier
# than the elevation blend — a stick lift is a deliberate, quick action.
const _BLADE_LIFT_BLEND_SPEED: float = 12.0


# Eases _blade_lift_blend toward blade_up each tick. The IK reads the blend via
# get_blade_lift_blend() to raise the blade target toward blade_lift_height, so
# the whole stick rises off the ice instead of snapping. Called from
# _physics_process.
func _update_blade_lift(delta: float) -> void:
	var target: float = 1.0 if blade_up else 0.0
	_blade_lift_blend = move_toward(
			_blade_lift_blend, target, _BLADE_LIFT_BLEND_SPEED * delta)


# Eased 0→1 lift factor consumed by SkaterIKCoordinator.blade_y_local().
func get_blade_lift_blend() -> float:
	return _blade_lift_blend


# Forcibly pop this skater's blade up for `duration` seconds (opponent stick
# lift). Takes the max with any in-flight timer so a fresh hook never shortens
# an existing one. Host-side only; clients receive the resolved blade_up.
func force_blade_lift(duration: float) -> void:
	_forced_lift_timer = maxf(_forced_lift_timer, duration)


func is_forced_lift_active() -> bool:
	return _forced_lift_timer > 0.0


# ── Facing ────────────────────────────────────────────────────────────────────
func set_facing(facing: Vector2) -> void:
	_facing = facing
	rotation.y = atan2(-_facing.x, -_facing.y)


func set_lower_body_lag(angle: float) -> void:
	lower_body.rotation.y = angle


func get_facing() -> Vector2:
	return _facing


# ── Skating Stride ────────────────────────────────────────────────────────────
# Procedural leg animation, driven by SkaterSkatingCoordinator. Each leg is a
# two-segment pivot chain in the scene (see Scenes/Skater.tscn):
#
#   LowerBody/LegL          Node3D at the hip joint  — rotate to swing the leg
#     ├─ HipL, ThighL, KneeL   (upper-leg meshes)
#     └─ ShinL              Node3D at the knee joint — rotate for the knee bend
#          └─ SockL, SkateL, FootL   (lower-leg meshes)
#
# Animating is just rotating the two pivots — the limb meshes hang underneath
# and keep their own positions and .scale (the latter owned by
# SkaterAppearanceCoordinator), so the gait and attribute scaling never write
# the same property. Pivots are resolved lazily and null-guarded so the rig
# degrades to a static pose if the scene hasn't been updated yet.
var _legs_resolved: bool = false
var _leg_l: Node3D = null
var _leg_r: Node3D = null
var _shin_l: Node3D = null
var _shin_r: Node3D = null


# pitch = fore/aft swing (local X) and roll = side-to-side splay (local Z) of the
# whole leg about the hip; knee = flex of the lower leg (local X) about the knee.
# All radians.
func set_leg_swing(left_pitch: float, left_roll: float, left_knee: float,
		right_pitch: float, right_roll: float, right_knee: float) -> void:
	if not _legs_resolved:
		_resolve_leg_pivots()
	if _leg_l != null:
		_leg_l.rotation = Vector3(left_pitch, 0.0, left_roll)
	if _shin_l != null:
		_shin_l.rotation.x = left_knee
	if _leg_r != null:
		_leg_r.rotation = Vector3(right_pitch, 0.0, right_roll)
	if _shin_r != null:
		_shin_r.rotation.x = right_knee


func _resolve_leg_pivots() -> void:
	_leg_l = lower_body.get_node_or_null("LegL") as Node3D
	_leg_r = lower_body.get_node_or_null("LegR") as Node3D
	_shin_l = lower_body.get_node_or_null("LegL/ShinL") as Node3D
	_shin_r = lower_body.get_node_or_null("LegR/ShinR") as Node3D
	_legs_resolved = true


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
#
# Slapshot wind-up override: when slapshot pinning is active the puck stays
# at a fixed lateral/forward offset from the player (matched to the one-timer
# slapper zone) instead of following the blade, which is lifted overhead and
# pulled back over the back shoulder during the coil. This keeps the puck on
# the ice in front of the skater so they can coast / brake during the wind-up
# without leaving the puck behind, and so the eventual shot fires from a sane
# ice position rather than from the elevated blade tip.
func get_carry_target_global() -> Vector3:
	if _slapshot_pin_active:
		var local := Vector3(_slapshot_pin_local.x, 0.0, _slapshot_pin_local.y)
		return global_position + global_transform.basis * local
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


# Slapshot pin state — set by SkaterController._enter_slapper_charge when the
# carrier commits to a slap, cleared in _transition_to_skating. The pin offset
# is XZ in skater-local space (already includes blade_side_sign).
var _slapshot_pin_active: bool = false
var _slapshot_pin_local: Vector2 = Vector2.ZERO

func enter_slapshot_pinning(local_offset_x: float, local_offset_z: float) -> void:
	_slapshot_pin_local = Vector2(local_offset_x, local_offset_z)
	_slapshot_pin_active = true

func exit_slapshot_pinning() -> void:
	_slapshot_pin_active = false

func is_slapshot_pinning() -> bool:
	return _slapshot_pin_active


func get_prev_blade_contact_global() -> Vector3:
	return _prev_blade_contact


# Snapshot the blade's current world contact point as "previous" for the
# swept-segment pickup/poke test that runs later in the same physics tick.
# Called from SkaterController._process_input *before* the IK update mutates
# blade.position, so the resulting (prev, curr) pair brackets both the
# IK sweep and the move_and_slide body motion within the tick. Capturing
# this from Skater._physics_process (which runs at priority 0, after the
# controller's priority -1 IK update) misses the IK delta — segment would
# only span body motion, and fast stick movements wouldn't register.
func capture_prev_blade_contact() -> void:
	_prev_blade_contact = get_blade_contact_global()


# Horizontal unit vector perpendicular to the stick shaft, picking the face
# that opposes reference_velocity (i.e. faces an incoming puck). Used by
# deflect math and by the receive-vs-deflect decision so both share one
# definition of "blade face".
func get_blade_face_normal(reference_velocity: Vector3) -> Vector3:
	if top_hand == null:
		return -global_transform.basis.z
	var stick_horiz: Vector3 = get_blade_contact_global() - top_hand.global_position
	stick_horiz.y = 0.0
	if stick_horiz.length() < 0.001:
		stick_horiz = -global_transform.basis.z
	stick_horiz = stick_horiz.normalized()
	var face_normal := Vector3(-stick_horiz.z, 0.0, stick_horiz.x)
	if face_normal.dot(reference_velocity) > 0.0:
		face_normal = -face_normal
	return face_normal


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
	helmet.rotation.y = angle


func get_upper_body_rotation() -> float:
	return upper_body.rotation.y


# ── Wall Clamping ─────────────────────────────────────────────────────────────
# Analytic rink boundary check using the rounded-rectangle inner wall surface.
# The blade is a segment from heel (local_pos) to toe (heel + forward·blade_length);
# both endpoints must stay inside the rink so no part of the stick enters the
# wall. Whichever endpoint pokes deepest determines the inward slide applied to
# the heel — since the blade is rigid, the toe travels with it. Blade direction
# is sampled from the blade Marker3D's current world transform; over a single
# frame the orientation changes slowly enough that this is accurate.
func clamp_blade_to_walls(local_pos: Vector3) -> Vector3:
	_last_wall_normal = Vector3.ZERO
	var heel_world: Vector3 = upper_body.to_global(local_pos)

	var forward_world: Vector3 = -blade.global_transform.basis.z
	forward_world.y = 0.0
	var forward_len_sq: float = forward_world.length_squared()

	var heel_xz := Vector2(heel_world.x, heel_world.z)
	var heel_clamped: Vector2 = GameRules.clamp_to_rink_inner(heel_xz)
	var offset: Vector2 = heel_clamped - heel_xz

	# If the blade has a usable horizontal forward direction, also test the toe
	# and adopt the larger inward correction.
	if forward_len_sq > 0.0001:
		forward_world = forward_world.normalized()
		var toe_world: Vector3 = heel_world + forward_world * blade_length
		var toe_xz := Vector2(toe_world.x, toe_world.z)
		var toe_clamped: Vector2 = GameRules.clamp_to_rink_inner(toe_xz)
		var toe_offset: Vector2 = toe_clamped - toe_xz
		if toe_offset.length_squared() > offset.length_squared():
			offset = toe_offset

	if offset.length_squared() < 0.0001:
		return local_pos
	_last_wall_normal = Vector3(offset.x, 0.0, offset.y).normalized()
	var clamped_world := Vector3(heel_world.x + offset.x, heel_world.y, heel_world.z + offset.y)
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
	_update_stick_knob(stick_origin, to_blade)


# Rides the knob just past the top hand, along the shaft away from the blade,
# with its CylinderMesh long axis (local Y) aligned to the shaft — same look_at +
# rotate_object_local(X, 90°) trick as the glove cuffs.
func _update_stick_knob(stick_origin: Vector3, to_blade: Vector3) -> void:
	if stick_knob_mesh == null or not is_instance_valid(stick_knob_mesh):
		return
	if to_blade.length_squared() < 0.0001:
		return
	var hand_w: Vector3 = upper_body.to_global(stick_origin)
	var up_shaft_w: Vector3 = (hand_w - upper_body.to_global(blade.position)).normalized()
	var cyl: CylinderMesh = stick_knob_mesh.mesh as CylinderMesh
	var knob_h: float = cyl.height if cyl != null else 0.05
	var knob_center_w: Vector3 = hand_w + up_shaft_w * (knob_h * 0.5)
	stick_knob_mesh.position = upper_body.to_local(knob_center_w)
	stick_knob_mesh.look_at(knob_center_w + up_shaft_w, _up_for_look_at(up_shaft_w))
	stick_knob_mesh.rotate_object_local(Vector3.RIGHT, PI * 0.5)


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
	_update_joint_sphere(top_elbow_sphere, elbow_w)
	_update_joint_sphere(top_hand_sphere, hand_w)


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
	_update_joint_sphere(bottom_elbow_sphere, elbow_w)
	_update_joint_sphere(bottom_hand_sphere, hand_w)


func _update_bone_mesh(bone: Node3D, a_world: Vector3, b_world: Vector3) -> void:
	if bone == null:
		return
	var a_local: Vector3 = upper_body.to_local(a_world)
	var b_local: Vector3 = upper_body.to_local(b_world)
	var length: float = (b_local - a_local).length()
	bone.position = (a_local + b_local) * 0.5
	bone.scale = Vector3(1.0, 1.0, maxf(length, 0.001))
	if (b_world - a_world).length() > 0.0001:
		bone.look_at(b_world, _up_for_look_at(b_world - a_world))


func _update_joint_sphere(sphere: MeshInstance3D, world_pos: Vector3) -> void:
	if sphere == null:
		return
	sphere.position = upper_body.to_local(world_pos)


func _update_cuff_transform(mesh: MeshInstance3D, elbow_w: Vector3, hand_w: Vector3) -> void:
	if mesh == null or not is_instance_valid(mesh):
		return
	var bone_dir: Vector3 = hand_w - elbow_w
	var bone_len: float = bone_dir.length()
	if bone_len < 0.0001:
		mesh.position = upper_body.to_local(hand_w)
		return
	var bone_dir_n: Vector3 = bone_dir / bone_len
	# Glove cuff cylinder: its forward end sits at the hand and it extends
	# back toward the elbow by its mesh height (no overlap past the hand).
	# CylinderMesh's long axis is local Y; look_at sets -Z = -bone_dir_n
	# (toward elbow), and rotate_object_local(X, +90°) then maps the new
	# local Y to that elbow direction — so the cylinder stretches along
	# the bone from hand to hand - bone_dir_n * cuff_height.
	var cyl: CylinderMesh = mesh.mesh as CylinderMesh
	var cuff_height: float = cyl.height if cyl != null else 0.06
	var cuff_center_w: Vector3 = hand_w - bone_dir_n * (cuff_height * 0.5 + cuff_wrist_offset)
	mesh.position = upper_body.to_local(cuff_center_w)
	mesh.look_at(cuff_center_w + bone_dir_n, _up_for_look_at(bone_dir_n))
	mesh.rotate_object_local(Vector3.RIGHT, PI * 0.5)


# Returns an up vector that's safely non-colinear with `direction`. Falls back
# to Vector3.FORWARD when `direction` is near-vertical so look_at() doesn't
# warn about colinear basis vectors. Cylindrical meshes (arm bones, cuffs)
# are rotationally symmetric around their long axis, so the choice of up only
# matters for the warning — not for the rendered geometry.
static func _up_for_look_at(direction: Vector3) -> Vector3:
	if absf(direction.normalized().y) > 0.99:
		return Vector3.FORWARD
	return Vector3.UP


# Bone "rig" pattern: the public node is a Node3D wrapper that gets positioned,
# scaled, and look_at'd by _update_bone_mesh(). The child MeshInstance3D named
# "Cylinder" holds a unit-height CylinderMesh, pre-rotated 90° around X so the
# cylinder's local Y axis maps to the wrapper's local Z (the look_at forward
# axis). When the wrapper is scaled along Z to the bone's length, the cylinder
# stretches along the bone. SkaterUniformCoordinator drills into this child to
# set material_override (see bone_visual()).
func _resolve_or_create_bone_mesh(node_name: String) -> Node3D:
	var existing: Node3D = upper_body.get_node_or_null(node_name) as Node3D
	if existing != null:
		return existing
	var wrapper := Node3D.new()
	wrapper.name = node_name
	upper_body.add_child(wrapper)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Cylinder"
	var cyl := CylinderMesh.new()
	cyl.top_radius = arm_mesh_thickness * 0.5
	cyl.bottom_radius = arm_mesh_thickness * 0.5
	cyl.height = 1.0
	cyl.radial_segments = 16
	mesh_instance.mesh = cyl
	mesh_instance.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	wrapper.add_child(mesh_instance)
	return wrapper


# Returns the MeshInstance3D child of a bone wrapper so callers can set
# material_override and adjust transparency without knowing the wrapper layout.
func bone_visual(bone: Node3D) -> MeshInstance3D:
	if bone == null:
		return null
	return bone.get_node_or_null("Cylinder") as MeshInstance3D


func _resolve_or_create_joint_sphere(node_name: String, radius: float) -> MeshInstance3D:
	var existing: MeshInstance3D = upper_body.get_node_or_null(node_name) as MeshInstance3D
	if existing != null:
		return existing
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 14
	sphere.rings = 8
	mesh_instance.mesh = sphere
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
		# Anchor to ice level — the Skater root is at body-center height, so a
		# local Y of 0 lands the sphere up at chest height where the puck can
		# never reach it. Setting global Y after rebases local Y without
		# touching XZ.
		_slapper_zone_area.global_position.y = 0.0
	_slapper_zone_area.collision_layer = Constants.LAYER_BLADE_AREAS if active else 0


func is_slapper_zone_active() -> bool:
	return _slapper_zone_area.collision_layer != 0


func get_slapper_zone_global_position() -> Vector3:
	return _slapper_zone_area.global_position


func get_slapper_zone_radius() -> float:
	return _slapper_zone_sphere.radius


# ── Uniform / Appearance (delegate to SkaterUniformCoordinator) ───────────────
# Applies the full v2 colors dict (output of TeamColorRegistry.get_colors)
# — base colors, stripe arrays, yoke, shoulder + jersey text colors, blade.
# Call before or after set_jersey_info; both repaint the decals using cached
# inputs from whichever side was called last.
func set_uniform(colors: Dictionary) -> void:
	_uniform.apply_uniform(colors)


# Sets the back-of-jersey name and number; text colors come from the cached
# uniform (last set_uniform call).
func set_jersey_info(p_name: String, number: int) -> void:
	_uniform.apply_jersey_info(p_name, number)


# ── HUD (delegate to SkaterHUDCoordinator) ────────────────────────────────────
func set_player_name(p_name: String) -> void:
	_hud.set_player_name(p_name)


func set_ring_relation_resolver(resolver: Callable) -> void:
	_hud.set_ring_relation_resolver(resolver)


func set_charge_ring_visible(should_show: bool) -> void:
	_hud.set_charge_ring_visible(should_show)


# Latch all per-skater HUD chrome (slot ring, name label, charge ring, chevron,
# slapper indicator/ring) off. Used by the offline replay viewer and live
# spectator mode where broadcast / chase / free cameras frame the rink from
# angles the flat ring decals weren't designed for.
func set_world_hud_hidden(hidden: bool) -> void:
	_hud.set_world_hud_hidden(hidden)


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


# ── Appearance (delegate to SkaterAppearanceCoordinator) ──────────────────────
# Called by SkaterController.apply_attributes — same call path that applies
# the gameplay multipliers, so visual and gameplay stay in lockstep without
# a separate signal.
func apply_appearance(attrs: PlayerAttributes) -> void:
	if _appearance != null:
		_appearance.apply(attrs)
