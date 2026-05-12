class_name SkaterAgentStateMachine
extends RefCounted

# Per-bot AI state machine. Mirrors the dispatch + match + per-state handler
# pattern used by Scripts/controllers/skater_state_machine.gd. Owned by
# SkaterAgent; the agent owns the InputState scratch buffer and the
# AIController glue, the SM owns identity + state transitions + per-state
# behavior.
#
# Adding a new behavior (PASS, PROTECT, etc.) is a clean four-step recipe:
#   1. Append a State enum value
#   2. Add a match arm in dispatch()
#   3. Write the _state_<name> handler
#   4. Decide where the transition into it happens (usually a transition
#      check inside _state_carry)
#
# State graph (today):
#                          ┌─ no puck ─────────────────────┐
#                          │                               │
#       OFF_PUCK ◄──────────► CHASE_PUCK (F1 only) ────────│
#          │                       │                       │
#          │  picks up puck        │  picks up puck        │
#          ▼                       ▼                       │
#         CARRY ──[in OZ + quiet-eye expired]──► SHOOT_PRESSED
#          ▲                                          │
#          └──────────────────────────────────────────┘
#                  (next tick, release fires)

enum State {
	OFF_PUCK,         # default off-puck — anchor from brain slot
	CHASE_PUCK,       # loose-puck chase — pursue, blade on the puck
	CARRY,            # with puck, no committed action — aim at goal
	SHOOT_PRESSED,    # multi-tick wrister charge aimed at goalie shadow
	SLAPPER_PRESSED,  # multi-tick slapper charge — bigger commit, more power
	PASS_PRESSED,     # one-tick press window aimed at a teammate's lead position
}

# Margin from the goal line that anchors are clamped inside of. The
# matching X-inset lives on AIRoleHelpers.RINK_INSET_M (single source).
const RINK_Z_INSET: float = 1.0

# After CARRY's `_pick_action` chooses an action (PASS / SHOOT /
# SLAPPER), the bot doesn't transition immediately — it pre-aims by
# setting the mouse target to the action's aim direction and waits
# for the motion-limited mouse to converge before firing. Without
# this, the action state's first tick fires with the mouse still
# mid-traversal from CARRY's previous target, so quick-shot
# direction (PASS) and slapper locked-direction end up at whatever
# angle the mouse happened to be at.
#
# AIM_CONVERGED_DIST_M is the distance threshold treated as
# "converged" — must be larger than the per-tick step
# (MOUSE_MAX_SPEED_M_S * MOUSE_TICK_DELTA = 0.0625 m at 240 Hz)
# plus mouse noise (MOUSE_NOISE_STD_M = 0.02 m) so the bot doesn't
# get stuck oscillating just inside the threshold.
#
# INTENT_MAX_WAIT_TICKS is a safety timeout: after this many ticks
# of waiting, fire anyway. A receiver who keeps moving might never
# let the mouse "fully" converge; the timeout keeps the bot from
# pre-aiming forever. Bumped from 60 → 180 (250 ms → 750 ms) to
# accommodate facing rotation: a 180° back-pass needs ~520 ms for
# the body to rotate (per BOT_FACING_ROTATION_RATE_RAD_S), so the
# old 250 ms cap fired the press before the body finished rotating
# and the puck went out the ROM edge instead of at the receiver.
const AIM_CONVERGED_DIST_M: float = 0.15
const INTENT_MAX_WAIT_TICKS: int = 180   # ~750 ms at 240 Hz
# Aim wobble cones (half-angle). Bots fire perfectly past the goalie
# shadow without these — robotic, every shot to the same spot.
# Wobble is rolled once at shot/pass commit so the aim is consistent
# through the wind-up; the actual offset is a lateral perpendicular
# nudge whose magnitude scales with distance × tan(angle). 3° at a
# 5 m slot shot ≈ 26 cm of lateral drift, enough to push some shots
# wide and produce different results from the same setup tick.
# Passes get a tighter cone — a missed pass is more visible than a
# missed shot.
const SHOT_AIM_WOBBLE_CONE_DEG: float = 3.0
# Passes get a much tighter cone than shots. A missed pass is more
# visible (puck goes past the receiver into open space) and humans
# don't randomly mis-aim a pass to a teammate within stick reach the
# way they might mis-aim a contested shot. Set near zero so pass
# accuracy is essentially perfect; the only natural pass error
# remaining comes from the bot firing before the mouse fully
# converges to the aim, plus receiver-lead inaccuracy.
const PASS_AIM_WOBBLE_CONE_DEG: float = 0.3
# Goalie shadow half-width on the net plane lives on
# AIActionScoring.GOALIE_SHADOW_HALF_M (single source).
# After a puck-engagement event (we got stripped, or we just stripped
# someone — both detected as "puck became loose while we were close"),
# pull the blade back to our body for this many ticks. Speed-scaled:
# a bot at full skating speed was committed harder and takes longer
# to reset; a slow bot recovers quickly. The variance breaks lockstep
# between two bots involved in the same engagement (their speeds are
# almost never identical). Speed reference comes from
# AIActionScoring.SKATER_REF_SPEED_M_S (single source).
const ENGAGEMENT_COOLDOWN_MIN_TICKS: int = 24    # ~100 ms at 240 Hz
const ENGAGEMENT_COOLDOWN_MAX_TICKS: int = 96    # ~400 ms at 240 Hz
const ENGAGEMENT_PROXIMITY_M: float = 2.0        # blade-on-puck range

# Reference top skating speed for chase intercept lookahead lives in
# AIActionScoring (`SKATER_REF_SPEED_M_S`) so it's a single source of
# truth across role behaviors + chase logic. Reference it directly
# below where needed.

# Cap on lead lookahead so a barely-moving puck doesn't project an
# intercept point a million seconds away.
const CHASE_MAX_LOOKAHEAD_S: float = 1.5
# Steps per chase trajectory walk. Granular enough that the rink clamp
# catches a sliding puck hitting the boards mid-flight (so we don't aim
# at a point inside the wall), cheap enough at 6 Hz brain tick.
const CHASE_TRAJECTORY_STEPS: int = 12
# Angling: when chasing an opposing CARRIER (not a loose puck), shift
# the intercept point this far toward center-ice so the bot approaches
# from the inside and forces the carrier toward the boards. Real
# defenders don't chase straight-line at the puck — that lets the
# carrier cut to the middle. Skipped when the carrier is already near
# center (no inside to take away). The bias is capped at the carrier's
# own X magnitude so we never overshoot to the wrong side.
const CHASE_ANGLE_BIAS_M: float = 1.5

# Soft-hands reception. When closing on a loose puck moving faster
# than SOFT_HANDS_PUCK_SPEED_MIN_M_S (i.e. an incoming pass / stripped
# puck), AND we're within SOFT_HANDS_DISTANCE_M of the intercept
# point, the chase input is scaled by SOFT_HANDS_MOVE_SCALE. The bot
# arrives at the intercept at a fraction of normal speed instead of
# plowing into the puck at top speed — gives the blade time to be
# steady when the puck arrives so it catches rather than deflects.
# Tuning: raise SOFT_HANDS_PUCK_SPEED_MIN_M_S toward 12 if soft-
# hands fires on slow loose pucks the bot should just collect at
# speed; lower toward 5 if it's failing to soften on slow passes.
# Lower SOFT_HANDS_MOVE_SCALE toward 0.2 for an even stronger catch
# (risk: opp swoops in); raise toward 0.6 if reception still feels
# clattery.
const SOFT_HANDS_PUCK_SPEED_MIN_M_S: float = 8.0
const SOFT_HANDS_DISTANCE_M: float = 1.5
const SOFT_HANDS_MOVE_SCALE: float = 0.4

# CARRY blade aim distance (m forward in goal direction). Mouse on the
# goal plane (25+ m away) was useless for stickhandling: a 0.3 m
# lateral blade shift would need a ~22 m mouse offset. Putting mouse
# at 2 m forward keeps the blade IK at a comfortable position
# (within ROM, not at the clamp extreme) where small mouse shifts
# translate directly to blade movement. Body facing still tracks
# toward the attacking goal because the forward direction IS the
# goal direction.
const CARRY_BLADE_AIM_FORWARD_M: float = 2.0

# Minimum rink-side margin for the carry mouse target relative to the
# attacking goal line. Without this clamp, a carrier within 2 m of
# the goal line gets a mouse target that sits PAST the goal line —
# the blade IK extends through the net, the puck attached to the
# blade gets pushed into the goalie, rebound, repeat. The buffer
# distance lives on AIRoleHelpers.GOAL_LINE_BUFFER_M (single source).

# Stickhandling: shift the carrier's mouse perpendicular to facing,
# AWAY from the closest incoming defender. Pulls the puck off-side
# from where the defender is reaching. Defenders beyond
# STICKHANDLE_THREAT_RADIUS_M or moving slower than
# STICKHANDLE_CLOSING_VEL_MIN_M_S don't trigger an offset (they're
# not really threats). Magnitude scales linearly with proximity —
# closer threat → larger evade. Per-tick smoothing happens
# automatically via `_step_mouse_toward` (the unified motion model);
# no need for offset-specific lerping.
const STICKHANDLE_THREAT_RADIUS_M: float = 4.0
const STICKHANDLE_CLOSING_VEL_MIN_M_S: float = 1.0
const STICKHANDLE_OFFSET_MAX_M: float = 0.5

# Offsides hold / tag-up: how far on the NZ side of the OZ blue line
# the carrier holds (waiting for teammates to clear) and the offside
# tag-up target sits. Slightly past the line so the host's
# InfractionRules.has_tagged_up doesn't oscillate at the boundary.
const OFFSIDE_HOLD_BUFFER_M: float = 1.0

# Lead time for the carrier endpoint of the shot-lane repel. Off-puck
# bots step out of the FUTURE shooting lane, not the current one — by
# the time our steering moves us, the carrier has skated forward and
# the lane has rotated. Short window; long leads put the lane in the
# wrong zone entirely.
const SHOT_LANE_LEAD_TIME_S: float = 0.25

# Blade-reach radius. Inside this distance the bot's stick can already
# reach the puck where it actually is, so the blade IK should aim at
# the puck's CURRENT position instead of the lead intercept — otherwise
# the blade rides 0.5 m past a puck that's right at our feet and we
# fan on it. Steering still uses the lead so the body keeps closing.
# A bit larger than blade_length + stick_length (≈1.6 m) so the snap
# kicks in slightly before the blade actually arrives.
const BLADE_REACH_M: float = 1.8

# ── Wrister charge ───────────────────────────────────────────────────────────
# SHOOT_PRESSED runs a real wrister now: hold shoot_held for this many
# ticks while sweeping the mouse, then release. ~250 ms gives a solid
# wrister (charge_distance ≈ 1.0 of max 2.0, well past quick_shot_threshold).
const BOT_WRISTER_CHARGE_TICKS: int = 60
# Target accumulated charge_distance at release. SkaterController.
# max_wrister_charge_distance defaults to 2.0; we aim for half — past
# the quick-shot threshold (0.2), comfortable power (lerp ≈ 50%).
const BOT_WRISTER_TARGET_CHARGE: float = 1.0
# Per-tick mouse_screen_pos delta along the sweep direction.
# tick_wrister_charge multiplies screen delta by 0.01 * mouse_sensitivity
# to get world-space accumulation, so this works out at sens=1.0; hosts
# with non-default sens see a 2x range, which the target charge headroom
# absorbs.
const BOT_WRISTER_SCREEN_DELTA_PER_TICK: float = (
		BOT_WRISTER_TARGET_CHARGE / BOT_WRISTER_CHARGE_TICKS / 0.01)
# Mid-charge bail radius. If an opponent gets inside this distance
# while we're charging, cancel via block_held — getting blasted in the
# slot mid-windup is worse than not shooting. The carry state can re-
# evaluate next tick (probably picks PASS or stays in CARRY).
const BOT_WRISTER_BAIL_RADIUS_M: float = 2.0
# Lookahead used to score a wrister at COMMIT time. The shot fires
# ~250 ms after we decide to take it; defenders can move 1.0–1.5 m in
# that window. Score against predicted opponent positions so a
# defender about to step into the lane reads as a blocked lane now,
# instead of us committing and bailing later.
const BOT_WRISTER_LOOKAHEAD_S: float = (
		float(BOT_WRISTER_CHARGE_TICKS) / 240.0)
