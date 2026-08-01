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
# Depth must sit at real BPS depths, not compressed inward: at these shot speeds a
# slot shot leaves almost no lateral reaction window (~0.04 m of travel in flight),
# so cutting the angle by challenging is what makes the save, not reflexes. The BPS
# "play conservative on a lateral threat" read is handled dynamically by the lateral
# tracking cap + close_crease_butterfly rather than baked into a distance curve.
#
# There is no distance chart: depth is solved from the races (GoalieDepthSolver),
# and `depth_aggressive` is the CEILING on that solve rather than a zone value.
# `depth_base` / `depth_conservative` survive only as rush-backflow anchors and
# tier dials.
@export var depth_aggressive: float = 1.75
@export var depth_base: float = 1.30
# RESTING depth — middle of the blue paint, held while the play has not entered
# the zone. BPS "C". Depth is otherwise solved from the races, but the races only
# describe how far out a THREAT lets him come; a puck still up the ice is not a
# threat, and pure angle geometry would happily park him at the ceiling forever
# (challenging a puck 35 m away buys essentially no coverage, since the net
# subtends almost nothing from there). Real goalies rest in the paint and watch.
# The gate is a real rink landmark rather than a tuned distance — see
# `_threat_is_in_zone`.
@export var depth_conservative: float = 0.70
@export var depth_defensive: float = 0.10
# Minimum gap (m) the goalie keeps between himself and the threat while
# challenging. PHYSICAL, not a feel dial: his torso and pads have real depth, and
# standing level with the puck means the carrier simply walks around a body that
# has already committed forward — plus it puts the puck inside his own poke reach,
# where a whiffed jab leaves the net empty. Replaces the old `zone_post_z` ramp,
# which produced the same in-close pull-back as a hand-authored curve instead of
# as a consequence of the goalie having a body.
@export var challenge_standoff: float = 0.60
@export var zone_post_z: float = 2.0
# How fast `_current_depth` lerps toward the depth-chart target — the
# exponential settle that shapes ARRIVAL near the target. Big moves are
# rate-capped by `depth_max_speed` below, and fast retreats under a genuine
# rush are owned by the rate-matched rush backflow (which this lerp used to
# stand in for — the old 4.0 was chosen to catch a fast-closing skater).
@export var depth_speed: float = 4.0
# Physical ceiling (m/s) on in/out crease movement. Uncapped, the exponential
# lerp opens a 1.3 m challenge→crease change at ~5 m/s — roughly double a real
# goalie's telescoping push / backward C-cut (~2–2.5 m/s), which read as the
# goalie teleporting in and out of the crease. The rush backflow's rate-matched
# retreat deliberately bypasses this cap (it matches the attacker's closing
# speed, the real constraint on a backflow).
@export var depth_max_speed: float = 2.2
# Minimum perpendicular depth (m in front of the goal line) the goalie CENTER
# holds while squared to a shot in front of the net (STANDING / READY /
# RECOVERING / idle BUTTERFLY). The pads are the low-ice blockers, but they and
# the torso have real Z thickness and swing with the goalie's facing, so a
# center parked right on the line lets the rear of the body straddle BEHIND it —
# a puck could finish crossing the goal-line plane (goal at line +
# PUCK_COLLISION_RADIUS) before the pad face ever presented. The arc's own
# near-zero perpendicular depth at sharp angles gets there on its own.
# This floor keeps the whole body — pad face included — in front of that plane
# across facing rotations. It is deliberately NOT applied to the post-integrated
# (RVH/VH), committed-slide (COILING/SLIDING post seal), behind-net
# (PLAYING_PUCK), or planted (COVERING/CATCHING) states, where sitting at/behind
# the line is the correct play (wraps, walkouts, dead-angle post seals).
@export var min_challenge_depth: float = 0.20

@export var shuffle_speed: float = 2.0
@export var t_push_speed: float = GameRules.DEFAULT_GOALIE_T_PUSH_SPEED_M_S
# Lateral push acceleration (m/s²). The goalie ramps up to shuffle / T-push speed
# instead of snapping to it — pushes read like real push-offs, and a quick play
# can beat the goalie across before they reach speed (realism + a scoring window).
# The cross-crease desperation push bypasses this (stays instant). Set very high
# (e.g. 100) to restore the old snap-to-speed behaviour. Default sourced from
# GameRules so AIActionScoring's slide prediction stays in lockstep.
@export var lateral_accel: float = GameRules.DEFAULT_GOALIE_LATERAL_ACCEL_M_S2
@export var lateral_threshold: float = 0.3
@export var max_facing_angle: float = 70.0
# Head tracking (realism audit F9): the head yaws toward the RAW puck in every
# state — "Head Trajectory" doctrine has the eyes/head lead every movement and
# read, and the head/chest divergence (head on the puck while the body plays a
# stable squared target) is itself the realistic look. Applies through the
# reaction freeze (eyes follow the shot), in RVH (looking around the post), and
# while down. Purely cosmetic — no gameplay read keys off the head — and rides
# the existing head_yaw wire field to clients/replays.
@export var head_track_max_yaw_deg: float = 60.0
@export var rotation_speed: float = 5.0
@export var rvh_transition_speed: float = 6.0

# Base leg read after a COLD release (no windup was being read). NOTE on
# grounding (realism audit F15): 0.13 s sits below the measured ~0.18-0.20 s
# elite simple-reaction floor — the gap is deliberate baked-in anticipation for
# playability, and the honest version of that anticipation now exists as the
# pre-armed read (prearmed_reaction_delay, quiet-eye primed). If a literal
# model is ever wanted, raise this toward 0.18 and let the prearm carry the
# fast reads. Difficulty-varied (GoalieSkillProfile.reaction_delay_s) and
# AI-mirrored per tier via AIActionScoring.goalie_leg_delay_s — the default
# and the scorer's default both read GameRules; change together.
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

# ── Pre-armed read (quiet-eye anticipation) ──────────────────────────────────
# A goalie who has been READING a visible windup — the wrister's frozen-puck coil
# or a slapper charge — from a slot shooter (_is_reading_shot_threat) for
# `prearm_read_time` has the
# save response pre-programmed during the fixation, so on release both the leg
# and arm reads start from `prearmed_reaction_delay` instead of the cold-read
# baseline. GROUNDED (audit F2/F15): quiet-eye research (Panchuk & Vickers) has
# the save prepared during a ~1 s fixation and executed ballistically in
# <200 ms, and Clear Sight Analytics' set-and-sighted threshold is ~0.5 s of
# clear read before release (~97% save when met). Screens and caught-moving
# penalties still ADD on top, so only a set, sighted goalie collects the credit
# — and a quick-release snap FROM RANGE (no windup state, nothing to fixate)
# never earns the windup prime, which is exactly the real "quick release beats
# the read" edge. The prime lingers `prearm_linger` past the read so the release
# event can't race the flag off on the same tick the windup state clears.
#
# SLOT PROXIMITY PRIME (`prime_slot_distance`): a set, upright goalie with an
# opposing carrier already in tight is coiled and pre-programmed to react even
# WITHOUT a held windup — a real slot goalie is never a frozen statue on a quick
# release. So an in-front carrier inside `prime_slot_distance` arms the same prime
# by proximity. This is not a "save it anyway" buff: it only makes both limbs
# START moving (the cold arm read of 0.18 s exceeds a slot shot's ~0.10-0.16 s
# flight, so uncredited the goalie never moves at all). The flat reach-speed cap
# (`glove_react_max_speed`) still bounds how much net he covers in the time left,
# so a corner picked out of that reach beats him — the intended "pick a corner,
# don't face a statue" in-tight window. Distance is grounded at the zone where a
# cold arm read outlasts the shot's flight (flight < 0.18 s ⇒ under ~5-6 m for
# 25-30 m/s releases), so it targets exactly the freeze zone and no farther.
# ── Read staleness (the goalie can be WRONG) ─────────────────────────────────
# Every other latency here answers "when does he start moving"; this one answers
# "does he know where the puck is going". His committed belief about the shot's
# destination is the aim he read `read_lag` seconds ago — the shooter's published
# `predicted_shot_velocity`, sampled stale — and it converges onto the true line
# over the same window once the puck is in flight and he can actually see it.
#
# NOT RNG, and deliberately so (both teams field identical goalies and it must
# read that way): the error is a pure deterministic function of what the SHOOTER
# did with their aim. A stable aim through the wind-up means the stale sample
# EQUALS the truth, so a telegraphed shot is read exactly as well as before. A
# late swing against the grain is the only thing that beats it, by exactly the
# amount the shooter moved the aim. Repeatable, symmetric, attributable.
#
# What falls out, with no extra authoring: a long shot converges before it
# arrives (read correctly); an in-tight one does not (beaten); a screen costs
# ACCURACY as well as tempo, because there is nothing to converge WITH while the
# puck is hidden; and a deflection resets the read, so a tip in tight beats him
# while a tip from distance does not.
#
# Zero disables it entirely (belief == truth, exactly the pre-R1 goalie).
# Difficulty-varied via GoalieSkillProfile.read_lag_s.
@export var read_lag: float = 0.13
# How long it takes him to CORRECT a wrong belief once the puck is in flight and
# he can watch it. Split out of `read_lag`, which used to set both — see
# GoalieSkillProfile.read_converge_s for why they are different quantities.
@export var read_converge_time: float = 0.13
@export var prearmed_reaction_delay: float = 0.07
@export var prearm_read_time: float = 0.40
@export var prearm_linger: float = 0.25
@export var prime_slot_distance: float = 6.0

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
# A goalie is only sharp when SET — square and stopped. Being unset costs him
# three things, and only the third is perceptual:
#
#   1. MOMENTUM he cannot cancel. `unset_drift_decel_ratio` below.
#   2. AN OPEN TRAIL LEG. A butterfly entered with lateral speed splays like a
#      slide's does (_update_butterfly_five_hole), so the five-hole is live for
#      exactly as long as he is still travelling.
#   3. A beat of extra read latency, `move_read_speed_delay` — the residual an
#      off-balance body pays firing a response it has already chosen. Small on
#      purpose; see GoalieBehaviorRules.movement_read_penalty for why loading the
#      whole cost of being unset onto latency is the wrong model.
#
# The point of (1) and (2) is that the cost is DIRECTIONAL and readable, which
# latency never was: shoot against his motion and he cannot get back, shoot with
# it and he over-slides. Both are counter-playable, and neither makes a set
# goalie any harder to beat.
#
# SCRAMBLING IS PRICED SEPARATELY (`move_read_scramble_delay`, difficulty-varied)
# and stays large. Standing up out of a butterfly or riding a committed lunge has
# no lateral momentum for (1) to carry, so the drift cannot model it — and the
# failure there is that the response is not AVAILABLE yet, not that it starts
# late. That is a real latency, and it is the one a rebound converts on.
@export var move_read_speed_delay: float = 0.04    # s — read latency when moving on his feet
@export var move_read_scramble_delay: float = 0.12 # s — read latency while recovering / mid-lunge
@export var move_read_reference_speed: float = 2.5 # m/s — planar speed counted as fully moving
# Unset fraction (0..1) at or below which the goalie still counts as SET for the
# quiet-eye prime (_is_set_in_slot). 0.25 of the reference speed ≈ 0.6 m/s — a
# settling shuffle, not a push. Above it he is moving and does not collect the
# primed read.
@export var set_unset_max: float = 0.25
# Deceleration available to kill lateral momentum during the reaction freeze,
# as a fraction of `lateral_accel` (the accel he gets from a LOADED edge). Below
# 1.0 because stopping is the harder half: a goalie caught mid-push has weight on
# an unloaded leg and no edge to bite with until it re-plants. At 0.7 × 14 m/s²
# a full 3.8 m/s T-push carries ~0.4 m past the commit point and takes ~0.4 s to
# kill — the "he slid past the post" goal. Tier-varies for free off lateral_accel:
# worse edges (Easy, 6 m/s²) drift further, which is correct.
@export var unset_drift_decel_ratio: float = 0.7

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
# How far INBOARD of the post the post-seal spot sits. Shared by the VH/RVH
# stance position and by the arc solver's sharp-angle convergence target, so the
# squared stance hands off to post integration at the same place rather than
# teleporting. (= outer pad reach 0.88 - 0.50 body inset toward post.)
@export var post_seal_inset: float = 0.38
@export var rvh_early_angle: float = 80.0
@export var rvh_post_pad_angle: float = 15.0

@export var five_hole_base: float = 0.02
@export var five_hole_shuffle_max: float = 0.04
@export var five_hole_t_push_max: float = 0.10

@export var tracking_speed: float = 8.0
# Far-range tracking lerp speed — the quiet-eye lag (realism audit F1). At range
# a real goalie's angle corrections are smooth and slightly laggy; slowing the
# tracking lerp low-passes stickhandle wiggle (±1.5 m at ~2 Hz attenuates to
# roughly ±0.35 m of threat motion — ≈±0.06 m of goalie arc travel at B depth)
# without moving the squaring target off the puck. Blended from `tracking_speed`
# (in tight) toward this by the chest_track distance ramp.
@export var tracking_speed_far: float = 3.0
@export var part_lerp_speed: float = 6.0
@export var reaction_lerp_speed: float = 18.0
# Recovery rises body parts from butterfly pose → READY pose. Default tuned
# so the rise is ~95% complete by `recovery_duration = 0.35 s` (lerp speed
# ≈ 3 / duration). Was 3.0 which only converged ~65% — body still looked
# half-butterfly when recovery ended.
@export var recovery_lerp_speed: float = 9.0

# ── Threat tracking ───────────────────────────────────────────────────────────
# Square to the PUCK. Real doctrine is unanimous (realism audit F1): a goalie
# sets his angle off the puck at every range — "chin lined up with the shooter's
# body" is the canonical coached ERROR, and quiet-eye research puts elite gaze on
# the puck and stick blade, not the torso. The shooter's body is an anticipation
# CUE (pre-lean, slapper tell), never the squaring target. A small body weight
# survives only in tight — where the puck-to-body offset subtends a huge angle
# and a dash of body bias keeps committed-drive reads stable — and it fades OUT
# with distance (the real error gradient: at range the offset angle is tiny, so
# puck-tracking costs almost nothing in jitter and buys correct angles).
# Stickhandle jitter is absorbed TEMPORALLY instead: the tracking lerp slows
# with distance (`tracking_speed_far` — the quiet-eye lag), low-passing the
# dangle wiggle without moving the goalie's set point off the puck.
# ONE VALUE, and it is deliberately flat. Measured, this weight moves the goalie
# only a few CENTIMETRES: for a carrier with the puck 0.6 m to the side, the
# entire span from w=0 to w=0.30 is ~10 cm at 3 m, ~5 cm at 6 m and ~3 cm at 9 m,
# because his lateral target is an arc position that is damped and geometrically
# compressed, not a raw lerp. Splitting it by stance or fading it with distance
# buys ~1 cm against a 3.8 cm puck and a 1.83 m net — and the angular argument for
# a distance fade cancels anyway, since jitter and offset both scale with
# 1/distance, leaving the ratio unchanged with range.
@export var shooter_weight: float = 0.20
# PINNED-WINDUP override — applies to BOTH shot wind-ups
# (SkaterStateMachine.state_pins_puck). While a carrier winds one up the puck is
# rigidly pinned to the body and does NOT jitter: the slapper pins it at a fixed
# lateral offset to the blade side (Skater.enter_slapshot_pinning,
# ~slapper_zone_offset_x = 1 m), and the wrister freezes the blade at its
# body-local pose, so in both cases the puck sits rock-steady relative to the body
# and IS the honest shot origin the release fires from. The body-weight bias above
# only exists to reject stickhandle jitter, which is absent here, so it biases the
# goalie off the puck toward the shooter's chest for no benefit. Track the pinned
# puck itself (weight -> 0): it IS the shot origin the release fires from.
#
# The only surviving exception, and it is a ZERO rather than a different weight.
# MAGNITUDE: worth ~3.5 cm of squaring at 3 m on a 1 m pin — the arc solve
# compresses lateral target changes, so do not reach for this lever expecting it to
# move him far. (A naive reading of the geometry suggests ~offset*(1-w) ≈ 25 cm;
# that is wrong.) It is kept because it is free — a pinned puck has no jitter to
# reject, so the bias has no job — and because it is the one case with a reported
# exploit behind it: skate up square and rip one past the goalie's side.
@export var shooter_weight_pinned_windup: float = 0.0
# Slapper aim shade (anticipatory read): squaring to the pinned puck alone leaves
# the against-the-grain corner of a committed slot slapshot open by ~1 m — the
# goalie holds its set angle and a corner shot goes past its side (the "Colin
# cheese"). A real goalie reads the shot's side off the LOCKED wind-up and cheats
# his angle that way. This shades the goalie's lateral target toward where the shot
# will cross his depth plane (from the published predicted velocity), ramped by how
# long he's read the wind-up (prearm_read_time) so a quick release gets little shade
# — the skill window survives — while a lazy full wind-up to an open corner gets cut
# off. Directional, so a faked aim shades him the WRONG way (counter-readable, not a
# flat buff). Kept below 1.0 so a well-placed, quick corner release can still beat
# him (beatable realism). See _move_along_arc.
#
# DELIBERATELY SLAPPER-ONLY (`_reading_planted_windup`), unlike the squaring
# override above which covers both wind-ups. The shade is a POSITIONAL commit —
# the body physically moves toward a predicted crossing — so it is only safe
# against a shooter who can't relocate the shot origin. The slapper plants
# (locomotion suppressed + an active velocity drag); the wrister suppresses no
# locomotion, so a wrister shooter can simply skate out from under a shade and
# finish against the grain, making a mis-aimed shade worse than none. Extending it
# needs a second bound — min(what the goalie can reach, what the shooter can still
# invalidate) — which is tracked separately in
# docs/goalie-grounding-refactor-plan.md §1.4. The TEMPORAL read credit (the
# quiet-eye prearm) has no such restriction and already covers both wind-ups via
# _is_reading_shot_threat: readiness to move is direction-agnostic, so relocating
# doesn't invalidate it.
@export_range(0.0, 1.0, 0.05) var slapper_aim_shade: float = 0.7
# Distance ramp for the puck-lead fade and the tracking-lag scale. Between
# `chest_track_near_distance` and `chest_track_far_distance` the jittery
# puck-velocity lead fades to zero and the tracking lerp slows toward
# `tracking_speed_far`. Distances are Euclidean carrier→goal-center. (It no
# longer ramps the body bias — see `shooter_weight`, now one flat value.)
@export var chest_track_near_distance: float = 2.5
@export var chest_track_far_distance: float = 7.0
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

