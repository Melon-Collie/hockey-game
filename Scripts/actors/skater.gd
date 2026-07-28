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
# Rigid shaft-follow pitch (see _apply_blade_tilt): the blade mesh pitches by
# (blade_lie_deg − live shaft angle), so it stays rigidly attached to the shaft
# through every pose — toe-up through the slapshot wind-up and stick lifts,
# a slight toe-drag dig when the cursor pulls the blade in close. The clamps
# bound the read: the dig floor keeps the toe from visibly stabbing through
# the ice, the ceiling caps the wind-up apex just past shaft-aligned.
const _BLADE_FOLLOW_PITCH_MIN_DEG: float = -18.0
const _BLADE_FOLLOW_PITCH_MAX_DEG: float = 100.0
# Blended in with the scroll-wheel loft level (half strength at LOW, full at
# HIGH): the loft opens the face upward to "scoop" the puck, so elevation keys
# off the Z loft far more than the X toe-lift. Eased via _blade_elevation_blend
# in _physics_process so it doesn't snap.
const _BLADE_ELEVATED_EXTRA_LOFT_DEG: float = 16.0   # about Z (handedness-signed)
const _BLADE_ELEVATED_EXTRA_LIFT_DEG: float = 4.0    # about X (small touch of toe-lift)
const _BLADE_ELEVATION_BLEND_SPEED: float = 6.0      # blend units/sec (full swing in ~0.17 s)

# Shoulder anchor offset from body center. The shoulder (top-hand anchor)
# sits on the OPPOSITE side of the body from the blade: a left-handed shooter
# (blade on −X) has the top hand on the right shoulder (+X), and vice versa.
# Matches the ShoulderL/R ball origins in Scenes/Skater.tscn (keep in sync) —
# just clear of the torso cylinder (radius ~0.20-0.22 at shoulder height) so
# the arm bone roots at the deltoid ball instead of half-buried in the chest.
@export var shoulder_offset: float = 0.24
# Shoulder Y in upper-body-local space. Matches the ShoulderL/R ball centers
# in the scene (keep in sync) so the drawn arm hangs from the visible
# shoulder rather than a point 5 cm below it. Vertical drop from shoulder to
# hand at rest = shoulder_height − hand_rest_y (mesh-native 0.40 − (−0.10) =
# 0.50 m; both scale with build height in apply_attributes, so the drop is
# 0.50 m × height_mult). That drop is subtracted inside the derived backhand ROM
# (SkaterController.apply_attributes: reach = sqrt(arm_eff² − drop²)), so the
# hand can never be placed beyond the arm's length — raising this shrinks
# flat-footed reach; the directional reach lean (SkaterPoseCoordinator) buys
# it back by tilting the whole frame toward the target.
@export var shoulder_height: float = 0.40
# Blade length (heel to toe). The Blade Marker3D represents the heel (where
# the shaft meets the blade); the blade mesh extends forward by this distance.
# The puck plays at the contact point, which is blade_length * 0.5 forward
# of the Marker3D along its local forward axis (-Z in local, which
# set_blade_position() orients via look_at each tick). The visible blade mesh
# is generated from this length by StickBladeMeshBuilder (_rebuild_blade_mesh)
# — the BoxMesh in Scenes/Skater.tscn is only a pre-_ready placeholder.
@export var blade_length: float = GameRules.DEFAULT_BLADE_LENGTH_M
# Cosmetic blade-mesh geometry (StickBladeMeshBuilder): how deep the curve
# bows, where along the blade it starts, and how much of the toe rounds off.
# Pure visuals — contact math reads the Blade marker + blade_length only. A
# future gear system makes these per-player (the stick "pattern"); until then
# they're one house pattern for everyone.
@export var blade_curve_depth: float = 0.022
@export var blade_curve_start_frac: float = 0.35
@export var blade_toe_round_frac: float = 0.24
# Length of the hosel — the tapered throat carrying the heel cross-section up
# the shaft line (the shaft-follow tilt keeps the blade rigidly at
# blade_lie_deg to the shaft, so fixed blade-local hosel geometry stays glued
# to the rendered shaft in every pose). Blade mesh only; the tape band keeps
# its flat heel cap.
@export var blade_hosel_length: float = 0.085
# The stick's built-in lie: the shaft↔ice angle at which the blade sits flat.
# Derived from the rest pose (hand ~0.87 m above the heel over a
# sqrt(1.30² − 0.87²) ≈ 0.97 m horizontal run → atan ≈ 42°, i.e. about a
# real lie 5.5). The shaft-follow pitch reads deviation from this angle.
@export var blade_lie_deg: float = 42.0
# Tape band geometry: cross-section growth over the blade, heel overhang (the
# band's heel cap sits proud of the blade's own — coplanar caps z-fight), and
# where along the blade the bare toe starts.
const _BLADE_TAPE_INFLATE_M: float = 0.004
const _BLADE_TAPE_HEEL_OVERHANG_FRAC: float = -0.02
const _BLADE_TAPE_END_FRAC: float = 0.62
@export var wall_squeeze_threshold: float = 0.3
# When the puck is lost on the boards (blade squeezed past the threshold above),
# it squirts ALONG the boards in the carrier's travel direction. This blends a
# small fraction of the inward wall normal into that release so the puck peels a
# touch off the boards rather than hugging them — reads as coming free. 0 = pure
# along-wall slide; ~0.25 ≈ 14° off the boards.
@export var wall_pin_inward_bias: float = 0.25
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
# values in SkaterController.apply_attributes: the forehand cap is anatomical
# (cross-body reach, arm × 0.5625) and the backhand cap is chain-derived
# (sqrt(arm_eff² − shoulder-to-hand drop²)), so no reachable hand target ever
# exceeds the arm's length — the forearm never draws stretched.
# Baseline lengths give one-arm = 0.70m; with the shoulder balls at ±0.24
# that's a wingspan ≈ 1.88m on a 1.78m body (~106% of height — a touch rangy
# vs the 100–104% real athletes run, which reads fine in-game; the segments
# split evenly because the distal bone ends at the gloved-fist center, and
# elbow→fist really is about humerus-length).
@export var upper_arm_length: float = 0.35
@export var forearm_length: float = 0.35
# Pole direction for the elbow (upper-body local). Mostly down with a real
# outward flare (+X is away from the body; the sign flips per side in
# update_arm_mesh) and a touch backward — a hockey top-hand elbow rides out
# and slightly behind the chest line, not pinned against the ribs.
@export var arm_pole_local: Vector3 = Vector3(0.55, -1.0, 0.1)
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

# ── Stick Flex Tuning (cosmetic) ──────────────────────────────────────────────
# Vertex-shader shaft bow (Shaders/stick_flex.gdshader), driven entirely from
# replicated fields (current_shot_state + shot_charge + carry side), so every
# machine renders identical flex with no controller plumbing and no network
# state. The shader displaces vertices BETWEEN the pinned endpoints — the
# hand and blade anchors (gameplay) never move. Negative maxima flip the bow
# side globally if a build reads inverted.
@export var stick_flex_max_m: float = 0.07       # mid-shaft bow at full wrister charge
@export var stick_flex_slap_m: float = 0.10      # contact-spike bow of the slapshot downswing
@export var stick_flex_load_speed: float = 10.0  # how fast the bow tracks the charge
@export var stick_whip_hz: float = 9.0           # release-whip oscillation frequency
@export var stick_whip_damping: float = 14.0     # release-whip decay rate