# Forehand wind-up offset for the visible blade sweep. mouse_world_pos
# at tick 0 sits BOT_WRISTER_WIND_UP_BACK_M behind the bot along
# (-aim_dir) and BOT_WRISTER_WIND_UP_SIDE_M to the forehand side
# perpendicular to aim_dir. Across the charge it lerps to the aim
# point, so the blade IK draws the stick back-and-to-the-handed-side
# then sweeps through the puck. Also forces the entry blade pose to
# the forehand side (wrister_start_blade_local_x captured at WRISTER_AIM
# entry), so SkaterController doesn't classify the shot as backhand
# and apply the backhand_power_coefficient penalty.
const BOT_WRISTER_WIND_UP_BACK_M: float = 0.6
const BOT_WRISTER_WIND_UP_SIDE_M: float = 0.4

# Release-point forward distance for the wrister swing. The lerp's
# FORWARD endpoint sits this far ahead of the bot — not at the actual
# far aim point — so the lateral wind-up offset stays geometrically
# meaningful at release (a 0.4 m side offset at 30 m is 0.76°,
# invisible; at 1.5 m it's 15°, a clear forehand pose). Aim direction
# is geometrically compensated below so the resulting shot still
# lands on clean_aim despite the lateral offset.
const BOT_WRISTER_RELEASE_FORWARD_M: float = 1.5

# Side-selection for wrister wind-up — defender within this radius
# AND clearly on the forehand side flips the wind-up to backhand. The
# 1.5 m radius matches stick-reach for a poke check. The lateral
# threshold ensures we only flip when the defender is laterally on
# the forehand side, not directly in front (where the forehand still
# clears their stick).
const BOT_FOREHAND_STICK_REACH_M: float = 1.5
const BOT_FOREHAND_LATERAL_THRESHOLD_M: float = 0.3

# ── Unified mouse motion ─────────────────────────────────────────────────────
# Every state's `input.mouse_world_pos` goes through `_step_mouse_toward`,
# which simulates a real player's mouse motion with a max speed and
# small per-tick noise. This replaces a pile of per-state smoothing
# (smoothed aim direction, ik_gate clamp, smoothed stickhandle
# offset, etc.) with one consistent model:
#
#   target → "where the mouse would be if you moved toward it for
#             one frame, capped at MOUSE_MAX_SPEED_M_S, with noise"
#
# Real human mice move at 5-20 m/s in world terms (depending on
# sensitivity / situation). 15 m/s lets a 6 m anchor flip resolve in
# 0.4 s — fast enough to look responsive, slow enough that per-tick
# target oscillations average out (mouse never reaches either
# extreme, settles in the middle).
#
# Per-tick noise of 0.02 m std (uniform [-0.02, +0.02]) on each of x
# and z gives small organic wiggle. Doesn't accumulate (applied to
# the OUTPUT only — the underlying _mouse_pos stays smooth).
const MOUSE_MAX_SPEED_M_S: float = 15.0
const MOUSE_NOISE_STD_M: float = 0.02
# Bots run at the host physics rate (240 Hz) so we can use a fixed
# delta. Using a constant keeps the mouse motion deterministic and
# avoids threading delta through every state handler call.
const MOUSE_TICK_DELTA: float = 1.0 / 240.0

# ── Slapper ──────────────────────────────────────────────────────────────────
# Bots take slappers when they have meaningful clean space to wind up.
# SkaterController.slapper_wind_up_time = 0.3 s and max_slapper_charge_time
# = 0.7 s, so 0.55 s is past wind-up + ~62% into the charge window — a
# solid mid-power slapper. Total commit is ~530 ms vs 250 ms wrister,
# so the bot is exposed for longer; mid-charge bail uses a wider radius
# to bail before a closing defender disrupts the windup.
const BOT_SLAPPER_CHARGE_TICKS: int = 132   # 0.55 s at 240 Hz
const BOT_SLAPPER_BAIL_RADIUS_M: float = 2.5
const BOT_SLAPPER_LOOKAHEAD_S: float = (
		float(BOT_SLAPPER_CHARGE_TICKS) / 240.0)

# ── Owned state ──────────────────────────────────────────────────────────────
var _state: State = State.OFF_PUCK
var _ticks_in_state: int = 0

# Identity / orientation
var _peer_id: int = 0
var _team_id: int = 0
# +1 if own goal is at +GOAL_LINE_Z (Team 0), -1 for Team 1.
# See LocalController.get_attacking_goal_z for the source of truth.
var _own_goal_dir: float = 1.0
var _attacking_goal_pos: Vector3 = Vector3.ZERO
var _team_brain: TeamBrain = null
var _team_id_resolver: Callable = Callable()
# Handedness drives the wrister wind-up side: RH winds up on the +X
# (player-local) side of the aim line, LH on -X. Without this, every
# bot wrister would register as a backhand half the time and lose
# power via the backhand_power_coefficient.
var _is_left_handed: bool = false

# Reused buffer for steering's teammate-position list. Cleared at the top
# of each _apply_steering call.
var _scratch_teammates: Array[Vector3] = []
# Reused buffer for steering's opponent-position list. Cleared at the
# top of _apply_steering. The CARRIER role behavior owns its own
# scratch buffers for action scoring.
var _scratch_opponents: Array[Vector3] = []

# Carrier-role decision behavior. Owns _pick_action's scoring +
# hysteresis + cooldown + scratch buffers. Lives for the full
# lifetime of this state machine; `_state_carry` calls
# `_carrier.decide(ctx)` every tick (the carrier internally
# throttles re-evaluation at PICK_ACTION_PERIOD_TICKS). Mirror
# fields below (_intended_action, _pass_target_peer_id,
# _shot_is_elevated, _last_carry_anchor) are populated from
# `_carrier.*` at the top of `_state_carry` so press states +
# pre-aim convergence keep their existing reading patterns.
var _carrier := AIRoleCarrier.new()

# Set when CARRY commits to PASS_PRESSED; consumed by _state_pass_pressed
# the next tick. -1 means "no current pass target", matching the
# carrier_peer_id convention used elsewhere. Mirrored from
# `_carrier.pass_target_peer_id`.
var _pass_target_peer_id: int = -1

# CARRY pre-aim state: when the carrier picks an action, _state_carry
# stores it here (mirrored from _carrier.intended_action) and pre-aims
# the mouse toward the action's direction, waiting for convergence
# before transitioning. State.CARRY = "no intent."
var _intended_action: State = State.CARRY
var _intent_wait_ticks: int = 0

# Cached carry destination from the most recent carrier re-eval.
# Mirrored from `_carrier.last_carry_anchor`; read by `_state_carry`
# to drive steering during CARRY.
var _last_carry_anchor: Vector3 = Vector3.ZERO

# Engagement cooldown — see ENGAGEMENT_COOLDOWN_TICKS. _prev_carrier
# tracks last tick's puck.carrier_peer_id so we can detect the
# transition into "loose".
var _engagement_cooldown: int = 0
var _prev_carrier_peer_id: int = -1

# Set when CARRY commits to SHOOT_PRESSED; consumed by _state_shoot_pressed
# to drive the elevation flag. Mirrored from `_carrier.shot_is_elevated`.
var _shot_is_elevated: bool = false

# Debug: print one line at SHOOT commit and one line at wrister
# release so the user can compare what the projection promised vs.
# where the puck actually fired from. Toggle off for shipping.
const SHOW_COMMIT_DEBUG: bool = true
var _commit_pos: Vector3 = Vector3.ZERO
var _commit_vel: Vector3 = Vector3.ZERO
var _commit_projected_release: Vector3 = Vector3.ZERO
var _commit_shoot_score: float = 0.0
var _commit_carry_score: float = 0.0

# Multi-tick wrister charge bookkeeping. SHOOT_PRESSED is no longer a
# one-tick quick-shot — the bot holds shoot_held for BOT_WRISTER_CHARGE_TICKS
# while sweeping mouse_screen_pos, so SkaterAimingBehavior accumulates
# charge_distance and SkaterStateMachine fires a real wrister at release
# (direction = sweep direction, power = lerp(min, max, charge_t)).
var _shoot_charge_tick: int = 0
# Sweep direction in screen XY = world XZ (charge tracker does no camera
# transform). Captured at SHOOT_PRESSED entry; mouse_screen_pos walks
# along this each tick.
var _shoot_sweep_dir_xy: Vector2 = Vector2.ZERO
# Wind-up start position in WORLD space — captured ONCE at SHOOT_PRESSED
# entry (tick 0). Defines where the visible swing starts (behind the
# bot on the chosen side). Stays fixed in world space for the duration
# of the charge so the blade IK draws a clean sweep from this point.
var _shoot_wind_up_start: Vector3 = Vector3.ZERO
# Aim target = release position. Recomputed EVERY tick from current
# self_pos so the shot direction at release reflects where the bot
# actually IS when the shot fires, not where they were at tick 0. The
# bot may travel up to ~2 m during the wind-up even with active braking;
# without per-tick recompute the locked aim_target sits where the bot
# WAS, and (mouse − blade) at release can point backwards.
var _shoot_aim_target: Vector3 = Vector3.ZERO
# Captured once at tick 0 and re-applied to fresh clean_aim each tick
# so the aim doesn't randomly jitter inside the wobble cone per frame.
var _shoot_aim_wobble_offset: Vector3 = Vector3.ZERO
# Wind-up side decision: +1 = forehand, -1 = backhand. Captured at
# tick 0 (based on forehand-side pressure) and locked for the charge
# so the swing doesn't flip mid-press if a defender shuffles in and
# out of stick reach.
var _shoot_side_sign: float = 1.0
var _shoot_perp_sign: float = 1.0

# Pre-aim target locked at the moment intent flips from CARRY to a
# fire action. Without this, `_aim_target_for_intent` recomputes
# `compute_open_net_aim` every tick — and when the goalie is roughly
# centered the larger-arc selection can flip side-to-side per tick,
# making the mouse target jump from one corner to the other. Mouse
# never converges; bot's stick visibly wiggles. Locking the aim once
# at intent commit holds the convergence target stable. Reset to
# Vector3.INF when entering CARRY or after pre-aim hands off to the
# press state (which computes its own fresh aim with wobble).
var _locked_pre_aim_point: Vector3 = Vector3.INF

# Slapper bookkeeping. Symmetric to the wrister fields above.
# `slap_pressed` fires once at tick 0 (transitions SkaterStateMachine
# into SLAPPER_CHARGE_WITH_PUCK). `slap_held` stays high through the
# charge ticks, then drops to release. Aim direction is captured at
# slapper entry by SkaterController._enter_slapper_charge.
var _slapper_charge_tick: int = 0
var _slapper_aim_target: Vector3 = Vector3.ZERO

# Per-bot RNG for aim wobble. Seeded once in setup() from peer_id and
# the host tick at spawn so each bot has its own deterministic but
# distinct stream. The previous implementation allocated a fresh
# RandomNumberGenerator and called randomize() on every shot/pass —
# per-call heap allocation plus replay-breaking non-determinism.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Last action the bot actually fired (e.g. "SHOOT" / "PASS→Backdoor"
# / "SLAP"). Set inside the press-state handlers at the moment the
# press is dispatched, not when intent is picked — so the label
# reflects what the bot did rather than what it considered. Persists
# until the next press fires.
var debug_last_decision: String = ""

# Per-tick decision-scoring readout for the floating debug label.
# Populated by `_pick_action` every tick; AIController polls and
# refreshes the label only when content changes (so it doesn't
# flicker every frame). Slot label and carry direction are computed
# from the chosen peer / position at the same time.
var debug_shoot_score: float = 0.0
var debug_shoot_use_slapper: bool = false
var debug_pass_score: float = 0.0
var debug_pass_peer_id: int = 0
var debug_carry_score: float = 0.0
var debug_carry_pos: Vector3 = Vector3.ZERO


