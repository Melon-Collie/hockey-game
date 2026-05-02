class_name SkaterAgentStateMachine
extends RefCounted

# Per-bot AI state machine. Mirrors the dispatch + match + per-state handler
# pattern used by Scripts/controllers/skater_state_machine.gd. Owned by
# SkaterAgent; the agent owns the InputState scratch buffer and the
# AIController glue, the SM owns identity + state transitions + per-state
# behavior.
#
# Adding a new behavior (PASS, DUMP, PROTECT) is a clean four-step recipe:
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
	OFF_PUCK,        # default off-puck — anchor above puck, aim at goal
	CHASE_PUCK,      # F1 without puck — pursue, blade on the puck
	CARRY,           # with puck, no committed action — aim at goal
	SHOOT_PRESSED,   # one-tick press window aimed at goalie shadow
	PASS_PRESSED,    # one-tick press window aimed at a teammate's lead position
	DUMP_PRESSED,    # one-tick press window aimed at a deep-zone clear
}

# Off-puck anchor offsets. F2 is the triangle apex on the strong side
# (puck's X side), 3 m off the puck X-wise and 2 m back toward our own
# goal Z-wise. F3 is the weak-side trailer, 5 m mirrored across the
# puck X and 8 m back. The legacy OFF anchor (no F2/F3 role assigned —
# 4+ teammates case) keeps the original above-puck behavior.
const F2_OFFSET_X: float = 3.0
const F2_OFFSET_Z_BACK: float = 2.0
const F3_OFFSET_X_WEAK: float = 5.0
const F3_OFFSET_Z_BACK: float = 8.0
# When the puck is in our offensive zone, F3 plays "high man" — anchors
# just inside the OZ blue line (BLUE_LINE_Z + this offset, on the OZ
# side) instead of trailing the puck. Real-hockey safety valve: high
# man can backcheck if the play turns over and skates the other way.
const F3_HIGH_MAN_OZ_DEPTH_M: float = 1.0
const LEGACY_OFF_DEPTH: float = 4.0
# Man-to-man gap: defender anchors this far on the goal-side of their
# mark, on the line from mark → our net.
const MAN_GAP_DEPTH_M: float = 1.0
# Lead time for predicting mark position. Defender anchors against where
# the mark WILL BE, not where they are right now — without this, the
# defender is always trailing a step behind a moving forward.
const MAN_LEAD_TIME_S: float = 0.5
# Strong-side X is sign(puck.x), but only when the puck is meaningfully
# off-center; below this we default to the +X side so we don't flip
# F2/F3 sides every time the puck wiggles through center.
const STRONG_SIDE_X_DEADBAND: float = 0.5
# Margins from the rink edge / goal line that anchors are clamped inside of.
const RINK_X_INSET: float = 0.5
const RINK_Z_INSET: float = 1.0

const QUIET_EYE_TICKS: int = 8
# How wide the goalie's shadow on the net plane should be considered
# (meters, half-width). Tuneable in playtest.
const GOALIE_SHADOW_HALF: float = 0.3
# How far in front of the goal line the carrier sits when they reach the
# offensive zone — high slot, not in the cage.
const SLOT_DEPTH_FROM_GOAL_LINE: float = 5.0
# Reference puck speed for pass leading. Lead time = distance to receiver
# / this constant — a longer pass leads further because it takes longer
# to arrive. Approximate quick-wrister puck speed; doesn't have to be
# perfect, small over/under just shifts the aim point a few cm.
const PASS_PUCK_SPEED_REF_M_S: float = 22.0
# Cap on pass lead so a degenerate state (zero pass speed estimate, or a
# long bomb across the rink) doesn't project the receiver into next week.
const PASS_LEAD_MAX_S: float = 0.6
# DUMP aim — deep into the attacking zone, on the bot's strong side.
# DUMP_CORNER_X is the absolute X of the dump target (corner area).
# DUMP_DEPTH_FROM_GOAL_M is how far in front of the attacking goal line
# the dump lands (deep-zone corner, far from the net so the goalie
# can't easily glove it).
const DUMP_CORNER_X: float = 8.0
const DUMP_DEPTH_FROM_GOAL_M: float = 6.0
# After a puck-engagement event (we got stripped, or we just stripped
# someone — both detected as "puck became loose while we were close"),
# pull the blade back to our body for this many ticks. Speed-scaled:
# a bot at full skating speed was committed harder and takes longer
# to reset; a slow bot recovers quickly. The variance breaks lockstep
# between two bots involved in the same engagement (their speeds are
# almost never identical).
const ENGAGEMENT_COOLDOWN_MIN_TICKS: int = 24    # ~100 ms at 240 Hz
const ENGAGEMENT_COOLDOWN_MAX_TICKS: int = 96    # ~400 ms at 240 Hz
const ENGAGEMENT_SPEED_REF_M_S: float = 10.5     # SkaterController.max_speed default
const ENGAGEMENT_PROXIMITY_M: float = 2.0        # blade-on-puck range