# ── Body Check Tuning ─────────────────────────────────────────────────────────
@export var weight: float = 1.0
# Fraction of closing momentum the inelastic resolver transfers on a committed
# check (SkaterCollisionRules — the only body-check delivery term now; the old
# restitution/drive-through exports were pre-inelastic dead code, removed). At
# equal mass the victim's knockback is closing × transfer × 0.5, so this is the
# master "how hard does a check hit" dial: raising it strips/staggers/knocks-down
# at lower closing speeds AND deepens the attacker's own inelastic decel (the
# symmetric exchange — a real check costs the checker some speed too). Scaled
# per-build by PlayerAttributes.check_delivery_mult (flat 1.0 in v4 — mass is the
# only differentiator), so the same 0.65 lands for every build.
@export var body_check_transfer: float = 0.65
@export var body_check_brace_resistance: float = 0.4
# Fraction of body_check_transfer that lands WITHOUT the hit button committed.
# The hit button (Ctrl / input.hit_held) is the intent gate: a committed check
# delivers the full transfer, an incidental bump only this fraction — so skating
# into someone uncommitted jostles but rarely staggers and never knocks down.
# Set by the controller each tick via hit_committed below (re-derived from
# input.hit_held, so it survives reconcile with no wire cost).
@export var hit_passive_transfer_mult: float = 0.3
# True this tick when the attacker is committing a check (hit button held +
# stamina available). Written by SkaterController._apply_movement from the
# replicated input.hit_held; read in _resolve_player_collisions to pick between
# full and passive transfer. Not itself on the wire — the aggressor is always the
# locally-simulated body wherever the resolver reads it (host sims all, a client
# its own), and replay re-derives it from input.hit_held.
var hit_committed: bool = false

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
# Vertical center of the body-block sphere, in skater-local space (origin sits at
# the hips). Raised to torso height so the PASSIVE sphere (body_block_radius)
# clears a grounded puck (top ≈ ice_height + radius ≈ 0.12) — loose pucks on the
# ice slip under/between the legs, enabling nutmegs. The WIDER explicit-block
# sphere (block_body_radius, Ctrl) is what stops a low puck: set_block_stance
# rebases it to seal from the ice up (the hip-height origin puts this local
# offset at the torso, so without the rebase a flat shot slid under the crouch).
# Mirrors the grounded-vs-airborne split the blade already uses.
@export var body_block_height: float = 0.7

# ── Node References ───────────────────────────────────────────────────────────
@onready var mesh_root: Node3D = $MeshRoot
@onready var lower_body: Node3D = $MeshRoot/LowerBody
@onready var upper_body: Node3D = $MeshRoot/UpperBody
@onready var blade: Marker3D = $MeshRoot/UpperBody/Blade
@onready var shoulder: Marker3D = $MeshRoot/UpperBody/Shoulder
@onready var stick_mesh: MeshInstance3D = $MeshRoot/UpperBody/StickMesh
# Made public so SkaterUniformCoordinator can colour the head mesh.
@onready var helmet: MeshInstance3D = $MeshRoot/UpperBody/Helmet

# Cached blade MeshInstance3D (child of the Blade marker) and the curve sign
# its procedural mesh was last built with (0 = not built yet). The tilt pass
# runs at render rate, so the node lookup is resolved once in
# _rebuild_blade_mesh rather than per frame.
var _blade_mesh_instance: MeshInstance3D = null
var _blade_mesh_curve_sign: float = 0.0

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
# Visual forearm-bulk multiplier (the Hands attribute's arm tell), stamped by
# SkaterAppearanceCoordinator.apply. The glove cuffs must stay proud of the
# scaled forearm cylinder: with a fixed cuff radius, Hands 4's forearm
# (0.055 × 1.20) landed EXACTLY on the cuff's 0.11 × 0.6 — two coaxial
# cylinders with identical radii, z-fighting along the whole wrist — and
# Hands 5 poked clean through it. Both writers read this: the appearance pass
# resizes live cuffs when attributes change, and _rebuild_glove_cuffs sizes
# fresh ones on uniform apply (either order works).
var forearm_visual_mult: float = 1.0

# Butt-end knob cylinder at the top of the shaft (just past the top hand).
# Created by SkaterUniformCoordinator on uniform apply; positioned per-tick by
# update_stick_mesh() so it rides the butt end as the shaft swings.
var stick_knob_mesh: MeshInstance3D = null

signal body_checked_player(victim: Skater, impact_force: float, hit_direction: Vector3)
signal body_check_impulse_applied(impulse: Vector3)
# Fired ON THE VICTIM with the transfer impulse (m/s, world space) it just
# absorbed — magnitude for the stagger/stamina debuff, direction for the recoil
# lean. Distinct from body_check_impulse_applied (which fires for BOTH roles —
# the attacker's restitution bounce and the victim's transfer — and feeds the
# reconcile velocity buffer): this one is victim-only, so the controller can apply
# the stagger/stamina debuff without mistaking a delivered hit's bounce-back for
# being hit. Host-authoritative consumers gate on is_host; see
# SkaterController._on_body_check_received.
signal body_check_received(impulse: Vector3)
# Fired at the END of _physics_process, AFTER move_and_slide + collision
# resolution + rink clamp have settled this tick's position and velocity. The
# local player's controller uses it to capture its reconcile prediction snapshot
# at the same post-integration sub-step the host samples for its world-state
# broadcast (StateBufferManager.capture → fill_network_state, which reads the
# post-move skater.global_position). Capturing the snapshot pre-move (in the
# controller's priority -1 pass) left the client's prediction for host_timestamp
# T one integration step (~one tick of travel) behind the host's authoritative
# state for the same T — a benign phase offset that, at skating speed, exceeded
# reconcile_position_threshold on nearly every moving tick and drove a reconcile
# storm. Emitted for every skater; only the local controller connects.
signal post_move_integrated()
# Mirrors SkaterStateMachine.State for the current carrier. Updated each tick
# by Local/RemoteController so the goalie AI can read shot-state tells (e.g.
# SLAPPER_CHARGE_WITH_PUCK windup) without reaching across controller boundaries.
var current_shot_state: int = 0

# Movement INTENT — the raw WASD vector (world frame) and brake hold, stamped
# per tick by whichever controller simulates this skater (local input, bot AI,
# host-side client sim) and decoded from the wire for client-rendered remotes;
# same pattern as current_shot_state. Cosmetic-only consumers (the gait) read
# what the player is TRYING to do — crossover intent, deliberate hockey stop,
# no-keys glide — a beat before velocity responds.
var move_intent: Vector2 = Vector2.ZERO
var brake_intent: bool = false
# Predicted world-space shot velocity (direction * speed) if the carrier
# released the shot they're currently charging RIGHT NOW. Published each tick by
# SkaterController during a live charge (WRISTER via _update_wrister_charge, SLAPPER
# via _update_slapper_charge) for EVERY shooter — host player, bot, and remote alike.
# The host simulates a remote's carry from its replicated input (RemoteController.
# _drive_from_input), and everything the solve needs rides the wire: mouse_world_pos,
# the attack-aligned mouse_screen_pos (wrister drag), and the join-payload Shot Power
# Sensitivity. The goalie AI reads it to pre-lean toward a charging shot's predicted
# impact; it gates on `current_shot_state` for freshness and on a non-zero length so
# a stale value left after release (or an as-yet-unset one) is never trusted.
var predicted_shot_velocity: Vector3 = Vector3.ZERO

# ── Stick Flex Runtime State (see Stick Flex Tuning exports) ──────────────────
const _STICK_FLEX_SEGMENTS: int = 12   # shaft subdivisions the bend shader needs
const _SLAP_SPIKE_SECONDS: float = 0.1 # downswing load time before the whip
var _stick_flex: float = 0.0           # smoothed signed load bow (metres)
var _stick_whip_amp: float = 0.0       # release-whip starting amplitude (signed)
var _stick_whip_t: float = -1.0        # seconds since whip start; <0 = idle
var _slap_spike_t: float = -1.0        # seconds into the slap contact spike; <0 = idle
var _flex_prev_state: int = 0
var _flex_sent: float = 0.0            # last uniform written (dirty guard)

