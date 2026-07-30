class_name RoleContext
extends RefCounted

# Read-only inputs that every role-behavior decide() function consumes.
# Built once per off-puck (and eventually carry) tick by the
# SkaterAgentStateMachine and passed into the role's static decide().
# Roles may not mutate these fields.

var snapshot: WorldSnapshot = null
var self_pos: Vector3 = Vector3.ZERO
var self_velocity: Vector3 = Vector3.ZERO
var team_id: int = 0
var peer_id: int = 0
# Net the bot is attacking (offensive goal). Y is 0.
var attacking_goal_pos: Vector3 = Vector3.ZERO
# Net the bot is defending (own goal). Y is 0.
var defending_goal_pos: Vector3 = Vector3.ZERO
# +1 if own goal sits at +GOAL_LINE_Z (Team 0), -1 otherwise. "Forward"
# (toward attacking goal) along Z is `-own_goal_dir`.
var own_goal_dir: float = 1.0
# TeamBrain anchor for this bot's current slot. May be Vector3.ZERO when
# unassigned (first ticks); roles fall back to self_pos in that case.
var anchor: Vector3 = Vector3.ZERO
# Team-strategy read surface for queries like get_slot(other_peer_id). Holds the
# live TeamBrain in unit tests and the frozen TeamBrainView in production dispatch
# (both are TeamStrategyView) — see docs/ai-threading-plan.md, Phase 3a.
var team_brain: TeamStrategyView = null
# Hysteretic strong-side sign from the brain (+1 = +X side, -1 = -X).
# BREAKOUT outlet roles read this so their strong/weak side matches the
# brain's slot assignment. Defaults to +1 when no brain is wired (tests).
var strong_x: float = 1.0
# Opponent peer_id this defender is assigned to cover ("man-on-threat"),
# from TeamBrain's central threat partition. -1 = unassigned (no brain,
# offensive/neutral state, or a defender outside the backline) — in that
# case defensive roles fall back to their legacy all-opponents minimax.
# Lets the MARK defenders focus on a DISTINCT man so two don't both
# collapse onto the single most dangerous opponent.
var assigned_threat_peer: int = -1
# TeamBrain's shared per-opponent shoot-threat bases (opp peer_id -> surface;
# see TeamBrain.threat_shoot_base_by_opp for the approximation contract).
# MARK's unassigned fallback consumes these as ordering / pruning bounds
# instead of recomputing them per decide. Live reference to the brain's dict;
# empty = no memo (no brain, or no MARK slot live) — compute exactly.
var threat_shoot_base_by_opp: Dictionary[int, float] = {}
# The team's shared transition read (docs/transition-defense-plan.md §4) — who
# is genuinely attacking, who is back, the numbers, backpressure, coverage
# accounting. Live reference to the brain's instance (a frozen copy in
# production dispatch). Never null: an unwired context gets the inert read from
# TeamStrategyView, which reports Mode.NONE and no attackers, so behavior with
# no brain is exactly what it was before the read existed.
var rush_read: AIRushRead = TeamStrategyView.new().get_rush_read()
# Last dispatch's answer to "did I hold my forward stand?" — the incumbent side
# of the pinch read's control hysteresis (AIRoleHelpers.may_hold_forward_stand).
# Reset across a slot change, same contract as prev_role_target.
var prev_held_forward_stand: bool = false
# Peer -> team_id lookup for opponent / teammate filtering. Live dict
# owned by PlayerRegistry; roles read with `dict.get(pid, -1)`. Used to
# be a `Callable`; downgraded to a Dictionary because role decide() and
# its helpers iterate skaters at AI dispatch rate and the Callable.call
# overhead showed up in profiles. Empty dict = nothing resolves (the
# decide() helpers all default to -1 unknown).
var team_id_by_peer: Dictionary = {}
# Smoothed per-peer linear acceleration (m/s² in world XZ), keyed by
# peer_id. Built by SkaterAgentStateMachine from frame-over-frame
# velocity diffs and low-passed for noise. Roles use this to lead
# receivers along `pos + vel·t + ½·a·t²` instead of pure velocity
# extrapolation — a receiver who's turning or just starting to skate
# arrives meaningfully off the constant-velocity prediction over a
# 0.4-0.6 s pass window. Missing entries default to ZERO (no accel
# adjustment) — same behaviour as before this field existed.
var acceleration_by_peer: Dictionary = {}