# Reference top skating speed used for chase intercept lookahead. Doesn't
# need to match SkaterController exactly — small over/under shifts where
# the intercept point lands but doesn't break behavior.
const CHASE_SPEED_REF_M_S: float = 10.5
# Cap on lead lookahead so a barely-moving puck doesn't project an
# intercept point a million seconds away.
const CHASE_MAX_LOOKAHEAD_S: float = 1.5
# Steps per chase trajectory walk. Granular enough that the rink clamp
# catches a sliding puck hitting the boards mid-flight (so we don't aim
# at a point inside the wall), cheap enough at 6 Hz brain tick.
const CHASE_TRAJECTORY_STEPS: int = 12

# Carrier anchor search step. The carrier samples candidate positions
# this far from their current spot in 8 cardinal directions and picks
# the one with the best shoot-or-pass score. Bot drifts toward the
# best-option spot tick by tick — no teleporting, just gradient
# follow.
const CARRY_SEARCH_STEP_M: float = 3.0
# Margin from the attacking goal line we won't drift past while
# searching (carrier shouldn't anchor behind the net).
const CARRY_GOAL_LINE_BUFFER_M: float = 1.0

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
# evaluate next tick (probably picks DUMP or PASS).
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
# Reused buffer for action scoring's opponent-position list. Cleared at
# the top of _pick_action.
var _scratch_opponents: Array[Vector3] = []
# Parallel buffer of opponent positions PREDICTED forward by the wrister
# charge window. Used only by score_shoot — a wrister is a 250 ms time
# commitment, so we score it against where defenders will be at release
# time, not where they are at decision time. Pass / dump are one-tick
# and use _scratch_opponents (current positions) as before.
var _scratch_opponents_shoot: Array[Vector3] = []

# Set when CARRY commits to PASS_PRESSED; consumed by _state_pass_pressed
# the next tick. 0 means "no current pass target" (real peer_ids are
# either 1+ for humans or 10000+ for bots, so 0 is safe as sentinel).
var _pass_target_peer_id: int = 0

# Engagement cooldown — see ENGAGEMENT_COOLDOWN_TICKS. _prev_carrier
# tracks last tick's puck.carrier_peer_id so we can detect the
# transition into "loose".
var _engagement_cooldown: int = 0
var _prev_carrier_peer_id: int = -1

# Set when CARRY commits to SHOOT_PRESSED; consumed by _state_shoot_pressed
# to drive the elevation flag. Picked from the goalie state at decision
# time — a butterfly/sliding goalie has top corners exposed, an upright
# goalie blocks elevated with the glove/blocker.
var _shot_is_elevated: bool = false

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
# Wind-up start position in WORLD space — captured at SHOOT_PRESSED
# entry. mouse_world_pos lerps from this to the aim point across the
# charge, so the blade IK visibly sweeps from forehand wind-up through
# to the puck.
var _shoot_wind_up_start: Vector3 = Vector3.ZERO
var _shoot_aim_target: Vector3 = Vector3.ZERO

# Debug: live scores from the most recent _pick_action tick. Read by
# AIController at ~10 Hz to drive the floating per-bot label. Updated
# every CARRY tick; stale when the bot isn't carrying (label shows
# the last available snapshot in that case).
var debug_scores: Array[String] = []
# Last non-skating decision the bot committed to (e.g. "SHOOT" /
# "PASS→3" / "DUMP"). Set when _pick_action transitions into one of
# the press states; persists until the next decision.
var debug_last_decision: String = ""


# ── Setup ────────────────────────────────────────────────────────────────────

func setup(peer_id: int, team_id: int, brain: TeamBrain, resolver: Callable,
		is_left_handed: bool) -> void:
	_peer_id = peer_id
	_team_id = team_id
	_own_goal_dir = 1.0 if team_id == 0 else -1.0
	# Aim point at the opposing goal mouth. Used as fallback aim and as
	# the net plane for shot-aim geometry. y=0 — blade IK is 2D for now.
	_attacking_goal_pos = Vector3(0.0, 0.0, -_own_goal_dir * GameRules.GOAL_LINE_Z)
	_team_brain = brain
	_team_id_resolver = resolver
	_is_left_handed = is_left_handed


# ── State accessors ──────────────────────────────────────────────────────────

func get_state() -> State:
	return _state


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
	# to OFF_PUCK so _off_puck_anchor's tag-up branch routes us back to
	# the blue line. The host clears is_ghost via has_tagged_up once we
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
		State.PASS_PRESSED:
			_state_pass_pressed(input, snapshot, self_pos, have_puck)
		State.DUMP_PRESSED:
			_state_dump_pressed(input, snapshot, self_pos, have_puck)