# ── Cosmetic Rig Dirty-Flag (mirrors Goalie._connectors_pose_changed) ─────────
# The stick/arm/cuff/sphere rebuild in update_stick_mesh / update_arm_mesh /
# update_bottom_arm_mesh is a pure function of five marker LOCAL positions — the
# to_global → IK solve → to_local round-trip cancels the body transform, so the
# resulting bone local transforms depend only on these markers (and handedness,
# which re-runs _position_hand_markers on flip). A settled skater (idle, or a
# converged interpolation/reconcile pose) leaves the markers bit-identical tick
# over tick, so the whole render-rate rig pass can be skipped. Seeded to NAN so
# the first frame always rebuilds. Stick flex is time/state-driven, not
# marker-driven, so it runs every frame regardless (own shader-write guard).
var _rig_last_top_hand: Vector3 = Vector3(NAN, NAN, NAN)
var _rig_last_blade: Vector3 = Vector3(NAN, NAN, NAN)
var _rig_last_shoulder: Vector3 = Vector3(NAN, NAN, NAN)
var _rig_last_bottom_shoulder: Vector3 = Vector3(NAN, NAN, NAN)
var _rig_last_bottom_hand: Vector3 = Vector3(NAN, NAN, NAN)
# Render-rate cosmetic pose hook. The controller registers a Callable(delta)
# that runs the purely-cosmetic pose passes — the leg gait, head tracking, and
# off-hand IK — which used to run in the physics tick (120 Hz × every skater,
# plus once per replayed input during reconcile). None of them feed the blade's
# world frame (the gait's stride texture was decoupled from it), so they're pure
# render concerns: run once per rendered frame here, visibility-gated, like the
# stick/arm mesh rebuild below. Empty Callable = no hook (safe default).
var render_pose_update: Callable = Callable()
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


# Returns the live (cached) list of ALL skaters, set by PlayerRegistry on spawn.
# _resolve_player_collisions iterates it (skipping self) to resolve skater-vs-
# skater contact analytically now that skaters are off each other's move_and_slide
# mask. Empty Callable (tutorial dummy / test) → no skater-vs-skater resolution.
var _skater_collision_provider: Callable = Callable()
# Stable, machine-consistent id (the owning peer_id) set by PlayerRegistry on
# spawn. Used ONLY to break exact head-on ties in the aggressor gate — it must be
# identical on every machine (get_instance_id() is per-process and would let host
# and client resolve the same pair from opposite sides, desyncing reconcile).
var collision_tiebreak_id: int = 0
# Reused across pairs each tick — no per-pair heap allocation in the 120 Hz
# resolver (the hot-path "build once, fill scratch" pattern).
var _collision_result: SkaterCollisionRules.Result = SkaterCollisionRules.Result.new()


func set_skater_collision_provider(provider: Callable) -> void:
	_skater_collision_provider = provider


# Live (cached) goalie pose list — one Dictionary per goalie with
# position / rotation_y / is_butterfly — set by GameManager on spawn
# (get_goalie_data). clamp_body_to_goalies reads it to hold the skater clear of
# each goalie now that skater-vs-goalie is analytic (move_and_slide is gone).
# Empty Callable (tutorial dummy / test) → no goalie block.
var _goalie_data_provider: Callable = Callable()


func set_goalie_data_provider(provider: Callable) -> void:
	_goalie_data_provider = provider


# Set true by the analytic containment clamps (rink / net / goalie) on any tick
# they reposition the body — the analytic stand-in for the CharacterBody
# is_on_wall() flag move_and_slide used to raise. LocalController reads it to
# suppress reconcile jitter while a skater is pinned against a boundary. Reset at
# the start of each _physics_process integration.
var _touched_boundary: bool = false


func is_touching_boundary() -> bool:
	return _touched_boundary


# The disc radius used for analytic skater-vs-skater contact — the (Size-scaled)
# physics cylinder radius, so the hitbox and the contact geometry stay identical.
func collision_radius() -> float:
	return _collision_cyl.radius if _collision_cyl != null else 0.5
# ── Runtime ───────────────────────────────────────────────────────────────────
var _facing: Vector2 = Vector2.DOWN
# Loft mode (0 flat / 1 low saucer / 2 high). Set each tick by the controller
# from the input frame; replicated so remotes/AI read it directly.
var elevation_level: int = 0
# Eased 0→1 toward elevation_level/2 (half scoop at LOW, full at HIGH); drives
# the extra blade toe-lift (see _update_blade_elevation / _apply_blade_tilt).
var _blade_elevation_blend: float = 0.0
# True when the blade is lifted off the ice — own stick-lift (Q held while not
# carrying) or a forced pop from an opponent hooking under this stick. Set each
# tick by the controller; read host-side by PuckController's interaction gate
# and replicated so remotes/AI can read it. A lifted blade only meets airborne
# pucks (to tip them); it clears grounded pucks and sticks.
var blade_up: bool = false
# Deliberate-deflect intent: true while a human player holds the shoot button
# (LMB) WITHOUT carrying the puck — a committed "redirect this, don't catch it."
# Set each tick by the controller (see SkaterController._wants_deflect); read
# host-side by PuckController's loose-puck interaction gate, which routes blade
# contact into a deflect off the blade face instead of corralling the puck. A
# transient per-tick flag, recomputed from replayed inputs during reconcile, so
# it needs no replication or snapshot. AI bots never set it (they reuse the held
# shoot button off-puck for wrister one-timers).
var deflect_intent: bool = false
# Eased 0→1 toward blade_up; drives the IK blade-lift offset (see
# SkaterIKCoordinator.blade_y_local). Mirrors _blade_elevation_blend.
var _blade_lift_blend: float = 0.0
# Eased 0→1 toward an EMPTY-HANDED body-check commit (the "delivering" state).
# Drives a cosmetic stick raise in SkaterIKCoordinator.blade_y_local so a committed
# checker visibly pulls the stick off the ice — the readable tell that the stance
# is live. Gameplay-inert: while committed the blade is already withdrawn from all
# puck interaction (gated on hit_committed), so lifting it changes nothing but the
# visual. A carrier holding the button to BRACE keeps the stick down (delivering is
# false while carrying), so this never lifts a puck off someone's blade.
var _commit_lift_blend: float = 0.0
# Counts down while an opponent's stick-lift has forcibly popped this skater's
# blade up. Set host-side by the stick-lift claim path; decremented every tick.
# The controller ORs this into the effective blade_up regardless of possession,
# so a forced lift dislodges a carried puck. Stays 0 on clients (they read the
# resolved blade_up off the wire).
var _forced_lift_timer: float = 0.0
var is_ghost: bool = false
# True while this skater is knocked down by a hard body check (knockdown_timer > 0
# on its controller). Set by SkaterController each tick; read by the puck pickup
# election so a downed player can't magnet the puck, the same way is_ghost gates it.
var is_knocked_down: bool = false
var is_braking: bool = false
var is_braced: bool = false
var shot_charge: float = 0.0
var slapper_aim_dir: Vector3 = Vector3.ZERO
var blade_world_velocity: Vector3 = Vector3.ZERO
var _prev_blade_world_pos: Vector3 = Vector3.ZERO
# Faceoff draw tracking (host-only; the two centers, only during a faceoff). While
# active, retain a decaying peak of the horizontal blade velocity so the contested
# pickup reads the SWIPE'S CREST rather than the raw per-tick velocity at contact —
# a well-aimed sweep lands even if it peaks a few ticks off the drop. The crest and
# drop are timed in shared host-clock time (see the _draw_*_host_time block below)
# so ping doesn't tax the bonus. Zero cost unless begin_draw_tracking is called:
# FaceoffDrawRules.decay_peak_speed and the timing weight are pure.
var _draw_tracking: bool = false
var _draw_elapsed: float = 0.0               # real host physics time, for auto-expire only
var _draw_drop_elapsed: float = -1.0         # _draw_elapsed at the drop (auto-expire pin)
var _draw_peak_vel: Vector3 = Vector3.ZERO   # heading × retained crest speed
var _draw_peak_speed: float = 0.0
# Timing is judged in SHARED host-clock time (the input's host_timestamp), NOT host
# physics elapsed: a client's draw is scored by WHEN IT INTENDED to swing (its
# stamped host-time of effect), not when its input happened to land on the host. So
# ping no longer taxes the timing bonus — only clock-sync accuracy does — and every
# client is judged on the same clock, an equal shot regardless of ping. (The host's
# own player / bots stamp host-now, so they're unchanged.)
var _draw_input_host_time: float = 0.0       # current input's host_timestamp (fed by the controller)
var _draw_peak_host_time: float = 0.0        # shared host-time of the retained crest
var _draw_drop_host_time: float = -1.0       # shared host-time of the drop, -1 until marked
var _draw_peak_decay: float = 0.0            # m/s per second (set by begin_draw_tracking)
var _draw_valid_window_s: float = 0.0        # auto-end this long after the drop
# Last known-finite body position, cached each tick before move_and_slide so the
# non-finite guard (_sanitize_physics_state) can restore a sane position if some
# upstream bug ever feeds NaN/Inf into the body. Seeded from the spawn position.
var _last_finite_position: Vector3 = Vector3.ZERO
var _prev_blade_contact: Vector3 = Vector3.ZERO
var _last_wall_normal: Vector3 = Vector3.ZERO
var _collision_cyl: CylinderShape3D = null
var _blade_area: Area3D = null
var _slapper_zone_area: Area3D = null
var _slapper_zone_sphere: SphereShape3D = null
var _default_upper_body_y: float = 0.0
var _default_lower_body_y: float = 0.0
# Cosmetic vertical drop of the whole visible body (torso + hips) while in
# the bent-knee skating stance, so the flexed legs keep the skates on the
# ice. Driven by SkaterSkatingCoordinator; composes with the shot-block
# crouch through _apply_body_height (the single writer of both body Ys).
var _skating_crouch_drop: float = 0.0
var _block_stance_active: bool = false
var _skeleton_root_offset: float = 0.0  # see set_skeleton_root_offset
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

	# Stick-flex prep: the shaft BoxMesh is a scene sub-resource shared by
	# every skater — duplicate it before subdividing (the flex shader needs
	# vertices along the length to bend), same discipline as the collision
	# shape above so instances don't share the mutation.
	var shaft: BoxMesh = stick_mesh.mesh as BoxMesh
	if shaft != null:
		shaft = shaft.duplicate() as BoxMesh
		shaft.subdivide_depth = _STICK_FLEX_SEGMENTS
		stick_mesh.mesh = shaft

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
	_last_finite_position = global_position
	_default_upper_body_y = upper_body.position.y
	_default_lower_body_y = lower_body.position.y

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


