class_name SkaterController
extends Node

# ── State Machine ─────────────────────────────────────────────────────────────
# Type alias so LocalController and RemoteController keep compiling without
# changes when they reference State.X values or use State as a type annotation.
const State = SkaterStateMachine.State
var _sm: SkaterStateMachine = SkaterStateMachine.new()

# ── Movement Tuning ───────────────────────────────────────────────────────────
@export var thrust: float = GameRules.DEFAULT_SKATER_THRUST_M_S2
@export var friction: float = 0.8
@export var friction_drag: float = 0.27
@export var max_speed: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
@export var move_deadzone: float = 0.1
@export var brake_multiplier: float = 4.0
# Lateral grip — perpendicular-to-motion thrust authority (the edges' bite in a
# cut; see SkaterMovementRules.MovementConfig.lateral_grip). 1.0 = the shipped
# neutral feel; per-build value = base × agility_mult in apply_attributes, and
# the skate-profile gear slot leans it later. Turn radius at speed rides this.
@export var lateral_grip: float = 1.0
@export var puck_carry_speed_multiplier: float = 0.92  # pre-apply default; per-build value is set by apply_attributes (PlayerAttributes.carry_speed_mult, Speed-eased)
@export var backward_thrust_multiplier: float = 0.80
@export var crossover_thrust_multiplier: float = 0.90
# Ceiling on the velocity fed to the gait during the faceoff / intro skate-in
# (see begin_approach / apply_approach). The glide always completes in a fixed
# duration, so a far start implies a high velocity — clamp it here so the stride
# animation reads as a hard skate rather than over-spinning past its range.
@export var approach_max_gait_speed: float = 9.0
# ── Sprint / Stamina Tuning ───────────────────────────────────────────────────
# Sprint (Shift) burns a stamina pool for a top-speed burst. Boost is primarily
# the speed cap; a smaller thrust bump lets you actually reach it. Stamina is a
# 0..1 fraction; drain/regen are fractions-per-second.
# sprint_max_speed_multiplier is now OVERWRITTEN per-build by apply_attributes
# (PlayerAttributes.sprint_ceiling_mult) so the sprint CEILING is Speed-attributed
# and grounded to the 20–25 mph NHL burst band — a burner opens a gear a plodder
# doesn't have. This @export is just the pre-apply default (a neutral build).
@export var sprint_max_speed_multiplier: float = 1.14
# Fraction of the puck-carry speed penalty waived WHILE sprinting — heads-down,
# straight-line, flat-out. Lets a fast carrier separate; the real carry cost is
# the sprint stamina drain below, not an intrinsic slowdown.
@export var sprint_carry_penalty_bypass: float = 0.6
@export var sprint_thrust_multiplier: float = 1.20
@export var sprint_drain_per_sec: float = 0.45         # ~2.2s of full sprint off-puck
@export var sprint_carry_drain_multiplier: float = 1.6 # carrying drains faster (~1.4s)
@export var stamina_regen_per_sec: float = 0.25        # baseline (medium Physical): ~4s to refill, ~2s to the 0.5 sprint-unlock
@export var sprint_unlock_fraction: float = 0.5        # exhausted → recover to here before sprinting again
# Turn-rate scale while sprinting (< 1.0 = wider, lazier turns). This is the
# tradeoff that makes sprint a decision rather than a hold-always button:
# committed straight-line speed at the cost of agility, mirroring the
# hustle/turn-radius coupling in sim hockey games. Scales facing_drag_speed in
# SkaterPoseCoordinator.apply_facing. Deterministic from sprint_active, so it
# re-derives identically through reconcile replay (no new wire state).
@export var sprint_turn_multiplier: float = 0.55
# ── Hit-Button (Body-Check Commit) Tuning ─────────────────────────────────────
# The hit button (Ctrl / input.hit_held) commits a check: it delivers the full
# body-check transfer (see Skater.hit_passive_transfer_mult for the uncommitted
# floor), and pays for it with a stamina drain on the shared sprint pool PLUS the
# commitment of pulling the stick off the ice — while committed you can't poke,
# receive a pass, or corral a loose puck (gated in PuckController/PickupClaim on
# the replicated skater.hit_committed). So a big hit is a committed read (line them
# up, spend stamina, give up puck play), not a free bump. Deterministic from the
# replicated input.hit_held, so every cost re-derives through reconcile replay.
@export var hit_stamina_drain_per_sec: float = 0.5    # drained while committing a check
# Turn-rate scale while committing (< 1.0 = wider turns). Now 1.0 (no penalty): the
# commitment cost moved entirely onto the withdrawn stick above, so you can steer
# freely to line up the hit — the old penalty punished the ATTEMPT (tracking a
# mover) rather than the miss, which is backwards. Full-speed homing is still
# bounded because sprinting in for max closing pays sprint's own turn radius
# (sprint_turn_multiplier). Dial below 1.0 if committed checks feel too sticky.
@export var hit_turn_multiplier: float = 1.0
# Commit stance (cosmetic): while the Hit button is held the skater visibly loads
# up for the check — leans into it, drops the leading shoulder, sinks into a
# crouch, and (empty-handed only) pulls the stick up off the ice. A render-rate
# trunk blend (SkaterSkatingCoordinator) off the replicated skater.hit_committed
# plus a stick raise driven through the IK's blade_y (gameplay-inert while
# committed), so it reads on every machine and never affects puck play. Deliberately
# pronounced — the stance has to be unmistakable so the commitment (and the withdrawn
# stick) is legible to the player and their opponent. Eases in/out as Ctrl is held.
@export var hit_commit_lean_deg: float = 24.0         # forward trunk lean into the check
@export var hit_commit_shoulder_deg: float = 19.0     # leading-shoulder drop (roll)
@export var hit_commit_crouch_m: float = 0.12         # sink into the checking stance
@export var hit_commit_blade_lift_m: float = 0.22     # stick raise off the ice on an empty-handed commit
# Loaded blade pose: while committing (empty-handed), the blade STOPS chasing the
# cursor and eases to a fixed body-local "ready to hit" position — stick up (the
# lift above) and held in front, so the stance snaps to a distinct silhouette
# instead of a raised-but-still-tracking stick. Body-local XZ: +x is the forehand
# side (× blade_side_sign), −z is in front of the skater (see _blade_relative_angle
# bearing math). Gameplay-inert — the blade is withdrawn from puck play while
# committed, so this is a pure cosmetic override that eases back to cursor tracking
# on release. Feel dials; verify the silhouette in-game.
@export var hit_commit_blade_local_x: float = 0.10    # forehand-side offset of the loaded blade
@export var hit_commit_blade_local_z: float = -0.34   # how far in FRONT the loaded blade sits (−z = ahead)
@export var hit_commit_pose_speed: float = 9.0        # how fast the stance eases in/out
# ── Body-Check Stagger Tuning ─────────────────────────────────────────────────
# Getting checked hard staggers the victim: a temporary thrust penalty plus a
# stamina bite, both scaled by how hard the hit landed (the m/s transfer impulse).
# stagger_timer (seconds) holds the recovery window AND drives the penalty depth —
# a harder hit sets a longer timer, easing back to full thrust as it decays. Flat
# for every player in v1 (the hit strength already reflects the attacker's Size/
# Physical/Speed and the victim's mass). Pure math in BodyCheckRules; deterministic
# and replicated so it survives reconcile replay (same treatment as stamina).
# Grounded to the inelastic magnitudes: the delivered victim impulse is
# closing_speed × transfer × m_a/(m_a+m_b), so at a MEDIUM build (transfer 0.65,
# equal mass → ×0.5) it's ~0.325 × closing, and a heavier build (a touch more mass
# ratio) is higher still. The ref point is deliberately the SAME as the puck-strip
# threshold (Puck.body_check_strip_threshold, 1.35): a hit hard enough to count as
# a full check is exactly a hit hard enough to knock the puck loose. At the 0.65
# transfer that lands a full check + strip at ~4 m/s closing for a medium build
# (~3.4 for a heavy one) — "square them up and skate into them with some pace,"
# comfortably reachable. (The impulse breakpoints used to sit at closing speeds
# that were partly unreachable — a full check needed ~6 m/s and a knockdown ~13 —
# after the transfer and the attribute mass range drifted apart across reworks;
# the 0.65 transfer + the retuned knockdown band below re-anchor the whole ladder
# into the reachable 2–10 m/s closing range this fixes.)
# Speed still buys MORE than a full check: closing past the ref keeps scaling the
# impulse linearly into the knockdown band below, so a sprint / head-on collision
# is a bigger hit — a ceiling, not a requirement. Still feel tunables.
@export var stagger_min_impulse: float = 0.6       # m/s transfer delta below which a hit doesn't stagger
@export var stagger_ref_impulse: float = 1.35      # m/s transfer delta treated as a full-strength check (== puck-strip threshold)
@export var stagger_max_seconds: float = 1.0       # recovery window of a full-strength check
@export var stagger_max_stamina_drain: float = 0.35  # pool fraction a full-strength check bites
@export var stagger_max_thrust_penalty: float = 0.5  # peak thrust reduction at full stagger
# Cosmetic stumble while staggered: a decaying trunk wobble layered into the
# gait's trunk texture (SkaterSkatingCoordinator). Amplitude tracks the time
# left on stagger_timer, and the wobble phase is derived FROM the timer, so
# every machine renders the identical stumble from the replicated value.
@export var stagger_wobble_deg: float = 9.0   # peak trunk wobble at full stagger
@export var stagger_wobble_hz: float = 3.0    # wobble frequency
# Directional recoil: on top of the wobble, the whole torso reels the way the
# hit shoved it (pitch + roll), easing out as stagger_timer decays — a body
# absorbing the check, not just shaking. Direction is the transfer impulse
# (stagger_recoil_dir); remotes recoil generically backward (they get the timer
# off the wire, not the direction). Applied in SkaterPoseCoordinator._apply_lean.
@export var stagger_recoil_deg: float = 13.0  # peak torso recoil lean at full stagger
# ── Knockdown Tuning ──────────────────────────────────────────────────────────
# The top of the stagger continuum: a hit whose victim impulse exceeds
# knockdown_impulse KNOCKS THE VICTIM DOWN — movement locked, no puck interaction,
# the body slides from the hit and bleeds speed via knockdown_friction — for a
# recovery window scaling with the hit (see BodyCheckRules.knockdown_seconds_from_
# impulse). knockdown_timer rides the SAME replicated / snapped / decayed rail as
# stagger_timer. Deliberately kept ABOVE the full-check point (stagger_ref 1.35):
# a full check staggers + strips; a KNOCKDOWN is the reward for a genuinely SOLID
# hit — ~5.5 m/s closing at a medium build (~4.5 for a heavy one), the pace of a
# committed skate-in on a carrier, up to a maximal ~9.5 m/s head-on/sprint
# collision. It sits just above the AI's commit bar (AIBodyCheck.COMMIT_IMPULSE_M_S
# 1.6) so a committed bot check lands a hard stagger/strip and, at real closing,
# tips into a knockdown. (Was 3.0/5.0 — a band that needed ~13–22 m/s closing,
# above the top skater speed, so knockdowns were effectively unreachable; retuned
# so solid hits knock down as intended.) Set knockdown_impulse very high (or 0) to
# effectively disable knockdowns.
@export var knockdown_impulse: float = 1.8         # m/s victim impulse above which a hit knocks down
@export var knockdown_ref_impulse: float = 3.1     # m/s impulse of a maximal (longest) knockdown
@export var knockdown_min_seconds: float = 0.7     # down time of a just-barely knockdown
@export var knockdown_max_seconds: float = 1.5     # down time of a maximal hit
@export var knockdown_friction: float = 8.0        # m/s² the downed body sheds speed while sliding
# Knockdown pose (cosmetic): a downed player crumples — the body drops toward the
# ice, the legs go limp, and the torso reels hard in the hit direction (an
# amplified stagger recoil). All driven off the replicated knockdown_timer, so it
# renders identically on every machine and through reconcile, like the stagger
# stumble. knockdown_getup_seconds is the tail window over which the pose eases back
# up (the get-up) — the pose holds full while more than this much time remains.
@export var knockdown_pose_drop_m: float = 0.85    # how far the body sinks while down
@export var knockdown_fold_deg: float = 50.0       # peak torso reel (added onto the recoil) while down
@export var knockdown_getup_seconds: float = 0.4   # tail over which the down pose eases back up
# ── Facing Tuning ─────────────────────────────────────────────────────────────
# How fast facing drifts toward the cursor during normal play. Lower = more
# skating lag before the body re-orients (more backskate/crossover time).
# Good range: 1.0 (very lazy) – 3.0 (snappy).
@export var facing_drag_speed: float = 5.0
@export var facing_drag_speed_braking: float = 10.0

# ── Blade / Stick / Top-Hand IK Tuning ────────────────────────────────────────
# Blade world-space Y. 0.0 = ice surface. Converted to upper-body-local via
# SkaterIKCoordinator.blade_y_local() before any IK or pose call, so the blade always sits at a
# fixed world height regardless of where the upper body anchor is placed in the
# scene. This also means crouching (block stance) doesn't pull the blade
# through the ice — the local Y compensates automatically.
@export var blade_height: float = 0.03
# World-space height the blade rises to when lifted (stick-lift / Q held, or a
# forced pop from an opponent's stick lift). A lifted blade clears grounded
# pucks and sticks — it only meets airborne pucks, to tip them. Eased in via
# Skater._blade_lift_blend and consumed by SkaterIKCoordinator.blade_y_local().
@export var blade_lift_height: float = 0.35
# Fixed, rigid shaft length (hand to blade heel). Baseline 1.30 m ≈ adult
# senior stick shaft (butt-to-heel). The blade mesh extends forward from the
# heel; see Skater.blade_length. Total hand-to-toe is stick_length + blade_length.
@export var stick_length: float = GameRules.DEFAULT_STICK_LENGTH_M
# Hand Y in upper-body-local space. Baseline resting position (used in the
# FAR regime). In the CLOSE regime the hand rises toward `hand_y_max` so the
# stick tilts more vertical and the blade can tuck in close to the body.
# This export is the MESH-NATIVE (Size L2, 5'10") value; apply_attributes
# scales it by height_mult, matching the appearance pass scaling the whole
# skeleton about the ice plane — so the hand sits at the same body point
# (0.50 m × height below the shoulder) on every build instead of pinning to
# one absolute height (which left Size-5 hands hanging visibly low).
# The upper body rides at height_mult × 1.0 m world Y (FACEOFF_SPAWN_HEIGHT
# is the physics origin for every build — only the mesh skeleton scales; the
# cosmetic skating crouch lowers it up to ~7 cm at speed) and the blade at
# blade_height (~ice), so -0.10 gives a hand world Y of 0.90 m × height (hip
# height on each frame) and a rest stick angle of ~42° at L2 — approaching a
# real lie-5 address (~45°), up from the ~38° reach-cheat this used to run
# (hand_rest_y -0.17). The steeper stick pulls the rest carry circle in
# ~6 cm (stick_horiz 1.03 → 0.97), but the shallower shoulder-to-hand drop
# re-aims the arm budget sideways (derived backhand ROM 0.37 → 0.46 m of
# hand displacement), so rim reach is roughly preserved and the directional
# reach lean stays pure bonus on top.
@export var hand_rest_y: float = -0.10
# Ceiling for hand Y in the CLOSE regime. When aiming very close to the
# skater, the hand rises to shorten the stick's horizontal projection; this
# cap keeps the pose anatomical (0.30 local = 1.30 m world at L2 — the hand
# won't climb past chest level). Mesh-native like hand_rest_y; apply_
# attributes scales it by height_mult so the ceiling stays chest-height on
# every frame. With default stick_length = 1.30 m and the blade on the ice
# (blade_y ≈ -0.97 local at L2), hand_y_max = 0.30 → hand-to-blade drop
# 1.27 → min horizontal stick reach ≈ 0.28 m.
@export var hand_y_max: float = 0.30
# Asymmetric ROM for the top hand (measured from shoulder in upper-body-local
# horizontal plane, expressed in "forehand side = positive angle" convention).
# Forehand cross-body reach is anatomically limited; backhand same-side reach
# allows full arm extension, supporting one-handed backhand plays.
# Note: the upper body twists toward the blade (upper_body_twist_ratio = 1.0),
# which effectively reduces how far the hand must reach in upper-body-local space
# — these values assume that twist is active.
@export var rom_forehand_angle_max_deg: float = 90.0
@export var rom_backhand_angle_max_deg: float = 90.0
# Reach caps are DERIVED in apply_attributes — forehand from the anatomical
# cross-body ratio, backhand from the arm chain (sqrt(arm_eff² − drop²), the
# farthest a rest-height hand can sit without out-reaching the arm). These
# defaults just mirror the baseline-size derivation for any skater that has
# not had attributes applied yet.
@export var rom_forehand_reach_max: float = 0.39
@export var rom_backhand_reach_max: float = 0.46
# Fraction of full arm extension the backhand ROM rim uses. 1.0 solves the
# reach with a ramrod-straight arm; slightly under keeps a hint of elbow bend
# at max extension so the rim pose stays organic.
@export var rom_arm_extension: float = 0.97
# Cap on how fast the aim target can move in world XZ per second. The IK consumes
# the smoothed target, so the blade visibly inherits the cap. Originally a high
# (60 m/s) smoothing cap that only bound on fast mouse wraps; now lowered into
# the dangle-speed range (~8-14 m/s). Under attributes v4 the blade tracks every
# build's cursor at the same fidelity (hands_blade_mult() is 1.0 by
# constitution — no hands stat), so this cap is uniform; the lever-geometry
# stage (stick length → tip speed vs inertia) will derive it from reach
# instead. A medium player's full ROM span is ~1.18 m, so 10 m/s crosses it in
# ~118 ms. Tune UP if deliberate aim feels laggy at
# low Hands; tune DOWN if fast dangling feels the same at L1 and L5. (Live-feel
# call — can't be measured headless.)
@export var max_blade_speed: float = 10.0
# Second-order blade: acceleration cap (m/s²) on the dangle velocity — the
# stick's INERTIA. Direction REVERSALS pay the cost, traverse speed doesn't.
# Per-build value derives from lever geometry in apply_attributes: cap ∝
# 1/lever^k — a long stick sweeps faster (tip speed below) but can't cut back
# as fast; a short stick is the scalpel. This is the hands seesaw of
# attributes v4 — geometry, never a fidelity table. The shipped 250 was
# playtest-calibrated across the min/neutral/max builds; 0 disables inertia
# entirely (the pre-v4 first-order servo, bit-exact).
@export var max_blade_accel: float = 250.0
# The k in cap ∝ 1/lever^k. Raw physics is k=2 (I ∝ mL²), but reversal time
# then scales ~L³ across the build range — too brutal. The model's FORM is
# physical; the exponent is feel — 1.6 is the playtest-calibrated spread
# (scalpel↔scythe contrast reads clearly without breaking the scythe).
@export var blade_inertia_exponent: float = 1.6

# ── Nudge (self-tap, nutmeg setup) ────────────────────────────────────────────
# Tap stick-lift (Q) while carrying in plain SKATING_WITH_PUCK to push the puck a
# tiny amount off the blade — a self-pass for threading the puck between a
# defender's legs (the body block only covers the torso now, so a grounded puck
# slips under). The released puck inherits the skater's horizontal velocity plus
# a small nudge along the blade's current motion direction, so RELATIVE to the
# carrier it's just a soft tap in the stick's sweep direction — keep skating and
# you re-collect it. nudge_speed is that relative tap speed (m/s).
@export var nudge_speed: float = 2.2

# Fraction of the carrier's horizontal momentum the nudged puck inherits. Below
# 1.0 the puck drifts back RELATIVE to the carrier while skating (faster skating
# → bigger drift), opening the nutmeg gap instead of the puck keeping perfect
# pace. Stationary it's a no-op (skater velocity ~ 0). Keep close to 1.0 so the
# carrier can still re-collect after the gap opens.
@export var nudge_velocity_retain: float = 0.85

# ── Bottom-Hand IK Tuning ─────────────────────────────────────────────────────
# The bottom hand is purely reactive: each tick it targets a point a short way
# down the stick shaft (from the top hand toward the blade). It releases toward
# a shoulder rest only when the blade's world angle exceeds the upper body's
# rotation limit — ensuring the hand stays connected during any normal swing.
# Never influences blade placement. See domain/rules/bottom_hand_ik.gd.
# Fraction along the shaft (0 = top hand, 1 = blade heel) that the bottom hand
# grips. ~0.25 on a 1.30 m shaft ≈ a typical hockey grip width.
@export var bottom_hand_grip_fraction: float = 0.25
# Fine-tune Y offset added to the bottom hand's shaft-derived grip height
# (SkaterIKCoordinator.update_bottom_hand lerps top-hand Y toward blade Y at
# the grip fraction, then adds this). 0.0 = grip sits exactly on the shaft.
@export var bh_hand_y: float = 0.0
# Blade world angle (from skater forward, toward backhand) at which the bottom
# hand starts releasing toward the shoulder rest. Match upper_body_max_twist_deg
# so the hand releases exactly when the body can no longer rotate to follow.
@export var bh_release_angle_deg: float = 67.0
# Degrees past bh_release_angle_deg over which the hand blends to full rest.
@export var bh_release_angle_band_deg: float = 15.0

