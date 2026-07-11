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

# Depth chart = the Buckley Positioning System (BPS) A/B/C/D zones, measured as a
# RADIUS from goal center (the arc-positioning radius consumed by
# GoalieBehaviorRules.target_arc_position). BPS anchors, grounded in real crease
# geometry — the NHL crease top is ~4.5 ft ≈ 1.37 m, matching this project's
# CreaseRules.STRAIGHT_DEPTH:
#   A Aggressive   — ~2 ft outside the crease top; challenge a rush / breakaway /
#                    clean look and force the shooter to beat you.
#   B Base         — heels at the crease top; where MOST shots are faced (covers a
#                    lot of net while still leaving reaction time).
#   C Conservative — middle of the blue paint; anticipating a lateral play (2-on-1).
#   D Defensive    — on the post / tracking behind the net.
# Bumped OUT from the old (compressed ~half-a-crease-too-deep) values to real BPS
# depths: at the raised shot speeds a slot shot leaves almost no lateral reaction
# window (~0.04 m of travel in flight), so cutting the angle by challenging is what
# makes the save, not reflexes. The BPS "play conservative on a lateral threat"
# read is handled dynamically by lateral_pressure_depth_pull + close_crease_
# butterfly rather than baked into the distance curve, so the chart keeps its shape.
@export var depth_aggressive: float = 1.75
@export var depth_base: float = 1.30
@export var depth_conservative: float = 0.70
@export var depth_defensive: float = 0.10
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
# Lateral push acceleration (m/s²). The goalie ramps up to shuffle / T-push speed
# instead of snapping to it — pushes read like real push-offs, and a quick play
# can beat the goalie across before they reach speed (realism + a scoring window).
# The cross-crease desperation push bypasses this (stays instant). Set very high
# (e.g. 100) to restore the old snap-to-speed behaviour.
@export var lateral_accel: float = 14.0
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
@export var arm_reaction_delay: float = GameRules.DEFAULT_GOALIE_ARM_REACTION_DELAY_S

# Imminence gate on the reflexive low-shot butterfly drop. The goalie reads and
# freezes the instant a shot is RELEASED (arm reach + tracking start right
# away), but it only commits the LEG drop once the puck is within this many
# seconds of crossing the goal line. Passes are quick-shots — they fire the
# same release event as a real shot — so without this gate a hard pass or clear
# up the ice reads as a low shot from across the rink and drops the goalie long
# before the play arrives. At 0.45s a 25 m/s shot drops around the top of the
# circles; slower pucks have to get correspondingly closer before it commits.
@export var drop_max_time_to_impact: float = 0.45

# Imminence gate on STARTING a release reaction at all. A release whose puck is
# more than this many seconds from crossing the goal line doesn't begin a
# reaction (no freeze, no arm read) — it's too far to be worth committing to.
# Without it, a hard pass or clear up the ice (passes fire puck_released like a
# shot) freezes the goalie from across the rink even though the leg drop is now
# gated. Must be >= drop_max_time_to_impact (you read before you drop). Genuine
# long shots that release outside this window aren't lost: once the loose puck
# closes to within `universal_react_max_time_to_impact` the universal-reaction
# path picks it up. 0.9s comfortably covers point shots (a 30 m/s blue-line
# slapshot is ~0.65s out) while ignoring slow clears/passes from distance.
@export var react_max_time_to_impact: float = 0.9

# ── Screening ─────────────────────────────────────────────────────────────────
# A body between the shooter and the goalie hides the puck, so the goalie can't
# start their read until the puck emerges from behind the screen. The delay is
# GROUNDED, not a flat fudge: GoalieBehaviorRules.screen_occlusion_delay returns
# how long the worst screener actually hides the puck given the shot's speed and
# geometry (a dead-on point screen hides it far longer than a body at the door-
# step), and `screen_max_extra_delay` is only the CAP on that so a perfect screen
# still leaves a last-instant chance. Both the leg drop and the arm reach are held
# by it. Makes net-front traffic and point shots through a screen a real threat.
# Evaluated once at the read (the goalie loses the beat the moment the puck is
# hidden; re-checking mid-flight would hand the time back). Host-only like all
# goalie AI, so it costs nothing on the wire and never diverges on clients.
@export var screen_max_extra_delay: float = 0.30  # s — CAP on the screen-occlusion pickup delay
@export var screener_radius: float = 0.6          # m — body half-width that blocks sight

# ── Caught moving ─────────────────────────────────────────────────────────────
# A goalie is only sharp when SET — square and stopped. Caught mid-push, sliding,
# or standing up, they read the shot late (see GoalieBehaviorRules.movement_read_
# penalty). Like screening, this adds to the read; unlike a flat difficulty buff
# it ONLY fires while the goalie is in motion, so it opens scoring windows (shoot
# while he's moving) without making a set goalie any harder to beat.
@export var move_read_max_delay: float = 0.12      # s — extra read latency when fully unset
@export var move_read_reference_speed: float = 2.5 # m/s — planar speed counted as fully moving

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

# Universal puck tracking — react to any loose puck on track to cross the goal
# line soon, not just shots released by an opposing carrier. Catches board
# bounces, poke-strips, deflections, rebounds, and slow tricklers that don't
# fire a release event. Urgency is set by time-to-impact, NOT raw speed: a
# puck oozing at the 5-hole from a foot out must trigger a reaction even though
# it's slow. `min_speed` is only an anti-jitter floor for near-stationary
# pucks; `max_time_to_impact` is the real "is a goal imminent" gate.
@export var universal_react_min_speed: float = 1.0
@export var universal_react_max_time_to_impact: float = 0.6

# Diagnostic toggle. When on, prints to the console whenever the universal
# reaction fires and whenever the post-seal clamp actively pulls the standing
# target in (i.e. the clamp changed the value, not a no-op). Host-only so the
# log isn't doubled. Leave off in normal play.
@export var debug_goalie_reads: bool = false

@export var rvh_depth: float = 0.1
@export var rvh_early_angle: float = 80.0
@export var rvh_post_pad_angle: float = 15.0

@export var five_hole_base: float = 0.02
@export var five_hole_shuffle_max: float = 0.04
@export var five_hole_t_push_max: float = 0.10

@export var tracking_speed: float = 8.0
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
# tracking causes the goalie to shuffle perfectly into 5-hole shots. With the
# active blade / poke / sweep systems now disrupting close-range puck control,
# we can afford to bias slightly more toward the puck — the goalie's stick
# pressures the carrier into committing rather than the body chasing dangles.
@export var shooter_weight_standing: float = 0.40
@export var shooter_weight_butterfly: float = 0.60
# Distance-scaled chest tracking. A real goalie plays the shooter's chest at
# range and only tracks the puck itself in tight, so a stickhandle at the point
# doesn't wobble the body. Between `chest_track_near_distance` (full puck
# tracking) and `chest_track_far_distance` (play the chest) the effective
# shooter_weight lerps toward `shooter_weight_far` and the jittery puck-velocity
# lead fades to zero. Distances are Euclidean carrier→goal-center.
@export var chest_track_near_distance: float = 2.5
@export var chest_track_far_distance: float = 7.0
@export var shooter_weight_far: float = 0.90
# Lead-the-target time. Threat position projects forward by
# `carrier.velocity * carrier_velocity_lead_time` so the goalie pre-positions
# toward where the carrier WILL be — the realistic answer to "skater is
# faster than the goalie laterally." Sustained lateral skates (8 m/s) lead
# 1.4 m at 0.18s, meaningful for sweeps and wraparounds. Stickhandling
# jitter has small velocities (~1-2 m/s) so the lead barely moves
# (0.2-0.4 m), and the existing tracking-speed lerp smooths brief deke
# velocity spikes so quick fakes don't drag the goalie out of position.
@export var carrier_velocity_lead_time: float = 0.12
# Puck velocity lead — CARRIER-PRESENT (dangle) branch only. Projects where the
# PUCK is going (vs just the carrier body), which catches what the carrier lead
# misses and is what keeps the goalie in front of forehand-backhand dekes:
#   - Forehand-backhand dekes: carrier body stationary, puck drags laterally
#   - Carrier pivoting to shoot: body still, blade swings out for release
# Shorter than the carrier lead because puck velocity is jittery during
# stickhandling — the tracking-speed lerp + this shorter lead means transient
# dangles don't drag the goalie out while sustained motion does.
@export var puck_velocity_lead_time: float = 0.08
# Puck velocity lead — LOOSE-puck (no carrier) branch, i.e. a pass/rebound in
# flight. Deliberately ~0: the goalie must NOT front-run a back-door pass, so he
# tracks where the puck IS and loses the cross-crease race to a hard pass like a
# real goalie. Kept separate from the dangle lead above so weakening the pass
# read does not touch deke coverage. Raise slightly if he's too beatable on
# slower cross-ice plays.
@export var loose_puck_velocity_lead_time: float = 0.0

# ── Lateral pressure depth retreat ───────────────────────────────────────────
# When a lateral threat moves faster than the goalie can t-push, retreat
# depth (back toward the goal line). Real goaltending principle: shorter
# post-to-post distance from the goal line is easier to seal than the
# aggressive angle. Scales with the velocity deficit (carrier_vx vs
# t_push_speed) so small lateral plays don't trigger any retreat; only
# genuine overspeed plays do. Capped so the goalie doesn't collapse to
# the goal line entirely.
@export var lateral_pressure_depth_pull: float = 0.20  # m of retreat per m/s of deficit
@export var lateral_pressure_max_pull: float = 0.50    # m max retreat from Buckley depth

# ── Backdoor-aware depth (anticipatory) ──────────────────────────────────────
# The lateral-pressure retreat above is REACTIVE — it reads puck velocity, i.e.
# it fires after the pass releases, which against a one-timer is too late by
# design. This is the anticipatory read a real goalie makes BEFORE the pass:
# seeing a one-timer man on the weak side, he challenges the carrier less so he
# can still re-square across when the feed goes. Pure race math in
# GoalieBehaviorRules.backdoor_depth_cap (pass flight + release swing vs.
# react delay + accel-ramped T-push); the goalie's speed/react inputs reuse
# t_push_speed / lateral_accel / cross_crease_react_delay so the positioning
# read stays consistent with the live push it's predicting — and the actual
# cross-crease save still runs that honest race, so this repositions rather
# than buffs. Sitting deeper opens the carrier's direct-shot angle: respecting
# the back door is a genuine trade the shooter can exploit.
@export var backdoor_release_time: float = 0.15         # s — receiver's one-timer swing
@export var backdoor_assumed_pass_speed: float = GameRules.DEFAULT_QUICK_SHOT_POWER_M_S
@export var backdoor_max_shooter_distance: float = 9.0  # m — shooter→goal eligibility

# ── Beaten-wide post seal ────────────────────────────────────────────────────
# A carrier driving laterally across the crease face beats standing tracking
# when the T-push race to the tuck point (the post) is unwinnable — the
# around-the-pad reach. When GoalieBehaviorRules.is_beaten_wide says the race
# is lost, the goalie stops tracking upright and drops; the existing
# _try_commit_slide pad-coverage check then seals the post (post_seal_depth +
# sealed_pad_toe_out already handle the flush seal). The drop is itself a
# commitment — butterfly can't reach RVH directly and eats a recovery window —
# so baiting the drop and pulling back to the slot is the emergent counter.
# min_lateral_speed keeps the stay-up-vs-a-controlled-dangler rule: only a
# genuine lateral drive triggers, never a stationary stickhandle. The distance
# gate is tactical feel: how far out a lateral cut reads as a tuck threat.
@export var beaten_wide_min_lateral_speed: float = 1.5   # m/s — carrier must be driving
@export var beaten_wide_max_threat_distance: float = 4.0 # m — in-tight gate (threat→goal)

# Close-crease auto-butterfly. When an opposing carrier is at the doorstep
# the goalie can't track laterally fast enough; better to commit butterfly
# and slide-react. Different from the old `is_under_pressure` (2.5 m + 1 m/s)
# which fired far enough out to be exploitable — this only fires inside the
# crease where dropping is the correct read regardless of follow-up play.
@export var close_crease_butterfly_distance: float = 1.5

# Crease-jam butterfly. Loose puck or stationary-carrier puck inside the
# jam zone with an opposing skater close enough to whack at it — drop and
# seal even though nobody's "shooting" yet. Without this, bots that crowd
# the crease and pivot-stickhandle keep the goalie upright indefinitely
# because the carrier-at-doorstep check requires meaningful velocity and
# loose pucks have no carrier at all.
@export var jam_puck_distance: float = 2.0    # m — puck-to-goalie threshold
@export var jam_opponent_distance: float = 1.5 # m — opposing-skater-to-puck threshold
# A net-front jam SEALS the ice (drops the goalie to butterfly) so a stick
# battle can't be banged through the standing 5-hole. A loose-puck scramble
# always qualifies; an opposing carrier qualifies only when jammed in tight and
# moving slower than this — a faster carrier is driving the net (an attack), and
# coaches teach staying up to force the release. Set to 0 to seal only on loose
# pucks (never for a carried puck).
@export var jam_carrier_max_speed: float = 3.0 # m/s — carrier above this is attacking, not jamming

# ── Butterfly commitment ─────────────────────────────────────────────────────
# Once the goalie drops they cannot stand-skate. Lateral movement is via
# committed butterfly slides only. They cannot reach RVH directly — must
# stand up first (RECOVERING window).
@export var butterfly_min_hold_time: float = 0.35   # s the goalie must stay down
@export var recovery_duration: float = 0.35         # s spent standing back up
@export var butterfly_drop_speed: float = 0.05      # s for pads to close to floor
@export var butterfly_radius: float = 0.40          # arc radius from goal center while down

# ── Butterfly slide (pivot-and-ride) ─────────────────────────────────────────
# Real goalies plant the outside (non-post) leg, pivot off it, and swing the
# sealing leg through to the post. The body rotates around the push-off foot
# rather than translating laterally — the path is an arc, not a straight line.
# Destination is committed at slide-start; mid-slide can't correct. That's the
# realism win — fast cross-passes can beat the slide because the goalie already
# committed the read.
@export var slide_initial_speed: float = 2.8        # m/s push-off speed (visible glide, not teleport)
@export var slide_friction: float = 2.6             # m/s² decay — brisk enough to read as a discrete
                                                    # plant-push-seal, not a long floaty glide, while
                                                    # still carrying far enough to complete a full
                                                    # post-to-post span before the min-speed snap

