class_name GoalieController
extends Node

# AI orchestrator. Owns tracking, depth/position/facing math, and the per-tick
# wiring between four collaborators that hold the actual mutable state:
#   _sm       — GoalieStateMachine     (current state enum + recovery timer)
#   _slide    — GoalieSlideBehavior    (butterfly slide commit/decay, drop animation)
#   _reaction — GoalieShotReaction     (reaction freeze + shot/arm processing timers)
#   _pose     — GoalieBodyConfigBuilder (pure pose math, one per-tick scratch config)
# All tuning exports stay here for editor access; setup() pushes the relevant
# values into each collaborator.

# ── Tuning ────────────────────────────────────────────────────────────────────
@export var catches_left: bool = true

@export var depth_aggressive: float = 1.2
@export var depth_base: float = 0.6
@export var depth_conservative: float = 0.3
@export var depth_defensive: float = 0.1
@export var zone_post_z: float = 2.0
@export var zone_aggressive_z: float = 8.0
@export var zone_base_z: float = 12.0
@export var zone_conservative_z: float = 20.0
# How fast `_current_depth` lerps toward the depth-chart target. Higher =
# faster retreat when the skater closes. At 2.0 the lerp couldn't catch a
# fast-closing skater inside 2m (depth chart's retreat zone); bumped to
# 4.0 so a 0.25s approach (8 m/s closing 2m) converges ~63% — goalie
# meaningfully retreats before contact instead of being stuck out front.
@export var depth_speed: float = 4.0

@export var shuffle_speed: float = 2.0
@export var t_push_speed: float = GameRules.DEFAULT_GOALIE_T_PUSH_SPEED_M_S
@export var lateral_threshold: float = 0.3
@export var max_facing_angle: float = 70.0
@export var rotation_speed: float = 5.0
@export var rvh_transition_speed: float = 6.0

@export var reaction_delay: float = GameRules.DEFAULT_GOALIE_REACTION_DELAY_S
# Arms specifically take longer to react than legs. Legs are reflexive (drop
# instantly when the brain reads "low shot"); arms require "where in the
# upper net" computation which adds processing time. Setting this longer
# than `reaction_delay` makes close-range top-corner shots score because
# the arm doesn't even start moving in time. Long shots still allow full
# extension once the arm clears the delay.
@export var arm_reaction_delay: float = 0.18

@export var shot_speed_threshold: float = 5.0
@export var net_half_width: float = 0.915
# Margin past the net edges for "is this a shot on goal" classification.
# Generous on purpose — real goalies track anything heading at their general
# area, even shots clearly going wide (could deflect, tip, rebound). Cross-
# crease passes self-filter through `detect_shot`'s velocity-direction check
# (low z-velocity → huge t_to_goal → impact_x lands way off-net), so a wide
# margin doesn't pull passes in. Pickup / boards / post / net signals clear
# the reaction freeze if it does turn out to be a pass.
@export var net_margin: float = 3.0

@export var rvh_depth: float = 0.1
@export var rvh_early_angle: float = 80.0
@export var rvh_post_pad_angle: float = 15.0

@export var five_hole_base: float = 0.02
@export var five_hole_shuffle_max: float = 0.06
@export var five_hole_t_push_max: float = 0.15

@export var tracking_speed: float = 6.0
@export var part_lerp_speed: float = 6.0
@export var reaction_lerp_speed: float = 18.0
# Recovery rises body parts from butterfly pose → READY pose. Default tuned
# so the rise is ~95% complete by `recovery_duration = 0.35 s` (lerp speed
# ≈ 3 / duration). Was 3.0 which only converged ~65% — body still looked
# half-butterfly when recovery ended.
@export var recovery_lerp_speed: float = 9.0

# ── Threat tracking ───────────────────────────────────────────────────────────
# "Play the chest, not the puck": carrier body is steady while the puck swings
# ±1.5 m during stickhandling. Higher weights track the carrier; pure-puck
# tracking causes the goalie to shuffle perfectly into 5-hole shots.
@export var shooter_weight_standing: float = 0.55
@export var shooter_weight_butterfly: float = 0.75  # more committed when down
# Lead-the-target time. Threat position projects forward by
# `carrier.velocity * carrier_velocity_lead_time` so the goalie pre-positions
# toward where the carrier WILL be — the realistic answer to "skater is
# faster than the goalie laterally." Sustained lateral skates (8 m/s) lead
# 1.4 m at 0.18s, meaningful for sweeps and wraparounds. Stickhandling
# jitter has small velocities (~1-2 m/s) so the lead barely moves
# (0.2-0.4 m), and the existing tracking-speed lerp smooths brief deke
# velocity spikes so quick fakes don't drag the goalie out of position.
@export var carrier_velocity_lead_time: float = 0.18

# Close-crease auto-butterfly. When an opposing carrier is at the doorstep
# the goalie can't track laterally fast enough; better to commit butterfly
# and slide-react. Different from the old `is_under_pressure` (2.5 m + 1 m/s)
# which fired far enough out to be exploitable — this only fires inside the
# crease where dropping is the correct read regardless of follow-up play.
@export var close_crease_butterfly_distance: float = 2.0
@export var close_crease_butterfly_speed: float = 1.5  # carrier must show intent

# Crease-jam butterfly. Loose puck or stationary-carrier puck inside the
# jam zone with an opposing skater close enough to whack at it — drop and
# seal even though nobody's "shooting" yet. Without this, bots that crowd
# the crease and pivot-stickhandle keep the goalie upright indefinitely
# because the carrier-at-doorstep check requires meaningful velocity and
# loose pucks have no carrier at all.
@export var jam_puck_distance: float = 2.0    # m — puck-to-goalie threshold
@export var jam_opponent_distance: float = 1.5 # m — opposing-skater-to-puck threshold

# ── Butterfly commitment ─────────────────────────────────────────────────────
# Once the goalie drops they cannot stand-skate. Lateral movement is via
# committed butterfly slides only. They cannot reach RVH directly — must
# stand up first (RECOVERING window).
@export var butterfly_min_hold_time: float = 0.35   # s the goalie must stay down
@export var recovery_duration: float = 0.35         # s spent standing back up
@export var butterfly_drop_speed: float = 0.08      # s for pads to close to floor
@export var butterfly_radius: float = 0.40          # arc radius from goal center while down

# ── Butterfly slide (pivot-and-ride) ─────────────────────────────────────────
# Real goalies plant the outside (non-post) leg, pivot off it, and swing the
# sealing leg through to the post. The body rotates around the push-off foot
# rather than translating laterally — the path is an arc, not a straight line.
# Destination is committed at slide-start; mid-slide can't correct. That's the
# realism win — fast cross-passes can beat the slide because the goalie already
# committed the read.
@export var slide_initial_speed: float = 4.5        # m/s push-off speed
@export var slide_friction: float = 6.0             # m/s² decay
@export var slide_min_speed: float = 0.3            # m/s — slide ends below this
@export var slide_trigger_distance: float = 0.40    # m — threat-X delta needed to commit
@export var slide_cooldown: float = 0.20            # s between committed slides
# When a slide commits toward a post (extreme lateral target), the goalie
# also pulls deep so the sealing pad presses the post — backdoor /
# wraparound coverage. Depth target = lerp(current_depth, post_seal_depth)
# scaled by how extreme the lateral slide endpoint is. Slides toward
# centre hold depth; slides to ±net_half_width go fully deep.
@export var post_seal_depth: float = 0.10
# How parallel the body becomes with the slide direction (degrees of Y
# rotation toward slide). Body parts (pads, gloves) are placed in goalie
# local X — rotating the body yaw toward the slide direction swings those
# local-X pads off the slide axis, so the legs stop sliding from one to the
# other and instead point into/out of the net. Keep at 0 so the body stays
# square to the shooter while the legs slide laterally; lean and push-off
# pad kick already sell the pivot read.
@export var slide_facing_max_deg: float = 0.0
# Lateral offset from goalie center to the pad center in butterfly. Used to
# compute the slide target so the sealing pad ends up even with the post:
# goalie center sits at ±(net_half_width - pad_local_offset). Matches the
# `left_pad_pos.x = -0.42` value baked into the BUTTERFLY body config.
@export var pad_local_offset: float = 0.42
# Forward bow of the pivot arc at mid-slide, in metres. The goalie's center
# traces a slight arc toward the shooter as the body pivots around the
# push-off foot — depth peaks at mid-slide then settles at the seal target.
# Purely visual; 0.0 = straight lateral line.
@export var slide_pivot_arc_depth: float = 0.04
# How much the push-off pad lifts off the ice at the start of the push (metres,
# Y offset). Returns to zero as the slide decays so it settles flat.
@export var slide_pushoff_lift: float = 0.05
# Rotation (degrees) the push-off pad kicks toward vertical at push-off.
# 0° = stays flat like sealing pad; 35° = partial kick — enough to read as
# a plant-and-push. Returns to flat as the slide decays.
@export var slide_pushoff_rot_deg: float = 35.0
# Body lean into the slide direction (degrees Z rotation). Shifts weight into
# the push — without it, only the yaw moves and the pivot read is lost.
@export var slide_body_lean_deg: float = 6.0
# Suppress slide triggers for this long after a "shot event" — either a shot
# being released OR the puck contacting the goalie. Real goalies track up to
# release, then commit to their read and process the outcome; they can't
# simultaneously read a shot AND react to a new lateral threat. After a save,
# deflection trajectories are also unpredictable in this window. One timer
# covers both cases.
@export var post_event_slide_lockout: float = 0.25

