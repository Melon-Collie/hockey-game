class_name SkaterController
extends Node

# ── State Machine ─────────────────────────────────────────────────────────────
# Type alias so LocalController and RemoteController keep compiling without
# changes when they reference State.X values or use State as a type annotation.
const State = SkaterStateMachine.State
var _sm: SkaterStateMachine = SkaterStateMachine.new()

# ── Movement Tuning ───────────────────────────────────────────────────────────
@export var thrust: float = 10.5
@export var friction: float = 0.8
@export var friction_drag: float = 0.27
@export var max_speed: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
@export var move_deadzone: float = 0.1
@export var brake_multiplier: float = 4.0
@export var puck_carry_speed_multiplier: float = 0.86
@export var backward_thrust_multiplier: float = 0.80
@export var crossover_thrust_multiplier: float = 0.90
# ── Sprint / Stamina Tuning ───────────────────────────────────────────────────
# Sprint (Shift) burns a stamina pool for a top-speed burst. Boost is primarily
# the speed cap; a smaller thrust bump lets you actually reach it. Stamina is a
# 0..1 fraction; drain/regen are fractions-per-second. Flat for every player in
# v1 (not attribute-scaled) — but the cap they multiply, max_speed, is already
# Speed-scaled, so faster skaters get a proportionally faster sprint for free.
@export var sprint_max_speed_multiplier: float = 1.18
@export var sprint_thrust_multiplier: float = 1.20
@export var sprint_drain_per_sec: float = 0.45         # ~2.2s of full sprint off-puck
@export var sprint_carry_drain_multiplier: float = 1.6 # carrying drains faster (~1.4s)
@export var stamina_regen_per_sec: float = 0.30        # ~3.3s to refill from empty
@export var sprint_unlock_fraction: float = 0.5        # exhausted → recover to here before sprinting again
# Turn-rate scale while sprinting (< 1.0 = wider, lazier turns). This is the
# tradeoff that makes sprint a decision rather than a hold-always button:
# committed straight-line speed at the cost of agility, mirroring the
# hustle/turn-radius coupling in sim hockey games. Scales facing_drag_speed in
# SkaterPoseCoordinator.apply_facing. Deterministic from sprint_active, so it
# re-derives identically through reconcile replay (no new wire state).
@export var sprint_turn_multiplier: float = 0.55
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
# With the upper body at ~0.95 m world Y and blade at 0.0 (ice), -0.17 gives
# a hand world Y of ~0.78 m and a stick angle of ~37° — shallower than the
# previous ~47° and closer to a real hockey address position. Horizontal reach
# at rest rises from ~0.89 m to ~1.04 m.
@export var hand_rest_y: float = -0.17
# Ceiling for hand Y in the CLOSE regime. When aiming very close to the
# skater, the hand rises to shorten the stick's horizontal projection; this
# cap keeps the pose anatomical (hand won't climb past chin level). With
# default stick_length = 1.30 m, hand_y_max = 0.30 → min horizontal stick
# reach ≈ 0.36 m.
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
@export var rom_forehand_reach_max: float = 0.45
@export var rom_backhand_reach_max: float = 0.70
# Cap on how fast the aim target can move in world XZ per second. Smooths fast
# mouse wraps across the back of the player (avoiding the blade snap that
# crossing the IK ROM boundary used to produce) and ROM-clamp pops near the
# reach limit. The IK consumes the smoothed target, so the blade visibly
# inherits the cap. Tune up if normal aim feels laggy; tune down if wraps still
# feel snappy.
@export var max_blade_speed: float = 60.0

# ── Bottom-Hand IK Tuning ─────────────────────────────────────────────────────
# The bottom hand is purely reactive: each tick it targets a point a short way
# down the stick shaft (from the top hand toward the blade). It releases toward
# a shoulder rest only when the blade's world angle exceeds the upper body's
# rotation limit — ensuring the hand stays connected during any normal swing.
# Never influences blade placement. See domain/rules/bottom_hand_ik.gd.
# Fraction along the shaft (0 = top hand, 1 = blade heel) that the bottom hand
# grips. ~0.25 on a 1.30 m shaft ≈ a typical hockey grip width.
@export var bottom_hand_grip_fraction: float = 0.25
# Bottom hand resting Y in upper-body-local. Same height as top hand rest.
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
@export var upper_body_lean_max_deg: float = 15.0
@export var upper_body_lean_return_speed: float = 8.0

# ── Velocity Lean Tuning ──────────────────────────────────────────────────────
@export var velocity_lean_max_deg: float = 10.0
@export var velocity_lean_speed: float = 6.0