# ── Rush retreat (speed-matched backflow) ────────────────────────────────────
# Against a CLOSING opposing carrier inside `rush_engage_distance`, depth follows
# the taught backflow curve instead of the chart's flat aggressive zone: back at
# crease-top depth by the hash marks (`rush_mid_distance` → depth_base), at
# goal-line depth as the attacker reaches the crease (`rush_arrive_distance` →
# depth_defensive), retreating at a rate MATCHED to the attacker's closing speed
# (GoalieBehaviorRules.rush_retreat_rate) so the challenge gap is a modeled read
# rather than lerp lag (realism audit F5 — holding full aggressive depth and
# relying on the depth lerp to catch a rush makes the gap an artifact of
# smoothing convergence). A slow walk-in
# below `rush_min_closing_speed` keeps the challenge (stay out, force the
# release — the taught read against a controlled carrier); a rush that stalls
# lets the chart re-challenge. The real counter-dynamics fall out: decelerating
# strands the goalie out at challenge depth (more net to shoot at — the taught
# breakaway trade), while a speed rush arrives on a goalie already at depth.
@export var rush_engage_distance: float = 8.0
@export var rush_mid_distance: float = 4.5
@export var rush_arrive_distance: float = 1.5
@export var rush_min_closing_speed: float = 1.5

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
@export var backdoor_assumed_pass_speed: float = GameRules.DEFAULT_QUICK_PASS_POWER_M_S
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
# The speed bar is a genuine DRIVE: brisk walking pace is ~1.5 m/s, and an
# in-tight dangle routinely swings the body through it — reading that as
# "beaten to the post" sold the goalie on the first move of every deke.
@export var beaten_wide_min_lateral_speed: float = 2.5   # m/s — a drive, not a lateral shuffle
@export var beaten_wide_max_threat_distance: float = 4.0 # m — in-tight gate (threat→goal)
# Quiet-eye confirmation on CARRIER-driven lateral commits (the standing
# beaten-wide drop and the butterfly pad-coverage slide): the verdict must
# hold continuously this long before the goalie sells out. A genuine drive to
# the post sustains it; a deke's transient lateral spike breaks it and the
# timer resets — pulling the puck back visibly un-commits him. Grounded in
# the quiet-eye fixation (~100–300 ms of trajectory confirmation before an
# elite goalie commits; the audit's anticipation research). PASS-driven
# commits stay instant by design — a puck in flight cannot cut back, so the
# cross-crease one-timer seal keeps its zero-hesitation commit.
@export var lateral_commit_confirm_s: float = 0.15

# "An opposing stick is on this puck" — a poke-range radius, used by the cover
# read to tell a loose puck he can safely sweep from one he has to smother.
# (Was `puck_contest_radius`, shared with the crease-jam butterfly trigger;
# that trigger is now GoalieSaveSelection's time race and this is its only
# remaining reader.)
@export var puck_contest_radius: float = 1.5 # m

# ── Butterfly commitment ─────────────────────────────────────────────────────
# Once the goalie drops they cannot stand-skate. Lateral movement is via
# committed butterfly slides only. They cannot reach RVH directly — must
# stand up first (RECOVERING window).
@export var butterfly_min_hold_time: float = 0.35   # s the goalie must stay down
@export var recovery_duration: float = 0.35         # s spent standing back up
# Pads-to-floor time. GROUNDED (realism audit F2): motion capture of a pro
# goalie measures butterfly drop velocity at 2.07 ± 0.09 m/s (Brock Univ.,
# Sports 10(6):96) — over the ~0.4 m the pads/hips fall, the ice seal lands
# ~0.2 s after commitment. The old 0.05 snap was ~5× faster than a real drop
# and made the five-hole close near-instantly once the leg read elapsed. The
# gap also closes CONTINUOUSLY through the drop (openness converges during
# drop_progress), so the effective five-hole seal — gap narrower than the puck
# — lands well before full completion. Difficulty-varied (GoalieSkillProfile.
# butterfly_drop_s) and AI-mirrored per tier via AIActionScoring.goalie_
# butterfly_drop_s; this default mirrors the scorer's GOALIE_BUTTERFLY_DROP_S
# baseline — change both together.
@export var butterfly_drop_speed: float = 0.20      # s for pads to close to floor
@export var butterfly_radius: float = 0.40          # arc radius from goal center while down
# Knee shuffle (realism audit F6) — the smallest down-movement tier. Real down
# movement is three-tier: knee shuffle (10–40 cm squared micro-scoots, constant
# in scrambles — the "butterfly crawl"), backside push, and the full committed
# slide. Idle BUTTERFLY tracks the arc target at this slow pace with the seal
# held, so post-save re-centering and scramble adjustments no longer leave the
# goalie a statue between slides; genuine cross-crease coverage still requires
# the committed slide (the pad-edge trigger is untouched). Suppressed while
# reacting (set, reading the shot — same freeze as the upright mover).
@export var knee_shuffle_speed: float = 0.7          # m/s — micro-scoot pace while sealed

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
# Lunge: the blocker assembly briefly extends forward — the stick blade jabs at
# the puck. Brief active window with a cooldown so the goalie can't spam-stick
# into every carrier. Mechanically a quick forward push on c.blocker_pos.z,
# sin-curved over the active window.
#
# WHEN it fires is not a distance. `lunge_extension` IS the trigger geometry: he
# jabs only when the blade cannot reach the puck from where it is and can if it
# extends by this much (GoalieStickRules.lunge_is_the_only_reach). A plain
# goalie-to-puck distance trigger fires while the blade is already inside
# `goalie_poke_radius`, paying the fully-unset read penalty for a jab he does not
# need.
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
# ── Cover / freeze (smother) ──────────────────────────────────────────────────
# The real loose-puck hierarchy is: cover under pressure, sweep when there's
# time to play it, leave it only with clear teammate possession (USA Hockey
# "Controlling Rebounds"). The sweep is only the correct clear when a corner
# exit lane is OPEN — so the cover triggers exactly when the lane model says
# every sweep would feed an opponent's stick AND an opponent is on the puck.
# The smother is a race: the glove takes `cover_reach_time` to land, and until
# it does the puck is still live (a whack that moves it aborts the cover into
# a RECOVERING scramble — the gamble). Once secured the puck is dead
# (pickup_locked); resolution is ruleset-split by GameManager via the
# `puck_covered` signal: NHL whistles a defensive-zone faceoff; ARCADE (and
# OFF / free play) runs the flow-preserving hold-and-release — the goalie
# holds `cover_hold_s` (the scramble dies, the defense resets) then plays it
# out himself through the same lane-aware sweep. `cover_cooldown_s` keeps the
# smother a scramble-killer, not a spammable wall.
@export var cover_reach_time: float = 0.35      # s — glove-to-puck smother race window
@export var cover_secure_radius: float = 0.55   # m — puck must still be this close when the glove lands
@export var cover_hold_s: float = 0.85          # s — ARCADE hold before the live release
@export var cover_cooldown_s: float = 7.0       # s — between covers (success or failed gamble)
# A puck at rest ON the goalie's body — a deadened save settling on top of the
# butterfly pads. The goalie is the only body that can support a puck off the
# ice (the puck mask excludes skaters), and a pad-shelf puck is unplayable
# through every normal path (grounded blades can't reach an "airborne" puck;
# the crease sweep refuses pucks above `clear_max_height`) — in real hockey
# it's a covered puck anyway, so it triggers the same smother, bypassing the
# cover cooldown (there is no other resolution). Detection is the pure
# GoalieBehaviorRules.puck_resting_on_goalie window held for a dwell.
@export var cover_body_rest_dwell_s: float = 0.3      # s — must SIT there, not bounce through
@export var cover_body_rest_max_height: float = 0.6   # m — pad/lap shelf envelope the glove can pin
@export var cover_body_radius: float = 0.7            # m — butterfly's horizontal span
@export var cover_escape_height: float = 0.9          # m — above the collapsed torso = out of the smother

# ── Catch-and-hold (glove) ────────────────────────────────────────────────────
# A controlled GLOVE save is a CATCH: the puck pins into the glove (squeeze-
# and-look) instead of dropping dead at the feet. Resolution mirrors the real
# rule's incentive structure: held UNDER PRESSURE (opponent bearing down) it
# freezes the play — same `puck_covered` rails as the smother (NHL whistles a
# defensive-zone faceoff; ARCADE holds `cover_hold_s` then plays on) — while an
# UNPRESSURED catch quick-drops after a beat and plays the puck (the real
# delay-of-game incentive: you don't freeze it with nobody on you). The drop
# places the puck at the goalie's feet, where the existing dwell → lane-aware
# windup-strike clear takes over naturally.
@export var catch_hold_pressure_radius: float = 2.5  # m — opponent inside this → hold/freeze
@export var catch_quick_drop_s: float = 0.4           # s — unpressured look-and-drop beat

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
# Windup: the clear is now windup → STRIKE → follow-through. The decision
# starts a short backswing (blade cocks away from the send corner); the clear
# VELOCITY applies only at the strike moment, when the blade snaps through the
# puck — so the stick is visibly what clears it, instead of the puck departing
# by itself with a trailing cosmetic wave. During the windup the puck is still
# live: if it gets whacked away or picked up first, the strike whiffs (the
# follow-through still plays — an honest missed sweep).
@export var sweep_windup_s: float = 0.12            # s — backswing before the strike
@export var sweep_windup_x_extension: float = 0.12  # m — cock away from the send corner at peak
@export var sweep_windup_z_pull: float = 0.06       # m — pull back toward the body at peak
@export var sweep_windup_max_yaw_deg: float = 25.0  # blade yaw away from the send side at peak

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
# Goalies read it: hands come up (pose tell) and the read PRIMES (pre-armed
# reaction — see prearm_read_time). The taught response to a clean windup is
# GET SET — square, stopped, at depth — not retreat (audit F13: backing in
# concedes angle exactly when the goalie has his best look; a windup is MORE
# read time, which is why slapshots convert lower than snap shots). Being set
# emerges naturally: the charging carrier glides, so the arc target goes
# stationary and the movement converges — no depth concession is applied.
# Screened windups are handled by the blocking drop, not by depth.

# ── Shot anticipation (pre-lean) ──────────────────────────────────────────────
# A charging shot has a visible windup. The goalie reads it and pre-leans toward
# where the shot is *currently* aimed (predicted via the carrier's published
# `predicted_shot_velocity`), so a clean shot into the top corner has a shorter
# arm trip on release. Crucially the lean tracks the LIVE aim every tick — a
# player who sweeps the cursor one way then swings it back before release moves
# the real impact off the lean, so a tricky release still beats the goalie (read vs
# counter-read, not a flat buff). The lean is PARTIAL (`prelean_strength` of the
# way to the predicted reach) and never adds save speed — it only changes the
# resting hand position, so the arm-delay / glove-speed caps on the actual
# reaction still hold. Directional pre-lean needs the shooter's live predicted
# velocity, which SkaterController publishes every charge tick for BOTH shot types
# and EVERY shooter — host player, bot, and remote (the host simulates a remote's
# carry from replicated input, and the wrister's origin→cursor aim rides the wire
# as the replicated cursor). The non-directional "hands up, ready" tell is the fallback only
# when the current aim isn't at the net, not a remote-shooter limitation. Host-only
# like all goalie AI — the lean rides the broadcast glove/blocker pose to clients.
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

# ── Behind-net puck play (tier-1 conservative rim stop) ──────────────────────
# Tuning for the trip. Doctrine and the GO race's conservatism are in
# Scripts/controllers/CLAUDE.md; the race itself is
# GoalieBehaviorRules.puck_play_race_clear, driven by GoaliePuckPlay.
@export var puck_play_skate_speed: float = 4.2      # m/s — goalies skate slower than skaters
@export var puck_play_skate_accel: float = 8.0      # m/s² — out/back push ramp
@export var puck_play_go_margin: float = 0.9        # s — surplus required to GO (INF = never)
@export var puck_play_abort_margin: float = 0.45    # s — mid-trip floor; below it, bail (hysteresis)
@export var puck_play_stop_beat: float = 0.25       # s — settle the trap before turning back
@export var puck_play_set_beat: float = 0.15        # s — must beat the rim to the spot by this
@export var puck_play_capture_radius: float = 1.0   # m — paddle trap reach at the stop point
@export var puck_play_min_puck_speed: float = 4.0   # m/s — slower pucks don't need a stop
@export var puck_play_max_puck_speed: float = 22.0  # m/s — faster rims are shots/clears, stay home
@export var puck_play_opponent_speed: float = 11.0  # m/s — assume full sprint (conservative bound)
@export var puck_play_net_front_exclusion: float = 3.0 # m — opponent near the net front vetoes the trip
@export var puck_play_cooldown_s: float = 4.0       # s — between trips (no dithering at the post)
@export var puck_play_boards_inset: float = 0.7     # m — stop point this far inside the end boards
@export var puck_play_post_clearance: float = 0.55  # m — waypoint this far outside the post
# Skating-stride cadence for the trip (rad of stride phase per METER traveled —
# distance-driven so the feet never treadmill; a full two-push cycle every
# ~2.6 m at 2.4). The stride itself is the skater gait's idiom reduced to the
# pad rig (GoalieBodyConfigBuilder._apply_puck_play_stride) and only plays on
# the behind-net skate — crease movement (shuffle / T-push) is correctly a
# glide, which is why the goalie never strides in the crease.
@export var puck_play_stride_cadence: float = 2.4

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
# Goal-line hysteresis for the RVH ↔ VH stance-family swap (realism audit F14).
# VH is the post stance for a sharp-angle SHOT threat still in FRONT of the
# goal line — post pad vertical, keeping short-side-high coverage (Jake Allen /
# Woll: "VH for a shot threat with distance, RVH at/below the goal line").
# RVH's documented weakness is exactly short-side high, so defaulting to it for
# in-front sharp angles concedes the top of the net. The puck must cross the
# goal line by this much before the family switches, so a puck dribbling along
# the line doesn't flicker the stance.
@export var post_stance_swap_deadband_m: float = 0.15

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
# Reach height ABOVE THE CHEST ANCHOR — the posture cost of being down. Each
# pose authors a `body_pos.y` (READY 1.06, STANDING 1.22, BUTTERFLY 0.40), and
# the hand ceiling is that plus this, capped by `react_hand_y_max`. DERIVED, not
# chosen: 1.06 + 0.49 = 1.55, the flat ceiling this replaced, so upright reach is
# bit-identical and only the down postures give anything up. See
# GoalieBodyConfigBuilder._reachable_hand_y.
@export var arm_reach_above_chest: float = 0.49
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
# — hence 5.0, well below the 7-10 peak. Setting it much lower leaves the glove
# unable to reach corners it should on mid/long shots. Close top-corner snipes still beat
# the ARM DELAY (arm_reaction_delay 0.18 s > a slot shot's flight), so this only
# shuts the range shots a real goalie gloves — it doesn't touch the in-tight window.
# NOTE: AIActionScoring mirrors this as the arm deploy ramp (goalie_arm_deploy_s
# = HIGH-band EXT / speed; baseline const GOALIE_ARM_DEPLOY_S, re-derived per
# tier in set_goalie_profile) — change the baselines together.
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

# Host-side: the goalie has secured (smothered) a loose puck. GameManager
# resolves it by ruleset — NHL whistles a defensive-zone faceoff; ARCADE / OFF
# do nothing (the controller's own hold-and-release timer plays it out).
signal puck_covered(covering_team_id: int)

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
#   _puck_play — GoaliePuckPlay (behind-net rim-stop trip: decision, geometry, phase)
var _puck_play: GoaliePuckPlay = GoaliePuckPlay.new()
#   _clear     — GoalieCreaseClear   (sweep / cover / catch decisions + timers)
var _clear: GoalieCreaseClear = GoalieCreaseClear.new()
#   _view      — GoalieWorldView     (ONE per-tick skater scan, shared by every read)
var _view: GoalieWorldView = GoalieWorldView.new()
# Reused depth-constraint scratch — refilled in place each tick (hot path).
var _depth_constraints := GoalieDepthSolver.Constraints.new()

