class_name Skater
extends Node3D

# ── Character ─────────────────────────────────────────────────────────────────
# Set before add_child() at spawn; can also be flipped at runtime (free-play
# picker) — the setter re-positions the four hand/shoulder Marker3Ds so the
# rig follows. Most other sign-flips (stick orientation, blade side, IK pole)
# read this at runtime and need no special handling.
var is_left_handed: bool = true:
	set(v):
		is_left_handed = v
		_position_hand_markers()

# ── Blade Tuning ──────────────────────────────────────────────────────────────
# Resting blade tilt, applied to the blade *mesh* only — never the Blade marker
# the puck-contact math reads (set_blade_position / get_blade_contact_global).
# Toe-lift (about X, the lie angle) is handedness-neutral and kept small; the
# face-open loft (axial twist about the hosel line) is a tiny resting cup and
# flips sign with handedness, since the forehand face is on opposite sides for
# L/R shots.
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
# Blended in with the scroll-wheel loft level (a third per rung, full at HIGH):
# the loft opens the face upward to "scoop" the puck, so elevation keys off the
# axial twist far more than the X toe-lift. Eased via _blade_elevation_blend in
# _physics_process so it doesn't snap.
const _BLADE_ELEVATED_EXTRA_LOFT_DEG: float = 16.0   # axial twist (handedness-signed)
const _BLADE_ELEVATED_EXTRA_LIFT_DEG: float = 4.0    # about X (small touch of toe-lift)
const _BLADE_ELEVATION_BLEND_SPEED: float = 6.0      # blend units/sec (full swing in ~0.17 s)
# Toe-drag read. The shaft only steepens past its lie in TopHandIK's CLOSE
# regime (the hand rising to shorten the stick's horizontal run) — in the FAR
# regime the hand rides at rest height and the shaft holds the lie exactly, so
# the factor is identically 0 there. Onset is ~6° past the lie (blade ≈ 0.87 m
# from the shoulder); full at the dig clamp (≈ 0.65 m), holding full from there
# down to the hand_y_max floor (≈ 0.28 m). Carry-only: the wrists roll the
# face CLOSED over the puck (signed against the elevation scoop, so a drag
# visibly cups where a loft opens) and curl the toe in around it (the
# axial-twist sweep).
const _BLADE_TOE_DRAG_ONSET_DEG: float = -6.0
const _BLADE_TOE_DRAG_FULL_DEG: float = _BLADE_FOLLOW_PITCH_MIN_DEG
const _BLADE_TOE_DRAG_ROLL_DEG: float = 20.0         # axial twist (handedness-signed)
# Mild face close at full backhand cradle — a backhand can't roll to a
# forehand hook, so the cradle cups instead of rolling (grammar table in the
# push-model plan).
const _BLADE_CRADLE_CUP_DEG: float = 8.0             # axial twist (handedness-signed)

# Shoulder anchor offset from body center. The shoulder (top-hand anchor)
# sits on the OPPOSITE side of the body from the blade: a left-handed shooter
# (blade on −X) has the top hand on the right shoulder (+X), and vice versa.
# Matches the ShoulderL/R cap origins in Scenes/Skater.tscn (keep in sync)
# so the drawn arm roots at the deltoid cap. Sits so the cap's blunt base
# seats into the trap slope (torso upper-chest x extent ~0.21) with its
# equator just proud of the jersey.
var shoulder_offset: float = 0.22
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
var shoulder_height: float = 0.40
# Blade length (heel to toe). The Blade Marker3D represents the heel (where
# the shaft meets the blade); the blade mesh extends forward by this distance.
# The puck plays at the contact point, which is blade_length * 0.5 forward
# of the Marker3D along its local forward axis (-Z in local, which
# set_blade_position() orients via look_at each tick). The visible blade mesh
# is generated from this length by StickBladeMeshBuilder (_rebuild_blade_mesh)
# — the BoxMesh in Scenes/Skater.tscn is only a pre-_ready placeholder.
var blade_length: float = GameRules.DEFAULT_BLADE_LENGTH_M
# Cosmetic blade-mesh geometry (StickBladeMeshBuilder): how deep the curve
# bows, how late along the blade it turns (higher = toe curve, lower = heel
# curve), the radius of the rounded toe corner, and how far the face twists
# open toward the toe. Pure visuals — contact math reads the Blade marker +
# blade_length only; the gameplay face angle is PlayerAttributes' own table.
# Defaults are the M92 pattern; apply_blade_pattern swaps the set per the
# CURVE gear.
var blade_curve_depth: float = 0.022
var blade_curve_power: float = 3.0
var blade_toe_round_m: float = 0.028
var blade_face_twist_deg: float = 7.0
# Length of the hosel — the tapered throat carrying the heel cross-section up
# the shaft line (the shaft-follow tilt keeps the blade rigidly at
# blade_lie_deg to the shaft, so fixed blade-local hosel geometry stays glued
# to the rendered shaft in every pose). Blade mesh only; the tape band keeps
# its flat heel cap.
var blade_hosel_length: float = 0.085
# The stick's built-in lie: the shaft↔ice angle at which the blade sits flat.
# Derived from the rest pose (hand ~0.87 m above the heel over a
# sqrt(1.30² − 0.87²) ≈ 0.97 m horizontal run → atan ≈ 42°, i.e. about a
# real lie 5.5). The shaft-follow pitch reads deviation from this angle.
var blade_lie_deg: float = 42.0
# Reception ceiling lean from the blade-curve gear (attributes v4): the
# reception decision sites scale the puck's league deflect ceiling + squared
# bonus by this — a flatter pattern soaks a harder feed. Set by
# SkaterController.apply_attributes; never touches pickup_max_speed (the
# always-catches floor stays build-independent, which keeps the client's
# provisional-pickup gate exact).
var reception_ceiling_mult: float = 1.0

# The player's tape job (blade wrap color + coverage, knob color). Cosmetic —
# set by PlayerRegistry from the replicated per-peer tape code before the
# uniform is applied; SkaterUniformCoordinator resolves the palette picks
# against the team accent when it paints. Never null after _init.
var tape_config: StickTapeConfig = StickTapeConfig.new()
# The player's gear cosmetics (skate/glove models, laces, stick, helmet face
# gear) — same contract as tape_config: set from the replicated per-peer code
# before the uniform is applied, resolved against the kit by the uniform
# coordinator. Never null.
var gear_style: GearStyleConfig = GearStyleConfig.new()
var wall_squeeze_threshold: float = 0.3
# When the puck is lost on the boards (blade squeezed past the threshold above),
# it squirts ALONG the boards in the carrier's travel direction. This blends a
# small fraction of the inward wall normal into that release so the puck peels a
# touch off the boards rather than hugging them — reads as coming free. 0 = pure
# along-wall slide; ~0.25 ≈ 14° off the boards.
var wall_pin_inward_bias: float = 0.25
# How far the blade mesh visually shifts perpendicular to the stick toward the
# forehand or backhand face during carry. Player's cursor stays at the puck;
# the visible blade renders just to one side of the puck on the appropriate
# face. Pure cosmetic — IK math, pickup distance, shot release all use the
# centered blade contact.
var carry_blade_offset: float = 0.07
# How fast the rendered carry factor lerps toward the discrete ±1 side.
# Higher = snappier flip, lower = visible swing through center. ~12/s ≈ 80 ms
# to traverse 95% of the transition.
var carry_side_lerp_speed: float = 12.0
# Peak Y lift (world meters) of the transit hop — the blade rising over the
# puck while the pushing face flips (see get_carry_transit_factor). Set to 0
# to disable.
var carry_transit_lift: float = 0.10
# ── Stickhandling push model (docs/stickhandling-push-model-plan.md) ──────────
# The blade renders on the side of the puck it is PUSHING from — the side
# opposite the puck's motion in the carrier's frame — and inward pulls play
# the toe-drag / heel-cradle grammar. All keyed off blade velocity relative to
# the body, which every peer derives from the replicated pose, so the strokes
# read identically across the lobby with no wire field.
#
# Lateral stroke speed (m/s in the carrier's frame) that flips the pushing
# face. Below it the blade cradles on its current side; the threshold doubles
# as the flip hysteresis, since re-flipping takes a genuine opposite stroke
# back above the same bar. Sized well above interpolation noise and well
# under a deliberate dangle stroke.
var carry_flip_speed: float = 0.8
# Inward-pull speed band (m/s toward the body) over which the pull grammar
# ramps 0→1. The floor keeps a slow reposition a plain cradle; the ceiling
# lands full grammar at a committed pull, still far under the dangle
# speed cap.
var carry_pull_ramp_min: float = 0.8
var carry_pull_ramp_max: float = 2.5
# Half-band (m of handedness-normalized body-local blade X) over which an
# inward pull blends between the toe drag (forehand side) and the heel cradle
# (backhand side), covering pulls through body centre without a seam.
var carry_diagonal_band: float = 0.15
# Ease rate (units/s) for the two pull-gesture factors — fast enough to land
# inside a real pull (~0.13 s full swing), slow enough not to flicker on a
# jittery stroke.
var carry_gesture_ease: float = 8.0
# Duration (s) of one transit hop. A flip that arrives while a hop is still
# in flight rides it out rather than restarting, so a fast dangle bounces
# once per stroke instead of hovering mid-air (the plan's trap #2).
# Deliberately LONGER than the smoothed side factor's flip traverse
# (~2 / carry_side_lerp_speed ≈ 0.17 s): the blade crosses at the same speed
# but hangs before landing, which is the readable gap between blade touches —
# release off the toe, a beat of air, the heel catch on the far face.
var carry_transit_hop_time: float = 0.24
# ── Catch/release blade geometry (mesh-only, like the wrister address) ────────
# The visible blade slides along its own heel→toe axis so each stroke reads as
# real contact prosody: a hard push rolls the puck out toward the TOE (the toe
# is the last point of contact of every real stroke, so flips — which only
# happen mid-stroke — release off the toe automatically), and the far face
# lands HEEL-first and rolls back to the carry seat. Pure blade-mesh offsets
# (_apply_blade_tilt): the puck stays bound to the cursor, and the marker the
# gameplay reads is untouched.
#
# Toe-ward ride at full stroke speed, as a fraction of blade_length; ramps in
# over [carry_flip_speed, carry_stroke_full_speed] of lateral stroke.
var carry_stroke_toe_u: float = 0.12
var carry_stroke_full_speed: float = 3.0
# Heel-first landing offset at the instant of the catch (fraction of
# blade_length), decaying to the seat at carry_catch_decay per second.
var carry_catch_heel_u: float = 0.14
var carry_catch_decay: float = 7.0
# ── Pass-reception cushion (mesh-only, same channel as the catch above) ───────
# A caught feed knocks the blade back along its own arrival line before the
# hands re-seat it — the visible momentum absorb of the catch. Fired by each
# machine's own attach path (trigger_reception_cushion) with the puck's
# velocity relative to the receiver; the give scales with the SQUARE of that
# closing speed (stopping distance under a constant absorb force ∝ v², the
# same hands-soak model PuckReceptionRules is calibrated on), so a
# walking-pace pickup gives essentially nothing and a full-pace feed reads as
# a real corral. One continuous model — there is deliberately no separate
# slow-pickup animation. Blade-mesh slide plus a wrist cup closing over the
# puck; the marker, pin, and cursor binding are untouched.
var reception_give_max: float = 0.12       # m of give at a ceiling-speed catch
var reception_give_decay: float = 5.0      # blend/s back to the seat
var reception_cup_deg: float = 7.0         # extra face close-over at full give
# Closing speed (m/s, receiver frame) at which the give saturates. Mirrors the
# any-angle deflect ceiling (Puck.deflect_min_speed) — a hotter arrival
# deflects instead of catching, so the visual maxes out there.
var reception_give_full_speed: float = 22.0
# Commit threshold on |aim_dir · face_normal| (both unit) for the wrister
# address flip — the aim line must sit at least ~asin(this) (~14°) off the
# stick line before the addressed side changes, so a near-parallel aim holds
# instead of flickering. See _update_wrister_address.
var wrister_address_commit_dot: float = 0.25
# WHERE ALONG THE BLADE the wound-up puck sits, as a fraction of blade_length
# from the heel (0.5 = mid-blade, the un-tell'd contact point). This is the
# diegetic readout of the loft level during a wrister wind-up: the level is
# fictionalized as the contact point, so a defender or goalie studying a
# committed shooter can read the elevation intent off the blade's seat and the
# shooter can beat that read by switching levels late. Blade-mesh only
# (_aim_seat_offset_u → _apply_blade_tilt): the BLADE slides around the frozen
# puck, the pin never leaves the cursor. Derived per peer from the replicated
# elevation_level and blade pose, so remote views agree.
var carry_contact_flat_u: float = 0.34
var carry_contact_high_u: float = 0.70