# ── Lower Body Lag Tuning ─────────────────────────────────────────────────────
@export var lower_body_lag_max_deg: float = 20.0
@export var lower_body_lag_speed: float = 5.0

# ── Skating Stride Tuning ─────────────────────────────────────────────────────
# Procedural leg gait — see SkaterSkatingCoordinator. All cosmetic. Forward,
# backward, and lateral (crossover) gaits blend by direction of travel.
@export var stride_cadence: float = 1.4          # low-speed slope: radians of stride phase per metre skated
@export var stride_cadence_max_rate: float = 6.5  # rad/s ceiling the cadence saturates toward (caps sprint leg turnover)
@export var stride_roll_deg: float = 7.0          # side-to-side leg rock amplitude (fwd/back)
@export var stride_pitch_deg: float = 6.0         # forward push amplitude (fore/aft)
@export var stride_back_pitch_deg: float = 4.0    # backward C-cut amplitude (reaches forward)
@export var crossover_lean_deg: float = 6.0       # static lean into the crossover direction
@export var crossover_scissor_deg: float = 8.0    # legs scissor laterally across each other
@export var stride_knee_deg: float = 18.0         # knee flex depth on the recovery half-stroke
@export var stride_intensity_speed: float = 6.0   # how fast the legs ease in/out of motion

# ── Wrister Tuning ────────────────────────────────────────────────────────────
@export var min_wrister_power: float = GameRules.DEFAULT_WRISTER_POWER_MIN_M_S
@export var max_wrister_power: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
@export var max_wrister_charge_distance: float = 0.7
@export var backhand_power_coefficient: float = 0.75
@export var max_charge_direction_variance: float = 35.0
@export var quick_shot_power: float = GameRules.DEFAULT_QUICK_SHOT_POWER_M_S
# Absolute charge_distance (in meters of blade travel) below which the
# wrister releases as a quick shot. Independent of max_wrister_charge_distance
# so the snap-tap feel is the same across attribute spreads — a 0.15m drag
# is a quick shot regardless of who's shooting. Above this, the wrister
# lerps power between min and max based on charge ratio.
@export var quick_shot_threshold: float = 0.15
@export var quick_shot_elevation: float = 0.10
@export var wrister_elevation_target_height: float = 0.90
# Apex cap for elevated shots — puck can't rise more than this above the blade.
# 1.5 m is just under the glass, well above crossbar (1.22 m). On-net shots
# arrive at goal line at ≤ target_height; missed shots can't fly over boards.
@export var max_apex_above_blade: float = 1.5
# Cosine of the half-angle cone within which a shot counts as "toward the net".
# 0.5 = 60° cone. Shots outside this cone use `away_from_net_elevation` instead
# of the ballistic-targeting math.
@export var toward_net_dot_threshold: float = 0.5
# Fixed Y direction for elevated shots not aimed at the offensive net (passes,
# clears, backward dumps). Small positive value so the puck still lifts off ice
# without trying to arc toward an irrelevant target height.
@export var away_from_net_elevation: float = 0.10

# ── Head Tracking Tuning ─────────────────────────────────────────────────────
@export var head_track_speed: float = 12.0
@export var head_track_max_deg: float = 60.0

# ── Slapper Tuning ────────────────────────────────────────────────────────────
@export var slapper_wind_up_height: float = 1.0
@export var slapper_wind_up_time: float = 0.3
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
# body toward the back shoulder. Eased with sqrt so most of the coil happens
# early and the latter part of the wind-up is a held "loaded" pose.
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
# is tuned for gentle aim-tracking and only reaches ~85% of an 80° target
# inside the 0.3s wind-up window, which reads as a half-finished coil.
@export var slapper_wind_up_lerp_speed: float = 18.0
@export var slapper_elevation_target_height: float = 0.65
@export var one_timer_window_duration: float = 0.45  # seconds after puck arrives to release
@export var one_timer_leniency_time: float = 0.08   # seconds of puck travel added to zone radius as leniency
@export var one_timer_center_power_bonus: float = 0.10  # ±10%: edge of zone = −10%, dead centre = +10%

var show_one_timer_indicator: bool = false

# ── Follow Through Tuning ─────────────────────────────────────────────────────
@export var follow_through_duration: float = 0.25
@export var wrister_follow_through_hand_y: float = 0.35
@export var wrister_follow_through_blade_lift: float = 0.20
@export var slapper_follow_through_arc_dist: float = 0.4  # blade XZ travel along shot_dir during follow-through