# ── Setup ────────────────────────────────────────────────────────────────────

func setup(peer_id: int, team_id: int, brain: TeamBrain, resolver: Callable,
		is_left_handed: bool) -> void:
	if brain == null:
		push_error("SkaterAgentStateMachine.setup: null TeamBrain for peer_id=%d team_id=%d — bot was spawned before GameManager.team_brains was populated. Bot will run without role assignments." % [peer_id, team_id])
	_peer_id = peer_id
	_team_id = team_id
	_own_goal_dir = 1.0 if team_id == 0 else -1.0
	# Aim point at the opposing goal mouth. Used as fallback aim and as
	# the net plane for shot-aim geometry. y=0 — blade IK is 2D for now.
	_attacking_goal_pos = Vector3(0.0, 0.0, -_own_goal_dir * GameRules.GOAL_LINE_Z)
	_team_brain = brain
	_team_id_resolver = resolver
	_is_left_handed = is_left_handed
	# Seed the per-bot RNG. peer_id × prime spreads the bot id range
	# (10000+) across the seed space; XOR with NetworkManager.host_tick
	# at spawn salts the seed per-session so every match isn't an
	# identical wobble pattern (still deterministic within a session,
	# which is what replay needs).
	_rng.seed = (peer_id * 1000003) ^ NetworkManager.host_tick


# ── State accessors ──────────────────────────────────────────────────────────

func get_state() -> State:
	return _state


# Read by AIController for the debug label. Returns "TEAM_STATE: Slot"
# (e.g., "DtoO: SprintBy", "DZ: Pressure"), or "?" when the brain
# hasn't yet assigned a slot (first ticks after spawn).
func debug_role() -> String:
	if _team_brain == null:
		return "?"
	return "%s: %s" % [_team_state_label(_team_brain.state), _slot_label(_team_brain.get_slot(_peer_id))]


# Returns "SHOOT" / "SLAP" / "PASS" / "CARRY" / "—" identifying which
# option scored highest on the most recent _pick_action tick.
# Independent of commit (intent) — purely the live winner.
func debug_winner() -> String:
	var fire_score: float = debug_shoot_score if debug_shoot_score >= debug_pass_score else debug_pass_score
	var fire_label: String = ("SLAP" if debug_shoot_use_slapper else "SHOOT") if debug_shoot_score >= debug_pass_score else "PASS"
	if fire_score == 0.0 and debug_carry_score == 0.0:
		return "—"
	if fire_score >= debug_carry_score:
		return fire_label
	return "CARRY"


# String form of the bot's currently-committed intent ("SHOOT" /
# "SLAP" / "PASS" / "CARRY"). Differs from debug_winner when the bot
# is mid-pre-aim or mid-charge.
func debug_intent() -> String:
	match _intended_action:
		State.SHOOT_PRESSED: return "SHOOT"
		State.SLAPPER_PRESSED: return "SLAP"
		State.PASS_PRESSED: return "PASS"
		_: return "CARRY"


# Receiver slot label for the best pass this tick ("Outlet" / "Backdoor"
# / etc.), or "—" when no pass target.
func debug_pass_slot() -> String:
	if debug_pass_peer_id == 0 or _team_brain == null:
		return "—"
	return _slot_label(_team_brain.get_slot(debug_pass_peer_id))


# Compass direction string for the best carry destination relative
# to the bot's current position. "stand" when destination ≈ self,
# otherwise one of fwd/back/L/R/fwd-L/fwd-R/back-L/back-R using world
# attacking direction as forward.
func debug_carry_dir(self_pos: Vector3) -> String:
	if debug_carry_pos == Vector3.ZERO:
		return "—"
	var dx: float = debug_carry_pos.x - self_pos.x
	var dz: float = debug_carry_pos.z - self_pos.z
	if dx * dx + dz * dz < 0.25:  # within 0.5 m → stand-still
		return "stand"
	# "Forward" = toward attacking goal. own_goal_dir = +1 means own
	# net at +Z, attacking -Z. So forward sign on z = -own_goal_dir.
	var fwd_z_sign: float = -_own_goal_dir
	var dz_signed: float = dz * fwd_z_sign  # positive = forward
	# Lateral and longitudinal magnitudes — pick a compass bucket.
	var ax: float = absf(dx)
	var az: float = absf(dz_signed)
	var lon: String = ("fwd" if dz_signed > 0.0 else "back") if az > 0.5 else ""
	var lat: String = ("L" if dx < 0.0 else "R") if ax > 0.5 else ""
	if lon != "" and lat != "":
		return "%s-%s" % [lon, lat]
	if lon != "":
		return lon
	if lat != "":
		return lat
	return "stand"


func _team_state_label(state: int) -> String:
	match state:
		AIPossessionState.State.DZONE:
			return "DZ"
		AIPossessionState.State.OZONE:
			return "OZ"
		AIPossessionState.State.TRANS_DO:
			return "DtoO"
		AIPossessionState.State.TRANS_OD:
			return "OtoD"
		AIPossessionState.State.NEUTRAL:
			return "Neutral"
		_:
			return "?"


func _slot_label(slot: int) -> String:
	match slot:
		AIRoleSlots.Slot.CARRIER:
			return "Carrier"
		AIRoleSlots.Slot.PRESSURE:
			return "Pressure"
		AIRoleSlots.Slot.ANCHOR:
			return "Anchor"
		AIRoleSlots.Slot.COVER:
			return "Cover"
		AIRoleSlots.Slot.FINISHER:
			return "Finisher"
		AIRoleSlots.Slot.OUTLET:
			return "Outlet"
		AIRoleSlots.Slot.SUPPORT:
			return "Support"
		AIRoleSlots.Slot.CHASE:
			return "Chase"
		AIRoleSlots.Slot.FLANK_L:
			return "FlankL"
		AIRoleSlots.Slot.FLANK_R:
			return "FlankR"
		_:
			return "-"


# ── Dispatch ─────────────────────────────────────────────────────────────────

# Caller (SkaterAgent) is responsible for zeroing `input` before this call.
# We fill move_vector / mouse_world_pos / shoot flags based on _state.
func dispatch(input: InputState, snapshot: WorldSnapshot) -> void:
	if snapshot == null or snapshot.puck_state == null or snapshot.skater_states.is_empty():
		_reset_to_off_puck()
		return
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		# Snapshot pre-dates this bot's spawn; freeze for one tick.
		_reset_to_off_puck()
		return

	var self_pos: Vector3 = self_state.position
	var have_puck: bool = (snapshot.puck_state.carrier_peer_id == _peer_id)
	_ticks_in_state += 1
	_update_engagement_cooldown(snapshot, self_state)

	# When we're ghosted (offside, can't interact with the puck), chase
	# behavior is degenerate — we'd skate at a puck we can't pick up. Drop
	# to OFF_PUCK so the tag-up override in _state_off_puck routes us back
	# to the blue line. The host clears is_ghost via has_tagged_up once we
	# cross over.
	if self_state.is_ghost and _state == State.CHASE_PUCK:
		_set_state(State.OFF_PUCK)

	match _state:
		State.OFF_PUCK:
			_state_off_puck(input, snapshot, self_pos, have_puck)
		State.CHASE_PUCK:
			_state_chase_puck(input, snapshot, self_pos, have_puck)
		State.CARRY:
			_state_carry(input, snapshot, self_pos, have_puck)
		State.SHOOT_PRESSED:
			_state_shoot_pressed(input, snapshot, self_pos, have_puck)
		State.SLAPPER_PRESSED:
			_state_slapper_pressed(input, snapshot, self_pos, have_puck)
		State.PASS_PRESSED:
			_state_pass_pressed(input, snapshot, self_pos, have_puck)


# ── State handlers ───────────────────────────────────────────────────────────

func _state_off_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)

	# Tag-up override: when ghosted (offside), bot must clear back across
	# the blue line before doing anything else. Highest-priority override
	# above all slot logic — bypasses role dispatch entirely.
	if self_state != null and self_state.is_ghost:
		var tag_up: Vector3 = _tag_up_anchor(self_pos)
		_apply_steering(input, snapshot, self_pos, tag_up)
		input.mouse_world_pos = _step_mouse_toward(_ready_stance_aim(self_pos, tag_up, snapshot))
	else:
		# Role dispatch: each TeamBrain-assigned slot maps to a behavior
		# module that produces a RoleDecision (target_position +
		# optional aim override + optional fire intents). The default
		# fallback (AIRoleAnchorFollow) just steers to the brain anchor.
		var ctx: RoleContext = _build_role_context(snapshot, self_pos, self_state)
		var decision: RoleDecision = _dispatch_role_decision(ctx)
		_apply_steering(input, snapshot, self_pos, decision.target_position)
		if decision.has_aim_override:
			input.mouse_world_pos = _step_mouse_toward(decision.aim_world_pos)
		else:
			input.mouse_world_pos = _step_mouse_toward(_ready_stance_aim(self_pos, decision.target_position, snapshot))

	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif _should_chase_loose_puck(snapshot, self_pos):
		_set_state(State.CHASE_PUCK)


# Builds the read-only inputs every role-behavior decide() needs.
# Allocates a fresh RoleContext per call; cheap RefCounted, profile if
# this ever shows up in flame graphs.
func _build_role_context(snapshot: WorldSnapshot, self_pos: Vector3,
		self_state: SkaterNetworkState) -> RoleContext:
	var ctx := RoleContext.new()
	ctx.snapshot = snapshot
	ctx.self_pos = self_pos
	ctx.self_velocity = self_state.velocity if self_state != null else Vector3.ZERO
	ctx.team_id = _team_id
	ctx.peer_id = _peer_id
	ctx.attacking_goal_pos = _attacking_goal_pos
	ctx.defending_goal_pos = Vector3(0.0, 0.0, _own_goal_dir * GameRules.GOAL_LINE_Z)
	ctx.own_goal_dir = _own_goal_dir
	ctx.team_brain = _team_brain
	ctx.team_id_resolver = _team_id_resolver
	if _team_brain != null:
		var brain_anchor: Vector3 = _team_brain.get_anchor(_peer_id, snapshot)
		ctx.anchor = brain_anchor if brain_anchor != Vector3.ZERO else self_pos
	else:
		ctx.anchor = self_pos
	return ctx


# Routes the bot's current slot to its role-behavior module. Returns a
# RoleDecision the state machine consumes to drive steering / aim /
# fire-intent transitions.
#
# CARRIER does not appear here — the state machine's _state_carry
# state owns carrier dispatch directly because the carrier needs
# its own steering rules (HOLD vs DRIFT during pre-aim) and press
# transitions (SHOOT_PRESSED / SLAPPER_PRESSED / PASS_PRESSED).
# Phase 3 adds CARRIER here for the puck-in-flight case where the
# brain still has us slotted CARRIER but we don't have the puck.
func _dispatch_role_decision(ctx: RoleContext) -> RoleDecision:
	var slot: int = _team_brain.get_slot(_peer_id) if _team_brain != null else AIRoleSlots.Slot.NONE
	match slot:
		AIRoleSlots.Slot.FINISHER:
			return AIRoleFinisher.decide(ctx)
		AIRoleSlots.Slot.SUPPORT:
			return AIRoleSupport.decide(ctx)
		AIRoleSlots.Slot.OUTLET:
			return AIRoleOutlet.decide(ctx)
		AIRoleSlots.Slot.PRESSURE:
			return AIRolePressure.decide(ctx)
		AIRoleSlots.Slot.ANCHOR:
			return AIRoleAnchor.decide(ctx)
		AIRoleSlots.Slot.COVER:
			return AIRoleCover.decide(ctx)
		AIRoleSlots.Slot.CHASE:
			return AIRoleChase.decide(ctx)
		AIRoleSlots.Slot.FLANK_L:
			return AIRoleFlank.decide(ctx, -1.0)
		AIRoleSlots.Slot.FLANK_R:
			return AIRoleFlank.decide(ctx, 1.0)
		_:
			return AIRoleAnchorFollow.decide(ctx)