# ── Cached rule configs (built once in setup) ────────────────────────────────
var _shot_cfg: GoalieBehaviorRules.ShotDetectionConfig
# Speed-floor-free variant of _shot_cfg for the universal-reaction path (slow
# tricklers / board bounces must classify even below shot_speed_threshold).
var _universal_shot_cfg: GoalieBehaviorRules.ShotDetectionConfig
var _zone_cfg: GoalieBehaviorRules.DefensiveZoneConfig
var _arc_cfg: GoalieBehaviorRules.ArcConfig
var _universal_reaction_cfg: GoalieBehaviorRules.UniversalReactionConfig
var _screen_cfg: GoalieBehaviorRules.ScreenConfig
var _move_read_cfg: GoalieBehaviorRules.MovementReadConfig
var _beaten_wide_cfg: GoalieBehaviorRules.BeatenWideConfig
var _backdoor_cfg: GoalieBehaviorRules.BackdoorThreatConfig
var _rush_cfg: GoalieBehaviorRules.RushRetreatConfig
var _sweep_lane_cfg: GoalieBehaviorRules.SweepLaneConfig

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
# Signed lateral velocity (m/s) carried INTO the reaction freeze, captured from
# `_velocity_x` the tick the read commits and bled off at the unset drift decel.
# Lateral only: depth is a committed, chart-driven quantity and east-west
# momentum is the whole of the caught-moving story.
var _reaction_drift_vx: float = 0.0
# Wall-clock of the last puck contact on this goalie, for the shot log's
# second-chance discriminator. Analytics only — nothing in the tick reads it, so
# it stays off the replay-determinism surface.
var _last_save_time: float = -1.0
var _five_hole_openness: float = 0.0
var _tracked_threat_position: Vector3 = Vector3.ZERO
# Position-derived puck velocity, for intercept math during elevated shots.
# Works on both host and client (linear_velocity is unreliable on the client
# during interpolation). Updated each tick from the puck position delta.
var _puck_velocity_est: Vector3 = Vector3.ZERO
var _prev_puck_position: Vector3 = Vector3.ZERO
# Windup reads, split by what they license. `_reading_pinned_windup` is true for
# EITHER wind-up (SkaterStateMachine.state_pins_puck) — the puck is rigidly pinned
# to the body, so the goalie squares to the pinned puck and must not add a puck
# lead on top of the carrier lead (they'd be the same motion twice).
# `_reading_planted_windup` is the strict subset where the shooter is ALSO planted
# (slapper only — locomotion suppressed + velocity dragged to zero), which is what
# makes the positional aim shade a safe bet; see the slapper_aim_shade doc-block.
var _reading_pinned_windup: bool = false
var _reading_planted_windup: bool = false
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
# Pre-armed read state (quiet-eye anticipation): `_shot_read_timer` accumulates
# while the goalie is continuously reading a windup; once it crosses
# `prearm_read_time`, `_prime_linger_timer` holds the primed flag briefly so the
# release itself (which clears the windup state) can't race it off.
var _shot_read_timer: float = 0.0
var _prime_linger_timer: float = 0.0
# ── Read staleness (see the read_lag export) ─────────────────────────────────
# Ring of the shooter's published aim, one entry per host tick while the goalie
# is reading a wind-up. `_lagged_aim` reads `read_lag` seconds back — the belief
# he commits to at release. Fixed capacity, written in place: no per-tick alloc.
const _AIM_HISTORY_CAP: int = 64
var _aim_history: PackedVector3Array = PackedVector3Array()
var _aim_history_idx: int = 0
var _aim_history_len: int = 0
# The impact point the goalie BELIEVES at release, and how far he has converged
# onto the true one (0 = fully on the stale read, 1 = caught up). `_read_hold`
# freezes the convergence while the puck is hidden behind a screen — you cannot
# refine a read you cannot see. `_read_last_vel` detects a mid-flight trajectory
# change (a tip) so the read can be reset to what he was committed to.
var _read_belief_x: float = 0.0
var _read_belief_y: float = 0.0
var _read_blend: float = 1.0
var _read_hold: float = 0.0
# The initial ballistic commitment has been made (the first reach deployed), so
# the read is now being refined from live observation. One-shot: a LATE
# re-classification re-arms the arm timer, and that must not re-freeze the
# convergence — he is watching the puck the whole way, not restarting his read.
var _read_committed: bool = false
var _read_last_vel: Vector3 = Vector3.ZERO
# Blocking-drop timer for fully-screened releases (audit F4): >= 0 counts down
# from the base leg read; on expiry the goalie commits the blocking butterfly
# without waiting to SEE the puck. -1 = inactive.
var _screen_block_drop_timer: float = -1.0
# Chest-blend ramp (0 in tight → 1 at range) from the last threat computation;
# consumed by the tracking lerp to scale the quiet-eye lag with distance.
var _chest_t: float = 0.0
# Cover / smother state. `_clear.cover_secured` flips when the glove lands with the
# puck still in the secure radius; the reach timer runs the smother race, the
# hold timer runs the ARCADE hold-and-release, and the cooldown spaces covers.
# Quiet-eye confirmation accumulators for the two carrier-driven lateral
# commits (see lateral_commit_confirm_s). Reset whenever their read breaks.
var _beaten_wide_confirm_timer: float = 0.0
var _slide_coverage_confirm_timer: float = 0.0
# Catch-and-hold state. `_clear.catch_secured` flips once the pin (freeze + lock) is
# applied on the first catching tick — physics writes are deferred out of the
# contact callback the catch signal fires from. `_clear.catch_pressured` picks the
# hold length and whether the freeze resolution (puck_covered) fires.
# Lunge state: active timer counts down while the blocker is extended;
# cooldown timer counts down after each lunge before another can fire.
var _lunge_active_timer: float = 0.0
var _lunge_cooldown_timer: float = 0.0
# Loose-puck sweep cooldown — counts down after each crease clear so the goalie
# sweeps once and lets the puck travel instead of dribbling it tick-by-tick.
# Counts up while a loose puck sits clearable in front of the goalie; the sweep
# only fires once it crosses `clear_dwell`. Resets the moment the puck leaves
# the clearable window so the goalie doesn't bat live/airborne pucks on contact.
# Clear-sweep phases. `_clear.windup_timer` counts down the backswing; when it
# expires _strike_pending_sweep applies the clear velocity (the strike moment —
# the stick is what clears the puck) and starts `_clear.anim_timer`, the
# follow-through swing. `_clear.anim_dir` is the goalie-local lateral sign of
# the send. `_clear.pending_cover_release` marks a windup begun from the
# COVERING hold: its strike also unlocks the pinned puck and stands the goalie
# up through RECOVERING.
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
# Reused per-tick Situation for the block-or-react decision (hot path: this runs
# every tick for both goalies and again per replayed input in reconcile).
var _save_situation := GoalieSaveSelection.Situation.new()
# Scratch for the read-belief solve at release (see _seed_read_belief).
var _scratch_belief := GoalieBehaviorRules.ShotResult.new()
# Mid-flight velocity change (m/s) that counts as a REDIRECT rather than the
# analytic step's own drag/bounce jitter — a blade tip changes the line by far
# more than a tick of friction does.
const _DEFLECTION_DELTA_M_S: float = 3.0
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
		puck.puck_caught_by_goalie.connect(_on_puck_caught)
		# Resolving events that end the reaction freeze. Each fires only on
		# a loose puck (already gated inside Puck) and starts the clear timer.
		puck.puck_hit_boards.connect(_on_reaction_resolved)
		puck.puck_touched_post.connect(_on_reaction_resolved)
		puck.puck_hit_goal_body.connect(_on_reaction_resolved)

# Overwrite the difficulty-varying @exports from a skill profile. Only the knobs
# the profile carries are touched; everything else keeps its authored default.
# The AI-mirrored reads (leg delay, drop time, lateral accel, arm deploy) are
# kept honest per tier by AIActionScoring.set_goalie_profile, called where
# GameManager selects the match's goalie_skill_profile — t_push_speed is the one
# read knob still fixed across tiers (see GoalieSkillProfile → AI MIRROR).
# Called from setup() before the cached configs are built.
func _apply_skill_profile(profile: GoalieSkillProfile) -> void:
	arm_reaction_delay = profile.arm_reaction_delay_s
	cross_crease_react_delay = profile.cross_crease_react_delay_s
	goalie_poke_radius = profile.poke_radius_m
	screen_max_extra_delay = profile.screen_max_extra_delay_s
	move_read_scramble_delay = profile.move_read_scramble_delay_s
	depth_aggressive = profile.depth_aggressive_m
	depth_base = profile.depth_base_m
	glove_react_max_speed = profile.glove_react_max_speed_mps
	blocker_react_max_speed = profile.blocker_react_max_speed_mps
	pad_toe_out_butterfly_deg = profile.pad_toe_out_butterfly_deg
	lateral_accel = profile.lateral_accel_mps2
	puck_play_go_margin = profile.puck_play_go_margin_s
	reaction_delay = profile.reaction_delay_s
	prearmed_reaction_delay = profile.prearmed_reaction_delay_s
	read_lag = profile.read_lag_s
	read_converge_time = profile.read_converge_s
	butterfly_drop_speed = profile.butterfly_drop_s
	five_hole_base = profile.five_hole_base_m


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
	_pose_inputs.reading_pinned_windup = false
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
	_pose_inputs.sweep_windup_progress = 0.0
	_pose_inputs.paddle_sweep_active = false
	_pose_inputs.standing_sweep_active = false
	_pose_inputs.head_yaw_deg = 0.0
	_pose_inputs.puck_play_stopping = false
	_pose_inputs.puck_play_stride_phase = 0.0
	_pose_inputs.puck_play_stride_intensity = 0.0
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
	_pose.sweep_windup_x_extension = sweep_windup_x_extension
	_pose.sweep_windup_z_pull = sweep_windup_z_pull
	_pose.sweep_windup_max_yaw_deg = sweep_windup_max_yaw_deg
	_pose.body_lean_max_deg = body_lean_max_deg
	_pose.body_lean_reach_norm = body_lean_reach_norm
	_pose.shoulder_pitch_y_neutral = shoulder_pitch_y_neutral
	_pose.shoulder_pitch_forward_max_deg = shoulder_pitch_forward_max_deg
	_pose.shoulder_pitch_back_max_deg = shoulder_pitch_back_max_deg
	_pose.shoulder_pitch_y_range = shoulder_pitch_y_range
	_pose.react_hand_y_min = react_hand_y_min
	_pose.react_hand_y_max = react_hand_y_max
	_pose.arm_reach_above_chest = arm_reach_above_chest
	_pose.react_hand_z = react_hand_z
	_pose.slide_pushoff_lift = slide_pushoff_lift
	_pose.slide_pushoff_rot_deg = slide_pushoff_rot_deg
	_pose.slide_body_lean_deg = slide_body_lean_deg
	_pose.slide_initial_speed = slide_initial_speed
	_puck_play.skate_speed = puck_play_skate_speed
	_puck_play.skate_accel = puck_play_skate_accel
	_puck_play.go_margin = puck_play_go_margin
	_puck_play.abort_margin = puck_play_abort_margin
	_puck_play.stop_beat = puck_play_stop_beat
	_puck_play.set_beat = puck_play_set_beat
	_puck_play.capture_radius = puck_play_capture_radius
	_puck_play.min_puck_speed = puck_play_min_puck_speed
	_puck_play.max_puck_speed = puck_play_max_puck_speed
	_puck_play.opponent_speed = puck_play_opponent_speed
	_puck_play.net_front_exclusion = puck_play_net_front_exclusion
	_puck_play.cooldown_s = puck_play_cooldown_s
	_puck_play.boards_inset = puck_play_boards_inset
	_puck_play.post_clearance = puck_play_post_clearance
	_puck_play.stride_cadence = puck_play_stride_cadence
	_puck_play.goal_line_z = _goal_line_z
	_puck_play.goal_center_x = _goal_center_x
	_puck_play.direction_sign = _direction_sign
	_puck_play.net_half_width = net_half_width
	_puck_play.home_depth = maxf(depth_defensive, 0.2)
	_clear.reach = clear_reach
	_clear.max_puck_speed = clear_max_puck_speed
	_clear.max_height = clear_max_height
	_clear.dwell = clear_dwell
	_clear.exit_speed = clear_speed
	_clear.lateral_weight = clear_lateral_weight
	_clear.forward_weight = clear_forward_weight
	_clear.center_deadband = clear_center_deadband
	_clear.cooldown = clear_cooldown
	_clear.windup_s = sweep_windup_s
	_clear.anim_duration = sweep_anim_duration
	_clear.cover_reach_time = cover_reach_time
	_clear.cover_secure_radius = cover_secure_radius
	_clear.cover_hold_s = cover_hold_s
	_clear.cover_cooldown_s = cover_cooldown_s
	_clear.cover_escape_height = cover_escape_height
	_clear.body_rest_dwell_s = cover_body_rest_dwell_s
	_clear.body_rest_max_height = cover_body_rest_max_height
	_clear.body_radius = cover_body_radius
	_clear.catch_quick_drop_s = catch_quick_drop_s
	_clear.goal_line_z = _goal_line_z
	_clear.goal_center_x = _goal_center_x
	_clear.direction_sign = _direction_sign
	_clear.catches_left = catches_left
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
	# Universal-reaction impact classification uses the SAME geometry but with NO
	# speed floor. The universal path's urgency decision is already made by
	# should_react_to_puck (imminence + on-net, tiny anti-jitter floor only) — its
	# whole point is that a slow trickler / dying board-bounce at the doorstep is
	# MORE urgent than a rocket from the point, not less. Re-running detect_shot
	# with `_shot_cfg`'s 5 m/s `shot_speed_threshold` here silently rejected every
	# sub-threshold puck, so slow pucks oozing at the net never triggered a
	# reaction and the goalie sat a statue. This clone keeps low/elevated
	# classification and the on-net check; speed gating stays on the RELEASE path
	# (which must still filter slow dribbled passes) via `_shot_cfg`.
	_universal_shot_cfg = GoalieBehaviorRules.ShotDetectionConfig.new()
	_universal_shot_cfg.shot_speed_threshold = 0.0
	_universal_shot_cfg.net_half_width = net_half_width
	_universal_shot_cfg.net_margin = net_margin
	_universal_shot_cfg.reaction_delay = reaction_delay
	_universal_shot_cfg.low_shot_threshold = low_shot_threshold
	_universal_shot_cfg.elevated_threshold = elevated_threshold
	_screen_cfg = GoalieBehaviorRules.ScreenConfig.new()
	_screen_cfg.screener_radius = screener_radius
	_move_read_cfg = GoalieBehaviorRules.MovementReadConfig.new()
	_move_read_cfg.reference_speed = move_read_reference_speed
	_move_read_cfg.speed_delay = move_read_speed_delay
	_move_read_cfg.scramble_delay = move_read_scramble_delay
	_universal_reaction_cfg = GoalieBehaviorRules.UniversalReactionConfig.new()
	_universal_reaction_cfg.min_speed = universal_react_min_speed
	_universal_reaction_cfg.max_time_to_impact = universal_react_max_time_to_impact
	_universal_reaction_cfg.net_half_width = net_half_width
	_universal_reaction_cfg.net_margin = net_margin
	_zone_cfg = GoalieBehaviorRules.DefensiveZoneConfig.new()
	_zone_cfg.zone_post_z = zone_post_z
	_arc_cfg = GoalieBehaviorRules.ArcConfig.new()
	_arc_cfg.net_half_width = net_half_width
	_arc_cfg.seal_inset = post_seal_inset
	_arc_cfg.seal_depth = rvh_depth
	_arc_cfg.post_integration_angle_deg = rvh_early_angle
	_zone_cfg.rvh_early_angle = rvh_early_angle
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
	_sweep_lane_cfg = GoalieBehaviorRules.SweepLaneConfig.new()
	# Physical lane parameters shared with the bot AI's lane model: blade reach,
	# a competitive read delay, and lateral close pace at ~half top speed.
	_sweep_lane_cfg.stick_reach = GameRules.DEFAULT_STICK_LENGTH_M
	_sweep_lane_cfg.reaction_delay = 0.08
	_sweep_lane_cfg.close_speed = 0.5 * GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
	_rush_cfg = GoalieBehaviorRules.RushRetreatConfig.new()
	_rush_cfg.engage_distance = rush_engage_distance
	_rush_cfg.mid_distance = rush_mid_distance
	_rush_cfg.arrive_distance = rush_arrive_distance
	_rush_cfg.depth_engage = depth_aggressive
	_rush_cfg.depth_mid = depth_base
	_rush_cfg.depth_arrive = depth_defensive
	_clear.lane_cfg = _sweep_lane_cfg
	_depth_constraints.floor_radius = depth_defensive
	_depth_constraints.settle_speed = depth_speed
	_depth_constraints.max_speed = depth_max_speed

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
	_reading_pinned_windup = false
	_reading_planted_windup = false
	_tracked_threat_position = puck.global_position if puck != null else Vector3.ZERO
	_prev_puck_position = _tracked_threat_position
	_cross_crease_react_timer = 0.0
	_cross_crease_timer = 0.0
	_cross_crease_target_x = 0.0
	_shot_commit_timer = 0.0
	_shot_read_timer = 0.0
	_prime_linger_timer = 0.0
	_aim_history_idx = 0
	_aim_history_len = 0
	_read_blend = 1.0
	_read_hold = 0.0
	_read_committed = false
	_read_last_vel = Vector3.ZERO
	_screen_block_drop_timer = -1.0
	_chest_t = 0.0
	# Cover state clears with the goalie; the puck's pickup_locked is owned by
	# the phase machinery through stoppages (FACEOFF_PREP locks, PLAYING entry
	# unlocks), so a reset mid-cover never needs to touch the lock here. But
	# motion_pinned IS the goalie's — a reset stops the per-tick pin, so release it
	# or the drive would stay frozen after the faceoff drop unlocks pickup.
	if puck != null:
		puck.motion_pinned = false
	_clear.reset()
	_beaten_wide_confirm_timer = 0.0
	_slide_coverage_confirm_timer = 0.0
	_puck_play.reset()
	_lunge_active_timer = 0.0
	_lunge_cooldown_timer = 0.0
	_move_speed_current = 0.0
	_reaction_drift_vx = 0.0
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
	# A physics tick IS a new view by definition. The frame stamp inside the view
	# only has to catch RE-reads within one tick (the puck_released signal handler
	# fires outside _physics_process and must not rebuild what this tick already
	# scanned); it is not a reliable "has the world moved" test on its own, since
	# a harness that drives _physics_process directly never advances the engine's
	# frame counter and would silently read the first tick's skater positions
	# forever.
	_view.invalidate()
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
	# for the threat-pressing closing check and the intercept-at-goalie-plane
	# glove targeting.
	var inv_dt: float = 1.0 / maxf(delta, 0.0001)
	_puck_velocity_est = (puck.global_position - _prev_puck_position) * inv_dt
	_prev_puck_position = puck.global_position
	# Detect a shot windup on the carrier — stance tell, not a butterfly drop.
	# PINNED covers both wind-ups (the puck is body-rigid in either, so the
	# squaring / lead corrections apply); PLANTED is the slapper-only subset where
	# the shooter also can't relocate, which the positional aim shade needs.
	var carrier: Skater = puck.get_carrier()
	var upright: bool = _sm.is_upright()
	_reading_pinned_windup = carrier != null and upright \
			and SkaterStateMachine.state_pins_puck(carrier.current_shot_state)
	_reading_planted_windup = carrier != null and upright \
			and carrier.current_shot_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK
	# Compute desired threat target. With a carrier we lerp toward the
	# blended (chest+puck) target so stickhandling jitter is smoothed. With
	# no carrier (loose puck, rebound, shot in flight) the threat is the
	# puck position directly — lerping here makes the goalie chase stale
	# positions and commit slides to where the rebound *was*, sliding away
	# from where it actually is.
	var target_threat: Vector3 = _compute_threat_position()
	if puck.get_carrier() != null and not _reaction.reacting:
		# Quiet-eye smoothing: the tracking lerp slows with carrier distance so
		# far-range stickhandle wiggle is low-passed instead of chased — the
		# temporal replacement for the old chest-weighted squaring target
		# (realism audit F1). `_chest_t` was just set by the threat computation.
		var track_speed: float = lerpf(tracking_speed, tracking_speed_far, _chest_t)
		_tracked_threat_position = _tracked_threat_position.lerp(target_threat, track_speed * delta)
	else:
		_tracked_threat_position = target_threat
	if is_server:
		_update_shot_commit(delta, carrier)
		_update_cross_crease(delta, carrier)
		_update_lunge(delta)
	# Universal puck tracking: trigger a reaction for any loose puck above the
	# threshold heading for the net within max_time_to_impact, regardless of
	# whether a release event fired. Catches board bounces, poke-strips,
	# deflections, rebounds. Gated to host, non-reacting, non-post-integrated,
	# loose puck — release-triggered shots and RVH/VH commits stay untouched.
	if is_server and not _reaction.reacting and not _sm.is_post_integrated() \
			and _sm.current != State.PLAYING_PUCK and carrier == null:
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
		# The goalie acts on his BELIEF, which converges onto the truth as the puck
		# flies and he can actually see it (see _advance_read_convergence). With
		# read_lag == 0 this is the old exact re-projection, unchanged.
		_advance_read_convergence(delta, result)
		# Elevated shot that's tipped low and tracking low — start the
		# butterfly drop timer (still allowed during freeze; arms-and-drop
		# are the body reactions the freeze permits). Keyed off the BELIEVED
		# impact height: he drops for the shot he thinks is coming.
		if _reaction.impact_y < low_shot_threshold:
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
			or _sm.is_post_integrated() \
			or _sm.current == State.PLAYING_PUCK \
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
	# One flat weight — see the `shooter_weight` doc-block for the measurement
	# that collapsed the stance split and the distance fade into it.
	# Distance-scaled chest tracking: far out, play the shooter's chest almost
	# entirely (the dangle is irrelevant until it's in tight) and fade the puck
	# lead to zero so forehand-backhand jitter stops wobbling the body; in tight,
	# restore full puck tracking. Keyed off the carrier's distance to the goal.
	var carrier_dist: float = GoalieBehaviorRules.threat_distance_to_goal(
			carrier.global_position, _goal_line_z, _goal_center_x)
	var chest_t: float = GoalieBehaviorRules.chest_tracking_factor(
			carrier_dist, chest_track_near_distance, chest_track_far_distance)
	_chest_t = chest_t
	# EITHER shot windup is the exception: the puck is pinned to the body (no
	# jitter to reject) and IS the shot origin at every range, so square to it
	# directly — no body bias at all. See shooter_weight_pinned_windup.
	var w: float = shooter_weight_pinned_windup if _reading_pinned_windup \
			else shooter_weight
	var blended: Vector3 = GoalieBehaviorRules.compute_threat_position(
			puck.global_position, carrier.global_position, true, w)
	# Two leads: CARRIER velocity captures body motion (sustained skating) and is
	# smooth, so it always contributes. PUCK velocity captures dangle / dragged-
	# across motion (forehand-backhand dekes, pivot-to-shoot blade swings) — it's
	# the jitter source, so it's faded out with distance (×(1-chest_t)): kept in
	# tight where it keeps the goalie in front of a walkout deke, gone at range
	# where it only chased stickhandling wiggle. Y is zeroed because skaters
	# don't move vertically — leading height noise would drift the threat off ice.
	#
	# EITHER shot windup is the exception: the puck is pinned to the body and moves
	# WITH it, so `_puck_velocity_est` IS the carrier velocity — the two leads then
	# double-count the same body motion (~1.67× lead in tight) and OVER-lead a
	# lateral coast, over-committing the goalie ahead of the pinned puck and opening
	# the against-the-grain side. There's no independent dangle to catch (the blade
	# is frozen body-local for a wrister, the offset fixed for a slapper), so drop
	# the puck lead during either windup and let the honest carrier lead alone keep
	# the goalie square.
	#
	# This matters MORE on the wrister than the slapper: the slapper plants
	# (locomotion suppressed + velocity dragged to zero), so there is little body
	# motion left to double-count, while a wrister shooter keeps full thrust and
	# can be skating flat out — the spurious lead peaks exactly where the goalie
	# can least afford it (~0.5 m at 6 m/s lateral, about half a net width of
	# over-commitment).
	var puck_lead_scale: float = 0.0 if _reading_pinned_windup else (1.0 - chest_t)
	var lead: Vector3 = carrier.velocity * carrier_velocity_lead_time \
			+ _puck_velocity_est * puck_velocity_lead_time * puck_lead_scale
	lead.y = 0.0
	return blended + lead