# ── Shot-Block Tuning ─────────────────────────────────────────────────────────
# Movement speed while blocking (unused while the stance is fully planted; kept for tuning).
@export var block_speed_multiplier: float = 0.45
@export var active_block_dampen: float = 0.35      # puck energy retention on active block
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
@export var block_hand_y: float = -0.17      # top-hand height while blocking (m, local; matches hand_rest_y)

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
var _is_elevated: bool = false
var _aiming: SkaterAimingBehavior = SkaterAimingBehavior.new()
var _pose: SkaterPoseCoordinator = SkaterPoseCoordinator.new()
var _shot_pose: SkaterShotPoseCoordinator = SkaterShotPoseCoordinator.new()
var _skating: SkaterSkatingCoordinator = SkaterSkatingCoordinator.new()
var _ik: SkaterIKCoordinator = SkaterIKCoordinator.new()
var last_processed_host_timestamp: float = 0.0
var has_puck: bool = false
var is_replaying: bool = false
# Sprint stamina (0..1) and the exhaustion lockout latch. Updated deterministically
# each tick in _apply_movement; the local player's reconcile snaps both to the
# host's authoritative value before replay (see LocalController.reconcile) and
# the host broadcasts them via fill_network_state.
var stamina: float = 1.0
var _sprint_locked: bool = false
# Resolved sprint-boost state for this tick. Written in _apply_movement (which
# runs before _pose.apply_facing in _process_input) and read by the pose
# coordinator to apply the turn-rate penalty. Public so the pose collaborator
# can read it without a getter.
var sprint_active: bool = false

# ── Setup ─────────────────────────────────────────────────────────────────────
func setup(assigned_skater: Skater, assigned_puck: Puck, game_state: Node) -> void:
	skater = assigned_skater
	puck = assigned_puck
	_game_state = game_state
	_is_host = game_state.is_host()
	process_physics_priority = -1  # Run before Skater.move_and_slide
	skater.body_checked_player.connect(_on_body_checked_player)
	skater.body_block_hit.connect(_on_body_block_hit)
	_ik.setup(skater, self)
	_shot_pose.setup(skater, _sm, _aiming, _ik, self)
	var _cb := SkaterStateMachine.Callbacks.new()
	_cb.apply_blade_from_mouse = _ik.apply_blade_from_mouse
	_cb.apply_slapper_blade_position = _shot_pose.apply_slapper_blade_position
	_cb.apply_block_blade_position = _shot_pose.apply_block_blade_position
	_cb.apply_wrister_follow_through = _shot_pose.apply_wrister_follow_through
	_cb.apply_slapper_follow_through = _shot_pose.apply_slapper_follow_through
	_cb.enter_shot_block = _enter_shot_block
	_cb.enter_slapper_charge = _enter_slapper_charge
	_cb.transition_to_skating = _transition_to_skating
	_cb.release_wrister = _release_wrister
	_cb.release_slapper = _release_slapper
	_cb.try_one_timer_release = _try_one_timer_release
	_cb.update_wrister_charge = _update_wrister_charge
	_cb.update_slapper_charge = _update_slapper_charge
	_cb.apply_slapper_velocity_drag = _apply_slapper_velocity_drag
	_cb.apply_block_movement = _apply_block_movement
	_sm.setup(_cb, _aiming)
	_pose.setup(skater, _sm, _aiming, self)
	_skating.setup(skater, _sm, self)