func _process(delta: float) -> void:
	# Cosmetic mesh pass at render rate. The stick and arm meshes are pure
	# write-only functions of the marker positions (top_hand, blade, shoulder,
	# bottom_hand) that the physics-rate controllers and interpolators
	# maintain — nothing reads the mesh transforms back. Recomputing them at
	# the physics rate wasted ~75% of the work on poses that never rendered, and
	# reconcile re-ran them once per replayed input (a hitch exactly when the
	# network was already degraded). One pass per rendered frame, after all
	# physics ticks for the frame have finalized the markers, is exactly the
	# work the screen consumes.
	# Skip the marker-driven rig rebuild when hidden or when nothing moved since
	# the last frame (dirty-flag, same pattern as Goalie._update_connectors).
	# Stick flex is time/state-driven — it runs every frame regardless (it has
	# its own shader-write guard) so a mid-shot whip never freezes on an
	# otherwise-static pose.
	if is_visible_in_tree():
		# Cosmetic pose (leg gait / head / off-hand IK) at render rate, before the
		# marker-driven mesh rebuild that consumes it. Skipped entirely when hidden
		# — an off-screen skater needs no animated pose. Gameplay-relevant pose
		# (facing, upper-body twist, blade IK) already ran in the physics tick.
		if render_pose_update.is_valid():
			render_pose_update.call(delta)
		if _rig_pose_changed():
			update_stick_mesh()
			update_arm_mesh()
			update_bottom_arm_mesh()
	_update_stick_flex(delta)


# Returns true (and refreshes the snapshot) when any marker feeding the cosmetic
# rig moved since the last rebuild. Exact equality is sufficient: a converged
# pose reproduces bit-identical local marker positions, and any real motion trips
# the compare. Handedness flips move the shoulder/hand markers via
# _position_hand_markers, so they trip it too. Markers are guaranteed non-null by
# the time _process runs (created in _ready / setup), matching the unguarded
# access the rig functions already rely on.
func _rig_pose_changed() -> bool:
	if top_hand.position == _rig_last_top_hand \
			and blade.position == _rig_last_blade \
			and shoulder.position == _rig_last_shoulder \
			and bottom_shoulder.position == _rig_last_bottom_shoulder \
			and bottom_hand.position == _rig_last_bottom_hand:
		return false
	_rig_last_top_hand = top_hand.position
	_rig_last_blade = blade.position
	_rig_last_shoulder = shoulder.position
	_rig_last_bottom_shoulder = bottom_shoulder.position
	_rig_last_bottom_hand = bottom_hand.position
	return true


func _physics_process(delta: float) -> void:
	# _prev_blade_contact is captured at the top of each controller's tick, before
	# the per-tick IK update runs (see Skater.capture_prev_blade_contact()).
	# Capturing it here would read post-IK and miss the swing within the tick.
	var blade_world_pos: Vector3 = upper_body.to_global(blade.position)
	blade_world_velocity = (blade_world_pos - _prev_blade_world_pos) / delta
	_prev_blade_world_pos = blade_world_pos
	if _draw_tracking:
		_update_draw_peak(delta)
	# Backstop: never hand a NaN/Inf velocity or position to Jolt — a non-finite
	# value there is a hard, uncatchable native crash. This should never fire;
	# when it does it logs the offending state so the upstream source is findable.
	_sanitize_physics_state()
	# Integrate velocity → position directly. move_and_slide() is gone: its only
	# real collisions were skater-vs-goalie-body (now analytic in
	# clamp_body_to_goalies below) and the ice floor — a no-op under the Y-lock,
	# since velocity.y is pinned to 0 (top-down game, no gravity). Boards, net, and
	# skater-vs-skater were already analytic. This `pos += vel·dt` is now bit-
	# identical to LocalController's reconcile-replay integration, so the live tick
	# and the replay no longer differ on the move step.
	_touched_boundary = false
	global_position += velocity * delta
	# Capture velocity BEFORE the analytic skater-vs-skater resolution so the delta
	# below isolates the body-check impulse (the resolver's self velocity change) for
	# the reconcile replay recording — same as when this delta came from the old
	# Jolt-driven _resolve_player_collisions.
	var vel_pre_body_check: Vector3 = velocity
	_resolve_player_collisions()
	var body_check_delta: Vector3 = velocity - vel_pre_body_check
	if body_check_delta.length_squared() > 0.0001:
		body_check_impulse_applied.emit(body_check_delta)
	# Boards are off the skater's physics mask (a CharacterBody cylinder wedges in
	# the concave corner mesh), so hold the body inside the rink analytically.
	# Runs AFTER the body-check delta is captured so a board slide never reads as
	# a hit. The reconcile replay calls the same methods (see LocalController).
	clamp_body_to_rink()
	# Net is off the skater's physics mask too (a cylinder wedges in the concave
	# pocket like the boards) — hold the body clear of the goal-net box analytically.
	clamp_body_to_net()
	# Goalie bodies are no longer on the skater physics mask now that move_and_slide
	# is gone — hold the skater clear of the goalie footprint analytically so you
	# can't walk through the goalie (see clamp_body_to_goalies).
	clamp_body_to_goalies()
	_update_blade_elevation(delta)
	_forced_lift_timer = maxf(_forced_lift_timer - delta, 0.0)
	_update_blade_lift(delta)
	_update_commit_lift(delta)
	_hud.update(delta)
	# Position + velocity are now fully settled for this tick (move_and_slide,
	# body-check collision resolution, and the rink clamp above have all run).
	# The local controller captures its reconcile prediction snapshot here so it
	# reads the same post-integration state the host broadcasts (see the signal
	# doc-comment). Blade elevation/lift above is cosmetic and doesn't touch the
	# body position/velocity/upper-body fields the snapshot records.
	post_move_integrated.emit()