# ── Upper Body Tuning ─────────────────────────────────────────────────────────
@export var upper_body_twist_ratio: float = 0.8
@export var upper_body_max_twist_deg: float = 67.0   # caps rotation so extreme angles don't over-rotate
@export var upper_body_return_speed: float = 6.0
# Upper-body twist follow-through (secondary motion) — a damped spring trails
# the tracked twist so the shoulders whip through a fast cut and settle instead
# of tracking rigidly. Renders the tracked angle plus the spring's lag; zero at
# steady state. follow_gain 0 restores rigid tracking.
@export var upper_body_follow_gain: float = 0.4        # how far the shoulders overshoot the whip
@export var upper_body_follow_stiffness: float = 110.0  # spring constant (higher = quicker catch-up)
@export var upper_body_follow_damping: float = 18.0     # damping (near-critical — a clean settle)
# Reach lean — the torso tips TOWARD the blade's reach direction (pitch +
# roll, see SkaterPoseCoordinator.compute_upper_body_lean_target). Because
# the blade IK solves in the leaned frame, this lean genuinely extends world
# reach at the ROM rim (~sin(lean) × shoulder height of shoulder travel plus
# the longer stick footprint from the dropped hands) — the honest way a real
# player buys reach. engage_power > 1 keeps the torso quiet through mid-ROM
# stickhandling and commits the lean near full extension.
@export var upper_body_lean_max_deg: float = 18.0
@export var upper_body_lean_engage_power: float = 1.6
@export var upper_body_lean_return_speed: float = 8.0

# ── Velocity Lean / Skating Posture Tuning ────────────────────────────────────
# Trunk lean INTO travel, re-derived from velocity on every machine (never
# networked — see SkaterPoseCoordinator.compute_velocity_lean_target). Forward
# skating folds the torso forward into the attack posture that makes skating
# read as skating; backward skating sits slightly back; lateral travel banks
# into the carve. The lower body banks fully but follows the forward pitch
# only fractionally — the legs stay under the hips while the trunk folds.
@export var velocity_lean_forward_max_deg: float = 20.0
@export var velocity_lean_back_max_deg: float = 6.0
@export var velocity_lean_lateral_max_deg: float = 12.0
@export var velocity_lean_speed: float = 6.0
@export var lower_body_pitch_follow: float = 0.35

# ── Lower Body Lag Tuning ─────────────────────────────────────────────────────
@export var lower_body_lag_max_deg: float = 20.0
@export var lower_body_lag_speed: float = 5.0

# ── Skating Stride Tuning ─────────────────────────────────────────────────────
# Procedural leg gait — see SkaterSkatingCoordinator. All cosmetic. Forward,
# backward, and lateral (crossover) gaits blend by direction of travel.
@export var stride_cadence: float = 1.4          # low-speed slope: radians of stride phase per metre skated
@export var stride_cadence_max_rate: float = 6.5  # rad/s ceiling the cadence saturates toward (caps sprint leg turnover)
@export var stride_roll_deg: float = 7.0          # side-to-side leg rock amplitude (fwd/back)
# Forward push amplitude (fore/aft). Raised 6 → 10 when the knee fore-aft
# compensation landed: the old visible "reach" was mostly the knee-release
# artifact kicking the skate forward mid-stroke, so once the foot started
# tracking the thigh-design curve the honest stride needed a bigger wave to
# cover the same ground (with the correct slow-recovery / fast-push timing).
@export var stride_pitch_deg: float = 10.0
@export var stride_back_pitch_deg: float = 6.0    # backward C-cut amplitude (reaches forward)
@export var crossover_lean_deg: float = 6.0       # static lean into the strafe direction
@export var crossover_scissor_deg: float = 8.0    # aim-locked strafe: legs scissor laterally
# Carve crossovers — engaged by path curvature (CarveRules), not lateral
# velocity: crossovers are how a skater TURNS at speed. Roles are fixed by
# the turn direction: the outside leg lifts and steps across (over_*,
# clearance), the inside leg extends beneath the body (under_roll).
# carve_stride_fade bleeds the fore/aft stride out as the carve engages —
# in a hard carve the crossovers ARE the stride.
@export var carve_ref_turn_rate: float = 1.6   # rad/s of travel-direction turn = full carve
@export var carve_min_speed: float = 2.5       # m/s floor — slow pivots are steps, not crossovers
@export var carve_engage_speed: float = 5.0    # carve blend ease rate
@export var carve_over_roll_deg: float = 24.0  # crossing (outside) leg roll across the body
@export var carve_under_roll_deg: float = 16.0 # inside leg under-push roll
@export var carve_over_pitch_deg: float = 8.0  # crossing leg also steps AHEAD
@export var carve_clearance_knee_deg: float = 28.0  # lift while crossing the planted leg
@export var carve_stride_fade: float = 0.7     # fraction of fore/aft stride removed at full carve
# Crossover rhythm + cadence (see the carve block in SkaterSkatingCoordinator):
# the over-step and under-push alternate halves of the stride cycle (two-beat
# push-push), the legs hold a static lean into the turn, and while the path is
# actually bending the stride frequency follows the ARC — steps per radian of
# heading change — instead of straight-line speed. Forward-gated: a backward
# turn keeps its C-cuts (forward crossover roles mirror wrong through the flip).
@export var crossover_phase_per_turn: float = 7.0  # stride-phase rad per rad of heading change at full carve
@export var carve_forward_ramp: float = 1.0    # m/s of forward travel over which crossovers fade in
@export var carve_base_lean_deg: float = 7.0   # static both-leg lean into the turn while striding a carve
@export var carve_rock_fade: float = 0.85      # edge-rock/abduction/scissor faded out at full carve
# Gliding — releasing all movement keys settles the legs to rest (the stride
# is input-gated, v15 intent byte) while this floor keeps working knees under
# a coasting skater, scaled by speed.
@export var glide_stance: float = 0.5
@export var stride_knee_deg: float = 18.0         # recovery tuck depth of the swinging (unloaded) knee
@export var stride_intensity_speed: float = 6.0   # how fast the legs ease in/out of motion
@export var stride_skew: float = 0.3              # push/recovery asymmetry of the stroke (0 = pure sine)
# Shifts the leg-pitch stroke behind the body: the push extends (1+bias)× the
# amplitude back while the recovery reaches only (1−bias)× ahead, so the
# returning skate lands under the hips instead of kicking out in front.
# 0 = symmetric metronome (the old forward-kick look).
@export var stride_rear_bias: float = 0.45
@export var stride_abduction_deg: float = 10.0    # outward flare of the extending leg (the skating "V" push)
@export var stride_bob_m: float = 0.02            # vertical body bob per half-stride (weight transfer)
@export var stride_sway_deg: float = 3.0          # torso weight-shift roll oscillating with the stride
@export var stride_dig_lean_deg: float = 8.0      # extra trunk pitch from effort: forward driving, back braking
# Glide-vs-push: stride amplitude scales above/below the speed baseline by the
# sign of tangential acceleration — driving digs in, coasting settles to a glide.
@export var stride_effort_ref_accel: float = 9.0  # m/s^2 of tangential accel mapping to full push effort
@export var stride_effort_speed: float = 5.0      # how fast the glide<->push effort signal eases
@export var stride_push_gain: float = 0.7         # how far effort drives amplitude off the speed baseline
@export var stride_glide_floor: float = 0.35      # min amplitude scale when coasting (the glide)
@export var stride_push_ceiling: float = 1.5      # max amplitude scale when driving hard
# Stance — the speed-engaged crouch. The skater sits into flexed hips/knees as
# soon as they're moving with intent; SkaterSkatingCoordinator derives the
# matching knee flex and body drop from the leg geometry so one export drives
# an anatomically consistent crouch that keeps the skates planted on the ice.
@export var stance_hip_deg: float = 22.0            # static hip flex at full stance
@export var stance_full_speed_fraction: float = 0.45  # fraction of max_speed at which the crouch fully engages
@export var stance_push_gain: float = 0.35          # effort deepens (push) / shallows (glide) the stance
@export var stance_knee_release: float = 0.85       # fraction of stance knee flex released at full push extension
# Faceoff ready stance — during the FACEOFF_PREP countdown the speed-driven
# crouch is floored at faceoff_stance (players are at a standstill, so the
# intensity envelope alone would leave them bolt upright) and the feet
# stagger fore/aft (stick-side foot back, braced for the draw). Phase is
# replicated, so every machine poses its skaters identically.
@export var faceoff_stance: float = 0.85       # stance engagement floor at the dot
@export var faceoff_split_deg: float = 9.0     # fore/aft leg stagger at the dot
# Fraction of the rest blade radius at which this skater's CENTER spawns from
# the faceoff dot — reach-derived so a Size-1 center (short stick + arms) can
# play the drop as comfortably as a Size-5 (see faceoff_center_distance).
@export var faceoff_center_reach_fraction: float = 0.9
# Faceoff-draw swipe capture (see Skater.begin_draw_tracking / FaceoffDrawRules).
# A center's blade-swipe crest is retained through the draw so the contest reads
# the sweep, not the raw tick-at-contact velocity — this is what lets a well-aimed
# swipe actually land. faceoff_draw_peak_decay (m/s per second) sets how long a
# crest lingers (~crest/decay seconds), giving a natural pre-roll while forgetting
# an early guess; faceoff_draw_window auto-ends tracking that long after the drop.
# The timing REWARD curve lives with the contest resolver (PuckController.contest_
# draw_timing_*). Read by PhaseCoordinator when it arms the two centers.
@export var faceoff_draw_peak_decay: float = 12.0
@export var faceoff_draw_window: float = 1.0
# Hockey stop — braking hard at speed turns the lower body across the travel
# direction (legs sideways, torso still on the play) with a scissored,
# edge-rolled stance. Engagement derives from the velocity-based effort
# signal (HockeyStopRules — hysteresis + side latch), so remotes/bots read
# the identical stop with no wire state. All cosmetic; brake physics and the
# skid VFX are untouched.
@export var hockey_stop_effort: float = 0.55     # braking-effort fraction that engages
@export var hockey_stop_min_speed: float = 3.0   # m/s floor — no stop pose from a shuffle
@export var hockey_stop_max_yaw_deg: float = 70.0  # lower-body turn cap across travel
@export var hockey_stop_split_deg: float = 14.0  # leading/trailing leg scissor
@export var hockey_stop_edge_deg: float = 12.0   # shared leg roll — edges biting
@export var hockey_stop_stance: float = 0.9      # stance floor while stopping (deep knees)
@export var hockey_stop_trunk_roll_deg: float = 6.0  # trunk bank over the skid
@export var hockey_stop_blend_speed: float = 9.0 # pose ease-in/out rate
# Hip-to-travel alignment — the lower body yaws toward the direction of
# MOTION (torso keeps facing the cursor) so the legs stride along travel
# instead of flailing through the crossover/backward blends whenever cursor
# and movement disagree. Clamped: misalignment beyond the cap still plays
# the backward C-cut / crossover gaits on the residual, as designed.
@export var hip_align_max_deg: float = 50.0  # cap on the hips' turn toward travel
@export var hip_align_speed: float = 6.0     # how fast the hips settle onto the travel line
# Input-intent gait reads (GaitIntentRules, v15 intent byte) — signals for
# what the player is TRYING to do, layered over the velocity-derived gait.
# All cosmetic; every signal derives from replicated state, so local, bot,
# and remote skaters read identically.
@export var intent_signal_speed: float = 6.0     # ease rate of the smoothed intent signals
# Dig-in: intent held at low speed — explosive, choppy first strides.
@export var dig_in_fade_speed: float = 4.0       # m/s where the dig hands off to the speed gait
@export var dig_in_intensity: float = 0.85       # stride intensity floor while digging in
@export var dig_in_cadence_rate: float = 4.5     # rad/s stride-phase floor — quick chop from a standstill
@export var dig_in_chop: float = 0.35            # push-amplitude cut at full dig (short strides)
@export var dig_in_stance: float = 0.7           # stance floor — power comes from bent knees
@export var dig_in_lean_deg: float = 6.0         # extra forward trunk pitch driving out of the start
# Reversal: intent opposing travel at speed — the stop-and-go weight shift.
@export var reversal_min_speed: float = 2.5      # m/s floor — a slow reversal is just a step
@export var reversal_start_opposition: float = 0.5  # travel·intent opposition where the shift begins
@export var reversal_stride_fade: float = 0.8    # stride suppression at full reversal (legs plant)
@export var reversal_stance: float = 0.85        # stance floor — sits down hard into the plant
@export var reversal_lean_deg: float = 7.0       # trunk tips BACK against the travel it fights
@export var reversal_plant_deg: float = 8.0      # wide-V outward leg plant
# Shuffle: lateral intent at low speed — hips stay square, legs side-step.
@export var shuffle_fade_speed: float = 4.0      # m/s where crossovers take over from the shuffle
@export var shuffle_start_lateral: float = 0.6   # lateral intent fraction where the shuffle begins
@export var shuffle_intensity: float = 0.6       # stride intensity floor while side-stepping
@export var shuffle_cadence_rate: float = 3.0    # rad/s stride-phase floor for the steps
# Backpedal: intent held behind the facing — a defender's deliberate back-skate.
@export var backpedal_start: float = 0.35        # backward intent fraction where the read begins
@export var backpedal_ccut_roll_deg: float = 6.0 # extra out-and-in leg sweep (real C-cuts)
@export var backpedal_chest_deg: float = 4.0     # chest-up trunk pitch over the C-cuts
# Glide enrichment: coasting (no keys) sways weight edge-to-edge, and a carve
# released into a glide exits the turn on its edges (one-foot-glide read).
@export var glide_sway_deg: float = 2.5          # lazy edge-to-edge roll amplitude
@export var glide_sway_hz: float = 0.4           # sway frequency — far below stride cadence
@export var glide_carve_lean_deg: float = 10.0   # legs lean into the arc gliding out of a turn
@export var glide_inside_tuck_deg: float = 10.0  # inside-leg knee tuck — weight on the outside edge
# Sprint read: sprint_active (resolved where the skater is simulated; bit 5 of
# the v16 intent byte for client-rendered remotes) drives a visibly committed
# gait — LONGER, more powerful strides (the cadence ceiling already keeps leg
# turnover flat, so sprint reads as reach, not churn), a deeper sit, and the
# shoulders driving forward. Doubles as the opponent-stamina tell: a skater
# who stops striding like this has run out of sprint.
@export var sprint_stride_gain: float = 0.35     # stride amplitude boost at full sprint
@export var sprint_stance_gain: float = 0.18     # extra crouch depth while sprinting
@export var sprint_lean_deg: float = 7.0         # extra forward trunk pitch while sprinting
# Cadence "gears" — grounded in on-ice biomechanics: from acceleration to
# sustained max velocity real skaters DROP stride frequency and lengthen the
# glide (speed is power per stride, not faster turnover). cruise_gear (fast AND
# not still accelerating) eases the stride rate down, deepens the sit, and warps
# the stroke toward a longer glide dwell. All zero while accelerating/digging,
# so the start/chop feel is untouched; set these to 0 to restore the prior gait.
@export var cadence_cruise_falloff: float = 0.28    # max fraction the stride rate eases down at sustained cruise
@export var glide_hold_skew: float = 0.25           # extra stroke skew at cruise — snappier push, longer glide dwell
@export var cadence_glide_stance_gain: float = 0.12 # extra sit depth at sustained top speed
# Spring weight transfer (Rosen-style secondary motion) — a damped spring lags
# the lateral weight shift behind the stride so the body rides over the loaded
# leg and settles with follow-through instead of rolling rigidly with it. Adds
# "weight" for almost nothing. weight_shift_deg 0 restores the prior gait.
@export var weight_shift_deg: float = 2.5           # amplitude of the springy lateral body lean
@export var weight_spring_stiffness: float = 90.0   # spring constant (higher = snappier follow)
@export var weight_spring_damping: float = 14.0     # damping (near-critical — a clean settle with slight overshoot)

# ── Wrister Tuning ────────────────────────────────────────────────────────────
@export var min_wrister_power: float = GameRules.DEFAULT_WRISTER_POWER_MIN_M_S
@export var max_wrister_power: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
@export var backhand_power_coefficient: float = 0.75
@export var max_charge_direction_variance: float = 35.0
# Forehand-default deadband (RADIANS of net swing rotation) for the
# forehand/backhand read: a stroke whose blade sweeps less than this net angle
# around the player — a near-straight push — defaults to forehand. A backhand
# is the deliberate rotational commit past it. See
# ShotMechanics.is_backhand_from_swing. 0.35 rad ≈ 20°.
@export var wrister_backhand_deadband: float = 0.35
# ── Wrister power model (ShotMechanics.wrister_power_t) ──
# Power is a feel-curve over the release speed signal (cursor speed for humans,
# a committed target for bots — see _wrister_sweep_speed). power_curve shapes
# where an ordinary flick lands in the band. Feel tunable, NOT attribute-scaled
# (Shot scales the ceiling).
@export var wrister_power_curve: float = GameRules.DEFAULT_WRISTER_POWER_CURVE
# ── Pure mouse-speed wrister ──
# Wrister power is a curve over the raw SCREEN-space cursor speed (px/s) — flick
# fast = hard, sweep slow = soft — distance-independent. Direction is still the
# drag vector; power_curve (above) shapes where a flick lands.
# wrister_mouse_speed_full is the cursor speed (px/s) that reads as full power.
# It's PER-SETUP (scales with DPI/resolution), so players calibrate via the
# Shot Power Sensitivity setting rather than this raw reference.
@export var wrister_mouse_speed_full: float = 2500.0
@export var wrister_mouse_speed_smoothing: float = 14.0
# PROTOTYPE (aim-model A/B): when true, the wrister's DIRECTION is PINNED
# ORIGIN → cursor — the shot fires along the line from where the stroke STARTED
# (the blade/puck at mouse-down, SkaterAimingBehavior.wrister_origin_world) to
# the cursor at release. This is the "start at your blade, drag to where you
# point, and the puck follows that line" model — the endpoint form of the old
# blade-ROM-sweep aim — and it's the SAME positional family the quick pass uses.
# When false, the wrister aims along the drag vector (where the cursor was moving
# at release) — the original gestural aim. Power is untouched either way: it stays
# the pure mouse-SPEED model, so this only swaps the direction signal.
# Rationale: the drag-vector wrister and the blade→cursor quick pass are two
# contradictory aim models, and the quick pass trains the habit (park the cursor
# on the target) that breaks the gestural wrister. Unifying them makes the quick
# pass a genuine on-ramp ("a wrister at fixed power") and lets a live aim line be
# drawn while charging (a drag-vector shot can't be previewed — its direction
# doesn't exist until release). The origin is PINNED at stroke start, not read
# from the live blade: the live blade leads and arcs to an extreme by release, so
# a live-blade origin whipped the aim at tight angles / a close cursor.
# NOTE (netcode): this reintroduces a body/blade-derived aim, the class of signal
# the original blade-ROM aim was removed for (client/host divergence). The origin
# is captured and reconcile-restored like the rest of the charge state, so it's
# deterministic under replay — but validate an online shot before shipping the
# swap. Flip in the editor to compare feel without a rebuild.
@export var wrister_positional_aim: bool = true
# PROTOTYPE (freeze-blade): when true, the blade+puck STOP chasing the cursor for
# the duration of a wrister charge and hold at the shot origin — the torso still
# coils toward the cursor, but the puck sits still where the shot will fire from.
# This makes the origin visible and turns the charge into a legible "committing
# to a shot" read (for the goalie and for other players), and makes the pinned
# origin→cursor aim exact (the puck really is at the origin at release). Release
# is unchanged — fires instantly, the existing follow-through plays the unwind.
# Implies positional aim (a frozen blade has no drag/sweep to read). Forehand/
# backhand still comes from the swing chirality, but sourced from the CURSOR's
# bearing sweep while frozen (the blade can't swing) — see _update_wrister_charge.
# The travel gate is disabled while frozen (a frozen blade banks no blade-path
# travel), so power is uncapped mouse-speed for now (twitch = max); a real anti-
# degeneracy pass (a cursor-sweep gate) comes later if the freeze is worth keeping.
@export var wrister_freeze_blade: bool = true
# ── Travel-gated ceiling (ShotMechanics.wrister_travel_cap_t) ──
# The power CEILING must be earned with real blade travel: cursor speed alone
# (a wiggle, a short jerk, a cranked Shot Power Sensitivity) caps at the floor
# tier. Measured in WORLD meters of blade path over the stroke, so it can't be
# bought with DPI or the sensitivity setting — pixels don't move the blade
# past ROM. The full-travel reference is a baseline for the default build;
# apply_attributes rescales it by the build's own blade sweep radius (stick +
# arm ROM) so "a full stroke" means the same fraction of each build's
# reachable arc — Size must not leak into the wrister ceiling.
#   wrister_full_stroke_travel: blade path (m) that unlocks the full band.
#     <= 0 disables the gate. Calibrate against the debug shot toast's stroke
#     readout (an honest full sweep should land at/past it; a twitch far under).
#   wrister_travel_cap_floor: fraction of the power band reachable with zero
#     travel — the instant flick-pass / snap tier (0.4 of the 10..33 base band
#     ≈ 19 m/s, a crisp pass; %-based, so Shot scales it with the ceiling).
@export var wrister_full_stroke_travel: float = 1.0
@export var wrister_travel_cap_floor: float = 0.4
# Blade-speed budget ALONG the shot axis during a wrister aim (m/s of blade
# travel, applied relative to the skater like max_blade_speed). High and FLAT
# (not Hands-scaled) so the wind-back-and-snap of a wrister tracks responsively
# for every player — Hands still gates the off-axis (lateral/dangle) component,
# which stays capped at max_blade_speed. See SkaterIKCoordinator.apply_blade_from_mouse.
@export var wrister_on_axis_blade_speed: float = 60.0
# Fixed power of the quick pass (blade→cursor snap fired by the dedicated
# quick_pass button). Doubles as the pass speed, so it stays flat for everyone.
@export var quick_pass_power: float = GameRules.DEFAULT_QUICK_PASS_POWER_M_S
# Loft-level vertical launch speeds (m/s), shared by quick passes, wristers, and
# slappers in every direction — one elevation mechanic for shots AND passes
# (see ShotMechanics loft-level doc). Apex above the launch point (ice_height
# 0.0175 m) is v_y²/2g; the crossbar pipe runs 1.19–1.25 m (centerline 1.22 m):
#   LOW  2.2  → apex ~0.26 m — the saucer: clears stick blades, lands and slides.
#   HIGH 4.65 → apex ~1.12 m (puck top ~1.14 m) — the peak sits a clean ~5 cm
#   UNDER the crossbar's inner edge (1.19 m), so a HIGH shot can snipe the top of
#   the net but its disc never reaches the bar to tip over it. Apex height is a
#   FIXED ceiling (v_y is power-independent), so raising shot power can't sail a
#   shot over — it only moves the apex DISTANCE out. This is deliberately below
#   #340's apex-at-crossbar (v_y 4.9): once #363 raised shot power (wrister 24→33,
#   slapper 34→40 m/s) the apex distance moved into common point/slot range, so
#   the marginal over-the-bar condition started landing on ordinary shots.
# Where the arc sits at the net is emergent from distance + power — that read
# is the skill (the old ballistic solve auto-arrived at a target height).
@export var loft_vertical_speed_low: float = GameRules.DEFAULT_LOFT_VY_LOW_M_S
@export var loft_vertical_speed_high: float = GameRules.DEFAULT_LOFT_VY_HIGH_M_S