# Smoothed per-peer HEADING turn rate (rad/s, signed), keyed by peer_id — how
# fast each skater's travel direction is rotating. The passer's receiver-
# commitment read: a receiver mid-cut is hard to lead, so a feed to one is
# priced as riskier in the pass EV (see _pass_variant_ev → pass_miss_prob). A
# running estimate, so confidence builds over time. Missing entries default to
# 0.0 (settled / no penalty) — same behaviour as before this field existed.
var heading_omega_by_peer: Dictionary = {}

# Per-peer attribute-scaled capabilities (AISkaterCaps), keyed by peer_id — every
# player's REAL build (top speed, accel, reach, shot speed, weight/brace), so a
# bot can model a specific teammate or opponent with what they can actually do
# instead of the league average. Memoized by PlayerRegistry (rebuilt only on
# spawn / picker, never per tick) and passed here by live reference, same pattern
# as team_id_by_peer / acceleration_by_peer. Read `caps_by_peer.get(pid, null)`;
# a missing entry (unit tests, unwired) means "fall back to the league default",
# which reproduces the prior behaviour exactly.
var caps_by_peer: Dictionary = {}

# ── Self capabilities (attribute-scaled, this bot only) ───────────────────────
# Populated by SkaterAgentStateMachine from its own AISkaterCaps so the carrier
# scores ITS OWN actions with this bot's real top speed / shot speed instead of
# league defaults. Defaults equal the baseline, so unwired contexts (unit tests)
# keep the prior behaviour. (Cross-player evaluation reads caps_by_peer above.)
var self_max_speed: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
# This bot's real all-direction thrust (Acceleration-scaled max_accel). Feeds
# time_to_arrive's cross-momentum shed cost, so a high-Acceleration build prices a
# redirect (killing sideways momentum to reach a carry candidate) faster than a low one.
var self_max_accel: float = GameRules.DEFAULT_SKATER_THRUST_M_S2
# This bot's lateral-grip multiplier (AISkaterCaps.lateral_grip) — its own
# ETA reads shed cross-momentum at the real perpendicular authority.
var self_lateral_grip: float = 1.0
# Also the upper clamp on this bot's distance-adaptive pass launch speed.
# This bot's own aim-execution spread (radians, worst-case): the per-release
# sampled aim error over the blade aim arm. The shot-aim model reserves this
# much of the net's entry width so a corner snipe's error spreads into
# net/miss, not into the post band, and the shot SCORE demands the same as
# extra window (the fit inset in _hole_open_angle) — a wobblier hand needs a
# wider opening for the same chance, so spread shapes shot selection too.
# 0 for an error-free (test/raw) agent.
var self_aim_spread_rad: float = 0.0
# This bot's own PASS release-direction error (radians): the pass counterpart of
# self_aim_spread_rad, from BotSkillProfile.pass_aim_error_rad. Drives the
# derived pass-miss probability (AIActionScoring.pass_miss_prob) — projected to
# the tape over the pass distance, it sets how often a clear-lane feed still
# fumbles, so a wobblier-handed bot's long feeds carry more risk. 0 for an
# error-free (test/raw) agent — the pass miss then collapses to the base floor.
var self_pass_aim_error_rad: float = 0.0
# This bot's shot release-timing variance (max seconds LATE —
# BotSkillProfile.shot_timing_error_s; execution samples uniform [0, max]).
# The carrier's own shot evals hand the goalie the EXPECTED lateness
# (× 0.5, the mean of that draw), scoring each shot at its median release:
# a window thinner than the median slop zeroes out through the hole
# geometry, one around it is attempted and converts only when the sampled
# delay lands early enough — the honest counterpart of the aim spread, on
# the WHEN axis instead of the WHERE. 0 for a tick-perfect (test/raw) agent.
var shot_timing_error_s: float = 0.0
var self_wrister_shot_speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
# This bot's blade toe cap (tan — curve gear), so its own HIGH-hole pricing
# knows its real minimum roofing distance (AISkaterCaps.loft_tan_max).
var self_loft_tan: float = 1.0
# This bot's body-check delivery (mass-emergent) and current stagger, so the
# on-puck defensive roles (PRESSURE / FORECHECK F1) can decide whether a check
# is worth committing to via AIBodyCheck. League baselines / 0 when unwired.
var self_weight: float = 1.0
var self_body_check_transfer: float = 0.45
var self_stagger_timer: float = 0.0
# This bot's own Hands-scaled carry-handle reach — how tight an evasion seam it
# can thread (best_evade_point). League default when unwired.
var self_handle_reach: float = 0.9
# This bot's real blade reach (stick + blade, attribute-scaled) — the physical
# "one stick length" unit the rush gap ladder is expressed in, so a long-stick
# defenseman legitimately plays a hair wider gap.
var self_blade_reach: float = SkaterAgentStateMachine.BLADE_REACH_M
# This bot's blade reach cone half-angle (ROM + torso twist) and Agility-scaled
# facing turn rate — how the carrier prices the rotation an out-of-cone aim costs
# (_facing_rotation_time). A shot/pass anywhere inside the cone is free (no body
# turn); only the narrow back wedge pays, at this turn rate. League defaults when
# unwired (unit tests) reproduce the prior scoring.
var self_reach_cone_half_angle: float = deg_to_rad(157.0)
var self_facing_turn_rate: float = 6.0
# Release-offset sampling inputs (carrier shoot-now eval): the Hands-scaled blade
# traverse speed (relocating the puck across the envelope costs offset/speed of
# extra goalie-tracking time), the backhand power coefficient (a backhand-side
# release fires at this fraction of the wrister pace), and the handedness
# perpendicular sign orienting which lateral side IS the forehand (matches
# SkaterAgentStateMachine._handedness_perp_sign: -1 right-handed, +1 left).
# League/RH defaults when unwired.
var self_blade_speed: float = 10.0
var self_backhand_power_coefficient: float = 0.75
var self_forehand_perp_sign: float = -1.0