# Sanitizes the body's velocity/position to finite values right before the Jolt
# step. A NaN/Inf reaching move_and_slide() crashes the engine natively (no
# GDScript try/catch can recover it), so we clamp at the seam and log where it
# came from. Cheap value-type checks — hot-path safe at 120 Hz × skaters; the
# string-formatting cost only ever runs on the (should-never) failure branch.
func _sanitize_physics_state() -> void:
	if not velocity.is_finite():
		push_error("Skater '%s': non-finite velocity %s before move_and_slide — zeroing (state=%d pos=%s)."
				% [name, velocity, current_shot_state, global_position])
		velocity = Vector3.ZERO
	if global_position.is_finite():
		_last_finite_position = global_position
	else:
		push_error("Skater '%s': non-finite position %s before move_and_slide — restoring %s."
				% [name, global_position, _last_finite_position])
		global_position = _last_finite_position
		velocity = Vector3.ZERO


func _resolve_player_collisions() -> void:
	# Skaters are off each other's move_and_slide mask (see Constants.MASK_SKATER):
	# skater-vs-skater contact is resolved analytically here via SkaterCollisionRules
	# (inelastic disc model, no restitution bounce) instead of Jolt's cylinder
	# separation + the old attacker_restitution curve. Iterates the registry's
	# cached skater list rather than get_slide_collision(). No provider (tutorial
	# dummy / unit test) → no skater-vs-skater resolution.
	if not _skater_collision_provider.is_valid():
		return
	# A ghosted skater (offside / icing / crease-dwell) has no physical presence:
	# it neither delivers nor receives body contact. The physics layers set_ghost
	# zeroes don't cover this path — skater-vs-skater contact is analytic, so the
	# ghost gate has to live here. is_ghost replicates (SkaterNetworkState), so
	# every machine skips the same pairs and the aggressor gate stays deterministic.
	if is_ghost:
		return
	var others: Array = _skater_collision_provider.call()
	if others == null:
		return
	var my_radius: float = collision_radius()
	for other: Skater in others:
		if other == null or other == self or other.is_ghost:
			continue
		# Center-to-center axis on XZ, n pointing self -> other (the hit direction).
		# Fallback for coincident centers matches SkaterCollisionRules so the emit
		# direction and the resolved geometry agree.
		var d: Vector3 = other.global_position - global_position
		d.y = 0.0
		var dist: float = d.length()
		var n: Vector3 = Vector3(1.0, 0.0, 0.0) if dist < 0.0001 else d / dist
		# Aggressor gate — resolve each pair EXACTLY once, from the side moving toward
		# the other more (replicating move_and_slide's old "only the moving body
		# reports a slide collision"). agg_metric = (v_self + v_other)·n: > 0 → self is
		# the aggressor and resolves this pair; < 0 → the other side does; ~0 (head-on
		# or both still) → the lower instance id resolves. Deterministic across
		# machines (velocities + ids replicate), so prediction and reconcile agree.
		var agg_metric: float = (velocity + other.velocity).dot(n)
		if agg_metric < -0.0001:
			continue
		if absf(agg_metric) <= 0.0001 and collision_tiebreak_id > other.collision_tiebreak_id:
			continue
		# Transfer (0..1) = attacker (self) delivery × hit-button commit gate × victim
		# brace. The Hit button is BOTH sides of the physical battle: committing (self)
		# delivers full transfer instead of hit_passive_transfer_mult ("deal more"), and
		# committing (the victim) braces to cut the delivered impulse ("take less") —
		# the brace moved off brake onto the same button. Both read the REPLICATED
		# hit_committed so they evaluate identically on every machine.
		#
		# But a puck CARRIER can't DELIVER an offensive check — holding the button
		# while carrying only BRACES (the victim-brace below still reads hit_committed
		# regardless of possession), so a carrier bulldozing lands the incidental
		# passive bump, not a full hit. Derived from the replicated current_shot_state
		# so it re-evaluates identically on every machine and through reconcile.
		var delivering: bool = hit_committed \
				and not SkaterStateMachine.state_has_puck(current_shot_state)
		var atk_transfer: float = body_check_transfer \
				* (1.0 if delivering else hit_passive_transfer_mult)
		var brace: float = other.body_check_brace_resistance if other.hit_committed else 1.0
		SkaterCollisionRules.resolve(_collision_result,
				global_position, velocity, weight, my_radius,
				other.global_position, other.velocity, other.weight, other.collision_radius(),
				atk_transfer * brace)
		if not _collision_result.overlapping:
			continue
		# Self (attacker): separation + inelastic decel / drive-through, applied
		# unconditionally (this machine simulates self wherever the resolver runs).
		# Recorded for reconcile replay via the body_check_delta capture in
		# _physics_process (velocity - vel_after_slide).
		global_position += _collision_result.sep_a
		velocity += _collision_result.dvel_a
		# Victim side only when this machine authoritatively owns `other` (host owns
		# all; a client owns only its local predicted skater) — same gate as the old
		# resolver, skipping churn the next host snapshot overwrites. The emit records
		# the victim's incoming impulse for ITS reconcile replay and drives the stagger
		# (body_check_received). The knockback magnitude (|dvel_b|) is now the inelastic
		# reduced-mass impulse, not the old weight-ratio transfer formula.
		if is_host_machine or other.is_local_skater:
			other.global_position += _collision_result.sep_b
			var other_vel_before: Vector3 = other.velocity
			other.velocity += _collision_result.dvel_b
			var other_delta: Vector3 = other.velocity - other_vel_before
			if other_delta.length_squared() > 0.0001:
				other.body_check_impulse_applied.emit(other_delta)
				other.body_check_received.emit(other_delta)
		# Credit / claim path — only on a real (closing) hit, NOT gated by authority
		# (must fire on the attacker's own machine and the host for lag-comp
		# validation, Lever A). impact_force keeps the weight × closing convention
		# BodyCheckRules.puck_strip_impulse reconstructs the strip magnitude from.
		if _collision_result.impulse_applied:
			body_checked_player.emit(other, weight * _collision_result.closing_speed, n)


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
	_touched_boundary = true


# Holds the body out of the goal-net pocket analytically. The net is off the
# skater physics mask (LAYER_NET, puck-only) because a CharacterBody cylinder
# shoved into the concave back corner wedges and freezes — most reliably when the
# goalie bulldozes a skater across the goal line before the crease-dwell ghost
# fires. Mirrors clamp_body_to_rink: project the XZ clear of the net box via
# GameRules.push_out_of_net (radius-inset so the body EDGE stops at the panels)
# and strip any velocity pointing into the net, so the skater slides free instead
# of being re-seated by the shove next tick. Pure value-type math — no allocation,
# hot-path safe at 120 Hz × actors. Called live after move_and_slide (and after
# clamp_body_to_rink) and re-used by LocalController's reconcile replay.
func clamp_body_to_net() -> void:
	var radius: float = _collision_cyl.radius if _collision_cyl != null else 0.0
	var xz := Vector2(global_position.x, global_position.z)
	var pushed: Vector2 = GameRules.push_out_of_net(xz, radius)
	if xz.distance_squared_to(pushed) <= 1e-6:
		return
	var out_dir: Vector2 = (pushed - xz).normalized()
	var vel_xz := Vector2(velocity.x, velocity.z)
	var into_net: float = vel_xz.dot(out_dir)
	if into_net < 0.0:
		# Velocity points into the net — strip that component, keep the tangential
		# slide so the skater brushes along the post/panel instead of sticking.
		vel_xz -= into_net * out_dir
		velocity.x = vel_xz.x
		velocity.z = vel_xz.y
	global_position.x = pushed.x
	global_position.z = pushed.y
	_touched_boundary = true