# ── Shot Timer ────────────────────────────────────────────────────────────────
# `_reaction.shot_timer` is the goalie's processing delay after shot release —
# the beat between "I see the shot" and "I act on the prediction". Gates the
# butterfly drop (low shots) AND the arm reach (elevated shots, see
# `GoalieBodyConfigBuilder._apply_elevated_shot_reaction`).
func _update_shot_timer(delta: float) -> void:
	_reaction.tick_processing_timers(delta)
	# Blocking drop for fully-screened releases: counts down the base leg read,
	# then seals regardless of the shot's height classification or imminence —
	# the goalie is dropping because he can't see, not reacting to what he saw.
	# Deactivates if the reaction resolves first (save / boards / pickup).
	if _screen_block_drop_timer >= 0.0:
		if not _reaction.reacting:
			_screen_block_drop_timer = -1.0
		else:
			_screen_block_drop_timer -= delta
			if _screen_block_drop_timer <= 0.0:
				_screen_block_drop_timer = -1.0
				if _sm.is_upright():
					_enter_butterfly()
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
	if _clear.cover_cooldown_timer > 0.0:
		_clear.cover_cooldown_timer = maxf(_clear.cover_cooldown_timer - delta, 0.0)
	_puck_play.tick_cooldown(delta)
	# Convert puck global X into goalie local X. The -Z goal goalie is rotated PI
	# so its local +X is global -X; multiplying by -_direction_sign corrects for that.
	var puck_local_x: float = (_tracked_threat_position.x - _goal_center_x) * -_direction_sign
	match _sm.current:
		State.STANDING, State.READY:
			# Post integration is for puck POSSESSED at sharp angles / behind net
			# (post-hug coverage), not puck IN FLIGHT from one. Gating on `not
			# reacting` prevents the case where a sharp-angle shot triggers
			# reaction → next tick the puck is still in the defensive zone →
			# state flips to a post stance and clears the reaction before the
			# goalie can do anything. Once the shot resolves normally (boards /
			# post / net / save / pickup), the freeze clears and the next tick
			# can post-integrate if appropriate.
			# Stance family split (audit F14): puck BEHIND the goal line → RVH
			# (the ice-seal for wraps/walkouts); puck IN FRONT at the sharp
			# angle → VH (post pad vertical — a live shot threat keeps the
			# short-side-high coverage RVH would concede).
			# Behind-net puck play outranks post integration: a rim the goalie can
			# safely trap is stopped instead of watched from RVH. The go decision
			# is ultra-conservative (see the export block), so this rarely fires.
			if _should_play_rim() and not _reaction.reacting:
				_enter_puck_play()
			elif _is_puck_in_defensive_zone() and not _reaction.reacting:
				if _puck_front_of_goal_m() > 0.0:
					_sm.transition_to(State.VH_LEFT if puck_local_x < 0.0 else State.VH_RIGHT)
				else:
					_sm.transition_to(State.RVH_LEFT if puck_local_x < 0.0 else State.RVH_RIGHT)
			elif _should_block(delta) and not _reaction.reacting:
				# The block-or-react decision — see GoalieSaveSelection for the doctrine.
				#
				# ⚠️ `not _reaction.reacting` IS LOAD-BEARING. It looks inherited from
				# the branches above (whose comment justifies it for post stances) and
				# it is not. Once a shot is READ, the reaction pipeline knows something
				# this model does not: the shot's HEIGHT. Blocking concedes the top of
				# the net, so blocking a shot already read as elevated is strictly
				# wrong, and `_should_block` has no impact_y to check.
				#
				# Measured, by removing it: every unscreened shot inside ~3.9 m starts
				# blocking regardless of height (arrival <= reaction_delay), and the
				# keeper falls apart in the way that looks like a buff and is not —
				# dot-line beatability 16/288 -> 25/288, a COLD five-hole window opening
				# from nothing to 17 cm, and test_goalie_disguise_read's wrong-HEIGHT
				# arm dropping to 4/14 against a 6/14 baseline. Deception paying
				# NEGATIVELY is the tell, and it is the third time that signature has
				# come from making him pre-commit (see _build_save_situation on
				# WRISTER_AIM, and the tip doctrine in GoalieSaveSelection). A goalie
				# who blocks cannot be read, and being readable is the game.
				#
				# `_screen_block_drop_timer` is the one mechanism that stays separate:
				# a fully-screened release is the one time the height read is itself
				# untrustworthy, which is why it may act during a reaction when this
				# branch must not.
				#
				# A controlled dangler in space still keeps him UP — there the answer
				# fits.
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
			# A converged read that says "high" checks an unsealed drop.
			if _maybe_arrest_drop():
				return
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
			if _should_play_rim():
				_enter_puck_play()
			elif not _is_puck_in_defensive_zone():
				_sm.transition_to(State.READY if _is_ready_situation() else State.STANDING)
			elif _puck_front_of_goal_m() > post_stance_swap_deadband_m:
				# Puck walked out in front — flip to VH for the shot threat.
				_sm.transition_to(State.VH_LEFT)
			elif puck_local_x >= rvh_swap_deadband_m:
				_sm.transition_to(State.RVH_RIGHT)
		State.RVH_RIGHT:
			if _should_play_rim():
				_enter_puck_play()
			elif not _is_puck_in_defensive_zone():
				_sm.transition_to(State.READY if _is_ready_situation() else State.STANDING)
			elif _puck_front_of_goal_m() > post_stance_swap_deadband_m:
				_sm.transition_to(State.VH_RIGHT)
			elif puck_local_x < -rvh_swap_deadband_m:
				_sm.transition_to(State.RVH_LEFT)
		State.VH_LEFT:
			if not _is_puck_in_defensive_zone():
				_sm.transition_to(State.READY if _is_ready_situation() else State.STANDING)
			elif _puck_front_of_goal_m() < -post_stance_swap_deadband_m:
				# Puck carried behind the goal line — back to the RVH ice seal.
				_sm.transition_to(State.RVH_LEFT)
			elif puck_local_x >= rvh_swap_deadband_m:
				_sm.transition_to(State.VH_RIGHT)
		State.VH_RIGHT:
			if not _is_puck_in_defensive_zone():
				_sm.transition_to(State.READY if _is_ready_situation() else State.STANDING)
			elif _puck_front_of_goal_m() < -post_stance_swap_deadband_m:
				_sm.transition_to(State.RVH_RIGHT)
			elif puck_local_x < -rvh_swap_deadband_m:
				_sm.transition_to(State.VH_LEFT)
		State.COVERING:
			_tick_cover(delta)
		State.PLAYING_PUCK:
			_tick_puck_play(delta)
		State.CATCHING, State.CATCHING_DOWN:
			_tick_catch(delta)

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

# ── Block or react ────────────────────────────────────────────────────────────
# Gathers the scene inputs for GoalieSaveSelection, which owns the decision. See
# that file for the doctrine; the short version is that reacting is preferred and
# blocking is for when reacting is impossible, and "impossible" is a race the
# goalie can actually run: can I still complete an answer before the puck is on
# me, given what can still change it?
#
# The doorstep windup, the crease jam and the stand-up hold are all this one
# question rather than three thresholds. `_confirmed_beaten_wide` is an INPUT
# rather than a branch, because a lost lateral race is a coverage fact, not a
# timing one.
func _build_save_situation(delta: float) -> GoalieSaveSelection.Situation:
	var s := _save_situation
	var puck_pos: Vector3 = puck.global_position
	# PRICE THE SHOT FROM WHERE IT WILL ACTUALLY BE RELEASED. A slapper charge
	# relocates the carried puck to a fixed skater-local spot the instant it is
	# entered — across the body for a left-hander, ~1.65 m measured — and
	# `Puck.release` fires the shot from that pin, never from where the puck was
	# being carried. Reading the live position therefore prices a release point
	# that will not exist by the time anything is shot.
	#
	# It is not a rounding error. Host-side the relocation lands in ONE tick
	# (Puck._physics_process assigns the carry target outright), so a goalie who
	# evaluates on the tick before it lands commits to a butterfly for a gap of
	# 5.29 m and finds himself at 6.62 m the next frame — the block verdict
	# reverses, but butterfly_min_hold_time pins him down for 0.35 s first, so it
	# reads in game as "he drops, backs up a bit, then gets back up and resets to
	# his aggressive depth" against a shooter who never moved.
	#
	# Only for the PINNED wind-up: that is exactly the case where the release
	# origin is a known fixed point rather than a guess.
	var pinning_carrier: Skater = puck.get_carrier()
	if pinning_carrier != null and pinning_carrier.is_slapshot_pinning():
		var pin: Vector3 = pinning_carrier.get_carry_target_global()
		pin.y = puck_pos.y
		puck_pos = pin
	var gap: float = goalie.global_position.distance_to(puck_pos)
	var vel: Vector3 = puck.linear_velocity
	var speed: float = vel.length()
	# Soonest a stick that is not his can reach the puck and change it. Opponents
	# only: a teammate touching the puck does not make it unpredictable, but an
	# opponent reaching a teammate's puck does — which is why this is a race to
	# the PUCK rather than a possession check.
	_ensure_view()
	s.time_to_contest = GoalieSaveSelection.contest_time(
			_view.nearest_opponent_dist, GameRules.DEFAULT_STICK_LENGTH_M,
			GameRules.DEFAULT_SKATER_MAX_SPEED_M_S)
	# Soonest the puck can be ON him: when it can next be LAUNCHED, plus the
	# flight from where it sits. Three launch cases, and the middle one is the
	# patience half of react-vs-block:
	#
	#   in flight            it is already launched — real pace, real flight.
	#   hostile carrier      he has declared nothing yet. A controlled puck on an
	#     with no windup     attacker's blade is READABLE: the body and stick will
	#                        tell him before it comes. No timing pressure at all,
	#                        so he stays up and makes the dangler declare.
	#   anything else        the next hostile touch IS the release — a loose puck
	#                        in a scramble, or a teammate corralling one with an
	#                        opponent arriving. Nothing telegraphs a whack, so the
	#                        contest clock is the launch clock.
	#
	# The middle case is load-bearing. Price every carrier at the worst case ("he
	# could shoot this instant") and nothing is answerable anywhere inside the slot
	# — a 6 m release is 0.18 s of flight against a 0.13 s read — so he drops on
	# everything and the patience is gone. Being unable to FULLY react does not
	# make blocking better, because blocking concedes the top of the net; he reacts
	# to what the shooter declares.
	# "Declared" is the PLANT, not the pin. Both wind-ups pin the puck to the body
	# (state_pins_puck), but only SLAPPER_CHARGE_WITH_PUCK also suppresses
	# locomotion and drags the shooter's velocity to zero. The pin says a shot is
	# loaded; the plant says it is loaded FROM HERE, and pre-committing needs the
	# second one — dropping to a threat whose origin is still skating commits the
	# goalie against a shot that will not come from where he committed. Same split
	# the tracking read already makes (_reading_pinned_windup vs
	# _reading_planted_windup).
	#
	# Measured, not assumed. Counting WRISTER_AIM as a declaration makes him block
	# through the whole slot, and test_goalie_disguise_read prices that: with the
	# block replacing the read, selling the wrong corner or the wrong height stops
	# paying anything (4/14 across all three arms, against 6/14 telegraphed and
	# 11/14 wrong-height under the read). A goalie who pre-commits cannot be
	# deceived, and the in-tight aim duel is the skill this game wants there.
	var carrier: Skater = puck.get_carrier()
	var hostile_carrier: bool = carrier != null \
			and (team_id == -1 or carrier.get_team_id() != team_id)
	var launch: float = 0.0
	if hostile_carrier and carrier.current_shot_state \
			!= SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK:
		launch = INF
	elif not hostile_carrier:
		launch = s.time_to_contest
	# CLOSING speed, not raw speed. A puck's own flight only puts it on him if it
	# is coming at him: `gap / speed` treats a puck flying AWAY at 20 m/s exactly
	# like one flying at him, and dropped him for both. It also mis-times the
	# cross-crease pass, which is the case that matters — a pass crossing the
	# crease is not arriving on the goalie at all, it is arriving at a RECEIVER,
	# and the clock that matters is the receiver's stick plus the one-timer from
	# there. That falls out of the launch route below with no extra machinery,
	# and it is the same fact `cross_crease_race_lost` computes for the
	# drop-and-slide (which still owns WHERE to seal — this only answers whether
	# the ice needs sealing at all).
	var to_goalie: Vector3 = goalie.global_position - puck_pos
	to_goalie.y = 0.0
	var toward: Vector3 = to_goalie.normalized()
	var closing: float = vel.x * toward.x + vel.z * toward.z
	var arriving: bool = speed >= shot_speed_threshold and closing > 0.001
	if arriving:
		s.time_to_arrival = gap / closing
	elif is_inf(launch):
		s.time_to_arrival = INF
	else:
		s.time_to_arrival = launch \
				+ gap / GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	# Occlusion along the line the puck would actually travel: its own velocity
	# when that is what reaches him, otherwise the puck→goalie line at the pace a
	# touch would put on it (screen delay is `along / speed`, so both terms
	# matter).
	var sight_vel: Vector3 = vel
	if not arriving:
		sight_vel = toward * GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	s.sight_delay = _screen_delay(sight_vel)
	s.reaction_delay = reaction_delay
	s.drop_time = butterfly_drop_speed
	s.lateral_race_lost = _confirmed_beaten_wide(delta)
	return s


# Should he be sealing the ice rather than reading? One question for going down
# AND for staying down, so he cannot pop up into a situation he would have
# dropped for.
# The staying-down twin of `_should_block`, sharing its lunge precedence: a
# committed poke is a save selection already made, and the seal must not undo it
# either.
func _should_hold_seal() -> bool:
	if _lunge_active_timer > 0.0:
		return false
	return GoalieSaveSelection.should_hold_seal(
			_build_save_situation(0.0), recovery_duration)


func _should_block(delta: float) -> bool:
	# Lunge precedence, carried over from the doorstep predicate this replaced: a
	# committed poke IS a save selection, already made. Dropping out of it would
	# be a free undo of the gamble, and the gamble is the point — a beaten lunge
	# is supposed to concede (see _movement_read_delay).
	if _lunge_active_timer > 0.0:
		return false
	return GoalieSaveSelection.should_block(_build_save_situation(delta))


# Beaten-wide with the quiet-eye confirmation: the race verdict must hold
# continuously for `lateral_commit_confirm_s` before the standing goalie
# sells out pads-first. One tick of lateral body velocity is a deke's
# opening move, not a drive — the reset on a broken verdict is what makes
# the pull-back un-commit him.
func _confirmed_beaten_wide(delta: float) -> bool:
	if not _is_beaten_wide():
		_beaten_wide_confirm_timer = 0.0
		return false
	_beaten_wide_confirm_timer += delta
	return _beaten_wide_confirm_timer >= lateral_commit_confirm_s


# True when an opposing carrier's lateral drive has beaten the standing
# goalie to the tuck point (the around-the-pad reach). Race math in
# GoalieBehaviorRules.is_beaten_wide; this gathers the scene inputs. Reads the
# carrier's actual body velocity AND the raw carried-puck position, not the
# lerped tracked threat — the smoothed threat lags exactly when the drive is
# fastest, and the puck term is the point-of-no-return gate (a forehand-drag
# drive with the puck trailing commits nothing; see the rule header).
func _is_beaten_wide() -> bool:
	var carrier: Skater = puck.get_carrier()
	if carrier == null:
		return false
	if team_id != -1 and carrier.get_team_id() == team_id:
		return false
	return GoalieBehaviorRules.is_beaten_wide(
			carrier.global_position, puck.global_position, carrier.velocity.x,
			goalie.global_position, _goal_line_z, _goal_center_x,
			_direction_sign, net_half_width, _beaten_wide_cfg)