# ── State handlers ───────────────────────────────────────────────────────────

func _state_off_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Anchor depends on role: F2 strong-side support, F3 weak-side trailer,
	# or legacy "above puck" for any unassigned role (4+ teammate case).
	var anchor: Vector3 = _off_puck_anchor(snapshot.puck_state.position, self_pos, snapshot)
	_apply_steering(input, snapshot, self_pos, anchor)
	input.mouse_world_pos = _attacking_goal_pos
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif _is_f1() and not _teammate_has_puck(snapshot):
		_set_state(State.CHASE_PUCK)


func _state_chase_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lead intercept: aim at where the puck WILL be when we'd actually
	# arrive, not at where it is now. Per-bot t_arrival (distance / max
	# speed) means two bots converging on the same loose puck compute
	# different intercept points, breaking the "both glued to the same
	# puck position" pattern.
	var puck_pos: Vector3 = snapshot.puck_state.position
	var target: Vector3 = _lead_intercept(self_pos, puck_pos, snapshot.puck_state.velocity)
	_apply_steering(input, snapshot, self_pos, target)
	# Aim: normally blade-on-intercept, but during the engagement cooldown
	# (just got stripped or just stick-checked someone) pull the blade
	# back to our body so the puck can settle without auto-magnetting
	# back to us. Once the puck is inside our blade reach, snap the aim
	# to the puck's ACTUAL position — leading at this range puts the
	# blade past a puck that's already on our stick.
	if _engagement_cooldown > 0:
		input.mouse_world_pos = Vector3(self_pos.x, 0.0, self_pos.z)
	elif self_pos.distance_to(puck_pos) <= BLADE_REACH_M:
		input.mouse_world_pos = puck_pos
	else:
		input.mouse_world_pos = target
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif not _is_f1() or _teammate_has_puck(snapshot):
		# Either we're not F1 anymore, or a teammate just picked up the
		# puck — in both cases, drop back to off-puck support instead of
		# pinning our blade to the puck on our own teammate's stick.
		_set_state(State.OFF_PUCK)


func _state_carry(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# In NZ/DZ, drive toward the high slot to enter the offensive zone.
	# Once in OZ, search for the position with the best shot/pass option
	# and drift toward it — patient cycling.
	var anchor: Vector3 = _carry_anchor(snapshot, self_pos)
	_apply_steering(input, snapshot, self_pos, anchor)
	input.mouse_world_pos = _shot_aim_point(snapshot, self_pos)
	# Transitions
	if not have_puck:
		_set_state(_post_puck_lost_state())
		return
	if _ticks_in_state < QUIET_EYE_TICKS:
		return
	# Quiet-eye expired — pick the highest-scoring action. CARRY is the
	# implicit default if nothing clears the threshold (set elsewhere as
	# AIActionScoring.ACTION_THRESHOLD).
	_pick_action(snapshot, self_pos)


func _state_shoot_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lost the puck mid-charge — bail. SkaterStateMachine's release path
	# is a no-op without the puck, so we don't need to force a release.
	if not have_puck:
		_set_state(_post_puck_lost_state())
		return

	# Mid-charge bail: opponent closing in. block_held cancels WRISTER_AIM
	# back to SKATING_WITH_PUCK without a release. Skipped on tick 0 — we
	# just made the decision, give it at least one frame to commit.
	if _shoot_charge_tick > 0 and _opponent_within(snapshot, self_pos, BOT_WRISTER_BAIL_RADIUS_M):
		input.block_held = true
		_set_state(State.CARRY)
		return

	_apply_slot_steering(input, snapshot, self_pos)
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
		_shoot_aim_target = _shot_aim_point(snapshot, self_pos)
		var dir_xz: Vector3 = Vector3(
				_shoot_aim_target.x - self_pos.x, 0.0, _shoot_aim_target.z - self_pos.z)
		var aim_dir: Vector3
		if dir_xz.length_squared() > 0.0001:
			aim_dir = dir_xz.normalized()
		else:
			aim_dir = Vector3(0.0, 0.0, 1.0)
		# Forehand-side perpendicular: 90° rotation of aim_dir in XZ.
		# RH winds up on the +X-player-local side (= aim_dir rotated 90°
		# CW); LH on the -X side (90° CCW).
		var perp_sign: float = -1.0 if _is_left_handed else 1.0
		var forehand_perp: Vector3 = Vector3(
				aim_dir.z * perp_sign, 0.0, -aim_dir.x * perp_sign)
		_shoot_wind_up_start = (
				self_pos
				- aim_dir * BOT_WRISTER_WIND_UP_BACK_M
				+ forehand_perp * BOT_WRISTER_WIND_UP_SIDE_M)
		_shoot_sweep_dir_xy = Vector2(aim_dir.x, aim_dir.z)
		input.shoot_pressed = true

	# Lerp mouse_world_pos from wind-up start to aim across the charge.
	# Blade IK chases this, so the player visibly draws the stick back
	# on the forehand and sweeps through to the aim point.
	var t: float = float(_shoot_charge_tick) / float(BOT_WRISTER_CHARGE_TICKS)
	input.mouse_world_pos = _shoot_wind_up_start.lerp(_shoot_aim_target, t)

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
		_set_state(State.CARRY)


func _state_pass_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	_apply_slot_steering(input, snapshot, self_pos)
	# Aim at the receiver's lead position. Quick-shot direction is
	# blade-from-player at release, and the blade IK swings toward
	# mouse_world_pos — so this fires the puck along the bot→receiver
	# vector.
	input.mouse_world_pos = _pass_aim_point(snapshot, self_pos)
	input.shoot_pressed = true
	input.shoot_held = true
	# Same one-tick-then-exit pattern as SHOOT_PRESSED. Clear the target
	# either way so a future PASS picks a fresh one.
	_pass_target_peer_id = 0
	if not have_puck:
		_set_state(_post_puck_lost_state())
	else:
		_set_state(State.CARRY)


func _state_dump_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	_apply_slot_steering(input, snapshot, self_pos)
	# Aim at a deep corner of the attacking zone on our strong side —
	# typical hockey "dump it deep, chase it down." Quick-shot direction
	# is blade-from-player so the puck flies along the bot→corner
	# vector; even at fixed quick_shot_power the dump usually clears
	# the bot's zone, which is what matters.
	input.mouse_world_pos = _dump_aim_point(self_pos)
	input.shoot_pressed = true
	input.shoot_held = true
	if not have_puck:
		_set_state(_post_puck_lost_state())
	else:
		_set_state(State.CARRY)


# ── Internal helpers ─────────────────────────────────────────────────────────

# Anchor + steering shared by CARRY / SHOOT_PRESSED / PASS_PRESSED. Each
# state sets `input.mouse_world_pos` itself because the aim differs
# (goal-shadow vs receiver lead).
func _apply_slot_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - SLOT_DEPTH_FROM_GOAL_LINE)
	_apply_steering(input, snapshot, self_pos, Vector3(0.0, 0.0, slot_z))