@export var slide_min_speed: float = 0.3            # m/s — slide ends below this
@export var slide_cooldown: float = 0.20            # s between committed slides
# Slide trigger is a pad-coverage check: slide when the puck (projected forward
# by slide_anticipation_time via _puck_velocity_est) is past the goalie's pad
# reach by more than slide_coverage_buffer, AND the puck is within
# slide_threat_max_distance of the goal (imminent). Captures both spec'd
# scenarios — forehand-backhand deke (puck dragged past goalie's pads while
# carrier stays put) and cross-crease pass (puck flies across into pad-edge
# territory on the other side) — without needing separate detector paths.
@export var slide_threat_max_distance: float = 6.0  # m — Euclidean puck→goal; filters long shots
@export var slide_coverage_buffer: float = 0.10     # m — past pad edge before triggering (anti-jitter)
@export var slide_anticipation_time: float = 0.10   # s — projects puck via velocity so cross-crease commits early
# Shooter-present gate: only slide if there's someone who can actually shoot
# the puck. Opposing carrier (any range) counts; loose puck counts only if an
# opposing skater is within this radius. No need to seal the back door for a
# puck nobody can play.
@export var slide_loose_puck_shooter_radius: float = 2.0

# ── Active blade intent ───────────────────────────────────────────────────────
# When an opposing shooter is close, the goalie yaws the blocker assembly so
# the stick blade points toward the puck side — making the stick a deliberate
# obstacle the carrier has to dangle around. Trigger conditions:
#   - Opposing carrier within `active_blade_carrier_radius` of the goalie, OR
#   - Loose puck within `active_blade_loose_puck_radius` with an opposing
#     skater within `slide_loose_puck_shooter_radius` (re-using the slide
#     trigger's shooter-present helper).
@export var active_blade_carrier_radius: float = 2.5
@export var active_blade_loose_puck_radius: float = 1.5
# Max blocker-assembly yaw the active-stick intent will apply. Smaller than
# the elevated-reach yaw cap because the blocker pad rides with the rotation
# and we don't want it swinging off the right side.
@export var active_blade_max_yaw_deg: float = 25.0
# Lookahead depth (m) used in the atan2(-puck_local_x, -lookahead) yaw calc.
# Larger = more lateral offset needed to fully commit the yaw; smaller = blade
# snaps quicker but jumps on small puck wiggles.
@export var active_blade_lookahead: float = 1.5
# Lunge: when an opposing threat is right at the doorstep, the blocker
# assembly briefly extends forward — the stick blade jabs at the puck. Brief
# active window with a cooldown so the goalie can't spam-stick into every
# carrier. The user spec'd this as "lunge"; mechanically it's just a quick
# forward push on c.blocker_pos.z, sin-curved over the active window.
@export var lunge_trigger_distance: float = 1.2  # m — puck-to-goalie radius
@export var lunge_extension: float = 0.35        # m — forward push at peak
@export var lunge_duration: float = 0.15         # s — active window (0→peak→0 sin curve)
@export var lunge_cooldown: float = 0.60         # s — minimum gap between lunges
# Goalie poke check: when the stick blade comes within this radius of the
# carried puck, the goalie strips it. The puck is magneted to the carrier's
# blade with no physics during carry, so RigidBody contact won't fire — this
# is the explicit substitute. Host-only.
@export var goalie_poke_radius: float = 0.25

# ── Paddle-down sweep ─────────────────────────────────────────────────────────
# Butterfly-only stick behavior: paddle drops flat to the ice and the blocker
# arm yaws aggressively toward the puck side. Used to disrupt cross-crease
# one-timers, sweep loose pucks at the goalie's feet, or pressure a deking
# carrier without breaking the pad seal. Composes with the goalie poke check
# automatically — the swept blade reaches further laterally and the per-tick
# poke check fires when it comes within range of a carried puck.
@export var paddle_sweep_trigger_distance: float = 1.5
@export var paddle_sweep_max_yaw_deg: float = 65.0
@export var paddle_sweep_y_drop: float = 0.08
@export var paddle_sweep_x_extension: float = 0.10

# ── Standing sweep ───────────────────────────────────────────────────────────
# Upright equivalent of the paddle-down sweep. More aggressive blade reach
# than the default active blade intent — yaws further, pushes laterally,
# drops the hand a bit. Gated specifically on slow / stationary carriers (or
# loose pucks) at close range, where the goalie has time to commit and
# coaches teach being more aggressive with the stick. Against fast carriers
# the default mild active blade intent stays.
@export var standing_sweep_trigger_distance: float = 2.0
@export var standing_sweep_carrier_max_speed: float = 3.0  # m/s — above this, default to mild intent
@export var standing_sweep_max_yaw_deg: float = 45.0
@export var standing_sweep_y_drop: float = 0.04
@export var standing_sweep_x_extension: float = 0.06

# ── Rebound steering (pad toe-out) ───────────────────────────────────────────
# Pads are angled (Y-yaw, toes outward) so a save deflects the puck toward the
# corner instead of reflecting it straight back up the slot — pose-based rebound
# control, no physics override. Butterfly carries the larger angle: it's the
# low-shot / 5-hole save posture where a straight-back rebound is most
# dangerous. Pushed into the pose builder in _configure_collaborators.
@export var pad_toe_out_standing_deg: float = 12.0
@export var pad_toe_out_butterfly_deg: float = 18.0
# Sealing-pad squaring range (m). The toe-out steers rebounds but angles a pad
# off the goal-line plane; pressed to a post that angle opens a seam beside the
# post. When a butterfly pad's outer edge comes within this distance of its post
# the toe-out ramps to 0 so the pad seals flat and square. Only the sealing pad
# squares — the slot-side pad keeps full toe-out for rebound control. A centred
# butterfly sits `net_half_width - pad_edge` (~0.075 m) short of each post, so
# keep this under that or a centred drop squares both pads and loses all rebound
# steering. Set 0 to disable (pads always toed out).
@export var post_seal_square_range: float = 0.06

# ── Loose-puck clear (sweep the crease) ──────────────────────────────────────
# The stick poke check only strips a CARRIED puck — a loose puck sitting at the
# goalie's feet does nothing on blade contact. This is the missing counterpart:
# a slow loose puck within stick reach in front of the goalie gets actively
# swept to the corner, so the goalie doesn't stand up and leave a rebound in
# the blue paint (the "stop the 5-hole, poke the loose puck in" pattern). Fires
# from any non-reacting state, butterfly or upright, regardless of whether an
# opponent is nearby — clearing the crease is correct even with no pressure.
# Drives the standing / paddle sweep pose too so the reach reads visually.
@export var clear_reach: float = 1.4            # m — goalie-to-puck distance the stick can sweep
@export var clear_max_puck_speed: float = 4.0   # m/s — above this it's a live shot/rebound, leave it
@export var clear_max_height: float = 0.12      # m — puck must be on the ice; airborne pucks aren't swept
@export var clear_dwell: float = 0.35           # s — the puck must sit clearable this long before the sweep
@export var clear_speed: float = 7.0            # m/s imparted to the swept puck
@export var clear_lateral_weight: float = 1.0   # corner-ward bias (lateral vs forward)
@export var clear_forward_weight: float = 0.5   # out-of-crease bias
@export var clear_center_deadband: float = 0.15 # m — |puck.x| under this picks the stick side
@export var clear_cooldown: float = 0.45        # s between sweeps (anti-dribble)
# Clear-sweep animation. The sweep imparts the clearing velocity instantly; on
# its own the puck just shoots to the corner with no stick motion, which reads
# oddly. This is a short timed follow-through — the blocker/paddle swings across
# in the send direction over `sweep_anim_duration` (sin-eased 0→1→0), so the
# blade visibly shoves the puck out. Mirrors the lunge animation idiom. Purely
# cosmetic (the clear velocity is already applied); magnitudes pushed to the pose
# builder in _configure_collaborators.
@export var sweep_anim_duration: float = 0.22       # s — swing-through window
@export var sweep_anim_x_extension: float = 0.14    # m — lateral push toward the send corner at peak
@export var sweep_anim_z_extension: float = 0.18    # m — forward (out-of-crease) push at peak
@export var sweep_anim_max_yaw_deg: float = 40.0    # blade yaw toward the send side at peak

# Body rotation toward the slide direction, applied as a fixed end angle (not
# free-form facing). The pad's effective lateral reach shrinks by cos(rotation),
# so the slide target body_x has to account for it — the two settings are
# computed together so the leading pad EDGE lands on the post regardless of
# rotation. Pure visual "lean into the motion" without breaking the seal.
@export var slide_max_rotation_deg: float = 25.0
# Coil phase duration. The slide is two-phase: body rotates in place (loading
# weight on the far leg) for this long, then push-off translates linearly to
# the seal target. Reads as a deliberate plant-and-push instead of the body
# teleporting laterally with rotation lerping independently.
@export var slide_coil_duration: float = 0.12

# ── Cross-crease detection (STANDING push only) ──────────────────────────────
# A pass whipping across the slot is read off PUCK velocity, not the smoothed
# threat (which lags toward the passer's body). When detected and the goalie is
# STANDING, after a human reaction delay the goalie commits a hard but REALISTIC
# T-push on its feet toward the projected crossing — at the normal t_push_speed,
# accelerating from rest (no turbo, no instant-on). This is deliberately an
# honest race the goalie LOSES to a clean hard cross-seam one-timer (he's still
# mid-push / unset when the shot comes) and wins against slow / telegraphed /
# long-developing feeds. (Butterfly slides are NOT triggered here — they come
# out of the pad-coverage check in _try_commit_slide, which handles both this
# and dekes uniformly.)
@export var cross_crease_slot_depth: float = 5.0        # m in front of goal the pass window covers
@export var cross_crease_lateral_ratio: float = 1.5     # |vx| must exceed |vz|*this to count as a pass
@export var cross_crease_min_lateral_speed: float = 6.0 # m/s puck lateral speed to trigger
@export var cross_crease_lead_time: float = 0.30        # s to project the puck forward for the target
# Human read delay before the push engages — the goalie doesn't move for this
# long after the pass releases. On a quick royal-road one-timer this delay alone
# loses him the race; raise it to make the back door deadlier, lower it (toward
# the dangle/shot reaction_delay) to give him a fighting chance on the cross.
@export var cross_crease_react_delay: float = 0.12      # s before the standing drive engages
@export var cross_crease_push_duration: float = 0.50    # s the standing push stays committed
# Lateral coverage half-extent used to clamp the STANDING cross-crease drive so
# the goalie stays inside the net. This is the standing (pads-together) coverage,
# NOT the splayed butterfly pad edge (pad_local_offset + butterfly_pad_half_width
# = 0.84): clamping the standing push by the butterfly extent left only ±0.075 m
# of travel, T-pushing the goalie to net CENTER — the opposite of sealing the far
# post. Default = pad_local_offset (goalie can drive its near pad toward the post).
@export var cross_crease_drive_edge: float = 0.42
# When a slide commits toward a post (extreme lateral target), the goalie
# also pulls deep so the sealing pad presses the post — backdoor /
# wraparound coverage. Depth target = lerp(current_depth, post_seal_depth)
# scaled by how extreme the lateral slide endpoint is. Slides toward
# centre hold depth; slides to ±net_half_width go fully deep.
@export var post_seal_depth: float = 0.10
# Lateral offset from goalie center to the pad center in butterfly. Used to
# compute the slide target so the sealing pad ends up even with the post:
# goalie center sits at ±(net_half_width - pad_local_offset). Matches the
# `left_pad_pos.x = -0.42` value baked into the BUTTERFLY body config.
@export var pad_local_offset: float = 0.42
# Half-extent of a splayed butterfly pad along the goalie's lateral (X) axis.
# Subtle: the pad collider is BoxShape3D(0.28, 0.84, 0.2), but in butterfly the
# pad is rotated 90° around its Z axis (see GoalieBodyConfigBuilder), which
# swaps the X and Y axes in body-local space — the pad's LENGTH (0.84) becomes
# its lateral extent, not its WIDTH (0.28). Half-length = 0.42.
# Added to pad_local_offset to get the pad's OUTER edge distance from body
# center. Slide targets aim for (post - pad_edge_extent) so the visible pad
# edge lands ON the post rather than overhanging it — sealing with the edge,
# not the center.
@export var butterfly_pad_half_width: float = 0.42
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

# ── Shot anticipation (pre-lean) ──────────────────────────────────────────────
# A charging shot has a visible windup. The goalie reads it and pre-leans toward
# where the shot is *currently* aimed (predicted via the carrier's published
# `predicted_shot_velocity`), so a clean shot into the top corner has a shorter
# arm trip on release. Crucially the lean tracks the LIVE aim every tick — a
# player who drags one way then flicks the other at release moves the real
# impact off the lean, so a tricky release still beats the goalie (read vs
# counter-read, not a flat buff). The lean is PARTIAL (`prelean_strength` of the
# way to the predicted reach) and never adds save speed — it only changes the
# resting hand position, so the arm-delay / glove-speed caps on the actual
# reaction still hold. Directional pre-lean needs the shooter's aim, which is
# only host-side for host-controlled shooters (host player + bots); remote
# shooters fall back to a non-directional "hands up, ready" tell. Host-only like
# all goalie AI — the lean rides the broadcast glove/blocker pose to clients.
@export var prelean_strength: float = 0.35          # 0 = off, 1 = full reach pre-committed
@export var prelean_max_distance: float = 9.0       # m — goalie→shooter range the read fires within
@export var prelean_ready_lift: float = 0.06        # m — non-directional hands-up lift (remote shooters)
# Commit window (s): while the goalie is reading a charging shot from a slot
# shooter — and briefly after — it has committed to that shot and can't also
# anticipate a new lateral threat. The cross-crease desperation push is
# suppressed during this window, so a genuine last-second pass beats the
# committed goalie to the back door (the realism the slide-commit math already
# wants, but which the standing push undercut by pre-jumping the pass). A slow,
# telegraphed cross-pass made before/after the window still gets tracked.
@export var prelean_commit_window: float = 0.25

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
# Faster freeze-clear when the puck contacts this goalie (a save) — the read is
# resolved the instant the save lands, so the goalie lifts the freeze quickly and
# can track / slide to the rebound instead of standing frozen while it sits in the
# slot. Non-save resolutions keep the longer `reaction_clear_delay` beat.
@export var save_clear_delay: float = 0.08
# Hard cap on `_reacting_to_shot` duration as a safety net only. The freeze
# is supposed to end via a resolving event; this catches edge cases where
# none of the expected events fire (puck stuck somewhere, signal missed).
@export var max_reaction_duration: float = 1.0

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