# ── Slapper tell ──────────────────────────────────────────────────────────────
# Slapshots have a visible windup (SLAPPER_CHARGE_WITH_PUCK on the carrier).
# Goalies read it: pull slightly deeper into the crease and raise hands.
# Wrist shots have no comparable tell — react on release only.
@export var slapper_tell_depth_pull: float = 0.10   # m deeper while reading windup

# Recovery proximity: while in BUTTERFLY, the goalie holds whenever the puck
# is within this Euclidean distance — covers genuine jam plays, post-save
# rebounds bouncing in front, and slow follow-ups. Only when the puck has
# clearly cleared this zone does speed/direction-based recovery apply. ~2.4m
# is a couple of stick-lengths from the goalie, ~half-slot.
@export var recovery_proximity_threshold: float = 2.4

# Reaction freeze ends only on a discrete resolving event: puck hits this
# goalie, hits the boards, hits a post, hits the net, or is picked up by
# any skater. After the event there's a short delay before the freeze
# clears — `reaction_clear_delay`. The goalie isn't simultaneously
# processing the resolution AND deciding the next move; gives them a beat.
@export var reaction_clear_delay: float = 0.25
# Hard cap on `_reacting_to_shot` duration as a safety net only. The freeze
# is supposed to end via a resolving event; this catches edge cases where
# none of the expected events fire (puck stuck somewhere, signal missed).
@export var max_reaction_duration: float = 1.5

# ── Ready stance ──────────────────────────────────────────────────────────────
# Distinct half-down stance triggered when the play is in the goalie's
# defensive half AND the puck is loose or carried by an opponent. Crouched,
# weight forward, gloves more active — closer to butterfly so the drop is
# faster, and gives the player visual signal that the goalie is engaged. The
# goalie returns to READY (not STANDING) after butterfly recovery while the
# threat persists, so they aren't bouncing all the way upright between drops.
@export var ready_zone_distance: float = 25.0  # m — puck perp distance threshold to enter READY

# Lateral deadband for the RVH_LEFT ↔ RVH_RIGHT swap. The puck has to
# cross the goalie's centerline by at least this much before the post
# being hugged switches sides. Without this, a puck hovering at
# ~x=0 (e.g., directly behind the net) flickers the state every tick
# from float jitter, spamming state-change RPCs.
@export var rvh_swap_deadband_m: float = 0.25

# ── Client Correction Tuning ──────────────────────────────────────────────────
# Server broadcasts (40 Hz) soft-correct the client-side goalie simulation.
@export var correction_blend: float = 0.40      # per-broadcast blend strength toward server
@export var correction_hard_snap: float = 1.5   # metres — snap immediately if farther than this
@export var correction_dead_zone: float = 0.02  # metres — ignore errors smaller than this

@export var low_shot_threshold: float = 0.45
@export var elevated_threshold: float = 0.45
@export var react_hand_y_min: float = 0.50
@export var react_hand_y_max: float = 1.55
@export var react_hand_z: float = -0.28
# Glove arm reach. The glove (in `_apply_elevated_shot_reaction`) moves
# toward the shot's lateral impact point clamped within these bounds, so
# the goalie actively extends the arm to make catch saves rather than
# just rotating the wrist in place. Inward bound stops cross-body reach
# from looking goofy. Forward Z increases with reach distance — extending
# the arm naturally moves the glove forward of the body line.
@export var glove_max_x_outward: float = -0.85   # max extension to the glove side
@export var glove_max_x_inward: float = -0.10    # max cross-body reach
@export var glove_max_z_reach: float = 0.10      # extra forward Z at full extension
@export var glove_max_yaw_deg: float = 60.0      # cap on glove Y rotation toward puck
# Blocker reach mirrors the glove. Pad+stick are rigid so we only translate
# the assembly toward the intercept; yaw is around Y so the per-state X tilt
# (which keeps the blade on the ice) stays intact. Sign-mirrored from glove
# values since the blocker is on the +X side for `catches_left = true`.
@export var blocker_max_x_outward: float = 0.85
@export var blocker_max_x_inward: float = 0.10
@export var blocker_max_z_reach: float = 0.10
@export var blocker_max_yaw_deg: float = 60.0
# Body lean toward the reach side during elevated saves. Real goalies shift
# weight into the save — torso tilts toward the side the arm is extending.
# Without it, only the arms move and the save reads as a wrist twist.
# Scaled by the absolute lateral reach distance (small lean for body shots,
# full lean for corner pulls).
@export var body_lean_max_deg: float = 14.0
@export var body_lean_reach_norm: float = 0.7   # reach distance that maps to full lean
# Hard cap on glove linear speed during shot reactions, in m/s. Lerp-based
# tracking made the math vague (asymptotic convergence); a velocity cap is
# exact: max per-frame travel = speed * delta. Real glove speeds are
# 2-3 m/s for a full extension. At 2.0 m/s with a typical 250 ms flight
# time on a close-range wrister, the glove can travel 0.5 m — enough for
# body / mid-net shots but not the 0.6-0.7 m needed for a top-corner pull.
# Big reaches don't make it; small reaches still close in time.
@export var glove_react_max_speed: float = 2.0
# Blocker (entire BlockArm assembly) reach speed cap, mirroring the glove.
# Same magnitude — both arms have similar reach speed; if blocker should be
# faster (some real goalies' dominant hand), bump this up.
@export var blocker_react_max_speed: float = 2.0

@export var five_hole_butterfly_move_max: float = 0.18  # opens with slide velocity

# ── External signals ──────────────────────────────────────────────────────────
signal state_transitioned(team_id: int, new_state: int)
signal shot_reaction_started(team_id: int, impact_x: float, impact_y: float, is_elevated: bool)
# Fired host-side whenever the reaction freeze clears via any path (resolving
# event + delay, safety timeout, BUTTERFLY entry). Wired through NetworkManager
# so clients drop their own freeze on the same beat — without this, the client's
# `_client_reaction_timer` (1.5 s safety) was the only escape for elevated
# shots that don't trigger any state change, leaving clients visibly frozen
# long after the host had moved on.
signal reaction_cleared(team_id: int)

# ── References ────────────────────────────────────────────────────────────────
var goalie: Goalie = null
var puck: Puck = null
var is_server: bool = false
var team_id: int = -1