# Score every applicable action and transition into the highest-scoring
# state. CARRY is the implicit default — if neither SHOOT nor any PASS
# clears AIActionScoring.ACTION_THRESHOLD we stay in CARRY without
# transitioning (next tick re-evaluates).
#
# Mutates _pass_target_peer_id when PASS wins.
func _pick_action(snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	# Build opponents lists. Current positions for pass/dump/receiver
	# pressure (one-tick decisions); predicted-forward positions for
	# wrister scoring (250 ms time commitment — defender 4 m away at
	# 5 m/s closing covers half that gap before the shot fires).
	_scratch_opponents.clear()
	_scratch_opponents_shoot.clear()
	for peer_id: int in snapshot.skater_states:
		if int(_team_id_resolver.call(peer_id)) != _team_id and peer_id != _peer_id:
			var s: SkaterNetworkState = snapshot.skater_states[peer_id]
			_scratch_opponents.append(s.position)
			_scratch_opponents_shoot.append(AITrajectory.predict_at(
					s.position, s.velocity, BOT_WRISTER_LOOKAHEAD_S))

	# SHOOT score — at most one. Falls back to attacking_goal_pos if no
	# opposing goalie is buffered (e.g., first-frame edge case).
	var goalie_pos: Vector3 = _attacking_goal_pos
	var opp_team_id: int = 1 - _team_id
	var opp_goalie: GoalieNetworkState = snapshot.goalie_states.get(opp_team_id)
	if opp_goalie != null:
		goalie_pos = Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z)
	var shoot_score: float = AIActionScoring.score_shoot(
			self_pos, _attacking_goal_pos, goalie_pos,
			GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
			_scratch_opponents_shoot)

	# PASS score — one per teammate. Track the best. Ghosted teammates
	# (currently offside) can't legally receive — their collision masks
	# are off, so the puck would pass through them. Skip outright.
	var best_pass_peer: int = 0
	var best_pass_score: float = 0.0
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) != _team_id:
			continue
		var receiver_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		if receiver_state.is_ghost:
			continue
		var receiver: Vector3 = receiver_state.position
		var s: float = AIActionScoring.score_pass(
				self_pos, receiver, receiver_state.facing,
				_attacking_goal_pos, goalie_pos,
				GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
				_scratch_opponents)
		if s > best_pass_score:
			best_pass_score = s
			best_pass_peer = peer_id

	# DUMP score — fires when pressured + far from attacking goal. Pure
	# function of pressure and zone, doesn't compete on shot/pass quality.
	var dump_score: float = AIActionScoring.score_dump(
			self_pos, _attacking_goal_pos, _own_goal_dir,
			GameRules.BLUE_LINE_Z, _scratch_opponents)

	# Debug: snapshot the per-tick scores for the on-ice label. Sorted
	# desc, top 3, peer id mod 1000 for compactness.
	var rows: Array = [
			["shoot", shoot_score],
			["pass→%d" % (best_pass_peer % 1000) if best_pass_peer != 0 else "pass", best_pass_score],
			["dump", dump_score],
	]
	rows.sort_custom(func(a, b): return a[1] > b[1])
	debug_scores.clear()
	for r: Array in rows:
		debug_scores.append("%s:%.2f" % [r[0], r[1]])

	# Pick the winner. Threshold gates "do nothing" — when all scores
	# are weak (e.g., bot in own zone with no pressure or teammate
	# ahead), CARRY wins implicitly.
	var max_score: float = maxf(maxf(shoot_score, best_pass_score), dump_score)
	if max_score < AIActionScoring.ACTION_THRESHOLD:
		return
	if shoot_score >= best_pass_score and shoot_score >= dump_score:
		_shot_is_elevated = _should_elevate_shot(snapshot)
		debug_last_decision = "SHOOT"
		_set_state(State.SHOOT_PRESSED)
	elif best_pass_score >= dump_score:
		_pass_target_peer_id = best_pass_peer
		debug_last_decision = "PASS→%d" % (best_pass_peer % 1000)
		_set_state(State.PASS_PRESSED)
	else:
		debug_last_decision = "DUMP"
		_set_state(State.DUMP_PRESSED)