# ── Client Render Tuning ──────────────────────────────────────────────────────
# Clients consume the host's broadcast goalie pose through a small buffer and
# render at `now - NetworkManager.get_interpolation_delay()`, the shared delay
# the skater / puck interpolators also use — so a save reads correctly relative
# to the puck. Local AI doesn't run on clients — the pose is purely
# interpolated, so the client view always matches the host's save-relevant frames.
@export var extrapolation_max_ms: float = 50.0  # cap dead-reckon when snapshots are late
@export var rejoin_blend_duration: float = 0.075  # smoothstep window back from extrapolation

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
# Shoulder save: forward/back pitch on the body during an elevated shot reaction.
# Low-chest shots (intercept_y below `shoulder_pitch_y_neutral`) lean the torso
# forward to present the chest into the shot. Upper-body / head shots lean the
# torso back so the chest collider rocks up and the glove/blocker have room to
# come in. Applied additively on top of each state's resting body pitch so the
# butterfly's existing -10° forward lean is preserved at neutral height.
@export var shoulder_pitch_y_neutral: float = 0.95
@export var shoulder_pitch_forward_max_deg: float = 8.0
@export var shoulder_pitch_back_max_deg: float = 5.0
@export var shoulder_pitch_y_range: float = 0.55  # y-distance from neutral that maps to full back lean
# Hard cap on glove linear speed during shot reactions, in m/s. A velocity cap is
# exact: max per-frame travel = speed * delta. GROUNDED in explosive human hand
# speed: a reactive glove save flashes ~0.6-0.75 m in ~0.13 s ≈ ~5 m/s effective,
# and boxing measures peak hand speed at ~7 m/s (jab) to ~10 m/s (rear straight),
# accelerating rest→full in 50-100 ms. Since this cap is FLAT (the glove moves at
# it from t=0, no ramp) it should sit at the average over the stroke, not the peak
# — hence 5.0, well below the 7-10 peak. The old 2.0 was less than half a real
# hand and, against the raised shot speeds (shorter flight), left the glove unable
# to reach corners it should on mid/long shots. Close top-corner snipes still beat
# the ARM DELAY (arm_reaction_delay 0.18 s > a slot shot's flight), so this only
# shuts the range shots a real goalie gloves — it doesn't touch the in-tight window.
# NOTE: AIActionScoring.GOALIE_ARM_DEPLOY_S mirrors this (= HIGH-band EXT / speed);
# change both together.
@export var glove_react_max_speed: float = 5.0
# Blocker (entire BlockArm assembly) reach speed cap, mirroring the glove.
# Same magnitude — both arms have similar reach speed; if blocker should be
# faster (some real goalies' dominant hand), bump this up.
@export var blocker_react_max_speed: float = 5.0

@export var five_hole_butterfly_move_max: float = 0.18  # opens with slide velocity

# Clients render the goalie purely from the interpolated host pose broadcast
# (see `_interpolate_and_apply`), so there are no client-facing state-transition
# or shot-reaction signals/RPCs — the host's broadcast pose carries the butterfly
# drop, glove/blocker reach, and recovery directly.

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
var _universal_reaction_cfg: GoalieBehaviorRules.UniversalReactionConfig
var _screen_cfg: GoalieBehaviorRules.ScreenConfig
var _move_read_cfg: GoalieBehaviorRules.MovementReadConfig
var _crease_jam_cfg: GoalieBehaviorRules.CreaseJamConfig
var _beaten_wide_cfg: GoalieBehaviorRules.BeatenWideConfig
var _backdoor_cfg: GoalieBehaviorRules.BackdoorThreatConfig
# Reused scratch for the per-shot screen scan so a read doesn't allocate a fresh
# array. PackedVector3Array.clear() keeps capacity across shots.
var _screen_positions: PackedVector3Array = PackedVector3Array()

# ── Runtime (controller-local) ────────────────────────────────────────────────
var _current_depth: float = 0.1
var _current_x: float = 0.0
var _target_x: float = 0.0
var _velocity_x: float = 0.0
var _velocity_z: float = 0.0
# Ramped lateral move speed for the upright arc mover. Accelerates toward the
# desired shuffle / T-push speed at `lateral_accel` so pushes aren't instant;
# reset to 0 whenever the goalie is set/frozen so the next push starts from rest.
var _move_speed_current: float = 0.0
var _five_hole_openness: float = 0.0
var _tracked_threat_position: Vector3 = Vector3.ZERO
# Position-derived puck velocity, for intercept math during elevated shots.
# Works on both host and client (linear_velocity is unreliable on the client
# during interpolation). Updated each tick from the puck position delta.
var _puck_velocity_est: Vector3 = Vector3.ZERO
var _prev_puck_position: Vector3 = Vector3.ZERO
var _puck_approach_velocity: float = 0.0
var _reading_slapper_tell: bool = false
# Cross-crease push state (standing "push on feet" toward a detected pass).
# `_cross_crease_react_timer` counts down the human read delay after the pass is
# detected; when it expires the push engages and `_cross_crease_timer` counts
# down while the drive is committed (drives toward `_cross_crease_target_x` at
# the normal T-push speed, accelerating from rest — see _move_along_arc).
var _cross_crease_react_timer: float = 0.0
var _cross_crease_timer: float = 0.0
var _cross_crease_target_x: float = 0.0
# Shot-commit window: counts down after the goalie last read a charging shot
# from a slot shooter. While > 0 the cross-crease desperation push is suppressed
# (the goalie committed to the shot and is late on the back door).
var _shot_commit_timer: float = 0.0
# Lunge state: active timer counts down while the blocker is extended;
# cooldown timer counts down after each lunge before another can fire.
var _lunge_active_timer: float = 0.0
var _lunge_cooldown_timer: float = 0.0
# Loose-puck sweep cooldown — counts down after each crease clear so the goalie
# sweeps once and lets the puck travel instead of dribbling it tick-by-tick.
var _clear_cooldown_timer: float = 0.0
# Counts up while a loose puck sits clearable in front of the goalie; the sweep
# only fires once it crosses `clear_dwell`. Resets the moment the puck leaves
# the clearable window so the goalie doesn't bat live/airborne pucks on contact.
var _clear_dwell_timer: float = 0.0
# Clear-sweep follow-through animation. `_sweep_anim_timer` counts down while the
# blade swings through after a clear fires; `_sweep_anim_dir` is the goalie-local
# lateral sign of the send (which way the paddle swings). Cosmetic — the clear
# velocity is applied at trigger time; this only drives the pose.
var _sweep_anim_timer: float = 0.0
var _sweep_anim_dir: float = 0.0
# Blade velocity tracking for the goalie poke check. We need the BLADE's
# world velocity (not the goalie body's) because the strip-velocity math
# blends checker blade velocity with carrier blade velocity. Position-
# derived so it works regardless of how the pose updates the blade.
var _prev_blade_world_pos: Vector3 = Vector3.ZERO
var _blade_world_velocity: Vector3 = Vector3.ZERO
# Body rotation captured at slide commit. The coil-phase facing lerps from
# this to the slide end angle so the rotation completes during the coil and
# holds through the translation phase.
var _slide_start_rotation_y: float = 0.0
# Skater accessor for the crease-jam butterfly check. Host-only — the check
# runs inside the host-side state machine; clients render the resulting pose
# from the interpolated host broadcast.
var _skater_getter: Callable = Callable()

# Lag-comp back-date (seconds) consumed by the next release-triggered
# reaction. Set by GameManager._fire_remote_shot / one_timer when a
# client RPC carries a host_timestamp older than now. Cleared on consumption
# so it never bleeds into a later shot.
var _pending_reaction_back_date: float = 0.0

# Sets the back-date in seconds for the next puck_released reaction. Should
# be called immediately before puck.release() so the synchronous
# puck_released signal handler picks it up. Out-of-flow callers (deferred
# release, multiple frames between set and consume) risk applying the
# back-date to the wrong shot — the field clears the moment _on_puck_released
# runs OR _physics_process ticks, whichever comes first.
func set_pending_reaction_back_date(seconds: float) -> void:
	_pending_reaction_back_date = maxf(seconds, 0.0)

# ── Client Simulation ─────────────────────────────────────────────────────────
# State buffer holds the most recent host snapshots (sorted by timestamp).
# `_interpolate_and_apply` reads from it at render_time and writes the pose
# straight onto the goalie node. Bounded at 30 entries (~0.25 s at 120 Hz) to
# match the skater buffer.
var _state_buffer: Array[BufferedGoalieState] = []
# Reused scratch objects for the per-tick client interpolation (both state
# builders rewrite every field on each call, so no stale values leak).
var _scratch_bracket := BufferedStateInterpolator.BracketResult.new()
var _scratch_state := GoalieNetworkState.new()
# Reused ShotResult for the per-tick detect_shot calls (reaction re-projection
# and universal-reaction scan), so the host doesn't allocate one per tick/goalie.
var _scratch_shot := GoalieBehaviorRules.ShotResult.new()
# Separate scratch for the per-tick pre-lean prediction so it never races the
# reaction re-projection scratch within a tick (both can run the same frame).
var _scratch_prelean_shot := GoalieBehaviorRules.ShotResult.new()
# Per-physics-frame memo for _opposing_shooter_near_puck (host hot path).
var _shooter_near_memo_frame: int = -1
var _shooter_near_memo: bool = false
var is_extrapolating: bool = false
# Rejoin blend (root translation only): on the extrapolation→interpolation seam
# the dead-reckoned root position is smoothstepped back to the authoritative
# position so a goalie that changed direction during a packet gap (butterfly
# drop, push to a post) doesn't pop at the crease. Pose joints are frozen during
# extrapolation, not dead-reckoned, so they need no blend. < 0 means inactive.
var _rejoin_blend_elapsed: float = -1.0
var _rejoin_blend_from_x: float = 0.0
var _rejoin_blend_from_z: float = 0.0

func get_buffer_depth() -> int:
	return _state_buffer.size()

# ── Setup ─────────────────────────────────────────────────────────────────────
# `profile` selects the difficulty tuning (Normal vs Hard). Null = Hard, i.e.
# the authored @export defaults unchanged — so tutorial / replay / single-goalie
# spawns that don't pass one behave exactly as before. Applied BEFORE
# _configure_collaborators() so the cached rule configs pick up the changed
# values.
func setup(assigned_goalie: Goalie, assigned_puck: Puck, assigned_goal_line_z: float, assigned_is_server: bool,
		profile: GoalieSkillProfile = null) -> void:
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
	if profile != null:
		_apply_skill_profile(profile)
	_configure_collaborators()
	_sm.transitioned.connect(_on_sm_transitioned)
	_reaction.started.connect(_on_reaction_started)
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

# Overwrite the difficulty-varying @exports from a skill profile. Only the knobs
# the profile carries are touched; everything else keeps its authored default.
# Deliberately does NOT touch reaction_delay or t_push_speed — AIActionScoring
# mirrors those to predict the goalie, so they stay consistent across tiers (see
# GoalieSkillProfile). Called from setup() before the cached configs are built.
func _apply_skill_profile(profile: GoalieSkillProfile) -> void:
	arm_reaction_delay = profile.arm_reaction_delay_s
	cross_crease_react_delay = profile.cross_crease_react_delay_s
	goalie_poke_radius = profile.poke_radius_m
	screen_max_extra_delay = profile.screen_max_extra_delay_s
	move_read_max_delay = profile.move_read_max_delay_s
	depth_aggressive = profile.depth_aggressive_m
	depth_base = profile.depth_base_m
	glove_react_max_speed = profile.glove_react_max_speed_mps
	blocker_react_max_speed = profile.blocker_react_max_speed_mps
	pad_toe_out_butterfly_deg = profile.pad_toe_out_butterfly_deg
	lateral_accel = profile.lateral_accel_mps2


# Live re-apply of a difficulty profile onto a running goalie — used by free play,
# which is effectively the main menu (no match reload) so the goalie tier can be
# tuned without a respawn. Idempotent by construction: the profile sets ABSOLUTE
# values, so re-applying any tier fully determines the exports with no compounding
# (same contract as SkaterController.apply_attributes). Rebuilds the cached rule
# configs so the new depth chart / pose tuning takes effect on the next tick.
func apply_skill_profile(profile: GoalieSkillProfile) -> void:
	if profile == null:
		return
	_apply_skill_profile(profile)
	_configure_collaborators()

# Wired by GameManager so the crease-jam check can scan opposing skaters
# without the controller knowing about the registry / spawner.
func set_skater_getter(getter: Callable) -> void:
	_skater_getter = getter

# Static-drill five-hole opening (only the frozen "beat the goalie" tutorial
# goalie uses these — zero blast radius on real gameplay). A real standing goalie
# rests the paddle on the ice in front of the pads, which sits right over the
# five-hole and blocks the low centre shot the drill asks for. So for the static
# target we widen the pad gap AND lift the blade up off the ice so a dead-centre
# low shot has a real lane. Tunable; the exact look wants an in-editor check.
const _DRILL_FIVE_HOLE_OPEN: float = 0.10   # extra pad separation each side (m)
const _DRILL_STICK_LIFT_DEG: float = 26.0   # reduce the forward blade tilt by this to raise the blade off the ice
const _DRILL_BLOCKER_LIFT:   float = 0.06   # raise the whole blocker assembly (m) so the blade clears the low lane