# Alias the state enum so existing internal code reads `State.STANDING` instead
# of `GoalieStateMachine.State.STANDING`. The numeric values are preserved (see
# `domain/ai/role_behaviors/carrier.gd` which duplicates them).
const State = GoalieStateMachine.State

# ── Goal Geometry ─────────────────────────────────────────────────────────────
var _goal_line_z: float = 0.0
var _goal_center_x: float = 0.0
var _direction_sign: int = 1

# ── Collaborators ─────────────────────────────────────────────────────────────
var _sm: GoalieStateMachine = GoalieStateMachine.new()
var _slide: GoalieSlideBehavior = GoalieSlideBehavior.new()
var _reaction: GoalieShotReaction = GoalieShotReaction.new()
var _pose: GoalieBodyConfigBuilder = GoalieBodyConfigBuilder.new()
var _pose_inputs: GoalieBodyConfigBuilder.Inputs = GoalieBodyConfigBuilder.Inputs.new()

# ── Cached rule configs (built once in setup) ────────────────────────────────
var _shot_cfg: GoalieBehaviorRules.ShotDetectionConfig
var _zone_cfg: GoalieBehaviorRules.DefensiveZoneConfig
var _depth_cfg: GoalieBehaviorRules.DepthConfig

# ── Runtime (controller-local) ────────────────────────────────────────────────
var _current_depth: float = 0.1
var _current_x: float = 0.0
var _target_x: float = 0.0
var _velocity_x: float = 0.0
var _velocity_z: float = 0.0
var _five_hole_openness: float = 0.0
var _tracked_threat_position: Vector3 = Vector3.ZERO
# Position-derived puck velocity, for intercept math during elevated shots.
# Works on both host and client (linear_velocity is unreliable on the client
# during interpolation). Updated each tick from the puck position delta.
var _puck_velocity_est: Vector3 = Vector3.ZERO
var _prev_puck_position: Vector3 = Vector3.ZERO
var _puck_approach_velocity: float = 0.0
var _reading_slapper_tell: bool = false
# Skater accessor for the crease-jam butterfly check. Host-only — the check
# runs inside the host-side state machine and clients receive the resulting
# transition via the existing apply_state_transition RPC.
var _skater_getter: Callable = Callable()

# ── Client Simulation ─────────────────────────────────────────────────────────
var is_extrapolating: bool = false  # always false; kept for telemetry compat
var _last_server_ts: float = 0.0

func get_buffer_depth() -> int:
	return 0  # no longer buffering; kept for telemetry compat

# ── Setup ─────────────────────────────────────────────────────────────────────
func setup(assigned_goalie: Goalie, assigned_puck: Puck, assigned_goal_line_z: float, assigned_is_server: bool) -> void:
	goalie = assigned_goalie
	puck = assigned_puck
	is_server = assigned_is_server
	_goal_line_z = assigned_goal_line_z
	_goal_center_x = 0.0
	_direction_sign = sign(-_goal_line_z)
	_current_x = _goal_center_x
	_target_x = _goal_center_x
	_current_depth = depth_defensive
	_tracked_threat_position = puck.global_position
	_prev_puck_position = puck.global_position
	_configure_collaborators()
	_sm.transitioned.connect(_on_sm_transitioned)
	_reaction.started.connect(_on_reaction_started)
	_reaction.finished.connect(_on_reaction_finished)
	# Place the goalie in the crease BEFORE the first physics tick — otherwise
	# the actor sits at scene-default (0,0,0) and the AI skates it to position
	# on tick 1, which players see as "spawning at center ice then moving."
	goalie.set_goalie_position(_current_x, _goal_line_z + _direction_sign * _current_depth)
	goalie.set_goalie_rotation_y(PI if _direction_sign == 1 else 0.0)
	if is_server:
		puck.puck_released.connect(_on_puck_released)
		puck.puck_touched_goalie.connect(_on_puck_contact)
		# Resolving events that end the reaction freeze. Each fires only on
		# a loose puck (already gated inside Puck) and starts the clear timer.
		puck.puck_hit_boards.connect(_on_reaction_resolved)
		puck.puck_touched_post.connect(_on_reaction_resolved)
		puck.puck_hit_goal_body.connect(_on_reaction_resolved)

# Wired by GameManager so the crease-jam check can scan opposing skaters
# without the controller knowing about the registry / spawner.
func set_skater_getter(getter: Callable) -> void:
	_skater_getter = getter

# Push export tuning into each collaborator. Called from setup() and any time
# exports change in the editor (only at game start in practice — runtime tuning
# is the user's responsibility for now).
func _configure_collaborators() -> void:
	_slide.slide_initial_speed = slide_initial_speed
	_slide.slide_friction = slide_friction
	_slide.slide_min_speed = slide_min_speed
	_slide.slide_cooldown = slide_cooldown
	_slide.slide_pivot_arc_depth = slide_pivot_arc_depth
	_slide.post_seal_depth = post_seal_depth
	_slide.pad_local_offset = pad_local_offset
	_slide.post_event_slide_lockout = post_event_slide_lockout
	_slide.butterfly_drop_speed = butterfly_drop_speed
	_slide.butterfly_min_hold_time = butterfly_min_hold_time
	_reaction.reaction_delay = reaction_delay
	_reaction.arm_reaction_delay = arm_reaction_delay
	_reaction.max_reaction_duration = max_reaction_duration
	_reaction.reaction_clear_delay = reaction_clear_delay
	_pose.catches_left = catches_left
	_pose.rvh_post_pad_angle = rvh_post_pad_angle
	_pose.glove_max_x_outward = glove_max_x_outward
	_pose.glove_max_x_inward = glove_max_x_inward
	_pose.glove_max_z_reach = glove_max_z_reach
	_pose.glove_max_yaw_deg = glove_max_yaw_deg
	_pose.blocker_max_x_outward = blocker_max_x_outward
	_pose.blocker_max_x_inward = blocker_max_x_inward
	_pose.blocker_max_z_reach = blocker_max_z_reach
	_pose.blocker_max_yaw_deg = blocker_max_yaw_deg
	_pose.body_lean_max_deg = body_lean_max_deg
	_pose.body_lean_reach_norm = body_lean_reach_norm
	_pose.react_hand_y_min = react_hand_y_min
	_pose.react_hand_y_max = react_hand_y_max
	_pose.react_hand_z = react_hand_z
	_pose.slide_pushoff_lift = slide_pushoff_lift
	_pose.slide_pushoff_rot_deg = slide_pushoff_rot_deg
	_pose.slide_body_lean_deg = slide_body_lean_deg
	_pose.slide_initial_speed = slide_initial_speed
	_build_rule_configs()

# Rule configs are built once and reused — exports don't change at runtime.
# Without this, three `RefCounted` allocations happen per physics tick per
# goalie (plus extra shot-config allocs during reaction re-projection) at
# 240Hz, for no semantic gain.
func _build_rule_configs() -> void:
	_shot_cfg = GoalieBehaviorRules.ShotDetectionConfig.new()
	_shot_cfg.shot_speed_threshold = shot_speed_threshold
	_shot_cfg.net_half_width = net_half_width
	_shot_cfg.net_margin = net_margin
	_shot_cfg.reaction_delay = reaction_delay
	_shot_cfg.low_shot_threshold = low_shot_threshold
	_shot_cfg.elevated_threshold = elevated_threshold
	_zone_cfg = GoalieBehaviorRules.DefensiveZoneConfig.new()
	_zone_cfg.zone_post_z = zone_post_z
	_zone_cfg.rvh_early_angle = rvh_early_angle
	_depth_cfg = GoalieBehaviorRules.DepthConfig.new()
	_depth_cfg.zone_post_z = zone_post_z
	_depth_cfg.zone_aggressive_z = zone_aggressive_z
	_depth_cfg.zone_base_z = zone_base_z
	_depth_cfg.zone_conservative_z = zone_conservative_z
	_depth_cfg.depth_aggressive = depth_aggressive
	_depth_cfg.depth_base = depth_base
	_depth_cfg.depth_conservative = depth_conservative
	_depth_cfg.depth_defensive = depth_defensive