# Lead the receiver by their flight-time along their current velocity.
# Long passes lead further than short ones — the puck takes longer to
# arrive, so the receiver moves further during transit. Falls back to
# the goal if the target slot disappeared between picking and pressing
# (rare — bot demoted, peer disconnected, etc.).
func _pass_aim_point(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var receiver: SkaterNetworkState = snapshot.skater_states.get(_pass_target_peer_id)
	if receiver == null:
		return _attacking_goal_pos
	# Flight time estimate — distance to receiver / pass speed. Capped so
	# a degenerate near-zero-speed estimate can't blow up the lead.
	var dist: float = self_pos.distance_to(receiver.position)
	var flight_t: float = clampf(
			dist / PASS_PUCK_SPEED_REF_M_S, 0.0, PASS_LEAD_MAX_S)
	return AITrajectory.predict_at(receiver.position, receiver.velocity, flight_t)


func _apply_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, anchor: Vector3) -> void:
	# Single-pass split into teammate vs opponent buckets — both feed
	# AISteering's repel forces.
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

	input.move_vector = AISteering.compute_move_vector(
			self_pos, anchor, _scratch_teammates, _scratch_opponents,
			lane_start, lane_end,
			GameRules.RINK_HALF_WIDTH, GameRules.RINK_HALF_LENGTH)


# True if the opposing goalie is "down" — butterfly, sliding, or
# recovering. Top corners are exposed in all three poses; an elevated
# wrister beats a glove that's still 0.6 m off the ice. Standing /
# ready / RVH stay upright, so a ground shot past the shadow is the
# higher-EV pick. Match the int values in GoalieController.State so
# we don't depend on the controller class being available here.
const _GOALIE_STATE_BUTTERFLY: int = 1   # GoalieController.State.BUTTERFLY
const _GOALIE_STATE_RECOVERING: int = 2  # GoalieController.State.RECOVERING
const _GOALIE_STATE_SLIDING: int = 6     # GoalieController.State.SLIDING

func _should_elevate_shot(snapshot: WorldSnapshot) -> bool:
	var opp_team_id: int = 1 - _team_id
	var opp_goalie: GoalieNetworkState = snapshot.goalie_states.get(opp_team_id)
	if opp_goalie == null:
		return false
	var s: int = opp_goalie.state_enum
	return s == _GOALIE_STATE_BUTTERFLY \
			or s == _GOALIE_STATE_RECOVERING \
			or s == _GOALIE_STATE_SLIDING


# Shot aim past the goalie's projected shadow. Falls back to goal center
# if the opposing goalie state isn't buffered yet.
func _shot_aim_point(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var opp_team_id: int = 1 - _team_id
	var opp_goalie: GoalieNetworkState = snapshot.goalie_states.get(opp_team_id)
	if opp_goalie == null:
		return _attacking_goal_pos
	var goalie_pos := Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z)
	return AIShotAim.compute_open_net_aim(
			self_pos, goalie_pos,
			_attacking_goal_pos.z,
			GameRules.NET_HALF_WIDTH,
			GOALIE_SHADOW_HALF)


func _is_f1() -> bool:
	return _team_brain != null and _team_brain.get_role(_peer_id) == AIRoleAssignment.ROLE_F1