# ── Arm Tuning ────────────────────────────────────────────────────────────────
# Two-bone arm IK: shoulder → elbow → top_hand. ROM is derived from these
# values in SkaterController.apply_attributes: the forehand cap is anatomical
# (cross-body reach, arm × 0.5625) and the backhand cap is chain-derived
# (sqrt(arm_eff² − shoulder-to-hand drop²)), so no reachable hand target ever
# exceeds the arm's length — the forearm never draws stretched.
# 0.33 per segment ≈ real shoulder→elbow and elbow→fist-center at the mesh's
# native 5'10" — the distal bone ends at the FIST, so it carries the hand's
# length too, which is also why the two split evenly. One arm = 0.70 m; with the
# shoulder caps at ±0.22 that is a wingspan ≈ 1.84 m on a 1.78 m body, ~103% of
# height and inside the 100–104% real athletes run.
var upper_arm_length: float = 0.33
var forearm_length: float = 0.33
# Pole direction for the elbow (upper-body local). Mostly down with a real
# outward flare (+X is away from the body; the sign flips per side in
# update_arm_mesh) and a touch backward — a hockey top-hand elbow rides out
# and slightly behind the chest line, not pinned against the ribs.
var arm_pole_local: Vector3 = Vector3(0.55, -1.0, 0.1)
# Base size of the arm bone meshes. scale.z is set per tick to the bone's
# actual length; X/Y control arm thickness. Sized as a padded JERSEY SLEEVE
# (elbow pad + liner under cloth), not a bare arm: a bare-arm 0.055 radius reads
# skinny next to the 0.09 socks.
var arm_mesh_thickness: float = 0.13
# Radius of the elbow joint spheres positioned per-tick at the IK elbow.
# Well proud of arm_mesh_thickness * 0.5 so the joint reads as the elbow
# PAD bulging under the sleeve, the arm's answer to the deltoid caps.
var elbow_sphere_radius: float = 0.082
# Radius of the gloved fist positioned per-tick at the IK hand — slightly
# thicker than the sleeve it hangs from. 0.064 puts the fist mesh (±1.05
# unit-width) at ~13.4 cm across the knuckles, a real glove proportion.
var hand_sphere_radius: float = 0.064
# Gap (along the bone direction, toward the elbow) between the hand-sphere
# center and the forward face of the glove cuff cylinder. Without this the
# cuff sits flush against the hand sphere and visually swallows it; a small
# pullback exposes the hand sphere as a distinct ball at the wrist.
var cuff_wrist_offset: float = 0.05

# ── Stick Flex Tuning (cosmetic) ──────────────────────────────────────────────
# Vertex-shader shaft bow (Shaders/stick_flex.gdshader), driven entirely from
# replicated fields (current_shot_state + shot_charge) and the stick's own
# rendered pose, so every machine renders identical flex with no controller
# plumbing and no network state. The shader displaces vertices BETWEEN the
# pinned endpoints — the hand and blade anchors (gameplay) never move.
# Amplitudes are unsigned metres; which way the bow points is geometry, solved
# per frame by SkaterStickRig's bow-axis solve.
var stick_flex_max_m: float = 0.07       # mid-shaft bow at full wrister charge
var stick_flex_slap_m: float = 0.10      # contact bow of the slapshot / one-timer
var stick_flex_windup_m: float = 0.045   # trailing bow at a full slapper wind-up
var stick_flex_load_speed: float = 10.0  # how fast the bow tracks the charge
var stick_whip_hz: float = 9.0           # release-whip oscillation frequency
var stick_whip_damping: float = 14.0     # release-whip decay rate

# ── Body Footprint ────────────────────────────────────────────────────────────
# Radius (m) of the disc every analytic contact path treats as this skater's
# body: skater-vs-skater in _resolve_player_collisions and the rink / net /
# goalie containment clamps. Scaled per-build by SkaterController.apply_attributes
# (radius_mult), so read it through collision_radius() rather than caching it.
var body_collision_radius: float = 0.35

# ── Body Check Tuning ─────────────────────────────────────────────────────────
var weight: float = 1.0
# Fraction of closing momentum the inelastic resolver transfers on a committed
# check (SkaterCollisionRules — the only body-check delivery term). At
# equal mass the victim's knockback is closing × transfer × 0.5, so this is the
# master "how hard does a check hit" dial: raising it strips/staggers/knocks-down
# at lower closing speeds AND deepens the attacker's own inelastic decel (the
# symmetric exchange — a real check costs the checker some speed too). Scaled
# per-build by PlayerAttributes.check_delivery_mult (flat 1.0 in v4 — mass is the
# only differentiator), so the same 0.65 lands for every build.
var body_check_transfer: float = 0.65
var body_check_brace_resistance: float = 0.4
# Fraction of body_check_transfer that lands WITHOUT the hit button committed.
# The hit button (Ctrl / input.hit_held) is the intent gate: a committed check
# delivers the full transfer, an incidental bump only this fraction — so skating
# into someone uncommitted jostles but rarely staggers and never knocks down.
# Set by the controller each tick via hit_committed below (re-derived from
# input.hit_held, so it survives reconcile with no wire cost).
var hit_passive_transfer_mult: float = 0.3
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
var body_block_radius: float = 0.5
var block_body_radius: float = 0.9
# World-Y ceiling of the shot-block seal — the top of the KNEELING body (helmet
# shell, ≈1.44 m at the default build; the standing head reaches ≈1.85 m). A
# blocker who drops to a knee gives up everything above it, so elevating over
# him beats the block. Authored rather than measured off the live pose on
# purpose: the pose is a render-rate cosmetic (SkaterSkatingCoordinator), and
# collision must not depend on when a frame happened to draw. Re-derive it if
# the kneel angles move — test_shot_body_animation pins the two together.
var block_seal_height: float = 1.45
# Vertical center of the body-block sphere, in skater-local space (origin sits at
# the hips). Raised to torso height so the PASSIVE sphere (body_block_radius)
# clears a grounded puck (top ≈ ice_height + radius ≈ 0.12) — loose pucks on the
# ice slip under/between the legs, enabling nutmegs. The WIDER explicit-block
# sphere (block_body_radius, Ctrl) is what stops a low puck: set_block_stance
# rebases it to seal from the ice up (the hip-height origin puts this local
# offset at the torso, so without the rebase a flat shot slid under the block).
# Mirrors the grounded-vs-airborne split the blade already uses.
var body_block_height: float = 0.7

# ── Node References ───────────────────────────────────────────────────────────
@onready var mesh_root: Node3D = $MeshRoot
@onready var lower_body: Node3D = $MeshRoot/LowerBody
@onready var upper_body: Node3D = $MeshRoot/UpperBody
@onready var blade: Marker3D = $MeshRoot/UpperBody/Blade
@onready var shoulder: Marker3D = $MeshRoot/UpperBody/Shoulder
@onready var stick_mesh: MeshInstance3D = $MeshRoot/UpperBody/StickMesh

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

# Visual forearm-bulk multiplier (the Hands attribute's arm tell), stamped by
# SkaterAppearanceCoordinator.apply. The glove cuff radius must scale with this,
# not stay fixed: at Hands 4 the scaled forearm (0.055 × 1.20) is EXACTLY the
# fixed cuff's 0.11 × 0.6 — coaxial cylinders of equal radius, z-fighting the
# whole wrist — and Hands 5 pokes clean through. Read by both the appearance and
# the uniform pass, which size the cuff independently and in either order.
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
# Fired at the END of _physics_process, AFTER integration + collision resolution
# + the containment clamps have settled this tick's position and velocity. The
# local player's controller uses it to capture its reconcile prediction snapshot
# at the same post-integration sub-step the host samples for its world-state
# broadcast (StateBufferManager.capture → fill_network_state, which reads the
# post-move skater.global_position). The snapshot must not be taken pre-move:
# one integration step of phase offset against the host's state for the same
# host_timestamp exceeds reconcile_position_threshold on nearly every moving
# tick. Emitted for every skater; only the local controller connects.
signal post_move_integrated()
# Mirrors SkaterStateMachine.State for the current carrier. Updated each tick
# by Local/RemoteController so the goalie AI can read shot-state tells (e.g.
# SLAPPER_CHARGE_WITH_PUCK windup) without reaching across controller boundaries.
#
# Gaining or losing the puck raises _blade_tilt_dirty because the toe-drag wrist
# roll is carry-only: possession can flip on a tick where no marker moved, and
# _rig_pose_changed cannot see that (same reason _update_blade_elevation raises
# it). Only the has-puck EDGE trips it — shot-state churn within a carry, which
# is most of the traffic through here, costs a comparison.
var current_shot_state: int = 0:
	set(v):
		if SkaterStateMachine.state_has_puck(v) \
				!= SkaterStateMachine.state_has_puck(current_shot_state):
			_blade_tilt_dirty = true
		current_shot_state = v

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

# ── Cosmetic Rig Dirty-Flag ──────────────────────────────────────────────────
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
var _rig_last_check_lead: float = NAN
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
# skater contact. Empty Callable (tutorial dummy / test) → no resolution.
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
# each goalie — skater-vs-goalie contact is analytic.
# Empty Callable (tutorial dummy / test) → no goalie block.
var _goalie_data_provider: Callable = Callable()