func is_butterfly() -> bool:
	return _sm.is_butterfly()

func reset_to_crease() -> void:
	_sm.reset()
	_slide.reset()
	_reaction.reset()
	_current_depth = depth_defensive
	_current_x = _goal_center_x
	_target_x = _goal_center_x
	_five_hole_openness = 0.0
	_reading_slapper_tell = false
	_puck_approach_velocity = 0.0
	_tracked_threat_position = puck.global_position if puck != null else Vector3.ZERO
	_prev_puck_position = _tracked_threat_position
	goalie.set_goalie_position(_current_x, _goal_line_z + _direction_sign * _current_depth)
	goalie.set_goalie_rotation_y(PI if _direction_sign == 1 else 0.0)

# ── Process ───────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if goalie == null or puck == null:
		return
	# Client runs the full goalie AI every frame using its local puck position.
	# Server broadcasts correct the AI state softly via apply_state().
	if not is_server:
		_reaction.tick_client(delta)
	_update_tracking(delta)
	_update_shot_timer(delta)
	_update_state(delta)
	_update_depth(delta)
	_update_position(delta)
	_update_facing(delta)
	_update_body_parts(delta)

# ── Tracking ──────────────────────────────────────────────────────────────────
# "Threat" = where the goalie's positioning targets. Carrier body (steady)
# blends with puck (jumpy from stickhandling) per shooter_weight. With no
# carrier the puck IS the threat. Shot in flight (post-release) drops to
# pure-puck via the reaction freeze — see compute_threat below.
func _update_tracking(delta: float) -> void:
	# Position-derived puck velocity. Works on both host and client (the
	# client's `linear_velocity` is unreliable during interpolation). Used
	# for both the approach-velocity threat-pressing check and the
	# intercept-at-goalie-plane glove targeting.
	var inv_dt: float = 1.0 / maxf(delta, 0.0001)
	_puck_velocity_est = (puck.global_position - _prev_puck_position) * inv_dt
	_puck_approach_velocity = -_puck_velocity_est.z * _direction_sign
	_prev_puck_position = puck.global_position
	# Detect slapper windup on the carrier — stance tell, not a butterfly drop.
	var carrier: Skater = puck.get_carrier()
	_reading_slapper_tell = carrier != null \
			and carrier.current_shot_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK \
			and _sm.is_upright()
	# Compute desired threat target. With a carrier we lerp toward the
	# blended (chest+puck) target so stickhandling jitter is smoothed. With
	# no carrier (loose puck, rebound, shot in flight) the threat is the
	# puck position directly — lerping here makes the goalie chase stale
	# positions and commit slides to where the rebound *was*, sliding away
	# from where it actually is.
	var target_threat: Vector3 = _compute_threat_position()
	if puck.get_carrier() != null and not _reaction.reacting:
		_tracked_threat_position = _tracked_threat_position.lerp(target_threat, tracking_speed * delta)
	else:
		_tracked_threat_position = target_threat
	if not _reaction.reacting or not is_server:
		return
	# Tick the freeze (handles carrier-arm, clear-timer countdown, duration cap).
	# A pickup with a non-null carrier arms the clear timer if not yet armed.
	if _reaction.tick_freeze(delta, puck.get_carrier() != null):
		return
	# Re-project impact position each frame so the elevated-shot reach stays
	# accurate as the puck travels (handles bounces, deflections affecting
	# trajectory). Does NOT clear the freeze if re-projection fails — that would
	# release it mid-flight on shots that arc over the net or drift wide before
	# any resolving event has fired.
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
			puck.global_position, puck.linear_velocity,
			_goal_line_z, _goal_center_x, _shot_cfg)
	if result.is_shot:
		_reaction.update_impact(result.impact_x, result.impact_y)
		# Elevated shot that's tipped low and tracking low — start the
		# butterfly drop timer (still allowed during freeze; arms-and-drop
		# are the body reactions the freeze permits).
		if result.is_low:
			_reaction.tip_to_low(reaction_delay)

# Threat = blend of carrier body and puck. While reacting to a shot in flight
# the puck IS the threat (no chest to chase — react to trajectory). RVH and
# recovering states use raw puck position too because the carrier's body
# isn't the relevant target there. STANDING/READY/BUTTERFLY blend chest+puck.
func _compute_threat_position() -> Vector3:
	var carrier: Skater = puck.get_carrier()
	if carrier == null or _reaction.reacting \
			or _sm.is_rvh() \
			or _sm.current == State.RECOVERING:
		return puck.global_position
	var w: float = shooter_weight_butterfly if _sm.is_butterfly() else shooter_weight_standing
	var blended: Vector3 = GoalieBehaviorRules.compute_threat_position(
			puck.global_position, carrier.global_position, true, w)
	# Lead by carrier velocity. Sustained lateral motion projects ahead;
	# transient deke spikes are smoothed by the tracking-speed lerp. Y is
	# zeroed because skaters don't move vertically — leading height noise
	# would drift the threat off the ice.
	var lead: Vector3 = carrier.velocity * carrier_velocity_lead_time
	lead.y = 0.0
	return blended + lead

# ── Shot Timer ────────────────────────────────────────────────────────────────
# `_reaction.shot_timer` is the goalie's processing delay after shot release —
# the beat between "I see the shot" and "I act on the prediction". Gates the
# butterfly drop (low shots) AND the arm reach (elevated shots, see
# `GoalieBodyConfigBuilder._apply_elevated_shot_reaction`).
func _update_shot_timer(delta: float) -> void:
	if _reaction.tick_processing_timers(delta, _sm.is_upright()):
		_enter_butterfly()