# Holds the skater clear of every goalie's footprint analytically so you can't
# walk through the goalie now that the goalie body parts are off the skater
# physics mask (move_and_slide is gone). Mirrors clamp_body_to_net: push the XZ
# out of the goalie footprint — a cylinder while standing/RVH, an oriented box in
# the butterfly (the leg pads spread wide) — and strip any velocity pointing into
# the goalie so the skater slides along it instead of being re-seated next tick.
# Reads the same host-refreshed goalie pose cache the blade clamp uses (position /
# rotation_y / is_butterfly). A ghosted skater (crease-dwell / offside) passes
# through, matching the mask drop in set_ghost and the is_ghost gate in
# _resolve_player_collisions. Pure value-type math — no allocation, hot-path safe
# at 120 Hz × actors. Called live after the rink/net clamps and re-used by
# LocalController's reconcile replay so both paths agree.
func clamp_body_to_goalies() -> void:
	if is_ghost or not _goalie_data_provider.is_valid():
		return
	var goalie_data: Array = _goalie_data_provider.call()
	if goalie_data == null:
		return
	var radius: float = _collision_cyl.radius if _collision_cyl != null else 0.0
	var xz := Vector2(global_position.x, global_position.z)
	for data: Dictionary in goalie_data:
		var gpos: Vector3 = data["position"]
		var gpos_xz := Vector2(gpos.x, gpos.z)
		var pushed: Vector2 = GameRules.push_out_of_goalie(
				xz, gpos_xz, data["rotation_y"], data["is_butterfly"],
				GameRules.GOALIE_BLOCK_RADIUS + radius,
				GameRules.GOALIE_BUTTERFLY_HALF_X + radius,
				GameRules.GOALIE_BUTTERFLY_HALF_Z + radius)
		if xz.distance_squared_to(pushed) <= 1e-6:
			continue
		var out_dir: Vector2 = (pushed - xz).normalized()
		var vel_xz := Vector2(velocity.x, velocity.z)
		var into_goalie: float = vel_xz.dot(out_dir)
		if into_goalie < 0.0:
			# Velocity points into the goalie — strip that component, keep the
			# tangential slide so the skater brushes past instead of sticking.
			vel_xz -= into_goalie * out_dir
			velocity.x = vel_xz.x
			velocity.z = vel_xz.y
		global_position.x = pushed.x
		global_position.z = pushed.y
		# Re-seat the working XZ so a second goalie is tested from the new spot.
		xz = pushed
		_touched_boundary = true


# Re-positions the four hand/shoulder Marker3Ds based on the current
# is_left_handed value. Called from _ready() once the markers exist, and
# from the is_left_handed setter whenever the flag is flipped after spawn
# (free-play picker → free-play skater follows without a respawn). Safe
# to call before _ready() — exits early if the markers haven't been
# created yet.
# Attribute-scaled shoulder anchor placement. Called from
# SkaterController.apply_attributes BEFORE the ROM derivation reads
# shoulder_height — the logical anchors mirror the visual shoulder-ball
# positions the appearance pass computes from the same multipliers (y rides
# height, x rides torso bulk), so the drawn arm and the IK stay rooted at
# the same point on every build.
func set_shoulder_anchor(offset: float, height: float) -> void:
	shoulder_offset = offset
	shoulder_height = height
	_position_hand_markers()


func _position_hand_markers() -> void:
	if shoulder == null or top_hand == null or bottom_shoulder == null or bottom_hand == null:
		return
	var top_hand_side_sign: float = 1.0 if is_left_handed else -1.0
	shoulder.position        = Vector3( top_hand_side_sign * shoulder_offset, shoulder_height, 0.0)
	top_hand.position        = Vector3(shoulder.position.x, 0.0, 0.0)
	bottom_shoulder.position = Vector3(-top_hand_side_sign * shoulder_offset, shoulder_height, 0.0)
	bottom_hand.position     = Vector3(bottom_shoulder.position.x, 0.0, 0.0)
	# The procedural blade mesh bakes the curve direction in, so a handedness
	# change (including the first call from _ready, when the sign is still 0)
	# rebuilds it. No-ops on the attribute-reapply path (same sign).
	var curve_sign: float = 1.0 if is_left_handed else -1.0
	if curve_sign != _blade_mesh_curve_sign:
		_rebuild_blade_mesh()
	_apply_blade_tilt()


# Sets the cosmetic blade-mesh orientation — never the Blade marker the
# puck-contact math reads (set_blade_position / get_blade_contact_global).
# Three composed reads:
#   1. Shaft-follow pitch: the blade is rigidly attached to the shaft, so it
#      pitches by (blade_lie_deg − live shaft angle). At the rest lie that's
#      ~0 (blade flat on the ice); when the stick rises (slapshot wind-up,
#      stick lift, high follow-through finish) the blade tips toe-up and stays
#      on the shaft line instead of floating ice-parallel at the tip of a
#      steep shaft; when the cursor pulls the blade in close (steep shaft) it
#      digs slightly toe-down — the toe-drag read. Clamped by the
#      _BLADE_FOLLOW_PITCH_* bounds.
#   2. Resting toe-lift + the scroll-loft elevation extras (about X).
#   3. Face-open loft (about Z, handedness-signed — the forehand face is on
#      opposite sides for L/R shots).
# The mesh is heel-origin (StickBladeMeshBuilder), so the rotation pivots
# about the heel and the shaft→blade junction stays pinned at any pitch.
# Idempotent (recomputed from identity each call, scale preserved — the
# tape-band child rides along); safe before _ready(). Runs at render rate
# from update_stick_mesh (value-type math only, no allocation).
func _apply_blade_tilt() -> void:
	if _blade_mesh_instance == null or not is_instance_valid(_blade_mesh_instance):
		return
	var follow_pitch_deg: float = 0.0
	if top_hand != null and blade != null:
		var shaft: Vector3 = blade.position - top_hand.position
		var horiz: float = Vector2(shaft.x, shaft.z).length()
		if horiz > 0.001 or absf(shaft.y) > 0.001:
			var shaft_pitch_deg: float = rad_to_deg(atan2(-shaft.y, horiz))
			follow_pitch_deg = clampf(blade_lie_deg - shaft_pitch_deg,
					_BLADE_FOLLOW_PITCH_MIN_DEG, _BLADE_FOLLOW_PITCH_MAX_DEG)
	# Loft sign: opens the forehand face upward. Flipped from the usual
	# blade_side_sign convention so the cup tilts the right way for each hand.
	var blade_side_sign: float = 1.0 if is_left_handed else -1.0
	var toe_lift: float = _BLADE_TOE_LIFT_DEG + follow_pitch_deg \
			+ _blade_elevation_blend * _BLADE_ELEVATED_EXTRA_LIFT_DEG
	var loft: float = (_BLADE_FACE_OPEN_DEG + _blade_elevation_blend * _BLADE_ELEVATED_EXTRA_LOFT_DEG) * blade_side_sign
	var rot: Basis = Basis.IDENTITY \
			.rotated(Vector3.RIGHT, deg_to_rad(toe_lift)) \
			.rotated(Vector3.BACK, deg_to_rad(loft))
	var keep_scale: Vector3 = _blade_mesh_instance.transform.basis.get_scale()
	_blade_mesh_instance.transform.basis = rot.scaled(keep_scale)


# (Re)generates the procedural curved blade mesh (and the tape band riding it,
# when the uniform pass has already created one) for the current handedness.
# The generated mesh is heel-origin, so the MeshInstance3D is re-seated at the
# Blade marker origin — replacing the centered placeholder BoxMesh transform
# from the scene. Caches the MeshInstance3D for the render-rate tilt pass.
func _rebuild_blade_mesh() -> void:
	if blade == null:
		return
	var blade_mesh: MeshInstance3D = blade.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if blade_mesh == null:
		return
	var curve_sign: float = 1.0 if is_left_handed else -1.0
	blade_mesh.mesh = StickBladeMeshBuilder.build(
			blade_mesh_params(0.0, 0.0, 1.0, blade_hosel_length))
	blade_mesh.position = Vector3.ZERO
	_blade_mesh_instance = blade_mesh
	_blade_mesh_curve_sign = curve_sign
	var tape: MeshInstance3D = blade_mesh.get_node_or_null("BladeTape") as MeshInstance3D
	if tape != null:
		tape.mesh = build_blade_tape_mesh()


