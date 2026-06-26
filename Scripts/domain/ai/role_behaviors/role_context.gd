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
# Lets ANCHOR / COVER focus on a DISTINCT man so two defenders don't both
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

# ── Self capabilities (attribute-scaled, this bot only) ───────────────────────
# Populated by SkaterAgentStateMachine from its AISelfCapabilities so the
# carrier scores ITS OWN actions with this bot's real top speed / shot speed
# instead of league defaults. Defaults equal the baseline, so unwired contexts
# (unit tests) keep the prior behaviour. Cross-player evaluation (a receiver's
# shot, an opponent's ETA) deliberately stays on the default constants — see
# AISelfCapabilities.
var self_max_speed: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
# Also the upper clamp on this bot's distance-adaptive pass launch speed.
var self_wrister_shot_speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S

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
var scratch_teammates: Array[Vector3] = []
var scratch_opp_receivers: Array[Vector3] = []