# Snap the goalie into a neutral STANDING pose in a single apply (t = 1.0).
# The tutorial's stationary "beat the goalie" drill freezes the controller
# (physics + process off) so the AI never ticks — but that also means the pose
# builder never runs, and the goalie holds the scene-default pose with its pads
# together, closing the five-hole the drill tells the player to shoot at. Call
# this after disabling processing so the static goalie reads as a proper upright
# goalie: top corners open and a five-hole between the pads.
#
# `open_five_hole` additionally widens the pad gap and lifts the paddle off the
# ice so the low centre shot the drill teaches actually has somewhere to go.
func snap_to_standing_pose(open_five_hole: bool = false) -> void:
	_sm.reset()
	var pad_open: float = _DRILL_FIVE_HOLE_OPEN if open_five_hole else 0.0
	_five_hole_openness = pad_open
	_pose_inputs.state = State.STANDING
	_pose_inputs.five_hole_openness = pad_open
	_pose_inputs.reading_slapper_tell = false
	_pose_inputs.reacting_to_shot = false
	_pose_inputs.shot_is_elevated = false
	_pose_inputs.current_x = _current_x
	_pose_inputs.goalie_z = goalie.global_position.z
	_pose_inputs.direction_sign = _direction_sign
	_pose_inputs.slide_velocity_x = 0.0
	_pose_inputs.slide_dir = 0.0
	_pose_inputs.arm_reaction_pending = false
	_pose_inputs.puck_position = puck.global_position
	_pose_inputs.puck_velocity_est = Vector3.ZERO
	_pose_inputs.blade_intent_active = false
	_pose_inputs.lunge_progress = 0.0
	_pose_inputs.sweep_anim_progress = 0.0
	_pose_inputs.sweep_anim_dir = 0.0
	_pose_inputs.paddle_sweep_active = false
	_pose_inputs.standing_sweep_active = false
	var config: GoalieBodyConfig = _pose.build(_pose_inputs)
	if open_five_hole:
		# Lift the paddle up off the ice so it no longer guards the five-hole.
		# (Direction is hand-agnostic: less forward tilt = blade higher; the pad
		# widening above is symmetric.)
		config.blocker_pos.y += _DRILL_BLOCKER_LIFT
		config.blocker_rot.x -= _DRILL_STICK_LIFT_DEG
	goalie.apply_body_config(config, 1.0)

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
	_slide.pad_edge_extent = pad_local_offset + butterfly_pad_half_width
	_slide.coil_duration = slide_coil_duration
	_slide.post_event_slide_lockout = post_event_slide_lockout
	_slide.butterfly_drop_speed = butterfly_drop_speed
	_slide.butterfly_min_hold_time = butterfly_min_hold_time
	_reaction.reaction_delay = reaction_delay
	_reaction.arm_reaction_delay = arm_reaction_delay
	_reaction.max_reaction_duration = max_reaction_duration
	_reaction.reaction_clear_delay = reaction_clear_delay
	_reaction.save_clear_delay = save_clear_delay
	_pose.catches_left = catches_left
	_pose.rvh_post_pad_angle = rvh_post_pad_angle
	_pose.pad_toe_out_standing = pad_toe_out_standing_deg
	_pose.pad_toe_out_butterfly = pad_toe_out_butterfly_deg
	_pose.glove_max_x_outward = glove_max_x_outward
	_pose.glove_max_x_inward = glove_max_x_inward
	_pose.glove_max_z_reach = glove_max_z_reach
	_pose.glove_max_yaw_deg = glove_max_yaw_deg
	_pose.blocker_max_x_outward = blocker_max_x_outward
	_pose.blocker_max_x_inward = blocker_max_x_inward
	_pose.blocker_max_z_reach = blocker_max_z_reach
	_pose.blocker_max_yaw_deg = blocker_max_yaw_deg
	_pose.active_blade_max_yaw_deg = active_blade_max_yaw_deg
	_pose.active_blade_lookahead = active_blade_lookahead
	_pose.lunge_extension = lunge_extension
	_pose.paddle_sweep_max_yaw_deg = paddle_sweep_max_yaw_deg
	_pose.paddle_sweep_y_drop = paddle_sweep_y_drop
	_pose.paddle_sweep_x_extension = paddle_sweep_x_extension
	_pose.standing_sweep_max_yaw_deg = standing_sweep_max_yaw_deg
	_pose.standing_sweep_y_drop = standing_sweep_y_drop
	_pose.standing_sweep_x_extension = standing_sweep_x_extension
	_pose.sweep_anim_x_extension = sweep_anim_x_extension
	_pose.sweep_anim_z_extension = sweep_anim_z_extension
	_pose.sweep_anim_max_yaw_deg = sweep_anim_max_yaw_deg
	_pose.body_lean_max_deg = body_lean_max_deg
	_pose.body_lean_reach_norm = body_lean_reach_norm
	_pose.shoulder_pitch_y_neutral = shoulder_pitch_y_neutral
	_pose.shoulder_pitch_forward_max_deg = shoulder_pitch_forward_max_deg
	_pose.shoulder_pitch_back_max_deg = shoulder_pitch_back_max_deg
	_pose.shoulder_pitch_y_range = shoulder_pitch_y_range
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
# every physics tick, for no semantic gain.
func _build_rule_configs() -> void:
	_shot_cfg = GoalieBehaviorRules.ShotDetectionConfig.new()
	_shot_cfg.shot_speed_threshold = shot_speed_threshold
	_shot_cfg.net_half_width = net_half_width
	_shot_cfg.net_margin = net_margin
	_shot_cfg.reaction_delay = reaction_delay
	_shot_cfg.low_shot_threshold = low_shot_threshold
	_shot_cfg.elevated_threshold = elevated_threshold
	_screen_cfg = GoalieBehaviorRules.ScreenConfig.new()
	_screen_cfg.screener_radius = screener_radius
	_move_read_cfg = GoalieBehaviorRules.MovementReadConfig.new()
	_move_read_cfg.reference_speed = move_read_reference_speed
	_move_read_cfg.max_delay = move_read_max_delay
	_crease_jam_cfg = GoalieBehaviorRules.CreaseJamConfig.new()
	_crease_jam_cfg.puck_distance = jam_puck_distance
	_crease_jam_cfg.opponent_distance = jam_opponent_distance
	_crease_jam_cfg.carrier_max_speed = jam_carrier_max_speed
	_universal_reaction_cfg = GoalieBehaviorRules.UniversalReactionConfig.new()
	_universal_reaction_cfg.min_speed = universal_react_min_speed
	_universal_reaction_cfg.max_time_to_impact = universal_react_max_time_to_impact
	_universal_reaction_cfg.net_half_width = net_half_width
	_universal_reaction_cfg.net_margin = net_margin
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
	_beaten_wide_cfg = GoalieBehaviorRules.BeatenWideConfig.new()
	_beaten_wide_cfg.goalie_lateral_speed = t_push_speed
	_beaten_wide_cfg.goalie_lateral_accel = lateral_accel
	_beaten_wide_cfg.reach_half_width = pad_local_offset
	_beaten_wide_cfg.min_lateral_speed = beaten_wide_min_lateral_speed
	_beaten_wide_cfg.max_threat_distance = beaten_wide_max_threat_distance
	_backdoor_cfg = GoalieBehaviorRules.BackdoorThreatConfig.new()
	_backdoor_cfg.pass_speed = backdoor_assumed_pass_speed
	_backdoor_cfg.release_time = backdoor_release_time
	_backdoor_cfg.react_delay = cross_crease_react_delay
	_backdoor_cfg.goalie_lateral_speed = t_push_speed
	_backdoor_cfg.goalie_lateral_accel = lateral_accel
	_backdoor_cfg.max_shooter_distance = backdoor_max_shooter_distance

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
	_cross_crease_react_timer = 0.0
	_cross_crease_timer = 0.0
	_cross_crease_target_x = 0.0
	_shot_commit_timer = 0.0
	_lunge_active_timer = 0.0
	_lunge_cooldown_timer = 0.0
	_clear_cooldown_timer = 0.0
	_sweep_anim_timer = 0.0
	_sweep_anim_dir = 0.0
	_move_speed_current = 0.0
	goalie.set_stick_collision_enabled(true)
	goalie.set_goalie_position(_current_x, _goal_line_z + _direction_sign * _current_depth)
	goalie.set_goalie_rotation_y(PI if _direction_sign == 1 else 0.0)

# ── Process ───────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if goalie == null or puck == null:
		return
	# Clients are pure interpolators: the host's authoritative pose is buffered
	# and rendered at `now - interpolation_delay`, no local AI tick. This
	# eliminates host/client divergence (ghost saves, phantom goals) that the
	# old client-AI-with-soft-correction model produced when the local puck
	# read and the broadcast read disagreed.
	if not is_server:
		if _rejoin_blend_elapsed >= 0.0:
			_rejoin_blend_elapsed += delta
		_interpolate_and_apply()
		return
	_update_tracking(delta)
	_update_shot_timer(delta)
	_update_state(delta)
	_update_depth(delta)
	_update_position(delta)
	_update_facing(delta)
	_update_body_parts(delta)
	_update_goalie_poke(delta)

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
	if is_server:
		_update_shot_commit(delta, carrier)
		_update_cross_crease(delta, carrier)
		_update_lunge(delta)
	# Universal puck tracking: trigger a reaction for any loose puck above the
	# threshold heading for the net within max_time_to_impact, regardless of
	# whether a release event fired. Catches board bounces, poke-strips,
	# deflections, rebounds. Gated to host, non-reacting, non-RVH, loose puck
	# — release-event-triggered shots and RVH commits remain untouched.
	if is_server and not _reaction.reacting and not _sm.is_rvh() and carrier == null:
		_check_universal_reaction()
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
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot_into(
			puck.global_position, _loose_puck_velocity(),
			_goal_line_z, _goal_center_x, _shot_cfg, _scratch_shot)
	if result.is_shot:
		_reaction.update_impact(result.impact_x, result.impact_y)
		# Elevated shot that's tipped low and tracking low — start the
		# butterfly drop timer (still allowed during freeze; arms-and-drop
		# are the body reactions the freeze permits).
		if result.is_low:
			_reaction.tip_to_low(reaction_delay)
	elif _puck_past_save_plane():
		# The shot has passed the save point (or is a weak deflection wandering
		# off slowly): the read the freeze was holding is resolved. Arm the clear
		# so a puck that never contacts a resolving surface can't pin the goalie
		# for the full max_reaction_duration safety cap. Narrow on purpose — a
		# still-live shot drifting wide but fast holds the freeze until it hits
		# the boards, exactly as before.
		_reaction.arm_clear()

# Threat = blend of carrier body and puck. While reacting to a shot in flight
# the puck IS the threat (no chest to chase — react to trajectory). RVH and
# recovering states use raw puck position too because the carrier's body
# isn't the relevant target there. STANDING/READY/BUTTERFLY blend chest+puck.
func _compute_threat_position() -> Vector3:
	var carrier: Skater = puck.get_carrier()
	if carrier == null or _reaction.reacting \
			or _sm.is_rvh() \
			or _sm.current == State.RECOVERING:
		# Loose puck (or reaction-frozen / RVH / recovering): track the raw puck
		# position. A SEPARATE, near-zero lead is used here (vs the dangle branch
		# below) so the goalie does NOT front-run a back-door pass — he reads where
		# the puck IS, not where it's headed, and so loses the race across the
		# crease to a hard cross-seam pass exactly like a real goalie. The lead
		# scales with puck speed, so it only ever mattered for FAST loose pucks
		# (passes); a slow rebound is unaffected either way.
		var puck_lead: Vector3 = _puck_velocity_est * loose_puck_velocity_lead_time
		puck_lead.y = 0.0
		return puck.global_position + puck_lead
	# COILING and SLIDING share the down-state chest weight (they're part of
	# the butterfly cycle, just at different points in the motion).
	var base_w: float = shooter_weight_butterfly if _sm.is_down() else shooter_weight_standing
	# Distance-scaled chest tracking: far out, play the shooter's chest almost
	# entirely (the dangle is irrelevant until it's in tight) and fade the puck
	# lead to zero so forehand-backhand jitter stops wobbling the body; in tight,
	# restore full puck tracking. Keyed off the carrier's distance to the goal.
	var carrier_dist: float = GoalieBehaviorRules.threat_distance_to_goal(
			carrier.global_position, _goal_line_z, _goal_center_x)
	var chest_t: float = GoalieBehaviorRules.chest_tracking_factor(
			carrier_dist, chest_track_near_distance, chest_track_far_distance)
	var w: float = lerpf(base_w, shooter_weight_far, chest_t)
	var blended: Vector3 = GoalieBehaviorRules.compute_threat_position(
			puck.global_position, carrier.global_position, true, w)
	# Two leads: CARRIER velocity captures body motion (sustained skating) and is
	# smooth, so it always contributes. PUCK velocity captures dangle / dragged-
	# across motion (forehand-backhand dekes, pivot-to-shoot blade swings) — it's
	# the jitter source, so it's faded out with distance (×(1-chest_t)): kept in
	# tight where it keeps the goalie in front of a walkout deke, gone at range
	# where it only chased stickhandling wiggle. Y is zeroed because skaters
	# don't move vertically — leading height noise would drift the threat off ice.
	var lead: Vector3 = carrier.velocity * carrier_velocity_lead_time \
			+ _puck_velocity_est * puck_velocity_lead_time * (1.0 - chest_t)
	lead.y = 0.0
	return blended + lead

# ── Shot Timer ────────────────────────────────────────────────────────────────
# `_reaction.shot_timer` is the goalie's processing delay after shot release —
# the beat between "I see the shot" and "I act on the prediction". Gates the
# butterfly drop (low shots) AND the arm reach (elevated shots, see
# `GoalieBodyConfigBuilder._apply_elevated_shot_reaction`).
func _update_shot_timer(delta: float) -> void:
	_reaction.tick_processing_timers(delta)
	if not _reaction.low_drop_ready(_sm.is_upright()):
		return
	# Leg drop is reflexive once the shot's read, but only commit to butterfly
	# when the puck is actually closing on the net. Passes fire puck_released
	# like any quick-shot, so without this a pass/clear up the ice reads as a
	# low shot from across the rink and drops the goalie before the play
	# arrives. The reaction freeze + arm tracking still begin at release (in
	# _on_puck_released); only the leg drop waits for the puck to close within
	# drop_max_time_to_impact. `low_drop_ready` is a level signal, so the drop
	# fires on whichever tick the puck first becomes imminent.
	var ttg: float = _puck_time_to_goal_line()
	if ttg >= 0.0 and ttg <= drop_max_time_to_impact:
		_enter_butterfly()

# Seconds until the puck crosses this goalie's goal line on its current heading,
# or -1 if it isn't approaching (moving parallel or away). Host-side only — uses
# linear_velocity, reliable on the host. Drives the imminence gate on the
# low-shot butterfly drop in _update_shot_timer.
func _puck_time_to_goal_line() -> float:
	var vz: float = _loose_puck_velocity().z
	if absf(vz) < 0.001:
		return -1.0
	var t: float = (_goal_line_z - puck.global_position.z) / vz
	return t if t > 0.0 else -1.0

# Velocity for reading a LOOSE puck's trajectory (a shot / pass / rebound in
# flight). On the host the authoritative Jolt `linear_velocity` is the cleanest
# signal; the position-derived estimate is the fallback for clients (where
# `linear_velocity` is unreliable during interpolation) and for the brief
# frozen→dynamic release transition where it momentarily reads zero. Callers must
# already know the puck is loose — a CARRIED puck is frozen on the blade so its
# `linear_velocity` is meaningless; those reads use the tracked chest instead.
# One intentional accessor so the linear_velocity / estimate choice lives in a
# single place rather than being re-decided (inconsistently) at each call site.
func _loose_puck_velocity() -> Vector3:
	if is_server and not puck.linear_velocity.is_zero_approx():
		return puck.linear_velocity
	return _puck_velocity_est