# Reach ROM is derived from arm length, not an independent tunable. These
# ratios reflect anatomy: forehand reach is shoulder-joint-limited (about
# 56% of arm length, can't cross the body very far); backhand reach is
# arm-extension-limited (about 87.5% of arm length, near-full extension
# out to the same side). Constant ratios mean the arm-bend at the ROM cap
# looks the same on every player, big or small.
const _ROM_FOREHAND_OF_ARM: float = 0.5625
const _ROM_BACKHAND_OF_ARM: float = 0.875


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
var _base_min_wrister_power:            float = 0.0
var _base_max_wrister_power:            float = 0.0
var _base_quick_shot_power:             float = 0.0
var _base_min_slapper_power:            float = 0.0
var _base_max_slapper_power:            float = 0.0
var _base_max_wrister_charge_distance:  float = 0.0
var _base_max_slapper_charge_time:      float = 0.0
var _base_puck_carry_speed_multiplier:  float = 0.0
var _base_stick_length:                 float = 0.0
var _base_skater_upper_arm_length:      float = 0.0
var _base_skater_forearm_length:        float = 0.0
var _base_skater_weight:                float = 0.0
var _base_skater_body_check_transfer:   float = 0.0
var _base_skater_body_check_brace_resistance: float = 0.0
var _base_skater_collision_radius:      float = 0.0
var _base_skater_collision_height:      float = 0.0


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
	var m_speed:    float = attrs.speed_mult()
	var m_agility:  float = attrs.agility_mult()
	var m_size:     float = attrs.size_mult()
	var m_strength: float = attrs.strength_mult()
	var m_height:   float = attrs.height_mult()
	thrust    = _base_thrust    * m_speed
	max_speed = _base_max_speed * m_speed
	facing_drag_speed           = _base_facing_drag_speed           * m_agility
	facing_drag_speed_braking   = _base_facing_drag_speed_braking   * m_agility
	brake_multiplier            = _base_brake_multiplier            * m_agility
	# friction_drag is velocity-proportional drag — scaling it inversely
	# with Agility gives agile players the "good edges" feel: less momentum
	# leaks through the blades during a cut, so they carry more speed out
	# of turns. Lateral / backward thrust multipliers are universal — every
	# skater shares the same forward > lateral > backward shape; what makes
	# Slick agile is how cleanly they transition between those directions.
	friction_drag               = _base_friction_drag               * attrs.agility_glide_mult()
	puck_carry_speed_multiplier = _base_puck_carry_speed_multiplier * attrs.agility_carry_mult()
	# Shot powers use the narrower Strength-Shot multiplier (±15%) rather
	# than canonical Strength (±25%) so the wrister floor stays playable
	# for low-Strength shooters. Charge speed uses its own inverted table.
	var m_shot_power: float = attrs.strength_shot_mult()
	min_wrister_power = _base_min_wrister_power * m_shot_power
	max_wrister_power = _base_max_wrister_power * m_shot_power
	quick_shot_power  = _base_quick_shot_power  * m_shot_power
	min_slapper_power = _base_min_slapper_power * m_shot_power
	max_slapper_power = _base_max_slapper_power * m_shot_power
	# Charge cap scales with both Strength (how easy to load) and Size (so the
	# cap stays a constant fraction of the player's ROM — small players can
	# still fill the bar with their own full-reach sweep).
	max_wrister_charge_distance = _base_max_wrister_charge_distance * attrs.strength_charge_mult() * attrs.size_charge_mult()
	max_slapper_charge_time     = _base_max_slapper_charge_time     * attrs.strength_charge_mult()
	# Weight uses the narrower SIZE_WEIGHT spread (±12%) instead of canonical
	# Size (±18%) so the weight_ratio in the check formula doesn't dominate
	# the Strength-driven body_check_transfer. Brace and hitbox stay on
	# canonical Size.
	skater.weight                       = _base_skater_weight                  * attrs.size_weight_mult()
	skater.body_check_transfer          = _base_skater_body_check_transfer     * m_strength
	# Inverse: brace_resistance is a coefficient on incoming transfer when
	# the victim is braced — *lower* = better resistance. A bigger-Size
	# player should resist knockback better, so the multiplier flips.
	skater.body_check_brace_resistance = _base_skater_body_check_brace_resistance * (2.0 - m_size)
	# Arms and stick scale with actual height (the dedicated height_mult,
	# tighter than the gameplay size_mult) — keeps proportions realistic so
	# a taller player has a correspondingly longer arm and stick rather than
	# looking awkward with a baseline-length stick. update_stick_mesh() and
	# the arm bone wrappers recompute visuals from these every frame, so no
	# separate visual pass is needed.
	stick_length              = _base_stick_length              * m_height
	skater.upper_arm_length   = _base_skater_upper_arm_length   * m_height
	skater.forearm_length     = _base_skater_forearm_length     * m_height
	# Reach ROM is a derived property of arm length — the ratios reflect
	# fixed anatomy (forehand is shoulder-limited, backhand uses near-full
	# extension), so they stay constant across sizes. Bigger arms naturally
	# yield more reach without being an independent attribute axis. The
	# arm-bend at the ROM cap is consistent (~87.5% extension on backhand)
	# for every player, so small skaters don't look rigid at full reach.
	var arm_total: float = skater.upper_arm_length + skater.forearm_length
	rom_forehand_reach_max    = arm_total * _ROM_FOREHAND_OF_ARM
	rom_backhand_reach_max    = arm_total * _ROM_BACKHAND_OF_ARM
	# Hitbox: cylinder radius scales with the wider gameplay Size multiplier
	# (matches body-check feel), height with the realistic-proportions
	# multiplier. Skater._ready() duplicated the shape so this mutation is
	# per-instance and won't leak across skaters.
	var col: CollisionShape3D = skater.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null:
		var cyl: CylinderShape3D = col.shape as CylinderShape3D
		if cyl != null:
			cyl.radius = _base_skater_collision_radius * m_size
			cyl.height = _base_skater_collision_height * m_height
	# Attribute scaling rewrote the exports the cached configs were built
	# from — drop them so the next tick rebuilds with the new values.
	_ik.invalidate_configs()
	_cached_move_cfg = null
	_cached_block_move_cfg = null
	skater.apply_appearance(attrs)