# Distance from the nearest non-ghost opposing skater to the puck, or INF if
# there are none (or no skater getter wired). Ghosted players (offside / icing)
# can't play the puck, so they don't count as pressure.
func _nearest_opposing_skater_dist_to_puck() -> float:
	_ensure_view()
	return _view.nearest_opponent_dist

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
	if _sm.is_post_integrated():
		return false
	# THE JAB IS THE LAST RESORT, not the first. He commits only when the blade
	# cannot reach the puck from where it is and can if it extends — see
	# GoalieStickRules.lunge_is_the_only_reach for why, and for what the old
	# `lunge_trigger_distance` was actually doing.
	if not GoalieStickRules.lunge_is_the_only_reach(
			goalie.get_blade_world_position().distance_to(puck.global_position),
			goalie_poke_radius, lunge_extension):
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
	# Windup → strike: the backswing runs down, then the strike applies the
	# clear velocity as the blade snaps through the puck (host-only path).
	if _clear.windup_timer > 0.0:
		_clear.windup_timer = maxf(_clear.windup_timer - delta, 0.0)
		if _clear.windup_timer <= 0.0:
			_strike_pending_sweep()
	if _clear.anim_timer > 0.0:
		_clear.anim_timer = maxf(_clear.anim_timer - delta, 0.0)
		if _clear.anim_timer <= 0.0:
			# Sweep window over — restore the stick's normal save collision.
			goalie.set_stick_collision_enabled(true)
	var carrier: Skater = puck.get_carrier()
	if carrier == null:
		# A puck at rest ON the body outranks the sweep (the sweep can't reach
		# it — it reads as airborne); otherwise sweep a loose puck out of the
		# crease.
		if _maybe_cover_body_rested_puck(delta):
			return
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
	if _clear.windup_timer > 0.0:
		return  # a sweep is already wound up — the strike owns the next beat
	if _clear.clear_cooldown_timer > 0.0:
		_clear.clear_cooldown_timer = maxf(_clear.clear_cooldown_timer - delta, 0.0)
		return
	if not _is_loose_puck_clearable():
		_clear.dwell_timer = 0.0
		return
	# The puck has to settle on the ice in front of the goalie for a beat before
	# the sweep fires — otherwise the goalie bats pucks away the instant they
	# drift into reach. Accumulate dwell while clearable; the predicate already
	# reset it to zero the moment the puck left the window.
	_clear.dwell_timer += delta
	if _clear.dwell_timer < clear_dwell:
		return
	# Lane-aware clear: pick a corner whose exit lane no opponent can reach. If
	# BOTH lanes are covered — the situation where a real sweep just feeds an
	# opponent's stick — and someone is on the puck, this is the cover read:
	# smother it (audit follow-up to F12/§6.3; USA Hockey's cover-vs-clear
	# hierarchy). With cover on cooldown (or no real pressure) fall back to the
	# natural-side sweep — a desperation clear beats standing still.
	var sweep_vel: Vector3 = _pick_clear_velocity()
	if sweep_vel == Vector3.ZERO:
		if _clear.cover_cooldown_timer <= 0.0 \
				and _nearest_opposing_skater_dist_to_puck() <= puck_contest_radius:
			_enter_cover()
			return
		sweep_vel = _natural_clear_velocity(0.0)
	_begin_sweep(sweep_vel, false)


# Start the windup: the blade cocks away from the planned send corner for
# `sweep_windup_s`; the STRIKE (in _strike_pending_sweep, when the timer
# expires) is what actually imparts the clear velocity — so the stick visibly
# sweeps the puck out rather than the puck departing at the decision moment.
# Stick collision is disabled for the whole windup + follow-through window
# (the blade path runs straight through the puck's exit line); re-enabled by
# the follow-through countdown in _update_goalie_poke. `planned_vel` only
# picks the windup's visual direction — the strike re-solves the lane-aware
# exit against the live world.
func _begin_sweep(planned_vel: Vector3, cover_release: bool) -> void:
	_clear.pending_cover_release = cover_release
	_clear.windup_timer = sweep_windup_s
	_clear.dwell_timer = 0.0
	_clear.set_send_dir(planned_vel)
	goalie.set_stick_collision_enabled(false)
	if sweep_windup_s <= 0.0:
		_strike_pending_sweep()


# The strike: the backswing has snapped through — impart the clear velocity
# NOW, at the moment the blade visually meets the puck. The exit is re-solved
# lane-aware against the live world (the puck may have drifted during the
# windup, and a lane may have opened/closed). A cover-release strike also
# unlocks the pinned puck and stands the goalie up; a plain clear whose puck
# got whacked away or grabbed during the windup WHIFFS — the follow-through
# still plays, an honest missed sweep.
func _strike_pending_sweep() -> void:
	var cover_release: bool = _clear.pending_cover_release
	_clear.pending_cover_release = false
	_clear.anim_timer = sweep_anim_duration
	if cover_release:
		puck.pickup_locked = false
		puck.motion_pinned = false  # releasing the pin — the drive owns it again
		_clear.cover_secured = false
		_apply_strike_velocity()
		_clear.cover_cooldown_timer = cover_cooldown_s
		_sm.transition_to(State.RECOVERING)
		_sm.recovery_timer = 0.0
		return
	if not _puck_strikeable():
		return
	_apply_strike_velocity()


func _apply_strike_velocity() -> void:
	var vel: Vector3 = _pick_clear_velocity()
	if vel == Vector3.ZERO:
		vel = _natural_clear_velocity(0.0)
	puck.apply_goalie_sweep(vel)
	_clear.clear_cooldown_timer = clear_cooldown
	# Re-aim the follow-through at the ACTUAL exit corner (the lane re-solve at
	# strike time can flip it from the windup's plan).
	if not vel.is_zero_approx():
		_clear.set_send_dir(vel)


# Is the loose puck still there for the strike to hit? Mirrors the clearable
# window with a little sweep-reach slack — someone may have moved it during
# the windup.
func _puck_strikeable() -> bool:
	if puck.get_carrier() != null or puck.pickup_locked:
		return false
	return _clear.is_strikeable_geometry(
			puck.global_position, puck.linear_velocity.length(), goalie.global_position)


# Natural-side clear velocity (dead-centre pucks default to the stick side);
# `forced_side` != 0 overrides toward that corner.
func _natural_clear_velocity(forced_side: float) -> Vector3:
	return _clear.natural_exit(puck.global_position, forced_side)


# Lane-aware corner pick: natural side if its exit lane is clear of opposing
# reach, else the far corner, else ZERO (no safe sweep exists — the cover
# read). Opponent gather is a scalar loop into a reused packed array.
func _pick_clear_velocity() -> Vector3:
	_ensure_view()
	return _clear.pick_exit(puck.global_position, _view.opponents)


# Refresh the shared per-tick skater view. Every read that needs other skaters
# goes through this — ONE scan per frame instead of the six independent walks the
# controller used to run. Frame-stamped and lazy, so it is also correct when
# called from the puck_released SIGNAL handler, which fires outside the physics
# tick and would otherwise read a stale or unbuilt view.
func _ensure_view() -> void:
	if not _skater_getter.is_valid():
		_view.invalidate()
		return
	_view.ensure(Engine.get_physics_frames(), _skater_getter.call(),
			team_id, puck.global_position, puck.get_carrier())


# ── Cover / smother lifecycle ─────────────────────────────────────────────────
# A loose puck at rest ON the goalie's body (see the cover_body_rest exports).
# Runs every host tick from the no-carrier poke path; returns true when it
# committed the smother. States with their own puck lifecycle (COVERING,
# PLAYING_PUCK, the catches) and an in-flight sweep windup keep priority.
# Deliberately ignores `cover_cooldown_s`: unlike the lane-read smother, where
# the desperation sweep is the fallback, a body-rested puck has no other
# resolution — every normal play path is height-gated off it.
func _maybe_cover_body_rested_puck(delta: float) -> bool:
	if _sm.current == State.COVERING or _sm.current == State.PLAYING_PUCK \
			or _sm.is_catching():
		return false
	if _clear.windup_timer > 0.0 or puck.pickup_locked:
		return false
	if not _clear.tick_body_rest(delta, puck.global_position,
			puck.linear_velocity.length(), goalie.global_position):
		return false
	_enter_cover()
	return true


# Enter the smother: collapse over the puck and start the reach race. The
# glove takes `cover_reach_time` to land; until then the puck is still live.
func _enter_cover() -> void:
	_clear.cover_secured = false
	_clear.cover_reach_timer = cover_reach_time
	_clear.cover_hold_timer = 0.0
	_move_speed_current = 0.0
	_sm.transition_to(State.COVERING)


# Per-tick COVERING logic (host). Reach phase: the smother race — a puck that
# gets whacked out of the window before the glove lands aborts the cover into
# a RECOVERING scramble (the gamble). Secured phase: the puck is dead under
# the glove (velocity re-zeroed each tick so the goalie's own colliders can't
# nudge it; skater bodies can't touch it — the puck mask excludes them and the
# blade paths are pickup_locked-gated). NHL resolution arrives externally as a
# whistle (GameManager) whose faceoff reset calls reset_to_crease; otherwise
# the ARCADE hold expires here and the goalie plays it out himself.
func _tick_cover(delta: float) -> void:
	if not is_server:
		return
	if puck.get_carrier() != null:
		_abort_cover()
		return
	if not _clear.cover_secured:
		var dist: float = goalie.global_position.distance_to(puck.global_position)
		# Height escape is the collapsed-body window (`cover_escape_height`),
		# NOT the sweep's on-ice ceiling — a body-rested cover starts with the
		# puck already at pad-top height and must not insta-abort. A real whack
		# that pops the puck out also gives it speed; the velocity gate reads it.
		if _clear.cover_escaped(dist, puck.linear_velocity.length(),
				puck.global_position.y):
			_abort_cover()
			return
		_clear.cover_reach_timer -= delta
		if _clear.cover_reach_timer > 0.0:
			return
		if dist > cover_secure_radius:
			_abort_cover()
			return
		# Glove is down with the puck still under it — secured.
		_clear.cover_secured = true
		_clear.cover_hold_timer = cover_hold_s
		puck.pickup_locked = true
		puck.motion_pinned = true  # goalie owns the transform now — freeze the drive
		puck.set_puck_velocity(Vector3.ZERO)
		puck_covered.emit(team_id)
		return
	# Secured: keep the puck dead and run the ARCADE hold-and-release timer.
	puck.set_puck_velocity(Vector3.ZERO)
	if _clear.windup_timer > 0.0:
		return  # release windup in flight — the strike unlocks, sweeps, stands up
	_clear.cover_hold_timer -= delta
	if _clear.cover_hold_timer <= 0.0:
		# Hold over — wind up the release sweep while the glove still pins the
		# puck; the strike (cover_release = true) unlocks it as the blade snaps
		# through, so the release visibly comes off the stick.
		var planned: Vector3 = _pick_clear_velocity()
		if planned == Vector3.ZERO:
			planned = _natural_clear_velocity(0.0)
		_begin_sweep(planned, true)


# ── Catch-and-hold lifecycle ─────────────────────────────────────────────────
# A controlled glove save just landed (puck.puck_caught_by_goalie, emitted from
# the host-authoritative rebound resolution inside a physics callback — so all
# physics writes are deferred to the first _tick_catch). Enter the squeeze:
# upright or down variant by the goalie's current stance; hold length and the
# freeze resolution by pressure — held under pressure it rides the same
# `puck_covered` rails as the smother, unpressured it look-and-drops and plays
# on (the real delay-of-game incentive).
func _on_puck_caught(contacted: Goalie) -> void:
	if contacted != goalie or not is_server:
		return
	if _sm.is_catching() or _sm.current == State.COVERING \
			or _sm.current == State.PLAYING_PUCK or _sm.is_post_integrated():
		return
	if puck.pickup_locked or puck.get_carrier() != null:
		return
	_clear.catch_secured = false
	_clear.catch_pressured = _nearest_opposing_skater_dist_to_puck() <= catch_hold_pressure_radius
	_clear.catch_hold_timer = cover_hold_s if _clear.catch_pressured else catch_quick_drop_s
	_sm.transition_to(State.CATCHING_DOWN if _sm.is_down() else State.CATCHING)


# Per-tick squeeze (host). First tick pins the puck into the glove — carry-
# style RigidBody freeze plus pickup_locked (blade paths and bots treat it as
# dead) — and fires the freeze resolution if the catch was pressured. Every
# tick re-pins the puck to the glove's world position so it rides the squeeze
# pose; when the hold expires the goalie sets it down at his feet and plays on
# (the existing dwell → lane-aware clear takes over).
func _tick_catch(delta: float) -> void:
	if not is_server:
		return
	if not _clear.catch_secured:
		_clear.catch_secured = true
		# pickup_locked makes the puck dead to blades; motion_pinned parks the
		# analytic drive so the per-tick glove pin below owns the position.
		puck.pickup_locked = true
		puck.motion_pinned = true
		puck.set_puck_velocity(Vector3.ZERO)
		if _clear.catch_pressured:
			puck_covered.emit(team_id)
	puck.set_puck_position(goalie.get_glove_world_position())
	_clear.catch_hold_timer -= delta
	if _clear.catch_hold_timer <= 0.0:
		_drop_caught_puck()


# Set the caught puck down at the feet and rejoin play through the recovery
# window. The dropped puck is an ordinary loose puck again — the crease-clear
# machinery (dwell → lane-aware windup-strike, or another cover if the lanes
# are jammed) handles what happens next.
func _drop_caught_puck() -> void:
	puck.pickup_locked = false
	puck.motion_pinned = false  # releasing the glove pin — the drive owns it again
	_clear.catch_secured = false
	puck.set_puck_position(Vector3(
			goalie.global_position.x, puck.ice_height,
			goalie.global_position.z + float(_direction_sign) * 0.45))
	puck.set_puck_velocity(Vector3.ZERO)
	_sm.transition_to(State.RECOVERING)
	_sm.recovery_timer = 0.0


# ── Behind-net puck play (delegated to GoaliePuckPlay) ───────────────────────
# The trip's decision, geometry and phase live in the collaborator; the
# controller keeps the scene-level guards, the state-machine transitions, and the
# puck mutation (the trap), which must stay on the main thread.
func _should_play_rim() -> bool:
	if _reaction.reacting:
		return false
	if puck.get_carrier() != null or puck.pickup_locked:
		return false
	# Cheap geometry rejects BEFORE the skater scan — this is polled every tick.
	var vel: Vector3 = _loose_puck_velocity()
	if not _puck_play.may_consider(puck.global_position, vel):
		return false
	_ensure_view()
	return _puck_play.should_go(
			puck.global_position, vel, goalie.global_position, _view.opponents)


func _enter_puck_play() -> void:
	_puck_play.begin()
	_move_speed_current = 0.0
	_sm.transition_to(State.PLAYING_PUCK)


func _tick_puck_play(delta: float) -> void:
	if not is_server:
		return
	_ensure_view()
	_puck_play.advance(delta, goalie.global_position, puck.global_position,
			_loose_puck_velocity().length(), puck.get_carrier() != null, _view.opponents)
	if _puck_play.wants_trap:
		# The trap: kill the rim dead at the paddle. Physics write, so it is the
		# controller's to perform — the collaborator only asks.
		puck.apply_goalie_sweep(Vector3.ZERO)
	if _puck_play.arrived_home:
		# Home — hand control back. `_current_depth` returns to radius units for
		# the standing family; the defensive-zone check next tick post-integrates
		# if the puck is still back there.
		_current_depth = GoalieBehaviorRules.threat_distance_to_goal(
				goalie.global_position, _goal_line_z, _goal_center_x)
		_sm.transition_to(State.READY if _is_ready_situation() else State.STANDING)


# The smother failed (puck whacked away / picked up before the glove landed)
# or was interrupted — release any lock and eat the scramble recovery. The
# full cover cooldown applies either way: a failed gamble is still the gamble.
func _abort_cover() -> void:
	if _clear.cover_secured:
		puck.pickup_locked = false
		puck.motion_pinned = false  # cover fell through — hand the puck back to the drive
		_clear.cover_secured = false
	if _clear.windup_timer > 0.0:
		# A wound-up release dies with the cover; give the stick its collision
		# back (no strike/follow-through will run the countdown for us).
		_clear.windup_timer = 0.0
		_clear.pending_cover_release = false
		if _clear.anim_timer <= 0.0:
			goalie.set_stick_collision_enabled(true)
	_clear.cover_cooldown_timer = cover_cooldown_s
	_sm.transition_to(State.RECOVERING)
	_sm.recovery_timer = 0.0


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
	if _reaction.reacting or _sm.is_post_integrated() or _sm.current == State.COVERING:
		return false
	return _clear.is_clearable_geometry(
			puck.global_position, puck.linear_velocity.length(), goalie.global_position)


# Returns the current lunge progress as a sin curve: 0 at start, 1 at peak
# (mid-window), 0 at end. The pose builder consumes this to scale the
# forward blocker extension.
func _lunge_progress() -> float:
	if _lunge_active_timer <= 0.0 or lunge_duration <= 0.0:
		return 0.0
	var elapsed: float = clampf((lunge_duration - _lunge_active_timer) / lunge_duration, 0.0, 1.0)
	return sin(PI * elapsed)


# Windup (backswing) progress, 0 → 1 as the blade cocks over sweep_windup_s.
func _sweep_windup_progress() -> float:
	return _clear.windup_progress()


# Clear-sweep follow-through, sin-curved 0 → 1 (peak) → 0 over sweep_anim_duration.
# The pose builder scales the blade swing-through by this value. Same shape as
# the lunge; distinct timer so a clear and a lunge don't fight over one window.
func _sweep_anim_progress() -> float:
	return _clear.anim_progress()


# True when the puck has someone who can actually shoot it: either an opposing
# carrier (any range), or a loose puck with an opposing skater within
# `loose_puck_radius`. Own-team possession / own-team retrieves don't count
# as shooting threats.
func _opposing_shooter_near_puck(loose_puck_radius: float) -> bool:
	# The per-tick memo this used to carry is gone: GoalieWorldView is already
	# frame-stamped, so the shared scan does the memoising for every reader.
	#
	# NOTE the loose-puck distance comes from `nearest_opponent_dist_any`, which
	# INCLUDES ghosted players — see the quirk documented on GoalieWorldView. Kept
	# bit-identical to the pre-extraction behaviour and flagged there, rather than
	# silently corrected inside a refactor.
	var carrier: Skater = puck.get_carrier()
	if carrier != null:
		return team_id == -1 or carrier.get_team_id() != team_id
	_ensure_view()
	return _view.nearest_opponent_dist_any < loose_puck_radius