# ── State Machine ─────────────────────────────────────────────────────────────
# Entry rules:
#   STANDING ↔ READY         ─ READY when puck is in goalie's half AND not
#                              carried by own team. STANDING otherwise (own
#                              offense, or play is in opposing half).
#   STANDING/READY → BUTTERFLY ─ shot detected (low). Pressure-triggered drop
#                                is gone — close-range non-shooting threats
#                                are answered by stick + poke check (TBD).
#   STANDING/READY → RVH_*   ─ puck enters defensive zone (behind goal / sharp angle)
#   BUTTERFLY → RECOVERING   ─ min hold elapsed && puck not pressing && not sliding
#   BUTTERFLY ↛ RVH directly ─ must recover first (vulnerable window — exactly
#                              what makes wraparounds and quick cross-creasers work)
#   RECOVERING → READY/STAND ─ recovery_duration elapsed; back into READY if
#                              the threat persists, else fully STANDING.
#   RVH_* → READY/STANDING   ─ puck leaves defensive zone; same READY check.
func _update_state(delta: float) -> void:
	# Shot timer is only meaningful in upright stances (STANDING / READY) — drop
	# triggers come from there. Clear it as soon as we enter any other state so
	# a returning RECOVERING/RVH transition doesn't immediately re-fire butterfly.
	if not _sm.is_upright():
		_reaction.shot_timer = 0.0
		_reaction.arm_timer = 0.0
	_slide.tick_cooldown(delta)
	# Convert puck global X into goalie local X. The -Z goal goalie is rotated PI
	# so its local +X is global -X; multiplying by -_direction_sign corrects for that.
	var puck_local_x: float = (_tracked_threat_position.x - _goal_center_x) * -_direction_sign
	match _sm.current:
		State.STANDING, State.READY:
			# RVH is for puck POSSESSED at sharp angles / behind net (post-hug
			# coverage), not puck IN FLIGHT from one. Gating on `not reacting`
			# prevents the case where a sharp-angle shot triggers reaction → next
			# tick the puck is still in the defensive zone → state flips to RVH
			# and clears the reaction before the goalie can do anything. Once
			# the shot resolves normally (boards / post / net / save / pickup),
			# the freeze clears and the next tick can transition to RVH if
			# appropriate.
			if _is_puck_in_defensive_zone() and not _reaction.reacting:
				_sm.transition_to(State.RVH_LEFT if puck_local_x < 0.0 else State.RVH_RIGHT)
			elif (_is_carrier_at_doorstep() or _is_jammed_at_crease()) and not _reaction.reacting:
				# Either a moving carrier at point-blank range (can't track
				# laterally fast enough → commit the seal and slide-react to
				# wraparounds) OR a crease jam: puck close with an opponent
				# in poke range, no shot inbound but a whack is one tick away.
				# Both cases want pads on the ice regardless of follow-up play.
				_enter_butterfly()
			else:
				# Toggle STANDING ↔ READY based on threat conditions.
				var should_be_ready: bool = _is_ready_situation()
				if _sm.current == State.STANDING and should_be_ready:
					_sm.transition_to(State.READY)
				elif _sm.current == State.READY and not should_be_ready:
					_sm.transition_to(State.STANDING)
		State.BUTTERFLY, State.SLIDING:
			_slide.tick_butterfly(delta)
			# Recovery only fires from idle BUTTERFLY (not mid-slide). Slide
			# completion transitions back to BUTTERFLY first — recovery
			# can fire on the next tick if conditions hold. RVH from butterfly
			# is forbidden: must stand first so the goalie eats a recovery
			# window on wraparound plays.
			if _sm.current == State.BUTTERFLY \
					and _slide.can_recover() \
					and not _is_threat_pressing():
				_sm.transition_to(State.RECOVERING)
				_sm.recovery_timer = 0.0
				# Also clear the reaction freeze for any client that missed
				# the state-change RPC.
				_reaction.finish()
		State.RECOVERING:
			_sm.recovery_timer += delta
			if _sm.recovery_timer >= recovery_duration:
				_sm.transition_to(State.READY if _is_ready_situation() else State.STANDING)
				_sm.recovery_timer = 0.0
		State.RVH_LEFT:
			if not _is_puck_in_defensive_zone():
				_sm.transition_to(State.READY if _is_ready_situation() else State.STANDING)
			elif puck_local_x >= rvh_swap_deadband_m:
				_sm.transition_to(State.RVH_RIGHT)
		State.RVH_RIGHT:
			if not _is_puck_in_defensive_zone():
				_sm.transition_to(State.READY if _is_ready_situation() else State.STANDING)
			elif puck_local_x < -rvh_swap_deadband_m:
				_sm.transition_to(State.RVH_LEFT)

# True when the puck is in the goalie's defensive half AND not controlled by
# the goalie's own team (loose or carried by an opponent). Drives the
# STANDING ↔ READY transition.
func _is_ready_situation() -> bool:
	# Perpendicular distance from goal line; positive = in front of goal.
	var puck_perp: float = (puck.global_position.z - _goal_line_z) * _direction_sign
	if puck_perp > ready_zone_distance:
		return false
	# Puck is in our half. If a teammate carries it, no threat — they're
	# regrouping or holding possession in own offensive zone behind us.
	var carrier: Skater = puck.get_carrier()
	if carrier != null and carrier.get_team_id() == team_id and team_id != -1:
		return false
	return true

# True when an opposing carrier is at point-blank range with intent (moving).
# Used to commit butterfly proactively — at this range the goalie can't track
# laterally fast enough, so dropping is the correct read regardless of follow-
# up play. Stationary teammates / opposing regroup don't trigger.
func _is_carrier_at_doorstep() -> bool:
	var carrier: Skater = puck.get_carrier()
	if carrier == null:
		return false
	if carrier.get_team_id() == team_id and team_id != -1:
		return false
	if carrier.velocity.length() < close_crease_butterfly_speed:
		return false
	return goalie.global_position.distance_to(carrier.global_position) < close_crease_butterfly_distance

# True when the puck is jammed in the crease — close to the goalie, and at
# least one opposing skater is within stick-poke range of the puck. Covers
# the cases the carrier-at-doorstep check misses: loose pucks (no carrier),
# and stationary carriers (sub-`close_crease_butterfly_speed`). Without this
# the goalie stays upright through extended crease scrambles. Own-team
# carriers are excluded — defencemen jamming around the crease aren't a
# threat. Host-only; the resulting transition is broadcast normally.
func _is_jammed_at_crease() -> bool:
	if goalie.global_position.distance_to(puck.global_position) > jam_puck_distance:
		return false
	var carrier: Skater = puck.get_carrier()
	if carrier != null and team_id != -1 and carrier.get_team_id() == team_id:
		return false
	if carrier != null:
		# Opposing carrier inside the jam zone is reason enough — they can
		# whack at any moment regardless of speed.
		return true
	if not _skater_getter.is_valid():
		return false
	var skaters: Array = _skater_getter.call()
	for skater: Skater in skaters:
		if skater == null:
			continue
		if team_id != -1 and skater.get_team_id() == team_id:
			continue
		if skater.global_position.distance_to(puck.global_position) < jam_opponent_distance:
			return true
	return false

func _enter_butterfly() -> void:
	_sm.transition_to(State.BUTTERFLY)

# Entry side-effects for state changes — runs for EVERY transition (host AND
# client) because `apply_state_transition` also routes through `_sm.transition_to`.
# Snap-back-to-depth bookkeeping is unit-sensitive: `_current_depth` carries
# different units per state (radius in STANDING/READY/RECOVERING; perpendicular
# depth in BUTTERFLY/RVH) and the wrong unit on entry teleports the goalie.
func _on_sm_transitioned(prev: State, new_state: State) -> void:
	match new_state:
		State.BUTTERFLY:
			# Fresh butterfly entry resets timers + snaps depth. Returning
			# from a slide (SLIDING → BUTTERFLY) preserves accumulated hold
			# time, drop progress, and the depth the slide ended at — the
			# slide is part of the same butterfly cycle.
			if prev != State.SLIDING:
				_slide.enter_fresh_butterfly()
				# Standing/Ready stored radius; butterfly holds perpendicular
				# depth, so snap to the goalie's actual world perp depth.
				_current_depth = (goalie.global_position.z - _goal_line_z) * _direction_sign
			_slide.velocity_x = 0.0
		State.RECOVERING:
			_slide.velocity_x = 0.0
		State.STANDING:
			_slide.drop_progress = 0.0
			_slide.velocity_x = 0.0
		State.RVH_LEFT, State.RVH_RIGHT:
			# Coming in from STANDING with the goalie on the goal line (sharp-
			# angle arc flatten), the carried-over radius value (e.g. 1.2 m)
			# gets re-interpreted as perp depth and the next tick teleports
			# the goalie 1.2 m forward. Snap to the actual current perp depth
			# so the position holds, then `_update_depth` lerps gently to
			# `rvh_depth` from there.
			_current_depth = (goalie.global_position.z - _goal_line_z) * _direction_sign
	if is_server:
		state_transitioned.emit(team_id, new_state as int)

# Should the goalie keep holding butterfly because the puck is still a threat?
# Hold conditions, in priority:
#   1. Puck is CLOSE (within recovery_proximity_threshold)  → hold
#      Catches the rebound-stays-in-front case: a deflection bouncing back
#      toward the shooter (any speed, any direction) is still a threat
#      because the goalie can't usefully recover before a follow-up shot
#      or a teammate's pickup.
#   2. Puck is fast AND approaching                         → hold (active shot)
#   3. Otherwise                                            → release (cleared)
# Pressure detection is one-way: it only HOLDS butterfly, never triggers entry.
func _is_threat_pressing() -> bool:
	var threat_dist: float = GoalieBehaviorRules.threat_distance_to_goal(
			puck.global_position, _goal_line_z, _goal_center_x)
	# Proximity-stay only applies when a hostile carrier is in the
	# butterfly zone — they could shoot at any moment, hold the seal.
	# Loose pucks (no carrier) skip this and fall through to the
	# speed/direction check; a slow rebound sitting in the crease
	# doesn't keep the goalie pinned in butterfly forever.
	if threat_dist < recovery_proximity_threshold:
		var carrier: Skater = puck.get_carrier()
		if carrier != null and (team_id == -1 or carrier.get_team_id() != team_id):
			return true
	# Crease jam: hold butterfly while opponents are within poke range of the
	# puck in the goalie's lap, even if the puck is loose and slow. Same gate
	# as the entry trigger — if conditions still warrant butterfly entry, they
	# warrant staying down.
	if _is_jammed_at_crease():
		return true
	var speed_low: bool
	var moving_away: bool
	if is_server:
		speed_low = puck.linear_velocity.length() < shot_speed_threshold
		moving_away = puck.linear_velocity.z * _direction_sign > 0.0
	else:
		speed_low = absf(_puck_approach_velocity) < shot_speed_threshold
		moving_away = _puck_approach_velocity < 0.0
	if moving_away:
		return false
	return not speed_low