func _state_chase_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lead intercept: aim at where the puck WILL be when we'd actually
	# arrive, not at where it is now. Per-bot t_arrival (distance / max
	# speed) means two bots converging on the same loose puck compute
	# different intercept points, breaking the "both glued to the same
	# puck position" pattern.
	var puck_pos: Vector3 = snapshot.puck_state.position
	var self_vel_3d: Vector3 = Vector3.ZERO
	var self_state2: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state2 != null:
		self_vel_3d = self_state2.velocity
	var target: Vector3 = _lead_intercept(self_pos, self_vel_3d, puck_pos, snapshot.puck_state.velocity)
	# Angling: when an OPPONENT carries the puck, shift the intercept
	# toward center-ice so we approach from the inside and force them to
	# the boards. Loose pucks get the raw intercept — there's no carrier
	# to angle off of. Teammate-carried case is filtered upstream by the
	# F1→OFF_PUCK transition, so by the time we reach here a non-(-1)
	# carrier is necessarily an opponent.
	var carrier_pid: int = snapshot.puck_state.carrier_peer_id
	if carrier_pid != -1 and carrier_pid != _peer_id:
		var carrier_state: SkaterNetworkState = snapshot.skater_states.get(carrier_pid)
		if carrier_state != null:
			target = _angle_intercept_inside(target, carrier_state.position)
	_apply_steering(input, snapshot, self_pos, target)

	# Soft-hands: when receiving a fast loose puck (incoming pass) and
	# we're within SOFT_HANDS_DISTANCE_M of the intercept, scale the
	# move input down so the bot arrives at low speed instead of
	# plowing into a 22 m/s puck. A ~10 m/s body collision against a
	# fast puck deflects it off the blade rather than catching it;
	# reducing closing speed lets the puck "roll onto" the stick.
	# Carrier check ensures we're not soft-handing during a stripped-
	# puck scrum (where opp possession is also -1 in the brief moment
	# after stripping but the puck is slow). Bot-velocity check
	# avoids the case where we're not actually moving toward the puck.
	var puck_velocity: Vector3 = snapshot.puck_state.velocity
	var puck_speed_xz: float = sqrt(puck_velocity.x * puck_velocity.x
			+ puck_velocity.z * puck_velocity.z)
	if carrier_pid == -1 and puck_speed_xz > SOFT_HANDS_PUCK_SPEED_MIN_M_S:
		var dist_to_intercept: float = self_pos.distance_to(target)
		if dist_to_intercept < SOFT_HANDS_DISTANCE_M:
			input.move_vector *= SOFT_HANDS_MOVE_SCALE

	# Aim: normally blade-on-intercept, but during the engagement cooldown
	# (just got stripped or just stick-checked someone) pull the blade
	# back to our body so the puck can settle without auto-magnetting
	# back to us. Once the puck is inside our blade reach, snap the aim
	# to the puck's ACTUAL position — leading at this range puts the
	# blade past a puck that's already on our stick. For fast loose
	# pucks (incoming passes), aim at the puck's CURRENT position even
	# from far out — the blade tracks the puck along its flight line so
	# it's always on the path the puck is travelling, instead of pointing
	# at the destination point and snapping onto the puck only at the
	# end of the approach.
	if _engagement_cooldown > 0:
		input.mouse_world_pos = _step_mouse_toward(Vector3(self_pos.x, 0.0, self_pos.z))
	elif self_pos.distance_to(puck_pos) <= BLADE_REACH_M:
		input.mouse_world_pos = _step_mouse_toward(puck_pos)
	elif carrier_pid == -1 and puck_speed_xz > SOFT_HANDS_PUCK_SPEED_MIN_M_S:
		input.mouse_world_pos = _step_mouse_toward(puck_pos)
	else:
		input.mouse_world_pos = _step_mouse_toward(target)
	# Transitions: chase ends as soon as someone has the puck, OR we're
	# no longer the closest teammate (let the new closest take over).
	if have_puck:
		_set_state(State.CARRY)
	elif not _should_chase_loose_puck(snapshot, self_pos):
		_set_state(State.OFF_PUCK)