# ── Difficulty pace knobs (from BotSkillProfile, this bot only) ───────────────
# Set by SkaterAgentStateMachine each tick from the applied skill profile.
# Defaults are the no-op baseline, so unwired contexts (unit tests, perfect bot)
# behave exactly as before these existed.
# Extra metres PRESSURE drops its cut-off line back toward our net (pressure.gd).
var pursuit_standoff_m: float = 0.0
# Multiplier on this bot's own pass launch speed (carrier.gd own-pass sites).
var pass_speed_scale: float = 1.0
# How hard the on-puck pressurer hunts body checks. 1.0 = today; 0.0 = never
# commits a check (pure containment). Consumed in evaluate_body_check.
var check_aggression: float = 1.0
# Multiplier on DEFENSIVE_ANTICIPATION_S — how much the backline leads a moving
# man. 1.0 = today; lower = defenders sit a step behind (more space). lead_threat.
var defensive_anticipation_scale: float = 1.0
# Seconds after gaining possession during which the carrier may only CARRY —
# no SHOOT / PASS / DUMP commit until the puck has "settled on the tape".
# 0.0 = today's instant release. Consumed by AIRoleCarrier's settle window.
var carry_settle_delay_s: float = 0.0
# COGNITION gate: false = this bot models the goalie as always SET — the
# unsettled re-square race is invisible to its pass / one-timer EV
# (carrier._goalie_unsettled_at returns 0). The aim-side half of the same gate
# (across-the-grain velocity projection) lives on the state machine, which owns
# the aim. True = the perfect-bot / Hard read.
var reads_goalie_motion: bool = true
# COGNITION gate: false = the carrier never values a play that doesn't exist
# yet (carrier._best_developing_feed returns 0) — no protecting the puck for a
# staging finisher or an opening outlet. True = the perfect-bot / Hard read.
var holds_for_developing_feeds: bool = true
# COGNITION gate: false = this bot is blind to receiver commitment — it prices
# a feed to a hard-cutting receiver identically to one skating a straight line
# (heading_omega read as 0 in the pass EV), so it chucks passes at turning
# players (a newcomer-beatable flaw). True = it reads the receiver's turn and
# waits for the settle before feeding (the Normal / Hard read).
var reads_receiver_commitment: bool = true
# COGNITION gate: false = the rush gap defender (RUSH_D1) sees only the
# carrier and retreats on the carrier→net line; true = it reads the carrier's
# passing options and splits toward an uncovered receiver's feed lane — the
# 2-on-1 "play the pass" doctrine (AIRoleRushD's lane fan).
var plays_rush_pass_lanes: bool = true
# COGNITION gate: true = the carrier shields the puck with its body — under
# pressure the blade pulls the puck to the protected side of the reachable-set
# seam (carrier protect_offset/protect_gain, consumed by the state machine's
# carry mouse aim) and the poke-evade deke cuts toward the seam instead of a
# blind perpendicular. False = today's naive forward carry (the puck stays
# presented ahead of the body — the easy pickpocket a newcomer needs).
var protects_the_puck: bool = true