# ── Depth ─────────────────────────────────────────────────────────────────────
# Standing depth is the "challenge angle" arc radius from goal center. The
# Buckley chart still drives the radius via Euclidean threat distance — the
# geometric arc emerges from `target_arc_position` consuming radius for
# lateral motion when the threat is wide. This naturally pulls the goalie
# back on sharp angles (real goalie behaviour) instead of skating a flat
# line at fixed depth.
func _update_depth(delta: float) -> void:
	if _sm.is_rvh():
		_current_depth = lerpf(_current_depth, rvh_depth, depth_speed * delta)
		return
	if _sm.current == State.BUTTERFLY:
		# Idle butterfly: commit at the depth set on entry, hold it.
		return
	if _sm.current == State.SLIDING:
		# Depth is managed by `_slide.advance_slide` (lerps toward the
		# post-seal target during slide). Don't touch from here.
		return
	if _sm.current == State.RECOVERING:
		# Gentle fade back toward defensive crease while standing up.
		_current_depth = lerpf(_current_depth, depth_defensive, depth_speed * delta)
		return
	# STANDING / READY: depth chart drives radius. Slapper tell pulls deeper.
	var threat_dist: float = GoalieBehaviorRules.threat_distance_to_goal(
			_tracked_threat_position, _goal_line_z, _goal_center_x)
	var target_radius: float = GoalieBehaviorRules.target_depth_for_puck_distance(
			threat_dist, _depth_cfg)
	if _reading_slapper_tell:
		target_radius = maxf(target_radius - slapper_tell_depth_pull, depth_defensive)
	_current_depth = lerpf(_current_depth, target_radius, depth_speed * delta)

# ── Position ──────────────────────────────────────────────────────────────────
# STANDING uses true 2D arc tracing: target is (arc_x, arc_z) from the threat,
# and both x and z move toward it together so the goalie stays on the arc as
# it shifts. RECOVERING also uses 2D motion back toward the defensive crease.
# BUTTERFLY uses commit-and-ride; RVH uses the existing pad-flush math.
func _update_position(delta: float) -> void:
	var prev_x: float = _current_x
	var prev_z: float = goalie.global_position.z
	var new_z: float
	# `_current_depth` is the **radius from goal center** (the depth chart
	# output), not perpendicular depth — read it that way uniformly. The arc
	# move outputs a (x, z) on the radius-N arc; the goalie's actual perp
	# depth at the resulting point is naturally <= _current_depth and is NOT
	# stored back. Next frame's _update_depth keeps lerping radius toward the
	# chart target without oscillation.
	match _sm.current:
		State.STANDING, State.READY, State.RECOVERING:
			var pair: Vector2 = _move_along_arc(delta)
			_current_x = pair.x
			new_z = pair.y
		State.BUTTERFLY:
			_update_butterfly_five_hole(delta)
			_try_commit_slide()
			new_z = _goal_line_z + _direction_sign * _current_depth
		State.SLIDING:
			_update_butterfly_five_hole(delta)
			var pair: Vector2 = _slide.advance_slide(delta, _goal_center_x, net_half_width)
			_current_x = pair.x
			_current_depth = pair.y
			new_z = _goal_line_z + _direction_sign * _current_depth
			if _slide.is_slide_finished():
				_sm.transition_to(State.BUTTERFLY)
		State.RVH_LEFT:
			# 0.38 = outer pad reach (0.88) - 0.50 body inset toward post.
			_current_x = move_toward(_current_x, _goal_center_x + (net_half_width - 0.38) * _direction_sign, rvh_transition_speed * delta)
			new_z = _goal_line_z + _direction_sign * _current_depth
		State.RVH_RIGHT:
			_current_x = move_toward(_current_x, _goal_center_x - (net_half_width - 0.38) * _direction_sign, rvh_transition_speed * delta)
			new_z = _goal_line_z + _direction_sign * _current_depth
		_:
			new_z = _goal_line_z + _direction_sign * _current_depth
	if delta > 0.0:
		_velocity_x = (_current_x - prev_x) / delta
		_velocity_z = (new_z - prev_z) / delta
	goalie.set_goalie_position(_current_x, new_z)

# 2D arc tracing for STANDING/RECOVERING. Target is the arc point at the
# current radius; choose lateral speed by 2D distance so X and Z move at the
# same rate (no asymmetric snap on Z when threat angle shifts). Five-hole
# openness scales with motion category exactly as before.
#
# While reacting to a shot, lateral movement freezes entirely — the goalie
# committed to their pre-release position and is now reading the shot. They
# react with body parts (butterfly drop / glove raise) but don't slide or
# shuffle. The freeze releases when the freeze clears (`detect_shot`
# re-projection in `_update_tracking` returns false on board / post / wide /
# saved pucks) or via the safety timeout in `_update_tracking`.
func _move_along_arc(delta: float) -> Vector2:
	var current := Vector2(_current_x, goalie.global_position.z)
	if _reaction.reacting:
		if is_server:
			_five_hole_openness = lerpf(_five_hole_openness, five_hole_base, part_lerp_speed * delta)
		return current
	var target_xz: Vector2 = _arc_target_xz()
	_target_x = target_xz.x
	var delta_2d: float = current.distance_to(target_xz)
	var move_speed: float
	var five_hole_target: float
	if delta_2d < 0.01:
		move_speed = shuffle_speed
		five_hole_target = five_hole_base
	elif delta_2d > lateral_threshold:
		move_speed = t_push_speed
		five_hole_target = five_hole_t_push_max
	else:
		move_speed = shuffle_speed
		five_hole_target = five_hole_shuffle_max
	var step: float = move_speed * delta
	var new_xz: Vector2
	if delta_2d <= step or delta_2d < 0.0001:
		new_xz = target_xz
	else:
		new_xz = current + (target_xz - current) * (step / delta_2d)
	if is_server:
		_five_hole_openness = lerpf(_five_hole_openness, five_hole_target, part_lerp_speed * delta)
	return new_xz

# Arc target (x, z) at the current radius — STANDING/RECOVERING tracing.
# BUTTERFLY uses compute_slide_destination directly with butterfly_radius.
func _arc_target_xz() -> Vector2:
	return GoalieBehaviorRules.target_arc_position(
			_tracked_threat_position, _goal_line_z, _goal_center_x,
			_direction_sign, _current_depth, net_half_width)

# Five-hole openness for BUTTERFLY/SLIDING. Server-only — clients adopt the
# server's value via apply_state.
func _update_butterfly_five_hole(delta: float) -> void:
	if not is_server:
		return
	if _slide.drop_progress < 1.0:
		# Snap closed during the active drop animation.
		_five_hole_openness = lerpf(_five_hole_openness, 0.0, part_lerp_speed * delta * 2.0)
	elif _sm.current == State.SLIDING:
		# Trail-leg gap opens with slide velocity ratio.
		var speed_ratio: float = clampf(absf(_slide.velocity_x) / maxf(slide_initial_speed, 0.01), 0.0, 1.0)
		_five_hole_openness = lerpf(
				_five_hole_openness,
				five_hole_butterfly_move_max * speed_ratio,
				part_lerp_speed * delta)
	else:
		# IDLE BUTTERFLY: pads on the ice, touching at the knees.
		_five_hole_openness = lerpf(_five_hole_openness, 0.0, part_lerp_speed * delta)