# ── Head Tracking Tuning ─────────────────────────────────────────────────────
@export var head_track_speed: float = 12.0
@export var head_track_max_deg: float = 60.0

# ── Slapper Tuning ────────────────────────────────────────────────────────────
@export var slapper_wind_up_height: float = 1.0
# (No separate wind-up duration — the pose fills over max_slapper_charge_time,
# see slapper_wind_up_t(), so the animation IS the charge readout.)
# Full-charge tell: with no charge ring, the wind-up pose IS the gauge, so
# "the coil is maxed" needs a live cue — a small quiver at the apex (the
# shooter straining at the top). Amplitude in metres on the blade height,
# half of it on the top hand.
@export var slapper_full_quiver_m: float = 0.02
@export var slapper_full_quiver_hz: float = 9.0
@export var slapper_zone_radius: float = 0.5
# Where the one-timer reception zone (and slap-with-puck pin) lives. Heavily
# lateral with a small forward bias matches a real cross-ice one-timer stance:
# puck arrives on the blade side, slightly ahead of the player's centre, so
# they can swing through it without reaching forward.
@export var slapper_zone_offset_x: float = 1.0  # lateral offset toward blade side
@export var slapper_zone_offset_z: float = -0.4  # forward offset (negative = in front of player)
@export var min_slapper_power: float = GameRules.DEFAULT_SLAPPER_POWER_MIN_M_S
@export var max_slapper_power: float = GameRules.DEFAULT_SLAPPER_POWER_MAX_M_S
@export var max_slapper_charge_time: float = 0.7
@export var slapper_blade_x: float = 1.0
@export var slapper_blade_z: float = -0.5
@export var slapper_aim_arc: float = 45.0
# Wind-up coil: layered on top of the aim-tracking torso angle. Rotates the
# back shoulder away from the target (for RHS that's CW from above, i.e. left
# shoulder points at the puck) while pulling the top hand up and across the
# body toward the back shoulder. The coil fills over the FULL charge time
# (slapper_wind_up_t) — the pose is the charge gauge — sqrt-eased so it snaps
# into motion early and creeps to its apex exactly at max charge.
@export var slapper_wind_up_twist_deg: float = 80.0
@export var slapper_wind_up_hand_up: float = 0.30      # top hand rises (m)
# Pushes the top hand forward in upper-body-local space (negative local Z).
# After the torso coil, this body-local "forward" points along the rotated
# body's new forward direction in world — so for an LHS player coiled CCW
# the hand ends up upper-left, for an RHS player coiled CW it ends up
# upper-right. The hand rides the rotation but is placed in front of the
# back shoulder rather than glued to it.
@export var slapper_wind_up_hand_forward: float = 0.35
# Lateral body-local offsets — left at 0 because they fight the coil (a
# body-local +Z offset rotates to a world -X under the coil, pulling the hand
# off the back-shoulder side). Available to tune if a held pose needs extra
# lateral character without flipping that direction.
@export var slapper_wind_up_hand_back: float = 0.0     # top hand pulls behind shoulder (+local z, m)
@export var slapper_wind_up_hand_inward: float = 0.0   # top hand pulls across body toward back shoulder (m)
# Where the blade lives at full wind-up (in body-local space, before the body
# coils). Forward in upper-body-local (negative Z) places the blade ahead of
# the rotated body in world space — same trick as the top hand. With the
# coil this lands the blade on the same side as the back-shoulder rotated
# *through* world-forward, so the stick reads as loaded across the front of
# the player rather than wrapping behind the back shoulder.
@export var slapper_wind_up_blade_x: float = 0.4       # blade lateral offset at full charge (was slapper_blade_x=1.0)
@export var slapper_wind_up_blade_z: float = -0.4      # blade depth at full charge — negative = forward in body-local
# Snappier lerp during the slapshot coil — the default upper_body_return_speed
# is tuned for gentle aim-tracking and lags a fast coil, which reads as a
# half-finished wind-up.
@export var slapper_wind_up_lerp_speed: float = 18.0
@export var one_timer_window_duration: float = 0.45  # seconds after puck arrives to release
@export var one_timer_leniency_time: float = 0.08   # seconds of puck travel added to zone radius as leniency
@export var one_timer_center_power_bonus: float = 0.10  # ±10%: edge of zone = −10%, dead centre = +10%
# Minimum wind-up (seconds of slapper charge) before an arriving puck opens the
# timed one-timer window. Below it — the "puck was already at the stick when the
# wind-up began" case — a forced window would open at ~zero power and cancel
# straight to carry (a flicker + a shot that never happens). Under this floor the
# catch rolls into a plain slapshot charge instead: keep winding up, release when
# ready. Feel floor, deliberately small so genuine early one-timers still window.
@export var one_timer_min_windup_time: float = 0.15

var show_one_timer_indicator: bool = false

# ── Follow Through Tuning ─────────────────────────────────────────────────────
# Durations are per shot type: the wrister carries a real finish, the quick
# shot / pass stays snappy (the blade is choreographed for the whole timer, so
# this is also how long the blade ignores the cursor after a pass), and the
# slapper swings biggest. Every amplitude below additionally scales with the
# shot's follow_through_power, set at release (wrister by charge, quick pass
# fixed low, slapper full) — a soft pass flicks, a full-charge bomb finishes
# high. Shapes ride sin(PI · t^arc_skew): 1.0 is a symmetric up-down arc, <1
# peaks earlier so the finish snaps up with the release and settles slowly.
@export var follow_through_duration: float = 0.22             # wrister — short + front-loaded so the whip fires WITH the release (was 0.35)
@export var quick_pass_follow_through_duration: float = 0.18  # snap pass flick
@export var slapper_follow_through_duration: float = 0.5
# Lower = the whip peaks EARLIER (0.4 → peak at ~t=0.18 of the timer, ~40 ms after
# release, then a slow settle). This is what makes the coil discharge explosively
# with the shot instead of the old mid-timer bell (peak ~130 ms after the puck
# already left). Shared with the slapper finish.
@export var follow_through_arc_skew: float = 0.4
# First fraction of the wrister/quick FT spent blending from the captured
# release pose onto the authored swing (kills the release-instant teleport
# to a near-rest pose — the "animation played twice" read). Small so the blade
# leaves the (now retracted, frozen) origin FAST and whips through the shot.
@export var follow_through_takeover_frac: float = 0.14
# Last fraction of the wrister/quick/slapper FT spent easing the finish aim (torso
# twist + blade) from the shot line back to the LIVE cursor, so the pose ends
# where the mouse actually is and hands off to blade-tracking without re-rotating
# (the "follow-through, then a reset back" read). 0 keeps the pure shot-line
# finish. Blends the aim only in the tail so the shot-line follow-through still
# reads through the meat of the timer.
@export var follow_through_return_frac: float = 0.4
@export var wrister_follow_through_min_power: float = 0.55  # amplitude floor at zero charge
@export var quick_pass_follow_through_power: float = 0.5
@export var wrister_follow_through_hand_y: float = 0.35
@export var wrister_follow_through_blade_lift: float = 0.55  # high-finish blade height off the ice
@export var wrister_follow_through_reach: float = 0.85  # forward DRIVE of the blade from the frozen origin along the shot line (the explosive "through the shot")
@export var wrister_follow_through_twist_deg: float = 45.0   # shoulders explode through the shot (frozen wrister discharges this instantly)
@export var slapper_follow_through_twist_deg: float = 50.0   # full uncoil past the shot line
@export var follow_through_lean_deg: float = 8.0             # trunk drives forward over the front foot
@export var follow_through_twist_lerp_speed: float = 15.0  # snap the torso from coil through the overshoot fast (was 9.0)
@export var slapper_follow_through_arc_dist: float = 0.75  # blade XZ travel along the shot line through the finish
@export var slapper_follow_through_height: float = 0.85    # high-finish blade height off the ice
@export var slapper_follow_through_hand_y: float = 0.4     # hands rise through the finish
@export var slapper_follow_through_hand_follow: float = 0.4  # fraction of blade travel the hands follow (limits shaft stretch)
@export var slapper_follow_through_contact_frac: float = 0.22  # first fraction of the timer spent on the downswing

# ── Shot Body Animation Tuning ────────────────────────────────────────────────
# Cosmetic lower-body work for the shots (SkaterSkatingCoordinator): the load
# sinks the weight onto the stick-side back leg while the charge builds, and
# the release drives it over the front foot with the back leg kicking into
# extension behind — the weight transfer that sells a shot. Wrister and
# slapper share the machinery with their own amplitude sets: the wrister load
# tracks the drag-charge, the slapper load tracks the wind-up (re-derived from
# the replicated charge — see the gait), sits deeper, and coils the hips
# harder under the 80° torso coil; the slapper kick swings bigger and always
# commits (higher min power — the swing is full-body even off a short
# wind-up). Driven entirely from the replicated fields (current_shot_state +
# shot_charge), so local, bot, and remote skaters play the identical animation
# with zero new network state (same contract as the stick flex). First-pass
# numbers — tune in the editor.
@export var wrister_load_stance: float = 0.55          # crouch floor at full charge (fraction of stance_hip_deg)
@export var wrister_load_lean_deg: float = 5.0         # shared leg roll: weight over the stick-side back leg
@export var wrister_load_split_deg: float = 8.0        # foot stagger: stick-side foot drops back
@export var wrister_load_hip_coil_deg: float = 8.0     # hips coil with the torso, stick-side hip back
@export var wrister_load_blend_speed: float = 6.0      # how fast the load pose tracks the charge (both shots)
@export var wrister_kick_time: float = 0.5             # seconds of weight transfer/kick after release
@export var wrister_kick_min_power: float = 0.35       # amplitude floor so snaps and passes still read
@export var wrister_kick_back_deg: float = 26.0        # back (stick-side) leg drives into extension behind
@export var wrister_kick_knee_extend_deg: float = 30.0 # back knee straightens through the kick
@export var wrister_kick_lean_deg: float = 7.0         # shared leg roll: weight lands over the front foot
@export var wrister_kick_stance: float = 0.5           # front-leg sit through the drive
@export var wrister_kick_hip_yaw_deg: float = 12.0     # hips uncoil through the shot line
@export var slapper_load_stance: float = 0.75          # the wind-up sits DEEP — the power position
@export var slapper_load_lean_deg: float = 7.0         # harder weight-back than the wrister load
@export var slapper_load_split_deg: float = 11.0       # wider shooting base for the full swing
@export var slapper_load_hip_coil_deg: float = 16.0    # hips coil under the wound-up torso
@export var slapper_kick_time: float = 0.6             # spans downswing + contact + finish
@export var slapper_kick_min_power: float = 0.6        # a slap swing commits the body even off a short wind-up
@export var slapper_kick_back_deg: float = 34.0        # full back-leg extension through the finish
@export var slapper_kick_knee_extend_deg: float = 38.0 # back knee straightens hard
@export var slapper_kick_lean_deg: float = 9.0         # weight lands hard over the front foot
@export var slapper_kick_stance: float = 0.6           # front-leg sit through the drive
@export var slapper_kick_hip_yaw_deg: float = 20.0     # hips uncoil hard through the shot line
@export var shot_stride_fade: float = 0.8              # stride suppression while loading/kicking (glide through the shot)

# ── Body Language Tuning ──────────────────────────────────────────────────────
# Remaining cosmetic body reads (all in SkaterSkatingCoordinator). Check
# delivery fires from the host-authoritative body_check_landed broadcast
# (start_check_drive), so the hitter's drive lands the same frame as the
# burst/thud on every machine; the stick-lift read keys off the replicated
# blade_up; the celebration bounce reads the same timer the raised-stick pose
# uses (started on every machine — see GameManager._trigger_scorer_celebration).
@export var check_drive_time: float = 0.45        # seconds of shoulder-drive after a landed hit
@export var check_drive_lean_deg: float = 14.0    # trunk drives INTO the hit at full hardness
@export var check_drive_stance: float = 0.6       # legs drive under the hit — the finishing base
@export var stick_lift_trunk_deg: float = 3.0     # slight chest-up pop while working under a stick
@export var stick_lift_stance: float = 0.2        # coiled working posture while the blade is up
@export var stick_lift_blend_speed: float = 10.0  # how fast the lift read engages/releases
@export var celebration_leg_stance: float = 0.6   # knee-pump depth of the celebration bounce

# ── Celebration Tuning ────────────────────────────────────────────────────────
# Cosmetic raised-stick goal celebration (SkaterShotPoseCoordinator.
# apply_celebration_pose) — heights in upper-body-local metres.
@export var celebration_hand_y: float = 0.45     # raised top-hand height
@export var celebration_stick_rise: float = 0.5  # blade height above the raised hand

# ── Shot-Block Tuning ─────────────────────────────────────────────────────────
# Movement speed while blocking (unused while the stance is fully planted; kept for tuning).
@export var block_speed_multiplier: float = 0.45
# Choreographed "stick down" block pose, authored in upper-body-local space.
# Forward is local −Z (toward the shooter the stance snapped to on entry); the
# stick side is +X for a righty, −X for a lefty (blade_side_sign). The blade lies
# flat on the ice (Y is lean-corrected to ice level); the top hand drops low and
# pushes forward so the shaft lies down across the lane. First-pass numbers —
# tune in the editor (see CLAUDE.md "get it working, then tune numbers").
@export var block_blade_reach: float = 1.0   # forward blade extension from the shoulder (m, local −Z)
@export var block_blade_x: float = 0.2       # lateral blade offset to the stick side (m)
@export var block_hand_forward: float = 0.3  # forward push of the top hand (m, local −Z)
@export var block_hand_x: float = 0.1        # lateral top-hand offset to the stick side (m)
@export var block_hand_y: float = -0.10      # top-hand height while blocking (m, local; matches mesh-native hand_rest_y)
# Cosmetic block BODY pose (gait + pose coordinator): the blocker drops into a
# low, wide wall — deep knee bend with the matching whole-body sink, both legs
# spread into a braced V, and the chest folds over the knees — instead of the
# old bolt-upright mannequin with straight legs. Keyed off the replicated
# current_shot_state, so remote blockers read identically.
@export var block_stance: float = 0.9            # stance-crouch floor while blocking (fraction of stance_hip_deg)
@export var block_spread_deg: float = 16.0       # both legs splay outward — the braced wall base
@export var block_trunk_pitch_deg: float = 14.0  # chest folds forward over the knees
@export var block_pose_blend_speed: float = 12.0 # snap-in speed of the body pose (the plant is committed)

# ── Goalie Body Block ─────────────────────────────────────────────────────────
# XZ cylinder radius used to push the blade (and carried puck) away from a
# goalie's body center. Tunable in the editor — matches roughly the goalie's
# padded chest width. The hand moves with the blade to keep stick length intact.
@export var goalie_block_radius: float = 0.50
@export var goalie_strip_power: float = 1.5
# Half-extents of the butterfly leg-pad strip box in goalie local XZ space.
@export var butterfly_pad_half_x: float = 0.84
@export var butterfly_pad_half_z: float = 0.25

# ── References ────────────────────────────────────────────────────────────────
var skater: Skater = null
var puck: Puck = null
# Injected at setup. Expected methods:
#   is_host() -> bool                              — changes only per session; cached in _is_host
#   is_movement_locked() -> bool                   — polled per frame
#   get_goalie_data() -> Array[Dictionary]         — position/rotation_y/is_butterfly per goalie
var _game_state: Node = null
var _is_host: bool = false

# ── Runtime State ─────────────────────────────────────────────────────────────
var _blade_relative_angle: float = 0.0
# Live cursor world position this tick — stamped in _process_input so the shot
# follow-through can ease its finish aim back to wherever the mouse currently is
# (see follow_through_return_frac). Fed from the replayed input during reconcile,
# so it stays deterministic. Only read by the FOLLOW_THROUGH pose branches, which
# never run on the faceoff/skate-in cosmetic paths, so a stale value is harmless.
var _current_aim_world: Vector3 = Vector3.ZERO
# Reused ShotResult for the per-tick "where would this charge go if released now"
# prediction in _update_wrister_charge — a caller-owned scratch so that hot path
# (120 Hz while charging, re-run per replayed input on reconcile) doesn't churn
# the heap. Pure output, overwritten each solve.
var _wrister_pred_scratch: ShotMechanics.ShotResult = ShotMechanics.ShotResult.new()
# Same scratch for the slapper windup's release-now prediction (_update_slapper_
# charge) — the goalie pre-leans off it toward a charging slapshot's aimed corner.
var _slapper_pred_scratch: ShotMechanics.ShotResult = ShotMechanics.ShotResult.new()
# Per-tick mirror of input.elevation_level (0 flat / 1 low / 2 high) — NOT
# sticky state: overwritten from the frame every tick, so reconcile replay
# re-derives it from the replayed inputs with nothing to snap.
var _elevation_level: int = 0
var _aiming: SkaterAimingBehavior = SkaterAimingBehavior.new()
var _pose: SkaterPoseCoordinator = SkaterPoseCoordinator.new()
var _shot_pose: SkaterShotPoseCoordinator = SkaterShotPoseCoordinator.new()
var _skating: SkaterSkatingCoordinator = SkaterSkatingCoordinator.new()
var _ik: SkaterIKCoordinator = SkaterIKCoordinator.new()
var last_processed_host_timestamp: float = 0.0
var has_puck: bool = false
var is_replaying: bool = false
# Previous-tick puck PIN (get_carry_target_global), the swept `prev` the carried-
# puck net clamp feeds NetClampRules so it can tell a legit front-mouth occupant
# (rides in / out) from a side/back intrusion (pushed out). Always a clamped
# (legal) position, per NetClampRules' inductive front-entry contract. Reset when
# the puck comes loose. See _clamp_carry_pin_from_net.
var _prev_carry_pin: Vector3 = Vector3.ZERO
var _has_prev_carry_pin: bool = false
# True on frames where a special locked-phase path posed the body itself this
# tick — faceoff-prep blade aim, the faceoff skate-in approach, and replay
# playback. Those paths run their own gait / head / off-hand (they're brief and
# not the 120 Hz × N hot path), so the render-rate cosmetic hook yields to them
# to avoid a double gait pass. The main live path (_process_input) clears it and
# delegates cosmetics to the render hook.
var _self_posing: bool = false
# Sprint stamina (0..1) and the exhaustion lockout latch. Updated deterministically
# each tick in _apply_movement; the local player's reconcile snaps both to the
# host's authoritative value before replay (see LocalController.reconcile) and
# the host broadcasts them via fill_network_state.
var stamina: float = 1.0
var _sprint_locked: bool = false
# Body-check stagger: seconds of thrust-penalty recovery remaining. Set
# host-authoritatively when this skater absorbs a check (_on_body_check_received),
# decayed each tick in _apply_movement, and replicated so the local player's
# reconcile snaps it to the host baseline before replay (same as stamina).
var stagger_timer: float = 0.0
# Body-check knockdown: seconds of full movement lockout remaining. Set host-
# authoritatively (and predicted on the local victim) when a hit exceeds the
# knockdown threshold; while > 0 the skater is down (no input, sliding, no puck).
# Replicated / snapped / decayed exactly like stagger_timer.
var knockdown_timer: float = 0.0
# Body-frame direction the last check shoved this skater (x = right, y = forward
# in the (x, z) plane). Drives the recoil lean in SkaterPoseCoordinator; set on
# the local victim / host from the transfer impulse, left at the default (0, 1 =
# straight back) for remotes, which only receive the timer. Cosmetic, so it does
# not need replicating or reconciling — the timer that gates it already does.
var stagger_recoil_dir: Vector2 = Vector2(0.0, 1.0)
# Resolved sprint-boost state for this tick. Written in _apply_movement (which
# runs before _pose.apply_facing in _process_input) and read by the pose
# coordinator to apply the turn-rate penalty. Public so the pose collaborator
# can read it without a getter.
var sprint_active: bool = false
# Resolved hit-commit (body-check button) state for this tick. Written in
# _apply_movement alongside sprint_active and read by the pose coordinator for the
# turn-rate penalty; also mirrored to skater.hit_committed so the collision
# resolver picks full-vs-passive transfer. Deterministic from input.hit_held +
# stamina, so it re-derives through reconcile replay with no wire state.
var hit_active: bool = false