func set_goalie_data_provider(provider: Callable) -> void:
	_goalie_data_provider = provider


# Set true by the analytic containment clamps (rink / net / goalie) on any tick
# they reposition the body — i.e. the skater is pinned against a boundary this
# tick. LocalController reads it to suppress reconcile jitter there. Reset at the
# start of each _physics_process integration.
var _touched_boundary: bool = false


func is_touching_boundary() -> bool:
	return _touched_boundary


# The (Size-scaled) disc radius every analytic contact path shares — skater-vs-
# skater and the three containment clamps read the same number, so the hitbox and
# the contact geometry cannot drift apart.
func collision_radius() -> float:
	return body_collision_radius


# ── Runtime ───────────────────────────────────────────────────────────────────
# World-space velocity in m/s, integrated into global_position once per tick in
# _physics_process. Y stays 0 (top-down game, no gravity). Owned by whichever
# machine simulates this skater; it is on the wire (SkaterNetworkState) and the
# reconcile replay rewinds and re-integrates it, so nothing may mutate it outside
# a controller's tick or the replay will not reproduce the live result.
var velocity: Vector3 = Vector3.ZERO
var _facing: Vector2 = Vector2.DOWN
# Loft mode (0 flat / 1 low saucer / 2 high). Set each tick by the controller
# from the input frame; replicated so remotes/AI read it directly.
var elevation_level: int = 0
# Eased 0→1 toward elevation_level/3 (a third per rung, full at HIGH); drives
# the extra blade toe-lift (see _update_blade_elevation / _apply_blade_tilt).
var _blade_elevation_blend: float = 0.0
# Set when an elevation blend step changes the blade tilt, consumed by the
# render-rate rig pass in _process. See _update_blade_elevation.
var _blade_tilt_dirty: bool = false
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
# Signed check-commit shoulder lead in [−1, +1] (+1 = the RIGHT shoulder leads),
# eased on the same gate and clock as the stick raise above. Sign is the leading
# side and magnitude the load depth, so a change of side can only happen by
# sliding through a square-shouldered pose. Drives the per-shoulder load-up on
# the cap/arm rig and the loaded blade's sweep — see CheckStanceRules.
var _check_lead: float = 0.0
# Metres of choke-up at a full commit, scaled per build off this skater's own
# stick by SkaterController.apply_attributes. Read through grip_choke() below —
# both the arm solve and the drawn shaft take it from there.
var commit_grip_choke_m: float = 0.0
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
# Last known-finite body position, cached each tick before the integration step so
# the non-finite guard (_sanitize_physics_state) can restore a sane position if
# some upstream bug ever feeds NaN/Inf into the body. Seeded from the spawn position.
var _last_finite_position: Vector3 = Vector3.ZERO
var _prev_blade_contact: Vector3 = Vector3.ZERO
var _last_wall_normal: Vector3 = Vector3.ZERO
var _default_upper_body_y: float = 0.0
var _default_lower_body_y: float = 0.0
# Cosmetic vertical drop of the whole visible body (torso + hips) while in
# the bent-knee skating stance, so the flexed legs keep the skates on the
# ice. Driven by SkaterSkatingCoordinator; composes with the shot-block
# crouch through _apply_body_height (the single writer of both body Ys).
var _skating_crouch_drop: float = 0.0
var _block_stance_active: bool = false
# Slapper one-timer zone — armed only while charging a slapper without the puck
# (see set_slapper_zone). Plain state: the zone is an ice-plane disc the analytic
# one-timer scans test against, not anything the engine knows about.
var _slapper_zone_active: bool = false
var _slapper_zone_radius: float = 0.0
# Zone center in skater-local space; get_slapper_zone_global_position rotates it
# with the body and drops it to the ice plane.
var _slapper_zone_offset: Vector3 = Vector3.ZERO
var _skeleton_root_offset: float = 0.0  # see set_skeleton_root_offset
# Sticky carry side: 0 when not carrying, ±1 while carrying — stored in
# forehand-normalized space (+1 = the offset lands on the forehand side for
# either handedness), flipped by strokes in _update_carry_contact.
var _carry_side: int = 0
# Smoothed rendered carry factor — lerps toward _carry_side at
# carry_side_lerp_speed. This is what get_carry_forehand_factor() returns so
# the visible flip animates through center instead of teleporting.
var _carry_side_smoothed: float = 0.0
# Eased pull-grammar factors (0→1), advanced by _update_carry_contact: the
# gestural toe drag (inward pull on the forehand diagonal — merged with the
# positional read in get_toe_drag_factor) and the backhand heel cradle.
var _toe_drag_gesture: float = 0.0
var _heel_cradle: float = 0.0
# Remaining phase (1→0) of the current transit hop; see
# get_carry_transit_factor.
var _transit_hop: float = 0.0
# Eased catch/release blade-geometry blends (0→1), advanced by
# _update_carry_contact: stroke-speed toe ride and the heel-first catch
# transient fired when a hop lands. Both feed the mesh seat slide in
# _apply_blade_tilt only.
var _stroke_toe_blend: float = 0.0
var _catch_heel_blend: float = 0.0
# Reception-cushion transient: unit arrival direction in blade-marker-local
# space (captured at the attach instant) and its decaying amplitude. Fed by
# trigger_reception_cushion, decayed alongside the blends above, consumed by
# _apply_blade_tilt only.
var _reception_give_dir: Vector3 = Vector3.ZERO
var _reception_give_blend: float = 0.0
# Eased 0→1 gate for the wind-up elevation seat (_aim_seat_offset_u) — 1 while
# in WRISTER_AIM, so the seat tell slides in with the commit and back out with
# the release instead of snapping on the state edge.
var _aim_seat_blend: float = 0.0
# ── Wrister address (see set_wrister_address) ─────────────────────────────────
# The live aim line (origin→cursor, world XZ), pushed per aim tick by the
# controller. The shot is a push along this line, so the frozen blade
# addresses the side of the puck it will push from — the same trailing-side
# rule strokes use, which is what makes the address geometric and
# handedness-free: it tracks where the aim actually is, not a body-relative
# hand label (a label-keyed side sat on the wrong side of the puck whenever
# the aim line disagreed with the natural pose for that hand). valid is false
# on peers that never receive the push (client-rendered remotes), which keep
# the frozen entry pose rather than guessing.
var _wrister_address_dir: Vector3 = Vector3.ZERO
var _wrister_address_valid: bool = false
# Eased blade-address factor in face-normal space (get_carry_forehand_factor's
# units). Outside a wrister aim it is pinned to the live carry factor (zero
# offset); during the aim it eases toward the addressed side, and the delta to
# the live factor slides the blade MESH over the still puck (_apply_blade_tilt).
var _address_factor: float = 0.0
# Committed address side in face-normal sign space (0 = unseeded). Flipped by
# CarryContactRules.stroke_side over the aim-line dot on simulating peers, or
# adopted from the wire-staged target on render-only remotes; a change is the
# crossing that fires the transit hop.
var _wrister_address_side: int = 0
# Wire-staged side from set_wrister_address_side (0 = none staged) — adopted
# by _update_wrister_address so crossings are detected in one place.
var _wrister_address_target_side: int = 0
# Visual-only offset applied to MeshRoot each frame. Set by LocalController
# during reconcile blending to ease the visible correction over a few ticks.
# The body itself is always at the authoritative position.
var visual_offset: Vector3 = Vector3.ZERO:
	set(v):
		visual_offset = v
		if mesh_root != null:
			# Shifts MeshRoot, an ancestor of the Blade marker — the blade
			# contact memo must not serve the un-shifted point.
			_blade_contact_dirty = true
			mesh_root.position = global_transform.basis.inverse() * v

# Collaborators. The three rigs own the cosmetic skeletons and the stick; the
# draw tracker is the faceoff clock. Each reads this node's tuning vars and
# markers and writes only its own state — see Scripts/actors/CLAUDE.md.
var _legs: SkaterLegRig
var _arms: SkaterArmRig
var _stick: SkaterStickRig
var _draw: SkaterDrawTracker = SkaterDrawTracker.new()
var _uniform: SkaterUniformCoordinator
var _hud: SkaterHUDCoordinator
var _appearance: SkaterAppearanceCoordinator


func _ready() -> void:
	add_to_group("skaters")

	# On-skates stance: the scene layout is standing height, so the skate
	# stack lifts both body roots (see SkaterMeshBuilder.SKATE_LIFT_M — the
	# blade meshes reach correspondingly deeper to keep the steel on the
	# ice). Before the _default_*_y captures below, so the height attribute's
	# root scaling composes on the lifted stance. Gameplay is unaffected: the
	# blade IK targets the world ice plane, and the hitbox never moves.
	upper_body.position.y += SkaterMeshBuilder.SKATE_LIFT_M
	lower_body.position.y += SkaterMeshBuilder.SKATE_LIFT_M

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

	# Rig collaborators first: the uniform and appearance passes below paint and
	# size through their seams, and the stick rig's setup subdivides the shaft
	# mesh the uniform's shader material is about to be installed on.
	_legs = SkaterLegRig.new()
	_legs.setup(self)
	_legs.build()

	_arms = SkaterArmRig.new()
	_arms.setup(self)
	_arms.build()

	_stick = SkaterStickRig.new()
	_stick.setup(self)

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
	# bottom_hand) the physics-rate controllers and interpolators maintain —
	# nothing reads the mesh transforms back — so one pass per rendered frame,
	# after every physics tick for that frame has finalized the markers, is
	# exactly the work the screen consumes. On the tick instead, ~75% of it
	# draws to nobody and reconcile re-runs it once per replayed input, a hitch
	# arriving exactly when the network is already degraded. The rebuild is
	# skipped when hidden or when no marker moved (dirty flag); stick flex is
	# time/state-driven, so it runs every frame regardless (own shader-write
	# guard) and a mid-shot whip never freezes on an otherwise-static pose.
	#
	# render_pose_update's pose — gait, head tracking, off-hand IK — is genuinely
	# time-driven, so project-wide physics interpolation resamples it at the tick
	# rate and draws it a tick late. Accepted: the gait is a few-Hz oscillation
	# and a tick of latency on a cosmetic pose is invisible. Do NOT opt these
	# nodes out to win that back — an opted-out child renders against the body's
	# post-tick position while the body renders interpolated, separating the two
	# by up to a tick of travel, and the stick visibly leaves the hands at speed.
	if is_visible_in_tree():
		# Cosmetic pose (leg gait / head / off-hand IK) at render rate, before the
		# marker-driven mesh rebuild that consumes it. Skipped entirely when hidden
		# — an off-screen skater needs no animated pose. Gameplay-relevant pose
		# (facing, upper-body twist, blade IK) already ran in the physics tick.
		if render_pose_update.is_valid():
			render_pose_update.call(delta)
		# _blade_tilt_dirty is ORed in because an elevation blend step changes the
		# blade tilt without moving any marker, so _rig_pose_changed can't see it
		# (see _update_blade_elevation). Left set while hidden so the pose is
		# rebuilt on the first visible frame.
		if _rig_pose_changed() or _blade_tilt_dirty:
			_blade_tilt_dirty = false
			update_stick_mesh()
			update_arm_mesh()
			update_bottom_arm_mesh()
	_stick.update_flex(delta)
	# World HUD (ring, name, chevrons, beacon) at RENDER rate: ~10 top_level node
	# transforms per skater that nothing reads back and no gameplay depends on,
	# so the physics rate would buy nothing and running here aligns them with the
	# pose actually being drawn. Its internal timers (ping bubble, ring recolour)
	# are wall-clock accumulators over delta, so the tick source changes when they
	# fire by less than a frame, not how long they last.
	if not CosmeticFreeze.hud:
		_hud.update(delta)