func _capture_attribute_bases() -> void:
	_base_thrust                       = thrust
	_base_max_speed                    = max_speed
	_base_facing_drag_speed            = facing_drag_speed
	_base_facing_drag_speed_braking    = facing_drag_speed_braking
	_base_brake_multiplier             = brake_multiplier
	_base_friction_drag                = friction_drag
	_base_min_wrister_power            = min_wrister_power
	_base_max_wrister_power            = max_wrister_power
	_base_quick_shot_power             = quick_shot_power
	_base_min_slapper_power            = min_slapper_power
	_base_max_slapper_power            = max_slapper_power
	_base_max_wrister_charge_distance  = max_wrister_charge_distance
	_base_max_slapper_charge_time      = max_slapper_charge_time
	_base_puck_carry_speed_multiplier  = puck_carry_speed_multiplier
	_base_stick_length                 = stick_length
	_base_skater_upper_arm_length      = skater.upper_arm_length
	_base_skater_forearm_length        = skater.forearm_length
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

func _on_body_block_hit(body: Node3D) -> void:
	if not _is_host:
		return
	if not body is Puck:
		return
	var dampen: float = active_block_dampen if _sm.get_state() == State.SHOT_BLOCKING else puck.body_block_dampen
	puck.on_body_block(skater, dampen)

# ── Entry Point ───────────────────────────────────────────────────────────────
func _process_input(input: InputState, delta: float) -> void:
	# Snapshot the blade's current contact point before any IK mutation runs
	# this tick. The host's swept-segment pickup/poke test (PuckController._check_interactions,
	# priority 1) reads this later in the tick as `blade_prev`; combined with the
	# post-IK + post-move_and_slide `blade_curr`, the segment spans both the IK
	# sweep and the body motion. Capturing here in every controller path
	# (Local / Remote / AI) keeps the test consistent across input sources.
	skater.capture_prev_blade_contact()
	if input.elevation_up:
		_is_elevated = true
	if input.elevation_down:
		_is_elevated = false
	skater.is_elevated = _is_elevated

	# Stick lift (Q). Voluntary lift is gated on NOT carrying — you can't raise
	# your own blade off the puck while stickhandling. A forced lift (an opponent
	# hooked under your stick) overrides regardless of possession and is what
	# dislodges the carried puck.
	skater.blade_up = (input.stick_lift_held and not has_puck) or skater.is_forced_lift_active()

	_apply_movement(input, delta)
	_pose.apply_velocity_lean(delta)
	_pose.apply_facing(input, delta)
	_apply_state(input, delta)
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
	_pose.apply_head_tracking(input, delta)
	if not is_slapper_charge:
		skater.set_top_hand_position(skater.upper_body_to_local(hand_world_pre))
		skater.set_blade_position(skater.upper_body_to_local(blade_world_pre))
	_ik.update_bottom_hand()
	# Stick/arm mesh updates moved to Skater._process — they're write-only
	# visuals recomputed from the markers this tick just placed, so one pass
	# per rendered frame (after all physics ticks) replaces the per-tick (and
	# per-reconcile-replayed-input) passes that used to run here.
	if not is_replaying:
		_pose.update_angular_velocities(delta)
		# Cosmetic leg gait — derived from velocity, so it's skipped during replay
		# (reconcile re-simulates many ticks per frame and would over-spin the phase).
		_skating.apply(delta)


# Aim-only blade update for FACEOFF_PREP: drives the blade target from the
# mouse, twists the upper body and head to follow it, and refreshes the
# dependent IK + visual meshes. Skips movement, lower-body facing rotation
# (the skater stays squared up to the dot), and state-machine dispatch.
# Callers must already have confirmed the phase allows blade aim during a
# locked phase.
func apply_blade_aim_only(input: InputState, delta: float) -> void:
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
	state.is_elevated = skater.is_elevated
	state.blade_up = skater.blade_up
	# Host-only shaft segment for stick-lift claim resolution (paired with
	# blade_contact_world). World-space grip point — the wire top_hand_position
	# is upper-body-local and can't be used for host-side world geometry.
	state.top_hand_world = skater.upper_body_to_global(skater.get_top_hand_position())
	state.shot_state = _sm.get_state() as int
	state.shot_charge = _aiming.charge_distance
	state.stamina = stamina
	state.sprint_locked = _sprint_locked

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
	skater.global_position = state.position
	skater.visual_offset = Vector3.ZERO
	skater.velocity = state.velocity
	skater.blade_up = state.blade_up
	stamina = state.stamina
	_sprint_locked = state.sprint_locked
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