# True when a shot the goalie is frozen-reading has resolved without contacting a
# surface: the puck is past the save point (goal-side of the goalie), or it's a
# weak deflection loitering slowly and moving away. Lets `_update_tracking` lift
# the freeze so a puck that never fires a boards/post/net event can't pin the
# goalie for the full `max_reaction_duration` safety cap.
func _puck_past_save_plane() -> bool:
	var perp: float = (puck.global_position.z - goalie.global_position.z) * _direction_sign
	if perp < 0.0:
		return true
	var approaching: float = -_loose_puck_velocity().z * _direction_sign
	return approaching < 0.0 and puck.linear_velocity.length() < shot_speed_threshold

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
	# Clear leftover reaction timers only when we're down with NO active reaction —
	# the stale-state case this guard was written for (a returning RECOVERING/RVH
	# transition must not instantly re-fire butterfly; low_drop_ready's own
	# `reacting` gate also covers that). Do NOT clear them for an ACTIVE reaction
	# that legitimately started while down (an elevated shot during butterfly/slide,
	# a rebound scramble): zeroing arm_timer there deleted the entire arm reaction
	# delay + screen/caught-moving penalties, making the goalie INSTANT exactly in
	# the down/moving scoring windows the design opens on purpose.
	if not _sm.is_upright() and not _reaction.reacting:
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
			elif _is_carrier_at_doorstep() and not _reaction.reacting:
				# Slapshot windup at point-blank range — close-range slapshots
				# travel faster than the goalie can react after release, so the
				# drop has to happen during the windup. A controlled stickhandler
				# in space still keeps the goalie up (force the release); the
				# net-front JAM below is the separate scramble trigger.
				_enter_butterfly()
			elif _should_seal_crease_jam() and not _reaction.reacting:
				# Net-front jam: a loose-puck scramble, a slow carrier jammed at
				# the doorstep, or a teammate corralling a contested puck in the
				# crease. Seal the ice low so a stick battle can't be banged
				# through the STANDING 5-hole. Distinct from a controlled carrier
				# attacking with space (handled by the stay-up default).
				_enter_butterfly()
			elif _is_beaten_wide() and not _reaction.reacting:
				# Beaten wide: the carrier's lateral drive wins the race to the
				# post — standing tracking is unwinnable, so drop now; the
				# _try_commit_slide pad-coverage check seals the post from
				# butterfly. Around-the-pad tucks die here; the counter is
				# baiting the drop and pulling back up (recovery window).
				_enter_butterfly()
			else:
				# Toggle STANDING ↔ READY based on threat conditions.
				var should_be_ready: bool = _is_ready_situation()
				if _sm.current == State.STANDING and should_be_ready:
					_sm.transition_to(State.READY)
				elif _sm.current == State.READY and not should_be_ready:
					_sm.transition_to(State.STANDING)
		State.BUTTERFLY, State.COILING, State.SLIDING:
			# All three down states share the butterfly hold/drop animation.
			# tick_butterfly drains drop_progress, hold_timer, event_lockout.
			_slide.tick_butterfly(delta)
			# Recovery only fires from idle BUTTERFLY (not mid-slide and not
			# mid-coil). Slide completion transitions back to BUTTERFLY first —
			# recovery can fire on the next tick if conditions hold. RVH from
			# butterfly is forbidden: must stand first so the goalie eats a
			# recovery window on wraparound plays.
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

# True when an opposing carrier at point-blank range is loading a SLAPSHOT.
# This is the only carrier-state that drops a goalie proactively in coaching:
# slapshot windup is an unambiguous commit (no cancel-and-deke option from
# SLAPPER_CHARGE_WITH_PUCK), so the goalie reads it and drops early —
# tracking a close-range slapshot from standing is a losing battle.
#
# We DON'T drop for "controlled stickhandler in tight" — coaches teach
# staying up against a controlled carrier, forcing them to release. Wrister
# charge is also intentionally NOT a drop trigger: the player can hold or
# cancel a wrister indefinitely, and reacting to charge alone commits the
# goalie prematurely. The actual wrister release fires the existing reaction
# pipeline, which drops on low projection.
#
# Crease scrambles (loose puck or a slow carrier jammed in tight) drop via the
# separate _should_seal_crease_jam check.
func _is_carrier_at_doorstep() -> bool:
	# Lunge precedence — give the stick first.
	if _lunge_active_timer > 0.0:
		return false
	var carrier: Skater = puck.get_carrier()
	if carrier == null:
		return false
	if carrier.get_team_id() == team_id and team_id != -1:
		return false
	# Slapshot windup is the only drop tell from a single carrier.
	if carrier.current_shot_state != SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK:
		return false
	# "In front of goalie" — carrier on the slot side relative to the goalie,
	# not behind or even with them. RVH handles behind-net plays.
	if (carrier.global_position.z - goalie.global_position.z) * _direction_sign <= 0.0:
		return false
	return goalie.global_position.distance_to(carrier.global_position) < close_crease_butterfly_distance

# True when an opposing carrier's lateral drive has beaten the standing
# goalie to the tuck point (the around-the-pad reach). Race math in
# GoalieBehaviorRules.is_beaten_wide; this gathers the scene inputs. Reads the
# carrier's actual body + velocity, not the lerped tracked threat — the tuck
# follows the chest, and the smoothed threat lags exactly when the drive is
# fastest.
func _is_beaten_wide() -> bool:
	var carrier: Skater = puck.get_carrier()
	if carrier == null:
		return false
	if team_id != -1 and carrier.get_team_id() == team_id:
		return false
	return GoalieBehaviorRules.is_beaten_wide(
			carrier.global_position, carrier.velocity.x,
			goalie.global_position, _goal_line_z, _goal_center_x,
			_direction_sign, net_half_width, _beaten_wide_cfg)

# True when there's a net-front JAM the goalie should seal: a loose-puck
# scramble in the crease (puck close, no carrier, an opposing skater on it) OR a
# SLOW opposing carrier jammed at the doorstep. The slow-carrier gate is the
# realism line — a fast carrier driving the net is an attack (stay up, force the
# release), a slow one jamming in the paint is a battle (seal the ice). The pure
# threshold decision lives in GoalieBehaviorRules.is_crease_jam; this method
# gathers the scene inputs.
#
# A jam is any of: a loose-puck scramble in the crease, a SLOW opposing carrier
# jammed at the doorstep, or a teammate corralling a CONTESTED puck on the
# doorstep (opponent within poke range — one strip from a goal). Drives both the
# proactive butterfly entry in _update_state and the recovery hold in
# _is_threat_pressing, so the goalie seals a contested crease and stays sealed
# rather than popping up into a poke-check-and-bang-it-in.
func _should_seal_crease_jam() -> bool:
	# Cheap reject before any skater scan — a jam only matters in the goalie's lap.
	if goalie.global_position.distance_to(puck.global_position) > jam_puck_distance:
		return false
	var carrier: Skater = puck.get_carrier()
	if carrier != null and (team_id == -1 or carrier.get_team_id() != team_id):
		# Opposing carrier → jam only if slow.
		return GoalieBehaviorRules.is_crease_jam(
				puck.global_position, goalie.global_position, _goal_line_z, _direction_sign,
				true, carrier.velocity.length(), INF, _crease_jam_cfg)
	# Loose puck, or a teammate-controlled puck: a jam when an opponent is within
	# poke range of the puck in the goalie's lap.
	var nearest_opp: float = _nearest_opposing_skater_dist_to_puck()
	return GoalieBehaviorRules.is_crease_jam(
			puck.global_position, goalie.global_position, _goal_line_z, _direction_sign,
			false, 0.0, nearest_opp, _crease_jam_cfg)

# Distance from the nearest non-ghost opposing skater to the puck, or INF if
# there are none (or no skater getter wired). Ghosted players (offside / icing)
# can't play the puck, so they don't make a jam.
func _nearest_opposing_skater_dist_to_puck() -> float:
	if not _skater_getter.is_valid():
		return INF
	var skaters: Array = _skater_getter.call()
	var nearest: float = INF
	for skater: Skater in skaters:
		if skater == null or skater.is_ghost:
			continue
		if team_id != -1 and skater.get_team_id() == team_id:
			continue
		nearest = minf(nearest, skater.global_position.distance_to(puck.global_position))
	return nearest

# True when an opposing shooter is close enough to the goalie that the stick
# blade should actively point at the puck side. Carrier within
# active_blade_carrier_radius, OR loose puck within active_blade_loose_puck_
# radius with an opposing skater near it (the slide trigger's shooter-present
# check, scoped to the loose-puck case).
func _is_blade_intent_active() -> bool:
	var carrier: Skater = puck.get_carrier()
	if carrier != null:
		if team_id != -1 and carrier.get_team_id() == team_id:
			return false
		return goalie.global_position.distance_to(carrier.global_position) \
				< active_blade_carrier_radius
	# Loose puck: must be close to the goalie AND have an opposing skater
	# nearby (someone who can actually whack it).
	if goalie.global_position.distance_to(puck.global_position) \
			>= active_blade_loose_puck_radius:
		return false
	return _opposing_shooter_near_puck(slide_loose_puck_shooter_radius)


# True when the goalie should commit to a standing sweep instead of the
# subtle active-blade-intent yaw. Upright states only; puck must be close,
# carrier slow (or puck loose), and an opposing shooter present. Skipped
# during reactions. The "carrier slow" gate is the realism win — coaches
# teach being more aggressive with the stick against dawdling stickhandlers
# (they're not moving fast enough to surprise the goalie), but staying mild
# against carriers driving hard (commitment leaves the goalie exposed).
func _is_standing_sweep_active() -> bool:
	if _sm.is_down():
		return false
	if _reaction.reacting:
		return false
	# A loose puck in tight gets the aggressive reach even with no opponent near
	# — the goalie is actively sweeping the crease (see _try_clear_loose_puck).
	if _is_loose_puck_clearable():
		return true
	if goalie.global_position.distance_to(puck.global_position) > standing_sweep_trigger_distance:
		return false
	if not _opposing_shooter_near_puck(slide_loose_puck_shooter_radius):
		return false
	# Loose puck = aggressive by default; carrier must be slow to qualify.
	var carrier: Skater = puck.get_carrier()
	if carrier == null:
		return true
	return carrier.velocity.length() <= standing_sweep_carrier_max_speed


# True when the goalie should commit to a paddle-down sweep instead of the
# upright active blade intent. Butterfly-family states only, and the puck
# (loose or carried) must be close to the goalie with an opposing shooter
# present. Skipped during reactions — the elevated reach owns the blocker.
func _is_paddle_sweep_active() -> bool:
	if not _sm.is_down():
		return false
	if _reaction.reacting:
		return false
	# Loose puck in tight gets the paddle reach even with no opponent near — the
	# goalie sweeps the crease from butterfly (see _try_clear_loose_puck).
	if _is_loose_puck_clearable():
		return true
	if goalie.global_position.distance_to(puck.global_position) > paddle_sweep_trigger_distance:
		return false
	return _opposing_shooter_near_puck(slide_loose_puck_shooter_radius)


# Lunge timing: tick the active and cooldown timers, and trigger a fresh
# lunge if both are idle and the trigger conditions hold. Host-only.
func _update_lunge(delta: float) -> void:
	if _lunge_active_timer > 0.0:
		_lunge_active_timer = maxf(_lunge_active_timer - delta, 0.0)
		return
	if _lunge_cooldown_timer > 0.0:
		_lunge_cooldown_timer = maxf(_lunge_cooldown_timer - delta, 0.0)
		return
	if _should_lunge():
		_lunge_active_timer = lunge_duration
		_lunge_cooldown_timer = lunge_duration + lunge_cooldown


# Lunge trigger: doorstep threat. Puck close to the goalie, on the slot side
# (not behind), and someone can actually shoot it. No lunging during a shot
# reaction (the arm reach takes priority over the stick jab) or from RVH.
func _should_lunge() -> bool:
	if _reaction.reacting:
		return false
	if _sm.is_rvh():
		return false
	if goalie.global_position.distance_to(puck.global_position) > lunge_trigger_distance:
		return false
	if (puck.global_position.z - goalie.global_position.z) * _direction_sign <= 0.0:
		return false
	return _opposing_shooter_near_puck(slide_loose_puck_shooter_radius)


# Goalie poke check. The puck is magneted to the carrier's blade with no
# physics during carry, so RigidBody contact won't strip it. Instead we run
# an explicit distance check each frame after the pose has been applied:
# if the goalie's blade is within goalie_poke_radius of the carried puck
# (and the carrier is opposing), call Puck.apply_goalie_poke_check.
#
# After a successful strip the puck has no carrier, so next-tick's check
# self-suppresses. The carrier's reattach_cooldown prevents an instant
# re-pickup that would let the goalie chain pokes.
#
# Velocity is position-derived (works regardless of how the pose system
# updates the blade) and used by poke_strip_velocity to direct the strip.
func _update_goalie_poke(delta: float) -> void:
	var current_blade_pos: Vector3 = goalie.get_blade_world_position()
	if _prev_blade_world_pos == Vector3.ZERO:
		_prev_blade_world_pos = current_blade_pos
	_blade_world_velocity = (current_blade_pos - _prev_blade_world_pos) / maxf(delta, 0.0001)
	_prev_blade_world_pos = current_blade_pos
	if _sweep_anim_timer > 0.0:
		_sweep_anim_timer = maxf(_sweep_anim_timer - delta, 0.0)
		if _sweep_anim_timer <= 0.0:
			# Sweep window over — restore the stick's normal save collision.
			goalie.set_stick_collision_enabled(true)
	var carrier: Skater = puck.get_carrier()
	if carrier == null:
		# No carrier to strip — instead sweep a loose puck out of the crease.
		_try_clear_loose_puck(delta)
		return
	# Phase lock — same gate the skater path's _check_interactions respects.
	# Faceoff prep / goal celebration freezes the puck; no pokes during those.
	if puck.pickup_locked:
		return
	# Use the shared can_poke_check rule (excludes own-team, future rules
	# inherited automatically) instead of inlining the team comparison.
	var carrier_team: int = carrier.get_team_id()
	if not PuckCollisionRules.can_poke_check(carrier_team, team_id):
		return
	if puck.global_position.distance_to(current_blade_pos) > goalie_poke_radius:
		return
	puck.apply_goalie_poke_check(current_blade_pos, _blade_world_velocity)


# Loose-puck crease clear. The poke check above strips a CARRIED puck; this is
# its loose-puck counterpart — when a slow loose puck is sitting within stick
# reach in front of the goalie, sweep it to the corner so the goalie doesn't
# stand up and leave a rebound in the blue paint. A cooldown gates it to one
# sweep per visit so the goalie shoves the puck clear instead of dribbling it
# tick-by-tick. Host-only (called from the host-gated _update_goalie_poke).
func _try_clear_loose_puck(delta: float) -> void:
	if _clear_cooldown_timer > 0.0:
		_clear_cooldown_timer = maxf(_clear_cooldown_timer - delta, 0.0)
		return
	if not _is_loose_puck_clearable():
		_clear_dwell_timer = 0.0
		return
	# The puck has to settle on the ice in front of the goalie for a beat before
	# the sweep fires — otherwise the goalie bats pucks away the instant they
	# drift into reach. Accumulate dwell while clearable; the predicate already
	# reset it to zero the moment the puck left the window.
	_clear_dwell_timer += delta
	if _clear_dwell_timer < clear_dwell:
		return
	# Dead-centre pucks have no natural corner — sweep toward the stick side.
	var default_side: float = 1.0 if catches_left else -1.0
	var sweep_vel: Vector3 = GoalieBehaviorRules.compute_clear_velocity(
			puck.global_position, _goal_center_x, _direction_sign,
			clear_lateral_weight, clear_forward_weight, clear_speed,
			clear_center_deadband, default_side)
	# Disable the stick's own collision before imparting velocity: the puck
	# has been dwelling right next to the blade (it actively tracks toward
	# the puck's side while loose — see _apply_active_blade_intent /
	# _apply_standing_sweep), and the swept puck's exit line often runs
	# straight through that resting blade. Re-enabled once the sweep window
	# (_sweep_anim_timer) elapses, in _update_goalie_poke's countdown.
	goalie.set_stick_collision_enabled(false)
	puck.apply_goalie_sweep(sweep_vel)
	_clear_cooldown_timer = clear_cooldown
	_clear_dwell_timer = 0.0
	# Kick off the follow-through swing so the blade visibly shoves the puck out.
	# Send direction in goalie-local X: world +X maps to local -direction_sign.
	var send_sign: float = signf(sweep_vel.x)
	if send_sign == 0.0:
		send_sign = 1.0 if catches_left else -1.0
	_sweep_anim_dir = send_sign * -_direction_sign
	_sweep_anim_timer = sweep_anim_duration