# Returns true (and refreshes the snapshot) when any marker feeding the cosmetic
# rig moved since the last rebuild. Exact equality is sufficient: a converged
# pose reproduces bit-identical local marker positions, and any real motion trips
# the compare. Handedness flips move the shoulder/hand markers via
# _position_hand_markers, so they trip it too. The check load-up is in here for
# the same reason: it displaces the arm roots without moving a marker, so a
# rebuild gated on markers alone would hold the arms at the un-loaded shoulder.
# Markers are guaranteed non-null by the time _process runs (created in _ready /
# setup), matching the unguarded access the rig functions already rely on.
func _rig_pose_changed() -> bool:
	if top_hand.position == _rig_last_top_hand \
			and blade.position == _rig_last_blade \
			and shoulder.position == _rig_last_shoulder \
			and bottom_shoulder.position == _rig_last_bottom_shoulder \
			and bottom_hand.position == _rig_last_bottom_hand \
			and _check_lead == _rig_last_check_lead:
		return false
	_rig_last_top_hand = top_hand.position
	_rig_last_blade = blade.position
	_rig_last_shoulder = shoulder.position
	_rig_last_bottom_shoulder = bottom_shoulder.position
	_rig_last_bottom_hand = bottom_hand.position
	_rig_last_check_lead = _check_lead
	return true


func _physics_process(delta: float) -> void:
	var _t0: int = Time.get_ticks_usec()
	# _prev_blade_contact is captured at the top of each controller's tick, before
	# the per-tick IK update runs (see Skater.capture_prev_blade_contact()).
	# Capturing it here would read post-IK and miss the swing within the tick.
	var blade_world_pos: Vector3 = upper_body.to_global(blade.position)
	blade_world_velocity = (blade_world_pos - _prev_blade_world_pos) / delta
	_prev_blade_world_pos = blade_world_pos
	if _draw.is_tracking():
		_draw.update(delta, blade_world_velocity)
	# Backstop: never let a NaN/Inf velocity or position reach the transform write —
	# it poisons every downstream reader (camera, IK, the wire state) irrecoverably.
	# This should never fire; when it does it logs the offending state so the
	# upstream source is findable.
	_sanitize_physics_state()
	# The whole move step: no engine body, no solver, just integration. This is the
	# same `pos += vel·dt` LocalController's reconcile replay runs, so the live tick
	# and the replay cannot differ here. Y needs no handling — velocity.y is pinned
	# to 0 (top-down game, no gravity).
	_touched_boundary = false
	global_position += velocity * delta
	# Capture velocity BEFORE the analytic skater-vs-skater resolution so the delta
	# below isolates the body-check impulse (the resolver's self velocity change) for
	# the reconcile replay recording.
	var vel_pre_body_check: Vector3 = velocity
	_resolve_player_collisions()
	var body_check_delta: Vector3 = velocity - vel_pre_body_check
	if body_check_delta.length_squared() > 0.0001:
		body_check_impulse_applied.emit(body_check_delta)
	# Containment: the rink boundary, the net, and the goalie footprint are all
	# held analytically against the same disc (collision_radius). The rink clamp
	# runs AFTER the body-check delta is captured so a board slide never reads as
	# a hit. The reconcile replay calls the same three methods (see LocalController).
	clamp_body_to_rink()
	clamp_body_to_net()
	clamp_body_to_goalies()
	_update_blade_elevation(delta)
	_forced_lift_timer = maxf(_forced_lift_timer - delta, 0.0)
	_update_blade_lift(delta)
	_update_commit_stance(delta)
	_update_carry_contact(delta)
	# Position + velocity are now fully settled for this tick (integration,
	# body-check resolution, and the containment clamps above have all run).
	# The local controller captures its reconcile prediction snapshot here so it
	# reads the same post-integration state the host broadcasts (see the signal
	# doc-comment). The blade elevation/lift/carry-contact blends above are
	# cosmetic and don't touch the body position/velocity/upper-body fields the
	# snapshot records.
	post_move_integrated.emit()
	HostCostProbe.record(HostCostProbe.Section.SKATER_PHYS, Time.get_ticks_usec() - _t0)


# Sanitizes the body's velocity/position to finite values right before the tick
# integrates them. A NaN/Inf transform can't be un-poisoned once written (every
# derived read — camera, IK, wire state — inherits it), so we clamp at the seam
# and log where it came from. Cheap value-type checks — hot-path safe at 120 Hz ×
# skaters; the string-formatting cost only ever runs on the (should-never) branch.
func _sanitize_physics_state() -> void:
	if not velocity.is_finite():
		push_error("Skater '%s': non-finite velocity %s before integration — zeroing (state=%d pos=%s)."
				% [name, velocity, current_shot_state, global_position])
		velocity = Vector3.ZERO
	if global_position.is_finite():
		_last_finite_position = global_position
	else:
		push_error("Skater '%s': non-finite position %s before integration — restoring %s."
				% [name, global_position, _last_finite_position])
		global_position = _last_finite_position
		velocity = Vector3.ZERO


func _resolve_player_collisions() -> void:
	# Skater-vs-skater contact, resolved against the registry's cached skater list
	# via SkaterCollisionRules (inelastic disc model, no restitution bounce). No
	# provider (tutorial dummy / unit test) → no skater-vs-skater resolution.
	if not _skater_collision_provider.is_valid():
		return
	# A ghosted skater (offside / icing / crease-dwell) has no physical presence:
	# it neither delivers nor receives body contact. is_ghost replicates
	# (SkaterNetworkState), so every machine skips the same pairs and the aggressor
	# gate below stays deterministic.
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
		# the other more. agg_metric = (v_self + v_other)·n: > 0 → self is
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
# boards, so the skater slides smoothly along them. Pure value-type math — no
# allocation, so it's hot-path safe at 120 Hz × actors. Called live from the
# integration step and re-used by LocalController's reconcile replay so both paths
# agree.
func clamp_body_to_rink() -> void:
	# Inset the boundary by the (Size-scaled) body radius so the body's EDGE stops
	# at the boards — otherwise the center reaches the surface and the body clips in
	# by its radius (worse for bigger players).
	var radius: float = collision_radius()
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


# Holds the body out of the goal-net pocket. Mirrors clamp_body_to_rink: project
# the XZ clear of the net box via GameRules.push_out_of_net (radius-inset so the
# body EDGE stops at the panels) and strip any velocity pointing into the net, so
# the skater slides free instead of being re-seated by the shove next tick — most
# often when the goalie bulldozes a skater across the goal line before the
# crease-dwell ghost fires. Called live after clamp_body_to_rink; same replay
# and allocation contract.
func clamp_body_to_net() -> void:
	var radius: float = collision_radius()
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


# Holds the skater clear of every goalie's footprint so you can't walk through the
# goalie. Mirrors clamp_body_to_net: push the XZ out of the goalie footprint — a
# cylinder while standing/RVH, an oriented box in the butterfly (the leg pads
# spread wide) — and strip any velocity pointing into the goalie so the skater
# slides along it instead of being re-seated next tick. Reads the same
# host-refreshed goalie pose cache the blade clamp uses (position / rotation_y /
# is_butterfly). A ghosted skater (crease-dwell / offside) passes through, matching
# the is_ghost gate in _resolve_player_collisions. Called live after the rink/net
# clamps; same replay and allocation contract.
func clamp_body_to_goalies() -> void:
	if is_ghost or not _goalie_data_provider.is_valid():
		return
	var goalie_data: Array = _goalie_data_provider.call()
	if goalie_data == null:
		return
	var radius: float = collision_radius()
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


# Re-positions the four hand/shoulder Marker3Ds for the current is_left_handed
# value. Safe to call before _ready() — exits early while the markers are still
# missing.
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


# How far the blade has pitched off its built-in lie, in degrees, clamped to the
# render bounds. The blade is rigidly attached to the shaft, so it pitches by
# (blade_lie_deg − live shaft angle): ~0 at the rest lie (blade flat on the ice),
# POSITIVE toe-up when the stick rises (slapshot wind-up, stick lift, high
# follow-through finish) so the blade stays on the shaft line instead of floating
# ice-parallel at the tip of a steep shaft, NEGATIVE toe-down when the cursor
# pulls the blade in close and the shaft steepens past its lie.
#
# A pure function of the current hand/blade markers, which are replicated (and
# interpolated) on remotes — so every peer derives the same pitch, and anything
# keyed to it agrees across the lobby without its own wire field.
func _shaft_follow_pitch_deg() -> float:
	if top_hand == null or blade == null:
		return 0.0
	var shaft: Vector3 = blade.position - top_hand.position
	var horiz: float = Vector2(shaft.x, shaft.z).length()
	if horiz <= 0.001 and absf(shaft.y) <= 0.001:
		return 0.0
	var shaft_pitch_deg: float = rad_to_deg(atan2(-shaft.y, horiz))
	return clampf(blade_lie_deg - shaft_pitch_deg,
			_BLADE_FOLLOW_PITCH_MIN_DEG, _BLADE_FOLLOW_PITCH_MAX_DEG)


# 0→1 "the puck has come in under the body" factor. Two reads merged by max,
# both meaning the same posture (toe hooked over the puck, wrists rolled):
#   positional — the shaft steepened past its lie (see _BLADE_TOE_DRAG_*), the
#   stick tucked in tight at the feet;
#   gestural — a live inward pull on the forehand diagonal (_toe_drag_gesture,
#   advanced by _update_carry_contact), which fires out at full reach too,
#   where the shaft never steepens.
# Drives the wrist-roll twist in _apply_blade_tilt.
#
# Carry-only, like the forehand/backhand side and its transit lift: a toe drag
# is a puckhandling move, not a consequence of shaft angle, so an empty-handed
# player who tucks the stick in tight keeps a square blade.
func get_toe_drag_factor() -> float:
	if not SkaterStateMachine.state_has_puck(current_shot_state):
		return 0.0
	var positional: float = clampf(
			inverse_lerp(_BLADE_TOE_DRAG_ONSET_DEG, _BLADE_TOE_DRAG_FULL_DEG,
					_shaft_follow_pitch_deg()),
			0.0, 1.0)
	return maxf(positional, _toe_drag_gesture)