signal puck_release_requested(direction: Vector3, power: float, is_slapper: bool)
# Fired when the player releases slap while the puck is nearby but not yet
# carried — the leniency one-timer. GameManager acquires + releases the puck;
# the controller transitions to follow-through immediately.
signal one_timer_release_requested(direction: Vector3, power: float)

func _do_release(direction: Vector3, power: float) -> void:
	if is_replaying:
		return
	var slapper: bool = _sm.get_state() == State.SLAPPER_CHARGE_WITH_PUCK
	puck_release_requested.emit(direction, power, slapper)

# ── Puck Signals ──────────────────────────────────────────────────────────────
func on_puck_picked_up_network() -> void:
	has_puck = true
	var local_blade: Vector3 = skater.get_blade_position() - skater.shoulder.position
	_blade_relative_angle = atan2(local_blade.x, -local_blade.z)
	if _sm.get_state() == State.SLAPPER_CHARGE_WITHOUT_PUCK:
		# One-timer: puck arrived during a slapper charge. Open the timing
		# window — player must release within one_timer_window_duration or
		# the shot is cancelled and they keep the puck in carry state.
		skater.set_slapper_zone(false)
		skater.set_slapper_mode(true)
		# Pin the just-attached puck to the ice for the one-timer window — same
		# as the carry → slapshot entry path. Without this the puck snaps to
		# the overhead blade contact the moment it attaches.
		var blade_side_sign: float = -1.0 if skater.is_left_handed else 1.0
		skater.enter_slapshot_pinning(blade_side_sign * slapper_zone_offset_x, slapper_zone_offset_z)
		_aiming.one_timer_window_timer = one_timer_window_duration + NetworkManager.get_latest_rtt_ms() / 2000.0
		_sm.set_state(State.SLAPPER_CHARGE_WITH_PUCK)
		if show_one_timer_indicator:
			skater.update_slapper_indicator_convergence(1.0)
			skater.update_slapper_indicator_window(1.0)
	else:
		_sm.set_state(State.SKATING_WITH_PUCK)

func on_puck_released_network() -> void:
	if not has_puck:
		return
	has_puck = false
	_transition_to_skating()

func teleport_to(pos: Vector3, facing: Vector2 = Vector2.ZERO) -> void:
	skater.global_position = pos
	skater.velocity = Vector3.ZERO
	# Fresh legs out of a faceoff / respawn — refill the stamina pool and clear
	# any exhaustion lockout so play resumes from a clean slate.
	stamina = 1.0
	_sprint_locked = false
	sprint_active = false
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

# Cancels an in-progress wrister/slapper wind-up. No-op unless actually mid-
# charge, so a routine teleport doesn't disturb skating state. Suppresses the
# charge-lost flash since a forced respawn isn't player-initiated charge loss.
func _cancel_active_charge() -> void:
	var s: int = _sm.get_state()
	if s != State.WRISTER_AIM and s != State.SLAPPER_CHARGE_WITH_PUCK \
			and s != State.SLAPPER_CHARGE_WITHOUT_PUCK:
		return
	_aiming.reset_slapper()
	_aiming.charge_distance = 0.0
	_transition_to_skating(true)

# ── State Machine ─────────────────────────────────────────────────────────────
func _apply_state(input: InputState, delta: float) -> void:
	var prev_state: int = _sm.get_state()
	_sm.dispatch(skater, input, delta, has_puck, _game_state.is_movement_locked())
	if prev_state != State.WRISTER_AIM and _sm.get_state() == State.WRISTER_AIM:
		_aiming.wrister_start_blade_local_x = skater.get_blade_position().x

# ── State Helpers ─────────────────────────────────────────────────────────────
func _transition_to_skating(suppress_lost_flash: bool = false) -> void:
	# Lost-charge feedback: if we're leaving an active charge state without
	# firing (i.e. not via FOLLOW_THROUGH), flash the charge ring red. The
	# ring auto-clears via Skater._physics_process once the flash decays.
	var prev_state: int = _sm.get_state()
	var was_charging: bool = prev_state == State.WRISTER_AIM \
			or prev_state == State.SLAPPER_CHARGE_WITH_PUCK \
			or prev_state == State.SLAPPER_CHARGE_WITHOUT_PUCK
	skater.shot_charge = 0.0
	skater.slapper_aim_dir = Vector3.ZERO
	if has_puck:
		_sm.set_state(State.SKATING_WITH_PUCK)
	else:
		_sm.set_state(State.SKATING_WITHOUT_PUCK)
	_sm.shot_dir = Vector3.ZERO
	_pose.reset_lean_and_lag()
	skater.set_lower_body_lag(0.0)
	skater.set_slapper_mode(false)
	skater.set_slapper_zone(false)
	skater.exit_slapshot_pinning()
	_hide_slapshot_hud()
	if show_one_timer_indicator and was_charging and not suppress_lost_flash:
		skater.trigger_charge_lost_flash()