func _enter_butterfly() -> void:
	_beaten_wide_confirm_timer = 0.0
	_slide_coverage_confirm_timer = 0.0
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
			# Directional recovery (realism audit F10): a real recovery loads the
			# far-side leg and RISES MOVING toward the puck — the stand-up and the
			# push to the new position are one motion, not stand-then-move (USA
			# Hockey Full Recovery). Seed the upright mover at shuffle pace so the
			# rise tracks the arc target immediately; the accel ramp still governs
			# anything faster, and the caught-moving read penalty naturally prices
			# the motion.
			_move_speed_current = shuffle_speed
		State.STANDING:
			_slide.drop_progress = 0.0
			_slide.velocity_x = 0.0
		State.RVH_LEFT, State.RVH_RIGHT, State.VH_LEFT, State.VH_RIGHT:
			# Coming in from STANDING with the goalie on the goal line (sharp-
			# angle arc flatten), the carried-over radius value (e.g. 1.2 m)
			# gets re-interpreted as perp depth and the next tick teleports
			# the goalie 1.2 m forward. Snap to the actual current perp depth
			# so the position holds, then `_update_depth` lerps gently to
			# `rvh_depth` from there. VH shares the fix-up (same post geometry).
			_current_depth = (goalie.global_position.z - _goal_line_z) * _direction_sign

# ARRESTED DROP. A goalie who commits his legs to a low read and then sees the
# puck rising CHECKS the drop — he stays taller and gets the hand up. He can only
# do it before the pads seal; past that the butterfly is spent and the top of the
# net is open, which is what makes selling the wrong height work at all.
#
# This is what keeps height deception a RACE rather than a switch. Without it any
# non-zero `read_lag` made the goalie wrong at the single instant the leg read
# fired, and `butterfly_min_hold_time` (longer than most flights) then sealed the
# outcome — so the deception converted identically at every range and at every
# lag value, and `read_lag` was not a dial for it at all. With the arrest, the
# question becomes "did the read converge before the pads did", which is a race
# between two physical clocks: it restores the range falloff (in tight he is
# genuinely beaten, from distance he recovers) and makes `read_lag` govern the
# outcome, since a staler read means a deeper commitment before the correction.
#
# The cost is the honest one and is already modelled: he leaves through
# RECOVERING (eating `recovery_duration` and the caught-moving read penalty)
# rather than teleporting upright, and the arm still owes its late read. Only a
# FRESH, unsealed drop qualifies — a committed slide is a different commitment
# and is deliberately not abortable.
func _maybe_arrest_drop() -> bool:
	if _sm.current != State.BUTTERFLY:
		return false
	if not _reaction.reacting or not _reaction.is_elevated:
		return false
	if _slide.drop_progress >= 1.0:
		return false   # pads already sealed — the butterfly is spent, wear it
	_sm.transition_to(State.RECOVERING)
	_sm.recovery_timer = 0.0
	return true


# Should the goalie keep holding butterfly because the puck is still a threat?
# Hold conditions, in priority:
#   0. Puck is BEHIND the goal line                               → release
#      A stance question, not a save question (GoalieSaveSelection's scope
#      note): nothing arrives on net from back there, and every hold below
#      prices a front-of-net threat — the carrier hold's radial distance
#      counts a wraparound carrier and the seal model prices a flight through
#      the net frame, both of which pinned him sealed facing the wrong way on
#      back-wall bounces. Butterfly cannot reach RVH directly, so releasing
#      here is what routes him through RECOVERING to the post seal — the
#      vulnerable window wraparounds are designed to exploit.
#   1. A hostile CARRIER is inside recovery_proximity_threshold  → hold
#      The rebound-stays-in-front case: a deflection bouncing back toward the
#      shooter is still a threat because he can't usefully recover before a
#      follow-up shot.
#   2. The situation would BLOCK a standing goalie                → hold
#      Standing up into a play he would have dropped for is the bug this fixes;
#      see below.
#   3. Puck's flight is closing on him at shot pace               → hold
#   4. Otherwise                                                  → release
# Pressure detection is one-way: it only HOLDS butterfly, never triggers entry —
# entry is _update_state's own `_should_block` branch, asking the same question.
func _is_threat_pressing() -> bool:
	if _puck_front_of_goal_m() <= 0.0:
		return false
	var threat_dist: float = GoalieBehaviorRules.threat_distance_to_goal(
			puck.global_position, _goal_line_z, _goal_center_x)
	# Proximity-stay only applies when a hostile carrier is in the
	# butterfly zone — they could shoot at any moment, hold the seal.
	# Loose pucks (no carrier) skip this and fall through to the
	# contest race inside `should_hold_seal`; a slow rebound sitting in
	# the crease doesn't keep the goalie pinned in butterfly forever.
	if threat_dist < recovery_proximity_threshold:
		var carrier: Skater = puck.get_carrier()
		if carrier != null and (team_id == -1 or carrier.get_team_id() != team_id):
			return true
	# THE SAME DECISION THAT PUT HIM DOWN — same model, same inputs — but through
	# `should_hold_seal`, which applies the asymmetric threshold (and the
	# stand-up race that releases him when nothing can touch the puck before he
	# is back on his feet). Going down and staying down are one question and not
	# one bar; see the rule for why the symmetric version self-oscillates off
	# the goalie's own depth. Possession never made a loose puck readable; a
	# stick that can reach it before he can answer is what makes it unreadable,
	# and that is what the model asks.
	if _should_hold_seal():
		return true
	# A live shot's flight: standing up into a puck flying at him opens the
	# five-hole exactly as it arrives. CLOSING speed on his body — not raw
	# speed with an approach sign read off the z-axis alone, which held him
	# down under a rebound rocketing laterally to the corner (fast, not
	# incoming) until friction bled it below the threshold.
	var vel: Vector3 = puck.linear_velocity if is_server else _puck_velocity_est
	var to_goalie: Vector3 = goalie.global_position - puck.global_position
	to_goalie.y = 0.0
	var gap: float = to_goalie.length()
	if gap < 0.001:
		return true
	var closing: float = (vel.x * to_goalie.x + vel.z * to_goalie.z) / gap
	return closing >= shot_speed_threshold

# ── Depth ─────────────────────────────────────────────────────────────────────
# Standing depth is the "challenge angle" arc radius from goal center. The
# Buckley chart still drives the radius via Euclidean threat distance — the
# geometric arc emerges from `target_arc_position` consuming radius for
# lateral motion when the threat is wide. This naturally pulls the goalie
# back on sharp angles (real goalie behaviour) instead of skating a flat
# line at fixed depth.
func _update_depth(delta: float) -> void:
	if _sm.is_post_integrated():
		# RVH and VH share the on-the-post depth.
		_current_depth = lerpf(_current_depth, rvh_depth, depth_speed * delta)
		return
	if _sm.current == State.BUTTERFLY:
		# Idle butterfly: commit at the depth set on entry, hold it.
		return
	if _sm.current == State.COVERING:
		# Smothering — planted over the puck, no depth motion.
		return
	if _sm.current == State.PLAYING_PUCK:
		# Behind-net trip — position is driven by the waypoint path, not depth.
		return
	if _sm.is_catching():
		# Squeezing the catch — planted, no depth motion.
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
		_approach_depth(depth_defensive, delta)
		return
	# STANDING / READY: every constraint below is a MAXIMUM RADIUS; the solver
	# takes the tightest and picks the approach rate. Composition lives in
	# GoalieDepthSolver so statement order here is no longer load-bearing.
	var c := _depth_constraints
	var threat_dist: float = GoalieBehaviorRules.threat_distance_to_goal(
			_tracked_threat_position, _goal_line_z, _goal_center_x)
	# Ceiling, not a curve — see GoalieDepthSolver's header. He challenges as far
	# out as the races allow, and this is the furthest that is ever worth going.
	c.ceiling_radius = depth_aggressive if _threat_is_in_zone(threat_dist) \
			else depth_conservative
	# Physical: never stand on (or past) the puck.
	c.standoff_cap = threat_dist - challenge_standoff
	c.lateral_cap = _lateral_tracking_cap(threat_dist)
	# Backdoor-aware cap (anticipatory): with a live one-timer man on the weak
	# side, don't challenge farther out than the cross-crease re-square race
	# allows. INF when no threat binds.
	c.backdoor_cap = _backdoor_depth_cap()
	_fill_rush_constraint(c)
	_current_depth = GoalieDepthSolver.solve(_current_depth, delta, c)


# Has the play actually entered the zone? Depth is solved from the races, but the
# races only bound how far out a THREAT lets him come — they say nothing about a
# puck that is not one yet, and geometry alone would hold him at the ceiling for a
# puck at the far blue line. Gated on the real rink landmark (goal line to blue
# line) rather than an authored distance, so it means "the play is in my end".
func _threat_is_in_zone(threat_dist: float) -> bool:
	return threat_dist <= GameRules.GOAL_LINE_Z - GameRules.BLUE_LINE_Z


# Lateral tracking cap — the anticipatory deke / walkout answer. How far out can
# he come and still stay SQUARE to a carrier taking the puck across? Pure rate
# geometry in GoalieBehaviorRules.lateral_tracking_cap; this gathers the inputs.
#
# The lateral speed is read from the CARRIER's body for a carried puck (audit F7):
# the raw puck estimate includes stickhandling, and a stationary dangler's blade
# routinely beats t_push_speed — a real goalie doesn't sink on a dangle, only on
# genuine carrier / pass lateral motion. Loose pucks (a pass in flight) keep the
# puck read.
#
# The constraint states itself — r <= push · d / v — so there is no pull-per-
# deficit curve here. Metres of retreat per m/s over his push speed would be a
# shape parameter standing in for that geometry (plan doc §4.1, G1).
func _lateral_tracking_cap(threat_dist: float) -> float:
	var carrier: Skater = puck.get_carrier()
	var lateral_speed_x: float = carrier.velocity.x if carrier != null \
			else _puck_velocity_est.x
	return GoalieBehaviorRules.lateral_tracking_cap(
			threat_dist, lateral_speed_x, t_push_speed)


# Rush backflow (audit F5): a CLOSING opposing carrier inside the engage range
# retreats the goalie along the taught curve at a rate MATCHED to the closing
# speed — a real backward C-cut instead of lerp lag. Only engages while genuinely
# closing; a stalled or lateral carrier leaves the constraint unset (INF) and falls
# back to the chart plus the ordinary settle.
func _fill_rush_constraint(c: GoalieDepthSolver.Constraints) -> void:
	c.rush_radius = INF
	c.rush_rate = 0.0
	var carrier: Skater = puck.get_carrier()
	if carrier == null or (team_id != -1 and carrier.get_team_id() == team_id):
		return
	var cdx: float = carrier.global_position.x - _goal_center_x
	var cdz: float = carrier.global_position.z - _goal_line_z
	var cdist: float = sqrt(cdx * cdx + cdz * cdz)
	if cdist >= rush_engage_distance or cdist <= 0.001:
		return
	var closing: float = -(carrier.velocity.x * cdx + carrier.velocity.z * cdz) / cdist
	if closing < rush_min_closing_speed:
		return
	c.rush_radius = GoalieBehaviorRules.rush_retreat_depth(cdist, _rush_cfg)
	c.rush_rate = GoalieBehaviorRules.rush_retreat_rate(cdist, closing, _rush_cfg)