# Off-puck anchor selection.
#   - DZ + opp possession (or loose puck in DZ): switch to man-to-man.
#     F2/F3 anchor on their assigned mark, 1 m goal-side.
#   - Otherwise: zone-ish triangle. F2 strong-side support, F3 weak-side
#     trailer, OFF (4+ teammate fallback) plays legacy above-puck.
func _off_puck_anchor(puck_pos: Vector3, self_pos: Vector3, snapshot: WorldSnapshot) -> Vector3:
	# Tag up: if WE are ghosted, ignore role/coverage entirely and head
	# back to the NZ side of the blue line. Anchor preserves our X so
	# the steering doesn't pull us laterally — fastest tag is straight
	# back. Host's InfractionRules.has_tagged_up clears is_ghost the
	# moment we cross. Already on the NZ side, so no further cap needed.
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state != null and self_state.is_ghost:
		return _tag_up_anchor(self_pos)

	var anchor: Vector3
	# Man-to-man takes priority in our defensive zone when the opp has
	# the puck (or it's loose in our zone). The brain publishes the
	# coverage map at 6 Hz; we just look up our mark.
	if _should_play_man_to_man(snapshot):
		var mark_pid: int = _team_brain.get_coverage_target(_peer_id) if _team_brain != null else 0
		if mark_pid != 0:
			var mark: SkaterNetworkState = snapshot.skater_states.get(mark_pid)
			if mark != null:
				return _cap_offside(_man_anchor(mark), snapshot)

	var role: StringName = _team_brain.get_role(_peer_id) if _team_brain != null else AIRoleAssignment.ROLE_OFF
	match role:
		AIRoleAssignment.ROLE_F2:
			anchor = _f2_anchor(puck_pos)
		AIRoleAssignment.ROLE_F3:
			anchor = _f3_anchor(puck_pos)
		_:
			# Legacy / fallback — Phase 3 anchor (above puck on own-net
			# side, X tracking the bot's current X to avoid sliding sideways).
			var anchor_z: float = puck_pos.z + _own_goal_dir * LEGACY_OFF_DEPTH
			anchor = _clamp_anchor(Vector3(self_pos.x, 0.0, anchor_z))
	return _cap_offside(anchor, snapshot)


# F2 anchor — triangle apex on the strong side (the side of the rink
# the puck is on), 3 m off the puck X and 2 m back toward our own
# goal Z. With STRONG_SIDE_X_DEADBAND we don't flip strong/weak when
# the puck wiggles through the center.
func _f2_anchor(puck_pos: Vector3) -> Vector3:
	var strong_x: float = signf(puck_pos.x) if absf(puck_pos.x) > STRONG_SIDE_X_DEADBAND else 1.0
	var x: float = puck_pos.x + strong_x * F2_OFFSET_X
	var z: float = puck_pos.z + _own_goal_dir * F2_OFFSET_Z_BACK
	return _clamp_anchor(Vector3(x, 0.0, z))


# Cap an off-puck anchor so we don't ask the bot to skate ahead of the
# puck across the OZ blue line. While the puck is in NZ or our DZ, any
# anchor that lands in our attacking zone gets pulled back to the NZ
# side of the line. Once the puck enters the OZ, the cap lifts and
# off-puck teammates are free to flow in for support.
#
# Carriers go through _carry_anchor, not here, so the puck is brought
# in normally — the cap only pins the support skaters.
func _cap_offside(anchor: Vector3, snapshot: WorldSnapshot) -> Vector3:
	var puck_z: float = snapshot.puck_state.position.z
	# Puck already in OZ? No cap.
	if -_own_goal_dir * puck_z > GameRules.BLUE_LINE_Z:
		return anchor
	# Puck not in OZ. Anchor allowed only on NZ/DZ side of the blue line.
	if -_own_goal_dir * anchor.z <= GameRules.BLUE_LINE_Z:
		return anchor
	# Anchor sits in OZ — pull it back to the NZ side, X unchanged so
	# steering doesn't drag the bot laterally.
	var hold_z: float = -_own_goal_dir * (GameRules.BLUE_LINE_Z - OFFSIDE_HOLD_BUFFER_M)
	return _clamp_anchor(Vector3(anchor.x, 0.0, hold_z))


# True iff any opponent is within `radius` of `pos` in XZ. Used by
# the wrister-charge bail; cheap at 6 opponents max so we recompute
# rather than caching.
func _opponent_within(snapshot: WorldSnapshot, pos: Vector3, radius: float) -> bool:
	var r2: float = radius * radius
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			continue
		var op: Vector3 = snapshot.skater_states[peer_id].position
		var dx: float = op.x - pos.x
		var dz: float = op.z - pos.z
		if dx * dx + dz * dz < r2:
			return true
	return false