# Builder params for the current blade geometry — shared by the blade mesh and
# the team-tape band (SkaterUniformCoordinator calls build_blade_tape_mesh so
# the band follows the same curve instead of clipping through it as a box).
# hosel_length defaults to 0 (flat heel cap) — only the blade mesh itself
# carries the hosel taper.
func blade_mesh_params(inflate: float, u_start: float, u_end: float,
		hosel_length: float = 0.0) -> StickBladeMeshBuilder.Params:
	var p := StickBladeMeshBuilder.Params.new()
	p.length = blade_length
	p.curve_depth = blade_curve_depth
	p.curve_start_frac = blade_curve_start_frac
	p.toe_round_frac = blade_toe_round_frac
	p.curve_sign = 1.0 if is_left_handed else -1.0
	p.inflate = inflate
	p.u_start = u_start
	p.u_end = u_end
	p.hosel_length = hosel_length
	p.hosel_angle_deg = blade_lie_deg
	return p


# Tape-band mesh for the current blade geometry, heel-origin like the blade
# mesh itself (the band node sits at the blade mesh's origin, untransformed).
func build_blade_tape_mesh() -> ArrayMesh:
	return StickBladeMeshBuilder.build(blade_mesh_params(
			_BLADE_TAPE_INFLATE_M, _BLADE_TAPE_HEEL_OVERHANG_FRAC, _BLADE_TAPE_END_FRAC))


# Eases the elevation blend toward the loft level each tick and re-tilts the
# blade only while transitioning (move_toward lands exactly on the target, after
# which the early-out stops the per-tick basis churn). Called from _physics_process.
func _update_blade_elevation(delta: float) -> void:
	var target: float = float(elevation_level) * 0.5
	if is_equal_approx(_blade_elevation_blend, target):
		return
	_blade_elevation_blend = move_toward(
			_blade_elevation_blend, target, _BLADE_ELEVATION_BLEND_SPEED * delta)
	_apply_blade_tilt()


# Blend units/sec for the blade-lift ease (~0.08 s for a full lift). Snappier
# than the elevation blend — a stick lift is a deliberate, quick action.
const _BLADE_LIFT_BLEND_SPEED: float = 12.0
# Ease rate for the commit-stance stick raise (units/sec). A touch slower than the
# blade lift so the stick "loads up" into the check rather than snapping.
const _COMMIT_LIFT_BLEND_SPEED: float = 9.0


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


# Eases _commit_lift_blend toward an empty-handed check commit ("delivering"), so
# the committed checker's stick cosmetically rises off the ice. A carrier holding
# the button to brace does NOT lift (delivering is false while carrying). Called
# from _physics_process alongside _update_blade_lift.
func _update_commit_lift(delta: float) -> void:
	var delivering: bool = hit_committed \
			and not SkaterStateMachine.state_has_puck(current_shot_state)
	var target: float = 1.0 if delivering else 0.0
	_commit_lift_blend = move_toward(
			_commit_lift_blend, target, _COMMIT_LIFT_BLEND_SPEED * delta)


# Eased 0→1 commit-stance stick-raise factor consumed by
# SkaterIKCoordinator.blade_y_local().
func get_commit_lift_blend() -> float:
	return _commit_lift_blend


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


# Sets the skating-stance body drop (metres). The stance flexes hips/knees,
# which shortens the legs' vertical span; lowering the torso AND the hips by
# the deficit keeps the skates planted instead of floating. Cosmetic only —
# the collision body and every gameplay read are unaffected; the blade IK
# re-lands the blade at ice height from upper_body.global_position each tick.
func set_skating_crouch_drop(drop: float) -> void:
	if is_equal_approx(_skating_crouch_drop, drop):
		return
	_skating_crouch_drop = drop
	_apply_body_height()


# Skeleton height offset (m), set by SkaterAppearanceCoordinator.apply:
# (height_mult − 1) × the roots' ice height. Raising the UpperBody/LowerBody
# roots by this while every offset below them scales by height_mult makes the
# whole mesh skeleton scale about the ICE PLANE — skate contact at y=0 is a
# fixed point of that scaling, so skates stay planted and the physics origin
# (FACEOFF_SPAWN_HEIGHT, Y-axis-locked) never has to move. Routed through
# _apply_body_height so this composes with the crouch/block drops instead of
# fighting them for the same property.
func set_skeleton_root_offset(offset: float) -> void:
	if is_equal_approx(_skeleton_root_offset, offset):
		return
	_skeleton_root_offset = offset
	_apply_body_height()


func _apply_body_height() -> void:
	var block_depth: float = block_crouch_depth if _block_stance_active else 0.0
	upper_body.position.y = _default_upper_body_y + _skeleton_root_offset \
			- block_depth - _skating_crouch_drop
	lower_body.position.y = _default_lower_body_y + _skeleton_root_offset \
			- _skating_crouch_drop


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
# teleporting.
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


# ── Faceoff draw tracking (host-only) ────────────────────────────────────────
# Start retaining the blade-swipe crest for this skater's draw. Called by the
# phase coordinator on the two centers at FACEOFF_PREP entry so a swing during the
# countdown pre-rolls into the contest; reset on every call. peak_decay bleeds the
# retained crest (m/s per second); valid_window_s auto-ends tracking that long
# after the drop so a resolved draw never leaks a stale peak into later play.
func begin_draw_tracking(peak_decay: float, valid_window_s: float) -> void:
	_draw_tracking = true
	_draw_elapsed = 0.0
	_draw_drop_elapsed = -1.0
	_draw_peak_vel = Vector3.ZERO
	_draw_peak_speed = 0.0
	_draw_input_host_time = 0.0
	_draw_peak_host_time = 0.0
	_draw_drop_host_time = -1.0
	_draw_peak_decay = peak_decay
	_draw_valid_window_s = valid_window_s


# Feed the current input's shared host-clock stamp so the crest is timed by when
# the swing was INTENDED (ping-neutral), not when it landed. Called by the
# controller each tick a draw is tracked.
func set_draw_input_time(host_time: float) -> void:
	_draw_input_host_time = host_time


# Stamp the drop instant (FACEOFF entry). host_time is the shared-clock drop time
# the timing bonus measures from; _draw_elapsed pins the real-time auto-expire.
func mark_draw_drop(host_time: float) -> void:
	_draw_drop_elapsed = _draw_elapsed
	_draw_drop_host_time = host_time


func end_draw_tracking() -> void:
	_draw_tracking = false


func is_draw_tracking() -> bool:
	return _draw_tracking


# Retained swipe crest (heading × decayed peak speed) for the contested pickup.
func draw_peak_velocity() -> Vector3:
	return _draw_peak_vel


# Seconds from the drop to the retained crest, in shared host-clock time; negative
# if the crest predates the drop (an early swing) or the drop hasn't been marked →
# treated as neutral timing.
func draw_since_drop() -> float:
	if _draw_drop_host_time < 0.0:
		return -1.0
	return _draw_peak_host_time - _draw_drop_host_time


func _update_draw_peak(delta: float) -> void:
	_draw_elapsed += delta
	if _draw_drop_elapsed >= 0.0 and _draw_elapsed - _draw_drop_elapsed > _draw_valid_window_s:
		_draw_tracking = false
		return
	var horiz := Vector3(blade_world_velocity.x, 0.0, blade_world_velocity.z)
	var cur_speed: float = horiz.length()
	var new_peak: float = FaceoffDrawRules.decay_peak_speed(
			_draw_peak_speed, cur_speed, _draw_peak_decay, delta)
	if cur_speed >= new_peak - 0.0001:
		# Current sweep is the crest — capture its heading and shared-clock time.
		if cur_speed > 0.0001:
			_draw_peak_vel = horiz
			_draw_peak_host_time = _draw_input_host_time
	elif _draw_peak_vel.length() > 0.0001:
		# Decaying — hold the crest heading, shed magnitude to the decayed peak.
		_draw_peak_vel = _draw_peak_vel.normalized() * new_peak
	_draw_peak_speed = new_peak