# Move `_current_depth` toward `target` with the exponential settle shaped by
# `depth_speed`, rate-capped at `depth_max_speed` — skating speed in and out
# of the crease is a physical quantity, not a lerp artifact.
func _approach_depth(target: float, delta: float) -> void:
	_current_depth = GoalieDepthSolver.approach(
			_current_depth, target, delta, depth_speed, depth_max_speed)

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
	_ensure_view()
	var cap: float = INF
	for pos in _view.off_puck_opponents:
		cap = minf(cap, GoalieBehaviorRules.backdoor_depth_cap(
				puck.global_position, _tracked_threat_position,
				pos, _goal_line_z, _goal_center_x,
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
			# The arc's perpendicular depth collapses toward the goal line at
			# sharp angles (goalie_z = goal_line + uz * radius, uz -> 0 wide);
			# floor it so the pads stay in front of the line. `_current_depth`
			# (the arc RADIUS) is intentionally not touched — only the realised
			# Z position is clamped, so the next tick keeps tracing the arc.
			new_z = _front_of_line_z(pair.y)
		State.BUTTERFLY:
			# Idle butterfly is a shot-facing stance: never sit so deep the pads
			# straddle behind the goal line. Floor the committed depth itself (not
			# just the final Z) so the slide-commit start depth stays consistent
			# with the rendered position.
			_current_depth = maxf(_current_depth, min_challenge_depth)
			_update_butterfly_five_hole(delta)
			_try_commit_slide(delta)
			# Dropping does not cancel travel: a butterfly entered with lateral
			# speed keeps riding it out, which is what makes a caught-moving
			# goalie slide past the puck rather than stop dead on top of it.
			# Skipped once a slide commits — the slide owns motion from there and
			# captured its own endpoints.
			#
			# Knee shuffle: if instead we're idle butterfly after the slide check
			# (drop complete, not frozen reading a shot), micro-scoot toward the
			# arc target — the small down-movement tier real goalies use constantly
			# in scrambles. Depth holds; the motion is lateral-only and slow, and
			# it feeds the caught-moving read penalty like any movement.
			if _sm.current == State.BUTTERFLY and _reaction.reacting:
				_current_x = _reaction_drift_x(delta, _current_x)
			elif _sm.current == State.BUTTERFLY and _slide.drop_progress >= 1.0:
				var knee_target: Vector2 = GoalieBehaviorRules.target_arc_position(
						_tracked_threat_position, _goal_line_z, _goal_center_x,
						_direction_sign, butterfly_radius, _arc_cfg)
				_current_x = move_toward(_current_x, knee_target.x, knee_shuffle_speed * delta)
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
		State.COVERING:
			# Planted over the puck — no root motion while smothering / holding.
			new_z = goalie.global_position.z
		State.CATCHING, State.CATCHING_DOWN:
			# Squeezing the catch — planted until the freeze or the drop.
			new_z = goalie.global_position.z
		State.PLAYING_PUCK:
			# Free skate along the post-waypoint path (the only movement mode not
			# clamped to the crease arc — the trip routes AROUND the post, never
			# through the net). The collaborator owns the path, the accel ramp and
			# the stride envelope.
			var pp_next: Vector2 = _puck_play.step_toward(
					delta, _current_x, goalie.global_position.z,
					_puck_play.current_target(_current_x, goalie.global_position.z))
			_current_x = pp_next.x
			new_z = pp_next.y
		State.RVH_LEFT, State.VH_LEFT:
			# VH hugs the same post spot — the stance differs (vertical pad,
			# taller body), not the position. `post_seal_inset` is shared with the
			# arc solver so the squared stance converges here rather than jumping.
			_current_x = move_toward(_current_x, _goal_center_x + (net_half_width - post_seal_inset) * _direction_sign, rvh_transition_speed * delta)
			new_z = _goal_line_z + _direction_sign * _current_depth
		State.RVH_RIGHT, State.VH_RIGHT:
			_current_x = move_toward(_current_x, _goal_center_x - (net_half_width - post_seal_inset) * _direction_sign, rvh_transition_speed * delta)
			new_z = _goal_line_z + _direction_sign * _current_depth
		_:
			new_z = _goal_line_z + _direction_sign * _current_depth
	if delta > 0.0:
		_velocity_x = (_current_x - prev_x) / delta
		_velocity_z = (new_z - prev_z) / delta
	goalie.set_goalie_position(_current_x, new_z)

# Clamp a candidate goalie Z so its perpendicular depth in front of the goal
# line is at least `min_challenge_depth` — keeps the pad face ahead of the
# goal-line plane in the shot-facing states. Only the states where sitting on
# the line is wrong call this; post-integrated / slide-seal / behind-net play
# never does (see the export doc-block).
func _front_of_line_z(z: float) -> float:
	# The floor exists for a goalie OUT challenging. Once the arc solve has given
	# up the challenge and converged on the post seal (out_seal_blend -> 1) the
	# correct depth is the seal's own, so fade the floor to it rather than holding
	# him off his line at exactly the angle where sitting on it is the play.
	var floor_depth: float = lerpf(
			min_challenge_depth, minf(rvh_depth, min_challenge_depth), _arc_cfg.out_seal_blend)
	var perp: float = (z - _goal_line_z) * _direction_sign
	if perp < floor_depth:
		return _goal_line_z + _direction_sign * floor_depth
	return z

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
		# Frozen and reading the shot — steering is suppressed, so the next push
		# after the freeze clears starts its ramp from rest. Momentum is NOT
		# suppressed: whatever he was carrying at release rides out as drift.
		_move_speed_current = 0.0
		if is_server:
			_five_hole_openness = lerpf(_five_hole_openness, five_hole_base, part_lerp_speed * delta)
		current.x = _reaction_drift_x(delta, current.x)
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
	# Slapper aim shade (anticipatory read): while reading a committed slot slapshot
	# wind-up, cheat the angle toward where the shot will cross the goalie's depth
	# plane — the real "he's lined it up top-far, I'll shade that way" read (see the
	# slapper_aim_shade export). Ramped by wind-up read time so a quick release keeps
	# the skill window; directional off the LOCKED aim, so a fake shades him wrong.
	# Skipped during a cross-crease push (a pass in flight owns the lateral target).
	if is_server and _reading_planted_windup and not cross_crease_push and slapper_aim_shade > 0.0:
		var shade_carrier: Skater = puck.get_carrier()
		if shade_carrier != null:
			var shade_vel: Vector3 = shade_carrier.predicted_shot_velocity
			if shade_vel.length_squared() >= 0.01 and absf(shade_vel.z) >= 0.001 \
					and _declared_shot_is_on_net(shade_vel):
				var goalie_plane_z: float = _goal_line_z + _direction_sign * _current_depth
				var t_cross: float = (goalie_plane_z - puck.global_position.z) / shade_vel.z
				if t_cross > 0.0:
					# Cover TO the post and no further. Even on a genuine corner
					# aim there is no goaltending reason to travel past the mouth,
					# and the projection is taken at the goalie's depth plane where
					# an aim just inside the post can still solve wide of it.
					var shot_x_at_depth: float = clampf(
							puck.global_position.x + shade_vel.x * t_cross,
							_goal_center_x - net_half_width,
							_goal_center_x + net_half_width)
					var shade_t: float = clampf(
							_shot_read_timer / maxf(prearm_read_time, 0.001), 0.0, 1.0) * slapper_aim_shade
					target_xz.x = lerpf(target_xz.x, shot_x_at_depth, shade_t)
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
			_direction_sign, _current_depth, _arc_cfg)

# Advance the caught-moving drift one tick and return the new lateral position.
# A goalie caught mid-push at the release does not stop dead to make the save —
# he rides his momentum out, and where it puts him is the real cost of being
# unset. Applies to every frozen shot-facing stance (upright and butterfly
# alike), so dropping does not cancel the travel.
#
# Bounded so a long drift can't carry the body past his own pad reach outside the
# post. Beyond that he is out of the play regardless and the clamp only keeps a
# runaway slide off the end boards.
func _reaction_drift_x(delta: float, x: float) -> float:
	if _reaction_drift_vx == 0.0:
		return x
	_reaction_drift_vx = move_toward(
			_reaction_drift_vx, 0.0, lateral_accel * unset_drift_decel_ratio * delta)
	var limit: float = net_half_width + pad_local_offset + butterfly_pad_half_width
	return clampf(x + _reaction_drift_vx * delta,
			_goal_center_x - limit, _goal_center_x + limit)

# Five-hole openness for BUTTERFLY/SLIDING. Server-only — clients adopt the
# server's value via apply_state.
func _update_butterfly_five_hole(delta: float) -> void:
	if not is_server:
		return
	if _slide.drop_progress < 1.0 and _reaction_drift_vx == 0.0:
		# Snap closed during the active drop animation.
		_five_hole_openness = lerpf(_five_hole_openness, 0.0, part_lerp_speed * delta * 2.0)
	elif _sm.current == State.SLIDING or _reaction_drift_vx != 0.0:
		# Trail-leg gap opens with translation speed. A butterfly entered while
		# still carrying a push splays the same way a committed slide does — the
		# trail leg has not caught up — so a goalie who drops mid-travel gives up
		# the five-hole for as long as he is moving, drop animation or not.
		var translation_speed: float = absf(_slide.velocity_x) if _sm.current == State.SLIDING \
				else absf(_reaction_drift_vx)
		var speed_ratio: float = clampf(translation_speed / maxf(slide_initial_speed, 0.01), 0.0, 1.0)
		_five_hole_openness = lerpf(
				_five_hole_openness,
				five_hole_butterfly_move_max * speed_ratio,
				part_lerp_speed * delta)
	else:
		# IDLE BUTTERFLY: pads on the ice, touching at the knees.
		_five_hole_openness = lerpf(_five_hole_openness, 0.0, part_lerp_speed * delta)

# Evaluate slide trigger conditions during idle BUTTERFLY. Host-only (clients
# receive the slide via position broadcast + state RPC).
func _try_commit_slide(delta: float) -> void:
	if not is_server:
		return
	if not _slide.can_commit_slide():
		return
	# Don't slide-track a puck in the defensive zone — RVH path handles it.
	if _is_puck_in_defensive_zone():
		return
	var pad_edge: float = pad_local_offset + butterfly_pad_half_width
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
	# Pad-coverage check — "is there net open to my side that I cannot cover from
	# here", measured as HOW FAR OFF HIS ANGLE HE IS, not how far the puck is to
	# his side. Those are the same thing only for a puck near the net, and wildly
	# different for a shooter out at an angle: raw |puck.x - goalie.x| reads 2.3 m
	# for a stationary shooter 3.2 m off centre whom the goalie is already square
	# to, so it fired the slide on nothing. That is the bug behind the slot-slapper
	# "he drops and slides away from the post during the wind-up" — the drop makes
	# _try_commit_slide reachable, this test then reports a breach that is really
	# just the shooter's angle, and the seal commits.
	#
	# The honest reference is the arc position the threat implies AT THE GOALIE'S
	# OWN RADIUS: square to the threat means zero offset by construction, whatever
	# angle he is being attacked from, and a genuine lateral play (cross-crease
	# feed, walkout, sustained drag) swings that target across the crease and
	# breaches the pad edge exactly as before.
	#
	# Radius comes from his ACTUAL world position rather than `_current_depth`,
	# which carries perpendicular depth in this state and radius in the standing
	# ones — passing it straight to an arc solve is the unit bug `butterfly_radius`
	# exists to sidestep.
	#
	# The carried/loose split below is unchanged in intent:
	#   Carried — use the quiet-eye-smoothed tracked threat, NOT the raw dangled
	#     puck. A stickhandle wiggle swings the puck past the pad edge on every
	#     deke; keying the slide off it made the goalie re-commit little slides
	#     and skate back and forth across the crease chasing jitter.
	#   Loose — project the puck forward via its velocity so a cross-crease pass /
	#     rebound in flight commits the slide early (the back-door seal).
	var carried: bool = puck.get_carrier() != null
	var reference: Vector3
	if carried:
		reference = _tracked_threat_position
	else:
		reference = puck.global_position
		reference.x += _loose_puck_velocity().x * slide_anticipation_time
	var body_dx: float = _current_x - _goal_center_x
	var body_dz: float = goalie.global_position.z - _goal_line_z
	var body_radius: float = sqrt(body_dx * body_dx + body_dz * body_dz)
	var square: Vector2 = GoalieBehaviorRules.target_arc_position(
			reference, _goal_line_z, _goal_center_x, _direction_sign,
			body_radius, _arc_cfg)
	# Still the world X the slide commits TOWARD — _commit_slide_toward only reads
	# its sign to pick the post side, and the seal target is solved there.
	var coverage_x: float = square.x
	var lateral_offset: float = coverage_x - _current_x
	if absf(lateral_offset) <= pad_edge + slide_coverage_buffer:
		_slide_coverage_confirm_timer = 0.0
		return
	# Carried puck: the breach must SUSTAIN for the quiet-eye confirmation
	# before the slide sells out — a forehand→backhand pull crosses the pad
	# line for a few ticks and comes back, and committing on the first
	# crossing is what let a deke send the goalie sliding away from the puck
	# (mid-slide cannot correct, by design). A pass/rebound in flight commits
	# instantly as before — it cannot cut back.
	if carried:
		_slide_coverage_confirm_timer += delta
		if _slide_coverage_confirm_timer < lateral_commit_confirm_s:
			return
	_slide_coverage_confirm_timer = 0.0
	_commit_slide_toward(coverage_x)


# Commit the pivot slide toward `coverage_x` (world X): puck-side post seal
# target, coil endpoints captured, transition to COILING. Shared by the
# butterfly pad-coverage trigger (_try_commit_slide) and the standing
# cross-crease lost-race drop-and-slide (_commit_cross_crease_response).
func _commit_slide_toward(coverage_x: float) -> void:
	var pad_edge: float = pad_local_offset + butterfly_pad_half_width
	var slide_rot: float = deg_to_rad(slide_max_rotation_deg)
	var puck_side: float = signf(coverage_x - _current_x)
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
	# The slide owns lateral motion from here (committed endpoints, own velocity).
	# Drop any caught-moving drift so it can't resume if the slide finishes while
	# the goalie is still frozen on the same read.
	_reaction_drift_vx = 0.0
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
	if _sm.current == State.PLAYING_PUCK:
		# Out playing the puck: face the puck itself, unclamped — behind the net
		# the goalie genuinely turns his back on the rink to make the stop.
		var pdx: float = puck.global_position.x - goalie.global_position.x
		var pdz: float = puck.global_position.z - goalie.global_position.z
		if pdx * pdx + pdz * pdz > 0.01:
			goalie.set_goalie_rotation_y(lerp_angle(
					goalie.get_goalie_rotation_y(), atan2(-pdx, -pdz), rotation_speed * delta))
		return
	if _sm.is_post_integrated():
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
	if _sm.current == State.BUTTERFLY or _sm.current == State.COVERING \
			or _sm.is_catching():
		# Idle butterfly / smother / catch squeeze: hold whatever angle the drop
		# or slide came in at. No animation — real goalies don't rotate the body once down,
		# and the slow lerp toward centre we used to do quietly undid the
		# slide's facing while the goalie was still down.
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
# ── Body-solve LOD ────────────────────────────────────────────────────────────
# The full body solve (_pose.build + the seven-part apply) is 31% of the goalie
# tick — 24.5 µs of 79.9, and 2.6x the next phase. It is also the one phase that
# is provably unobservable at range: the pads, glove, blocker and stick carry
# real colliders, so posing them IS gameplay when the puck can reach, and is
# nothing at all when it cannot. Reach is the stick, about 2 m.
#
# This is not a bot-vs-human carve-out. Goalies are never human, so there is no
# parity to break and no client reconciling one — the saving holds in a bot
# lobby, a full human lobby, and on a dedicated server alike. That last case is
# the point: headless, the control tick is essentially the whole bill.
#
# Waking is deliberately cheap and early. Every other phase keeps running, so
# tracking and the state machine still see the play — and since `reacting` is a
# wake condition, a shot re-arms the solve on the tick it is detected rather
# than waiting on distance at all.
const _BODY_SOLVE_WAKE_M: float = 14.0   # inside this, always solving
const _BODY_SOLVE_SLEEP_M: float = 18.0  # beyond this, suspend
var _body_solve_asleep: bool = false


# True only when this goalie provably cannot interact with anything. Every
# condition is a veto: any activity at all — a live read, a lunge, a clear
# swing, any stance that is not the plain upright one — keeps the solve running
# regardless of range. The distance test is last and hysteretic so the pair of
# thresholds cannot chatter with a puck hovering on the line.
func _suspend_body_solve() -> bool:
	if _reaction.reacting:
		_body_solve_asleep = false
		return false
	if _sm.current != GoalieStateMachine.State.STANDING \
			and _sm.current != GoalieStateMachine.State.READY:
		_body_solve_asleep = false
		return false
	if _lunge_active_timer > 0.0 or _clear.windup_timer > 0.0 or _clear.anim_timer > 0.0:
		_body_solve_asleep = false
		return false
	var dist: float = goalie.global_position.distance_to(puck.global_position)
	if dist < _BODY_SOLVE_WAKE_M:
		_body_solve_asleep = false
	elif dist > _BODY_SOLVE_SLEEP_M:
		_body_solve_asleep = true
	return _body_solve_asleep


func _update_body_parts(delta: float) -> void:
	# Suspended: hold the last pose. The lerp had already converged it to the
	# ready stance well before the puck got this far, so a held pose is the same
	# pose the solve would keep rebuilding — a goalie standing still while the
	# play is at the other end is what it should look like.
	if _suspend_body_solve():
		return
	_pose_inputs.state = _sm.current
	_pose_inputs.five_hole_openness = _five_hole_openness
	_pose_inputs.reading_pinned_windup = _reading_pinned_windup
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
	_pose_inputs.sweep_anim_dir = _clear.anim_dir
	_pose_inputs.sweep_windup_progress = _sweep_windup_progress()
	_pose_inputs.paddle_sweep_active = _is_paddle_sweep_active()
	_pose_inputs.standing_sweep_active = _is_standing_sweep_active()
	_pose_inputs.head_yaw_deg = _desired_head_yaw_deg()
	_pose_inputs.puck_play_stopping = _sm.current == State.PLAYING_PUCK \
			and _puck_play.is_stopping()
	_pose_inputs.puck_play_stride_phase = _puck_play.stride_phase
	_pose_inputs.puck_play_stride_intensity = _puck_play.stride_intensity
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
	elif _sm.current == State.COVERING:
		# Smother collapse paced so the glove lands ~within cover_reach_time
		# (lerp ≈95% at 3/x — matches the drop-snap idiom above).
		lerp_t = (3.0 / maxf(cover_reach_time, 0.001)) * delta
	elif _sm.is_catching():
		# The squeeze snaps in — the puck is already in the glove.
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

# Would the declared shot actually hit the net? The aim shade is a POSITIONAL
# commit — the goalie physically travels toward a predicted crossing — so it has
# to be spent on a shot that is going in.
#
# Without this the shade had no notion of the net existing (#552): aim a slapper
# wind-up deliberately WIDE of the post and the goalie shades up to
# `slapper_aim_shade` (0.7) of the way toward a puck that was never a threat,
# leaving the cage open for the carrier to coast into. The intended counter-play
# — fake him with the declared aim — degenerated into "point at the corner flag
# and walk it in".
#
# Reading a shot heading wide and LETTING IT GO is one of the easiest reads in
# the game, not one of the hardest, so an off-net declaration earns no shade at
# all rather than a reduced one.
#
# Solved at the GOAL LINE, which is where "on net" is a question about. The
# shade's own projection is taken at the goalie's depth plane and cannot answer
# it: a shot crossing his plane inside the posts can still be drifting wide by
# the time it reaches the line.
func _declared_shot_is_on_net(shot_velocity: Vector3) -> bool:
	if absf(shot_velocity.z) < 0.001:
		return false
	var t: float = (_goal_line_z - puck.global_position.z) / shot_velocity.z
	if t <= 0.0:
		return false   # heading away from this net
	var x_at_line: float = puck.global_position.x + shot_velocity.x * t
	return absf(x_at_line - _goal_center_x) \
			<= net_half_width + GameRules.PUCK_COLLISION_RADIUS


# Desired head yaw (degrees, goalie-ROOT-local) toward the raw puck — the head
# tracks the puck itself even when the body plays the smoothed threat; the
# divergence is the real "eyes on the puck, body square" look. Relative to the
# root's CURRENT rotation (the head node is a child), clamped to a human range.
func _desired_head_yaw_deg() -> float:
	var dx: float = puck.global_position.x - goalie.global_position.x
	var dz: float = puck.global_position.z - goalie.global_position.z
	if dx * dx + dz * dz < 0.01:
		return 0.0
	var target_world: float = atan2(-dx, -dz)
	var local: float = angle_difference(goalie.get_goalie_rotation_y(), target_world)
	var max_rad: float = deg_to_rad(head_track_max_yaw_deg)
	return rad_to_deg(clampf(local, -max_rad, max_rad))

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
# Directional lean needs the shooter's predicted velocity, which SkaterController
# publishes for both shot types and every shooter including remotes (the host
# simulates a remote's carry from replicated input).
#
# ONE BELIEF. The lean uses `_lagged_aim()` — the SAME stale sample the release
# read commits to — not the live value. Reading the live aim here makes the goalie
# hold two contradictory ideas about the same shot: at release he believes the aim
# from `read_lag` ago while his hands are already parked on the current one, so
# `read_lag` (the dial governing how WRONG he can be, and the one difficulty
# varies) never reaches his hands. A pre-lean is a read of the shooter's body
# developing, and a body read lags for the same reason the release read does. A
# stable aim through the wind-up leans where it always did (stale == truth), so
# this costs a telegraphed shooter nothing.
#
# ⚠️ Correct for consistency, but SMALL — do not expect it to move outcomes.
# Measured on the swept look-off in test_goalie_disguise_read it buys the shooter
# ~1 cm of extra reach deficit at read_lag 0.05 and ~3 cm at 0.13, on a ~15 cm
# gap, and flips ZERO outcomes. Specifically it does NOT explain why wrong-corner
# deception costs reach without converting at 5-9 m: the arm's budget there is
# simply large (disguised deficit -0.15 m, so the arm covers the gap with 15 cm to
# spare while deception buys 8). If corner deception should pay more, the lever is
# the reach budget, not the read.
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
	# Falls back to the live aim only when there is no history at all (read_lag
	# disabled, or the wind-up is younger than one sample) — otherwise
	# `_lagged_aim` already returns the oldest sample it holds, which is the
	# honest answer for a short wind-up: he can only be as stale as what he saw.
	var vel: Vector3 = _lagged_aim()
	if vel.length_squared() < 0.01:
		vel = carrier.predicted_shot_velocity
	if vel.length_squared() < 0.01:
		return  # not yet published this charge (freshness guard) — non-directional tell
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
	# Tick the human read delay; when it expires the committed response engages
	# (standing drive, or a drop-and-slide when the race is already lost).
	if _cross_crease_react_timer > 0.0:
		_cross_crease_react_timer -= delta
		if _cross_crease_react_timer <= 0.0:
			_cross_crease_react_timer = 0.0
			_commit_cross_crease_response()
	if carrier != null:
		return
	if _reaction.reacting or _sm.is_post_integrated() or _sm.current == State.PLAYING_PUCK:
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
	# Read the pass once, then commit a single delayed response — don't restart
	# the delay or re-arm while a read or drive is already in flight.
	if _cross_crease_timer <= 0.0 and _cross_crease_react_timer <= 0.0:
		if cross_crease_react_delay > 0.0:
			_cross_crease_react_timer = cross_crease_react_delay
		else:
			_commit_cross_crease_response()


# The cross-crease read delay has elapsed — commit the response. Save-selection
# fork (realism audit F3): if the standing push can still arrive before the
# one-timer (puck flight to the crossing + the receiver's release swing — the
# read delay is already spent), drive on the feet and arrive SET, the strong
# outcome. If the race is already lost, standing transit is the wrong posture —
# a real goalie goes pads-first: drop and butterfly-slide toward the crossing,
# arriving late but SEALED along the ice (takes away the low far-side finish
# that beats a late upright T-push). The slide runs the normal pivot machinery
# (coil → push) and the butterfly drop animates DURING the transit — drop-and-
# slide is one motion, as taught. A clean, hard royal-road one-timer still
# scores on either branch; the fork only changes what the near-misses look like.
func _commit_cross_crease_response() -> void:
	var race_lost: bool = _sm.is_upright() \
			and _slide.event_lockout <= 0.0 \
			and GoalieBehaviorRules.cross_crease_race_lost(
					_cross_crease_target_x, puck.global_position.x,
					_loose_puck_velocity().x, _current_x, pad_local_offset,
					backdoor_release_time, t_push_speed, lateral_accel)
	if race_lost:
		# Fresh butterfly entry snaps `_current_depth` to true perpendicular
		# depth (radius→perp unit fix-up in _on_sm_transitioned) before the
		# slide commit captures its coil endpoints.
		_enter_butterfly()
		_commit_slide_toward(_cross_crease_target_x)
		return
	_cross_crease_timer = cross_crease_push_duration

# Maintain the shot-commit window. The goalie is "committed" while it reads a
# charging shot from an opposing slot shooter; the timer lingers
# `prelean_commit_window` seconds after the read so a pass fired at the very end
# of the windup still lands inside it. Consumed by _update_cross_crease.
# Also accumulates the pre-armed read (quiet-eye): a continuous windup read of
# `prearm_read_time` primes the shorter release delays, held through
# `_prime_linger_timer` so the release (which clears the windup state, possibly
# earlier in the same tick) can't race the prime off before _on_puck_released
# consumes it.
func _update_shot_commit(delta: float, carrier: Skater) -> void:
	if _shot_commit_timer > 0.0:
		_shot_commit_timer = maxf(_shot_commit_timer - delta, 0.0)
	if _prime_linger_timer > 0.0:
		_prime_linger_timer = maxf(_prime_linger_timer - delta, 0.0)
	if _is_reading_shot_threat(carrier):
		_shot_commit_timer = prelean_commit_window
		_shot_read_timer += delta
		if _shot_read_timer >= prearm_read_time:
			_prime_linger_timer = prearm_linger
		_push_aim_sample(carrier.predicted_shot_velocity)
	else:
		_shot_read_timer = 0.0
		_aim_history_len = 0
	# Set-and-sighted in the slot: a coiled, upright goalie with an opposing
	# carrier already in tight is pre-programmed to react even without a held
	# windup, so a quick slot release draws a reflex save ATTEMPT instead of
	# freezing him in place (see the prearm doc-block). Refreshed every tick the
	# threat sits in the slot; `prearm_linger` carries the prime across the release
	# tick (which clears the carrier) into _on_puck_released. The movement-read
	# penalty still ADDS on top at _on_puck_released, so a goalie caught scrambling
	# in the slot claws the credit back — only a genuinely set goalie collects it.
	if _is_set_in_slot(carrier):
		_prime_linger_timer = prearm_linger

# True when an opposing carrier in the slot is winding up a shot (the wrister's
# frozen-puck coil or a slapshot charge) close enough that the goalie respects
# it. Drives both the
# pre-lean pose and the shot-commit window. Upright-only and not while already
# reacting — once a shot is in flight the reaction pipeline owns the read. Reads
# only `current_shot_state` (replicated) so it fires for remote shooters too;
# the DIRECTIONAL lean additionally needs the host-side predicted velocity.
func _is_reading_shot_threat(carrier: Skater) -> bool:
	if not _opposing_carrier_in_front(carrier, prelean_max_distance):
		return false
	return carrier.current_shot_state == SkaterStateMachine.State.WRISTER_AIM \
			or carrier.current_shot_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK

# True when a SET, upright goalie has an opposing carrier already in tight (within
# `prime_slot_distance`, in front). Arms the slot-proximity prime — the goalie is
# coiled and reacts reflexively on a quick release rather than freezing. No windup
# state required (that's the point: quick slot snaps are the freeze case). See the
# prearm doc-block for why this is an ATTEMPT enabler, not a save buff.
#
# The set-ness test is the same `_unset_fraction` the read penalty uses, so the
# prime and the penalty cannot disagree about the same body. Being coiled is the
# whole premise of the credit: a goalie still pushing across has neither the
# loaded edge nor the settled sightline that pre-programs the response, so he
# does not collect it.
func _is_set_in_slot(carrier: Skater) -> bool:
	# Geometry first: it early-outs on the common cases (no carrier, own team, not
	# upright, already reacting) without the set-ness solve's sqrt. Per-tick path.
	if not _opposing_carrier_in_front(carrier, prime_slot_distance):
		return false
	return _unset_fraction() <= set_unset_max

# Shared geometric core of the windup read and the slot-proximity prime: `carrier`
# is an opposing puck-carrier in front of the goalie (slot side, not behind the
# net) within `max_dist`, with the goalie upright and not already reacting (once a
# shot is in flight the reaction pipeline owns the read). Reads only replicated
# `global_position` / team so it fires for remote carriers too.
func _opposing_carrier_in_front(carrier: Skater, max_dist: float) -> bool:
	if carrier == null:
		return false
	if _reaction.reacting or not _sm.is_upright():
		return false
	if team_id != -1 and carrier.get_team_id() == team_id:
		return false
	# In front of the goalie (slot side), not behind the net.
	if (carrier.global_position.z - goalie.global_position.z) * _direction_sign <= 0.0:
		return false
	return goalie.global_position.distance_to(carrier.global_position) <= max_dist

# Record one tick of the shooter's published aim. Ring buffer, written in place.
func _push_aim_sample(aim: Vector3) -> void:
	if read_lag <= 0.0:
		return
	if _aim_history.size() < _AIM_HISTORY_CAP:
		_aim_history.resize(_AIM_HISTORY_CAP)
	_aim_history[_aim_history_idx] = aim
	_aim_history_idx = (_aim_history_idx + 1) % _AIM_HISTORY_CAP
	_aim_history_len = mini(_aim_history_len + 1, _AIM_HISTORY_CAP)


# The aim the goalie committed to: the sample from `read_lag` seconds back, or
# the OLDEST one held if he has not been reading that long (a short wind-up means
# a short history — he can only be as stale as what he has seen). Vector3.ZERO
# when there is no usable read at all, which is the honest answer for a release
# with no wind-up: no belief, fall back to observing the puck.
func _lagged_aim() -> Vector3:
	if read_lag <= 0.0 or _aim_history_len <= 0:
		return Vector3.ZERO
	var back: int = mini(int(round(read_lag * Engine.physics_ticks_per_second)),
			_aim_history_len)
	if back <= 0:
		back = 1
	var idx: int = (_aim_history_idx - back) % _AIM_HISTORY_CAP
	if idx < 0:
		idx += _AIM_HISTORY_CAP
	return _aim_history[idx]


# Seed the goalie's BELIEF about where a released shot is going. He sees the
# release itself (the event is unambiguous), so `truth` still decides that a shot
# is happening and when it arrives — but WHERE it is going comes from the stale
# read. A wind-up whose aim never moved yields a belief identical to the truth,
# which is exactly why a telegraphed shot is read as well as it ever was.
# Returns true when a distinct (misled) belief was seeded.
func _seed_read_belief(truth: GoalieBehaviorRules.ShotResult, screen_d: float) -> bool:
	_read_belief_x = truth.impact_x
	_read_belief_y = truth.impact_y
	_read_blend = 1.0 if read_lag <= 0.0 else 0.0
	_read_committed = false
	# Convergence cannot start while the puck is still hidden — nothing to see.
	_read_hold = screen_d
	_read_last_vel = _loose_puck_velocity()
	var aim: Vector3 = _lagged_aim()
	_aim_history_len = 0
	if aim.length_squared() < 0.01:
		_read_blend = 1.0   # no wind-up read to be stale — observe the puck
		return false
	var belief: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot_into(
			puck.global_position, aim, _goal_line_z, _goal_center_x,
			_universal_shot_cfg, _scratch_belief)
	if not belief.is_shot:
		_read_blend = 1.0   # the read was not a shot on net — nothing to commit to
		return false
	_read_belief_x = belief.impact_x
	_read_belief_y = belief.impact_y
	return true


# Advance the belief toward the truth as the puck flies and the goalie actually
# observes it: fully converged after one `read_lag`. Held while screened. A
# trajectory CHANGE mid-flight (a deflection) re-commits him to what he currently
# believes and restarts the convergence — the whole point of a tip is that it
# beats the READ, not the reach, so a tip in tight beats him and one from
# distance does not.
func _advance_read_convergence(delta: float, truth: GoalieBehaviorRules.ShotResult) -> void:
	if read_lag <= 0.0:
		_reaction.update_impact(truth.impact_x, truth.impact_y)
		return
	var vel: Vector3 = _loose_puck_velocity()
	if _read_last_vel != Vector3.ZERO \
			and vel.distance_to(_read_last_vel) > _DEFLECTION_DELTA_M_S:
		# Redirected — he is committed to the old line; re-read from scratch.
		_read_belief_x = lerpf(_read_belief_x, truth.impact_x, _read_blend)
		_read_belief_y = lerpf(_read_belief_y, truth.impact_y, _read_blend)
		_read_blend = 0.0
	_read_last_vel = vel
	# BALLISTIC COMMITMENT. The save is pre-programmed during the fixation and
	# executed without mid-flight correction (quiet-eye: the movement is
	# ballistic), so the belief must survive until he actually commits to it —
	# otherwise the read latency and the motor latency run concurrently, the
	# belief converges while the limb is still waiting on its delay, and a stale
	# read can never bite. Convergence therefore starts only once the reach has
	# actually deployed, and is held while the puck is screened (you cannot refine
	# a read you cannot see).
	# Convergence starts once he has committed the save he BELIEVES IN — whichever
	# limb read governs it, NOT the arm alone. On a believed-LOW read the legs
	# commit at the much shorter leg delay and the arm read never governs anything,
	# so gating on the arm delays the correction past the whole flight and he can
	# never recover from being sold low at any range. He commits early and his eyes
	# keep working; that gap is the race.
	if not _read_committed \
			and (_reaction.shot_timer <= 0.0 or not _reaction.arm_pending()):
		_read_committed = true
	if not _read_committed or _read_hold > 0.0:
		_read_hold = maxf(_read_hold - delta, 0.0)
	else:
		_read_blend = minf(_read_blend + delta / maxf(read_converge_time, 0.001), 1.0)
	# Re-classify as the read converges: a goalie who was sold a low shot and comes
	# to see it rising starts the (late) glove reach rather than staying committed.
	_reaction.update_impact(
			lerpf(_read_belief_x, truth.impact_x, _read_blend),
			lerpf(_read_belief_y, truth.impact_y, _read_blend),
			elevated_threshold, prearmed_reaction_delay)


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
			_goal_line_z, _goal_center_x, _universal_shot_cfg, _scratch_shot)
	if not result.is_shot:
		return
	if debug_goalie_reads:
		print("[goalie %d] universal reaction: puck@%.1f,%.1f vel=%.1f impact_x=%.2f %s" % [
				team_id, puck.global_position.x, puck.global_position.z,
				puck.linear_velocity.length(), result.impact_x,
				"ELEVATED" if result.is_elevated else "low"])
	# No pre-arm on the universal path — a loose puck has no windup to have been
	# reading. The screen/moving penalties apply the same as a release read, and
	# a fully-screened trajectory takes the blocking drop the same way.
	var screen_d: float = _screen_delay(vel)
	var move_d: float = _movement_read_delay()
	# A loose puck has no wind-up to have been reading, so there is no stale
	# belief — he reads the trajectory he can see. Seeding from `result` makes
	# belief == truth and the convergence a no-op.
	_seed_read_belief(result, screen_d)
	_reaction.start(result.impact_x, result.impact_y, result.is_elevated,
			result.reaction_delay, 0.0, screen_d + move_d)
	_maybe_arm_screen_block_drop(screen_d, move_d, 0.0)