# Sets the cosmetic blade-mesh orientation — never the Blade marker the
# puck-contact math reads (set_blade_position / get_blade_contact_global).
# Three composed reads:
#   1. Shaft-follow pitch (_shaft_follow_pitch_deg) — the rigid shaft attachment.
#   2. Resting toe-lift + the scroll-loft elevation extras (about X).
#   3. Axial twist about the hosel axis (handedness-signed): every face-angle
#      dressing composed into one wrist rotation — the resting cup, the loft
#      level's scoop, the toe-drag roll, and the backhand-cradle cup, the last
#      two closing against the first two on purpose (a lofted blade cups under
#      the puck, a dragged one rolls over the top of it).
# The twist axis is the one a real wrist roll has: a blade has no degrees of
# freedom relative to the shaft, so every face rotation is the whole stick
# twisting about its own line. Structurally load-bearing, not flavor — the
# hosel tip (the point update_stick_mesh aims the shaft at) LIES ON that axis,
# so it is invariant under any twist angle: the shaft→blade junction cannot
# kink and the shaft never swings when a dressing engages. Do not rotate these
# angles about a heel-local axis instead — that drags the tip off the shaft line
# by up to a few cm at full toe drag. The
# twist also sweeps the toe horizontally (~7 cm at 20°) — the drag curl the
# overhead camera reads. The one remaining junction bend is the follow-pitch
# clamp at its floor/ceiling, which is deliberate (the dig floor keeps the toe
# out of the ice).
# The mesh is heel-origin (StickBladeMeshBuilder), so the rotation pivots
# about the heel and the shaft→blade junction stays pinned at any pitch.
# Idempotent (recomputed from identity each call, scale preserved — the
# tape-band child rides along); safe before _ready(). Runs at render rate
# from update_stick_mesh (value-type math only, no allocation).
func _apply_blade_tilt() -> void:
	if _blade_mesh_instance == null or not is_instance_valid(_blade_mesh_instance):
		return
	var follow_pitch_deg: float = _shaft_follow_pitch_deg()
	# Twist sign: opens the forehand face upward. Flipped from the usual
	# blade_side_sign convention so the cup tilts the right way for each hand.
	var blade_side_sign: float = 1.0 if is_left_handed else -1.0
	var drag: float = get_toe_drag_factor()
	var toe_lift: float = _BLADE_TOE_LIFT_DEG + follow_pitch_deg \
			+ _blade_elevation_blend * _BLADE_ELEVATED_EXTRA_LIFT_DEG
	var twist: float = (_BLADE_FACE_OPEN_DEG \
			+ _blade_elevation_blend * _BLADE_ELEVATED_EXTRA_LOFT_DEG \
			- drag * _BLADE_TOE_DRAG_ROLL_DEG \
			- _heel_cradle * _BLADE_CRADLE_CUP_DEG \
			- _reception_give_blend * reception_cup_deg) * blade_side_sign
	var pitch_basis: Basis = Basis.IDENTITY.rotated(Vector3.RIGHT, deg_to_rad(toe_lift))
	# Hosel axis (StickBladeMeshBuilder._add_hosel: (0, sin lie, cos lie) in
	# blade-local space), carried through the pitch so the twist stays about
	# the pitched shaft line.
	var lie_rad: float = deg_to_rad(blade_lie_deg)
	var hosel_axis: Vector3 = pitch_basis * Vector3(0.0, sin(lie_rad), cos(lie_rad))
	var rot: Basis = pitch_basis.rotated(hosel_axis, deg_to_rad(twist))
	var keep_scale: Vector3 = _blade_mesh_instance.transform.basis.get_scale()
	_blade_mesh_instance.transform.basis = rot.scaled(keep_scale)
	# Mesh-only slides (never the marker; the shaft follows for free, since
	# update_stick_mesh aims it at the hosel tip through this transform):
	#   X — wrister-address slide along the face-normal axis, addressing the
	#   hand the release will fire as. Marker local +X IS the face normal
	#   (set_blade_position aims marker −Z along the shaft, so +X is its 90°
	#   Y-rotation, the same axis get_carry_target_global offsets the pin
	#   along). Zero outside an aim (_address_factor pins to the live factor).
	#   Z — seat along the blade's own heel→toe axis (the mesh extends
	#   toe-ward along −Z, so a heel-ward +Z shift seats the puck nearer the
	#   toe): a hard stroke rides the puck out to the toe, a landing hop
	#   catches heel-first and rolls back, and a wrister wind-up seats the
	#   frozen puck per the loft level (_aim_seat_offset_u — the elevation
	#   tell). Blade-mesh prosody only — the puck stays bound to the cursor.
	# The reception cushion is the one full-vector slide on top of both axes:
	# the blade gives along the caught puck's own arrival line (captured
	# blade-local, so the give rides the wrists as the body keeps turning).
	_blade_mesh_instance.position = Vector3(
			(_address_factor - get_carry_forehand_factor()) * carry_blade_offset,
			0.0,
			(_stroke_toe_blend * carry_stroke_toe_u
					- _catch_heel_blend * carry_catch_heel_u
					+ _aim_seat_offset_u()) * blade_length) \
			+ _reception_give_dir * (_reception_give_blend * reception_give_max)


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
	p.curve_power = blade_curve_power
	p.toe_round_m = blade_toe_round_m
	p.face_open_deg = blade_face_twist_deg
	p.curve_sign = 1.0 if is_left_handed else -1.0
	p.inflate = inflate
	p.u_start = u_start
	p.u_end = u_end
	p.hosel_length = hosel_length
	p.hosel_angle_deg = blade_lie_deg
	return p


# Tape-band mesh for the current blade geometry and tape job, heel-origin like
# the blade mesh itself (the band node sits at the blade mesh's origin,
# untransformed). Null when the tape job leaves the blade bare.
func build_blade_tape_mesh() -> ArrayMesh:
	if not tape_config.has_blade_tape():
		return null
	return StickBladeMeshBuilder.build_tape(
			blade_mesh_params(0.0, 0.0, 1.0), tape_config.span_range())


# Installs a new tape job and refreshes the rendered tape (geometry here,
# color via the uniform coordinator's tape repaint).
func set_tape_config(config: StickTapeConfig) -> void:
	if config == null:
		return
	tape_config = config
	if _uniform != null:
		_uniform.refresh_tape()


# Installs a new gear look (models, laces, face gear) and repaints the
# affected parts. Same live-cosmetic contract as set_tape_config.
func set_gear_style(config: GearStyleConfig) -> void:
	if config == null:
		return
	gear_style = config
	_arms.apply_face_gear()
	if _uniform != null:
		_uniform.refresh_gear_style()


# The face piece's render node, for the uniform coordinator's paint and ghost
# fade. Null while the pick is bare.
func face_gear_mesh() -> MeshInstance3D:
	return _arms.face_gear_mesh()


# The uniform pass installs a fresh shaft ShaderMaterial (uniform apply,
# un-ghost); its dirty guards have to forget their last-written values or an
# unchanged flex/length never re-sends.
func notify_shaft_material_rebuilt() -> void:
	_stick.notify_material_rebuilt()


# Blade pattern per CURVE gear — the visual half of the gear whose gameplay
# half lives in PlayerAttributes (loft / backhand / slap / reception).
# Modeled on the real patterns the gear names: M88 (mid curve — moderate
# depth spread through the middle, near-flat face, round toe), M92 (mid-toe
# all-rounder — the shipped house pattern, the middle row), M28 (toe hook —
# flat through the heel then a late deep bend with a visibly open toe face,
# slightly pointier toe). Depth and POWER place the bend (low power = early
# mid-blade bend, high = late toe hook); FACE_DEG twists the face open toward
# the toe (builder face_open_deg); TOE_ROUND is the corner radius. Called
# from SkaterController.apply_attributes, so the rendered blade matches the
# pick. Public: LockerMannequin builds its stick blade from the same rows.
const BLADE_PATTERN_DEPTH: Array[float] = [0.018, 0.022, 0.030]
const BLADE_PATTERN_POWER: Array[float] = [2.2, 3.0, 4.6]
const BLADE_PATTERN_FACE_DEG: Array[float] = [3.0, 7.0, 12.0]
const BLADE_PATTERN_TOE_ROUND: Array[float] = [0.030, 0.028, 0.024]


func apply_blade_pattern(curve_gear: int) -> void:
	var g: int = clampi(curve_gear, 0, BLADE_PATTERN_DEPTH.size() - 1)
	if is_equal_approx(blade_curve_depth, BLADE_PATTERN_DEPTH[g]) \
			and is_equal_approx(blade_curve_power, BLADE_PATTERN_POWER[g]) \
			and is_equal_approx(blade_face_twist_deg, BLADE_PATTERN_FACE_DEG[g]) \
			and is_equal_approx(blade_toe_round_m, BLADE_PATTERN_TOE_ROUND[g]):
		return
	blade_curve_depth = BLADE_PATTERN_DEPTH[g]
	blade_curve_power = BLADE_PATTERN_POWER[g]
	blade_face_twist_deg = BLADE_PATTERN_FACE_DEG[g]
	blade_toe_round_m = BLADE_PATTERN_TOE_ROUND[g]
	_rebuild_blade_mesh()


# Eases the elevation blend toward the loft level each tick (move_toward lands
# exactly on the target, after which the early-out stops the per-tick churn).
# Called from _physics_process because the blend is physics-timed.
#
# The stick REBUILD it triggers is cosmetic, so it is deferred to the render-rate
# rig pass in _process via this flag rather than run here. The marker dirty-flag
# there cannot see a blend change on its own: the tilt moves the hosel tip the
# shaft is aimed at without moving any marker. The rebuild must be the FULL
# stick pass, not just the tilt — if the shaft doesn't follow the hosel, the
# joint opens.
func _update_blade_elevation(delta: float) -> void:
	var target: float = float(elevation_level) / float(ShotMechanics.ELEVATION_HIGH)
	if is_equal_approx(_blade_elevation_blend, target):
		return
	_blade_elevation_blend = move_toward(
			_blade_elevation_blend, target, _BLADE_ELEVATION_BLEND_SPEED * delta)
	_blade_tilt_dirty = true


# Blend units/sec for the blade-lift ease (~0.08 s for a full lift). Snappier
# than the elevation blend — a stick lift is a deliberate, quick action.
const _BLADE_LIFT_BLEND_SPEED: float = 12.0
# Ease rate for the commit-stance stick raise (units/sec). A touch slower than the
# blade lift so the stick "loads up" into the check rather than snapping.
const _COMMIT_LIFT_BLEND_SPEED: float = 9.0
# Ease rate for the shoulder lead. Slower than the stick raise: the arm can snap
# up, but a shoulder driven forward is the body's whole mass moving, and this
# rate is also what a mid-approach change of lead side crosses zero at.
const _CHECK_LEAD_SPEED: float = 5.0


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