var _game_state_has_faceoff_prep: bool = false
var _game_state_has_period_break: bool = false
# Cosmetic goal-celebration window (seconds remaining / total). Set by
# GameManager on the machine that simulates the scorer; the raised-stick pose
# rides the normal hand/blade wire state to everyone else.
var _celebration_timer: float = 0.0
var _celebration_total: float = 1.0

# ── Faceoff / intro skate-in approach ─────────────────────────────────────────
# During FACEOFF_PREP the skater glides from a start point (its bench for the
# opening intro, else its current position) to the faceoff dot along a
# deterministic eased path instead of teleport-snapping — the existing
# velocity-driven gait rides on top. Position is a pure function of (start,
# target, elapsed/duration) so host and every client agree with reconcile off;
# the skater lands exactly on the dot at t=1 and hands back to the normal prep
# freeze for the rest of the countdown. See begin_approach / apply_approach.
var _approach_active: bool = false
var _approach_start: Vector3 = Vector3.ZERO
var _approach_target: Vector3 = Vector3.ZERO
var _approach_facing: Vector2 = Vector2.ZERO   # squared-up dot facing at arrival
var _approach_elapsed: float = 0.0
var _approach_duration: float = 1.0
var _approach_prev_pos: Vector3 = Vector3.ZERO
# Live planar velocity the skate-in launches from (period / stoppage faceoffs) so
# the glide flows out of the player's momentum instead of hard-stopping at the
# whistle. Zero for snap-from-rest starts (bench intro / post-goal staging).
var _approach_v0: Vector3 = Vector3.ZERO
# Below this planar speed a skate-in is treated as a snap-from-rest start (reset
# gait + square up to the path); at or above it, momentum is preserved.
const _APPROACH_CARRY_MIN: float = 0.3
# Reused so the per-tick skate-in render doesn't allocate an InputState.
var _approach_input: InputState = InputState.new()


# True during the FACEOFF_PREP countdown — the gait floors its stance crouch
# and staggers the feet (see faceoff_stance / faceoff_split_deg).
func is_faceoff_ready() -> bool:
	return _game_state_has_faceoff_prep and _game_state.is_faceoff_prep()


func start_celebration(duration: float) -> void:
	_celebration_total = maxf(duration, 0.001)
	_celebration_timer = _celebration_total


func is_celebrating() -> bool:
	return _celebration_timer > 0.0


# 0..1 progress through the celebration window (0 when idle). Read by the gait
# for the leg bounce, matching the `t` the raised-stick pose runs on.
func celebration_progress() -> float:
	if _celebration_timer <= 0.0:
		return 0.0
	return 1.0 - _celebration_timer / _celebration_total


# Ages the celebration window. Called from SkaterSkatingCoordinator.apply —
# the one per-tick pass that runs on EVERY path (local sim, host-driven
# remote, wire-fed remote, replay) — so the timer counts down even for
# skaters this machine doesn't simulate (the timer starts on every machine;
# see GameManager._trigger_scorer_celebration).
func tick_celebration(delta: float) -> void:
	if _celebration_timer > 0.0:
		_celebration_timer = maxf(_celebration_timer - delta, 0.0)


# Check-delivery body pose: the hitter drives the shoulder through the contact.
# Fired from the host-authoritative body_check_landed broadcast (and the replay
# event dispatcher), so it reads identically on every machine — same contract
# as the burst/thud. `hit_dir` is the world-space direction the victim was
# shoved (attacker → victim); `intensity` is the 0..1 VFX hardness.
func start_check_drive(hit_dir: Vector3, intensity: float) -> void:
	_skating.start_check_drive(hit_dir, intensity)

# ── Setup ─────────────────────────────────────────────────────────────────────
func setup(assigned_skater: Skater, assigned_puck: Puck, game_state: Node) -> void:
	skater = assigned_skater
	puck = assigned_puck
	_game_state = game_state
	_is_host = game_state.is_host()
	# Cached so the per-tick gait can ask about the faceoff phase without a
	# has_method() call at 120 Hz (test stubs may not implement it).
	_game_state_has_faceoff_prep = game_state.has_method("is_faceoff_prep")
	_game_state_has_period_break = game_state.has_method("is_period_break")
	process_physics_priority = -1  # Run before Skater.move_and_slide
	skater.body_checked_player.connect(_on_body_checked_player)
	skater.body_check_received.connect(_on_body_check_received)
	_ik.setup(skater, self)
	_shot_pose.setup(skater, _sm, _aiming, _ik, self)
	var _cb := SkaterStateMachine.Callbacks.new()
	_cb.apply_blade_from_mouse = _ik.apply_blade_from_mouse
	_cb.apply_wrister_aim_blade = _apply_wrister_aim_blade
	_cb.apply_slapper_blade_position = _shot_pose.apply_slapper_blade_position
	_cb.apply_block_blade_position = _shot_pose.apply_block_blade_position
	_cb.apply_wrister_follow_through = _shot_pose.apply_wrister_follow_through
	_cb.apply_slapper_follow_through = _shot_pose.apply_slapper_follow_through
	_cb.enter_shot_block = _enter_shot_block
	_cb.enter_slapper_charge = _enter_slapper_charge
	_cb.transition_to_skating = _transition_to_skating
	_cb.release_wrister = _release_wrister
	_cb.fire_quick_pass = _fire_quick_pass
	_cb.release_slapper = _release_slapper
	_cb.try_one_timer_release = _try_one_timer_release
	_cb.update_wrister_charge = _update_wrister_charge
	_cb.update_slapper_charge = _update_slapper_charge
	_cb.apply_slapper_velocity_drag = _apply_slapper_velocity_drag
	_cb.apply_block_movement = _apply_block_movement
	_sm.setup(_cb, _aiming)
	_pose.setup(skater, _sm, _aiming, self, _skating)
	_skating.setup(skater, _sm, self)
	# Cosmetic pose (leg gait / head / off-hand IK) now runs at render rate in
	# Skater._process instead of every physics tick — it feeds only meshes, not
	# the blade world frame. RemoteController overrides _render_pose_update to
	# drop head tracking (a wire-fed body has no cursor aim).
	skater.render_pose_update = _render_pose_update

# Reach ROM is derived from arm length, not an independent tunable. The
# forehand side is shoulder-joint-limited (about 56% of arm length — the top
# hand can't cross the body very far), a simple anatomical ratio. The
# backhand side is arm-EXTENSION-limited and solved from the chain geometry
# in apply_attributes: the hand rides at hand_rest_y (a fixed drop below the
# shoulder), so the farthest it can sit is sqrt(arm_eff² − drop²) with
# arm_eff = arm × rom_arm_extension. Deriving it this way guarantees no
# reachable pose out-reaches the arm (the forearm never draws stretched) and
# gives tall players disproportionately more reach than short ones — long
# arms matter most at full extension, which is the realistic shape.
const _ROM_FOREHAND_OF_ARM: float = 0.5625


# ── Player Attributes ─────────────────────────────────────────────────────────
# Base values captured on the first apply_attributes() call so subsequent
# applies (offline free-play picker re-applies) recompute from the original
# @export defaults instead of compounding with the previous multiplier.
# All tuning tables live on PlayerAttributes — see that file for the system
# overview and how to add new scalings.
var _attr_base_captured: bool = false
var _base_thrust:                       float = 0.0
var _base_max_speed:                    float = 0.0
var _base_facing_drag_speed:            float = 0.0
var _base_facing_drag_speed_braking:    float = 0.0
var _base_brake_multiplier:             float = 0.0
var _base_friction_drag:                float = 0.0
var _base_lateral_grip:                 float = 0.0
var _base_min_wrister_power:            float = 0.0
var _base_max_wrister_power:            float = 0.0
var _base_quick_pass_power:             float = 0.0
var _base_min_slapper_power:            float = 0.0
var _base_max_slapper_power:            float = 0.0
var _base_max_slapper_charge_time:      float = 0.0
var _base_max_blade_speed:              float = 0.0
var _base_max_blade_accel:              float = 0.0
var _base_puck_carry_speed_multiplier:  float = 0.0
var _base_stick_length:                 float = 0.0
var _base_wrister_full_stroke_travel:   float = 0.0
var _base_skater_upper_arm_length:      float = 0.0
var _base_skater_forearm_length:        float = 0.0
var _base_skater_shoulder_offset:       float = 0.0
var _base_skater_shoulder_height:       float = 0.0
var _base_skater_weight:                float = 0.0
var _base_skater_body_check_brace_resistance: float = 0.0
var _base_skater_body_check_transfer:   float = 0.0
var _base_skater_collision_radius:      float = 0.0
var _base_skater_collision_height:      float = 0.0
var _base_backhand_power_coefficient:   float = 0.0
# Blade face-angle cap (tan) for the release math — set per-build from the
# curve gear in apply_attributes; defaults to the universal 45° cap.
var loft_tan_max: float = ShotMechanics.MAX_LOFT_RATIO
var _base_sprint_drain_per_sec:         float = 0.0
var _base_stamina_regen_per_sec:        float = 0.0
var _base_hand_rest_y:                  float = 0.0
var _base_hand_y_max:                   float = 0.0


# Snapshot this body's attribute-scaled capabilities as the bot AI models them —
# read off the SAME scaled fields the physics drives with (set by
# apply_attributes), so the AI never disagrees with the body. Used two ways: a
# bot's self-model (AIController.apply_attributes) and PlayerRegistry's per-peer
# caps_by_peer (every player, so other bots read real builds). Cheap and
# allocation-light; called only on apply / spawn, never per tick.
func build_ai_caps() -> AISkaterCaps:
	var caps := AISkaterCaps.new()
	caps.max_speed = max_speed
	caps.sprint_speed_mult = sprint_max_speed_multiplier
	caps.max_accel = thrust
	caps.blade_span = stick_length + GameRules.DEFAULT_BLADE_LENGTH_M
	caps.stick_reach = stick_length
	# Fully-extended body→blade reach (arm ROM displacement + stick + blade). Read
	# off the same scaled geometry the body uses, so the host's client-blade
	# anti-cheat clamp bounds against this build's real reach, not the league
	# default. See AISkaterCaps.max_blade_reach / the claim resolvers.
	caps.max_blade_reach = stick_length + GameRules.DEFAULT_BLADE_LENGTH_M + rom_backhand_reach_max
	caps.wrister_shot_speed = max_wrister_power
	caps.blade_speed = max_blade_speed
	caps.loft_tan_max = loft_tan_max
	caps.lateral_grip = lateral_grip
	caps.backhand_power_coefficient = backhand_power_coefficient
	# Handle reach scales with the blade lever: max_blade_speed / its base is
	# exactly the lever ratio (attributes v4 — reach + stick length), so a
	# longer lever protects the puck further out. _base is captured on the
	# first apply_attributes (always run before this).
	if _base_max_blade_speed > 0.001:
		caps.handle_reach = AIActionScoring.EVADE_CARRY_HANDLE_M \
				* (max_blade_speed / _base_max_blade_speed)
	# Blade reach cone: the exact IK gate SkaterPoseCoordinator.apply_facing
	# enforces (ROM backhand + torso twist), so the bot models the same off-facing
	# reach the body actually has. Fixed geometry — not attribute-scaled.
	caps.reach_cone_half_angle = deg_to_rad(
			rom_backhand_angle_max_deg + upper_body_max_twist_deg)
	# Facing turn rate: the baseline 6.0 rad/s approximation scaled by real Agility.
	# facing_drag_speed is base × agility_mult, so its ratio to base IS the Agility
	# multiplier — a nimbler bot turns (and prices a back-wedge aim) faster.
	if _base_facing_drag_speed > 0.001:
		caps.facing_turn_rate *= facing_drag_speed / _base_facing_drag_speed
	if skater != null:
		caps.weight = skater.weight
		caps.body_check_transfer = skater.body_check_transfer
		caps.body_check_brace = skater.body_check_brace_resistance
	return caps


# Modulates the controller and skater tuning fields from a PlayerAttributes
# resource. Safe to call multiple times — the first call snapshots the
# shipped @export defaults, every call recomputes live = base × multiplier.
# Called once at spawn and again whenever the local player changes picks in
# offline free-play (online matches lock attributes at join time).
func apply_attributes(attrs: PlayerAttributes) -> void:
	if attrs == null or skater == null:
		return
	if not _attr_base_captured:
		_capture_attribute_bases()
	var m_height:  float = attrs.height_mult()
	# Skating splits into THREE height-routed sub-levers: Speed owns top-end
	# velocity (max_speed; the sprint ceiling below scales off it), Acceleration
	# owns thrust (forward burst — small-favored, floored above agility so a big
	# weak-skater can still drive straight), and Agility owns the turn/brake/edge
	# handling. Splitting burst off top speed lets a small player be explosive and
	# shifty without owning the top gear, and a big weak-skater feel bad in the
	# TURN rather than glued to the ice.
	var m_agility: float = attrs.agility_mult()
	max_speed = _base_max_speed * attrs.speed_mult()
	thrust    = _base_thrust    * attrs.accel_mult()
	facing_drag_speed           = _base_facing_drag_speed           * m_agility
	facing_drag_speed_braking   = _base_facing_drag_speed_braking   * m_agility
	brake_multiplier            = _base_brake_multiplier            * m_agility
	# Lateral grip is where agility's turn promise physically lands: it scales
	# the perpendicular thrust authority in the movement core, so the emergent
	# turn radius v²/(grip·a_perp) genuinely widens for a heavy/tall build and
	# tightens for a lean/small one (the facing/brake terms above are the feel
	# of quickness; this is the arc itself).
	lateral_grip                = _base_lateral_grip                * m_agility
	# The sprint CEILING is Speed-attributed (grounded to the 20–25 mph NHL burst
	# band), replacing the old flat multiplier that handed every skater the same
	# top gear. A real burner opens a gear a plodder simply doesn't have — that's
	# where puck-carrier separation lives now that cruise speeds are near-uniform.
	sprint_max_speed_multiplier = attrs.sprint_ceiling_mult()
	# friction_drag is velocity-proportional drag — scaling it inversely
	# with Agility gives agile players the "good edges" feel: less momentum
	# leaks through the blades during a cut, so they carry more speed out
	# of turns. Lateral / backward thrust multipliers are universal — every
	# skater shares the same forward > lateral > backward shape; what makes
	# Slick agile is how cleanly they transition between those directions.
	friction_drag               = _base_friction_drag               * attrs.agility_glide_mult()
	# Carry speed retention is a small, Speed-eased tax (attributes v4 folded the
	# old Hands term into the base — no hands lever by constitution). The real
	# cost of carrying at speed is the 1.6x sprint stamina drain (StaminaRules),
	# not an intrinsic slowdown — so a fast carrier CAN separate, in a
	# stamina-limited burst. This is a computed value, not a base×mult, so it's
	# set directly.
	puck_carry_speed_multiplier = attrs.carry_speed_mult()
	# Hands has no lever by constitution (attributes v4 — "your hands are you"):
	# the blade caps derive from LEVER GEOMETRY below, after the reach/stick
	# rescale computes this build's actual sweep radius. Backhand technique is
	# the human; what leans the coefficient is the BLADE's shape — the curve
	# gear slot (closed relaxes toward, never past, forehand parity; open
	# deepens the penalty).
	backhand_power_coefficient  = _base_backhand_power_coefficient * attrs.curve_backhand_mult()
	# Curve elevation is the blade FACE ANGLE: a launch-angle cap in the
	# release math (ShotMechanics.loft_y), never a lean on the loft speeds —
	# so at pace every curve reaches the same per-level apex (the crossbar
	# ceiling holds for all blades) while the soft in-tight roof is
	# face-gated. Open (45°) equals the universal MAX_LOFT_RATIO cap, i.e.
	# the pre-curve shipped behavior bit-exact.
	loft_tan_max = attrs.curve_loft_tan()
	# Shot scales the CHARGED-shot ceiling (wrister max + both slapper pools) and
	# the wrister charge EFFORT — but NOT the quick/uncharged snap. quick_pass
	# doubles as pass speed, so it stays baseline for everyone (reliable passing);
	# min_wrister is held at baseline too — it's the soft-touch floor (a slow
	# sweep is a touch pass, deliberately BELOW the snap speed), and everyone's
	# touch should be equally soft. So Shot = "what a charge buys you, and how
	# fast you can charge it."
	var m_shot_ceil: float = attrs.shot_power_mult()
	min_wrister_power = _base_min_wrister_power              # baseline floor (= snap)
	max_wrister_power = _base_max_wrister_power * m_shot_ceil
	quick_pass_power  = _base_quick_pass_power               # baseline — also the pass speed
	min_slapper_power = _base_min_slapper_power * m_shot_ceil
	max_slapper_power = _base_max_slapper_power * m_shot_ceil
	# Slapper wind-up time keeps the gentler shot_charge curve. (Wrister power is
	# pure mouse speed — no charge distance — so Shot only scales its ceiling.)
	max_slapper_charge_time     = _base_max_slapper_charge_time     * attrs.shot_charge_mult()
	# Physical battles are Checking-decided; height is only a MINOR mass edge, not a
	# substitute. `weight` (mass, the weight_ratio — hard to MOVE) is a small
	# height lever; Checking sets delivery (how hard you DELIVER a check, tall-
	# favored) and brace (how hard to PUT DOWN, tier-dominant — a big weak-Checking
	# build is genuinely hittable). Brace is inverse: lower = better resistance.
	skater.weight                      = _base_skater_weight                  * attrs.mass_mult()
	skater.body_check_transfer         = _base_skater_body_check_transfer     * attrs.check_delivery_mult()
	skater.body_check_brace_resistance = _base_skater_body_check_brace_resistance * attrs.brace_mult()
	# Stamina is height-flavored metabolism (no attribute touches it): a small player
	# has a SHALLOWER pool (drains faster) but recovers FAST, a big player has a
	# DEEP pool (drains slow) but recovers SLOWLY. So small = short repeatable
	# bursts, big = one long drive then a slow refill. Both scales ride height. The
	# cached stamina config is dropped below so the next tick rebuilds from these rates.
	sprint_drain_per_sec  = _base_sprint_drain_per_sec  * attrs.stamina_drain_mult()
	stamina_regen_per_sec = _base_stamina_regen_per_sec * attrs.stamina_regen_mult()
	# Arms scale with actual height (the dedicated height_mult,
	# tighter than the gameplay size_mult) — keeps proportions realistic so
	# a taller player has correspondingly longer arms (and ROM) rather than
	# looking awkward with baseline-length limbs. The stick is equipment, not
		# anatomy, so it rides a GENTLER curve (stick_len_mult, ~0.65x the height
		# deviation): real played stick lengths track height only loosely, so a
		# small player keeps a near-full-size stick. Total blade reach is still
		# arm-driven ROM + stick (top_hand_ik FAR regime), so the eased stick is
		# not a proportionally eased reach. update_stick_mesh() and
	# the arm bone wrappers recompute visuals from these every frame, so no
	# separate visual pass is needed.
	stick_length              = _base_stick_length              * attrs.stick_len_mult()
	skater.upper_arm_length   = _base_skater_upper_arm_length   * m_height
	skater.forearm_length     = _base_skater_forearm_length     * m_height
	# Shoulder anchors track the visual shoulder balls, which the appearance
	# pass repositions from the same multipliers (y rides height, x rides
	# torso bulk) — the drawn arm and the IK stay rooted at the same point on
	# every build. Must run BEFORE the hand/ROM derivation below reads
	# shoulder_height.
	skater.set_shoulder_anchor(
			_base_skater_shoulder_offset * attrs.torso_bulk_mult(),
			_base_skater_shoulder_height * m_height)
	# Hand heights scale with the skeleton: the appearance pass scales the
	# whole mesh rig about the ice plane (legs included — the upper body
	# rides at height_mult × 1.0 m world), so the hand's LOCAL rest height
	# scales by the same factor to keep the hand at the same point on every
	# body (shoulder-to-hand drop = 0.50 m × height). Same for the CLOSE-
	# regime ceiling. Near-zero gameplay cost: raising the hand shortens the
	# stick's horizontal footprint but lengthens the derived backhand ROM
	# below at almost exactly 1:1, so blade rim reach barely moves.
	hand_rest_y = _base_hand_rest_y * m_height
	hand_y_max  = _base_hand_y_max  * m_height
	# The gait's crouch drop rides the same leg scale the appearance pass
	# applies to the leg pivot chain, so flexed knees sink a tall build
	# proportionally deeper.
	_skating.leg_scale = m_height
	# Reach ROM is a derived property of arm length — forehand from the
	# anatomical cross-body ratio, backhand from the chain geometry (see the
	# _ROM_FOREHAND_OF_ARM doc block). Bigger arms naturally yield more reach
	# without being an independent attribute axis: with the whole chain
	# (arm and shoulder-to-hand drop) scaling by height, the derived reach
	# scales by height too. Long arms matter most at full extension.
	var arm_total: float = skater.upper_arm_length + skater.forearm_length
	rom_forehand_reach_max    = arm_total * _ROM_FOREHAND_OF_ARM
	var arm_eff: float = arm_total * rom_arm_extension
	var reach_drop: float = skater.shoulder_height - hand_rest_y
	rom_backhand_reach_max    = sqrt(maxf(arm_eff * arm_eff - reach_drop * reach_drop, 0.0))
	# The wrister travel gate's full-stroke reference scales with the blade's
	# actual sweep radius (stick + arm-driven ROM, both just rescaled above), so
	# "a full stroke" is the same fraction of each build's own reachable arc —
	# otherwise a flat meters constant would leak reach (a height tell) into the
	# wrister ceiling (short builds sweep less absolute path for the same honest
	# stroke).
	var base_sweep_radius: float = _base_stick_length + \
			(_base_skater_upper_arm_length + _base_skater_forearm_length) * _ROM_FOREHAND_OF_ARM
	var sweep_radius: float = stick_length + rom_forehand_reach_max
	# The runway = sweep-normalized full stroke × the gear lean (whippy flex /
	# open curve compress it — "max power with less real estate consumed";
	# stiff flex extends it). Quick-release gear beats the goalie by emitting
	# LESS WIND-UP EVIDENCE, not by a stat the goalie is told about.
	wrister_full_stroke_travel = _base_wrister_full_stroke_travel \
			* sweep_radius / maxf(base_sweep_radius, 0.001) \
			* attrs.wrister_runway_mult()
	# Blade caps derive from the same LEVER (constitution: geometry, never a
	# fidelity table). Tip speed rides the lever linearly — v = ω·L, the same
	# angular gesture sweeps a longer blade faster in m/s, so every build's
	# wrists are heard at the same ANGULAR fidelity (traverse time across your
	# own reach envelope stays ~flat; the calibration test pins it). The
	# acceleration cap (inertia) falls with lever^k — I ∝ mL², softened to the
	# authored blade_inertia_exponent — so the long lever sweeps but can't cut
	# back, the short lever is the scalpel. Base accel 0 = inertia disabled.
	# The ratio normalizes to the NEUTRAL build's lever (6'1"/standard), NOT the
	# mesh-native base geometry (the reach-1.0 anchor is 5'10", below the
	# gameplay neutral): neutral identity demands the neutral build's caps equal
	# the shipped exports exactly.
	var neutral_attrs := PlayerAttributes.all_average()
	var neutral_sweep: float = _base_stick_length * neutral_attrs.stick_len_mult() \
			+ (_base_skater_upper_arm_length + _base_skater_forearm_length) \
			* neutral_attrs.height_mult() * _ROM_FOREHAND_OF_ARM
	var lever_ratio: float = sweep_radius / maxf(neutral_sweep, 0.001)
	max_blade_speed = _base_max_blade_speed * lever_ratio
	max_blade_accel = _base_max_blade_accel / pow(lever_ratio, blade_inertia_exponent) \
			if _base_max_blade_accel > 0.0 else 0.0
	# Hitbox: cylinder radius scales with height (frame width — a taller player is
	# a bit wider). Height is held CONSTANT for every player — a taller cylinder
	# grew tall enough to touch several faces of the concave net/goal geometry at
	# once and wedge the body in a corner. The visual mesh still scales on Y
	# (appearance coordinator), so big players still look tall; only the physics
	# hitbox height is fixed. Skater._ready() duplicated the shape so this mutation
	# is per-instance and won't leak.
	var col: CollisionShape3D = skater.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null:
		var cyl: CylinderShape3D = col.shape as CylinderShape3D
		if cyl != null:
			cyl.radius = _base_skater_collision_radius * attrs.radius_mult()
			cyl.height = _base_skater_collision_height
	# Attribute scaling rewrote the exports the cached configs were built
	# from — drop them so the next tick rebuilds with the new values.
	_ik.invalidate_configs()
	_cached_move_cfg = null
	_cached_block_move_cfg = null
	_cached_stamina_cfg = null
	_cached_wrister_cfg = null
	_cached_slapper_cfg = null
	skater.apply_appearance(attrs)


