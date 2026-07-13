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
# TeamBrain reference for queries like get_slot(other_peer_id).
var team_brain: TeamBrain = null
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
# Also the upper clamp on this bot's distance-adaptive pass launch speed.
# This bot's own aim-execution spread (radians, worst-case): the output-cursor
# noise over the blade aim arm. The shot-aim model reserves this much of the
# net's entry width so a corner snipe's wobble spreads into net/miss, not into
# the post band, and the shot SCORE demands the same as extra window (the fit
# inset in _hole_open_angle) — a noisier hand needs a wider opening for the
# same chance, so spread shapes shot selection too. 0 for a noiseless
# (test/raw) agent.
var self_aim_spread_rad: float = 0.0
var self_wrister_shot_speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
# This bot's body-check delivery (Size + Physical) and current stagger, so the
# on-puck defensive roles (PRESSURE / FORECHECK F1) can decide whether a check
# is worth committing to via AIBodyCheck. League baselines / 0 when unwired.
var self_weight: float = 1.0
var self_body_check_transfer: float = 0.45
var self_stagger_timer: float = 0.0
# This bot's own Hands-scaled carry-handle reach — how tight an evasion seam it
# can thread (best_evade_point). League default when unwired.
var self_handle_reach: float = 0.9
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
# trade places every dispatch and oscillate the bot between them (see
# AIRolePressure.TARGET_SWITCH_MARGIN).
var prev_role_target: Vector3 = Vector3.INF

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
var scratch_teammates: Array[Vector3] = []
var scratch_opp_receivers: Array[Vector3] = []