# Eases the two commit-stance channels toward an empty-handed check commit
# ("delivering"): the stick rises off the ice, and the shoulder on the lead side
# loads up. A carrier holding the button to BRACE gets neither (delivering is
# false while carrying) — bracing is squaring up, not throwing a shoulder, and
# it must never lift a puck off its own blade. Called from _physics_process
# alongside _update_blade_lift: the lead feeds the loaded blade position, which
# goes on the wire, so it cannot ride the render clock.
func _update_commit_stance(delta: float) -> void:
	var delivering: bool = hit_committed \
			and not SkaterStateMachine.state_has_puck(current_shot_state)
	var target: float = 1.0 if delivering else 0.0
	_commit_lift_blend = move_toward(
			_commit_lift_blend, target, _COMMIT_LIFT_BLEND_SPEED * delta)
	var lead: float = 0.0
	if delivering:
		var body: Basis = global_transform.basis
		lead = CheckStanceRules.lead_target(move_intent,
				Vector2(body.x.x, body.x.z),
				-1.0 if is_left_handed else 1.0)
	_check_lead = move_toward(_check_lead, lead, _CHECK_LEAD_SPEED * delta)


# Eased 0→1 commit-stance stick-raise factor consumed by
# SkaterIKCoordinator.blade_y_local().
func get_commit_lift_blend() -> float:
	return _commit_lift_blend


func get_check_lead() -> float:
	return _check_lead


# How far down the shaft the top hand has slid, in metres — a real choke-up, and
# zero outside a check commit.
#
# The commit stance poses the hand and derives the blade one stick along the
# loaded bearing (SkaterIKCoordinator._commit_hand_pose), so this is what decides
# how far out that blade lands: a shorter lever holds it in tighter, which is why
# a player pulling a stick in chokes up on it in the first place. The shaft stays
# rigid — SkaterStickRig gives back out of the butt whatever the grip takes.
func grip_choke() -> float:
	return _commit_lift_blend * commit_grip_choke_m


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
	_blade_contact_dirty = true
	rotation.y = atan2(-_facing.x, -_facing.y)


func set_lower_body_lag(angle: float) -> void:
	lower_body.rotation.y = angle


func get_facing() -> Vector2:
	return _facing


# ── Leg rig (delegate to SkaterLegRig) ────────────────────────────────────────

func set_leg_swing(left_pitch: float, left_roll: float, left_knee: float,
		right_pitch: float, right_roll: float, right_knee: float,
		left_yaw: float = 0.0, right_yaw: float = 0.0) -> void:
	_legs.set_swing(left_pitch, left_roll, left_knee,
			right_pitch, right_roll, right_knee, left_yaw, right_yaw)


func apply_knockdown_leg_overlay(pose: KnockdownFallRules.SprawlPose,
		weight: float) -> void:
	_legs.apply_knockdown_overlay(pose, weight)


# ── Rendered pose seam (on-ice HUD, ice VFX) ─────────────────────────────────
# Where this skater is being DRAWN this frame. Anything placed onto the body at
# render rate — slot ring, chevrons, name plate, stamina gauge, slapper reticle —
# reads this rather than `global_transform`, the post-tick pose up to a tick of
# travel away.
#
# Memoized per drawn frame: several readers want it and their _process order is
# not fixed, so computing it on demand keeps them all on the SAME frame's pose.
var _render_xform: Transform3D = Transform3D.IDENTITY
var _render_xform_frame: int = -1


func render_transform() -> Transform3D:
	var frame: int = Engine.get_frames_drawn()
	if frame != _render_xform_frame:
		_render_xform_frame = frame
		_render_xform = get_global_transform_interpolated()
	return _render_xform


# ── Ice VFX seams (delegate to SkaterLegRig) ──────────────────────────────────

func blade_mark_position(left: bool) -> Vector3:
	return _legs.mark_position(left)


func set_edge_loads(left: float, right: float) -> void:
	_legs.set_edge_loads(left, right)


func edge_load(left: bool) -> float:
	return _legs.edge_load(left)


func set_foot_eversion(left_roll: float, right_roll: float) -> void:
	_legs.set_foot_eversion(left_roll, right_roll)


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
	_blade_contact_dirty = true
	upper_body.position.y = _default_upper_body_y + _skeleton_root_offset \
			- _skating_crouch_drop
	lower_body.position.y = _default_lower_body_y + _skeleton_root_offset \
			- _skating_crouch_drop


# ── Blade ─────────────────────────────────────────────────────────────────────
func set_blade_position(pos: Vector3) -> void:
	_blade_contact_dirty = true
	blade.position = pos
	var blade_world: Vector3 = upper_body.to_global(pos)
	var hand_world: Vector3 = upper_body.to_global(top_hand.position)
	var shaft_horiz: Vector3 = blade_world - hand_world
	shaft_horiz.y = 0.0
	if shaft_horiz.length() > 0.001:
		blade.look_at(blade_world + shaft_horiz.normalized(), Vector3.UP)


func get_blade_position() -> Vector3:
	return blade.position


# Memo for get_blade_contact_global(), which resolves the UpperBody→Blade
# transform chain and is read up to 3x per skater per tick across the
# interaction loops (plus IK, claims, and render-rate aim readers). The cached
# point is served while (a) no pose setter that can move the blade's world
# contact has run since the fill — set_blade_position, set_facing,
# set_upper_body_rotation / lean, _apply_body_height, and the visual_offset
# MeshRoot shift all raise _blade_contact_dirty — and (b) the body hasn't
# translated, guarded by comparing local `position` against the fill-time value
# (catches every direct global_position write: integration, collision push-out,
# clamps, reconcile snaps, teleports — none of which route through a setter
# here). An unchanged position with no setter call means an unchanged pose, so
# the memo is exact, not merely per-tick.
var _blade_contact_cache: Vector3 = Vector3.ZERO
var _blade_contact_cache_at: Vector3 = Vector3.INF
var _blade_contact_dirty: bool = true


# World position where the puck plays on the blade — mid-blade by default.
func get_blade_contact_global() -> Vector3:
	if not _blade_contact_dirty and position == _blade_contact_cache_at:
		return _blade_contact_cache
	var heel_world: Vector3 = upper_body.to_global(blade.position)
	var forward: Vector3 = -blade.global_transform.basis.z
	forward.y = 0.0
	var contact: Vector3 = heel_world
	if forward.length() >= 0.001:
		contact = heel_world + forward.normalized() * (blade_length * 0.5)
	_blade_contact_cache = contact
	_blade_contact_cache_at = position
	_blade_contact_dirty = false
	return contact


# Smoothed rendered factor in [−1, +1]. Discrete _carry_side is sticky
# (never centered while carrying); this lerps toward it so flips animate
# through center over carry_side_lerp_speed instead of teleporting.
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


# 0→1→0 envelope of the current transit hop — the blade rising over the puck
# while the pushing face flips to the other side. sin over the linear phase
# peaks mid-hop and lands at zero on both ends, so hops never pop; consumed by
# the transit-lift block in SkaterIKCoordinator.apply_blade_from_mouse.
func get_carry_transit_factor() -> float:
	return sin(PI * _transit_hop)


# Push the wrister's live aim line onto the skater — called every WRISTER_AIM
# tick by SkaterController._apply_wrister_aim_blade with _wrister_aim_dir's
# answer (origin→cursor for humans, the committed direction for bots). The
# address pass in _update_carry_contact consumes it so the wound-up blade
# visibly addresses the side of the still puck the shot will push from: a
# carrier who froze on the backhand and then aims a forehand sees the blade
# hop over the puck onto the shot line's trailing side. Runs on the owning
# client and on the host (which drives remote skaters from input), so every
# simulating peer shows it; render-only remotes never receive the push and
# keep the frozen entry pose (valid stays false).
func set_wrister_address(aim_dir: Vector3) -> void:
	_wrister_address_dir = aim_dir
	_wrister_address_valid = true


# The replicated form of the push, for client-rendered remotes: the committed
# side arrives off the wire (SkaterNetworkState.wrister_address_side, computed
# by the host running this same model) instead of being derived from an aim
# line the client doesn't have. Stages the side; _update_wrister_address
# adopts it, so the hop-on-crossing detection lives in one place for both
# sources. Caller gates on shot_state == WRISTER_AIM — the wire value is
# garbage outside it.
func set_wrister_address_side(side: int) -> void:
	_wrister_address_target_side = side
	_wrister_address_dir = Vector3.ZERO
	_wrister_address_valid = true


# The committed address side for the wire (±1; 0 before the first aim tick
# seeds it, which fill_network_state maps to the forehand bit state).
func get_wrister_address_side() -> int:
	return _wrister_address_side