# Snapshot the blade's current world contact point as "previous" for the
# swept-segment pickup/poke test that runs later in the same physics tick.
# Called once per tick from each controller's tick entry point *before* any
# path that mutates blade.position (input processing, blade-aim-only during a
# faceoff prep, the skate-in pose), so the resulting (prev, curr) pair brackets
# both the IK sweep and the body motion within the tick. Capturing this from
# Skater._physics_process (which runs at priority 0, after the controller's
# priority -1 IK update) misses the IK delta — segment would only span body
# motion, and fast stick movements wouldn't register.
#
# It must run on EVERY tick, not only on ticks that process an input: the
# blade keeps moving during a faceoff prep (aim-only IK, the skate-in glide)
# and on bot ticks that skip apply_decision, and a prev left behind by even a
# few of those ticks makes the swept segment span the gap.
func capture_prev_blade_contact() -> void:
	_prev_blade_contact = get_blade_contact_global()


# Re-anchor both blade histories to the blade's CURRENT world pose. Call after
# any discontinuous move of the body — a faceoff staging jump, respawn, slot
# swap. blade_world_velocity and the swept-segment pickup/poke tests are both
# first differences of these anchors, so carrying them across a teleport
# reports a blade that covered the whole jump in one tick: thousands of m/s
# into the faceoff draw's retained crest, and a segment that sweeps the rink.
func reseed_blade_history() -> void:
	_prev_blade_contact = get_blade_contact_global()
	_prev_blade_world_pos = upper_body.to_global(blade.position)
	blade_world_velocity = Vector3.ZERO


# Horizontal unit vector perpendicular to the stick shaft, picking the face
# that opposes reference_velocity (i.e. faces an incoming puck). Used by
# deflect math and by the receive-vs-deflect decision so both share one
# definition of "blade face".
func get_blade_face_normal(reference_velocity: Vector3) -> Vector3:
	if top_hand == null:
		return -global_transform.basis.z
	return PuckReceptionRules.blade_face_normal(
			get_blade_contact_global(), top_hand.global_position,
			reference_velocity, -global_transform.basis.z)


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
	# The shaft-follow pitch reads the same hand/blade markers that dirtied
	# this rebuild, so the blade mesh re-orients here at render rate too.
	_apply_blade_tilt()


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


# ── Stick Flex (cosmetic) ─────────────────────────────────────────────────────
# Render-rate driver for the shaft-bow shader uniform. Load: the shaft bows
# with wrister charge while aiming (side follows the carry face, so a
# backhand load bows the other way). Release: the bow springs through
# straight with a damped cosine oscillation — cos starts AT the loaded value,
# so the whip is continuous at the release instant. Slapshot: straight
# through the wind-up (real shafts load at CONTACT, not at the top of the
# swing), then a quick contact spike at the start of the follow-through's
# downswing that converts into the same whip. Every input is replicated
# (current_shot_state, shot_charge, carry side), so local, bot, and remote
# skaters render the identical flex with zero network additions.
func _update_stick_flex(delta: float) -> void:
	var state: int = current_shot_state
	# The shaft bows TOWARD the loaded blade face — the side the puck is on,
	# in the direction it's being pushed (three-point bend: puck pins the
	# blade back, top hand pulls back, bottom hand drives the middle forward,
	# so the belly of the C points at the target and the blade trails). An
	# earlier tuning pass negated this after a mis-read of the in-game bow;
	# playtest confirmed the negation had it backward.
	var side: float = (1.0 if _carry_side_smoothed >= 0.0 else -1.0) \
			* (-1.0 if is_left_handed else 1.0)
	if state != _flex_prev_state:
		if state == SkaterStateMachine.State.FOLLOW_THROUGH:
			if _flex_prev_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK \
					or _flex_prev_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK:
				_slap_spike_t = 0.0
			else:
				# Wrister / quick release: whip from the loaded bow, with a
				# minimum pop so uncharged snaps and passes still read.
				var amp: float = _stick_flex
				var min_pop: float = stick_flex_max_m * 0.35
				if absf(amp) < min_pop:
					amp = min_pop * side
				_start_stick_whip(amp)
		_flex_prev_state = state

	var display: float
	if _slap_spike_t >= 0.0:
		# Downswing contact spike: ramp the bow in fast, then let it go.
		_slap_spike_t += delta
		if _slap_spike_t < _SLAP_SPIKE_SECONDS:
			_stick_flex = stick_flex_slap_m * (_slap_spike_t / _SLAP_SPIKE_SECONDS) * side
		else:
			_start_stick_whip(_stick_flex)
			_slap_spike_t = -1.0
		display = _stick_flex
	elif _stick_whip_t >= 0.0:
		_stick_whip_t += delta
		var envelope: float = exp(-stick_whip_damping * _stick_whip_t)
		display = _stick_whip_amp * envelope * cos(TAU * stick_whip_hz * _stick_whip_t)
		if absf(_stick_whip_amp) * envelope < 0.002:
			_stick_whip_t = -1.0
			display = 0.0
		_stick_flex = display
	else:
		var target: float = 0.0
		if state == SkaterStateMachine.State.WRISTER_AIM:
			target = shot_charge * stick_flex_max_m * side
		_stick_flex = lerpf(_stick_flex, target, minf(stick_flex_load_speed * delta, 1.0))
		display = _stick_flex

	if is_equal_approx(display, _flex_sent):
		return
	_flex_sent = display
	var mat: ShaderMaterial = stick_mesh.material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter(&"flex_m", display)


func _start_stick_whip(amp: float) -> void:
	_stick_whip_amp = amp
	_stick_whip_t = 0.0
	_stick_flex = amp


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
		collision_layer = 0
		# Bare LAYER_WALLS = ice only: goalie bodies live on their own
		# LAYER_GOALIE_BODIES (dropped here), so a ghost skates through the
		# goalie too. Skater-vs-skater contact is analytic and gated on
		# is_ghost in _resolve_player_collisions.
		collision_mask = Constants.LAYER_WALLS
	else:
		_blade_area.collision_layer = Constants.LAYER_BLADE_AREAS
		collision_layer = Constants.LAYER_SKATER_BODIES
		collision_mask = Constants.MASK_SKATER
	_uniform.apply_ghost(ghost)
	_hud.apply_ghost(ghost)


# ── Shot-Block Stance ─────────────────────────────────────────────────────────
func set_block_stance(active: bool) -> void:
	_block_stance_active = active
	_apply_body_height()
	_blade_area.collision_layer = 0 if active else Constants.LAYER_BLADE_AREAS


# The body-block CYLINDER the analytic detector tests against (PuckController) — a vertical
# cylinder at the skater's XZ axis matching the torso. PASSIVE: radius body_block_radius over a
# torso band raised off the ice, so a grounded puck slides UNDER (a flat shot passes clean).
# SHOT-BLOCK crouch: the wider block_body_radius, banded from the ice up so a low shot is
# sealed. Reach is uniform across the band (unlike the old sphere, which bulged at one height).
func get_body_block_radius() -> float:
	return block_body_radius if _block_stance_active else body_block_radius


# World-Y extent [bottom, top] of the body-block cylinder.
func get_body_block_y_range() -> Vector2:
	if _block_stance_active:
		# Seal the ice up through the body (a crouched block stops a flat shot).
		return Vector2(0.0, 2.0 * block_body_radius)
	# Torso band centred at body_block_height, raised off the ice so a grounded puck passes under.
	var center_y: float = global_position.y + body_block_height
	return Vector2(center_y - body_block_radius, center_y + body_block_radius)


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


# Smart-ping chat bubble above this skater's head (see SkaterHUDCoordinator).
func show_ping_bubble(text: String) -> void:
	_hud.show_ping_bubble(text)


func set_ring_relation_resolver(resolver: Callable) -> void:
	_hud.set_ring_relation_resolver(resolver)


# Latch all per-skater HUD chrome (slot ring, name label, stamina ring,
# chevron, slapper indicator/ring) off. Used by the offline replay viewer and
# live spectator mode: the broadcast / chase / free cameras frame the rink
# from angles the flat ring decals weren't designed for, and the top-down POV
# cam keeps the same clean broadcast look rather than faking one player's
# local chrome.
func set_world_hud_hidden(hidden: bool) -> void:
	_hud.set_world_hud_hidden(hidden)


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