func _capture_attribute_bases() -> void:
	_base_thrust                       = thrust
	_base_max_speed                    = max_speed
	_base_facing_drag_speed            = facing_drag_speed
	_base_facing_drag_speed_braking    = facing_drag_speed_braking
	_base_brake_multiplier             = brake_multiplier
	_base_friction_drag                = friction_drag
	_base_lateral_grip                 = lateral_grip
	_base_min_wrister_power            = min_wrister_power
	_base_max_wrister_power            = max_wrister_power
	_base_quick_pass_power             = quick_pass_power
	_base_min_slapper_power            = min_slapper_power
	_base_max_slapper_power            = max_slapper_power
	_base_max_slapper_charge_time      = max_slapper_charge_time
	_base_max_blade_speed              = max_blade_speed
	_base_max_blade_accel              = max_blade_accel
	_base_backhand_power_coefficient   = backhand_power_coefficient
	_base_sprint_drain_per_sec         = sprint_drain_per_sec
	_base_stamina_regen_per_sec        = stamina_regen_per_sec
	_base_puck_carry_speed_multiplier  = puck_carry_speed_multiplier
	_base_stick_length                 = stick_length
	_base_wrister_full_stroke_travel   = wrister_full_stroke_travel
	_base_hand_rest_y                  = hand_rest_y
	_base_hand_y_max                   = hand_y_max
	_base_skater_upper_arm_length      = skater.upper_arm_length
	_base_skater_forearm_length        = skater.forearm_length
	_base_skater_shoulder_offset       = skater.shoulder_offset
	_base_skater_shoulder_height       = skater.shoulder_height
	_base_skater_weight                       = skater.weight
	_base_skater_body_check_transfer          = skater.body_check_transfer
	_base_skater_body_check_brace_resistance  = skater.body_check_brace_resistance
	var col: CollisionShape3D = skater.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null:
		var cyl: CylinderShape3D = col.shape as CylinderShape3D
		if cyl != null:
			_base_skater_collision_radius = cyl.radius
			_base_skater_collision_height = cyl.height
	_attr_base_captured = true


func _on_body_checked_player(victim: Skater, impact_force: float, hit_direction: Vector3) -> void:
	if not _is_host:
		return
	puck.on_body_check(skater, victim, impact_force, hit_direction)

# This skater just absorbed a check (victim-only signal). Host sets the stagger
# window + stamina bite scaled by hit strength, then broadcasts stagger_timer /
# stamina via fill_network_state; clients receive the resolved values and (for the
# local player) re-derive the decay through reconcile replay. `max` so a weaker
# follow-up never shortens an in-flight stagger.
#
# Client-side prediction (Lever C): the LOCAL victim also fires this (via the
# Lever-D kept transfer branch), so predict its thrust stagger immediately off the
# same transfer impulse instead of waiting a full round-trip for the host's
# stagger_timer snapshot. Stamina stays host-only (predicting a pool drain that
# might be refunded is more jarring than a brief thrust dip). Reconcile snaps
# stagger_timer to the server value and re-derives decay, so a misprediction
# self-heals in one reconcile — exactly how the host-set stagger is already
# treated. Remote bodies on a client still defer to the snapshot (early return).
func _on_body_check_received(impulse: Vector3) -> void:
	var impulse_magnitude: float = impulse.length()
	# Capture the recoil direction (body frame) so the torso reels the way the
	# hit shoved it — see SkaterPoseCoordinator._apply_lean. Set on the local
	# victim AND the host (both drive the stagger); remotes keep the default
	# backward recoil (they get stagger_timer off the wire, not the direction).
	var local_impulse: Vector3 = skater.global_transform.basis.inverse() * impulse
	var recoil_xz: Vector2 = Vector2(local_impulse.x, local_impulse.z)
	if recoil_xz.length() > 0.001:
		stagger_recoil_dir = recoil_xz.normalized()
	var cfg: BodyCheckRules.Config = _body_check_config()
	# Knockdown rides the same "extend, never shorten" rule as stagger and is set on
	# both the host and the local victim's prediction — so a downed local player goes
	# down immediately, and reconcile snaps knockdown_timer to the host value.
	var knockdown_add: float = BodyCheckRules.knockdown_seconds_from_impulse(impulse_magnitude, cfg)
	if not _is_host:
		if skater.is_local_skater:
			stagger_timer = maxf(stagger_timer,
					BodyCheckRules.stagger_seconds_from_impulse(impulse_magnitude, cfg))
			knockdown_timer = maxf(knockdown_timer, knockdown_add)
		return
	knockdown_timer = maxf(knockdown_timer, knockdown_add)
	var add: float = BodyCheckRules.stagger_seconds_from_impulse(impulse_magnitude, cfg)
	# Only extend (never shorten) the stagger window, and only bite stamina when
	# this hit is harder than the residual — incremental_stamina_drain handles the
	# sustained-contact case so a grind doesn't empty the pool every tick.
	if add <= stagger_timer:
		return
	stamina = maxf(stamina - BodyCheckRules.incremental_stamina_drain(stagger_timer, impulse_magnitude, cfg), 0.0)
	stagger_timer = add


# ── Entry Point ───────────────────────────────────────────────────────────────
# Whether this skater is committing to a deliberate deflect this tick. Base
# behaviour (human players, local and remote-on-host): holding the DEFLECT button
# (stick_lift / Q) without the puck. The loft level (scroll) then shapes it —
# FLAT grounded redirect, LOW grounded tip up, HIGH knock an airborne puck down /
# stick-lift (reach follows blade_can_interact; direction from Puck.apply_blade_deflect).
# AIController
# overrides this to always-false — bots don't deliberate-deflect; their
# one-timers hold the SLAP button off-puck (the real slapper charge + pickup
# zone — the only one-timer path on_puck_picked_up_network supports: a held
# wrister's state is force-reset to SKATING_WITH_PUCK on pickup, so a wrister
# release edge can never fire on a caught feed).
func _wants_deflect(input: InputState) -> bool:
	return input.stick_lift_held and not has_puck


func _process_input(input: InputState, delta: float) -> void:
	# Stamp movement intent for the cosmetic layers (gait glide / intent
	# crossovers / brake-gated hockey stop). Local, bot, and host-side client
	# simulation all funnel through here with real inputs; client-rendered
	# remotes get the same fields off the wire in RemoteController. Gated by
	# the SAME deadzone the movement physics uses, so "trying to move" means
	# the same thing to the animation as to the thrust — bot steering emits
	# small residual vectors at rest (potential-field repels never fully
	# cancel) that would otherwise read as a perpetual dig-in chop, and the
	# wire octant would inflate them to unit length on remote clients.
	_self_posing = false  # main live path delegates cosmetics to the render hook
	skater.move_intent = input.move_vector \
			if input.move_vector.length() > move_deadzone else Vector2.ZERO
	skater.brake_intent = input.brake
	# Snapshot the blade's current contact point before any IK mutation runs
	# this tick. The host's swept-segment pickup/poke test (PuckController._check_interactions,
	# priority 1) reads this later in the tick as `blade_prev`; combined with the
	# post-IK + post-move_and_slide `blade_curr`, the segment spans both the IK
	# sweep and the body motion. Capturing here in every controller path
	# (Local / Remote / AI) keeps the test consistent across input sources.
	skater.capture_prev_blade_contact()
	# Feed the shared host-clock stamp to an active faceoff draw so its timing is
	# judged ping-neutrally (see Skater.set_draw_input_time). Only during a draw.
	if skater.is_draw_tracking():
		skater.set_draw_input_time(input.host_timestamp)
	_elevation_level = input.elevation_level
	skater.elevation_level = _elevation_level
	_current_aim_world = input.mouse_world_pos

	# Deliberate-deflect intent (see Skater.deflect_intent). Holding the deflect
	# button (Q) without the puck commits to redirecting a loose puck off the
	# blade rather than corralling it; carrying means Q is the nudge tap instead,
	# so it's gated on NOT having the puck. The host reads this in
	# PuckController._check_interactions for every skater it simulates, and the
	# loft level shapes the redirect (grounded / up / down).
	skater.deflect_intent = _wants_deflect(input)

	# Blade lift (off the ice) is now a CONSEQUENCE of deflecting at HIGH loft:
	# the raised blade reaches higher airborne pucks (to knock them down) and is
	# what lets a stick-lift hook under an opponent's shaft. FLAT/LOW deflects keep
	# the blade grounded so they can still meet pucks on the ice (a LOW deflect
	# tips a grounded shot UP). A forced lift (an opponent hooked under your stick)
	# overrides regardless of possession and is what dislodges a carried puck.
	skater.blade_up = (skater.deflect_intent and _elevation_level >= ShotMechanics.ELEVATION_HIGH) \
			or skater.is_forced_lift_active()

	# Nudge: a stick-lift TAP while carrying pushes the puck off the blade as a
	# soft self-pass (nutmeg setup). Edge-triggered and gated to plain carry so
	# it never fires mid-charge; the is_replaying guard inside keeps it from
	# re-emitting during reconcile (same discipline as _do_release).
	if input.stick_lift_pressed and has_puck and _sm.get_state() == State.SKATING_WITH_PUCK:
		_nudge()

	_apply_movement(input, delta)
	_pose.apply_velocity_lean(delta)
	_pose.apply_facing(input, delta)
	_apply_state(input, delta)
	# Keep the PUCK ITSELF out of the net. The blade net-clamp (in apply_blade_
	# from_mouse) keeps the BLADE out, but a carried puck pins to a carry offset
	# OFF the blade (Skater.get_carry_target_global), a separate point the blade
	# clamp never validated — so a stick reaching from behind/beside could drag
	# the pinned puck into the net even with the blade reading legal. Runs after
	# _apply_state so it sees this tick's final blade pose.
	_clamp_carry_pin_from_net()
	# Mirror the state machine into the replicated field on every simulated
	# tick, AFTER _apply_state so same-tick transitions are visible to the
	# cosmetic consumers below (gait shot stance) and to Skater._process (stick
	# flex). Local and AI controllers also stamp this after their tick, but the
	# host-side client-simulation path (RemoteController._drive_from_input)
	# previously never stamped it, so host-rendered client skaters froze at a
	# stale shot state.
	skater.current_shot_state = _sm.get_state() as int
	# Save blade/hand world positions before upper body rotation. After the body
	# rotates toward the blade, re-expressing these in the new local frame gives
	# the bottom-hand IK the post-rotation geometry — so arm reach is evaluated
	# as if the body has fully caught up, independent of lerp speed.
	#
	# Skip the preservation during slapper wind-up: the slapper pose is authored
	# in upper-body-local space, so we WANT the stick to travel with the coiling
	# torso (otherwise the body rotates underneath a stationary hand and the
	# coil is invisible).
	var pre_state: SkaterStateMachine.State = _sm.get_state()
	var is_slapper_charge: bool = (
			pre_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK
			or pre_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK)
	var blade_world_pre: Vector3
	var hand_world_pre: Vector3
	if not is_slapper_charge:
		blade_world_pre = skater.upper_body_to_global(skater.get_blade_position())
		hand_world_pre = skater.upper_body_to_global(skater.get_top_hand_position())
	_pose.apply_upper_body(delta)
	if not is_slapper_charge:
		skater.set_top_hand_position(skater.upper_body_to_local(hand_world_pre))
		skater.set_blade_position(skater.upper_body_to_local(blade_world_pre))
	# Head tracking, off-hand IK, and the leg gait moved to render rate
	# (Skater.render_pose_update / _render_pose_update) — they feed only meshes,
	# not the blade world frame, so they don't belong in the 120 Hz + reconcile-
	# replay path. Stick/arm mesh rebuild already lives in Skater._process too.
	if not is_replaying:
		_pose.update_angular_velocities(delta)
		# Age the goal-celebration timer at physics rate. It used to ride the gait
		# pass, but the gait is render-rate + visibility-gated now, so the timer
		# owns its own physics tick here (real ticks only — it must not re-decrement
		# through reconcile replay) so it stays deterministic and never freezes for
		# an off-screen scorer.
		tick_celebration(delta)
		# Goal celebration: the scorer raises the stick. Overrides the hand/
		# blade pose the tick just placed — cosmetic-only (pickup is locked
		# through GOAL_CELEBRATION), real ticks only, and gated to plain skating
		# so a whiffed shot's follow-through isn't fought over. The render off-hand
		# IK yields while this is active (see _render_pose_update) so the fist pump
		# isn't clobbered a frame later.
		if _celebration_timer > 0.0:
			var cel_state: SkaterStateMachine.State = _sm.get_state()
			if cel_state == SkaterStateMachine.State.SKATING_WITH_PUCK \
					or cel_state == SkaterStateMachine.State.SKATING_WITHOUT_PUCK:
				_shot_pose.apply_celebration_pose(1.0 - _celebration_timer / _celebration_total)


# Render-rate cosmetic pose pass, registered on the skater and invoked once per
# rendered frame from Skater._process (visibility-gated). Runs the purely-cosmetic
# passes that used to sit in the 120 Hz physics tick: the leg gait, head tracking
# (off the last-seen aim), and the off-hand grip IK. None feed the blade world
# frame, so running them at render rate can't affect pickup or reconcile. Local
# and AI controllers use this base; RemoteController overrides it to drop head
# tracking (a wire-fed body has no cursor aim).
func _render_pose_update(delta: float) -> void:
	if skater == null or _self_posing:
		return
	_skating.apply(delta)
	_pose.apply_head_tracking_aim(_current_aim_world, delta)
	# During a goal celebration the physics tick places the off-hand fist pump
	# (apply_celebration_pose); yield so the base grip IK doesn't clobber it.
	if _celebration_timer <= 0.0:
		_ik.update_bottom_hand()


# Aim-only blade update for FACEOFF_PREP: drives the blade target from the
# mouse, twists the upper body and head to follow it, and refreshes the
# dependent IK + visual meshes. Skips movement, lower-body facing rotation
# (the skater stays squared up to the dot), and state-machine dispatch.
# Callers must already have confirmed the phase allows blade aim during a
# locked phase.
func apply_blade_aim_only(input: InputState, delta: float) -> void:
	# Movement is locked — whatever keys are down, nothing is being tried.
	skater.move_intent = Vector2.ZERO
	skater.brake_intent = false
	# Feed the shared host-clock stamp to the faceoff draw (this is the countdown
	# wind-up/rip path), so its timing is judged ping-neutrally.
	if skater.is_draw_tracking():
		skater.set_draw_input_time(input.host_timestamp)
	_ik.apply_blade_from_mouse(input, delta)
	# Preserve blade/hand world positions across the upper-body rotation —
	# same dance as _process_input. Without it the blade slides sideways as
	# the torso twists, decoupling the stick from where the player aimed it.
	var blade_world_pre: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
	var hand_world_pre: Vector3 = skater.upper_body_to_global(skater.get_top_hand_position())
	_pose.apply_upper_body(delta)
	_pose.apply_head_tracking(input, delta)
	skater.set_top_hand_position(skater.upper_body_to_local(hand_world_pre))
	skater.set_blade_position(skater.upper_body_to_local(blade_world_pre))
	# This locked-phase path poses its own gait ready-stance + off-hand (a brief
	# countdown, not the hot path); the render hook yields to it (see _self_posing).
	_self_posing = true
	_skating.apply(delta)
	_ik.update_bottom_hand()