# ── Smart-ping directive (a human teammate's tactical order) ──────────────────
# Populated per dispatch from TeamBrain.ping_* (AIPingDirectives). Defaults are
# the no-op baseline so unwired contexts (unit tests) behave exactly as before.
# GO_THERE steering override for THIS bot; Vector3.INF = none. The off-puck
# state machine replaces RoleDecision.target_position with it.
var ping_move_target: Vector3 = Vector3.INF
# A live SHOOT ping on this bot while it carries — the carrier multiplies its
# shoot EV by AIRoleCarrier.PING_SHOOT_EV_MULT.
var ping_shoot_active: bool = false
# The pinger of a live PASS_TO_ME / IM_OPEN ping (-1 none) — the carrier
# multiplies that receiver's pass EV by AIRoleCarrier.PING_PASS_EV_MULT.
var ping_pass_target_peer: int = -1

# Physics ticks per AI dispatch (decide() call). 1 = the perfect-bot default /
# every-physics-tick; higher at lower difficulty tiers. Roles that track real
# time (e.g. the carrier's re-eval cadence + hold-decay clock) must scale their
# per-call tick math by this so wall-clock durations don't stretch with the tier.
var dispatch_period_ticks: int = 1

# The target_position this bot's role chose on its PREVIOUS dispatch, or
# Vector3.INF when there is none (first dispatch, or the slot changed since —
# the state machine stamps INF across a slot change so no role inherits
# another role's target). Roles that pick their target by candidate argmax
# use it for switch-hysteresis: keep the standing target unless a fresh
# candidate beats it by a real margin, so two near-tied candidates can't
# trade places every dispatch and oscillate the bot between them (see the
# shared AIRoleHelpers.append_incumbent / incumbent_bonus / TARGET_SWITCH_MARGIN).
var prev_role_target: Vector3 = Vector3.INF

# The man this bot's zone role locked last dispatch (RoleDecision.
# locked_man_pid round-tripped by the state machine; -1 = none / role
# changed). The soft-lock's area-boundary hysteresis keys on it.
var prev_locked_man: int = -1

# Whether the match's ruleset enforces offsides (ARCADE ghost / NHL delayed —
# both void an in-zone-early receiver until he tags up at the blue line; only
# the OFF ruleset plays cherry-pickers as live threats). Read by the counter-
# channel build: an offside-positioned opponent's outlet gain clamps to his
# blue line (his earliest legal touch). Stamped per ctx build from the state
# machine's latched rule_set.
var offsides_enforced: bool = true

# ── 5v5 position identity ────────────────────────────────────────────────────
# Latched match team size (TeamBrain.team_size). Gates the 5v5-only reads
# (transition exposure) — 3v3 behavior is untouched at 3.
var team_size: int = GameRules.DEFAULT_TEAM_SIZE
# Whether this bot's lobby position is a defenseman (LD/RD), and its home
# side sign (-1 = left, +1 = right, 0 = center). Feed the defensive-
# responsibility anchor (AIZoneCoverage.defensive_anchor).
var self_is_defense: bool = false
var self_home_side: float = 0.0

# ── Reusable scratch buffers (not inputs) ────────────────────────────────────
# The SkaterAgentStateMachine reuses one RoleContext across dispatches, so the
# collect_* helpers fill these buffers instead of allocating fresh arrays at AI
# dispatch rate (~60 Hz per off-puck bot). Each helper clears its buffer before
# filling, and each buffer is consumed at most once per decide(), so reuse is
# safe. Roles must go through the collect_* helpers — never read stale contents
# directly. Vector3 results escape decide() only as value-type copies, never as
# retained array references, so the buffers are free to be overwritten next call.
var scratch_opp_positions: Array[Vector3] = []
var scratch_opp_states: Array[SkaterNetworkState] = []
# AISkaterCaps index-matched to scratch_opp_positions/_states (entries may be
# null), filled by collect_opponents so defensive ETAs read each opponent's real
# top speed. A null entry / short buffer means the league default.
var scratch_opp_caps: Array[AISkaterCaps] = []
# Peer ids index-matched to scratch_opp_positions, filled alongside it by
# collect_opponents (MARK's fallback keys the brain's threat memo by pid).
var scratch_opp_ids: Array[int] = []
var scratch_teammates: Array[Vector3] = []
var scratch_opp_receivers: Array[Vector3] = []
# Counter-threat states + index-matched caps for fill_counter_channels — the
# ATTACKER-FILTERED subset of the opponents (AIRoleHelpers.collect_counter_threats).
# Separate from scratch_opp_* because the O-zone stations need both at once: the
# full opponent list for their shot-lane reads, the filtered one for their
# race-home bound.
var scratch_counter_states: Array[SkaterNetworkState] = []
var scratch_counter_caps: Array[AISkaterCaps] = []
# Per-decide option-value upper bounds for the pruned carrier_best_option
# (see AIRoleHelpers.carrier_option_bases).
var scratch_option_bases: Array[float] = []