# True when a loose puck is sitting on the ice in front of the goalie, slow and
# close enough to sweep to the corner with the stick. Drives both the actual clear
# (_try_clear_loose_puck) and the standing / paddle sweep pose so the reach
# reads visually. Loose pucks only — carried pucks go through the poke check.
# Skipped while reacting to a shot (the goalie is reading a save, not poking at
# a rebound) and from RVH (post-hug owns the behind-net puck). Fires regardless
# of whether an opponent is near — clearing the crease is correct with no
# pressure too. Cheap value math only (no allocation, no skater scan), so it's
# safe to call several times per tick.
func _is_loose_puck_clearable() -> bool:
	if puck.get_carrier() != null:
		return false
	if puck.pickup_locked:
		return false
	if _reaction.reacting or _sm.is_rvh():
		return false
	# In front of the goal line only — never sweep a puck behind the net.
	if (puck.global_position.z - _goal_line_z) * _direction_sign <= 0.0:
		return false
	# On the ice only — a puck in the air is a live shot/deflection, not a loose
	# puck to sweep. Without this the goalie bats airborne pucks out of the air.
	if puck.global_position.y > clear_max_height:
		return false
	if puck.linear_velocity.length() > clear_max_puck_speed:
		return false
	return goalie.global_position.distance_to(puck.global_position) <= clear_reach


# Returns the current lunge progress as a sin curve: 0 at start, 1 at peak
# (mid-window), 0 at end. The pose builder consumes this to scale the
# forward blocker extension.
func _lunge_progress() -> float:
	if _lunge_active_timer <= 0.0 or lunge_duration <= 0.0:
		return 0.0
	var elapsed: float = clampf((lunge_duration - _lunge_active_timer) / lunge_duration, 0.0, 1.0)
	return sin(PI * elapsed)


# Clear-sweep follow-through, sin-curved 0 → 1 (peak) → 0 over sweep_anim_duration.
# The pose builder scales the blade swing-through by this value. Same shape as
# the lunge; distinct timer so a clear and a lunge don't fight over one window.
func _sweep_anim_progress() -> float:
	if _sweep_anim_timer <= 0.0 or sweep_anim_duration <= 0.0:
		return 0.0
	var elapsed: float = clampf((sweep_anim_duration - _sweep_anim_timer) / sweep_anim_duration, 0.0, 1.0)
	return sin(PI * elapsed)


# True when the puck has someone who can actually shoot it: either an opposing
# carrier (any range), or a loose puck with an opposing skater within
# `loose_puck_radius`. Own-team possession / own-team retrieves don't count
# as shooting threats.
func _opposing_shooter_near_puck(loose_puck_radius: float) -> bool:
	# Per-tick memo: five predicates call this every _physics_process with the
	# same radius, and nothing it reads changes within a tick. Only the common
	# radius is memoized so an unusual caller still computes exactly.
	var frame: int = Engine.get_physics_frames()
	var memoizable: bool = loose_puck_radius == slide_loose_puck_shooter_radius
	if memoizable and frame == _shooter_near_memo_frame:
		return _shooter_near_memo
	var result: bool = _compute_opposing_shooter_near_puck(loose_puck_radius)
	if memoizable:
		_shooter_near_memo_frame = frame
		_shooter_near_memo = result
	return result

func _compute_opposing_shooter_near_puck(loose_puck_radius: float) -> bool:
	var carrier: Skater = puck.get_carrier()
	if carrier != null:
		if team_id != -1 and carrier.get_team_id() == team_id:
			return false
		return true
	if not _skater_getter.is_valid():
		return false
	var skaters: Array = _skater_getter.call()
	for skater: Skater in skaters:
		if skater == null:
			continue
		if team_id != -1 and skater.get_team_id() == team_id:
			continue
		if skater.global_position.distance_to(puck.global_position) < loose_puck_radius:
			return true
	return false

func _enter_butterfly() -> void:
	_sm.transition_to(State.BUTTERFLY)

# Entry side-effects for state changes — host-only, since it fires off
# `_sm.transition_to` and only the host runs the goalie state machine (clients
# render the interpolated host pose and set `_sm.current` directly).
# Snap-back-to-depth bookkeeping is unit-sensitive: `_current_depth` carries
# different units per state (radius in STANDING/READY/RECOVERING; perpendicular
# depth in BUTTERFLY/RVH) and the wrong unit on entry teleports the goalie.
func _on_sm_transitioned(prev: State, new_state: State) -> void:
	match new_state:
		State.BUTTERFLY:
			# Fresh butterfly entry resets timers + snaps depth. Returning
			# inside the same slide cycle (COILING/SLIDING → BUTTERFLY)
			# preserves accumulated hold time, drop progress, and the depth
			# the slide ended at.
			if prev != State.SLIDING and prev != State.COILING:
				_slide.enter_fresh_butterfly()
				# Standing/Ready stored radius; butterfly holds perpendicular
				# depth, so snap to the goalie's actual world perp depth.
				_current_depth = (goalie.global_position.z - _goal_line_z) * _direction_sign
			_slide.velocity_x = 0.0
		State.RECOVERING:
			_slide.velocity_x = 0.0
			# Standing back up from a drop — the upright mover starts from rest.
			_move_speed_current = 0.0
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
	# Crease jam: hold butterfly through a net-front scramble — the same gate that
	# triggers the proactive drop in _update_state (no pop-up mid-battle). Covers a
	# loose puck, a slow opposing carrier, and a teammate corralling a contested
	# puck on the doorstep (poke-checked loose and banged in through a goalie
	# standing back up).
	if _should_seal_crease_jam():
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
	if _sm.current == State.COILING:
		# Depth is managed by `_slide.tick_coil` (lerps from coil_start_depth
		# toward start_depth as the body rotates around the pivot foot).
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
	# Lateral pressure retreat — when a lateral threat moves faster than the
	# goalie can t-push, pull depth back toward the goal line so the lateral
	# distance to cover shrinks. Scales with the velocity deficit so only
	# overspeed plays trigger meaningful retreat; small lateral motion at
	# normal carry speeds doesn't move the depth.
	var lateral_deficit: float = maxf(absf(_puck_velocity_est.x) - t_push_speed, 0.0)
	var lateral_pull: float = minf(lateral_deficit * lateral_pressure_depth_pull,
			lateral_pressure_max_pull)
	if lateral_pull > 0.0:
		target_radius = maxf(target_radius - lateral_pull, depth_defensive)
	# Backdoor-aware cap (anticipatory): with a live one-timer man on the weak
	# side, don't challenge farther out than the cross-crease re-square race
	# allows. See the export block for the model; INF when no threat binds.
	var backdoor_cap: float = _backdoor_depth_cap()
	if backdoor_cap < target_radius:
		target_radius = maxf(backdoor_cap, depth_defensive)
	_current_depth = lerpf(_current_depth, target_radius, depth_speed * delta)

# Most restrictive backdoor depth cap across the opposing off-puck skaters, or
# INF when nothing binds. Only meaningful against an opposing carrier — a
# backdoor one-timer needs a passer — so loose pucks and own-team possession
# skip the scan entirely. Scalar loop over the registry snapshot, no per-tick
# allocation (hot path: 120 Hz × goalies while standing).
func _backdoor_depth_cap() -> float:
	var carrier: Skater = puck.get_carrier()
	if carrier == null:
		return INF
	if team_id != -1 and carrier.get_team_id() == team_id:
		return INF
	if not _skater_getter.is_valid():
		return INF
	var skaters: Array = _skater_getter.call()
	var cap: float = INF
	for skater: Skater in skaters:
		if skater == null or skater == carrier or skater.is_ghost:
			continue
		if team_id != -1 and skater.get_team_id() == team_id:
			continue
		cap = minf(cap, GoalieBehaviorRules.backdoor_depth_cap(
				puck.global_position, _tracked_threat_position,
				skater.global_position, _goal_line_z, _goal_center_x,
				_direction_sign, _backdoor_cfg))
	return cap

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
		State.COILING:
			# Body rotates around the planted (pivot) foot, sweeping from
			# (coil_start_x, coil_start_depth) to the post-rotation
			# (start_x, start_depth). When the coil completes the next tick
			# enters SLIDING with push-off velocity already armed.
			_update_butterfly_five_hole(delta)
			var coil_pair: Vector2 = _slide.tick_coil(delta)
			_current_x = coil_pair.x
			_current_depth = coil_pair.y
			new_z = _goal_line_z + _direction_sign * _current_depth
			if _slide.is_coil_complete():
				_sm.transition_to(State.SLIDING)
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
		# Frozen and reading the shot — the goalie is set, so the next push after
		# the freeze clears starts the ramp from rest.
		_move_speed_current = 0.0
		if is_server:
			_five_hole_openness = lerpf(_five_hole_openness, five_hole_base, part_lerp_speed * delta)
		return current
	var target_xz: Vector2 = _arc_target_xz()
	# Cross-crease "push on feet": after the read delay (handled in
	# _update_cross_crease), a detected pass overrides the lateral target toward
	# the projected crossing and the goalie commits a hard T-push toward the far
	# man — but at the NORMAL t_push_speed, accelerating from rest like any push.
	# No turbo and no instant-on: it's an honest race the goalie loses to a quick
	# cross-seam one-timer and wins against a slow feed. Host-only (the timer is
	# host-set; clients adopt position via broadcast).
	var cross_crease_push: bool = is_server and _cross_crease_timer > 0.0
	if cross_crease_push:
		target_xz.x = _cross_crease_target_x
	_target_x = target_xz.x
	var delta_2d: float = current.distance_to(target_xz)
	var move_speed: float
	var five_hole_target: float
	if cross_crease_push:
		move_speed = t_push_speed
		five_hole_target = five_hole_t_push_max
	elif delta_2d < 0.01:
		move_speed = shuffle_speed
		five_hole_target = five_hole_base
	elif delta_2d > lateral_threshold:
		move_speed = t_push_speed
		five_hole_target = five_hole_t_push_max
	else:
		move_speed = shuffle_speed
		five_hole_target = five_hole_shuffle_max
	# Ramp the effective speed toward the desired so a push isn't instant — the
	# goalie accelerates onto its edge. The cross-crease drive ramps the same way
	# (a real push-off builds speed), which is part of why it loses the race to a
	# hard pass.
	_move_speed_current = move_toward(_move_speed_current, move_speed, lateral_accel * delta)
	var effective_speed: float = _move_speed_current
	var step: float = effective_speed * delta
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
#
# Arc target (x, z) at the current radius — the challenge-angle position for
# STANDING/READY/RECOVERING tracing. BUTTERFLY uses compute_slide_destination
# with butterfly_radius instead.
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
	var pad_edge: float = pad_local_offset + butterfly_pad_half_width
	var slide_rot: float = deg_to_rad(slide_max_rotation_deg)
	# Shooter-present gate: no point sealing the back door for a puck nobody
	# can play. Either an opposing carrier or an opposing skater within
	# slide_loose_puck_shooter_radius of a loose puck.
	if not _opposing_shooter_near_puck(slide_loose_puck_shooter_radius):
		return
	# Imminence gate: only slide for threats close to the net. Long shots
	# (puck still far in z) skip the trigger entirely. Euclidean so a wide
	# threat in the slot still qualifies.
	var puck_dist_to_goal: float = GoalieBehaviorRules.threat_distance_to_goal(
			puck.global_position, _goal_line_z, _goal_center_x)
	if puck_dist_to_goal > slide_threat_max_distance:
		return
	# Pad-coverage check. The lateral reference differs by whether the puck is
	# carried or loose:
	#   Carried — use the chest-weighted, distance-damped tracked threat, NOT the
	#     raw dangled puck. A stickhandle wiggle swings the puck past the pad edge
	#     on every deke; keying the slide off it made the goalie re-commit little
	#     slides and skate back and forth across the crease chasing jitter. The
	#     tracked threat only crosses the pad edge when the carrier genuinely
	#     moves the chest across (a real cross-crease drive), which is the slide
	#     we actually want.
	#   Loose — project the puck forward via its velocity so a cross-crease pass /
	#     rebound in flight commits the slide early (the back-door seal).
	var coverage_x: float
	if puck.get_carrier() != null:
		coverage_x = _tracked_threat_position.x
	else:
		coverage_x = puck.global_position.x + _loose_puck_velocity().x * slide_anticipation_time
	var lateral_offset: float = coverage_x - _current_x
	if absf(lateral_offset) <= pad_edge + slide_coverage_buffer:
		return
	var puck_side: float = signf(lateral_offset)
	if puck_side == 0.0:
		return
	var seal_target: float = _post_edge_seal_x(puck_side, pad_edge, slide_rot)
	# Skip if we're already at (or very near) the seal spot — the slide just
	# completed, no need to re-commit on the same side.
	if absf(seal_target - _current_x) < 0.05:
		return
	_slide_start_rotation_y = goalie.get_goalie_rotation_y()
	var seal_end: Vector2 = _coil_end_xz(puck_side, slide_rot)
	_slide.commit_slide(_current_x, _current_depth, seal_target,
			net_half_width, seal_end.x, seal_end.y)
	_sm.transition_to(State.COILING)


# Where the body ends up after the coil phase: it rotates around the PIVOT
# FOOT (the planted pad, opposite the slide direction) by the slide deviation,
# so the body sweeps an arc and lands somewhere shifted from the start. The
# planted pad's WORLD position stays fixed; the body and the OTHER pad swing.
#
# Body offset from pivot at slide start = (+side * pad_local_offset, 0), and it
# rotates by `deviation = direction_sign * side * slide_rot` in the XZ plane.
# The result fed to commit_slide as the coil-end / slide-phase start position.
#
# Returns Vector2(coil_end_x_world, coil_end_perp_depth).
func _coil_end_xz(side: float, slide_rot: float) -> Vector2:
	var deviation: float = _direction_sign * side * slide_rot
	var c: float = cos(deviation)
	var s: float = sin(deviation)
	# Body's offset from pivot rotates: (pad_local_offset, 0) → (pad*c, pad*s).
	# Delta in world XZ from the start body position is therefore
	# (pad*(c-1), pad*s) in the +side direction, but we want the delta in body
	# world coords: shift_x = side * pad * (c - 1), shift_z = side * pad * s.
	var shift_x: float = side * pad_local_offset * (c - 1.0)
	var shift_z: float = side * pad_local_offset * s
	# Convert world Z shift into perpendicular depth shift. Depth is
	# (z_world - goal_line_z) * direction_sign, so a positive z_world delta
	# becomes a +direction_sign delta in depth.
	var depth_shift: float = shift_z * _direction_sign
	return Vector2(_current_x + shift_x, _current_depth + depth_shift)