# The stickhandling push model (docs/stickhandling-push-model-plan.md): the
# blade renders on the side of the puck it is PUSHING from — the side opposite
# the puck's motion in the carrier's frame — and an inward pull plays the
# toe-drag / heel-cradle grammar, because no blade face points back at the
# carrier: pulling requires hooking the toe over the puck.
#
# Keyed off blade_world_velocity − velocity, both derived on every peer from
# the replicated pose, so this runs identically for local, AI, and remote
# skaters (called from _physics_process, not the IK pipeline) and remote views
# read the same strokes with no wire field. The velocity is one tick stale
# relative to the pose being placed this tick — invisible under the gesture
# ease. Live-only, never replayed: pure cosmetic smoothing memory, absorbed
# across reconcile snaps like every other blend here.
func _update_carry_contact(delta: float) -> void:
	var drag_target: float = 0.0
	var cradle_target: float = 0.0
	var stroke_toe_target: float = 0.0
	if not SkaterStateMachine.state_has_puck(current_shot_state):
		_carry_side = 0
	else:
		var stick: Vector3 = get_blade_contact_global() - top_hand.global_position
		stick.y = 0.0
		if stick.length_squared() > 0.000001:
			stick = stick.normalized()
			# Same axes get_carry_target_global offsets along, so the stroke
			# read and the rendered offset can never disagree on direction.
			var face_normal := Vector3(-stick.z, 0.0, stick.x)
			var v_rel: Vector3 = blade_world_velocity - velocity
			var v_perp: float = v_rel.dot(face_normal)
			var v_in: float = -v_rel.dot(stick)
			# Two handedness signs, matching the pair the old position key used:
			# factor space (get_carry_forehand_factor's mirror) converts the
			# stroke solver's geometric side to/from forehand-normalized
			# storage; position space normalizes body-local X so positive is
			# the blade's natural side.
			var factor_hs: int = 1 if is_left_handed else -1
			var pos_hs: float = -1.0 if is_left_handed else 1.0
			var body_x_norm: float = blade.position.x * pos_hs
			if _carry_side == 0:
				# First carry tick: no stroke yet — cradle on the body side the
				# puck was picked up on (forehand if exactly centered).
				_carry_side = -1 if body_x_norm < 0.0 else 1
			else:
				var sign_now: int = _carry_side * factor_hs
				var sign_new: int = CarryContactRules.stroke_side(
						sign_now, v_perp, carry_flip_speed)
				if sign_new != sign_now:
					_carry_side = sign_new * factor_hs
					# One hop per flip; a flip during a live hop rides it out,
					# so a fast dangle bounces per stroke instead of hovering.
					if _transit_hop <= 0.0:
						_transit_hop = 1.0
			var pull: float = CarryContactRules.pull_gesture(
					v_in, carry_pull_ramp_min, carry_pull_ramp_max)
			var forehand_w: float = CarryContactRules.forehand_weight(
					body_x_norm, carry_diagonal_band)
			drag_target = pull * forehand_w
			cradle_target = pull * (1.0 - forehand_w)
			# Stroke-speed toe ride: a hard lateral push rolls the puck out
			# along the curve toward the toe. Ramps in above the flip
			# threshold so a cradle stays seated; because flips only fire
			# mid-stroke, every release leaves off the toe by construction.
			stroke_toe_target = CarryContactRules.pull_gesture(
					absf(v_perp), carry_flip_speed, carry_stroke_full_speed)
	_carry_side_smoothed = lerpf(
			_carry_side_smoothed, float(_carry_side), carry_side_lerp_speed * delta)
	var hop_was_live: bool = _transit_hop > 0.0
	_transit_hop = maxf(_transit_hop - delta / carry_transit_hop_time, 0.0)
	if hop_was_live and _transit_hop <= 0.0 \
			and SkaterStateMachine.state_has_puck(current_shot_state):
		# The hop just landed on the far face: the catch. Heel-first, rolling
		# back to the carry seat as the blend decays.
		_catch_heel_blend = 1.0
	var new_drag: float = move_toward(_toe_drag_gesture, drag_target, carry_gesture_ease * delta)
	var new_cradle: float = move_toward(_heel_cradle, cradle_target, carry_gesture_ease * delta)
	var new_stroke: float = move_toward(
			_stroke_toe_blend, stroke_toe_target, carry_gesture_ease * delta)
	var new_catch: float = move_toward(_catch_heel_blend, 0.0, carry_catch_decay * delta)
	var new_give: float = move_toward(
			_reception_give_blend, 0.0, reception_give_decay * delta)
	var aim_seat_target: float = 1.0 \
			if current_shot_state == SkaterStateMachine.State.WRISTER_AIM else 0.0
	var new_aim_seat: float = move_toward(
			_aim_seat_blend, aim_seat_target, carry_gesture_ease * delta)
	if new_drag != _toe_drag_gesture or new_cradle != _heel_cradle \
			or new_stroke != _stroke_toe_blend or new_catch != _catch_heel_blend \
			or new_give != _reception_give_blend or new_aim_seat != _aim_seat_blend:
		# The gesture factors tilt/slide the blade mesh without moving any
		# marker, so the render-rate rig pass can't see the change — same
		# escape as _update_blade_elevation.
		_blade_tilt_dirty = true
	_toe_drag_gesture = new_drag
	_heel_cradle = new_cradle
	_stroke_toe_blend = new_stroke
	_catch_heel_blend = new_catch
	_reception_give_blend = new_give
	_aim_seat_blend = new_aim_seat
	_update_wrister_address(delta)


# The attach-instant cushion: the puck's arrival momentum visibly knocks the
# blade back along its line of travel, then the hands re-seat it (the decay in
# _update_carry_contact). `relative_velocity` is puck − receiver at contact —
# the same frame the receive decision judges. Cosmetic and per-machine: every
# peer fires it from its own attach event (host detection / lag-comp grant,
# client pickup notifies), so it needs no wire field and never replays.
# Skipped while slapshot-pinning: a one-timer feed lands under a raised,
# wound-up stick, and pins to the slapper zone rather than the blade — there
# is no blade-on-puck catch to cushion.
func trigger_reception_cushion(relative_velocity: Vector3) -> void:
	if blade == null or is_slapshot_pinning() or reception_give_full_speed <= 0.0:
		return
	var horiz := Vector3(relative_velocity.x, 0.0, relative_velocity.z)
	var speed: float = horiz.length()
	if speed < 0.001:
		return
	var t: float = clampf(speed / reception_give_full_speed, 0.0, 1.0)
	var amp: float = t * t
	if amp <= _reception_give_blend:
		return  # a live, larger cushion is still playing out
	var local_dir: Vector3 = blade.global_transform.basis.inverse() * (horiz / speed)
	local_dir.y = 0.0
	if local_dir.length_squared() < 0.000001:
		return
	_reception_give_dir = local_dir.normalized()
	_reception_give_blend = amp
	_blade_tilt_dirty = true


# The wrister-address pass: while the blade is frozen in a wrister aim, the
# visible blade addresses the side of the still puck the shot will push from —
# the push model applied to the shot line. The trailing side of D (origin→
# cursor) in face-normal space is −sign(D·N), which is exactly the stroke rule,
# so CarryContactRules.stroke_side decides it with the aim-line dot as the
# stroke and the commit threshold as the hysteresis (a near-parallel aim, D
# almost along the stick, holds the current side instead of flickering). The
# delta between the eased address factor and the live carry factor slides the
# blade MESH along the face-normal axis in _apply_blade_tilt; the marker, pin,
# release spawn, and aim line are untouched, so the fix is visually complete
# and gameplay-inert. Geometric and handedness-free: the address tracks where
# the aim actually is, so it cannot land on the wrong side of the puck.
#
# On aim exit the address becomes the real carry side (the arrangement the
# player last saw), so the mesh offset collapses to zero with no pop and the
# post-release ease starts from the addressed pose.
func _update_wrister_address(delta: float) -> void:
	var in_aim: bool = current_shot_state == SkaterStateMachine.State.WRISTER_AIM \
			and _wrister_address_valid
	if not in_aim:
		if _wrister_address_valid:
			# Just left the aim: adopt the addressed arrangement as the carry side.
			_wrister_address_valid = false
			var factor_hs: float = 1.0 if is_left_handed else -1.0
			_carry_side_smoothed = _address_factor * factor_hs
			if _carry_side != 0:
				_carry_side = -1 if _carry_side_smoothed < 0.0 else 1
		_address_factor = get_carry_forehand_factor()
		_wrister_address_side = 0
		_wrister_address_target_side = 0
		return
	var prev_side: int = _wrister_address_side
	var aim: Vector3 = _wrister_address_dir
	aim.y = 0.0
	var stick: Vector3 = get_blade_contact_global() - top_hand.global_position
	stick.y = 0.0
	if aim.length_squared() > 0.000001 and stick.length_squared() > 0.000001:
		# Simulating peer: derive the side from the aim line.
		aim = aim.normalized()
		stick = stick.normalized()
		var face_normal := Vector3(-stick.z, 0.0, stick.x)
		var seed: int = _wrister_address_side
		if seed == 0:
			# Seed from the entry arrangement so an aim that already trails
			# the blade re-addresses nothing.
			seed = -1 if _address_factor < 0.0 else 1
		_wrister_address_side = CarryContactRules.stroke_side(
				seed, aim.dot(face_normal), wrister_address_commit_dot)
	elif _wrister_address_target_side != 0:
		# Render-only remote: adopt the host's committed side off the wire.
		_wrister_address_side = _wrister_address_target_side
	# The crossing fires the same one-per-flip transit hop as a stroke —
	# against the previous committed side, or on the first commit against the
	# entry arrangement (committing LMB onto the other face).
	var reference: int = prev_side
	if reference == 0 and absf(_address_factor) > 0.0001:
		reference = -1 if _address_factor < 0.0 else 1
	if reference != 0 and _wrister_address_side != 0 \
			and _wrister_address_side != reference:
		if _transit_hop <= 0.0:
			_transit_hop = 1.0
	var new_addr: float = _address_factor
	if _wrister_address_side != 0:
		new_addr = move_toward(
				_address_factor, float(_wrister_address_side), carry_side_lerp_speed * delta)
	if new_addr != _address_factor:
		_blade_tilt_dirty = true  # the mesh offset moves without any marker
	_address_factor = new_addr


# Where along the blade the WOUND-UP puck sits, as a signed offset from
# mid-blade in fractions of blade_length — the contact-point tell, told the
# way every other tell here is told: the BLADE slides around the still puck
# (mesh channel, _apply_blade_tilt), never the puck off the cursor. Scoped to
# the wrister wind-up (_aim_seat_blend eases it in and out of WRISTER_AIM):
# that is where the read matters — the goalie/defender studying a committed
# shooter — and a plain carry keeps the puck exactly at the cursor with a
# mid-blade seat, so stickhandling never fights the mouse binding. Eased
# through _blade_elevation_blend, so a level switch slides the blade along
# the puck instead of teleporting — that ease is the deception window, since
# the read lands a beat after the commit.
func _aim_seat_offset_u() -> float:
	return (lerpf(carry_contact_flat_u, carry_contact_high_u, _blade_elevation_blend) - 0.5) \
			* _aim_seat_blend


# Correction the controller's per-tick net collision applies to the raw pin, so
# the carried puck is HELD at the twine instead of being allowed inside it. Zero
# whenever the pin is clear (the overwhelmingly common case). Written every
# simulated tick from deterministic inputs, so it replays; not cross-tick state.
var carry_pin_correction: Vector3 = Vector3.ZERO

# The pin as the blade defines it, before the net has its say. Only the
# controller's net collision wants this — everything else wants the resolved
# position below.
func get_carry_target_raw() -> Vector3:
	return _carry_target_raw()


func get_carry_target_global() -> Vector3:
	return _carry_target_raw() + carry_pin_correction


# Where the puck pins while carrying: contact − face_normal × forehand_factor ×
# carry_blade_offset. The blade MARKER is shifted to the forehand/backhand side
# by the IK target, so the stick visibly attaches to the offset blade while the
# puck sits at the un-offset position, where the cursor effectively is. All the
# heel→toe contact storytelling (elevation seat, stroke prosody, catches) lives
# on the blade MESH instead (_apply_blade_tilt), so this pin never drifts off the
# cursor. Falls back to get_blade_contact_global() (centered) when not carrying
# or when the geometry is degenerate.
#
# Slapshot wind-up override: while slapshot pinning is active the puck holds at a
# fixed lateral/forward offset from the player (matched to the one-timer slapper
# zone) rather than following the blade, which is lifted overhead and pulled back
# over the shoulder during the coil. That keeps the puck on the ice in front of
# the skater — so they can coast or brake through the wind-up without leaving it
# behind — and fires the shot from a sane ice position, not the elevated tip.
func _carry_target_raw() -> Vector3:
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


# ── Faceoff draw tracking (delegate to SkaterDrawTracker) ────────────────────

func begin_draw_tracking(peak_decay: float, valid_window_s: float) -> void:
	_draw.begin(peak_decay, valid_window_s)


func set_draw_input_time(host_time: float) -> void:
	_draw.set_input_time(host_time)


func mark_draw_drop(host_time: float) -> void:
	_draw.mark_drop(host_time)


func end_draw_tracking() -> void:
	_draw.end()


func is_draw_tracking() -> bool:
	return _draw.is_tracking()


func draw_peak_velocity() -> Vector3:
	return _draw.peak_velocity()


func draw_since_drop() -> float:
	return _draw.since_drop()


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