# Tag-up anchor: just on the NZ side of the OZ blue line, preserving X
# so steering pulls us straight back. Buffer past the line so the
# host's has_tagged_up doesn't toggle on/off at the boundary.
func _tag_up_anchor(self_pos: Vector3) -> Vector3:
	var tag_z: float = -_own_goal_dir * (GameRules.BLUE_LINE_Z - OFFSIDE_HOLD_BUFFER_M)
	return _clamp_anchor(Vector3(self_pos.x, 0.0, tag_z))


# True iff we're in our own zone defending — opp has the puck (or it's
# loose in our zone). Man-to-man only fires here; everywhere else (NZ,
# OZ, own possession) we keep the zone triangle.
func _should_play_man_to_man(snapshot: WorldSnapshot) -> bool:
	var puck_pos: Vector3 = snapshot.puck_state.position
	# In our DZ? oriented_z > BLUE_LINE_Z means past our own blue line.
	if _own_goal_dir * puck_pos.z <= GameRules.BLUE_LINE_Z:
		return false
	# Don't play man if our team has possession — that's a breakout, not
	# a defensive coverage situation. Loose pucks in our zone DO trigger
	# man (forwards are crashing, mark them).
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier != -1 and int(_team_id_resolver.call(carrier)) == _team_id:
		return false
	return true


# Man-to-man anchor: MAN_GAP_DEPTH_M off the mark along the line from
# the mark's PREDICTED position to our own net. Body shades the actual
# lane to net regardless of where the mark is on the ice (a mark out
# by the boards still gets shaded toward center, not just behind on
# Z). Predicting MAN_LEAD_TIME_S ahead means a moving forward doesn't
# slip past the defender — the defender anchors against where the
# mark will be by the time they arrive.
func _man_anchor(mark: SkaterNetworkState) -> Vector3:
	var lead_pos: Vector3 = AITrajectory.predict_at(
			mark.position, mark.velocity, MAN_LEAD_TIME_S)
	var our_net := Vector3(0.0, 0.0, _own_goal_dir * GameRules.GOAL_LINE_Z)
	var dx: float = our_net.x - lead_pos.x
	var dz: float = our_net.z - lead_pos.z
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist < 0.001:
		# Mark sitting on top of our net — degenerate case; just anchor
		# at the lead pos and let the goalie + steering sort it out.
		return _clamp_anchor(lead_pos)
	var step: float = MAN_GAP_DEPTH_M / dist
	return _clamp_anchor(Vector3(
			lead_pos.x + dx * step, 0.0,
			lead_pos.z + dz * step))


# F3 anchor — weak-side trailer, mirrored across the puck X and 8 m
# back toward our own goal. Safety-valve role.
func _f3_anchor(puck_pos: Vector3) -> Vector3:
	var strong_x: float = signf(puck_pos.x) if absf(puck_pos.x) > STRONG_SIDE_X_DEADBAND else 1.0
	var weak_x: float = -strong_x
	var x: float = puck_pos.x + weak_x * F3_OFFSET_X_WEAK
	# High man: when the puck is in our OZ, F3 anchors near the OZ blue
	# line ready to backcheck on a turnover — instead of trailing the
	# puck deeper. When the puck is in NZ or our DZ, fall back to the
	# legacy "above-puck" trailer position.
	var z: float
	if -_own_goal_dir * puck_pos.z > GameRules.BLUE_LINE_Z:
		z = -_own_goal_dir * (GameRules.BLUE_LINE_Z + F3_HIGH_MAN_OZ_DEPTH_M)
	else:
		z = puck_pos.z + _own_goal_dir * F3_OFFSET_Z_BACK
	return _clamp_anchor(Vector3(x, 0.0, z))


# Clamp an anchor to the playable rink with a small margin so steering
# doesn't pull the bot into the boards or behind the goal line.
func _clamp_anchor(p: Vector3) -> Vector3:
	var x: float = clampf(p.x,
			-GameRules.RINK_HALF_WIDTH + RINK_X_INSET,
			GameRules.RINK_HALF_WIDTH - RINK_X_INSET)
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


# Carrier anchor. In NZ/DZ, drive toward the high slot. Once in OZ,
# search nearby for the position with the best shoot-or-pass option
# (8 cardinal directions × CARRY_SEARCH_STEP_M plus stay-here).
func _carry_anchor(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	# No hold-up for the carrier — current arcade rules don't whistle on
	# offside, just ghost the trailing player. The off-puck teammates
	# clamp themselves on the NZ side of the line via _cap_offside, so
	# the carrier brings the puck in normally and they release across
	# behind it.
	if -_own_goal_dir * self_pos.z <= GameRules.BLUE_LINE_Z:
		var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - SLOT_DEPTH_FROM_GOAL_LINE)
		return Vector3(0.0, 0.0, slot_z)
	return _find_best_carry_position(snapshot, self_pos)