func _enter_shot_block() -> void:
	_sm.set_state(State.SHOT_BLOCKING)
	skater.set_block_stance(true)
	# Square the upper body and clear lean/lag so the choreographed block pose
	# (authored in upper-body-local space) points straight along the snapped
	# facing instead of inheriting residual twist from the prior state. The torso
	# pose pipeline early-returns during SHOT_BLOCKING, so these stay put for the
	# duration of the stance.
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
	# Lock aim direction from the actual blade-side release point → mouse.
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
	_pose.reset_lean_and_lag()
	skater.set_upper_body_rotation(0.0)
	skater.set_upper_body_lean(0.0)
	skater.set_lower_body_lean(0.0, 0.0)
	skater.set_lower_body_lag(0.0)
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
		skater.set_charge_ring_visible(true)
		skater.set_slapshot_arrow(true, slapper_zone_offset_x, slapper_zone_offset_z, slapper_zone_radius)
		skater.update_slapshot_arrow_direction(skater.slapper_aim_dir)

func _get_charge_direction() -> Vector3:
	# prev_blade_dir is the screen-space cursor drag direction packed
	# (x, 0, y), already in world XZ frame: LocalInputGatherer negates
	# mouse_screen_pos for attack_up team 1, so by the time the tracker
	# records this direction it's been pre-aligned with world XZ for
	# both screen-pos and the blade frame the magnitude reads from.
	# Don't re-flip here — that would invert correct shots.
	return _aiming.prev_blade_dir

func _release_wrister(input: InputState) -> void:
	if has_puck:
		var blade_world: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
		# _prev_blade_dir is the world-space direction the cursor was dragged
		# (relative to the player, so skating velocity is already removed).
		var is_backhand: bool = \
				_aiming.wrister_start_blade_local_x * (1.0 if skater.is_left_handed else -1.0) > 0.0
		var result := ShotMechanics.release_wrister(
				skater.global_position,
				input.mouse_world_pos,
				blade_world,
				is_backhand,
				_is_elevated,
				_aiming.charge_distance,
				_wrister_config(),
				_get_charge_direction())
		_sm.shot_dir = result.direction
		_do_release(result.direction, result.power)

	_sm.follow_through_is_slapper = false
	_sm.set_state(State.FOLLOW_THROUGH)
	_sm.follow_through_timer = follow_through_duration

func _release_slapper(input: InputState, one_timer: bool = false) -> void:
	if has_puck:
		# Direction is locked at the moment slap was pressed — no mid-swing steering.
		var locked_dir_3d := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
		var cfg: ShotMechanics.SlapperConfig = _slapper_config()
		# One-timers always fire at max power regardless of actual charge built.
		var charge: float = cfg.max_slapper_charge_time if one_timer else _aiming.slapper_charge_timer
		var result := ShotMechanics.release_slapper(
				skater.upper_body_to_global(skater.get_blade_position()),
				input.mouse_world_pos,
				_is_elevated,
				charge,
				cfg,
				locked_dir_3d)
		_sm.shot_dir = result.direction
		_do_release(result.direction, result.power)

	_sm.follow_through_is_slapper = true
	_sm.set_state(State.FOLLOW_THROUGH)
	_sm.follow_through_timer = follow_through_duration
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
	skater.set_charge_ring_visible(false)

func _update_wrister_charge(input: InputState) -> void:
	if not has_puck:
		return
	# Direction signal: cursor SCREEN position, packed (x, 0, y) for the
	# tracker's Vector3 interface. Screen space is the camera-immune
	# frame — pixel motion captures the player's mouse drag intent
	# independent of camera lag, body rotation, or skater locomotion.
	var intent_pos := Vector3(input.mouse_screen_pos.x, 0.0, input.mouse_screen_pos.y)
	# Magnitude signal: blade world position with skater translation subtracted.
	# ROM clamping inside apply_blade_from_mouse has already run this tick, so a
	# cursor past the reach limit produces zero delta here — no charge growth
	# from cursor motion that the blade physically didn't follow.
	var blade_world: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
	var blade_pos_rel_skater: Vector3 = blade_world - skater.global_position
	blade_pos_rel_skater.y = 0.0
	_aiming.tick_wrister_charge(
			intent_pos, blade_pos_rel_skater,
			max_charge_direction_variance, max_wrister_charge_distance)
	skater.shot_charge = _aiming.charge_distance / max_wrister_charge_distance
	# Charge ring is local-only; gate on the same flag as the one-timer reticle.
	if show_one_timer_indicator:
		skater.set_charge_ring_visible(true)