# ── Network State ─────────────────────────────────────────────────────────────
# Returns the typed network state object. Flattening to Array happens at the
# RPC boundary (GameManager.get_world_state), not here.
func get_network_state() -> SkaterNetworkState:
	var state := SkaterNetworkState.new()
	fill_network_state(state)
	return state

# Writes the current state into a caller-owned instance. StateBufferManager
# fills its pre-allocated ring slots through this every physics tick — allocating a
# fresh state per capture (get_network_state) defeated the ring's purpose.
func fill_network_state(state: SkaterNetworkState) -> void:
	state.position = skater.global_position
	state.velocity = skater.velocity
	state.blade_position = skater.get_blade_position()
	state.blade_contact_world = skater.get_blade_contact_global()
	state.top_hand_position = skater.get_top_hand_position()
	state.upper_body_rotation_y = skater.get_upper_body_rotation()
	state.facing = skater.get_facing()
	state.facing_angular_velocity = _pose.facing_angular_velocity
	state.upper_body_angular_velocity = _pose.upper_body_angular_velocity
	state.last_processed_host_timestamp = last_processed_host_timestamp
	state.is_ghost = skater.is_ghost
	state.elevation_level = skater.elevation_level
	state.blade_up = skater.blade_up
	# Host-only shaft segment for stick-lift claim resolution (paired with
	# blade_contact_world). World-space grip point — the wire top_hand_position
	# is upper-body-local and can't be used for host-side world geometry.
	state.top_hand_world = skater.upper_body_to_global(skater.get_top_hand_position())
	state.shot_state = _sm.get_state() as int
	# The normalized 0..1 charge (skater.shot_charge covers the wrister's
	# predicted release power AND slapper wind-up), in the u8 codec range.
	# Consumed on the receive side by the cosmetic pose layers (stick flex,
	# shot stance, wind-up engagement) — charge feedback is fully diegetic:
	# the wind-up animation itself is the gauge, there is no charge ring.
	state.shot_charge = skater.shot_charge
	state.stamina = stamina
	state.sprint_locked = _sprint_locked
	state.stagger_timer = stagger_timer
	state.knockdown_timer = knockdown_timer
	state.move_intent = skater.move_intent
	state.brake_intent = skater.brake_intent
	state.hit_committed = skater.hit_committed
	state.sprint_active = sprint_active

func get_shot_state() -> int:
	return _sm.get_state()

# Whether sprint is currently locked out by exhaustion (stamina bottomed out and
# hasn't recovered past sprint_unlock_fraction yet). Read-only view for the HUD.
func is_sprint_exhausted() -> bool:
	return _sprint_locked

func apply_network_state(_net_state: SkaterNetworkState, _host_ts: float) -> void:
	pass  # overridden by RemoteController on client

# Default 0 for controllers that don't queue inputs (LocalController, AIController).
# RemoteController overrides this with its actual input-queue depth, which is
# encoded into world state for client-side adaptive interpolation tuning.
func get_queue_depth() -> int:
	return 0

func apply_replay_state(state: SkaterNetworkState, delta: float) -> void:
	if skater == null:
		return
	# This path poses the gait + off-hand itself (below), so the render-rate
	# cosmetic hook yields to it while a replay is driving this skater.
	_self_posing = true
	skater.global_position = state.position
	skater.visual_offset = Vector3.ZERO
	skater.velocity = state.velocity
	skater.blade_up = state.blade_up
	# Intent feeds the gait's input-driven reads below (glide / dig-in /
	# crossovers / brake stop) — stamp it like the live controllers do, so
	# playback strides match live play instead of reading zero (file viewer)
	# or stale live-play intent (goal replay on live actors).
	skater.move_intent = state.move_intent
	skater.brake_intent = state.brake_intent
	skater.hit_committed = state.hit_committed
	# Same for the shot-state renders Skater._process drives every frame:
	# stick flex (shot_state transitions fire the release whip, shot_charge
	# sets the load bow) and the loft-level blade scoop. Goal replays run on
	# LIVE actors, so without these stamps the fields freeze at whatever the
	# live tick last wrote and the replayed shot plays with the wrong stick.
	skater.current_shot_state = state.shot_state
	skater.shot_charge = state.shot_charge
	skater.elevation_level = state.elevation_level
	# Skid VFX (SkaterVFX trail marks + spray) keys off is_braking — stamp it
	# from the recorded brake bit so replayed hockey stops spray like live ones.
	skater.is_braking = state.brake_intent
	stamina = state.stamina
	_sprint_locked = state.sprint_locked
	# The gait's sprint read (longer strides, deeper sit, forward lean) keys
	# off the controller's resolved sprint state — stamp it from the recorded
	# bit so replayed sprints stride like live ones.
	sprint_active = state.sprint_active
	stagger_timer = state.stagger_timer
	knockdown_timer = state.knockdown_timer
	skater.is_knocked_down = knockdown_timer > 0.0
	skater.set_facing(state.facing)
	skater.set_upper_body_rotation(state.upper_body_rotation_y)
	skater.set_top_hand_position(state.top_hand_position)
	# Re-derive lean from velocity + hand reach so the upper body leans before
	# the blade marker is placed (host's lean-compensated blade_y needs the
	# matching upper-body rotation to land at the ice in world space).
	_pose.snap_lean_to_state()
	skater.set_blade_position(state.blade_position)
	_ik.update_bottom_hand()
	# Procedural leg gait — derived from the velocity just applied, exactly as in
	# live play, so replayed skaters stride instead of gliding rigidly. `delta` is
	# the replay's virtual-clock advance this frame (slow-mo-scaled, 0 on a paused
	# scrub) so the stride cadence tracks the visible motion rather than wall time.
	_skating.apply(delta)
	# Lower-body yaw channels the gait publishes (hockey-stop skid, hip-to-travel
	# alignment, wrist-shot hip coil). On the simulating machine the pose
	# coordinator writes these in apply_facing, which never runs on this path —
	# mirror the write (lower_body_lag itself is a facing-turn artifact that
	# doesn't exist here).
	skater.set_lower_body_lag(
			_skating.stop_yaw_offset + _skating.travel_align_yaw + _skating.shot_hip_yaw)

signal puck_release_requested(direction: Vector3, power: float, is_slapper: bool)
# Debug/HUD annotation for the most recent release: "FH"/"BH" for wristers
# (the classification that drove the backhand power penalty), "" for quick
# shots and slappers (no backhand concept — quick takes no penalty, there is
# no backhand slapper). Set just before puck_release_requested fires; the
# shot-speed toast reads it alongside the signal.
var last_release_hand: String = ""
# Stroke travel (m) behind the most recent wrister release — the value the
# travel-gated ceiling read. -1.0 for quick shots and slappers (no stroke).
# Debug/HUD only: the shot-speed toast surfaces it so the full-stroke-travel
# tunable can be calibrated against real sweeps vs twitches.
var last_release_stroke_travel: float = -1.0
# Fired when the player releases slap while the puck is nearby but not yet
# carried — the leniency one-timer. GameManager acquires + releases the puck;
# the controller transitions to follow-through immediately.
signal one_timer_release_requested(direction: Vector3, power: float)

func _do_release(direction: Vector3, power: float) -> void:
	if is_replaying:
		return
	var slapper: bool = _sm.get_state() == State.SLAPPER_CHARGE_WITH_PUCK
	puck_release_requested.emit(direction, power, slapper)


# Net exclusion for the CARRIED PUCK. The blade net-clamp keeps the blade out of
# the net, but the puck pins to a carry offset off the blade (get_carry_target_
# global) — a separate point. This clamps that pin the same way, so a carried
# puck can only be inside the net box via a legit FRONT-mouth path (a wraparound
# tuck rides in; a reach from behind/beside is pushed out and the puck knocked
# loose). It is the physical invariant the goal check can then simply trust:
# a puck in the net got there legally. Mirrors the slapshot-pin clamp, which
# already guards its own pin — this covers the plain-carry and wrister-aim states
# (SLAPPER_CHARGE_WITH_PUCK still uses its stricter allow_front=false clamp in
# _update_slapper_charge, so skip it here to avoid fighting it).
func _clamp_carry_pin_from_net() -> void:
	if not has_puck or _sm.get_state() == State.SLAPPER_CHARGE_WITH_PUCK:
		_has_prev_carry_pin = false
		return
	var pin: Vector3 = skater.get_carry_target_global()
	# First carry tick: no legal prior pin to induct from. Seed from the pin so a
	# genuine front entry next tick is judged against a real position; a puck
	# picked up already inside the net is a post-goal artifact (pickup is locked
	# through the goal phase), so seeding it is benign.
	var prev: Vector3 = _prev_carry_pin if _has_prev_carry_pin else pin
	var clamped: Vector3 = NetClampRules.clamp_out_of_net(
			pin, prev, GameRules.GOAL_LINE_Z, GameRules.NET_HALF_WIDTH,
			GameRules.NET_POST_RADIUS, GameRules.NET_PUCK_BUFFER,
			GameRules.NET_DEPTH, GameRules.NET_HEIGHT, true)
	if clamped != pin:
		# The pin sat in the net off a non-front path — knock the puck loose,
		# pushed out along the clamp offset (out of the net), like any net contact.
		_has_prev_carry_pin = false
		var away: Vector3 = clamped - pin
		# Diagnostic: log every ejection so an in-game session can confirm the
		# guard is firing on the bot-behind-the-net plays (and that it's the PUCK
		# being ejected, not the blade passing through the mesh — a different bug).
		# Real ticks only; a temporary probe, safe to remove once verified.
		if not is_replaying:
			var depth_past: float = absf(pin.z) - GameRules.GOAL_LINE_Z
			var face: String = "side" if absf(away.x) >= absf(away.z) else "back/front"
			print("[net-pin-clamp] ejected carried puck: name=%s pin=(%.2f,%.2f,%.2f) depth_past_line=%.3f face=%s push=%.2f" % [
					skater.name, pin.x, pin.y, pin.z, depth_past, face, away.length()])
		if away.length() > 0.001:
			_do_release(away.normalized(), goalie_strip_power)
		return
	_prev_carry_pin = pin
	_has_prev_carry_pin = true

# Nudge: the carrier taps the puck off the blade as a soft self-pass. The
# released velocity is the skater's horizontal momentum plus a small push along
# the blade's current sweep direction — so the puck keeps pace with the carrier
# and only drifts a touch in the direction the stick was moving. Host-derived
# from the carrier's authoritative velocity exactly like a shot (the signal
# carries the host-computed velocity during remote-input replay, the
# client-predicted velocity locally). Skips during reconcile replay.
signal nudge_requested(velocity: Vector3)

func _nudge() -> void:
	if is_replaying:
		return
	var skater_vel := Vector3(skater.velocity.x, 0.0, skater.velocity.z)
	# Blade sweep RELATIVE to the carrier: the absolute blade world velocity minus
	# the skater's own translation. Using the absolute velocity made the push
	# collapse to the skating direction while moving (own velocity drowns out the
	# sweep); subtracting it recovers the true stick-sweep direction so the cursor
	# steers the nudge at speed exactly as it does standing still.
	var blade_dir := skater.blade_world_velocity - Vector3(skater.velocity.x, 0.0, skater.velocity.z)
	blade_dir.y = 0.0
	var push := Vector3.ZERO
	if blade_dir.length() > 0.01:
		push = blade_dir.normalized() * nudge_speed
	# Inherit slightly less than full momentum so the puck drifts back relative to
	# the carrier while skating — that drift plus the sweep push is the nutmeg gap.
	nudge_requested.emit(skater_vel * nudge_velocity_retain + push)

# ── Puck Signals ──────────────────────────────────────────────────────────────
func on_puck_picked_up_network() -> void:
	has_puck = true
	var local_blade: Vector3 = skater.get_blade_position() - skater.shoulder.position
	_blade_relative_angle = atan2(local_blade.x, -local_blade.z)
	if _sm.get_state() == State.SLAPPER_CHARGE_WITHOUT_PUCK:
		# Puck arrived during a puckless slapper wind-up. Pin it to the ice and
		# switch into the with-puck charge — same setup as the carry → slapshot
		# entry path (without the pin the puck snaps to the overhead wind-up blade).
		skater.set_slapper_zone(false)
		skater.set_slapper_mode(true)
		var blade_side_sign: float = -1.0 if skater.is_left_handed else 1.0
		skater.enter_slapshot_pinning(blade_side_sign * slapper_zone_offset_x, slapper_zone_offset_z)
		_sm.set_state(State.SLAPPER_CHARGE_WITH_PUCK)
		if _aiming.slapper_charge_timer >= one_timer_min_windup_time:
			# A genuine one-timer: the wind-up was already built when the feed
			# arrived. Open the timing window — release within
			# one_timer_window_duration to fire, or it cancels back to carry.
			_aiming.one_timer_window_timer = one_timer_window_duration + NetworkManager.get_latest_rtt_ms() / 2000.0
			if show_one_timer_indicator:
				skater.update_slapper_indicator_convergence(1.0)
				skater.update_slapper_indicator_window(1.0)
		# else: the puck was already at the stick when the wind-up started (charge
		# still ~0). Leave the window closed so it doesn't open at no power and
		# cancel straight to carry — this is now a plain slapshot charge that keeps
		# building and fires on release. _update_one_timer_indicator drops the
		# reticle for a windowless with-puck charge, leaving just the aim arrow.
	else:
		_sm.set_state(State.SKATING_WITH_PUCK)

func on_puck_released_network() -> void:
	if not has_puck:
		return
	has_puck = false
	_transition_to_skating()

func teleport_to(pos: Vector3, facing: Vector2 = Vector2.ZERO) -> void:
	# A hard teleport (respawn / slot swap) overrides any in-progress skate-in.
	# begin_approach re-arms this immediately after its own teleport_to(start).
	_approach_active = false
	skater.global_position = pos
	skater.velocity = Vector3.ZERO
	# Fresh legs out of a faceoff / respawn — refill the stamina pool and clear
	# any exhaustion lockout so play resumes from a clean slate.
	stamina = 1.0
	_sprint_locked = false
	sprint_active = false
	hit_active = false
	skater.hit_committed = false
	stagger_timer = 0.0
	knockdown_timer = 0.0
	skater.is_knocked_down = false
	# A faceoff / slot-swap teleport mid-windup must cancel any in-progress shot
	# charge. Otherwise the slapper charge timer keeps ticking across the
	# respawn and the player drops into the faceoff already charged.
	_cancel_active_charge()
	# Faceoff / slot swap teleports pass a non-zero facing so the skater
	# squares up to the puck instead of carrying their last-frame heading
	# (which routinely left players spawned backwards). Tutorial / test
	# call sites that don't want to override facing pass Vector2.ZERO.
	if facing != Vector2.ZERO:
		skater.set_facing(facing)
		_pose.facing = facing
		# Square the body up to the dot and wipe carried-over animation state:
		# clear the upper-body twist/lean/lag so the torso points forward, and
		# plant the legs at their rest pose so the stride doesn't resume mid-swing.
		_pose.reset_lean_and_lag()
		_skating.reset_to_rest()
		# Kill any celebration remainder. The timer only ticks in
		# _process_input, which doesn't run through the goal replay or the
		# faceoff-prep aim-only path — so the leftover slice (goal_scored
		# signal latency; larger on clients) would otherwise freeze through
		# the replay and fire the raised-stick pose AT the next faceoff.
		_celebration_timer = 0.0

# ── Faceoff / intro skate-in approach ─────────────────────────────────────────

# Begins the deterministic skate-in used during FACEOFF_PREP. apply_approach
# glides the body from `start` to `target` (the faceoff dot) over `duration`,
# squaring up to `settle_facing` on arrival. `initial_velocity` is the skater's
# live velocity: pass it for a period / stoppage skate-in (start == current
# position) so the glide flows out of the player's momentum instead of snapping
# to a stop at the whistle; pass zero (default) for a snap-from-rest start (the
# bench intro or post-goal staging, where the body relocates to `start` anyway).
# Deterministic per machine from (start, target, v0, elapsed) with reconcile off.
func begin_approach(start: Vector3, target: Vector3, settle_facing: Vector2,
		duration: float, initial_velocity: Vector3 = Vector3.ZERO) -> void:
	var carry := Vector3(initial_velocity.x, 0.0, initial_velocity.z)
	if carry.length() < _APPROACH_CARRY_MIN:
		# Snap-from-rest: relocate to `start`, reset the gait, and point down the
		# path (teleport_to squares up when given a non-zero facing).
		teleport_to(start, ApproachRules.path_facing(start, target, 0.0, settle_facing))
		carry = Vector3.ZERO
	else:
		# Momentum-preserving: clear stamina / charge and drop reconcile history
		# (teleport_to with a zero facing skips the gait reset + facing snap), then
		# re-seed the live velocity so the stride carries through the whistle.
		teleport_to(start, Vector2.ZERO)
		skater.velocity = carry
	_approach_active = true
	_approach_start = start
	_approach_target = target
	_approach_facing = settle_facing
	_approach_v0 = carry
	_approach_elapsed = 0.0
	_approach_duration = maxf(duration, 0.001)
	_approach_prev_pos = start


func is_approaching() -> bool:
	return _approach_active


func clear_approach() -> void:
	_approach_active = false


# Runs one skate-in tick if an approach is active for the live faceoff prep or
# the period-break skate-off (END_OF_PERIOD — see PhaseCoordinator.
# on_period_break_entered). Returns true while the skater is still gliding
# (caller skips its locked-phase freeze); false when there's no approach or the
# skater has arrived / the phase has ended (caller runs its normal freeze /
# aim-only handling). Real frames only — the skate-in is cosmetic and not part
# of the reconcile input-replay chain.
func tick_faceoff_approach(delta: float) -> bool:
	if not _approach_active:
		return false
	var in_prep: bool = _game_state_has_faceoff_prep and _game_state.is_faceoff_prep()
	var in_break: bool = _game_state_has_period_break and _game_state.is_period_break()
	if not (in_prep or in_break):
		# Left the approach phase (the drop, or an abandoned prep) with an
		# approach still set — drop it so it can't leak into a later locked phase.
		clear_approach()
		return false
	return apply_approach(delta)


# Advances the eased path one tick, moves the body, and renders the gait from a
# path-derived velocity. Returns true while gliding; on arrival (t >= 1) it snaps
# exactly onto the dot, clears the approach, and returns false so the caller
# hands back to the normal prep freeze (letting humans pre-aim the draw).
func apply_approach(delta: float) -> bool:
	_approach_elapsed += delta
	var t: float = clampf(_approach_elapsed / _approach_duration, 0.0, 1.0)
	if t >= 1.0:
		skater.global_position = _approach_target
		skater.velocity = Vector3.ZERO
		skater.set_facing(_approach_facing)
		_pose.facing = _approach_facing
		clear_approach()
		return false
	var new_pos: Vector3 = ApproachRules.path_position(
			_approach_start, _approach_target, t, _approach_v0, _approach_duration)
	var vel: Vector3 = (new_pos - _approach_prev_pos) / maxf(delta, 0.0001)
	_approach_prev_pos = new_pos
	# Clamp the gait-facing velocity (planar) so a long glide doesn't over-spin
	# the stride; the body still translates the full path distance this tick.
	var planar := Vector3(vel.x, 0.0, vel.z)
	if planar.length() > approach_max_gait_speed:
		planar = planar.normalized() * approach_max_gait_speed
	skater.global_position = new_pos
	skater.velocity = planar
	# Facing follows the actual per-tick travel (the momentum path curves), then
	# settles to the dot facing near the end — so a stoppage skater keeps its
	# heading through the whistle instead of snapping toward the dot.
	var facing: Vector2 = ApproachRules.facing_along(
			Vector2(planar.x, planar.z), t, _approach_facing)
	_render_approach_pose(facing, delta)
	return true


# Cosmetic pose pass for a skate-in tick: drives facing directly (the path owns
# heading, not mouse aim), carries the blade out front, and runs the same gait /
# upper-body / IK passes _process_input's tail runs — so the skater strides,
# leans, and settles into the faceoff ready stance exactly like normal skating.
func _render_approach_pose(facing: Vector2, delta: float) -> void:
	_pose.facing = facing
	skater.set_facing(facing)
	skater.move_intent = facing
	skater.brake_intent = false
	_approach_input.delta = delta
	# Aim the blade / head a few metres ahead along travel — a neutral carry that
	# flows into the draw aim once the skater arrives and the prep freeze resumes.
	_approach_input.mouse_world_pos = skater.global_position \
			+ Vector3(facing.x, 0.0, facing.y) * 6.0
	_pose.apply_velocity_lean(delta)
	_ik.apply_blade_from_mouse(_approach_input, delta)
	# Preserve blade/hand world positions across the upper-body rotation — same
	# dance as _process_input, so the stick doesn't slide sideways as the torso
	# tracks travel.
	var blade_world_pre: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
	var hand_world_pre: Vector3 = skater.upper_body_to_global(skater.get_top_hand_position())
	_pose.apply_upper_body(delta)
	_pose.apply_head_tracking(_approach_input, delta)
	skater.set_top_hand_position(skater.upper_body_to_local(hand_world_pre))
	skater.set_blade_position(skater.upper_body_to_local(blade_world_pre))
	# This intro-skate path poses its own gait + off-hand (a brief locked phase,
	# not the hot path); the render hook yields to it (see _self_posing).
	_self_posing = true
	_skating.apply(delta)
	# Publish the gait's lower-body yaw (hip-to-travel alignment) — normally
	# written inside _pose.apply_facing, which this path replaces.
	skater.set_lower_body_lag(
			_skating.stop_yaw_offset + _skating.travel_align_yaw + _skating.shot_hip_yaw)
	_ik.update_bottom_hand()