# Evaluate slide trigger conditions during idle BUTTERFLY. Host-only (clients
# receive the slide via position broadcast + state RPC).
func _try_commit_slide() -> void:
	if not is_server:
		return
	if not _slide.can_commit_slide():
		return
	# Don't slide-track a puck in the defensive zone — RVH path handles it.
	if _is_puck_in_defensive_zone():
		return
	var slide_target_x: float = _slide.clamp_lateral_target(
			_tracked_threat_position.x, _goal_center_x, net_half_width)
	if not GoalieBehaviorRules.should_commit_slide(_current_x, slide_target_x, slide_trigger_distance):
		return
	_slide.commit_slide(_current_x, _current_depth, slide_target_x, net_half_width)
	_sm.transition_to(State.SLIDING)

# ── Facing ────────────────────────────────────────────────────────────────────
# Threat-based facing: rotate toward where the goalie is tracking, not raw
# puck position. Stickhandling jitter no longer twists the body. Real goalies
# keep the body square once down — only the head/upper body track the puck
# (which we don't model), so BUTTERFLY/RECOVERING hold the body squared to
# centre. Rotating the entire rotation_y in butterfly looks unrealistic.
func _update_facing(delta: float) -> void:
	if _sm.is_rvh():
		var target_y: float = PI if _direction_sign == 1 else 0.0
		goalie.set_goalie_rotation_y(lerp_angle(goalie.get_goalie_rotation_y(), target_y, rotation_speed * delta))
		return
	# Same freeze as `_move_along_arc` — once the shot's been released the
	# goalie commits and reads, no body rotation tracking the puck. Especially
	# visible on elevated shots where the shot timer is never set (no butterfly
	# drop) and the rotation is otherwise the only thing the player sees move.
	if _reaction.reacting:
		return
	if _reaction.shot_timer > 0.0:
		return
	if _sm.current == State.BUTTERFLY or _sm.current == State.RECOVERING:
		# Body stays square in butterfly; gentle return to centre during recovery.
		var center_angle: float = PI if _direction_sign == 1 else 0.0
		var return_speed: float = rotation_speed * 0.5 if _sm.current == State.RECOVERING else rotation_speed * 0.25
		goalie.set_goalie_rotation_y(lerp_angle(
				goalie.get_goalie_rotation_y(), center_angle, return_speed * delta))
		return
	if _sm.current == State.SLIDING:
		# Body rotates toward the slide direction so the goalie reads as
		# leaning into the motion. Uses `_velocity_x` (position-derived) so
		# the rotation works on both host (where slide velocity matches)
		# AND client (where the slide is reflected via apply_state position
		# corrections). +Y rotates -Z → -X, so leftward motion gets positive
		# yaw — same convention as glove reach yaw.
		var base_angle: float = PI if _direction_sign == 1 else 0.0
		var speed_ratio: float = clampf(absf(_velocity_x) / maxf(slide_initial_speed, 0.01), 0.0, 1.0)
		var slide_dir: float = -signf(_velocity_x)
		var slide_yaw: float = slide_dir * deg_to_rad(slide_facing_max_deg) * speed_ratio
		var target_y: float = base_angle + slide_yaw
		goalie.set_goalie_rotation_y(lerp_angle(
				goalie.get_goalie_rotation_y(), target_y, rotation_speed * delta))
		return
	var dx: float = _tracked_threat_position.x - goalie.global_position.x
	var dz: float = _tracked_threat_position.z - goalie.global_position.z
	if Vector2(dx, dz).length() > 0.1:
		var base_angle: float = PI if _direction_sign == 1 else 0.0
		var target_y: float = atan2(-dx, -dz)
		var max_rad: float = deg_to_rad(max_facing_angle)
		var deviation: float = clampf(angle_difference(base_angle, target_y), -max_rad, max_rad)
		target_y = base_angle + deviation
		var new_y: float = lerp_angle(goalie.get_goalie_rotation_y(), target_y, rotation_speed * delta)
		goalie.set_goalie_rotation_y(new_y)

# ── Body Parts ────────────────────────────────────────────────────────────────
func _update_body_parts(delta: float) -> void:
	_pose_inputs.state = _sm.current
	_pose_inputs.five_hole_openness = _five_hole_openness
	_pose_inputs.reading_slapper_tell = _reading_slapper_tell
	_pose_inputs.reacting_to_shot = _reaction.reacting
	_pose_inputs.shot_is_elevated = _reaction.is_elevated
	_pose_inputs.shot_impact_x = _reaction.impact_x
	_pose_inputs.shot_impact_y = _reaction.impact_y
	_pose_inputs.current_x = _current_x
	_pose_inputs.goalie_z = goalie.global_position.z
	_pose_inputs.direction_sign = _direction_sign
	_pose_inputs.slide_velocity_x = _slide.velocity_x
	_pose_inputs.slide_dir = _slide.dir
	_pose_inputs.arm_reaction_pending = _reaction.arm_pending()
	_pose_inputs.puck_position = puck.global_position
	_pose_inputs.puck_velocity_est = _puck_velocity_est
	var config: GoalieBodyConfig = _pose.build(_pose_inputs)
	var lerp_t: float
	if _sm.current == State.BUTTERFLY or _sm.current == State.SLIDING:
		# Drop snap: scale lerp speed so pads converge ~95% within
		# `butterfly_drop_speed`. Lerp is asymptotic — for time-to-95%
		# convergence we need `speed * time ≈ 3`, so the factor is 3/x not 1/x.
		# Once the drop is complete, fall back to reaction speed for any
		# remaining tweaks. SLIDING shares the same logic — it's still
		# butterfly form, just with active lateral motion.
		var drop_lerp: float = 3.0 / maxf(butterfly_drop_speed, 0.001)
		lerp_t = drop_lerp * delta if _slide.drop_progress < 1.0 else reaction_lerp_speed * delta
	elif _reaction.reacting:
		lerp_t = reaction_lerp_speed * delta
	elif _sm.current == State.RECOVERING:
		lerp_t = recovery_lerp_speed * delta
	else:
		lerp_t = part_lerp_speed * delta
	# Pace the elevated-shot arm reach so the glove/blocker arrive WITH the puck
	# instead of sprinting to the intercept and waiting. needed_speed = distance
	# remaining ÷ time-to-puck-arrival, capped at the per-arm max. On close-range
	# shots with little time, max speed is used (graceful fail if the arm can't
	# make it); on longer shots with margin, the arm cruises at the slower pace.
	# Without this, the cap-only behaviour parked the arm early and read as the
	# goalie precognitively beating the puck to the spot.
	var glove_max_step: float = -1.0
	var blocker_max_step: float = -1.0
	if _reaction.reacting and _reaction.is_elevated:
		var dt_to_plane: float = -1.0
		if absf(_puck_velocity_est.z) > 0.001:
			var t: float = (goalie.global_position.z - puck.global_position.z) / _puck_velocity_est.z
			if t > 0.01:
				dt_to_plane = t
		if dt_to_plane > 0.0:
			var glove_dist: float = goalie.get_glove_position().distance_to(config.glove_pos)
			var blocker_dist: float = goalie.get_blocker_position().distance_to(config.blocker_pos)
			glove_max_step = minf(glove_dist / dt_to_plane, glove_react_max_speed) * delta
			blocker_max_step = minf(blocker_dist / dt_to_plane, blocker_react_max_speed) * delta
		else:
			# Puck already past the goalie plane or velocity unreadable — fall
			# back to the hard cap so the arm still tracks deflections / late
			# corrections at a sane speed instead of teleporting.
			glove_max_step = glove_react_max_speed * delta
			blocker_max_step = blocker_react_max_speed * delta
	goalie.apply_body_config(config, lerp_t, glove_max_step, blocker_max_step)