func set_upper_body_rotation(angle: float) -> void:
	_blade_contact_dirty = true
	upper_body.rotation.y = angle


func set_upper_body_lean(lean_x: float, lean_z: float = 0.0) -> void:
	_blade_contact_dirty = true
	upper_body.rotation.x = lean_x
	upper_body.rotation.z = lean_z


func set_lower_body_lean(lean_x: float, lean_z: float) -> void:
	lower_body.rotation.x = lean_x
	lower_body.rotation.z = lean_z


# ── Knockdown Fall ────────────────────────────────────────────────────────────
# Whole-rig tilt of the knockdown fall: rotates MeshRoot about its own origin —
# the ice-level point between the skates — so the body tips like a felled tree
# while the gameplay body (collider, slide, capsule position) stays upright
# underneath. `axis` is the horizontal rotation axis in body-local space
# (perpendicular to the fall direction), `tilt` in radians. MeshRoot's basis has
# exactly this one writer (visual_offset owns its position), so the write is
# absolute; the zero↔zero early-out keeps the upright hot path free.
var _knockdown_fall_tilt: float = 0.0


func set_knockdown_fall(axis: Vector3, tilt: float) -> void:
	if tilt == 0.0 and _knockdown_fall_tilt == 0.0:
		return
	_knockdown_fall_tilt = tilt
	# MeshRoot is an ancestor of the Blade marker — the contact memo must not
	# serve a pre-tilt point (same rule as the visual_offset write).
	_blade_contact_dirty = true
	if tilt == 0.0 or axis.length_squared() < 0.000001:
		mesh_root.basis = Basis.IDENTITY
		return
	mesh_root.basis = Basis(axis.normalized(), tilt)


# Head yaw, onto the helmet bone. The write owns Y only; the rig's captured
# helmet euler carries the scene's authored X/Z into the composed basis.
func set_head_angle(angle: float) -> void:
	_arms.set_head_angle(angle)


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


# ── Stick rig (delegate to SkaterStickRig) ────────────────────────────────────

# The hosel tip the shaft aims at rides the blade's cosmetic pitch, so the tilt
# is applied here rather than inside the rig: the tilt is the blade's, and the
# blade is this node's.
func update_stick_mesh() -> void:
	_apply_blade_tilt()
	# The blade's procedural mesh carries that tilt, and the rig's hosel-tip
	# solve rides it — so it is handed over rather than reached for.
	_stick.update_mesh(_blade_mesh_instance)



# ── Leg sizing seam (delegate to SkaterLegRig) ────────────────────────────────

func set_leg_bone_scale(bone: int, part_scale: Vector3) -> void:
	_legs.set_bone_scale(bone, part_scale)


func set_leg_bone_position(bone: int, pos: Vector3) -> void:
	_legs.set_bone_position(bone, pos)


func leg_bone_euler(bone: int) -> Vector3:
	return _legs.bone_euler(bone)


func leg_bone_position(bone: int) -> Vector3:
	return _legs.bone_position(bone)


func leg_bone_base_scale(bone: int) -> Vector3:
	return _legs.bone_base_scale(bone)


func leg_bone_base_position(bone: int) -> Vector3:
	return _legs.bone_base_position(bone)


func leg_surface_material(surface: int) -> StandardMaterial3D:
	return _legs.surface_material(surface)


func set_leg_surface_material(surface: int, mat: Material) -> void:
	_legs.set_surface_material(surface, mat)


# ── Arm rig (delegate to SkaterArmRig) ────────────────────────────────────────

func update_arm_mesh() -> void:
	_arms.update_top_arm()


func update_bottom_arm_mesh() -> void:
	_arms.update_bottom_arm()


func set_trunk_texture(pitch_add: float, roll_add: float) -> void:
	_arms.set_trunk_texture(pitch_add, roll_add)


func upper_surface_material(surface: int) -> StandardMaterial3D:
	return _arms.surface_material(surface)


func set_upper_surface_material(surface: int, mat: Material) -> void:
	_arms.set_surface_material(surface, mat)


func set_upper_bone_scale(bone: int, part_scale: Vector3) -> void:
	_arms.set_bone_scale(bone, part_scale)


func set_upper_bone_position(bone: int, pos: Vector3) -> void:
	_arms.set_bone_position(bone, pos)


func upper_bone_base_scale(bone: int) -> Vector3:
	return _arms.bone_base_scale(bone)


func upper_bone_base_position(bone: int) -> Vector3:
	return _arms.bone_base_position(bone)


func set_arm_bone_radius(part: int, radius: float) -> void:
	_arms.set_bone_radius(part, radius)


func set_arm_ball_radius(part: int, radius: float) -> void:
	_arms.set_ball_radius(part, radius)


func set_arm_cuff_radius(part: int, radius: float) -> void:
	_arms.set_cuff_radius(part, radius)


func arm_ball_radius(part: int) -> float:
	return _arms.ball_radius(part)



# ── Coordinate Helpers ────────────────────────────────────────────────────────
func upper_body_to_global(local_pos: Vector3) -> Vector3:
	return upper_body.to_global(local_pos)


func upper_body_to_local(world_pos: Vector3) -> Vector3:
	return upper_body.to_local(world_pos)


# ── Ghost Mode ────────────────────────────────────────────────────────────────
# A ghost (offside / icing / crease-dwell) has no interactive presence: every
# path that could touch it gates on is_ghost — skater-vs-skater in
# _resolve_player_collisions, the goalie clamp, and the puck's pickup/contest
# scans — so this only has to flip the flag and repaint. is_ghost replicates
# (SkaterNetworkState), so every machine drops the same skater out of play.
func set_ghost(ghost: bool) -> void:
	if is_ghost == ghost:
		return
	is_ghost = ghost
	_uniform.apply_ghost(ghost)
	_hud.apply_ghost(ghost)


# ── Shot-Block Stance ─────────────────────────────────────────────────────────
# The block's BODY pose (the one-knee drop) is the gait's, off the replicated
# shot state; this flag is the collision half — it widens the body-block cylinder
# below. Taking the blade OUT of puck play is handled by the SHOT_BLOCKING gates
# on the analytic paths themselves: PuckController's corral and contest scans,
# PickupClaimResolver, LocalController's provisional pickup.
func set_block_stance(active: bool) -> void:
	_block_stance_active = active


# The body-block CYLINDER the analytic detector tests against (PuckController) — a vertical
# cylinder at the skater's XZ axis matching the torso. PASSIVE: radius body_block_radius over a
# torso band raised off the ice, so a grounded puck slides UNDER (a flat shot passes clean).
# SHOT-BLOCK: the wider block_body_radius, banded from the ice up to block_seal_height so a
# low shot is sealed. Both dimensions are the one-knee pose's — the leg extended along the
# ice on one side and the stick flat on the other earn the width; the kneeling head caps the
# height, so beating a committed blocker means going OVER him. Reach is uniform
# across the band.
func get_body_block_radius() -> float:
	return block_body_radius if _block_stance_active else body_block_radius


# World-Y extent [bottom, top] of the body-block cylinder.
func get_body_block_y_range() -> Vector2:
	if _block_stance_active:
		# Seal the ice up through the kneeling body (a committed block stops a
		# flat shot; over the top of him it goes through).
		return Vector2(0.0, block_seal_height)
	# Torso band centred at body_block_height, raised off the ice so a grounded puck passes under.
	var center_y: float = global_position.y + body_block_height
	return Vector2(center_y - body_block_radius, center_y + body_block_radius)


# ── Slapper Zone ──────────────────────────────────────────────────────────────
# Arms the one-timer catch zone: a disc of `radius` centered `offset_x` to the
# blade side and `offset_z` ahead, in skater-local space. Disarming keeps the last
# geometry — every caller gates on is_slapper_zone_active() first.
func set_slapper_zone(active: bool, radius: float = 0.0, offset_x: float = 0.0, offset_z: float = 0.0) -> void:
	if active and radius > 0.0:
		_slapper_zone_radius = radius
		var blade_side_sign: float = -1.0 if is_left_handed else 1.0
		_slapper_zone_offset = Vector3(blade_side_sign * offset_x, 0.0, offset_z)
	_slapper_zone_active = active


func get_slapper_zone_global_position() -> Vector3:
	var world: Vector3 = to_global(_slapper_zone_offset)
	world.y = 0.0
	return world


func set_uniform(colors: Dictionary) -> void:
	_uniform.apply_uniform(colors)


# Sets the back-of-jersey name and number; text colors come from the cached
# uniform (last set_uniform call).
func set_jersey_info(p_name: String, number: int) -> void:
	_uniform.apply_jersey_info(p_name, number)


# ── On-ice ring (read by IceRingField, drawn by the ice shader) ───────────────
# The slot ring is not a node on this skater any more; the ice shader draws it
# from a uniform array. These are the two facts the field needs per frame.
func ring_field_visible() -> bool:
	return _hud.ring_visible()


func ring_field_color() -> Color:
	return _hud.ring_color()


func chevron_field_stack() -> int:
	return _hud.chevron_stack()


func chevron_field_apex() -> Vector2:
	return _hud.chevron_apex()


# ── Stamina gauge (read by IceRingField, drawn by the ice shader) ────────────
func stamina_field_visible() -> bool:
	return _hud.stamina_gauge_visible()


func stamina_field_fill() -> float:
	return _hud.stamina_gauge_fill()


func stamina_field_color() -> Color:
	return _hud.stamina_gauge_color()


func stamina_field_up() -> Vector2:
	return _hud.stamina_gauge_up()


func stamina_field_center() -> Vector2:
	return _hud.stamina_gauge_center()


# ── Slapper indicator (read by IceRingField, drawn by the ice shader) ────────
func slapper_field_visible() -> bool:
	return _hud.slapper_visible()


func slapper_field_arrow_visible() -> bool:
	return _hud.slapper_arrow_visible()


func slapper_field_center() -> Vector2:
	return _hud.slapper_center()


func slapper_field_radius() -> float:
	return _hud.slapper_zone_radius()


func slapper_field_ring_scale() -> float:
	return _hud.slapper_ring_scale()


func slapper_field_arrow_dir() -> Vector2:
	return _hud.slapper_arrow_dir()


func hud_screen_down() -> Vector2:
	return _hud.screen_down()


# ── Name plate (billboarded Label3D on this skater) ──────────────────────────
func name_plate_visible() -> bool:
	return _hud.name_plate_visible()


# Repaints the skin to the player's identity tone. Albedo only, preserving the
# current alpha so a repaint landing mid-ghost doesn't snap the skin opaque.
# Head and neck are one SURFACE of the helmet mesh (they wear the same material),
# so there is a single paint target — and it goes through surface_override,
# because the default lives on the mesh every skater shares.
func set_skin_tone(index: int) -> void:
	var skin: Color = SkinToneRegistry.color_for(index)
	var mat: StandardMaterial3D = upper_surface_material(
			SkaterMeshBuilder.UpperSurface.HELMET_SKIN)
	mat.albedo_color = Color(skin.r, skin.g, skin.b, mat.albedo_color.a)


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