# Cancels an in-progress wrister/slapper wind-up. No-op unless actually mid-
# charge, so a routine teleport doesn't disturb skating state. Suppresses the
# charge-lost flash since a forced respawn isn't player-initiated charge loss.
func _cancel_active_charge() -> void:
	var s: int = _sm.get_state()
	if s != State.WRISTER_AIM and s != State.SLAPPER_CHARGE_WITH_PUCK \
			and s != State.SLAPPER_CHARGE_WITHOUT_PUCK:
		return
	_aiming.reset_slapper()
	_transition_to_skating()

# ── State Machine ─────────────────────────────────────────────────────────────
func _apply_state(input: InputState, delta: float) -> void:
	_sm.dispatch(skater, input, delta, has_puck, _game_state.is_movement_locked())

# ── State Helpers ─────────────────────────────────────────────────────────────
func _transition_to_skating() -> void:
	var prev_state: int = _sm.get_state()
	skater.shot_charge = 0.0
	skater.slapper_aim_dir = Vector3.ZERO
	if has_puck:
		_sm.set_state(State.SKATING_WITH_PUCK)
	else:
		_sm.set_state(State.SKATING_WITHOUT_PUCK)
	_sm.shot_dir = Vector3.ZERO
	# Handoff out of the follow-through is CONTINUOUS: the FT branches already
	# eased the torso twist/lean and the blade onto the live cursor (see
	# follow_through_return_frac), so zeroing the smoothed pose here would snap
	# the shoulders square and re-rotate — the exact "reset back" we're killing.
	# Preserve the pose and seed the blade smoother from the finish position so
	# the normal dangle continues from where the swing left it. Charge-lost exits
	# (not FOLLOW_THROUGH) still reset to neutral as before.
	if prev_state == State.FOLLOW_THROUGH:
		if not is_replaying:
			_ik.seed_blade_smoothing(skater.upper_body_to_global(skater.get_blade_position()))
	else:
		_pose.reset_lean_and_lag()
		skater.set_lower_body_lag(0.0)
	skater.set_slapper_mode(false)
	skater.set_slapper_zone(false)
	skater.exit_slapshot_pinning()
	_hide_slapshot_hud()

# Aligns BOTH facing stores at spawn: the Skater node's root rotation and the
# pose coordinator's smoothed facing. The spawn path used to set only the
# skater side, leaving _pose.facing at its Vector2.DOWN default — the first
# input tick then re-asserted the stale pose facing, snapping the root up to
# 180° and dumping the whole turn into lower_body_lag: the player spawned
# visibly twisted. (The faceoff teleport already syncs both; this is the
# spawn-time equivalent.)
func set_spawn_facing(facing: Vector2) -> void:
	if facing == Vector2.ZERO:
		return
	skater.set_facing(facing)
	_pose.facing = facing
	_pose.reset_lean_and_lag()
	skater.set_lower_body_lag(0.0)
	# Plant the legs too, matching the faceoff teleport. A no-op at initial
	# spawn (the gait starts at rest), but mid-session callers — the tutorial
	# puppet repositioning between steps — would otherwise drop into the new
	# spot carrying the previous shift's mid-stride leg swing.
	_skating.reset_to_rest()


# This skater's center-slot distance from the faceoff dot: the rest-pose blade
# radius (stick horizontal footprint at rest) scaled by faceoff_center_reach_
# fraction, so the puck sits comfortably inside every build's reach at the
# drop — no hand displacement or lean needed. Host-computed by the phase
# coordinator and broadcast with the rest of the faceoff positions.
func faceoff_center_distance() -> float:
	return _ik.stick_horiz() * faceoff_center_reach_fraction


func _enter_shot_block() -> void:
	_sm.set_state(State.SHOT_BLOCKING)
	skater.set_block_stance(true)
	# Square the upper body and clear lean/lag so the choreographed block pose
	# (authored in upper-body-local space) points straight along the snapped
	# facing instead of inheriting residual twist from the prior state. The
	# torso pipeline's block branch holds the yaw square for the duration and
	# eases only the chest-over-knees pitch in from this cleared baseline.
	_pose.reset_lean_and_lag()
	skater.set_upper_body_rotation(0.0)
	skater.set_upper_body_lean(0.0)
	skater.set_lower_body_lean(0.0, 0.0)
	skater.set_lower_body_lag(0.0)
	# Snap facing toward puck on entry — locked for duration of stance
	var to_puck: Vector3 = puck.global_position - skater.global_position
	to_puck.y = 0.0
	if to_puck.length() > 0.01:
		_pose.facing = Vector2(to_puck.x, to_puck.z).normalized()
		skater.set_facing(_pose.facing)

func _enter_slapper_charge(input: InputState) -> void:
	_aiming.reset_slapper()
	_sm.shot_dir = Vector3.ZERO
	# Snap facing toward mouse first so the blade-side world position is correct.
	var to_mouse := Vector2(
		input.mouse_world_pos.x - skater.global_position.x,
		input.mouse_world_pos.z - skater.global_position.z)
	_pose.facing = to_mouse.normalized() if to_mouse.length() > move_deadzone else _pose.facing
	skater.set_facing(_pose.facing)
	# Square the stance BEFORE locking the aim. The slapper holds a squared upper
	# body (zero twist/lean), so the locked direction must be measured from THAT
	# pose. Measuring first (as it did) built the blade world point through the
	# residual skating twist/lean that's zeroed one line later — aiming from a
	# pose that lasts zero frames, and worse, twist/lean are only loosely synced
	# (lean isn't networked; twist re-snaps only at reconcile), so client and host
	# baked different transient poses into the lock and diverged. From the squared
	# stance the lock depends only on facing + body position + the fixed blade
	# offset, which both machines agree on.
	_pose.reset_lean_and_lag()
	skater.set_upper_body_rotation(0.0)
	skater.set_upper_body_lean(0.0)
	skater.set_lower_body_lean(0.0, 0.0)
	skater.set_lower_body_lag(0.0)
	# Lock aim direction from the squared blade-side release point → mouse.
	var blade_side_sign: float = -1.0 if skater.is_left_handed else 1.0
	var blade_local := Vector3(
		skater.shoulder.position.x + blade_side_sign * slapper_blade_x,
		_ik.blade_y_local(),
		skater.shoulder.position.z + slapper_blade_z)
	var blade_world: Vector3 = skater.upper_body_to_global(blade_local)
	var to_mouse_from_blade := Vector2(
		input.mouse_world_pos.x - blade_world.x,
		input.mouse_world_pos.z - blade_world.z)
	_sm.locked_slapper_dir = to_mouse_from_blade.normalized() if to_mouse_from_blade.length() > move_deadzone else _pose.facing
	skater.slapper_aim_dir = Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
	if has_puck:
		skater.set_slapper_mode(true)
		# Pin the carried puck to the slapper-zone ice spot for the duration of
		# the wind-up so it doesn't ride up with the blade as the stick lifts
		# overhead. The pin travels with the player (so coasting/braking still
		# works) and the shot fires from this position when released — see
		# Puck.release's slapshot branch.
		skater.enter_slapshot_pinning(blade_side_sign * slapper_zone_offset_x, slapper_zone_offset_z)
		_sm.set_state(State.SLAPPER_CHARGE_WITH_PUCK)
	else:
		# Activate the ice-level slapper zone so the puck can be detected at
		# ground level even though the blade is lifted during wind-up.
		skater.set_slapper_zone(true, slapper_zone_radius, slapper_zone_offset_x, slapper_zone_offset_z)
		_sm.set_state(State.SLAPPER_CHARGE_WITHOUT_PUCK)
		if show_one_timer_indicator:
			skater.set_slapper_indicator(true, slapper_zone_offset_x, slapper_zone_offset_z, slapper_zone_radius)
	if show_one_timer_indicator:
		skater.set_slapshot_arrow(true, slapper_zone_offset_x, slapper_zone_offset_z, slapper_zone_radius)
		skater.update_slapshot_arrow_direction(skater.slapper_aim_dir)

# The slapper aim locked at press (XZ as Vector2). Persists from _enter_slapper_charge
# until the next charge, so the host can read its OWN replayed value to fire a remote
# player's one-timer authoritatively instead of trusting the client-sent direction.
func get_locked_slapper_dir() -> Vector2:
	return _sm.locked_slapper_dir

func _get_charge_direction() -> Vector3:
	# prev_blade_dir is the screen-space cursor drag direction packed
	# (x, 0, y), already in world XZ frame: LocalInputGatherer negates
	# mouse_screen_pos for attack_up team 1, so by the time the tracker
	# records this direction it's been pre-aligned with world XZ for
	# both screen-pos and the blade frame the magnitude reads from.
	# Don't re-flip here — that would invert correct shots.
	return _aiming.prev_blade_dir

# The wrister's aim DIRECTION (world XZ), chosen by wrister_positional_aim. Shared
# by the release (_release_wrister) and the every-tick goalie-prediction path
# (_update_wrister_charge) so the pre-lean predicts exactly the shot that fires.
#   positional → pinned origin→cursor: from where the stroke STARTED
#     (SkaterAimingBehavior.wrister_origin_world, captured at mouse-down) toward
#     the cursor now — the "start at the blade, drag to where you point, the puck
#     follows that line" model, and the same positional aim the quick pass uses.
#     Anchoring at stroke start (not the live, swung blade) is what keeps it
#     stable at tight angles / a close cursor.
#   gestural → the drag vector (_get_charge_direction) — the original wrister aim.
# release_wrister falls back to player→cursor if this is degenerate. Backhand is
# unaffected either way (it's the sweep chirality, not the aim vector).
func _wrister_aim_dir(input: InputState) -> Vector3:
	# Freeze implies positional: a held blade has no drag/sweep to read.
	if wrister_positional_aim or wrister_freeze_blade:
		var d: Vector3 = input.mouse_world_pos - _aiming.wrister_origin_world
		d.y = 0.0
		return d
	return _get_charge_direction()

# Blade update for the WRISTER_AIM state: hold the blade at the shot origin under
# wrister_freeze_blade, else chase the cursor exactly like carry. Routed through
# the state machine's apply_wrister_aim_blade callback.
func _apply_wrister_aim_blade(input: InputState, delta: float) -> void:
	_ik.apply_blade_from_mouse(input, delta, wrister_freeze_blade)

# Forehand/backhand for the wrister, from the swing CHIRALITY — the net
# rotational sense of the blade's sweep around the player over the stroke
# (SkaterAimingBehavior.swing_rotation, accumulated by ChargeTracking). Shared
# by the release path and the every-tick goalie-prediction path so both agree.
# The accumulator is player-relative blade motion and is saved/restored across
# reconcile alongside charge, so the classification is deterministic.
func _classify_backhand() -> bool:
	return ShotMechanics.is_backhand_from_swing(
			_aiming.swing_rotation,
			skater.is_left_handed,
			wrister_backhand_deadband)

func _release_wrister(input: InputState) -> void:
	if has_puck:
		var blade_world: Vector3 = _ik.last_target_blade_world
		var aim_dir: Vector3 = _wrister_aim_dir(input)
		# Forehand/backhand from the swing chirality (ShotMechanics.is_backhand_from_swing),
		# whose source is the cursor bearing when frozen and the blade bearing when
		# live — see _update_wrister_charge. Same clockwise check either way.
		var is_backhand: bool = _classify_backhand()
		# LMB is always a charged wrister now — the quick pass lives on its own
		# button (_fire_quick_pass). A bare tap here fires a min-charge wrister.
		last_release_hand = "BH" if is_backhand else "FH"
		last_release_stroke_travel = _wrister_stroke_travel()
		var result := ShotMechanics.release_wrister(
				skater.global_position,
				input.mouse_world_pos,
				blade_world,
				is_backhand,
				_elevation_level,
				_wrister_config(),
				aim_dir,
				false,
				_wrister_sweep_speed(input),
				_wrister_stroke_travel())
		_sm.shot_dir = result.direction
		_do_release(result.direction, result.power)

	_sm.follow_through_is_slapper = false
	# Finish size follows the released POWER (pre-backhand — the body swing is the
	# same, the blade contact is what's weaker): a soft touch pass flicks, a
	# ripped full sweep finishes high. Computed from the aiming state (not
	# `result`) so a whiff still animates. Travel-gated like the real release,
	# so a capped twitch shot finishes small — the finish IS the power readout.
	var release_power_t: float = ShotMechanics.wrister_power_t(
			_wrister_sweep_speed(input), _wrister_config(), _wrister_stroke_travel())
	_sm.follow_through_power = lerpf(wrister_follow_through_min_power, 1.0, release_power_t)
	_shot_pose.begin_follow_through()
	_sm.set_state(State.FOLLOW_THROUGH)
	_sm.follow_through_timer = follow_through_duration
	_sm.follow_through_duration_total = follow_through_duration

# Instant quick pass — the fixed-power blade→cursor snap, fired straight from
# carry by the dedicated quick_pass button (no wrister aim/charge). Backhand is
# irrelevant here: the quick pass takes no backhand penalty (its power is flat).
# apply_blade_from_mouse ran earlier this tick, so last_target_blade_world is
# current.
func _fire_quick_pass(input: InputState) -> void:
	if has_puck:
		var blade_world: Vector3 = _ik.last_target_blade_world
		last_release_hand = ""
		last_release_stroke_travel = -1.0
		var result := ShotMechanics.release_wrister(
				skater.global_position,
				input.mouse_world_pos,
				blade_world,
				false,
				_elevation_level,
				_wrister_config(),
				Vector3.ZERO,
				true)
		_sm.shot_dir = result.direction
		_do_release(result.direction, result.power)

	_sm.follow_through_is_slapper = false
	_sm.follow_through_power = quick_pass_follow_through_power
	_shot_pose.begin_follow_through()
	_sm.set_state(State.FOLLOW_THROUGH)
	_sm.follow_through_timer = quick_pass_follow_through_duration
	_sm.follow_through_duration_total = quick_pass_follow_through_duration

func _release_slapper(input: InputState) -> void:
	if has_puck:
		# Direction is locked at the moment slap was pressed — no mid-swing steering.
		last_release_hand = ""
		last_release_stroke_travel = -1.0
		var locked_dir_3d := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
		var cfg: ShotMechanics.SlapperConfig = _slapper_config()
		# One-timers (puck arrived mid-charge) ride the same timer as a normal
		# release — power is whatever wind-up was actually built.
		var charge: float = _aiming.slapper_charge_timer
		var result := ShotMechanics.release_slapper(
				skater.upper_body_to_global(skater.get_blade_position()),
				input.mouse_world_pos,
				_elevation_level,
				charge,
				cfg,
				locked_dir_3d)
		# One-timer (puck arrived mid-charge → window armed): apply the SAME graded
		# centre-timing bonus the leniency-release path uses, so the ±10% is one
		# mechanic on both release paths — reachable however the shot fires, graded
		# by how centred the puck is. A one-timer that attaches on the pinned zone
		# spot is a clean, well-timed catch and earns it; a normal carried slapshot
		# has no window armed and is untouched.
		if _aiming.one_timer_window_timer > 0.0:
			var zone_world: Vector3 = skater.get_slapper_zone_global_position()
			var zone_xz := Vector2(zone_world.x, zone_world.z)
			var puck_xz := Vector2(puck.global_position.x, puck.global_position.z)
			result.power = ShotReleaseRules.one_timer_power(
					result.power, one_timer_center_power_bonus,
					zone_xz, puck_xz, slapper_zone_radius)
		_sm.shot_dir = result.direction
		_do_release(result.direction, result.power)

	_sm.follow_through_is_slapper = true
	# A slap swing is always full-bodied — power gates the finish only for wristers.
	_sm.follow_through_power = 1.0
	_sm.set_state(State.FOLLOW_THROUGH)
	_sm.follow_through_timer = slapper_follow_through_duration
	_sm.follow_through_duration_total = slapper_follow_through_duration
	# Hide the slapshot HUD the moment the shot fires. Follow-through is body
	# animation only — leaving the ring/arrow visible during that ~0.5s makes
	# them appear to rotate with the skater, which reads as weird.
	# _transition_to_skating still hides everything at the end as a safety net.
	_hide_slapshot_hud()

func _hide_slapshot_hud() -> void:
	if not show_one_timer_indicator:
		return
	skater.set_slapper_indicator(false)
	skater.set_slapshot_arrow(false)

func _update_wrister_charge(input: InputState) -> void:
	if not has_puck:
		return
	# Direction signal: cursor SCREEN position, packed (x, 0, y) for the
	# tracker's Vector3 interface. Screen space is the camera-immune
	# frame — pixel motion captures the player's mouse drag intent
	# independent of camera lag, body rotation, or skater locomotion.
	var intent_pos := Vector3(input.mouse_screen_pos.x, 0.0, input.mouse_screen_pos.y)
	# Magnitude signal: the ROM-clamped blade TARGET (closed-form project_blade,
	# computed in apply_blade_from_mouse this tick), skater translation subtracted.
	# Reading the target rather than the speed-capped smoothed blade keeps charge
	# gated by reachable space (a cursor past the reach limit pins the target →
	# zero delta) while staying deterministic, so host and client agree on charge.
	var blade_world: Vector3 = _ik.last_target_blade_world
	# Chirality (forehand/backhand) source: the signed angular sweep of this
	# bearing around the player over the stroke (ChargeTracking.swing_step). A
	# LIVE blade uses its own bearing. A FROZEN blade doesn't move, so it has no
	# chirality — read it from the CURSOR's bearing around the player instead: the
	# same clockwise check, sourced from mouse movement, so "bring the puck back on
	# the forehand and shoot forward" classifies as a forehand by its net rotation
	# (not by which side it started on). Reproduces how a live-blade wrister
	# classified before the freeze (the blade was tracking the cursor).
	var chirality_source: Vector3 = input.mouse_world_pos if wrister_freeze_blade else blade_world
	var blade_pos_rel_skater: Vector3 = chirality_source - skater.global_position
	blade_pos_rel_skater.y = 0.0
	# The stroke-travel accumulator's per-tick step is bounded by the on-axis
	# blade-speed budget × delta: the target is a closed-form ROM clamp (not
	# the speed-capped smoothed blade), so a forged/teleporting cursor could
	# otherwise bank a whole arc of travel in one tick.
	_aiming.tick_wrister_charge(
			intent_pos, blade_pos_rel_skater,
			max_charge_direction_variance,
			input.delta,
			wrister_mouse_speed_smoothing,
			wrister_on_axis_blade_speed * input.delta)
	# Publish where this charge would go if released NOW, so the host-side goalie
	# AI can pre-lean toward a charging shot's predicted impact. Mirrors the exact
	# release math in _release_wrister (same inputs), and re-solves every tick — so
	# a player who drags one way then flicks the other at release moves the real
	# impact off the goalie's lean (a tricky release beats the read). Works for
	# REMOTE shooters too: the host simulates their carry from replicated input
	# (RemoteController._drive_from_input → this path), and both signals ride the
	# wire — mouse_world_pos, plus mouse_screen_pos pre-aligned to world XZ by the
	# gatherer's attack-direction negation (the drag direction _get_charge_direction
	# reads) — with the remote's Shot Power Sensitivity from the join payload feeding
	# _wrister_sweep_speed. Host-only in that it runs on the authoritative sim, not in
	# that it's limited to host-controlled shooters.
	# Predict the exact release this tick — direction and backhand both matched to
	# the release path so the goalie pre-leans toward the shot that would fire.
	var charge_aim_dir: Vector3 = _wrister_aim_dir(input)
	var is_backhand: bool = _classify_backhand()
	# Re-solves every tick while charging (+ per replayed input on reconcile), so
	# fill a reused scratch instead of allocating a ShotResult each time.
	var pred := ShotMechanics.release_wrister(
			skater.global_position, input.mouse_world_pos, blade_world,
			is_backhand, _elevation_level,
			_wrister_config(), charge_aim_dir, false,
			_wrister_sweep_speed(input), _wrister_stroke_travel(), _wrister_pred_scratch)
	skater.predicted_shot_velocity = pred.direction * pred.power
	# shot_charge carries the release-now SPEED (normalized predicted power over
	# the min→max band) — the pure mouse-speed model, so it always matches the
	# shot that would come out this tick. This is the honest readout the goalie
	# leans on and what the stick-flex pose keys off (the flex is the only
	# visual charge feedback — there is no charge ring).
	var power_span: float = maxf(max_wrister_power - min_wrister_power, 0.001)
	skater.shot_charge = clampf((pred.power - min_wrister_power) / power_span, 0.0, 1.0)