# ── Shot Detection ────────────────────────────────────────────────────────────
func _on_puck_released() -> void:
	# RVH is post-hug coverage with a separate pose — no glove reach is wired,
	# and the goalie is already committed to the puck-side post. Every other
	# state (STANDING, READY, BUTTERFLY, SLIDING, RECOVERING) supports the
	# elevated-shot arm reach via the body-config builder, so the freeze starts
	# from any of them. Previously this was gated on `is_upright()`, which
	# silently dropped all goalie reactions to shots fired while the goalie was
	# already down — top-corner shots over a butterflied goalie went un-tracked
	# because no `shot_reaction_started` RPC ever fired.
	if _sm.is_rvh():
		return
	# `get_release_velocity` returns the impending velocity even when
	# `linear_velocity` is still zero (Jolt's frozen→dynamic transition queues
	# the velocity in `_pending_elevation_vel` for the next physics step).
	# Reading raw `linear_velocity` here misses the shot every time.
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
			puck.global_position,
			puck.get_release_velocity(),
			_goal_line_z,
			_goal_center_x,
			_shot_cfg)
	if not result.is_shot:
		return
	# Two separate processing delays. `shot_timer` (= reaction_delay, ~130ms)
	# gates the butterfly drop on low shots — leg drop is reflexive.
	# `arm_timer` (= arm_reaction_delay, ~180ms) gates the glove/blocker reach
	# on elevated shots — arms need extra processing time to decide WHERE in
	# the upper net to reach. Both run in parallel; start() arms both.
	_reaction.start(result.impact_x, result.impact_y, result.is_elevated, result.reaction_delay)

# Puck just hit a goalie body part. Re-arms the slide lockout so deflections
# don't trigger spurious slides, and starts the reaction clear delay — the
# goalie has physically engaged with the shot, so the read is over. Filters
# by identity since `Puck.puck_touched_goalie` fires on either net's goalie.
func _on_puck_contact(contacted: Goalie) -> void:
	if contacted != goalie:
		return
	_slide.arm_event_lockout()
	_reaction.arm_clear()

# Resolving events (boards / post / net) that aren't goalie-specific. Any of
# these means the shot has resolved — no longer a threat the goalie is
# reading. Starts the clear delay if currently reacting.
func _on_reaction_resolved() -> void:
	_reaction.arm_clear()

# Reaction collaborator signal handlers — translate to controller-level effects
# (slide lockout, external signal fan-out with team_id).
func _on_reaction_started(impact_x: float, impact_y: float, is_elevated: bool) -> void:
	# Goalies track up until release, then commit to their read — they need a
	# beat to process the shot before they can react to a new lateral threat.
	# Suppresses slide triggers during that window. Same mechanism as the
	# post-contact lockout; one runtime timer covers both events (max wins).
	_slide.arm_event_lockout()
	if is_server:
		shot_reaction_started.emit(team_id, impact_x, impact_y, is_elevated)

func _on_reaction_finished() -> void:
	# Without this RPC, clients receive no signal that the host's freeze ended
	# for elevated shots (no state change to drop butterfly), and they stay
	# frozen until the `_client_reaction_timer` 1.5 s safety timer expires.
	if is_server:
		reaction_cleared.emit(team_id)

# ── State Serialization ───────────────────────────────────────────────────────
# Returns the typed network state object. Flattening to Array happens at the
# RPC boundary (GameManager.get_world_state), not here.
func get_state() -> GoalieNetworkState:
	var s := GoalieNetworkState.new()
	s.position_x = goalie.global_position.x
	s.position_z = goalie.global_position.z
	s.rotation_y = goalie.get_goalie_rotation_y()
	s.state_enum = _sm.current as int
	s.five_hole_openness = _five_hole_openness
	s.velocity_x = _velocity_x
	s.velocity_z = _velocity_z
	return s

func apply_state(network_state: GoalieNetworkState, host_ts: float) -> void:
	if is_server:
		return
	if host_ts < _last_server_ts:
		return  # out-of-order packet; discard
	_last_server_ts = host_ts
	# Forward-predict server position to compensate for broadcast transit time.
	# elapsed ≈ RTT/2 at call-time; capped to avoid over-shooting on bad connections.
	var elapsed: float = clampf(NetworkManager.estimated_host_time() - host_ts, 0.0, 0.15)
	var predicted_x: float = network_state.position_x + network_state.velocity_x * elapsed
	var predicted_z: float = network_state.position_z + network_state.velocity_z * elapsed
	# `_current_depth` carries different units per state — it's the arc radius
	# (Euclidean to goal center) in STANDING/RECOVERING and perpendicular depth
	# in BUTTERFLY/RVH. Pick the right one to lerp toward so the client doesn't
	# fight its own AI. Both reduce to the same value at the centerline.
	var server_dx: float = predicted_x - _goal_center_x
	var server_dz: float = predicted_z - _goal_line_z
	var server_depth_value: float
	if _sm.current == State.STANDING or _sm.current == State.READY or _sm.current == State.RECOVERING:
		server_depth_value = sqrt(server_dx * server_dx + server_dz * server_dz)
	else:
		server_depth_value = server_dz * _direction_sign
	var client_z: float = goalie.global_position.z
	var dist: float = Vector2(_current_x - predicted_x, client_z - predicted_z).length()
	if dist > correction_hard_snap:
		_current_x = predicted_x
		_current_depth = server_depth_value
	elif dist > correction_dead_zone:
		_current_x = lerpf(_current_x, predicted_x, correction_blend)
		_current_depth = lerpf(_current_depth, server_depth_value, correction_blend)
	# Five hole: strong blend so client visual matches server physics within ~50 ms.
	# Client AI doesn't compute _five_hole_openness, so nothing fights the correction.
	_five_hole_openness = lerpf(_five_hole_openness, network_state.five_hole_openness, 0.80)

func apply_replay_state(state: GoalieNetworkState, delta: float) -> void:
	_sm.current = state.state_enum as State
	_five_hole_openness = state.five_hole_openness
	_update_body_parts(delta)
	goalie.set_goalie_position(state.position_x, state.position_z)
	goalie.set_goalie_rotation_y(state.rotation_y)


func apply_state_transition(new_state: int) -> void:
	if is_server:
		return
	# Route through transition_to so `_on_sm_transitioned` mirrors host-side
	# entry bookkeeping (drop progress, snap-to-perp-depth, etc.).
	_sm.transition_to(new_state as State)
	if new_state == State.STANDING as int or new_state == State.READY as int:
		_reaction.clear_for_client()
	elif new_state == State.RECOVERING as int:
		_sm.recovery_timer = 0.0
		_reaction.reacting = false

func apply_shot_reaction(impact_x: float, impact_y: float, is_elevated: bool) -> void:
	if is_server:
		return
	# Mirror host: arms processing-delay countdowns so client/server arm reach
	# (elevated) and butterfly drop (low) happen on the same wall-clock offset.
	# Subtract RPC transit time (≈ full RTT) so the client lands at the same
	# T+delay as the host. At RTT >= delay the timer clamps to 0 — react on
	# arrival.
	var rtt_s: float = NetworkManager.get_latest_rtt_ms() / 1000.0
	_reaction.apply_remote(impact_x, impact_y, is_elevated, _sm.is_upright(), rtt_s)

# Host fired the reaction-cleared signal — drop the freeze on this client.
# Idempotent: if state-change RPC already cleared us, this is a no-op.
func apply_reaction_cleared() -> void:
	if is_server:
		return
	_reaction.clear_for_client()

# ── Helpers ───────────────────────────────────────────────────────────────────
# Defensive-zone test uses raw puck position, not threat — the goalie reacts
# to where the puck physically is for RVH gating, not the blended chest.
func _is_puck_in_defensive_zone() -> bool:
	return GoalieBehaviorRules.is_puck_in_defensive_zone(
			puck.global_position, _goal_line_z, _goal_center_x,
			_direction_sign, _zone_cfg)