func _state_carry(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	if not have_puck:
		_carrier.reset()
		_intended_action = State.CARRY
		_intent_wait_ticks = 0
		_pass_target_peer_id = -1
		_shot_is_elevated = false
		_locked_pre_aim_point = Vector3.INF
		_set_state(_post_puck_lost_state(snapshot))
		return

	# Run the carrier role behavior. Internally throttled at
	# PICK_ACTION_PERIOD_TICKS — between re-evals it returns the
	# cached intent + last_carry_anchor unchanged. Mirror its public
	# fields back into the state machine so press states (SHOOT /
	# SLAPPER / PASS) and pre-aim convergence keep their existing
	# reading patterns.
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	var ctx: RoleContext = _build_role_context(snapshot, self_pos, self_state)
	_carrier.decide(ctx)

	# Support state from the carrier propagates every tick — press
	# states (SHOOT / SLAPPER / PASS) and pre-aim convergence read
	# these and they need to stay fresh.
	_last_carry_anchor = _carrier.last_carry_anchor
	_pass_target_peer_id = _carrier.pass_target_peer_id
	_shot_is_elevated = _carrier.shot_is_elevated
	debug_shoot_score = _carrier.debug_shoot_score
	debug_shoot_use_slapper = _carrier.debug_shoot_use_slapper
	debug_pass_score = _carrier.debug_pass_score
	debug_pass_peer_id = _carrier.debug_pass_peer_id
	debug_carry_score = _carrier.debug_carry_score
	debug_carry_pos = _carrier.debug_carry_pos

	# Intent transitions are gated on "currently in CARRY." Once a
	# fire intent (SHOOT / SLAPPER / PASS) is selected we hold it
	# through pre-aim convergence (or the INTENT_MAX_WAIT_TICKS safety
	# timeout). Without this gate, carrier score oscillations between
	# re-eval ticks can flip the intent back to CARRY before the
	# mouse + facing finish converging — the bot wants to shoot, never
	# quite finishes aiming, never fires. Press states still own their
	# own bail conditions (defender closing, puck loss) and the
	# unconditional `if not have_puck` early-return above still works.
	if _intended_action == State.CARRY:
		var new_intent: State = _state_from_carrier_intent(_carrier.intended_action)
		if new_intent != _intended_action:
			_intent_wait_ticks = 0
			# Capture the aim point ONCE so pre-aim convergence has a
			# stable target. Open-net arc selection can flip sides
			# per tick when the goalie is centered, which makes the
			# mouse target jump and the bot's stick wiggle.
			match new_intent:
				State.SHOOT_PRESSED, State.SLAPPER_PRESSED:
					_locked_pre_aim_point = _shot_aim_point(snapshot, self_pos)
				State.PASS_PRESSED:
					_locked_pre_aim_point = _pass_aim_point(snapshot, self_pos)
			# Debug: capture commit snapshot for SHOOT to compare against
			# actual release pos later.
			if SHOW_COMMIT_DEBUG and new_intent == State.SHOOT_PRESSED:
				var hv: Vector3 = Vector3.ZERO
				if self_state != null:
					hv = Vector3(self_state.velocity.x, 0.0, self_state.velocity.z)
				_commit_pos = self_pos
				_commit_vel = hv
				_commit_projected_release = self_pos + hv * BOT_WRISTER_LOOKAHEAD_S
				_commit_shoot_score = _carrier.debug_shoot_score
				_commit_carry_score = _carrier.debug_carry_score
				print("[bot %d] SHOOT COMMIT pos=(%.2f, %.2f) vel=(%.2f, %.2f) speed=%.2f projected_release=(%.2f, %.2f) shoot=%.3f carry=%.3f" % [
						_peer_id, _commit_pos.x, _commit_pos.z,
						_commit_vel.x, _commit_vel.z, hv.length(),
						_commit_projected_release.x, _commit_projected_release.z,
						_commit_shoot_score, _commit_carry_score])
		_intended_action = new_intent

	# Steering depends on which action is locked.
	#
	# CARRY: drift toward the carry destination.
	#
	# SHOOT_PRESSED (wrister) pre-aim: steer toward the projected
	# release position (current + velocity × wrister_lookahead). The
	# carrier scorer chose SHOOT based on score at that release-pos,
	# so the bot's actual motion needs to land there for the chosen
	# shot to be the shot taken. Steering to _last_carry_anchor
	# (often stand-still = self_pos) would brake the bot back to
	# commit position, releasing ~1-2 m short of the scored spot.
	#
	# SLAPPER_PRESSED / PASS_PRESSED: brake. Slappers need stability
	# for the wind-up; pass leads aim from a held spot.
	if _intended_action == State.CARRY:
		_apply_steering(input, snapshot, self_pos, _last_carry_anchor)
	elif _intended_action == State.SHOOT_PRESSED:
		var hv: Vector3 = Vector3.ZERO
		if self_state != null:
			hv = Vector3(self_state.velocity.x, 0.0, self_state.velocity.z)
		_apply_steering(input, snapshot, self_pos,
				self_pos + hv * BOT_WRISTER_LOOKAHEAD_S)
	else:
		# Fire intent locked, pre-aiming. Brake actively so the bot
		# doesn't coast past the spot they decided to fire from.
		_apply_brake_steering(input, snapshot, self_pos)

	# Mouse target depends on intent: carry uses normal goal-aim, fire
	# states pre-aim toward action direction.
	var mouse_target: Vector3
	if _intended_action == State.CARRY:
		mouse_target = _carry_mouse_aim(snapshot, self_pos)
	else:
		mouse_target = _aim_target_for_intent(snapshot, self_pos)
	input.mouse_world_pos = _step_mouse_toward(mouse_target)

	# If pre-aiming, wait for mouse convergence AND facing alignment
	# (or timeout) before transitioning to the action state. Mouse
	# converges fast (~130 ms for a 90° pivot at MOUSE_MAX_SPEED);
	# facing rotation is mouse-driven but lerp-based and slower
	# (~250 ms+ for the same pivot). Without the facing check the
	# bot fires while still rotated wrong and the puck goes out the
	# ROM edge. Action state fires on entry, so both must be aligned
	# at that moment. Timeout still fires after INTENT_MAX_WAIT_TICKS
	# as a safety so the bot can't pre-aim forever.
	if _intended_action != State.CARRY:
		var aim_dist: float = _mouse_pos.distance_to(mouse_target)
		var aim_converged: bool = aim_dist < AIM_CONVERGED_DIST_M
		var facing_aligned: bool = _is_facing_aligned_for_aim(snapshot, self_pos, mouse_target)
		if (aim_converged and facing_aligned) or _intent_wait_ticks >= INTENT_MAX_WAIT_TICKS:
			_set_state(_intended_action)
			_intended_action = State.CARRY
			_intent_wait_ticks = 0
			# Press state computes its own fresh aim with wobble on
			# tick 0; release the pre-aim lock so the next CARRY →
			# fire transition captures a new one.
			_locked_pre_aim_point = Vector3.INF
			# Force a fresh re-eval the next time CARRY is entered —
			# without this the carrier keeps its committed intent
			# across the press cycle and re-fires the same action
			# the moment we re-enter CARRY.
			_carrier.clear_intent()
		else:
			_intent_wait_ticks += 1


# Maps the carrier's INTENT_* enum (intentionally decoupled from
# State for unit testing) back into the state machine's State enum.
func _state_from_carrier_intent(intent: int) -> State:
	match intent:
		AIRoleCarrier.INTENT_SHOOT:
			return State.SHOOT_PRESSED
		AIRoleCarrier.INTENT_SLAPPER:
			return State.SLAPPER_PRESSED
		AIRoleCarrier.INTENT_PASS:
			return State.PASS_PRESSED
		_:
			return State.CARRY


# Returns the mouse target (in world XZ) the bot should be aiming at
# while pre-aiming for `_intended_action`. Always 2 m forward in the
# action's aim direction — direction is what matters for shot fire,
# not distance, so we keep the target close to the bot for fast
# convergence under the motion-limited model.
func _aim_target_for_intent(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	# Pre-aim convergence uses the LOCKED aim point captured at intent
	# transition (stable across ticks) rather than recomputing per tick.
	# Falls back to a fresh compute if the lock is missing — keeps the
	# old behavior if some code path skipped the capture.
	match _intended_action:
		State.PASS_PRESSED:
			var target: Vector3 = (_locked_pre_aim_point
					if _locked_pre_aim_point.is_finite()
					else _pass_aim_point(snapshot, self_pos))
			return _aim_2m_toward(self_pos, target)
		State.SHOOT_PRESSED, State.SLAPPER_PRESSED:
			var target: Vector3 = (_locked_pre_aim_point
					if _locked_pre_aim_point.is_finite()
					else _shot_aim_point(snapshot, self_pos))
			return _aim_2m_toward(self_pos, target)
		_:
			return _carry_mouse_aim(snapshot, self_pos)


# Returns a point 2 m from `self_pos` in the direction toward
# `aim_world`. Used to put the mouse close to the bot in the
# correct DIRECTION for an upcoming shot/pass, so it converges
# quickly under the motion model. Distance to the actual aim point
# doesn't matter — the shot direction at fire time depends on
# (mouse - shoulder) or (mouse - blade), which is a unit direction.
func _aim_2m_toward(self_pos: Vector3, aim_world: Vector3) -> Vector3:
	var to_aim: Vector3 = aim_world - self_pos
	to_aim.y = 0.0
	if to_aim.length_squared() < 0.0001:
		# Fall back to the attacking direction (team-aware). Vector3.FORWARD
		# is (0, 0, -1), which is correct for team 0 but inverts for team 1.
		return self_pos + Vector3(0.0, 0.0, -_own_goal_dir) * CARRY_BLADE_AIM_FORWARD_M
	return self_pos + to_aim.normalized() * CARRY_BLADE_AIM_FORWARD_M


# True when the bot's facing has rotated close enough to the
# action-aim direction that the blade ROM can fire there cleanly.
# Threshold is 80° each side: well within the 90° forehand /
# 120° backhand ROM, leaves slack so the actual fire direction
# isn't at the ROM edge. Used in the pre-aim convergence check
# to wait for body rotation, not just mouse rotation — facing
# is mouse-driven via the pose coordinator's lerp but lags mouse
# convergence significantly.
func _is_facing_aligned_for_aim(snapshot: WorldSnapshot, self_pos: Vector3,
		aim_target: Vector3) -> bool:
	var dx: float = aim_target.x - self_pos.x
	var dz: float = aim_target.z - self_pos.z
	var len_sq: float = dx * dx + dz * dz
	if len_sq < 0.0001:
		return true
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		return true
	var inv: float = 1.0 / sqrt(len_sq)
	var cos_angle: float = self_state.facing.x * dx * inv + self_state.facing.y * dz * inv
	# 80° each side: cos(80°) ≈ 0.174.
	return cos_angle >= 0.174


func _state_shoot_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lost the puck mid-charge — bail. SkaterStateMachine's release path
	# is a no-op without the puck, so we don't need to force a release.
	if not have_puck:
		_set_state(_post_puck_lost_state(snapshot))
		return

	# Mid-charge bail: opponent closing in from the front. block_held
	# cancels WRISTER_AIM back to SKATING_WITH_PUCK without a release.
	# Skipped on tick 0 — we just made the decision, give it at least
	# one frame to commit. Forward-only check: a defender behind the
	# shooter (between us and our own net) can't realistically disrupt a
	# wrister windup, and bailing on them was throwing away clean shots
	# any time a backchecker happened to be within 2 m. Matches the
	# pressure cube falloff intuition (behind/sideways = not a threat).
	if _shoot_charge_tick > 0 and _opponent_within_forward(
			snapshot, self_pos, _attacking_goal_pos - self_pos,
			BOT_WRISTER_BAIL_RADIUS_M):
		input.block_held = true
		_set_state(State.CARRY)
		return

	# Steer toward the projected release position so the bot actually
	# arrives at the spot the carrier scorer assumed. The projection
	# (current + velocity × wrister_lookahead) is what won SHOOT over
	# CARRY; if we steered toward _last_carry_anchor instead (often
	# stand-still = self_pos), the steering would brake the bot back
	# to current pos and the puck would release ~1-2 m short of the
	# scored spot. Rush wristers should fire from the projected spot,
	# not be braked back to commit position.
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	var release_target: Vector3 = self_pos
	if self_state != null:
		var hv: Vector3 = Vector3(self_state.velocity.x, 0.0, self_state.velocity.z)
		release_target = self_pos + hv * BOT_WRISTER_LOOKAHEAD_S
	_apply_steering(input, snapshot, self_pos, release_target)
	# Elevation flag based on decision at entry. Sticky in
	# SkaterController, so setting one direction explicitly each tick
	# normalizes it regardless of the last shot.
	if _shot_is_elevated:
		input.elevation_up = true
	else:
		input.elevation_down = true

	# First tick: capture aim, compute wind-up start (forehand side,
	# behind bot), fire shoot_pressed edge so SkaterStateMachine enters
	# WRISTER_AIM. wrister_start_blade_local_x is captured by
	# SkaterController at the moment of WRISTER_AIM entry from the
	# blade's CURRENT pose — which means we need mouse_world_pos to be
	# at the wind-up position THIS tick so apply_blade_from_mouse (still
	# running in SKATING_WITH_PUCK before the transition) puts the blade
	# on the forehand side.
	if _shoot_charge_tick == 0:
		debug_last_decision = "SHOOT"
		var clean_aim_init: Vector3 = _shot_aim_point(snapshot, self_pos)
		# Capture wobble as a Vector3 offset. Re-applied each tick to
		# the FRESH clean_aim so the resulting wobbled aim stays
		# consistent — recomputing _aim_wobble per tick would jitter.
		_shoot_aim_wobble_offset = _aim_wobble(self_pos, clean_aim_init, SHOT_AIM_WOBBLE_CONE_DEG)
		_shoot_perp_sign = -1.0 if _is_left_handed else 1.0
		var aim_dir_init: Vector3 = _shoot_wobbled_aim_dir(snapshot, self_pos)
		var forehand_perp_init: Vector3 = Vector3(
				aim_dir_init.z * _shoot_perp_sign, 0.0, -aim_dir_init.x * _shoot_perp_sign)

		# Pick wind-up side: forehand by default. Flip to backhand if a
		# defender is within stick reach AND clearly on the forehand
		# side — they'd poke the puck off a forehand wind-up. Locked
		# for the charge so no mid-swing oscillation.
		_shoot_side_sign = 1.0
		var reach_sq: float = BOT_FOREHAND_STICK_REACH_M * BOT_FOREHAND_STICK_REACH_M
		for peer_id: int in snapshot.skater_states:
			if peer_id == _peer_id:
				continue
			if int(_team_id_resolver.call(peer_id)) == _team_id:
				continue
			var opp_pos: Vector3 = snapshot.skater_states[peer_id].position
			var rel_x: float = opp_pos.x - self_pos.x
			var rel_z: float = opp_pos.z - self_pos.z
			var rel_len_sq: float = rel_x * rel_x + rel_z * rel_z
			if rel_len_sq > reach_sq:
				continue
			var forehand_dot: float = rel_x * forehand_perp_init.x + rel_z * forehand_perp_init.z
			if forehand_dot > BOT_FOREHAND_LATERAL_THRESHOLD_M:
				_shoot_side_sign = -1.0
				break

		# wind_up_start is FIXED in world space — defines where the
		# visible swing starts. Compute from initial position with
		# initial compensated aim_dir.
		var comp_aim_init: Vector3 = _shoot_compensated_aim_dir(aim_dir_init)
		var shoot_perp_init: Vector3 = forehand_perp_init * _shoot_side_sign
		_shoot_wind_up_start = (
				self_pos
				- comp_aim_init * BOT_WRISTER_WIND_UP_BACK_M
				+ shoot_perp_init * BOT_WRISTER_WIND_UP_SIDE_M)
		_shoot_sweep_dir_xy = Vector2(comp_aim_init.x, comp_aim_init.z)
		input.shoot_pressed = true

	# Recompute aim_target EVERY tick from current self_pos so the shot
	# direction at release reflects where the bot ACTUALLY is when the
	# shot fires, not where they were at tick 0. With active braking
	# the bot still travels ~2 m during the 250 ms wind-up; a fixed
	# tick-0 aim_target ends up BEHIND the bot at release and the shot
	# direction (mouse − blade) points the wrong way.
	var aim_dir_now: Vector3 = _shoot_wobbled_aim_dir(snapshot, self_pos)
	var comp_aim_now: Vector3 = _shoot_compensated_aim_dir(aim_dir_now)
	var forehand_perp_now: Vector3 = Vector3(
			aim_dir_now.z * _shoot_perp_sign, 0.0, -aim_dir_now.x * _shoot_perp_sign)
	var shoot_perp_now: Vector3 = forehand_perp_now * _shoot_side_sign
	_shoot_aim_target = (
			self_pos
			+ comp_aim_now * BOT_WRISTER_RELEASE_FORWARD_M
			+ shoot_perp_now * BOT_WRISTER_WIND_UP_SIDE_M)

	# Lerp mouse_world_pos from wind-up start (fixed) to aim target
	# (fresh) across the charge. Blade IK chases the lerp; the swing
	# starts from a fixed point behind the bot and ends at the
	# release point in front of the bot's CURRENT position.
	var t: float = float(_shoot_charge_tick) / float(BOT_WRISTER_CHARGE_TICKS)
	input.mouse_world_pos = _step_mouse_toward(_shoot_wind_up_start.lerp(_shoot_aim_target, t))

	# Walk mouse_screen_pos along the sweep direction. Per-tick delta is
	# BOT_WRISTER_SCREEN_DELTA_PER_TICK; SkaterAimingBehavior scales by
	# 0.01 * mouse_sensitivity to convert to world-space charge accrual.
	input.mouse_screen_pos = (
			_shoot_sweep_dir_xy * (BOT_WRISTER_SCREEN_DELTA_PER_TICK * float(_shoot_charge_tick)))

	if _shoot_charge_tick < BOT_WRISTER_CHARGE_TICKS:
		# Still charging — keep shoot_held high.
		input.shoot_held = true
		_shoot_charge_tick += 1
	else:
		# Release this tick: shoot_held drops, SkaterStateMachine's
		# _state_wrister_aim sees not shoot_held → release_wrister fires
		# with accumulated charge_distance and sweep direction.
		input.shoot_held = false
		# Debug: print release vs projection so we can see if the puck
		# fired from where the projection promised.
		if SHOW_COMMIT_DEBUG:
			var drift: Vector3 = self_pos - _commit_projected_release
			var actual_travel: Vector3 = self_pos - _commit_pos
			print("[bot %d] WRISTER RELEASE actual=(%.2f, %.2f) projected=(%.2f, %.2f) drift=(%+.2f, %+.2f) traveled=%.2fm of projected=%.2fm" % [
					_peer_id,
					self_pos.x, self_pos.z,
					_commit_projected_release.x, _commit_projected_release.z,
					drift.x, drift.z,
					actual_travel.length(),
					(_commit_projected_release - _commit_pos).length()])
		_set_state(State.CARRY)


# Slapper charge: hold slap_held for BOT_SLAPPER_CHARGE_TICKS, then
# Returns the normalised wobbled aim direction (clean_aim + cached
# wobble) from self_pos. Falls back to forward when degenerate.
func _shoot_wobbled_aim_dir(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var clean_aim: Vector3 = _shot_aim_point(snapshot, self_pos)
	var wobbled: Vector3 = clean_aim + _shoot_aim_wobble_offset
	var dir_xz: Vector3 = Vector3(wobbled.x - self_pos.x, 0.0, wobbled.z - self_pos.z)
	if dir_xz.length_squared() > 0.0001:
		return dir_xz.normalized()
	return Vector3(0.0, 0.0, 1.0)


# Compensates aim_dir against the geometric forehand bias introduced
# by the lateral release offset (atan2(SIDE, FORWARD)). Rotates
# aim_dir AWAY from shoot_perp so that (mouse − blade) at release
# still points at the original clean_aim. Sign depends on side +
# handedness — see the rot derivation comment.
func _shoot_compensated_aim_dir(aim_dir: Vector3) -> Vector3:
	var bias_rad: float = atan2(BOT_WRISTER_WIND_UP_SIDE_M, BOT_WRISTER_RELEASE_FORWARD_M)
	var rot: float = bias_rad * _shoot_side_sign * _shoot_perp_sign
	var cos_r: float = cos(rot)
	var sin_r: float = sin(rot)
	return Vector3(
			aim_dir.x * cos_r - aim_dir.z * sin_r,
			0.0,
			aim_dir.x * sin_r + aim_dir.z * cos_r)


# release. Mirrors _state_shoot_pressed except (a) longer commit, (b)
# uses slap_pressed/slap_held instead of shoot_*, (c) aim direction
# is captured ONCE at tick 0 by SkaterController._enter_slapper_charge
# from input.mouse_world_pos at that moment, so we set the target on
# first tick and the SM doesn't need to lerp the mouse during charge.
# Bail behaviour matches the wrister: forward-cone opponent within
# BOT_SLAPPER_BAIL_RADIUS_M cancels the charge via block_held.
func _state_slapper_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lost the puck mid-charge — bail. SkaterStateMachine cancels the
	# slapper internally when has_puck flips false and we're not
	# already in a release window, so no need to force block_held here.
	if not have_puck:
		_set_state(_post_puck_lost_state(snapshot))
		return

	# Mid-charge bail: forward defender closing in. block_held cancels
	# SLAPPER_CHARGE_WITH_PUCK back to SKATING_WITH_PUCK without
	# release. Skipped on tick 0 so we don't bail before the press
	# even registers.
	if _slapper_charge_tick > 0 and _opponent_within_forward(
			snapshot, self_pos, _attacking_goal_pos - self_pos,
			BOT_SLAPPER_BAIL_RADIUS_M):
		input.block_held = true
		_set_state(State.CARRY)
		return

	_apply_brake_steering(input, snapshot, self_pos)
	if _shot_is_elevated:
		input.elevation_up = true
	else:
		input.elevation_down = true

	# First tick: capture aim, fire slap_pressed. SkaterController's
	# _enter_slapper_charge reads input.mouse_world_pos and locks the
	# slapper aim direction from there for the rest of the charge.
	if _slapper_charge_tick == 0:
		debug_last_decision = "SLAP"
		var clean_aim: Vector3 = _shot_aim_point(snapshot, self_pos)
		_slapper_aim_target = clean_aim + _aim_wobble(self_pos, clean_aim, SHOT_AIM_WOBBLE_CONE_DEG)
		input.slap_pressed = true

	input.mouse_world_pos = _step_mouse_toward(_slapper_aim_target)

	if _slapper_charge_tick < BOT_SLAPPER_CHARGE_TICKS:
		input.slap_held = true
		_slapper_charge_tick += 1
	else:
		# Release: SkaterStateMachine sees not slap_held → release_slapper
		# fires with the locked direction and elapsed-time-derived power.
		input.slap_held = false
		_set_state(State.CARRY)


func _state_pass_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	_apply_brake_steering(input, snapshot, self_pos)
	# Resolve the receiver's slot label NOW for the debug readout —
	# `_pass_target_peer_id` gets cleared below, and the slot is what
	# tells the watcher who actually got the puck (e.g. "PASS→Backdoor").
	var target_slot_label: String = "?"
	if _team_brain != null and _pass_target_peer_id != -1:
		target_slot_label = _slot_label(_team_brain.get_slot(_pass_target_peer_id))
	debug_last_decision = "PASS→%s" % target_slot_label
	# Aim at the receiver's lead position. Quick-shot direction is
	# blade-from-player at release, and the blade IK swings toward
	# mouse_world_pos — so this fires the puck along the bot→receiver
	# vector.
	var clean_pass_aim: Vector3 = _pass_aim_point(snapshot, self_pos)
	input.mouse_world_pos = _step_mouse_toward(clean_pass_aim + _aim_wobble(
			self_pos, clean_pass_aim, PASS_AIM_WOBBLE_CONE_DEG))
	input.shoot_pressed = true
	input.shoot_held = true
	# v2: give-and-go cut sub-mode is removed. After the pass, the bot
	# falls back to its slot anchor for the new state (likely SUPPORT
	# or SPRINT_BY in TRANS_DO).
	# Same one-tick-then-exit pattern as SHOOT_PRESSED. Clear the target
	# either way so a future PASS picks a fresh one.
	_pass_target_peer_id = -1
	if not have_puck:
		_set_state(_post_puck_lost_state(snapshot))
	else:
		_set_state(State.CARRY)


# Hold-position steering during fire-state commits (SHOOT_PRESSED,
# SLAPPER_PRESSED, PASS_PRESSED) and CARRY pre-aim. The bot has
# decided where to fire from — they shouldn't keep skating forward
# during the wrister charge (60 ticks ≈ 250 ms) or slapper charge
# (132 ticks ≈ 550 ms), which would otherwise drift them up to ~4 m
# closer to the net before the puck releases. Anchor = self_pos
# zeroes the seek force so ice friction bleeds momentum naturally;
# repel forces (defenders, boards, crease) still apply via
# `_apply_steering`. Each fire state sets `input.mouse_world_pos`
# itself because the aim differs (goal-shadow vs receiver lead).
func _apply_hold_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	_apply_steering(input, snapshot, self_pos, self_pos)


# Brake steering — actively decelerate by pointing the steering anchor
# behind the bot's current velocity. The opposed direction triggers
# `AISteering.brake_pivot` which returns full reverse thrust, much
# faster deceleration than passive friction during coast (hold).
# Falls back to hold once velocity drops below BRAKE_MIN_SPEED so the
# bot doesn't start gliding backward after stopping. Used during
# fire-action pre-aim convergence and during the wrister / slapper
# wind-up — without this, a bot rushing at top speed coasts past the
# slot before the press can release, crashing into the goalie.
const BRAKE_STEERING_ANCHOR_DIST_M: float = 5.0
const BRAKE_STEERING_MIN_SPEED_M_S: float = 0.5
func _apply_brake_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		_apply_hold_steering(input, snapshot, self_pos)
		return
	var v: Vector3 = self_state.velocity
	var v_mag_sq: float = v.x * v.x + v.z * v.z
	if v_mag_sq < BRAKE_STEERING_MIN_SPEED_M_S * BRAKE_STEERING_MIN_SPEED_M_S:
		_apply_hold_steering(input, snapshot, self_pos)
		return
	var v_mag: float = sqrt(v_mag_sq)
	var brake_anchor: Vector3 = Vector3(
			self_pos.x - v.x / v_mag * BRAKE_STEERING_ANCHOR_DIST_M,
			0.0,
			self_pos.z - v.z / v_mag * BRAKE_STEERING_ANCHOR_DIST_M)
	_apply_steering(input, snapshot, self_pos, brake_anchor)


# Lead the receiver by their flight-time along their current velocity
# blended with their published steering anchor. Long passes lead
# further than short ones — the puck takes longer to arrive, so the
# receiver moves further during transit. Falls back to the goal if
# the target slot disappeared between picking and pressing (rare —
# bot demoted, peer disconnected, etc.).
func _pass_aim_point(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var receiver: SkaterNetworkState = snapshot.skater_states.get(_pass_target_peer_id)
	if receiver == null:
		return _attacking_goal_pos
	var dist: float = self_pos.distance_to(receiver.position)
	var flight_t: float = clampf(
			dist / AIActionScoring.PASS_SPEED_M_S, 0.0, AIRoleCarrier.PASS_LEAD_MAX_S)
	return _predict_receiver(_pass_target_peer_id, receiver, flight_t)


# Receiver position prediction — velocity extrapolation of the blade
# contact (in world space), plus the blade-to-body world offset so
# the puck aims at where the stick will be (not body center).
#
# An earlier version blended in the receiver's published steering
# anchor, intending to lead bots cutting toward their slot. That
# overshot dramatically (TRANS_DO OUTLET anchor is ~25 m up-ice).
# Velocity-only is conservative and correct: project only as far as
# the receiver actually moves, no aspirational pull.
#
# IMPORTANT: `receiver.blade_position` is in upper-body-LOCAL space —
# subtracting `receiver.position` (world) was nonsense and produced
# offsets up to 25 m, leading to passes fired at empty ice on the far
# side of the rink during D→O transition. Use `blade_contact_world`
# (host-only field, populated by SkaterController.get_network_state)
# which is the blade in world coordinates already.
func _predict_receiver(receiver_pid: int, receiver: SkaterNetworkState, flight_t: float) -> Vector3:
	# Predict the blade position forward by flight_t along body
	# velocity (assumes blade moves with body — fine over a 0.6 s
	# pass window).
	var blade_world: Vector3 = receiver.blade_contact_world
	# Defensive fallback: if blade_contact_world isn't populated
	# (zero — shouldn't happen on host but guard anyway), fall back
	# to body position. Aim at body center is worse than aim at
	# blade, but vastly better than aim at center ice.
	if blade_world == Vector3.ZERO:
		blade_world = receiver.position
	return AITrajectory.predict_at(blade_world, receiver.velocity, flight_t)


func _apply_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, anchor: Vector3) -> void:
	# Standard potential-field steering with brake-pivot.
	_scratch_teammates.clear()
	_scratch_opponents.clear()
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			_scratch_teammates.append(snapshot.skater_states[peer_id].position)
		else:
			_scratch_opponents.append(snapshot.skater_states[peer_id].position)

	# Shot-lane endpoints: only set when a teammate (not us, not opp) is
	# the carrier — keeps off-puck bots out of the carrier's lane to the
	# attacking goal. Carrier-side bots pass zero (they aren't repelled
	# from their own lane).
	var lane_start: Vector3 = Vector3.ZERO
	var lane_end: Vector3 = Vector3.ZERO
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier != -1 and carrier != _peer_id:
		if int(_team_id_resolver.call(carrier)) == _team_id:
			var carrier_state: SkaterNetworkState = snapshot.skater_states.get(carrier)
			if carrier_state != null:
				# Lead the carrier — the lane we want to clear is where
				# they'll shoot from, not where they are right now.
				lane_start = AITrajectory.predict_at(
						carrier_state.position, carrier_state.velocity,
						SHOT_LANE_LEAD_TIME_S)
				lane_end = _attacking_goal_pos

	var desired: Vector2 = AISteering.compute_move_vector(
			self_pos, anchor, _scratch_teammates, _scratch_opponents,
			lane_start, lane_end,
			GameRules.RINK_HALF_WIDTH, GameRules.RINK_HALF_LENGTH)

	# Brake-pivot: if our current velocity is roughly opposite the desired
	# direction (~180° transition), it's faster to brake and reverse than
	# to carve a wide arc. AISteering.brake_pivot returns the original
	# desired vector when no brake is needed.
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state != null:
		var v: Vector3 = self_state.velocity
		desired = AISteering.brake_pivot(desired, Vector2(v.x, v.z))
	input.move_vector = desired


# Adds a small lateral perpendicular nudge to an aim point —
# magnitude is `dist × tan(cone_deg)` with a uniformly random sign in
# [-1, +1]. Returns Vector3.ZERO when the aim is degenerate (target
# coincident with self) or cone is zero. Each call is rolled fresh,
# so callers should cache the offset across a multi-tick state (e.g.
# SHOOT_PRESSED captures it once at tick 0).
func _aim_wobble(from: Vector3, to: Vector3, cone_deg: float) -> Vector3:
	if cone_deg <= 0.0:
		return Vector3.ZERO
	var to_target := Vector3(to.x - from.x, 0.0, to.z - from.z)
	var dist: float = to_target.length()
	if dist < 0.01:
		return Vector3.ZERO
	# Uniform [-1, +1] × cone, then convert angle to lateral offset.
	# tan() at small angles ≈ angle in rad, but use tan() exactly so
	# the wobble scales correctly even for atypical (large) cones.
	# RNG is per-bot, seeded once in setup() — see _rng declaration.
	var theta_rad: float = deg_to_rad(cone_deg) * _rng.randf_range(-1.0, 1.0)
	var lateral: float = dist * tan(theta_rad)
	# Perpendicular to aim direction in XZ — 90° rotation: (x,z) → (-z,x).
	var dir: Vector3 = to_target / dist
	return Vector3(-dir.z, 0.0, dir.x) * lateral


# Returns the opposing goalie's CURRENT world position. Used as input
# to AIActionScoring.predict_goalie_pos, which models the goalie's
# react-then-slide forward along the puck's lateral target. Falls back
# to _attacking_goal_pos when goalie state isn't buffered yet (first-
# frame edge case); downstream geometry handles that gracefully.
func _goalie_now(snapshot: WorldSnapshot) -> Vector3:
	var opp_goalie: GoalieNetworkState = snapshot.goalie_states.get(1 - _team_id)
	if opp_goalie == null:
		return _attacking_goal_pos
	return Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z)


# Wraps AIActionScoring.predict_goalie_pos for the common case where
# the puck-at-release is the position we're scoring a shot from.
# `release_time_s` is the time from now until the bot fires (e.g.,
# wrister/slapper charge time + any path/flight time before the fire).
func _predict_goalie_at(snapshot: WorldSnapshot, release_time_s: float,
		puck_pos_at_release: Vector3) -> Vector3:
	return AIActionScoring.predict_goalie_pos(
			_goalie_now(snapshot), _attacking_goal_pos,
			release_time_s, puck_pos_at_release)


# CARRY-state mouse target: 2 m forward in the attacking-goal
# direction, plus a stickhandling offset perpendicular to that
# direction to evade the closest incoming defender. Body facing
# tracks the forward axis (toward the goal); blade IK lands
# comfortably in front of the body where small mouse shifts produce
# real blade motion (instead of clamping to ROM extreme as it would
# at goal-plane distance).
func _carry_mouse_aim(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var to_goal: Vector3 = _attacking_goal_pos - self_pos
	to_goal.y = 0.0
	var forward_dir: Vector3
	# Attacking direction is -_own_goal_dir along z (team 0 attacks -z,
	# team 1 attacks +z). Fall back to it when the bot has drifted past
	# the attacking goal line — without the sign check, `to_goal` would
	# point back through the rink and the bot would aim into its own
	# defensive zone.
	var attacking_z: float = -_own_goal_dir
	if to_goal.length_squared() > 0.0001 and to_goal.z * attacking_z > 0.0:
		forward_dir = to_goal.normalized()
	else:
		forward_dir = Vector3(0.0, 0.0, attacking_z)
	var base: Vector3 = self_pos + forward_dir * CARRY_BLADE_AIM_FORWARD_M
	# Clamp the carry mouse so it stays on the rink side of the
	# attacking goal line — the blade IK chases the mouse, and a mouse
	# target past the goal line punches the blade through the net.
	var goal_line_z: float = _attacking_goal_pos.z
	var max_forward_z: float = goal_line_z + AIRoleHelpers.GOAL_LINE_BUFFER_M * _own_goal_dir
	if (base.z - max_forward_z) * _own_goal_dir < 0.0:
		base.z = max_forward_z
	# Stickhandling offset is raw — `_step_mouse_toward` provides the
	# motion smoothing across ticks. When two defenders converge from
	# opposite sides and the raw target alternates per tick, the
	# motion model averages them out (mouse oscillates within a small
	# range bounded by the per-tick step).
	return base + _stickhandle_offset(snapshot, self_pos, forward_dir)


# Computes the perpendicular puck-evade offset for stickhandling.
# Finds the closest opponent that's both within STICKHANDLE_THREAT_RADIUS_M
# AND closing on us at STICKHANDLE_CLOSING_VEL_MIN_M_S+. Returns an XZ
# offset perpendicular to `forward_dir`, in the direction OPPOSITE
# the threat's lateral side, with magnitude scaling linearly with
# proximity (closer threat → larger offset, capped at
# STICKHANDLE_OFFSET_MAX_M). Returns Vector3.ZERO if no qualifying
# threat is in range.
func _stickhandle_offset(snapshot: WorldSnapshot, self_pos: Vector3, forward_dir: Vector3) -> Vector3:
	# Right-axis (XZ): forward rotated 90° CW around Y.
	var right_axis: Vector3 = Vector3(forward_dir.z, 0.0, -forward_dir.x)
	var best_lateral: float = 0.0
	var best_dist: float = INF
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			continue
		var opp_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		var to_opp: Vector3 = opp_state.position - self_pos
		to_opp.y = 0.0
		var dist: float = to_opp.length()
		if dist > STICKHANDLE_THREAT_RADIUS_M or dist < 0.001:
			continue
		# Closing velocity: component of opponent's velocity in the
		# TOWARD-ME direction. Static or fleeing opponents don't
		# trigger evasion.
		var to_opp_norm: Vector3 = to_opp / dist
		var closing_vel: float = -opp_state.velocity.dot(to_opp_norm)
		if closing_vel < STICKHANDLE_CLOSING_VEL_MIN_M_S:
			continue
		if dist < best_dist:
			best_dist = dist
			best_lateral = right_axis.dot(to_opp)
	if best_dist == INF or absf(best_lateral) < 0.01:
		return Vector3.ZERO
	var magnitude: float = STICKHANDLE_OFFSET_MAX_M * (1.0 - clampf(
			best_dist / STICKHANDLE_THREAT_RADIUS_M, 0.0, 1.0))
	# Pull AWAY from threat's lateral side. If threat is on right
	# (positive lateral dot), offset is -right (pulls puck left).
	return -right_axis * signf(best_lateral) * magnitude


# Shot aim past the goalie's projected shadow. Uses the goalie's
# predicted position at the wrister window, matching how score_shoot
# sees the goalie when scoring from self_pos. Threads the goalie's
# CURRENT lateral velocity into the aim — a goalie sliding right
# will drift further right by the time the puck arrives, so the
# aim biases LEFT (the recovery side). Captures the "shoot back
# across the grain" pattern.
func _shot_aim_point(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var goalie: Vector3 = _predict_goalie_at(
			snapshot, BOT_WRISTER_LOOKAHEAD_S, self_pos)
	var goalie_vx: float = 0.0
	var opp_team_id: int = 1 - _team_id
	var opp_goalie_state: GoalieNetworkState = snapshot.goalie_states.get(opp_team_id)
	if opp_goalie_state != null:
		goalie_vx = opp_goalie_state.velocity_x
	return AIShotAim.compute_open_net_aim(
			self_pos, goalie,
			_attacking_goal_pos.z,
			GameRules.NET_HALF_WIDTH,
			AIActionScoring.GOALIE_SHADOW_HALF_M,
			AIShotAim.DEFAULT_CORNER_BIAS,
			goalie_vx)


# OFF_PUCK ready-stance aim: returns a target 2 m in front of the bot
# in the direction of motion. The actual mouse position is then
# stepped toward this target by `_step_mouse_toward` (motion-limited
# + noisy), which gives realistic rotation behaviour without per-
# state smoothing logic.
#
#   - FAR from anchor (> FACE_THREAT_NEAR_ANCHOR_M): aim direction =
#     toward anchor. SkaterMovementRules scales thrust by facing
#     alignment, so facing toward our destination = max skating
#     speed. Critical for backcheck.
#   - NEAR anchor: aim toward the defensive threat (man-to-man mark
#     if assigned, else the puck). Real defenders watch the threat as
#     they settle into coverage.
const READY_STANCE_AIM_FORWARD_M: float = 2.0
const FACE_THREAT_NEAR_ANCHOR_M: float = 2.0

# Persistent mouse position across all ticks. Every `input.mouse_world_pos`
# assignment goes through `_step_mouse_toward(target)` which moves
# `_mouse_pos` toward the target at MOUSE_MAX_SPEED_M_S, capped by the
# tick budget. The first call snaps to the target; the bool flag (rather
# than `_mouse_pos == Vector3.ZERO`) is what gates the snap, since
# legitimate XZ targets at world origin would otherwise re-trigger it.
# See MOUSE_MAX_SPEED_M_S comment block for rationale.
var _mouse_pos: Vector3 = Vector3.ZERO
var _mouse_pos_initialized: bool = false


# Steps `_mouse_pos` toward `target` at MOUSE_MAX_SPEED_M_S, capped by
# the tick budget. First call snaps to the target. Returns the result
# with small per-tick noise for organic feel. Replaces the various
# per-state smoothing methods we used to have — single consistent
# model for every aim target.
func _step_mouse_toward(target: Vector3) -> Vector3:
	if not _mouse_pos_initialized:
		_mouse_pos = Vector3(target.x, 0.0, target.z)
		_mouse_pos_initialized = true
	var to_target_x: float = target.x - _mouse_pos.x
	var to_target_z: float = target.z - _mouse_pos.z
	var dist: float = sqrt(to_target_x * to_target_x + to_target_z * to_target_z)
	var max_step: float = MOUSE_MAX_SPEED_M_S * MOUSE_TICK_DELTA
	if dist > max_step:
		var inv: float = 1.0 / dist
		_mouse_pos.x += to_target_x * inv * max_step
		_mouse_pos.z += to_target_z * inv * max_step
	else:
		_mouse_pos.x = target.x
		_mouse_pos.z = target.z
	# Apply noise to OUTPUT only — _mouse_pos stays smooth, output
	# adds organic per-tick wiggle (uniform [-NOISE, +NOISE] on each
	# axis). Wiggle doesn't accumulate.
	var nx: float = _rng.randf_range(-1.0, 1.0) * MOUSE_NOISE_STD_M
	var nz: float = _rng.randf_range(-1.0, 1.0) * MOUSE_NOISE_STD_M
	return Vector3(_mouse_pos.x + nx, 0.0, _mouse_pos.z + nz)


# Returns a target position 2 m in front of the bot. Direction is
# anchor when far, threat when near. The actual mouse position is
# stepped toward this target by `_step_mouse_toward` (the unified
# motion model), which gives the smoothing for free.
func _ready_stance_aim(self_pos: Vector3, anchor: Vector3, snapshot: WorldSnapshot) -> Vector3:
	var desired_dir: Vector3 = _compute_desired_aim_dir(self_pos, anchor, snapshot)
	return self_pos + desired_dir * READY_STANCE_AIM_FORWARD_M


# Picks the desired raw aim direction: anchor direction when far,
# threat direction when near anchor.
func _compute_desired_aim_dir(self_pos: Vector3, anchor: Vector3, snapshot: WorldSnapshot) -> Vector3:
	var to_anchor: Vector3 = anchor - self_pos
	if to_anchor.length() > FACE_THREAT_NEAR_ANCHOR_M:
		return to_anchor.normalized()
	return _face_threat_or_current(snapshot, self_pos)


# Reads the bot's facing as a unit XZ Vector3, with safe fallback.
func _read_facing_3d(snapshot: WorldSnapshot) -> Vector3:
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null or self_state.facing.length_squared() < 0.0001:
		return Vector3.FORWARD
	return Vector3(self_state.facing.x, 0.0, self_state.facing.y)


# Unit direction toward the defensive threat — the man-to-man mark
# if assigned, else the puck. Falls back to current facing if the
# threat is essentially on top of us (avoids a degenerate aim
# direction).
func _face_threat_or_current(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	# v2: no man-to-man marks, so threat is just the puck. Falls back
	# to current facing when puck is essentially on top of us.
	var to_puck: Vector3 = snapshot.puck_state.position - self_pos
	if to_puck.length() > 0.3:
		return to_puck.normalized()
	return _read_facing_3d(snapshot)



# Clamp an anchor to the playable rink with a small margin so steering
# doesn't pull the bot into the boards or behind the goal line.
# True iff any opponent is within `radius` of `self_pos` AND in the
# forward half-plane defined by `forward_dir`. Used by the wrister /
# slapper mid-charge bail check — defenders behind or perpendicular
# to the shooter can't realistically disrupt the windup, so only
# forward-cone threats count. Falls through to omnidirectional check
# when forward_dir is degenerate.
func _opponent_within_forward(snapshot: WorldSnapshot, self_pos: Vector3,
		forward_dir: Vector3, radius: float) -> bool:
	var fl: float = sqrt(forward_dir.x * forward_dir.x + forward_dir.z * forward_dir.z)
	var fwd_x: float = 0.0
	var fwd_z: float = 0.0
	var have_dir: bool = fl > 0.001
	if have_dir:
		fwd_x = forward_dir.x / fl
		fwd_z = forward_dir.z / fl
	var r2: float = radius * radius
	for peer_id: int in snapshot.skater_states:
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			continue
		var pos: Vector3 = snapshot.skater_states[peer_id].position
		var dx: float = pos.x - self_pos.x
		var dz: float = pos.z - self_pos.z
		if dx * dx + dz * dz >= r2:
			continue
		if not have_dir:
			return true   # degenerate forward — fall through to omni
		if dx * fwd_x + dz * fwd_z > 0.0:
			return true
	return false


# Tag-up anchor: when ghosted (offside), anchor at the NZ side of our
# own blue line, preserving current X. Bot skates straight back; the
# host clears `is_ghost` via `InfractionRules.has_tagged_up` once the
# bot crosses the blue line. OFFSIDE_HOLD_BUFFER_M makes the destination
# meaningfully past the line so we don't oscillate at the boundary.
func _tag_up_anchor(self_pos: Vector3) -> Vector3:
	# Our own blue line is at +z for team 0, -z for team 1. NZ side of
	# it means slightly less depth (toward midrink, away from own goal).
	var z: float = _own_goal_dir * (GameRules.BLUE_LINE_Z - OFFSIDE_HOLD_BUFFER_M)
	return Vector3(self_pos.x, 0.0, z)


func _clamp_anchor(p: Vector3) -> Vector3:
	var x: float = clampf(p.x,
			-GameRules.RINK_HALF_WIDTH + AIRoleHelpers.RINK_INSET_M,
			GameRules.RINK_HALF_WIDTH - AIRoleHelpers.RINK_INSET_M)
	var z: float = clampf(p.z,
			-GameRules.GOAL_LINE_Z + RINK_Z_INSET,
			GameRules.GOAL_LINE_Z - RINK_Z_INSET)
	# Push out of either crease — bots shouldn't anchor inside a goalie's
	# space. Steering's crease repel is the runtime force; this is the
	# destination-side guard so the anchor doesn't actively PULL the bot
	# into the crease in the first place.
	var xz := Vector2(x, z)
	if CreaseRules.is_in_crease(xz):
		var dir: Vector2 = CreaseRules.outward_direction(xz)
		var goal_z: float = signf(xz.y) * GameRules.GOAL_LINE_Z
		var center := Vector2(0.0, goal_z)
		var pushed: Vector2 = center + dir * (CreaseRules.ARC_RADIUS + RINK_Z_INSET)
		x = pushed.x
		z = pushed.y
	return Vector3(x, 0.0, z)


# Shifts an intercept point toward the center-ice X axis by
# CHASE_ANGLE_BIAS_M relative to the carrier's CURRENT X. The shift
# magnitude is capped at the carrier's |X| so we never overshoot to
# the opposite side of center — that would put the bot on the carrier's
# OUTSIDE and open the middle, the exact pattern we're trying to avoid.
# Carriers within CHASE_ANGLE_BIAS_M of center are left alone (no
# inside to take away). Static + private so it's unit-testable.
static func _angle_intercept_inside(target: Vector3, carrier_pos: Vector3) -> Vector3:
	if absf(carrier_pos.x) <= CHASE_ANGLE_BIAS_M:
		return target
	var bias: float = -signf(carrier_pos.x) * CHASE_ANGLE_BIAS_M
	return Vector3(target.x + bias, target.y, target.z)


func _lead_intercept(self_pos: Vector3, self_vel: Vector3, puck_pos: Vector3, puck_vel: Vector3) -> Vector3:
	var dt: float = CHASE_MAX_LOOKAHEAD_S / float(CHASE_TRAJECTORY_STEPS)
	# Use puck-physics-aware prediction (ice friction + board bounces).
	# Constant-velocity over 1.5 s consistently overshot where a sliding
	# puck actually ends up; the new model matches Jolt's resolution.
	var traj: Array[Vector3] = AITrajectory.predict_puck(
			puck_pos, puck_vel, CHASE_TRAJECTORY_STEPS, dt)
	# Closing-rate-aware reach: bot's velocity component toward the
	# candidate intercept boosts the effective chase speed (bot already
	# committed in that direction has a head start). Component AWAY
	# from the target subtracts (bot has to redirect, slower reach).
	# Capped at ±50% of CHASE_SPEED so extreme velocities don't blow
	# up the estimate. Without this, the formula assumes bot starts
	# at rest and picks intercepts that bots currently moving the
	# wrong way can't actually reach — produces visible bad angles
	# on slow-moving pucks.
	var v_cap: float = AIActionScoring.SKATER_REF_SPEED_M_S * 0.5
	# Track the previous step's "reach surplus" (eff_speed × t − dist).
	# When it crosses zero between step i-1 and step i we have a
	# bracket; linear-interp the actual intercept fraction within that
	# step rather than always returning traj[i] (over-runs by up to dt).
	var prev_surplus: float = -INF
	var prev_pos: Vector3 = self_pos
	for i: int in traj.size():
		var t_step: float = (i + 1) * dt
		var dx: float = traj[i].x - self_pos.x
		var dz: float = traj[i].z - self_pos.z
		var dist: float = sqrt(dx * dx + dz * dz)
		var v_along: float = 0.0
		if dist > 0.001:
			var inv_d: float = 1.0 / dist
			v_along = self_vel.x * dx * inv_d + self_vel.z * dz * inv_d
		var effective_speed: float = AIActionScoring.SKATER_REF_SPEED_M_S + clampf(v_along, -v_cap, v_cap)
		var surplus: float = effective_speed * t_step - dist
		if surplus >= 0.0:
			if prev_surplus > -INF and prev_surplus < 0.0:
				# Bracket found: surplus crossed zero between (i-1, i).
				# Linear-interp the puck position for sub-step accuracy.
				var frac: float = -prev_surplus / (surplus - prev_surplus)
				return prev_pos.lerp(traj[i], frac)
			return traj[i]
		prev_surplus = surplus
		prev_pos = traj[i]
	# Puck is moving away faster than we can chase — aim at the last
	# projected position so we at least head in the right direction.
	return traj[traj.size() - 1] if traj.size() > 0 else puck_pos


# True iff a TEAMMATE (not me, not opp) currently has the puck. Used to
# suppress CHASE_PUCK so non-carrier bots don't sprint at their own
# teammate carrier with their blade out.
func _teammate_has_puck(snapshot: WorldSnapshot) -> bool:
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier == -1 or carrier == _peer_id:
		return false
	return int(_team_id_resolver.call(carrier)) == _team_id


# Where to drop into when the puck is lost mid-on-puck-state. The
# closest teammate to the puck chases; everyone else falls into
# normal off-puck slot positioning.
func _post_puck_lost_state(snapshot: WorldSnapshot) -> State:
	if snapshot == null or snapshot.puck_state == null:
		return State.OFF_PUCK
	# If someone has the puck (likely a teammate snagged it), no chase.
	if snapshot.puck_state.carrier_peer_id != -1:
		return State.OFF_PUCK
	var s: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if s == null:
		return State.OFF_PUCK
	return State.CHASE_PUCK if _is_closest_teammate_to_puck_at(snapshot, s.position) else State.OFF_PUCK


# True iff the puck is loose (no carrier) AND we are the closest
# teammate to it. Used by OFF_PUCK→CHASE_PUCK and CHASE_PUCK exit.
# Replaces the v1 "is F1?" gate — slot labels don't directly drive
# chase decisions in v2.
func _should_chase_loose_puck(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	if snapshot == null or snapshot.puck_state == null:
		return false
	if snapshot.puck_state.carrier_peer_id != -1:
		return false  # someone has the puck
	return _is_closest_teammate_to_puck_at(snapshot, self_pos)


# Returns true if this bot is the closest teammate to the current
# puck position. Used as the loose-puck-chase trigger.
func _is_closest_teammate_to_puck_at(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	var puck_pos: Vector3 = snapshot.puck_state.position
	var dx: float = self_pos.x - puck_pos.x
	var dz: float = self_pos.z - puck_pos.z
	var my_d2: float = dx * dx + dz * dz
	for pid: int in snapshot.skater_states:
		if pid == _peer_id:
			continue
		if int(_team_id_resolver.call(pid)) != _team_id:
			continue
		var pos: Vector3 = snapshot.skater_states[pid].position
		var ox: float = pos.x - puck_pos.x
		var oz: float = pos.z - puck_pos.z
		if ox * ox + oz * oz < my_d2:
			return false
	return true


# Detects "puck just became loose" and arms the engagement cooldown if
# we were close enough to be involved. Single rule covers both sides:
#   - We had the puck and got stripped: prev=us, now=-1, distance≈0
#   - We stick-checked someone: prev=opp, now=-1, we were near to do it
# The carrier-just-changed-to-someone-else case (a teammate or opp picked
# up cleanly without us being close) doesn't fire — prev was set, now
# is the new carrier, not -1.
#
# Cooldown duration scales with our skating speed at the moment of
# engagement: a bot moving at full speed was committed harder and takes
# longer to reset; a near-stationary bot recovers fast. Two bots in the
# same engagement almost never have identical speeds, so this also
# breaks the lockstep that made bots re-engage in unison.
func _update_engagement_cooldown(snapshot: WorldSnapshot, self_state: SkaterNetworkState) -> void:
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if _prev_carrier_peer_id != -1 and carrier == -1:
		var self_pos: Vector3 = self_state.position
		var puck_pos: Vector3 = snapshot.puck_state.position
		var dx: float = puck_pos.x - self_pos.x
		var dz: float = puck_pos.z - self_pos.z
		if dx * dx + dz * dz < ENGAGEMENT_PROXIMITY_M * ENGAGEMENT_PROXIMITY_M:
			var v: Vector3 = self_state.velocity
			var speed: float = sqrt(v.x * v.x + v.z * v.z)
			var ratio: float = clampf(speed / AIActionScoring.SKATER_REF_SPEED_M_S, 0.0, 1.0)
			_engagement_cooldown = int(round(lerpf(
					float(ENGAGEMENT_COOLDOWN_MIN_TICKS),
					float(ENGAGEMENT_COOLDOWN_MAX_TICKS),
					ratio)))
	_prev_carrier_peer_id = carrier
	if _engagement_cooldown > 0:
		_engagement_cooldown -= 1


func _set_state(s: State) -> void:
	if s != _state:
		# Wrister charge resets on every SHOOT_PRESSED entry — fresh
		# sweep direction, fresh tick count, fresh prev_mouse_screen_pos
		# (the SkaterStateMachine seeds that from input.mouse_screen_pos
		# at the entry edge).
		if s == State.SHOOT_PRESSED:
			_shoot_charge_tick = 0
			_shoot_sweep_dir_xy = Vector2.ZERO
		# Slapper charge resets on entry: tick counter to zero and aim
		# target cleared so we don't fire with a stale target if we
		# bail before tick 0 finishes.
		if s == State.SLAPPER_PRESSED:
			_slapper_charge_tick = 0
			_slapper_aim_target = Vector3.ZERO
		# Intent + wait counter reset on CARRY entry so a new puck
		# pickup gets a fresh re-evaluation rather than inheriting
		# stale state from a previous CARRY. _carrier.clear_intent()
		# also forces an immediate re-eval (cooldown to 0) on the
		# next decide() call.
		if s == State.CARRY:
			_intended_action = State.CARRY
			_intent_wait_ticks = 0
			_carrier.clear_intent()
		_state = s
		_ticks_in_state = 0


func _reset_to_off_puck() -> void:
	_state = State.OFF_PUCK
	_ticks_in_state = 0
	_pass_target_peer_id = -1
	_carrier.reset()