func _find_best_carry_position(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var goalie_pos: Vector3 = _attacking_goal_pos
	var opp_goalie: GoalieNetworkState = snapshot.goalie_states.get(1 - _team_id)
	if opp_goalie != null:
		goalie_pos = Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z)

	# Refresh the scratch lists. _pick_action would also populate
	# _scratch_opponents but it runs later in the same tick (after
	# QUIET_EYE_TICKS) so we can't rely on its state. Rebuild here.
	_scratch_opponents.clear()
	var teammates: Array[Vector3] = []
	var teammate_facings: Array[Vector2] = []
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		var s_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			teammates.append(s_state.position)
			teammate_facings.append(s_state.facing)
		else:
			_scratch_opponents.append(s_state.position)

	# Score current position as the baseline; only move if a candidate
	# beats it.
	var best_pos: Vector3 = self_pos
	var best_score: float = AIActionScoring.carry_position_score(
			self_pos, _attacking_goal_pos, goalie_pos,
			GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
			teammates, teammate_facings, _scratch_opponents)

	# 8 cardinal/diagonal directions. Pre-baked so we don't recompute
	# trig each tick.
	const SQRT2_INV: float = 0.70710678
	const DIRS: Array[Vector2] = [
			Vector2(1, 0), Vector2(SQRT2_INV, SQRT2_INV),
			Vector2(0, 1), Vector2(-SQRT2_INV, SQRT2_INV),
			Vector2(-1, 0), Vector2(-SQRT2_INV, -SQRT2_INV),
			Vector2(0, -1), Vector2(SQRT2_INV, -SQRT2_INV),
	]
	for d: Vector2 in DIRS:
		var candidate := Vector3(
				self_pos.x + d.x * CARRY_SEARCH_STEP_M, 0.0,
				self_pos.z + d.y * CARRY_SEARCH_STEP_M)
		# Don't drift back into the neutral zone or past the attacking
		# goal line. RINK_X_INSET keeps us off the boards.
		if -_own_goal_dir * candidate.z <= GameRules.BLUE_LINE_Z:
			continue
		if absf(candidate.z) > absf(_attacking_goal_pos.z) - CARRY_GOAL_LINE_BUFFER_M:
			continue
		if absf(candidate.x) > GameRules.RINK_HALF_WIDTH - RINK_X_INSET:
			continue
		var s: float = AIActionScoring.carry_position_score(
				candidate, _attacking_goal_pos, goalie_pos,
				GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
				teammates, teammate_facings, _scratch_opponents)
		if s > best_score:
			best_score = s
			best_pos = candidate
	return best_pos


# Dump target — deep corner of the attacking zone on the bot's strong
# side. Quick-shot direction is blade-from-player so the puck fires
# along the bot→corner vector, sliding into the deep zone where a
# forechecker can chase it down.
func _dump_aim_point(self_pos: Vector3) -> Vector3:
	var strong_x: float = signf(self_pos.x) if absf(self_pos.x) > STRONG_SIDE_X_DEADBAND else 1.0
	var deep_z: float = _attacking_goal_pos.z + _own_goal_dir * DUMP_DEPTH_FROM_GOAL_M
	return Vector3(strong_x * DUMP_CORNER_X, 0.0, deep_z)


# Walk the puck's predicted trajectory and pick the earliest step where
# we could actually reach the puck. The earliest reachable step is the
# best intercept — any later step the puck has slid further past us, any
# earlier step we wouldn't have arrived yet. Trajectory walk also gives
# us free rink-clamping (a sliding puck heading into corner boards no
# longer projects an intercept inside the wall) and a single seam to
# add puck friction later. Falls back to the puck's current position
# when no step is reachable in the lookahead window.
func _lead_intercept(self_pos: Vector3, puck_pos: Vector3, puck_vel: Vector3) -> Vector3:
	var dt: float = CHASE_MAX_LOOKAHEAD_S / float(CHASE_TRAJECTORY_STEPS)
	var traj: Array[Vector3] = AITrajectory.predict(
			puck_pos, puck_vel, CHASE_TRAJECTORY_STEPS, dt)
	for i: int in traj.size():
		var t_step: float = (i + 1) * dt
		var reach: float = self_pos.distance_to(traj[i])
		if reach <= CHASE_SPEED_REF_M_S * t_step:
			return traj[i]
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


# Where to drop into when the puck is lost mid-on-puck-state. F1s chase,
# everyone else holds the above-puck anchor.
func _post_puck_lost_state() -> State:
	return State.CHASE_PUCK if _is_f1() else State.OFF_PUCK


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
			var ratio: float = clampf(speed / ENGAGEMENT_SPEED_REF_M_S, 0.0, 1.0)
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
		_state = s
		_ticks_in_state = 0


func _reset_to_off_puck() -> void:
	_state = State.OFF_PUCK
	_ticks_in_state = 0
	_pass_target_peer_id = 0