# Fully-screened release → BLOCKING save selection (realism audit F4). When the
# worst screener hides the puck for the whole capped window — the goalie
# effectively never sees the release — real doctrine flips from reacting to
# blocking: commit the butterfly on the release READ (base leg delay + the
# caught-moving penalty, but NO screen wait — the goalie drops *because* he
# can't see, he isn't waiting to see) and eat the top-corner exposure that
# blocking concedes. The arm reach still pays the full screen delay (you can't
# reach at what you can't see); only the leg seal goes early. The normal
# `drop_max_time_to_impact` imminence gate is bypassed when the timer fires —
# a screened point shot is exactly the far release that gate normally defers.
func _maybe_arm_screen_block_drop(screen_d: float, move_d: float, back_date: float) -> void:
	if screen_max_extra_delay <= 0.0:
		return
	if screen_d < screen_max_extra_delay - 0.001:
		return
	if not _sm.is_upright():
		return
	_screen_block_drop_timer = maxf(reaction_delay + move_d - back_date, 0.0)


# Screen contribution: gather every body that could hide the puck from the goalie
# (both teams — a D-man screens his own goalie too; ghosted players don't), take
# the grounded occlusion delay for the worst screener, and clamp it to
# `screen_max_extra_delay`. The shooter self-excludes geometrically (they sit at
# the release point, along ≈ 0 < min_along).
func _screen_delay(shot_velocity: Vector3) -> float:
	if screen_max_extra_delay <= 0.0:
		return 0.0
	_ensure_view()
	if _view.screeners.is_empty():
		return 0.0
	var delay: float = GoalieBehaviorRules.screen_occlusion_delay(
			puck.global_position, shot_velocity, goalie.global_position,
			_view.screeners, _screen_cfg)
	return minf(delay, screen_max_extra_delay)


# How unset the goalie is right now, 0..1. Planar speed (lateral + depth motion)
# is the main driver; RECOVERING adds a posture floor (standing up is the least
# ready stance to make a save from). Mid-slide unset is already captured by the
# slide's translation speed.
#
# A committed lunge jab is the same gamble (audit F11): while the stick is
# extended the goalie is out of the play, so a shooter who beats the jab gets a
# fully-unset read — the modeled version of the coaching heuristic that a missed
# committed poke concedes roughly two goals per save.
#
# Single source of truth for "is he set": both the read penalty and the quiet-eye
# prime gate go through here, so the prime can never credit a goalie the read
# penalty is simultaneously calling unset.
func _unset_fraction() -> float:
	return GoalieBehaviorRules.unset_fraction(
			_planar_speed(), _is_scrambling(), _move_read_cfg)


func _planar_speed() -> float:
	return sqrt(_velocity_x * _velocity_x + _velocity_z * _velocity_z)


# Standing up out of a butterfly, or out of the play on a committed lunge.
func _is_scrambling() -> bool:
	return _sm.current == State.RECOVERING or _lunge_active_timer > 0.0


# Caught-unset contribution to the read. For a goalie travelling on his feet this
# is only a residual — the bulk of that cost is the drift carried through the
# freeze. Scrambling keeps a real latency because it has no momentum to carry.
# See the export doc-block and GoalieBehaviorRules.movement_read_penalty.
func _movement_read_delay() -> float:
	return GoalieBehaviorRules.movement_read_penalty(
			_planar_speed(), _is_scrambling(), _move_read_cfg)


# ── Release context for the shot log ─────────────────────────────────────────
# Read once per resolved shot by GameManager, never per tick. Everything here is
# already computed for the goalie's own read; these only stop it being discarded,
# so a logged shot carries the situation that produced it and an empirical xG can
# be fitted from real play (see ShotEvent's release-context block).
func stance() -> int:
	return _sm.current as int


func unset_fraction() -> float:
	return _unset_fraction()


func challenge_radius() -> float:
	return _current_depth


func lateral_x() -> float:
	return _current_x


# How long this shot was hidden from him, at the shot's own pace and geometry.
# Same call his read uses, so the logged value is the one he actually paid.
func screen_delay_for(shot_velocity: Vector3) -> float:
	return _screen_delay(shot_velocity)


# Seconds since the puck last touched him, or -1 if it has not this game. The
# rebound / second-chance discriminator: the logged 0-3 m band is dominated by
# second touches, and without this they are indistinguishable from clean looks.
func seconds_since_last_save() -> float:
	if _last_save_time < 0.0:
		return -1.0
	return maxf(float(Time.get_ticks_msec()) * 0.001 - _last_save_time, 0.0)


# ── Shot Detection ────────────────────────────────────────────────────────────
func _on_puck_released() -> void:
	# Consume any pending lag-comp back-date up front so an early `_sm.is_post_integrated()`
	# return or a no-shot result still clears the field — otherwise the next
	# puck event would inherit stale latency from a previous unrelated release.
	var back_date: float = _pending_reaction_back_date
	_pending_reaction_back_date = 0.0
	# RVH / VH are post-hug coverage with committed poses — no glove reach is
	# wired (they save by geometry: the blocking-stance trade), and the goalie is
	# already committed to the puck-side post. Every other
	# state (STANDING, READY, BUTTERFLY, SLIDING, RECOVERING) supports the
	# elevated-shot arm reach via the body-config builder, so the freeze starts
	# from any of them. Previously this was gated on `is_upright()`, which
	# silently dropped all goalie reactions to shots fired while the goalie was
	# already down — top-corner shots over a butterflied goalie went un-tracked
	# because the reaction freeze never started.
	if _sm.is_post_integrated() or _sm.current == State.PLAYING_PUCK:
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
	# The extra-read sources are split (not summed via a helper) because the
	# screen part also drives the blocking-drop selection, and a pre-armed read
	# (quiet-eye — the goalie was already fixated on this windup) replaces the
	# cold-read baseline on both limbs.
	var release_vel: Vector3 = puck.get_release_velocity()
	var screen_d: float = _screen_delay(release_vel)
	var move_d: float = _movement_read_delay()
	var leg_delay: float = result.reaction_delay
	var arm_cut: float = 0.0
	if _prime_linger_timer > 0.0:
		leg_delay = minf(leg_delay, prearmed_reaction_delay)
		arm_cut = maxf(reaction_delay - prearmed_reaction_delay, 0.0)
	# WHERE he thinks it is going comes from the stale wind-up read; WHEN and
	# WHETHER come from the release he actually saw. A stable aim makes the two
	# identical — a telegraphed shot is read exactly as well as before R1.
	_seed_read_belief(result, screen_d)
	var believed_elevated: bool = _read_belief_y >= elevated_threshold
	_reaction.start(_read_belief_x, _read_belief_y, believed_elevated,
			leg_delay, back_date, screen_d + move_d, arm_cut)
	_maybe_arm_screen_block_drop(screen_d, move_d, back_date)

# Puck just hit a goalie body part. Re-arms the slide lockout so deflections
# don't trigger spurious slides, starts the reaction clear delay, and seals the
# ice if the rebound warrants it — modern butterfly is the rebound-control
# posture (Hockey Canada / OMHA coaching), so after a save off the chest or
# glove the goalie should be down while a live rebound resolves.
#
# ASKS, rather than always dropping — an unconditional seal here is a reflex, not
# a save selection. A chest absorb that deadens the puck at his feet with nobody
# within five metres is not a threat, and being down for it is pure cost: the
# recovery gate then has to undo the posture, and the stand-up out of it is where
# five-hole rebounds come from. `_should_block` prices both cases with what it
# already has — a live rebound closing on him arrives fast, a loose one with an
# opponent arriving gets the contest clock, and a dead puck with nobody near gets
# neither.
#
# The existing recovery gate still decides standing back up. Filters by identity
# since `Puck.puck_touched_goalie` fires on either net's goalie.
func _on_puck_contact(contacted: Goalie) -> void:
	if contacted != goalie:
		return
	_slide.arm_event_lockout()
	_last_save_time = float(Time.get_ticks_msec()) * 0.001
	# A save resolves the read immediately — clear the freeze fast so the goalie
	# can track / slide to the rebound rather than sit frozen while it's in the
	# slot. (The slide event-lockout above still gives a beat before a committed
	# slide, so the goalie doesn't chase an unpredictable fresh deflection.)
	_reaction.arm_clear(true)
	if is_server and _sm.is_upright() and _should_block(0.0):
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
	# Capture the momentum he is carrying into the freeze. `_velocity_x` is last
	# tick's realised lateral speed, which is exactly the body state at release.
	# The freeze suppresses steering, NOT physics: he keeps travelling and bleeds
	# it off over the next few tenths (_reaction_drift_x).
	_reaction_drift_vx = _velocity_x

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
# Signed distance (m) of the puck IN FRONT of the goal line — positive on the
# goalie's play side, negative behind the net. Drives the RVH ↔ VH stance
# family split (VH in front, RVH behind).
func _puck_front_of_goal_m() -> float:
	return (puck.global_position.z - _goal_line_z) * _direction_sign

# Defensive-zone test uses raw puck position, not threat — the goalie reacts
# to where the puck physically is for RVH gating, not the blended chest.
func _is_puck_in_defensive_zone() -> bool:
	return GoalieBehaviorRules.is_puck_in_defensive_zone(
			puck.global_position, _goal_line_z, _goal_center_x,
			_direction_sign, _zone_cfg)