# Compute the goalie body X that puts the leading pad's outer edge ON the post
# for the given side (+1 = right post, -1 = left post), accounting for the
# body rotation the slide will end at: a rotated pad reaches `cos(rot)` of its
# unrotated lateral extent, so the body has to sit `pad_edge_extent * cos(rot)`
# inside the post (not `pad_edge_extent`). Without this correction the pad
# falls short of the post when the body is rotated, leaving the seal open.
func _post_edge_seal_x(side: float, pad_edge_extent: float, rotation_rad: float) -> float:
	var effective_reach: float = pad_edge_extent * cos(rotation_rad)
	return _goal_center_x + side * maxf(net_half_width - effective_reach, 0.0)

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
	if _sm.current == State.BUTTERFLY:
		# Idle butterfly: hold whatever angle the slide ended at (or the drop
		# came in at). No animation — real goalies don't rotate the body once
		# down, and the slow lerp toward centre we used to do quietly undid
		# the slide's facing while the goalie was still down.
		return
	if _sm.current == State.RECOVERING:
		# Standing back up — gentle return to square so the next read starts
		# from a neutral base.
		var center_angle: float = PI if _direction_sign == 1 else 0.0
		goalie.set_goalie_rotation_y(lerp_angle(
				goalie.get_goalie_rotation_y(), center_angle, rotation_speed * 0.5 * delta))
		return
	if _sm.current == State.COILING:
		# Coil phase: lerp body rotation from the start angle (captured at
		# commit) to the slide end angle, driven by coil_progress. End angle
		# is the fixed cos()-coupled value the seal target was computed
		# against — using atan2-based facing here would let rotation vary by
		# slide steepness and break the seal geometry. Convention:
		# deviation = direction_sign * _slide.dir * slide_rot, verified
		# against the standing facing code for both goal sides.
		var base_angle: float = PI if _direction_sign == 1 else 0.0
		var deviation: float = _direction_sign * _slide.dir * deg_to_rad(slide_max_rotation_deg)
		var target_y: float = base_angle + deviation
		var coil_progress: float = clampf(
				1.0 - _slide.coil_timer / _slide.coil_duration, 0.0, 1.0) \
				if _slide.coil_duration > 0.0 else 1.0
		goalie.set_goalie_rotation_y(lerp_angle(
				_slide_start_rotation_y, target_y, coil_progress))
		return
	if _sm.current == State.SLIDING:
		# Slide phase: hold the end angle the coil set. No further rotation —
		# the body is committed and translating.
		var base_angle: float = PI if _direction_sign == 1 else 0.0
		var deviation: float = _direction_sign * _slide.dir * deg_to_rad(slide_max_rotation_deg)
		goalie.set_goalie_rotation_y(base_angle + deviation)
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
	_pose_inputs.blade_intent_active = _is_blade_intent_active()
	_pose_inputs.lunge_progress = _lunge_progress()
	_pose_inputs.sweep_anim_progress = _sweep_anim_progress()
	_pose_inputs.sweep_anim_dir = _sweep_anim_dir
	_pose_inputs.paddle_sweep_active = _is_paddle_sweep_active()
	_pose_inputs.standing_sweep_active = _is_standing_sweep_active()
	_set_pad_toe_out_inputs()
	_set_prelean_inputs()
	var config: GoalieBodyConfig = _pose.build(_pose_inputs)
	var lerp_t: float
	if _sm.is_down():
		# Drop snap: scale lerp speed so pads converge ~95% within
		# `butterfly_drop_speed`. Lerp is asymptotic — for time-to-95%
		# convergence we need `speed * time ≈ 3`, so the factor is 3/x not 1/x.
		# Once the drop is complete, fall back to reaction speed for any
		# remaining tweaks. BUTTERFLY / COILING / SLIDING share the same
		# logic — they're all butterfly form, just at different motion
		# phases.
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

# Square each butterfly pad flat to its post as it seals, killing the rebound-
# steering toe-out only on the pad that's actually pressed to a post (the seam
# fix). `shortfall` is how far a pad's outer edge still is from its post: a
# centred butterfly sits `net_half_width - pad_edge` short of both, and as the
# goalie shifts toward a post that pad's shortfall drops to 0 and it squares.
# Both pads are set every tick (cheap value math); only butterfly / sliding
# poses read them.
func _set_pad_toe_out_inputs() -> void:
	var pad_edge: float = pad_local_offset + butterfly_pad_half_width
	var center_short: float = net_half_width - pad_edge
	# Local-left pad seals the post on the +direction_sign world side; local-right
	# seals the -direction_sign side. Derived from the pose's ±0.42 pad offsets
	# and the world mapping world_x = current_x - direction_sign * local_x.
	var shortfall_left: float = center_short - _direction_sign * _current_x
	var shortfall_right: float = center_short + _direction_sign * _current_x
	_pose_inputs.left_pad_toe_out = GoalieBehaviorRules.sealed_pad_toe_out(
			shortfall_left, pad_toe_out_butterfly_deg, post_seal_square_range)
	_pose_inputs.right_pad_toe_out = GoalieBehaviorRules.sealed_pad_toe_out(
			shortfall_right, pad_toe_out_butterfly_deg, post_seal_square_range)

# Populate the pose builder's pre-lean fields. The goalie leans toward a charging
# shot's predicted impact while reading the windup (see _is_reading_shot_threat).
# Directional lean needs the shooter's live predicted velocity, which is only
# published host-side for host-controlled shooters (host player + bots); remote
# shooters leave it ZERO and get the non-directional readiness tell. Re-solved
# every tick off the LIVE aim, so a late release moves the impact off the lean.
func _set_prelean_inputs() -> void:
	_pose_inputs.prelean_active = false
	_pose_inputs.prelean_directional = false
	_pose_inputs.prelean_strength = prelean_strength
	_pose_inputs.prelean_ready_lift = prelean_ready_lift
	if prelean_strength <= 0.0:
		return
	var carrier: Skater = puck.get_carrier()
	if not _is_reading_shot_threat(carrier):
		return
	_pose_inputs.prelean_active = true
	var vel: Vector3 = carrier.predicted_shot_velocity
	if vel.length_squared() < 0.01:
		return  # remote shooter (no aim on the wire) — non-directional tell only
	var res: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot_into(
			puck.global_position, vel, _goal_line_z, _goal_center_x,
			_shot_cfg, _scratch_prelean_shot)
	if not res.is_shot:
		return  # current aim isn't on net — nothing to lean toward
	_pose_inputs.prelean_directional = true
	_pose_inputs.prelean_impact_x = res.impact_x
	_pose_inputs.prelean_impact_y = res.impact_y

# ── Cross-crease detection (STANDING push only) ───────────────────────────────

# Read a cross-crease pass off PUCK velocity. The STANDING goalie arms its
# "push on feet" target/timer (consumed in _move_along_arc) toward the
# projected crossing. Butterfly slides are NOT triggered here — they fall
# out of the pad-coverage check in _try_commit_slide.
# Restricted to LOOSE pucks (a pass/bounce/strip in flight) — a carrier
# moving laterally with the puck is normal lateral skating, handled by the
# standing arc tracking. Loose-puck cross-creases get the standing push so
# the goalie can beat the puck to the far post on its feet.
func _update_cross_crease(delta: float, carrier: Skater) -> void:
	if _cross_crease_timer > 0.0:
		_cross_crease_timer -= delta
	# Tick the human read delay; when it expires the committed drive engages.
	if _cross_crease_react_timer > 0.0:
		_cross_crease_react_timer -= delta
		if _cross_crease_react_timer <= 0.0:
			_cross_crease_react_timer = 0.0
			_cross_crease_timer = cross_crease_push_duration
	if carrier != null:
		return
	if _reaction.reacting or _sm.is_rvh():
		return
	# Committed to a shot the goalie just read — don't pre-jump a new lateral
	# threat. A genuine last-second pass beats the committed goalie to the back
	# door (the realism the committed-slide math already wants). The goalie still
	# tracks the loose puck via normal arc movement, just without the desperation
	# push that used to anticipate the pass and beat it to the far post.
	if _shot_commit_timer > 0.0:
		return
	var cross_vx: float = GoalieBehaviorRules.lateral_puck_velocity_in_slot(
			puck.global_position, _loose_puck_velocity(), _goal_line_z,
			_direction_sign, cross_crease_slot_depth, cross_crease_lateral_ratio)
	if absf(cross_vx) < cross_crease_min_lateral_speed:
		return
	# Project the puck forward along its lateral motion. The slide consumer
	# uses the sign to pick which post to seal; the standing drive consumer
	# uses the value directly (where the receiver is). Clamp to the seal extent
	# so the standing push doesn't overshoot the sealing position. Re-aimed each
	# frame — an upright goalie can still adjust the drive on its feet (unlike a
	# committed butterfly slide).
	# Standing drive: clamp with the standing coverage extent, NOT the splayed
	# butterfly pad edge — the latter pinned the goalie to net-center (see
	# cross_crease_drive_edge). Keeps the near pad inside the post while letting
	# the goalie actually drive across to seal the far side.
	var target_x: float = puck.global_position.x + cross_vx * cross_crease_lead_time
	target_x = _slide.clamp_lateral_target(target_x, _goal_center_x, net_half_width, cross_crease_drive_edge)
	_cross_crease_target_x = target_x
	# Read the pass once, then commit a single delayed drive — don't restart the
	# delay or re-arm while a read or drive is already in flight.
	if _cross_crease_timer <= 0.0 and _cross_crease_react_timer <= 0.0:
		if cross_crease_react_delay > 0.0:
			_cross_crease_react_timer = cross_crease_react_delay
		else:
			_cross_crease_timer = cross_crease_push_duration

# Maintain the shot-commit window. The goalie is "committed" while it reads a
# charging shot from an opposing slot shooter; the timer lingers
# `prelean_commit_window` seconds after the read so a pass fired at the very end
# of the windup still lands inside it. Consumed by _update_cross_crease.
func _update_shot_commit(delta: float, carrier: Skater) -> void:
	if _shot_commit_timer > 0.0:
		_shot_commit_timer = maxf(_shot_commit_timer - delta, 0.0)
	if _is_reading_shot_threat(carrier):
		_shot_commit_timer = prelean_commit_window

# True when an opposing carrier in the slot is winding up a shot (wrister drag or
# slapshot charge) close enough that the goalie respects it. Drives both the
# pre-lean pose and the shot-commit window. Upright-only and not while already
# reacting — once a shot is in flight the reaction pipeline owns the read. Reads
# only `current_shot_state` (replicated) so it fires for remote shooters too;
# the DIRECTIONAL lean additionally needs the host-side predicted velocity.
func _is_reading_shot_threat(carrier: Skater) -> bool:
	if carrier == null:
		return false
	if _reaction.reacting or not _sm.is_upright():
		return false
	if team_id != -1 and carrier.get_team_id() == team_id:
		return false
	if carrier.current_shot_state != SkaterStateMachine.State.WRISTER_AIM \
			and carrier.current_shot_state != SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK:
		return false
	# In front of the goalie (slot side), within read range — not behind the net.
	if (carrier.global_position.z - goalie.global_position.z) * _direction_sign <= 0.0:
		return false
	return goalie.global_position.distance_to(carrier.global_position) <= prelean_max_distance

# Universal puck-tracking trigger. Runs each host physics frame on loose
# pucks; if the puck is fast and on track for the net within the
# reaction window, kicks off the same reaction pipeline as a release
# event. The release-event path (`_on_puck_released`) handles the
# carrier-just-let-go case; this handles everything else.
func _check_universal_reaction() -> void:
	# Loose-puck read (this path is gated to a null carrier), so the authoritative
	# linear_velocity is the right signal — routed through _loose_puck_velocity so
	# the choice matches every other loose read and degrades to the estimate if the
	# puck is momentarily frozen→dynamic. `_on_puck_released` still owns the actual
	# release transition via get_release_velocity().
	var vel: Vector3 = _loose_puck_velocity()
	if not GoalieBehaviorRules.should_react_to_puck(
			puck.global_position, vel,
			_goal_line_z, _goal_center_x, _universal_reaction_cfg):
		return
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot_into(
			puck.global_position, vel,
			_goal_line_z, _goal_center_x, _shot_cfg, _scratch_shot)
	if not result.is_shot:
		return
	if debug_goalie_reads:
		print("[goalie %d] universal reaction: puck@%.1f,%.1f vel=%.1f impact_x=%.2f %s" % [
				team_id, puck.global_position.x, puck.global_position.z,
				puck.linear_velocity.length(), result.impact_x,
				"ELEVATED" if result.is_elevated else "low"])
	_reaction.start(result.impact_x, result.impact_y, result.is_elevated,
			result.reaction_delay, 0.0, _read_extra_delay(vel))


# Total extra latency before the goalie picks up the shot: a screen hiding the
# puck PLUS being caught moving / unset at the read. Both push the leg drop and
# arm reach back. Computed once per shot (event-driven), off the hot path.
# `shot_velocity` is the release velocity — the occlusion delay needs the shot's
# speed and heading to know how long a screener hides the puck.
func _read_extra_delay(shot_velocity: Vector3) -> float:
	return _screen_delay(shot_velocity) + _movement_read_delay()


# Screen contribution: gather every body that could hide the puck from the goalie
# (both teams — a D-man screens his own goalie too; ghosted players don't), take
# the grounded occlusion delay for the worst screener, and clamp it to
# `screen_max_extra_delay`. The shooter self-excludes geometrically (they sit at
# the release point, along ≈ 0 < min_along).
func _screen_delay(shot_velocity: Vector3) -> float:
	if screen_max_extra_delay <= 0.0 or not _skater_getter.is_valid():
		return 0.0
	var skaters: Array = _skater_getter.call()
	_screen_positions.clear()
	for skater: Skater in skaters:
		if skater == null or skater.is_ghost:
			continue
		_screen_positions.append(skater.global_position)
	if _screen_positions.is_empty():
		return 0.0
	var delay: float = GoalieBehaviorRules.screen_occlusion_delay(
			puck.global_position, shot_velocity, goalie.global_position,
			_screen_positions, _screen_cfg)
	return minf(delay, screen_max_extra_delay)