func _update_slapper_charge(delta: float) -> void:
	_aiming.tick_slapper(delta)
	skater.shot_charge = minf(_aiming.slapper_charge_timer / max_slapper_charge_time, 1.0)
	# Publish where this slapshot would go if released NOW, so the host-side goalie
	# AI can pre-lean toward the aimed corner — the directional anticipation the
	# wrister already gets (_update_wrister_charge). This was the "skate up and rip a
	# slapper from the slot" cheese: the slapper path never published this, for ANY
	# shooter (host player and bots included, not just remotes), so the goalie squared
	# to the pinned puck but its glove rested centred and had to travel the full way
	# to a corner on reaction. The distinguishing axis was slapper-vs-wrister, not
	# local-vs-remote — the wrister already worked everywhere. Like the wrister, this
	# runs on the host for remotes too (RemoteController._drive_from_input simulates
	# their carry); the slapper direction is LOCKED at press (_sm.locked_slapper_dir,
	# built in _enter_slapper_charge from the replicated mouse_world_pos), so no
	# screen-space signal is even needed. Gated to the WITH-PUCK windup: a one-timer
	# wind-up has no puck to lean toward, and the goalie reads only SLAPPER_CHARGE_WITH_PUCK.
	if has_puck:
		var locked_dir_3d := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
		if locked_dir_3d.length_squared() > 0.0001:
			var pred := ShotMechanics.release_slapper(
					skater.global_position, skater.global_position,
					_elevation_level, _aiming.slapper_charge_timer,
					_slapper_config(), locked_dir_3d, _slapper_pred_scratch)
			skater.predicted_shot_velocity = pred.direction * pred.power
	if show_one_timer_indicator:
		skater.update_slapshot_arrow_direction(skater.slapper_aim_dir)
	# Net exclusion for the slapshot PIN. While charging with the puck, the puck
	# is pinned to a body-relative ice offset (Skater.get_carry_target_global's
	# slapshot branch) instead of the blade contact, so the blade-contact net
	# clamp never sees it — a carrier winding up while skating behind or across
	# a net would otherwise drag the pinned puck straight through the mesh (and
	# across the goal line). Mirror the blade path's rule: the moment the pin
	# would enter the net's exclusion box, the net knocks the puck loose.
	# allow_front=false — a wind-up never tucks the puck into the mouth.
	if has_puck and skater.is_slapshot_pinning():
		var pin: Vector3 = skater.get_carry_target_global()
		var clamped: Vector3 = NetClampRules.clamp_out_of_net(
				pin, pin, GameRules.GOAL_LINE_Z, GameRules.NET_HALF_WIDTH,
				GameRules.NET_POST_RADIUS, GameRules.NET_PUCK_BUFFER,
				GameRules.NET_DEPTH, GameRules.NET_HEIGHT, false)
		if clamped != pin:
			var away: Vector3 = clamped - pin
			if away.length() > 0.001:
				_do_release(away.normalized(), goalie_strip_power)

# Normalized wind-up progress (0..1) over the FULL charge time. With the charge
# ring gone the wind-up pose is the charge gauge, so every pose consumer (blade
# lift, torso coil, downswing start) must reach its apex exactly at max charge —
# one definition keeps them agreeing. Deterministic through reconcile replay:
# the charge timer is saved/restored with the aiming state.
func slapper_wind_up_t() -> float:
	return clampf(_aiming.slapper_charge_timer / maxf(max_slapper_charge_time, 0.001), 0.0, 1.0)

# Seconds the charge timer has sat past full — drives the full-charge quiver
# phase deterministically (no wall clock in pose math; replay-safe).
func slapper_overcharge_seconds() -> float:
	return maxf(_aiming.slapper_charge_timer - max_slapper_charge_time, 0.0)

func _apply_slapper_velocity_drag(delta: float) -> void:
	var slapper_vel := Vector2(skater.velocity.x, skater.velocity.z)
	var drag: float = friction + friction_drag * slapper_vel.length()
	slapper_vel = slapper_vel.move_toward(Vector2.ZERO, drag * delta)
	skater.velocity.x = slapper_vel.x
	skater.velocity.z = slapper_vel.y

func _try_one_timer_release(input: InputState) -> Dictionary:
	# Use XZ distance from the slapper zone center (ground level) — this matches
	# the ring indicator the player sees and avoids penalising blade height since
	# the blade is lifted during wind-up.
	var zone_world: Vector3 = skater.get_slapper_zone_global_position()
	var zone_xz := Vector2(zone_world.x, zone_world.z)
	var puck_xz := Vector2(puck.global_position.x, puck.global_position.z)
	var dist: float = zone_xz.distance_to(puck_xz)
	if dist > _effective_one_timer_leniency():
		# Whiff: no shot fires, but the state machine still commits the swing
		# to a full follow-through — hand it the same duration/power and drop
		# the HUD now, exactly like a connected release.
		_sm.follow_through_power = 1.0
		_hide_slapshot_hud()
		return {fired = false, follow_through_duration = slapper_follow_through_duration}
	var blade_world: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
	var locked_dir_3d := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
	var cfg: ShotMechanics.SlapperConfig = _slapper_config()
	var result := ShotMechanics.release_slapper(
			blade_world, input.mouse_world_pos,
			_elevation_level, _aiming.slapper_charge_timer, cfg, locked_dir_3d)
	result.power = ShotReleaseRules.one_timer_power(
			result.power, one_timer_center_power_bonus, zone_xz, puck_xz, slapper_zone_radius)
	if not is_replaying:
		one_timer_release_requested.emit(result.direction, result.power)
	# Same as _release_slapper — hide the HUD as soon as the shot fires so it
	# doesn't ride along through the follow-through. The state machine copies the
	# returned duration into follow_through_duration_total; power is set here.
	_sm.follow_through_power = 1.0
	_hide_slapshot_hud()
	return {fired = true, direction = result.direction, follow_through_duration = slapper_follow_through_duration}

func _apply_block_movement(_input: InputState, delta: float) -> void:
	# Committed stance: no directional thrust. Whatever momentum you carried in
	# bleeds off under the hard brake friction, so dropping into a block reads as
	# a deliberate plant rather than crouched skating. is_braking drives the
	# hockey-stop skid VFX (gated on speed, so it only shows while sliding to a
	# stop, not once planted).
	skater.is_braking = true
	skater.velocity = SkaterMovementRules.apply_movement(
			skater.velocity, Vector2.ZERO, skater.rotation.y,
			false, true, delta, _block_movement_config())

func _effective_one_timer_leniency() -> float:
	var puck_xz_speed: float = Vector2(puck.linear_velocity.x, puck.linear_velocity.z).length()
	return slapper_zone_radius + puck_xz_speed * one_timer_leniency_time

func _is_in_slapper_state() -> bool:
	var s: SkaterStateMachine.State = _sm.get_state()
	return s == State.SLAPPER_CHARGE_WITH_PUCK or s == State.SLAPPER_CHARGE_WITHOUT_PUCK

# ── Movement ──────────────────────────────────────────────────────────────────
func _apply_movement(input: InputState, delta: float) -> void:
	# Brake held — drives hockey stop VFX (gated on speed in skater_vfx.gd).
	skater.is_braking = input.brake
	skater.is_braced = input.brake

	# Knockdown: the top of the stagger continuum. Decays every tick like stagger.
	# While down, input is ignored entirely — the body keeps its momentum from the
	# hit and bleeds it via heavy friction (slides, then stops), stamina regenerates,
	# and stagger still decays, so the player recovers on all clocks while grounded.
	# All deterministic → reconcile replay reproduces the down window; the flag gates
	# puck pickup (Skater.is_knocked_down).
	knockdown_timer = maxf(knockdown_timer - delta, 0.0)
	skater.is_knocked_down = knockdown_timer > 0.0
	if skater.is_knocked_down:
		sprint_active = false
		hit_active = false
		skater.hit_committed = false
		stagger_timer = maxf(stagger_timer - delta, 0.0)
		var kd_cfg: StaminaRules.StaminaConfig = _stamina_config()
		stamina = StaminaRules.next_stamina(stamina, false, has_puck, delta, kd_cfg, false)
		_sprint_locked = StaminaRules.next_locked(_sprint_locked, stamina, false, kd_cfg, false)
		skater.velocity = skater.velocity.move_toward(Vector3.ZERO, knockdown_friction * delta)
		return

	var move_state: SkaterStateMachine.State = _sm.get_state()
	# Locomotion is suppressed during a planted slap windup / block stance, but
	# stamina still ticks (you can't sprint, so it regenerates). Computing it
	# before the early-return keeps the bar honest through those states.
	var locomotion_suppressed: bool = \
			move_state == State.SLAPPER_CHARGE_WITH_PUCK or move_state == State.SHOT_BLOCKING
	var is_moving: bool = not input.brake and input.move_vector.length() > move_deadzone
	sprint_active = not locomotion_suppressed and StaminaRules.sprint_active(
			stamina, input.sprint_held, is_moving, _sprint_locked)
	# Hit commit shares the sprint stamina pool and lockout but needs no movement
	# (you can hold the check-ready stance stationary to line someone up). Resolved
	# before the stamina update so this tick's drain reflects the commit, and
	# mirrored to the skater so the collision resolver reads full-vs-passive
	# transfer. Deterministic (input.hit_held + snapped stamina), so reconcile
	# replay reproduces it.
	hit_active = not locomotion_suppressed and StaminaRules.hit_active(
			stamina, input.hit_held, _sprint_locked)
	skater.hit_committed = hit_active
	var stamina_cfg: StaminaRules.StaminaConfig = _stamina_config()
	stamina = StaminaRules.next_stamina(stamina, sprint_active, has_puck, delta, stamina_cfg, hit_active)
	_sprint_locked = StaminaRules.next_locked(_sprint_locked, stamina, sprint_active, stamina_cfg, hit_active)
	# Body-check stagger decays deterministically every tick (including during a
	# planted charge/block and through reconcile replay), so the thrust penalty
	# eases back on its own. Decayed before the suppression early-out so a player
	# checked mid-windup keeps recovering.
	stagger_timer = maxf(stagger_timer - delta, 0.0)

	if locomotion_suppressed:
		return

	var cfg: SkaterMovementRules.MovementConfig = _movement_config()
	# Apply the stagger thrust penalty on top of the attribute-scaled base thrust.
	# cfg.thrust is set from `thrust` every tick (cheap, no allocation), so the
	# penalty is transient and never compounds into the cached config.
	cfg.thrust = thrust * BodyCheckRules.thrust_mult(stagger_timer, _body_check_config())
	skater.velocity = SkaterMovementRules.apply_movement(
			skater.velocity, input.move_vector, skater.rotation.y,
			has_puck, input.brake, delta, cfg, sprint_active)

# Movement configs are cached — _apply_movement runs every physics tick (and
# once per reconcile-replayed input), and the source exports change only in
# apply_attributes. Same pattern as the goalie controller's cached rule
# configs. The block config is an independent instance, NOT a mutated copy of
# the shared one — mutating the cached base would corrupt normal skating.
var _cached_move_cfg: SkaterMovementRules.MovementConfig = null
var _cached_block_move_cfg: SkaterMovementRules.MovementConfig = null

func _movement_config() -> SkaterMovementRules.MovementConfig:
	if _cached_move_cfg == null:
		_cached_move_cfg = _build_movement_config()
	return _cached_move_cfg

# Public read of the cached movement config (built from this skater's scaled
# tuning, rebuilt on apply_attributes). Consumed by stage-3 remote forward-
# prediction — the client (RemoteController) and host (HitClaimResolver) both
# drive SkaterMovementRules.integrate_forward with the target skater's own config.
# Live-tuning caveat aside, treat the returned object as read-only.
#
# thrust is re-normalized to the attribute-scaled base on every read: the live
# movement path transiently writes the stagger-scaled thrust into the CACHED
# config each tick, but only on the machine that simulates this skater (the
# host, or a bot's host controller) — a client's RemoteController never runs
# _apply_movement, so its copy holds base thrust. Without the reset the host
# claim rewind would integrate a recently-checked victim with present-tick
# staggered thrust while the client rendered base thrust — an input asymmetry
# breaking render == rewind right after checks, when follow-up claims cluster.
# The stagger penalty is then applied SYMMETRICALLY inside integrate_forward
# (both sides pass the snapshot's replicated stagger_timer + this skater's
# body-check config), so the normalization here is what keeps the base clean
# for that shared scaling rather than a decision to ignore stagger.
func get_movement_config() -> SkaterMovementRules.MovementConfig:
	var cfg: SkaterMovementRules.MovementConfig = _movement_config()
	cfg.thrust = thrust
	return cfg


# Public read of the cached body-check config — consumed by the stage-3 forward
# prediction (both the client render and the host claim rewind) to apply the
# victim's stagger thrust penalty identically on both sides.
func get_body_check_config() -> BodyCheckRules.Config:
	return _body_check_config()

func _block_movement_config() -> SkaterMovementRules.MovementConfig:
	if _cached_block_move_cfg == null:
		_cached_block_move_cfg = _build_movement_config()
		_cached_block_move_cfg.max_speed = max_speed * block_speed_multiplier
		_cached_block_move_cfg.thrust = thrust * block_speed_multiplier
	return _cached_block_move_cfg

func _build_movement_config() -> SkaterMovementRules.MovementConfig:
	var cfg := SkaterMovementRules.MovementConfig.new()
	cfg.thrust = thrust
	cfg.friction = friction
	cfg.friction_drag = friction_drag
	cfg.max_speed = max_speed
	cfg.move_deadzone = move_deadzone
	cfg.brake_multiplier = brake_multiplier
	cfg.puck_carry_speed_multiplier = puck_carry_speed_multiplier
	cfg.backward_thrust_multiplier = backward_thrust_multiplier
	cfg.crossover_thrust_multiplier = crossover_thrust_multiplier
	cfg.sprint_thrust_multiplier = sprint_thrust_multiplier
	cfg.sprint_max_speed_multiplier = sprint_max_speed_multiplier
	cfg.sprint_carry_penalty_bypass = sprint_carry_penalty_bypass
	cfg.lateral_grip = lateral_grip
	return cfg

# Stamina config is flat (not attribute-scaled), so a single lazily-built
# instance is reused for the controller's lifetime — same caching pattern as
# the movement config, minus the apply_attributes invalidation.
var _cached_stamina_cfg: StaminaRules.StaminaConfig = null

func _stamina_config() -> StaminaRules.StaminaConfig:
	if _cached_stamina_cfg == null:
		_cached_stamina_cfg = StaminaRules.StaminaConfig.new()
		_cached_stamina_cfg.drain_per_sec = sprint_drain_per_sec
		_cached_stamina_cfg.carry_drain_multiplier = sprint_carry_drain_multiplier
		_cached_stamina_cfg.regen_per_sec = stamina_regen_per_sec
		_cached_stamina_cfg.unlock_fraction = sprint_unlock_fraction
		_cached_stamina_cfg.hit_drain_per_sec = hit_stamina_drain_per_sec
	return _cached_stamina_cfg

# Body-check stagger config is flat (not attribute-scaled), so a single lazily-built
# instance is reused for the controller's lifetime — same pattern as the stamina
# config, read both on a hit (_on_body_check_received) and every tick (the thrust
# penalty in _apply_movement).
var _cached_body_check_cfg: BodyCheckRules.Config = null

func _body_check_config() -> BodyCheckRules.Config:
	if _cached_body_check_cfg == null:
		_cached_body_check_cfg = BodyCheckRules.Config.new()
		_cached_body_check_cfg.min_impulse = stagger_min_impulse
		_cached_body_check_cfg.ref_impulse = stagger_ref_impulse
		_cached_body_check_cfg.max_stagger_seconds = stagger_max_seconds
		_cached_body_check_cfg.max_stamina_drain = stagger_max_stamina_drain
		_cached_body_check_cfg.max_thrust_penalty = stagger_max_thrust_penalty
		_cached_body_check_cfg.knockdown_impulse = knockdown_impulse
		_cached_body_check_cfg.knockdown_ref_impulse = knockdown_ref_impulse
		_cached_body_check_cfg.min_knockdown_seconds = knockdown_min_seconds
		_cached_body_check_cfg.max_knockdown_seconds = knockdown_max_seconds
	return _cached_body_check_cfg

# Cached — _update_wrister_charge reads it every aim tick (120 Hz, replayed
# again per input through reconcile), so a per-call .new() is hot-path churn.
# Rebuilt lazily after apply_attributes nulls it (same pattern as the
# movement/stamina configs above).
var _cached_wrister_cfg: ShotMechanics.WristerConfig = null

func _wrister_config() -> ShotMechanics.WristerConfig:
	if _cached_wrister_cfg == null:
		_cached_wrister_cfg = ShotMechanics.WristerConfig.new()
		_cached_wrister_cfg.min_wrister_power = min_wrister_power
		_cached_wrister_cfg.max_wrister_power = max_wrister_power
		_cached_wrister_cfg.backhand_power_coefficient = backhand_power_coefficient
		_cached_wrister_cfg.quick_pass_power = quick_pass_power
		_cached_wrister_cfg.loft_vy_low = loft_vertical_speed_low
		_cached_wrister_cfg.loft_vy_high = loft_vertical_speed_high
		_cached_wrister_cfg.loft_tan_max = loft_tan_max
		_cached_wrister_cfg.power_curve = wrister_power_curve
		# Pure mouse-speed model: power is a curve over the cursor speed (fed as
		# sweep_speed by _wrister_sweep_speed). full_sweep_speed is the cursor
		# speed (px/s) that reads as full power.
		_cached_wrister_cfg.full_sweep_speed = wrister_mouse_speed_full
		# Travel-gated ceiling: the top of the band must be earned with real
		# blade travel (fed as stroke_travel by _wrister_stroke_travel).
		_cached_wrister_cfg.full_stroke_travel = wrister_full_stroke_travel
		_cached_wrister_cfg.travel_cap_floor = wrister_travel_cap_floor
	return _cached_wrister_cfg

# True for bot controllers (AIController overrides). Bots have no real cursor, so
# they drive the pure-mouse power model via a committed target fraction
# (InputState.bot_wrister_power_t) rather than a measured cursor speed.
func is_ai_controlled() -> bool:
	return false

# Shot Power Sensitivity for THIS controller. Base (bots / unknown) = 1.0;
# LocalController reads the local pref; a host-side RemoteController reads the
# value the host replicated from the remote client's join (set below), so the
# client's predicted shot power matches the host's authoritative shot.
var net_shot_power_sensitivity: float = 1.0

func shot_power_sensitivity() -> float:
	return 1.0

# The speed signal fed to the wrister power model:
#   - Bots: the cursor speed equivalent to their committed target power fraction
#     (deterministic — bots have no measured cursor).
#   - Humans: the raw cursor speed, scaled by that player's Shot Power
#     Sensitivity (calibrates the flick-for-power feel to their mouse DPI).
func _wrister_sweep_speed(input: InputState) -> float:
	if is_ai_controlled():
		return ShotMechanics.wrister_speed_for_power_t(input.bot_wrister_power_t, _wrister_config())
	return _aiming.cursor_speed_ema * shot_power_sensitivity()

# Stroke travel fed to the travel-gated power ceiling
# (ShotMechanics.wrister_travel_cap_t). Bots bypass the gate (INF): they have
# no measured stroke — the committed bot_wrister_power_t IS their whole
# gesture, and their wind-up geometry is cosmetic. Humans read the accumulated
# blade-path length of the live stroke (world meters, so the ceiling can't be
# bought with DPI or Shot Power Sensitivity).
func _wrister_stroke_travel() -> float:
	# A FROZEN blade sweeps no world-space path, so the travel-gated ceiling would
	# pin every shot at the floor tier (the ~59% cap seen in playtest). The gesture
	# that earns power is now the cursor sweep, not blade travel, so the blade-path
	# gate is meaningless here — disable it (INF) while frozen. A real anti-
	# degeneracy pass (a cursor-sweep gate) comes later if the freeze sticks.
	if is_ai_controlled() or wrister_freeze_blade:
		return INF
	return _aiming.stroke_travel

# Cached like the wrister config: _update_slapper_charge now re-solves the release
# every windup tick (120 Hz × actors, replayed on reconcile) to publish
# predicted_shot_velocity, so a fresh SlapperConfig per call would be per-tick heap
# churn. Rebuilt lazily; invalidated in apply_attributes when the source exports change.
var _cached_slapper_cfg: ShotMechanics.SlapperConfig = null

func _slapper_config() -> ShotMechanics.SlapperConfig:
	if _cached_slapper_cfg == null:
		_cached_slapper_cfg = ShotMechanics.SlapperConfig.new()
		_cached_slapper_cfg.min_slapper_power = min_slapper_power
		_cached_slapper_cfg.max_slapper_power = max_slapper_power
		_cached_slapper_cfg.max_slapper_charge_time = max_slapper_charge_time
		_cached_slapper_cfg.loft_vy_low = loft_vertical_speed_low
		_cached_slapper_cfg.loft_vy_high = loft_vertical_speed_high
		_cached_slapper_cfg.loft_tan_max = loft_tan_max
	return _cached_slapper_cfg