func _update_slapper_charge(delta: float) -> void:
	_aiming.tick_slapper(delta)
	skater.shot_charge = minf(_aiming.slapper_charge_timer / max_slapper_charge_time, 1.0)
	if show_one_timer_indicator:
		skater.update_slapshot_arrow_direction(skater.slapper_aim_dir)

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
		return {fired = false}
	var blade_world: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
	var locked_dir_3d := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
	var cfg: ShotMechanics.SlapperConfig = _slapper_config()
	var result := ShotMechanics.release_slapper(
			blade_world, input.mouse_world_pos,
			_is_elevated, cfg.max_slapper_charge_time, cfg, locked_dir_3d)
	var proximity: float = clampf(1.0 - dist / slapper_zone_radius, 0.0, 1.0)
	result.power *= 1.0 + one_timer_center_power_bonus * (2.0 * proximity - 1.0)
	if not is_replaying:
		one_timer_release_requested.emit(result.direction, result.power)
	# Same as _release_slapper — hide the HUD as soon as the shot fires so it
	# doesn't ride along through the follow-through.
	_hide_slapshot_hud()
	return {fired = true, direction = result.direction, follow_through_duration = follow_through_duration}

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

	var move_state: SkaterStateMachine.State = _sm.get_state()
	# Locomotion is suppressed during a planted slap windup / block stance, but
	# stamina still ticks (you can't sprint, so it regenerates). Computing it
	# before the early-return keeps the bar honest through those states.
	var locomotion_suppressed: bool = \
			move_state == State.SLAPPER_CHARGE_WITH_PUCK or move_state == State.SHOT_BLOCKING
	var is_moving: bool = not input.brake and input.move_vector.length() > move_deadzone
	sprint_active = not locomotion_suppressed and StaminaRules.sprint_active(
			stamina, input.sprint_held, is_moving, _sprint_locked)
	var stamina_cfg: StaminaRules.StaminaConfig = _stamina_config()
	stamina = StaminaRules.next_stamina(stamina, sprint_active, has_puck, delta, stamina_cfg)
	_sprint_locked = StaminaRules.next_locked(_sprint_locked, stamina, sprint_active, stamina_cfg)

	if locomotion_suppressed:
		return

	var cfg: SkaterMovementRules.MovementConfig = _movement_config()
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
	return _cached_stamina_cfg

func _wrister_config() -> ShotMechanics.WristerConfig:
	var cfg := ShotMechanics.WristerConfig.new()
	cfg.min_wrister_power = min_wrister_power
	cfg.max_wrister_power = max_wrister_power
	cfg.max_wrister_charge_distance = max_wrister_charge_distance
	cfg.backhand_power_coefficient = backhand_power_coefficient
	cfg.quick_shot_power = quick_shot_power
	cfg.quick_shot_threshold = quick_shot_threshold
	cfg.quick_shot_elevation = quick_shot_elevation
	cfg.elevation_target_height = wrister_elevation_target_height
	cfg.elevation_blade_height = 0.05
	cfg.elevation_gravity = 9.8
	cfg.elevation_goal_line_z = GameRules.GOAL_LINE_Z
	cfg.max_apex_above_blade = max_apex_above_blade
	cfg.attacking_goal_z = get_attacking_goal_z()
	cfg.toward_net_dot_threshold = toward_net_dot_threshold
	cfg.away_from_net_y = away_from_net_elevation
	return cfg

func _slapper_config() -> ShotMechanics.SlapperConfig:
	var cfg := ShotMechanics.SlapperConfig.new()
	cfg.min_slapper_power = min_slapper_power
	cfg.max_slapper_power = max_slapper_power
	cfg.max_slapper_charge_time = max_slapper_charge_time
	cfg.elevation_target_height = slapper_elevation_target_height
	cfg.elevation_blade_height = 0.05
	cfg.elevation_gravity = 9.8
	cfg.elevation_goal_line_z = GameRules.GOAL_LINE_Z
	cfg.max_apex_above_blade = max_apex_above_blade
	cfg.attacking_goal_z = get_attacking_goal_z()
	cfg.toward_net_dot_threshold = toward_net_dot_threshold
	cfg.away_from_net_y = away_from_net_elevation
	return cfg

# Signed Z of the goal this skater is attacking. Default 0.0 means "team
# unknown" — the elevation math falls back to picking a goal by shot_dir.z
# sign. LocalController overrides this once team_id is set.
func get_attacking_goal_z() -> float:
	return 0.0