# Caught-moving contribution: how unset the goalie is at the read. Planar speed
# (lateral + depth motion) is the main driver; RECOVERING adds a posture floor
# (standing up is the least ready stance to make a save from). Mid-slide unset is
# already captured by the slide's translation speed.
func _movement_read_delay() -> float:
	if move_read_max_delay <= 0.0:
		return 0.0
	var planar_speed: float = sqrt(_velocity_x * _velocity_x + _velocity_z * _velocity_z)
	var scrambling: bool = _sm.current == State.RECOVERING
	return GoalieBehaviorRules.movement_read_penalty(planar_speed, scrambling, _move_read_cfg)


# ── Shot Detection ────────────────────────────────────────────────────────────
func _on_puck_released() -> void:
	# Consume any pending lag-comp back-date up front so an early `_sm.is_rvh()`
	# return or a no-shot result still clears the field — otherwise the next
	# puck event would inherit stale latency from a previous unrelated release.
	var back_date: float = _pending_reaction_back_date
	_pending_reaction_back_date = 0.0
	# RVH is post-hug coverage with a separate pose — no glove reach is wired,
	# and the goalie is already committed to the puck-side post. Every other
	# state (STANDING, READY, BUTTERFLY, SLIDING, RECOVERING) supports the
	# elevated-shot arm reach via the body-config builder, so the freeze starts
	# from any of them. Previously this was gated on `is_upright()`, which
	# silently dropped all goalie reactions to shots fired while the goalie was
	# already down — top-corner shots over a butterflied goalie went un-tracked
	# because the reaction freeze never started.
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
	# Imminence gate: a release still way out (a hard pass or clear up the ice —
	# passes fire puck_released too) shouldn't begin a reaction. Don't freeze /
	# arm-read from across the rink. Genuine long shots aren't lost: once the
	# loose puck closes to within `universal_react_max_time_to_impact` the
	# universal-reaction path in _update_tracking picks it up. The back-date
	# (client latency) effectively brings the shot a touch closer, so subtract it.
	if result.time_to_impact - back_date > react_max_time_to_impact:
		return
	# Two separate processing delays. `shot_timer` (= reaction_delay, ~130ms)
	# gates the butterfly drop on low shots — leg drop is reflexive.
	# `arm_timer` (= arm_reaction_delay, ~180ms) gates the glove/blocker reach
	# on elevated shots — arms need extra processing time to decide WHERE in
	# the upper net to reach. Both run in parallel; start() arms both, and
	# `back_date` lag-comps client-initiated releases so the goalie gets the
	# same effective reaction window the shooter perceived.
	_reaction.start(result.impact_x, result.impact_y, result.is_elevated,
			result.reaction_delay, back_date, _read_extra_delay(puck.get_release_velocity()))

# Puck just hit a goalie body part. Re-arms the slide lockout so deflections
# don't trigger spurious slides, starts the reaction clear delay, and drops
# the goalie into butterfly if they were still upright — modern butterfly is
# the rebound-control posture (Hockey Canada / OMHA coaching). After a
# high-shot save off the chest/glove the goalie should be sealing the ice
# while the rebound resolves, not still standing. The existing recovery gate
# then decides standing back up based on whether the rebound is still close.
# Filters by identity since `Puck.puck_touched_goalie` fires on either
# net's goalie.
func _on_puck_contact(contacted: Goalie) -> void:
	if contacted != goalie:
		return
	_slide.arm_event_lockout()
	# A save resolves the read immediately — clear the freeze fast so the goalie
	# can track / slide to the rebound rather than sit frozen while it's in the
	# slot. (The slide event-lockout above still gives a beat before a committed
	# slide, so the goalie doesn't chase an unpredictable fresh deflection.)
	_reaction.arm_clear(true)
	if is_server and _sm.is_upright():
		_enter_butterfly()

# Resolving events (boards / post / net) that aren't goalie-specific. Any of
# these means the shot has resolved — no longer a threat the goalie is
# reading. Starts the clear delay if currently reacting.
func _on_reaction_resolved() -> void:
	_reaction.arm_clear()

# Reaction collaborator signal handler — translates the reaction start into the
# host-side slide lockout. (Host-only in practice: clients render from the
# interpolated pose broadcast and never run the reaction state machine.)
func _on_reaction_started(_impact_x: float, _impact_y: float, _is_elevated: bool) -> void:
	# Goalies track up until release, then commit to their read — they need a
	# beat to process the shot before they can react to a new lateral threat.
	# Suppresses slide triggers during that window. Same mechanism as the
	# post-contact lockout; one runtime timer covers both events (max wins).
	_slide.arm_event_lockout()

# ── State Serialization ───────────────────────────────────────────────────────
# Returns the typed network state object. Flattening to Array happens at the
# RPC boundary (GameManager.get_world_state), not here.
func get_state() -> GoalieNetworkState:
	var s := GoalieNetworkState.new()
	fill_state(s)
	return s

# Caller-owned-instance variant for the per-tick StateBufferManager capture.
func fill_state(s: GoalieNetworkState) -> void:
	s.position_x = goalie.global_position.x
	s.position_z = goalie.global_position.z
	s.rotation_y = goalie.get_goalie_rotation_y()
	s.state_enum = _sm.current as int
	s.five_hole_openness = _five_hole_openness
	s.velocity_x = _velocity_x
	s.velocity_z = _velocity_z
	# Authoritative pose — read live body-part transforms so replays and clients
	# (once step 2 lands) reflect the actual pose the host evaluated saves
	# against. Stick rides the blocker arm IRL (blocker pad on stick hand), so
	# no separate socket — the stick transform is derived from blocker + the
	# fixed scene offset baked into BlockArm.
	var body_rot: Vector3 = goalie.get_body_rotation()
	s.body_pitch = body_rot.x
	s.body_roll = body_rot.z
	s.left_pad_offset = goalie.get_left_pad_position()
	var lp_rot: Vector3 = goalie.get_left_pad_rotation()
	s.left_pad_pitch = lp_rot.x
	s.left_pad_roll = lp_rot.z
	s.left_pad_yaw = lp_rot.y
	s.right_pad_offset = goalie.get_right_pad_position()
	var rp_rot: Vector3 = goalie.get_right_pad_rotation()
	s.right_pad_pitch = rp_rot.x
	s.right_pad_roll = rp_rot.z
	s.right_pad_yaw = rp_rot.y
	s.glove_offset = goalie.get_glove_position()
	var g_rot: Vector3 = goalie.get_glove_rotation()
	s.glove_yaw = g_rot.y
	s.glove_pitch = g_rot.x
	s.blocker_offset = goalie.get_blocker_position()
	var b_rot: Vector3 = goalie.get_blocker_rotation()
	s.blocker_yaw = b_rot.y
	s.blocker_pitch = b_rot.x
	s.head_yaw = goalie.get_head_yaw()

func apply_state(network_state: GoalieNetworkState, host_ts: float) -> void:
	if is_server:
		return
	# Drop out-of-order packets — the buffer must stay sorted by timestamp for
	# bracket search to work, and an older snapshot can't visibly improve a
	# render anyway.
	if not _state_buffer.is_empty() and host_ts <= _state_buffer.back().timestamp:
		NetworkTelemetry.record_ooo_drop()
		return
	var entry := BufferedGoalieState.new()
	entry.timestamp = host_ts
	entry.state = network_state
	_state_buffer.append(entry)
	if _state_buffer.size() > 30:
		_state_buffer.pop_front()

# Renders the goalie at `now - interpolation_delay` from the buffered host
# snapshots. Lerps root + every socket transform between bracketing entries;
# when the buffer is empty or we've overshot the newest entry, dead-reckons
# the newest pose forward by velocity (capped at `extrapolation_max_ms`).
func _interpolate_and_apply() -> void:
	var prev_extrapolating: bool = is_extrapolating
	if _state_buffer.is_empty():
		is_extrapolating = false
		return
	var render_time: float = NetworkManager.estimated_host_time() - NetworkManager.get_interpolation_delay()
	var bracket: BufferedStateInterpolator.BracketResult = BufferedStateInterpolator.find_bracket(
			_state_buffer, render_time, _scratch_bracket)
	if bracket == null:
		is_extrapolating = false
		return
	is_extrapolating = bracket.is_extrapolating
	var interpolated: GoalieNetworkState
	if bracket.is_extrapolating:
		var dt: float = minf(bracket.extrapolation_dt, extrapolation_max_ms / 1000.0)
		var newest: GoalieNetworkState = bracket.to_state
		interpolated = _extrapolate_goalie_state(newest, dt)
	else:
		interpolated = _lerp_goalie_state(bracket.from_state, bracket.to_state, bracket.t)
	# Seam back from extrapolation: capture the currently-rendered root position
	# and smoothstep it onto the authoritative one over rejoin_blend_duration, so
	# a direction change during the gap doesn't snap. Mirrors the skater / puck
	# rejoin blend; scoped to root translation since the pose was held, not
	# dead-reckoned. C1 easing keeps the correction velocity from kinking.
	if prev_extrapolating and not is_extrapolating:
		_rejoin_blend_from_x = goalie.global_position.x
		_rejoin_blend_from_z = goalie.global_position.z
		_rejoin_blend_elapsed = 0.0
	if _rejoin_blend_elapsed >= 0.0:
		var ease_t: float = clampf(_rejoin_blend_elapsed / rejoin_blend_duration, 0.0, 1.0)
		var eased: float = smoothstep(0.0, 1.0, ease_t)
		interpolated.position_x = lerpf(_rejoin_blend_from_x, interpolated.position_x, eased)
		interpolated.position_z = lerpf(_rejoin_blend_from_z, interpolated.position_z, eased)
		if ease_t >= 1.0:
			_rejoin_blend_elapsed = -1.0
	_apply_interpolated(interpolated)
	BufferedStateInterpolator.drop_stale(_state_buffer, render_time)

# Fills and returns the reused _scratch_state — every field is written (lerp
# covers all fields; extrapolate copy_froms), keeping the per-tick render path
# allocation-free.
func _lerp_goalie_state(from_s: GoalieNetworkState, to_s: GoalieNetworkState, t: float) -> GoalieNetworkState:
	var r := _scratch_state
	r.position_x = lerpf(from_s.position_x, to_s.position_x, t)
	r.position_z = lerpf(from_s.position_z, to_s.position_z, t)
	r.rotation_y = lerp_angle(from_s.rotation_y, to_s.rotation_y, t)
	# State enum can't lerp — take the freshest so visuals don't lag the host
	# transition by half a bracket. Body / head height lookups depend on this.
	r.state_enum = to_s.state_enum
	r.five_hole_openness = lerpf(from_s.five_hole_openness, to_s.five_hole_openness, t)
	r.velocity_x = lerpf(from_s.velocity_x, to_s.velocity_x, t)
	r.velocity_z = lerpf(from_s.velocity_z, to_s.velocity_z, t)
	r.body_pitch = lerp_angle(from_s.body_pitch, to_s.body_pitch, t)
	r.body_roll = lerp_angle(from_s.body_roll, to_s.body_roll, t)
	r.left_pad_offset = from_s.left_pad_offset.lerp(to_s.left_pad_offset, t)
	r.left_pad_pitch = lerp_angle(from_s.left_pad_pitch, to_s.left_pad_pitch, t)
	r.left_pad_roll = lerp_angle(from_s.left_pad_roll, to_s.left_pad_roll, t)
	r.left_pad_yaw = lerp_angle(from_s.left_pad_yaw, to_s.left_pad_yaw, t)
	r.right_pad_offset = from_s.right_pad_offset.lerp(to_s.right_pad_offset, t)
	r.right_pad_pitch = lerp_angle(from_s.right_pad_pitch, to_s.right_pad_pitch, t)
	r.right_pad_roll = lerp_angle(from_s.right_pad_roll, to_s.right_pad_roll, t)
	r.right_pad_yaw = lerp_angle(from_s.right_pad_yaw, to_s.right_pad_yaw, t)
	r.glove_offset = from_s.glove_offset.lerp(to_s.glove_offset, t)
	r.glove_yaw = lerp_angle(from_s.glove_yaw, to_s.glove_yaw, t)
	r.glove_pitch = lerp_angle(from_s.glove_pitch, to_s.glove_pitch, t)
	r.blocker_offset = from_s.blocker_offset.lerp(to_s.blocker_offset, t)
	r.blocker_yaw = lerp_angle(from_s.blocker_yaw, to_s.blocker_yaw, t)
	r.blocker_pitch = lerp_angle(from_s.blocker_pitch, to_s.blocker_pitch, t)
	r.head_yaw = lerp_angle(from_s.head_yaw, to_s.head_yaw, t)
	return r

func _extrapolate_goalie_state(newest: GoalieNetworkState, dt: float) -> GoalieNetworkState:
	# Pose fields don't have an authoritative angular velocity on the wire, so
	# we hold the newest pose and only dead-reckon root translation via the
	# broadcast linear velocity. Brief gap holds (≤ extrapolation_max_ms) read
	# as a momentary freeze on the body parts — far better than wildly
	# extrapolating arm sweep angles past their intended endpoints.
	var r := _scratch_state
	r.copy_from(newest)
	r.position_x = newest.position_x + newest.velocity_x * dt
	r.position_z = newest.position_z + newest.velocity_z * dt
	return r

func _apply_interpolated(s: GoalieNetworkState) -> void:
	# Track the host's state enum and five-hole openness for any client code
	# that reads them (debug overlays, telemetry). The body / head heights
	# inside apply_network_pose key off s.state_enum directly.
	_sm.current = s.state_enum as State
	_five_hole_openness = s.five_hole_openness
	# Keep the controller-local kinematic mirrors in sync so external readers
	# (e.g. _current_x for the debug HUD) reflect what the client is rendering,
	# not stale spawn defaults.
	_current_x = s.position_x
	goalie.set_goalie_position(s.position_x, s.position_z)
	goalie.set_goalie_rotation_y(s.rotation_y)
	goalie.apply_network_pose(s)

func apply_replay_state(state: GoalieNetworkState, _delta: float) -> void:
	# Replays use the authoritative pose captured in the snapshot, not a
	# client-AI reconstruction. The pose fields (pad/glove/blocker/body
	# offsets and rotations) were broadcast by the host during the original
	# play — applying them directly means playback shows what actually
	# happened, addressing the "replay goalie isn't real" complaint.
	_sm.current = state.state_enum as State
	_five_hole_openness = state.five_hole_openness
	goalie.set_goalie_position(state.position_x, state.position_z)
	goalie.set_goalie_rotation_y(state.rotation_y)
	goalie.apply_network_pose(state)


# ── Helpers ───────────────────────────────────────────────────────────────────
# Defensive-zone test uses raw puck position, not threat — the goalie reacts
# to where the puck physically is for RVH gating, not the blended chest.
func _is_puck_in_defensive_zone() -> bool:
	return GoalieBehaviorRules.is_puck_in_defensive_zone(
			puck.global_position, _goal_line_z, _goal_center_x,
			_direction_sign, _zone_cfg)
