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
	OFF_PUCK,         # default off-puck — anchor above puck, aim at goal
	CHASE_PUCK,       # F1 without puck — pursue, blade on the puck
	CARRY,            # with puck, no committed action — aim at goal
	SHOOT_PRESSED,    # multi-tick wrister charge aimed at goalie shadow
	SLAPPER_PRESSED,  # multi-tick slapper charge — bigger commit, more power
	PASS_PRESSED,     # one-tick press window aimed at a teammate's lead position
	DUMP_PRESSED,     # one-tick press window aimed at a deep-zone clear
	ONE_TIMER_CHARGE, # off-puck slapper pre-charge — demanding the puck
}

# Off-puck anchor offsets. F2 is the triangle apex on the strong side
# (puck's X side), 3 m off the puck X-wise and 2 m back toward our own
# goal Z-wise. F3 is the weak-side trailer, 5 m mirrored across the
# puck X and 8 m back. The legacy OFF anchor (no F2/F3 role assigned —
# 4+ teammates case) keeps the original above-puck behavior.
const F2_OFFSET_X: float = 3.0
const F2_OFFSET_Z_BACK: float = 2.0
# F1 pressure read: when F1 has 2+ defenders within F1_PRESSURE_RADIUS_M,
# F2 collapses from the wide triangle apex to a tight close-support
# position — assist the carrier directly instead of holding apex space.
# When F1 has space, F2 stays at the apex looking like a passing
# option.
const F1_PRESSURE_RADIUS_M: float = 3.5
const F1_HEAVY_PRESSURE_COUNT: int = 2
const F2_SUPPORT_OFFSET_X: float = 1.5
const F2_SUPPORT_OFFSET_Z_BACK: float = 1.5
# F3 shades to the STRONG side (puck side) by this much. Real-hockey
# high man / trailer typically pinches with the play rather than
# camping the weak side — a strong-side F3 closes off the
# puck-supporting passing lane and is in position to pinch on a loose
# puck. Small magnitude so they don't bunch with F2 (3 m strong-side).
const F3_OFFSET_X_STRONG: float = 2.0
const F3_OFFSET_Z_BACK: float = 8.0
# In OZ, F3 trails the puck by this far toward our own goal — but
# clamped between the OZ blue line and the back of the OZ faceoff
# circles (see F3_OZ_DOT_BACK_OFFSET_M). 3v3 doesn't need a strict
# "glued to the blue line" high man like 5v5; F3 just shouldn't crash
# the net and let opponents get behind them on a turnover.
const F3_OZ_TRAIL_DEPTH_M: float = 5.0
# Faceoff circle radius (NHL standard ≈ 15 ft). The back edge of the
# OZ faceoff circle (toward NZ) is the deepest F3 will go — past that
# point, a turnover means we're gone before we can recover.
const F3_OZ_DOT_BACK_OFFSET_M: float = 4.5
# F3 high-man depth when our team has possession in the OZ. Sit just
# inside the OZ blue line as a free safety so a turnover doesn't leak
# a 2-on-1 the other way. The back-of-dots clamp is the right depth
# when defending or chasing a loose puck in OZ; during own possession
# the higher position prevents breakaway/odd-man rushes the moment we
# cough it up. 3v3-specific: with no D pair behind us, F3 is the only
# thing standing between a turnover and a clean breakaway.
const F3_OZ_OWN_POSSESSION_DEPTH_M: float = 2.0
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
# Hysteresis on the strong-side sign: once we've picked +1, only flip
# to -1 when puck.x crosses below -STRONG_SIDE_HYSTERESIS_M (and vice
# versa). The static `STRONG_SIDE_X_DEADBAND` alone wasn't enough —
# puck oscillating around x = -0.5 would flip strong_x, jumping the
# F2/F3 anchor 6 m laterally each tick. The 1.5 m hysteresis band
# means the puck has to commit to the other side before the bot
# flips. Bigger band = more sticky; smaller = more responsive.
const STRONG_SIDE_HYSTERESIS_M: float = 1.5
# Margins from the rink edge / goal line that anchors are clamped inside of.
const RINK_X_INSET: float = 0.5
const RINK_Z_INSET: float = 1.0

const QUIET_EYE_TICKS: int = 8

# After CARRY's `_pick_action` chooses an action (PASS/DUMP/SHOOT/
# SLAPPER), the bot doesn't transition immediately — it pre-aims by
# setting the mouse target to the action's aim direction and waits
# for the motion-limited mouse to converge before firing. Without
# this, the action state's first tick fires with the mouse still
# mid-traversal from CARRY's previous target, so quick-shot
# direction (PASS/DUMP) and slapper locked-direction (SLAPPER) end
# up at whatever angle the mouse happened to be at.
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
# pre-aiming forever.
const AIM_CONVERGED_DIST_M: float = 0.15
const INTENT_MAX_WAIT_TICKS: int = 60   # ~250 ms at 240 Hz
# Bias applied to score_pass when the receiver is human. Bots pass to
# the player about 25% more often than to another bot for the same
# raw scoring conditions — the human is the actor, the bots are
# support. Multiplicative so a bad pass to a human stays bad; only
# affects close-call decisions. Clamped to 1.0 max so a human-boosted
# score doesn't exceed the natural scoring range.
const HUMAN_PASS_BIAS: float = 1.25
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
const PASS_AIM_WOBBLE_CONE_DEG: float = 1.5
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
# Angling: when chasing an opposing CARRIER (not a loose puck), shift
# the intercept point this far toward center-ice so the bot approaches
# from the inside and forces the carrier toward the boards. Real
# defenders don't chase straight-line at the puck — that lets the
# carrier cut to the middle. Skipped when the carrier is already near
# center (no inside to take away). The bias is capped at the carrier's
# own X magnitude so we never overshoot to the wrong side.
const CHASE_ANGLE_BIAS_M: float = 1.5

# Carrier anchor search step. The carrier samples candidate positions
# this far from their current spot in 8 cardinal directions and picks
# the one with the best shoot-or-pass score. Bot drifts toward the
# best-option spot tick by tick — no teleporting, just gradient
# follow.
const CARRY_SEARCH_STEP_M: float = 3.0
# Margin from the attacking goal line we won't drift past while
# searching (carrier shouldn't anchor behind the net).
const CARRY_GOAL_LINE_BUFFER_M: float = 1.0

# CARRY blade aim distance (m forward in goal direction). Mouse on the
# goal plane (25+ m away) was useless for stickhandling: a 0.3 m
# lateral blade shift would need a ~22 m mouse offset. Putting mouse
# at 2 m forward keeps the blade IK at a comfortable position
# (within ROM, not at the clamp extreme) where small mouse shifts
# translate directly to blade movement. Body facing still tracks
# toward the attacking goal because the forward direction IS the
# goal direction.
const CARRY_BLADE_AIM_FORWARD_M: float = 2.0

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
# Slapper score multiplier vs wrister at the same geometry: a slapper
# is harder to stop because of raw puck speed, but the bot also pulls
# the goalie deeper via the slapper-tell stance pull (see
# `slapper_tell_depth_pull` in goalie_controller.gd). 1.15 captures
# both effects without making slapper strictly better than wrister —
# the longer charge time exposes the bot to forward defenders, so
# wrister wins under pressure. Tuning: raise toward 1.3 if bots feel
# under-committed to slappers when clean; lower toward 1.0 if they
# slap too often.
const SLAPPER_POWER_BONUS: float = 1.15

# ── One-timer pre-charge ─────────────────────────────────────────────────────
# Off-puck bot in good shot position pre-charges a slapper, broadcasting
# `shot_state == SLAPPER_CHARGE_WITHOUT_PUCK` to the rest of the team.
# The carrier reads this from the snapshot and boosts pass score
# heavily for the slapper-charging teammate — no telegraphed pass, no
# shared blackboard, the receiver "demands" the puck just by visibly
# winding up. SkaterController's existing without-puck slapper
# mechanic handles the rest: bot fires `slap_pressed` once, holds
# `slap_held`, and on release `try_one_timer_release` fires the
# one-timer if the puck is in the slapper zone.
#
# Trigger threshold is the same as ACTION_THRESHOLD-ish — score_shoot
# from the bot's current position must clear ONE_TIMER_TRIGGER_THRESHOLD
# (lower than ACTION_THRESHOLD so charges happen more readily; the
# cost of a wasted charge is just velocity drag).
const ONE_TIMER_TRIGGER_THRESHOLD: float = 0.4
# Release distance: drop slap_held when the puck is within this much
# of the bot's slapper zone center (NOT the bot's body). Zone radius
# is 0.5 m; SkaterController's `try_one_timer_release` adds velocity-
# scaled leniency on top (puck speed × 0.05 s), so 1.0 m at the
# zone-center sits well inside the effective release window for
# typical pass speeds (~22 m/s → leniency ≈ 1.6 m).
const ONE_TIMER_RELEASE_DISTANCE_M: float = 1.0
# Max charge duration. After this many ticks with no pass, abort the
# charge — the puck isn't coming, holding longer just keeps the bot
# stuck in slapper drag.
const ONE_TIMER_MAX_CHARGE_TICKS: int = 240   # 1 s
# Pass score multiplier for a teammate currently in
# SLAPPER_CHARGE_WITHOUT_PUCK. They're explicitly asking for the
# puck; reward the carrier for feeding them. 2.0 is enough to win
# over most other passes when the lane is reasonably clean.
const ONE_TIMER_TARGET_BONUS: float = 2.0
# Mirror of SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK (=4).
const _SHOT_STATE_SLAPPER_CHARGE_WITHOUT_PUCK: int = 4
# Slapper zone offsets in player-local space. Mirror SkaterController's
# `slapper_zone_offset_z` (forward, magnitude) and `slapper_zone_offset_x`
# (lateral toward blade side). Used to compute the bot's zone position
# in world space for both the pre-charge geometry gate (receiver-side)
# and the release-distance check.
const SLAPPER_ZONE_FORWARD_M: float = 1.0
const SLAPPER_ZONE_LATERAL_M: float = 0.8

# Quick-shot pass reachability cone. A pass commits via shoot_pressed
# the same tick it transitions out of CARRY → quick-shot direction is
# `(blade - player)` in `ShotMechanics.release_wrister`. The blade IK
# clamps to the bot's blade ROM (≈90° each side of facing), and the
# body can't rotate to face a backward target in one tick (it's
# `ik_locked_side`-frozen above 157° from current facing per
# SkaterPoseCoordinator). Receivers outside this dot threshold from
# the bot's current facing therefore fire at the ROM edge, not at the
# receiver — the puck goes sideways and "looks like a dump."
# 0.1 ≈ 84°; receivers near-perpendicular get filtered before
# scoring. Set to 0.0 for full forward 180° if the filter feels too
# strict during playtest.
const PASS_REACHABLE_DOT_MIN: float = 0.1

# ── Give-and-go ─────────────────────────────────────────────────────────────
# After releasing a pass, the passer cuts to open ice up-ice from the
# release point and holds that position for a short window — looking
# for a return pass. This is the most common 3v3 build pattern and it
# never emerged from the role-anchor logic, which snapped the passer
# straight back into their F2/F3 anchor the next tick.
#
# Implemented as an anchor override in OFF_PUCK: when the give-and-go
# timer is active, _off_puck_anchor returns _give_and_go_anchor (capped
# by _cap_offside) instead of the role anchor. The timer decrements
# every dispatch tick. CARRY clears it on entry — once we're back on
# the puck the cut is over.
#
# 1.5 s gives the receiver time to control the puck and either look
# back at us (return pass) or commit forward themselves (we revert to
# role anchor and play it as normal off-puck). The 10 m lead lands us
# just inside or right at the OZ blue line from a typical NZ pass —
# perfect spot for a return feed into the rush.
const GIVE_AND_GO_DURATION_TICKS: int = 360   # 1.5 s at 240 Hz
const GIVE_AND_GO_LEAD_M: float = 10.0

# ── Net-front screen ────────────────────────────────────────────────────────
# When a teammate winds up a slapper, the closest non-shooter teammate
# parks in front of the crease to screen the goalie. Bots don't fire
# slappers themselves (only wristers), so this fires on HUMAN
# teammates. Anchor sits SCREEN_OFFSET_FROM_GOAL_LINE_M past the goal
# line on the puck-side, centred on the net mouth — just outside the
# crease arc (radius 1.83 m), so steering's crease repel doesn't kick
# the screener back out.
const SCREEN_OFFSET_FROM_GOAL_LINE_M: float = 2.5
# Mirror of SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK. Hard-
# coded as int rather than typed enum so we don't introduce a domain →
# controller dependency from this AI module.
const _SHOT_STATE_SLAPPER_CHARGE_WITH_PUCK: int = 3

# ── Emergency backcheck ─────────────────────────────────────────────────────
# When the puck turns over in the NZ (or DZ) and a bot is caught
# up-ice — between attacker and own net — they need to skate STRAIGHT
# home, not via their man-to-man anchor (which might sit wide if the
# mark is at the boards). Override anchors the bot at puck depth +
# BACKCHECK_BACK_OF_PUCK_M (toward own net), centred X — i.e. "be
# back of the puck by a few metres." The override releases the moment
# the bot's z crosses the puck's z (own_goal_dir-signed), and
# man-to-man takes over with whatever mark coverage_assignment gave
# them.
#
# BACKCHECK_BACK_OF_PUCK_M is the cushion past puck depth — large
# enough that the bot keeps full speed through the override-release
# transition (well past the steering deadband). Anchor depth is
# clamped to BACKCHECK_MAX_DEPTH_FROM_GOAL_M past own goal so we
# never anchor into our own crease when the puck is already deep in
# our DZ; "the slot" is the deepest defensive position we want.
const BACKCHECK_BACK_OF_PUCK_M: float = 5.0
const BACKCHECK_MAX_DEPTH_FROM_GOAL_M: float = 5.0

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
# time, not where they are at decision time. Dump is one-tick and uses
# _scratch_opponents (current positions).
var _scratch_opponents_shoot: Array[Vector3] = []
# Per-receiver buffer of opponent positions PREDICTED forward by the
# pass's flight time (distance / PASS_PUCK_SPEED_REF_M_S). Pass flight
# is much longer than a wrister charge (0.5–1.1 s typical), so a
# defender clearly about to step into the lane reads as clear under
# current-position scoring. Rebuilt inside the score_pass loop in
# _pick_action because flight time depends on shooter→receiver distance.
var _scratch_opponents_pass: Array[Vector3] = []

# Set when CARRY commits to PASS_PRESSED; consumed by _state_pass_pressed
# the next tick. 0 means "no current pass target" (real peer_ids are
# either 1+ for humans or 10000+ for bots, so 0 is safe as sentinel).
var _pass_target_peer_id: int = 0

# CARRY pre-aim state: when `_pick_action` chooses an action, it
# stores the action here instead of transitioning immediately. CARRY
# then pre-aims the mouse toward the action's direction and waits
# for convergence before transitioning. State.CARRY = "no intent."
var _intended_action: State = State.CARRY
var _intent_wait_ticks: int = 0

# Has the slapper-without-puck slap_pressed fired yet inside
# ONE_TIMER_CHARGE? Reset on state entry. While false the bot is
# still pre-aiming (mouse converging to slap aim direction); once
# true the slapper is charging, locked direction is captured, and
# mouse position no longer affects the shot direction.
var _one_timer_slap_fired: bool = false

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

# Slapper bookkeeping. Symmetric to the wrister fields above.
# `slap_pressed` fires once at tick 0 (transitions SkaterStateMachine
# into SLAPPER_CHARGE_WITH_PUCK). `slap_held` stays high through the
# charge ticks, then drops to release. Aim direction is captured at
# slapper entry by SkaterController._enter_slapper_charge.
var _slapper_charge_tick: int = 0
var _slapper_aim_target: Vector3 = Vector3.ZERO

# Per-tick slapper-predicted opponent positions, used by score_slapper
# in `_pick_action`. Slapper has a longer commit (~0.55 s vs 0.25 s for
# wrister), so opponents are projected further forward — a defender
# stepping into the lane during the charge reads as a blocked lane at
# decision time, not as we bail mid-charge.
var _scratch_opponents_slapper: Array[Vector3] = []

# Give-and-go bookkeeping — see GIVE_AND_GO_*. Set when PASS_PRESSED
# fires; consumed by _off_puck_anchor while the timer is active. 0
# means "no active give-and-go cut."
var _give_and_go_anchor: Vector3 = Vector3.ZERO
var _give_and_go_remaining_ticks: int = 0

# Per-bot RNG for aim wobble. Seeded once in setup() from peer_id and
# the host tick at spawn so each bot has its own deterministic but
# distinct stream. The previous implementation allocated a fresh
# RandomNumberGenerator and called randomize() on every shot/pass —
# per-call heap allocation plus replay-breaking non-determinism.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

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
	# Seed the per-bot RNG. peer_id × prime spreads the bot id range
	# (10000+) across the seed space; XOR with NetworkManager.host_tick
	# at spawn salts the seed per-session so every match isn't an
	# identical wobble pattern (still deterministic within a session,
	# which is what replay needs).
	_rng.seed = (peer_id * 1000003) ^ NetworkManager.host_tick


# ── State accessors ──────────────────────────────────────────────────────────

func get_state() -> State:
	return _state


# Read by AIController for the debug label. Returns "F1"/"F2"/"F3"/"OFF",
# or "?" when the brain hasn't yet assigned a role (first ticks after spawn).
func debug_role() -> String:
	if _team_brain == null:
		return "?"
	return String(_team_brain.get_role(_peer_id))


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
	if _give_and_go_remaining_ticks > 0:
		_give_and_go_remaining_ticks -= 1

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
		State.SLAPPER_PRESSED:
			_state_slapper_pressed(input, snapshot, self_pos, have_puck)
		State.PASS_PRESSED:
			_state_pass_pressed(input, snapshot, self_pos, have_puck)
		State.DUMP_PRESSED:
			_state_dump_pressed(input, snapshot, self_pos, have_puck)
		State.ONE_TIMER_CHARGE:
			_state_one_timer_charge(input, snapshot, self_pos, have_puck)


# ── State handlers ───────────────────────────────────────────────────────────

func _state_off_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Anchor depends on role: F2 strong-side support, F3 weak-side trailer,
	# or legacy "above puck" for any unassigned role (4+ teammate case).
	var anchor: Vector3 = _off_puck_anchor(snapshot.puck_state.position, self_pos, snapshot)
	# Exempt the mark from opponent repel during man-to-man: defenders
	# are supposed to stand shoulder-to-shoulder with their mark, not
	# be pushed off by them. Without this, a defender marking a crease-
	# crashing opp drifts 2-3 m back from their anchor under repel.
	_apply_steering(input, snapshot, self_pos, anchor, _current_mark_pid(snapshot))
	# Aim mouse 2 m in our direction of motion (toward anchor), or
	# along current facing if we're already at the anchor. Previously
	# we aimed at `_attacking_goal_pos` (constant 25+ m away), which
	# put the blade IK at the ROM extreme every tick — tiny body
	# motion / rotation moved the clamped extreme around in world
	# space and the blade visibly jittered. A 2 m target sits well
	# inside the forehand reach window (`rom_forehand_reach_max = 0.45 m`
	# at the shoulder, so 2 m world is the natural far end), so the
	# blade settles into a relaxed "ready" position. Body facing
	# also tracks the anchor direction now, which is more natural —
	# defenders face their mark, F2 faces the strong-side support
	# spot, etc. — instead of facing the attacking goal regardless
	# of where they're going.
	input.mouse_world_pos = _step_mouse_toward(_ready_stance_aim(self_pos, anchor, snapshot))
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif _is_f1() and not _teammate_has_puck(snapshot):
		_set_state(State.CHASE_PUCK)
	elif _should_pre_charge_slapper(snapshot, self_pos):
		# Own team has the puck and we have a real shot from here —
		# pre-charge a slapper to broadcast the one-timer threat. The
		# carrier reads our shot_state from the snapshot and biases
		# pass scoring heavily toward us.
		_set_state(State.ONE_TIMER_CHARGE)


func _state_chase_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lead intercept: aim at where the puck WILL be when we'd actually
	# arrive, not at where it is now. Per-bot t_arrival (distance / max
	# speed) means two bots converging on the same loose puck compute
	# different intercept points, breaking the "both glued to the same
	# puck position" pattern.
	var puck_pos: Vector3 = snapshot.puck_state.position
	var target: Vector3 = _lead_intercept(self_pos, puck_pos, snapshot.puck_state.velocity)
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
	# Aim: normally blade-on-intercept, but during the engagement cooldown
	# (just got stripped or just stick-checked someone) pull the blade
	# back to our body so the puck can settle without auto-magnetting
	# back to us. Once the puck is inside our blade reach, snap the aim
	# to the puck's ACTUAL position — leading at this range puts the
	# blade past a puck that's already on our stick.
	if _engagement_cooldown > 0:
		input.mouse_world_pos = _step_mouse_toward(Vector3(self_pos.x, 0.0, self_pos.z))
	elif self_pos.distance_to(puck_pos) <= BLADE_REACH_M:
		input.mouse_world_pos = _step_mouse_toward(puck_pos)
	else:
		input.mouse_world_pos = _step_mouse_toward(target)
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif not _is_f1() or _teammate_has_puck(snapshot) or _is_caught_up_ice(snapshot, self_pos):
		# Drop back to off-puck support if any of:
		#   - We're not F1 anymore (role rotation).
		#   - Teammate just picked up the puck (we shouldn't chase our
		#     own carrier).
		#   - We're caught up-ice on opp possession in our defensive
		#     half — chasing forward can't catch the puck heading the
		#     other way; OFF_PUCK's backcheck override gets us home.
		_set_state(State.OFF_PUCK)


func _state_carry(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# In NZ/DZ, drive toward the high slot to enter the offensive zone.
	# Once in OZ, search for the position with the best shot/pass option
	# and drift toward it — patient cycling.
	var anchor: Vector3 = _carry_anchor(snapshot, self_pos)
	_apply_steering(input, snapshot, self_pos, anchor)

	if not have_puck:
		_intended_action = State.CARRY
		_set_state(_post_puck_lost_state())
		return

	# Decide on an action when quiet-eye expires AND we don't already
	# have a pending intent. Once an intent is set we hold it until
	# the mouse converges to its aim or the wait timeout fires —
	# re-picking each tick would let the intent oscillate between
	# two close-scoring actions and the mouse would never converge
	# to either.
	if _ticks_in_state >= QUIET_EYE_TICKS and _intended_action == State.CARRY:
		_pick_action(snapshot, self_pos)

	# Mouse target depends on whether we're carrying or pre-aiming
	# for an action.
	var mouse_target: Vector3
	if _intended_action == State.CARRY:
		mouse_target = _carry_mouse_aim(snapshot, self_pos)
	else:
		mouse_target = _aim_target_for_intent(snapshot, self_pos)
	input.mouse_world_pos = _step_mouse_toward(mouse_target)

	# If we're pre-aiming, wait for mouse convergence (or timeout)
	# before transitioning to the action state. The action state
	# fires immediately on entry, so the mouse direction at that
	# moment is what gets locked in (PASS/DUMP quick-shot direction,
	# SLAPPER locked_dir).
	if _intended_action != State.CARRY:
		var aim_dist: float = _mouse_pos.distance_to(mouse_target)
		if aim_dist < AIM_CONVERGED_DIST_M or _intent_wait_ticks >= INTENT_MAX_WAIT_TICKS:
			_set_state(_intended_action)
			_intended_action = State.CARRY
			_intent_wait_ticks = 0
		else:
			_intent_wait_ticks += 1


# Returns the mouse target (in world XZ) the bot should be aiming at
# while pre-aiming for `_intended_action`. Always 2 m forward in the
# action's aim direction — direction is what matters for shot fire,
# not distance, so we keep the target close to the bot for fast
# convergence under the motion-limited model.
func _aim_target_for_intent(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	match _intended_action:
		State.PASS_PRESSED:
			return _aim_2m_toward(self_pos, _pass_aim_point(snapshot, self_pos))
		State.DUMP_PRESSED:
			return _aim_2m_toward(self_pos, _dump_aim_point(self_pos))
		State.SHOOT_PRESSED, State.SLAPPER_PRESSED:
			return _aim_2m_toward(self_pos, _shot_aim_point(snapshot, self_pos))
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
		return self_pos + Vector3.FORWARD * CARRY_BLADE_AIM_FORWARD_M
	return self_pos + to_aim.normalized() * CARRY_BLADE_AIM_FORWARD_M


func _state_shoot_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lost the puck mid-charge — bail. SkaterStateMachine's release path
	# is a no-op without the puck, so we don't need to force a release.
	if not have_puck:
		_set_state(_post_puck_lost_state())
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
		var clean_aim: Vector3 = _shot_aim_point(snapshot, self_pos)
		_shoot_aim_target = clean_aim + _aim_wobble(self_pos, clean_aim, SHOT_AIM_WOBBLE_CONE_DEG)
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
		_set_state(State.CARRY)


# Slapper charge: hold slap_held for BOT_SLAPPER_CHARGE_TICKS, then
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
		_set_state(_post_puck_lost_state())
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

	_apply_slot_steering(input, snapshot, self_pos)
	if _shot_is_elevated:
		input.elevation_up = true
	else:
		input.elevation_down = true

	# First tick: capture aim, fire slap_pressed. SkaterController's
	# _enter_slapper_charge reads input.mouse_world_pos and locks the
	# slapper aim direction from there for the rest of the charge.
	if _slapper_charge_tick == 0:
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
	_apply_slot_steering(input, snapshot, self_pos)
	# Aim at the receiver's lead position. Quick-shot direction is
	# blade-from-player at release, and the blade IK swings toward
	# mouse_world_pos — so this fires the puck along the bot→receiver
	# vector.
	var clean_pass_aim: Vector3 = _pass_aim_point(snapshot, self_pos)
	input.mouse_world_pos = _step_mouse_toward(clean_pass_aim + _aim_wobble(
			self_pos, clean_pass_aim, PASS_AIM_WOBBLE_CONE_DEG))
	input.shoot_pressed = true
	input.shoot_held = true
	# Arm the give-and-go cut from the release position. _off_puck_anchor
	# honors this for GIVE_AND_GO_DURATION_TICKS; CARRY entry clears it.
	_give_and_go_anchor = _compute_give_and_go_anchor(self_pos)
	_give_and_go_remaining_ticks = GIVE_AND_GO_DURATION_TICKS
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
	input.mouse_world_pos = _step_mouse_toward(_dump_aim_point(self_pos))
	input.shoot_pressed = true
	input.shoot_held = true
	if not have_puck:
		_set_state(_post_puck_lost_state())
	else:
		_set_state(State.CARRY)


# Off-puck slapper pre-charge. The bot is in a good shot position
# while a teammate carries — we wind up a slapper without the puck so
# that (1) the carrier sees `shot_state == SLAPPER_CHARGE_WITHOUT_PUCK`
# and biases pass scoring toward us, and (2) when the puck arrives
# we release on the beat for a one-timer (SkaterController's
# `try_one_timer_release` does the proximity check).
#
# Exit conditions:
#   - have_puck: the puck arrived (deflection / pickup zone / slapper
#     zone). Drop slap_held; if the puck is in the slapper zone the
#     SM fires the one-timer, otherwise it cancels and we're back to
#     normal CARRY.
#   - Conditions invalid: own team lost possession, our shot score
#     dropped below threshold, etc. Drop slap_held to abort.
#   - Puck close (within ONE_TIMER_RELEASE_DISTANCE_M): release for
#     the one-timer. Try_one_timer_release does the actual fire/cancel
#     decision based on its own zone + leniency.
#   - Max ticks: timeout, abort the charge.
func _state_one_timer_charge(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	if have_puck:
		input.slap_held = false
		_set_state(State.CARRY)
		return
	if _ticks_in_state >= ONE_TIMER_MAX_CHARGE_TICKS:
		input.slap_held = false
		_set_state(State.OFF_PUCK)
		return

	# Hold position so we don't drift out of the shot lane while
	# charging. Slapper drag in SkaterController slows us anyway, but
	# anchoring at self_pos keeps the steering aligned. Must run BEFORE
	# _should_pre_charge_slapper since that helper reads
	# _scratch_opponents populated here.
	_apply_steering(input, snapshot, self_pos, self_pos)

	if not _should_pre_charge_slapper(snapshot, self_pos):
		input.slap_held = false
		_set_state(State.OFF_PUCK)
		return

	# Aim phase: wait for the motion-limited mouse to converge to the
	# slap-aim direction before firing slap_pressed. The locked
	# slapper direction is captured at slap_pressed time from
	# (mouse - blade), so firing before convergence locks a wrong
	# direction (mouse mid-traversal from OFF_PUCK's ready-stance
	# target). After slap_pressed fires we just hold mouse on the
	# shot aim — the locked direction is set, mouse position no
	# longer affects the shot direction.
	if not _one_timer_slap_fired:
		var aim_target: Vector3 = _aim_2m_toward(self_pos, _shot_aim_point(snapshot, self_pos))
		input.mouse_world_pos = _step_mouse_toward(aim_target)
		var converged: bool = _mouse_pos.distance_to(aim_target) < AIM_CONVERGED_DIST_M
		if converged or _ticks_in_state >= INTENT_MAX_WAIT_TICKS:
			input.slap_pressed = true
			_one_timer_slap_fired = true
		else:
			# Still aiming — hold slap_held off until we fire.
			input.slap_held = false
			return

	# Charge phase: slap_pressed already fired; locked direction is
	# set. Hold slap_held and wait for the puck.
	input.mouse_world_pos = _step_mouse_toward(_shot_aim_point(snapshot, self_pos))

	# Release window: drop slap_held when the puck nears the actual
	# slapper zone (offset forward + blade-side from us), NOT just the
	# player body. SkaterController's `try_one_timer_release` checks
	# `puck.distance_to(zone_pos)` against zone_radius + velocity-scaled
	# leniency, so we want our release threshold matched to that zone
	# center for accurate timing.
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state != null:
		var zone_pos: Vector3 = _compute_slapper_zone_pos(self_pos, self_state.facing)
		if zone_pos.distance_to(snapshot.puck_state.position) <= ONE_TIMER_RELEASE_DISTANCE_M:
			input.slap_held = false
			_set_state(State.OFF_PUCK)
			return

	input.slap_held = true


# ── Internal helpers ─────────────────────────────────────────────────────────

# Anchor + steering shared by CARRY / SHOOT_PRESSED / PASS_PRESSED. Each
# state sets `input.mouse_world_pos` itself because the aim differs
# (goal-shadow vs receiver lead).
func _apply_slot_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - SLOT_DEPTH_FROM_GOAL_LINE)
	_apply_steering(input, snapshot, self_pos, Vector3(0.0, 0.0, slot_z))


# Score every applicable action and transition into the highest-scoring
# state. CARRY is the implicit default — if no action clears
# AIActionScoring.ACTION_THRESHOLD we stay in CARRY without
# transitioning (next tick re-evaluates).
#
# Mutates _pass_target_peer_id when PASS wins.
func _pick_action(snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	_build_action_opponents_lists(snapshot)
	var goalie_pos: Vector3 = _predicted_goalie_pos(snapshot)
	var wrister_score: float = AIActionScoring.score_shoot(
			self_pos, _attacking_goal_pos, goalie_pos,
			GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
			_scratch_opponents_shoot)
	# Slapper: same geometry but with opponents predicted at the longer
	# slapper-charge lookahead (more chance a defender steps into the
	# lane during the windup), then scaled by SLAPPER_POWER_BONUS for
	# the harder-to-stop release. Take whichever of wrister/slapper
	# scores higher as the "shoot" option.
	var slapper_score: float = AIActionScoring.score_shoot(
			self_pos, _attacking_goal_pos, goalie_pos,
			GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
			_scratch_opponents_slapper) * SLAPPER_POWER_BONUS
	var shoot_use_slapper: bool = slapper_score > wrister_score
	var shoot_score: float = slapper_score if shoot_use_slapper else wrister_score
	var self_state: SkaterNetworkState = snapshot.skater_states[_peer_id]
	var best_pass: Array = _compute_best_pass(
			snapshot, self_pos, self_state.facing, goalie_pos)
	var best_pass_peer: int = best_pass[0]
	var best_pass_score: float = best_pass[1]
	var dump_score: float = AIActionScoring.score_dump(
			self_pos, _attacking_goal_pos, _own_goal_dir,
			GameRules.BLUE_LINE_Z, _scratch_opponents)
	_update_debug_scores(shoot_score, shoot_use_slapper, best_pass_peer, best_pass_score, dump_score)

	var max_score: float = maxf(maxf(shoot_score, best_pass_score), dump_score)
	if max_score < AIActionScoring.ACTION_THRESHOLD:
		return
	# Set intent instead of transitioning immediately. CARRY's per-tick
	# logic pre-aims toward this action's direction and transitions
	# only when the motion-limited mouse converges (or the wait
	# timeout fires) — see _state_carry.
	if shoot_score >= best_pass_score and shoot_score >= dump_score:
		_shot_is_elevated = _should_elevate_shot(snapshot)
		if shoot_use_slapper:
			debug_last_decision = "SLAP"
			_intended_action = State.SLAPPER_PRESSED
		else:
			debug_last_decision = "SHOOT"
			_intended_action = State.SHOOT_PRESSED
	elif best_pass_score >= dump_score:
		_pass_target_peer_id = best_pass_peer
		debug_last_decision = "PASS→%d" % (best_pass_peer % 1000)
		_intended_action = State.PASS_PRESSED
	else:
		debug_last_decision = "DUMP"
		_intended_action = State.DUMP_PRESSED
	_intent_wait_ticks = 0


# Populates the three scratch lists used by _pick_action's scoring:
# - _scratch_opponents: current opponent positions, for dump scoring.
# - _scratch_opponents_shoot: positions predicted forward by the
#   wrister-charge window, for wrister scoring.
# - _scratch_opponents_slapper: positions predicted forward by the
#   slapper-charge window (longer than wrister), for slapper scoring.
# Pass scoring uses a fourth per-receiver list (_scratch_opponents_pass)
# rebuilt inside `_compute_best_pass` because the lookahead varies per
# teammate.
func _build_action_opponents_lists(snapshot: WorldSnapshot) -> void:
	_scratch_opponents.clear()
	_scratch_opponents_shoot.clear()
	_scratch_opponents_slapper.clear()
	for peer_id: int in snapshot.skater_states:
		if int(_team_id_resolver.call(peer_id)) != _team_id and peer_id != _peer_id:
			var s: SkaterNetworkState = snapshot.skater_states[peer_id]
			_scratch_opponents.append(s.position)
			_scratch_opponents_shoot.append(AITrajectory.predict_at(
					s.position, s.velocity, BOT_WRISTER_LOOKAHEAD_S))
			_scratch_opponents_slapper.append(AITrajectory.predict_at(
					s.position, s.velocity, BOT_SLAPPER_LOOKAHEAD_S))


# Loops every legal pass target and returns [best_pid, best_score]. A
# pass takes 0.5–1.1 s of flight time, so the receiver and every
# defender are projected forward by that flight time before scoring —
# decision matches what `_pass_aim_point` actually fires at press time.
# Skips ghosted teammates (collision masks off → puck would pass
# through them) and unreachable receivers (outside the bot's blade
# ROM cone — quick-shot would fire at the ROM edge instead of the
# receiver). Human teammates get HUMAN_PASS_BIAS on close-call passes.
func _compute_best_pass(snapshot: WorldSnapshot, self_pos: Vector3,
		self_facing_xz: Vector2, goalie_pos: Vector3) -> Array:
	var best_pass_peer: int = 0
	var best_pass_score: float = 0.0
	# When the carrier is in our OZ, exclude receivers that aren't
	# also in OZ. Passing the puck out of OZ to a NZ teammate sends
	# the puck back across the blue line; if our carrier was in OZ
	# when the puck left and the new carrier brings it back in, the
	# original carrier is offside. Filtering here prevents that
	# whole sequence — bots only pass back-pass-out when they
	# themselves are in NZ.
	var carrier_in_oz: bool = -_own_goal_dir * self_pos.z > GameRules.BLUE_LINE_Z
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) != _team_id:
			continue
		var receiver_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		if receiver_state.is_ghost:
			continue
		if carrier_in_oz:
			var receiver_in_oz: bool = -_own_goal_dir * receiver_state.position.z > GameRules.BLUE_LINE_Z
			if not receiver_in_oz:
				continue
		var dist: float = self_pos.distance_to(receiver_state.position)
		var flight_t: float = clampf(
				dist / PASS_PUCK_SPEED_REF_M_S, 0.0, PASS_LEAD_MAX_S)
		var receiver: Vector3 = AITrajectory.predict_at(
				receiver_state.position, receiver_state.velocity, flight_t)
		if not _is_pass_target_reachable(self_pos, self_facing_xz, receiver):
			continue
		_scratch_opponents_pass.clear()
		for opp_pid: int in snapshot.skater_states:
			if opp_pid == _peer_id:
				continue
			if int(_team_id_resolver.call(opp_pid)) == _team_id:
				continue
			var opp_state: SkaterNetworkState = snapshot.skater_states[opp_pid]
			_scratch_opponents_pass.append(AITrajectory.predict_at(
					opp_state.position, opp_state.velocity, flight_t))
		# One-timer demand: receiver pre-charging a slapper without the
		# puck (`shot_state == SLAPPER_CHARGE_WITHOUT_PUCK`) is asking
		# for the puck. Boost their RECEIVER_QUALITY (shot opportunity
		# from where they are), not the final score — this leaves the
		# lane and pressure terms intact, so a slapper-charging
		# receiver behind a blocked lane still scores 0, and one
		# under heavy pressure still gets the pressure penalty.
		var receiver_q_bonus: float = (
				ONE_TIMER_TARGET_BONUS
				if receiver_state.shot_state == _SHOT_STATE_SLAPPER_CHARGE_WITHOUT_PUCK
				else 1.0)
		var s: float = AIActionScoring.score_pass(
				self_pos, receiver, receiver_state.facing,
				_attacking_goal_pos, goalie_pos,
				GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
				_scratch_opponents_pass,
				receiver_q_bonus)
		if NetworkManager.is_real_peer(peer_id):
			s = minf(s * HUMAN_PASS_BIAS, 1.0)
		if s > best_pass_score:
			best_pass_score = s
			best_pass_peer = peer_id
	return [best_pass_peer, best_pass_score]


# Updates `debug_scores` for the on-ice debug label. Top 3 sorted desc.
# `shoot_use_slapper` swaps the shot label so the on-ice readout
# shows whether the bot would slap or wrister at this tick.
func _update_debug_scores(shoot_score: float, shoot_use_slapper: bool,
		best_pass_peer: int, best_pass_score: float, dump_score: float) -> void:
	var pass_label: String = "pass→%d" % (best_pass_peer % 1000) if best_pass_peer != 0 else "pass"
	var shoot_label: String = "slap" if shoot_use_slapper else "shoot"
	var rows: Array = [
			[shoot_label, shoot_score],
			[pass_label, best_pass_score],
			["dump", dump_score],
	]
	rows.sort_custom(func(a, b): return a[1] > b[1])
	debug_scores.clear()
	for r: Array in rows:
		debug_scores.append("%s:%.2f" % [r[0], r[1]])


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


func _apply_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, anchor: Vector3,
		exempt_opp_pid: int = -1) -> void:
	# Single-pass split into teammate vs opponent buckets — both feed
	# AISteering's repel forces. `exempt_opp_pid` skips one specific
	# opponent from the opponent-repel list — used by man-to-man so
	# the defender can stand shoulder-to-shoulder with their mark
	# instead of being pushed away by them.
	_scratch_teammates.clear()
	_scratch_opponents.clear()
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			_scratch_teammates.append(snapshot.skater_states[peer_id].position)
		elif peer_id != exempt_opp_pid:
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


# Returns the opposing goalie's position predicted forward by
# BOT_WRISTER_LOOKAHEAD_S along their current velocity. Goalies actively
# slide at 4-5 m/s on shots; aiming at where the goalie IS rather than
# where they WILL BE hands them the save by the time our wrister
# releases (250 ms after decision). Falls back to _attacking_goal_pos
# when the goalie state isn't buffered yet (first-frame edge case);
# downstream geometry handles that input gracefully (degenerates to a
# corner aim past a "goalie at the goal center").
func _predicted_goalie_pos(snapshot: WorldSnapshot) -> Vector3:
	var opp_goalie: GoalieNetworkState = snapshot.goalie_states.get(1 - _team_id)
	if opp_goalie == null:
		return _attacking_goal_pos
	return AITrajectory.predict_at(
			Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z),
			Vector3(opp_goalie.velocity_x, 0.0, opp_goalie.velocity_z),
			BOT_WRISTER_LOOKAHEAD_S)


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
	if to_goal.length_squared() > 0.0001:
		forward_dir = to_goal.normalized()
	else:
		forward_dir = Vector3.FORWARD
	var base: Vector3 = self_pos + forward_dir * CARRY_BLADE_AIM_FORWARD_M
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


# Shot aim past the goalie's projected shadow.
func _shot_aim_point(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	return AIShotAim.compute_open_net_aim(
			self_pos, _predicted_goalie_pos(snapshot),
			_attacking_goal_pos.z,
			GameRules.NET_HALF_WIDTH,
			GOALIE_SHADOW_HALF)


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
# tick budget. Initialized to ZERO; first call snaps it to the
# target. See MOUSE_MAX_SPEED_M_S comment block for rationale.
var _mouse_pos: Vector3 = Vector3.ZERO

# Strong-side sign with hysteresis. See STRONG_SIDE_HYSTERESIS_M.
# Initialized to +1 (strong side defaults to +X); flips to -1 only
# when puck.x falls below -1.5, and back to +1 only when puck.x
# rises above +1.5. Per-bot so each bot tracks its own state.
var _last_strong_x: float = 1.0


# Steps `_mouse_pos` toward `target` at MOUSE_MAX_SPEED_M_S, capped by
# the tick budget. First call (when _mouse_pos is ZERO) snaps to the
# target. Returns the result with small per-tick noise for organic
# feel. Replaces the various per-state smoothing methods we used to
# have — single consistent model for every aim target.
func _step_mouse_toward(target: Vector3) -> Vector3:
	if _mouse_pos == Vector3.ZERO:
		_mouse_pos = Vector3(target.x, 0.0, target.z)
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


# Returns the strong-side sign for a puck/self position with
# per-bot hysteresis. Replaces the inline
# `signf(x) if absf(x) > DEADBAND else 1.0` pattern that was
# vulnerable to per-tick flipping near the deadband boundary.
func _hysteretic_strong_x(x: float) -> float:
	if _last_strong_x > 0.0:
		if x < -STRONG_SIDE_HYSTERESIS_M:
			_last_strong_x = -1.0
	else:
		if x > STRONG_SIDE_HYSTERESIS_M:
			_last_strong_x = 1.0
	return _last_strong_x

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
	var threat_pos: Vector3 = snapshot.puck_state.position
	var mark_pid: int = _current_mark_pid(snapshot)
	if mark_pid != 0:
		var mark_state: SkaterNetworkState = snapshot.skater_states.get(mark_pid)
		if mark_state != null:
			threat_pos = mark_state.position
	var to_threat: Vector3 = threat_pos - self_pos
	if to_threat.length() > 0.3:
		return to_threat.normalized()
	return _read_facing_3d(snapshot)


func _is_f1() -> bool:
	return _team_brain != null and _team_brain.get_role(_peer_id) == AIRoleAssignment.ROLE_F1


func _is_f3() -> bool:
	return _team_brain != null and _team_brain.get_role(_peer_id) == AIRoleAssignment.ROLE_F3


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

	# Give-and-go cut takes priority over role anchors while active. The
	# pre-computed anchor sits up-ice from the pass release; _cap_offside
	# pulls it back to the NZ side of the blue line until the puck enters
	# OZ, so the cut respects the same offside discipline as a normal
	# off-puck breakout.
	if _give_and_go_remaining_ticks > 0:
		return _cap_offside(_give_and_go_anchor, snapshot)

	# Net-front screen: if a teammate is winding up a slapper and I'm
	# the closest non-shooter teammate to the opposing net, park 1.5 m
	# in front of the crease to screen. Bots don't slap themselves
	# (only wristers), so this fires when a HUMAN teammate winds up.
	var screen_anchor: Vector3 = _net_front_screen_anchor_or_zero(snapshot, self_pos)
	if screen_anchor != Vector3.ZERO:
		return screen_anchor

	# Emergency backcheck: caught up-ice with opp possession on our
	# defensive half. The deepest non-carrier (F3 per the high-man
	# pin) sprints to the centred defensive slot — they're the
	# "safety" position. F1 and F2 caught up-ice fall through to
	# man-to-man instead of also routing to the centred slot, so
	# multiple backcheckers don't all converge on the same point
	# (which produced visible stacking / bots ramming each other in
	# the slot). F1/F2 marks are different opps so their anchors
	# spread naturally; the small route inefficiency is worth the
	# avoided collisions.
	if _is_caught_up_ice(snapshot, self_pos) and _is_f3():
		return _emergency_backcheck_anchor(snapshot)

	var anchor: Vector3
	# Man-to-man takes priority on our defensive half when the opp has
	# the puck (or it's loose). The brain publishes the coverage map at
	# 6 Hz; we just look up our mark.
	if _should_play_man_to_man(snapshot):
		var mark_pid: int = _team_brain.get_coverage_target(_peer_id) if _team_brain != null else 0
		if mark_pid != 0:
			var mark: SkaterNetworkState = snapshot.skater_states.get(mark_pid)
			if mark != null:
				return _cap_offside(_clamp_man_anchor_to_dz(_man_anchor(mark), snapshot), snapshot)

	var role: StringName = _team_brain.get_role(_peer_id) if _team_brain != null else AIRoleAssignment.ROLE_OFF
	match role:
		AIRoleAssignment.ROLE_F2:
			anchor = _f2_anchor(puck_pos, snapshot)
		AIRoleAssignment.ROLE_F3:
			anchor = _f3_anchor(puck_pos, snapshot)
		_:
			# Legacy / fallback — Phase 3 anchor (above puck on own-net
			# side, X tracking the bot's current X to avoid sliding sideways).
			var anchor_z: float = puck_pos.z + _own_goal_dir * LEGACY_OFF_DEPTH
			anchor = _clamp_anchor(Vector3(self_pos.x, 0.0, anchor_z))
	return _cap_offside(anchor, snapshot)


# F2 anchor — strong-side support. Two modes based on F1's pressure:
#   - F1 heavily pressured (2+ defenders within F1_PRESSURE_RADIUS_M):
#     collapse to close-support, ~1.5 m off F1 to give a quick outlet.
#   - F1 has space: triangle apex 3 m off puck.x, 2 m back. Spread out
#     and look like a passing option.
# STRONG_SIDE_X_DEADBAND prevents the strong/weak flip when the puck
# (or F1) wiggles through the center.
func _f2_anchor(puck_pos: Vector3, snapshot: WorldSnapshot) -> Vector3:
	var f1_pid: int = _f1_peer_id()
	if f1_pid != 0:
		var f1_state: SkaterNetworkState = snapshot.skater_states.get(f1_pid)
		if f1_state != null:
			var pressure: int = _opp_count_within(
					f1_state.position, F1_PRESSURE_RADIUS_M, snapshot)
			if pressure >= F1_HEAVY_PRESSURE_COUNT:
				return _f2_support_anchor(f1_state.position, puck_pos)
	# Default: triangle apex (F1 has space, F2 looks for an open lane).
	var strong_x: float = _hysteretic_strong_x(puck_pos.x)
	var x: float = puck_pos.x + strong_x * F2_OFFSET_X
	var z: float = puck_pos.z + _own_goal_dir * F2_OFFSET_Z_BACK
	return _clamp_anchor(Vector3(x, 0.0, z))


# Close-support anchor relative to F1, on the strong side. Used when
# F1 is heavily pressured and needs an immediate outlet target.
func _f2_support_anchor(f1_pos: Vector3, puck_pos: Vector3) -> Vector3:
	var strong_x: float = _hysteretic_strong_x(puck_pos.x)
	var x: float = f1_pos.x + strong_x * F2_SUPPORT_OFFSET_X
	var z: float = f1_pos.z + _own_goal_dir * F2_SUPPORT_OFFSET_Z_BACK
	return _clamp_anchor(Vector3(x, 0.0, z))


# Returns the F1 teammate's peer_id, or 0 if no F1 is currently
# assigned (TeamBrain hasn't run yet, or only one teammate on team).
func _f1_peer_id() -> int:
	if _team_brain == null:
		return 0
	for peer_id: int in _team_brain.roles:
		if _team_brain.roles[peer_id] == AIRoleAssignment.ROLE_F1:
			return peer_id
	return 0


# Counts opponents within `radius` of `pos` in XZ. Used by F2 to read
# F1's pressure level — separate from _opponent_within (bool) because
# the threshold is count-based.
func _opp_count_within(pos: Vector3, radius: float, snapshot: WorldSnapshot) -> int:
	var n: int = 0
	var r2: float = radius * radius
	for peer_id: int in snapshot.skater_states:
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			continue
		var p: Vector3 = snapshot.skater_states[peer_id].position
		var dx: float = p.x - pos.x
		var dz: float = p.z - pos.z
		if dx * dx + dz * dz < r2:
			n += 1
	return n


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


# Like _opponent_within but only counts opponents in the forward
# half-plane relative to `forward_dir`. Used by the wrister bail —
# defenders behind or beside the shooter aren't realistic threats to
# a wrister windup; matches the pressure cube falloff convention. A
# zero-length forward_dir falls through to the omnidirectional check
# so degenerate inputs don't silently skip the bail entirely.
func _opponent_within_forward(snapshot: WorldSnapshot, pos: Vector3,
		forward_dir: Vector3, radius: float) -> bool:
	var fwd_len: float = sqrt(forward_dir.x * forward_dir.x + forward_dir.z * forward_dir.z)
	if fwd_len < 0.001:
		return _opponent_within(snapshot, pos, radius)
	var fwd_x: float = forward_dir.x / fwd_len
	var fwd_z: float = forward_dir.z / fwd_len
	var r2: float = radius * radius
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			continue
		var op: Vector3 = snapshot.skater_states[peer_id].position
		var dx: float = op.x - pos.x
		var dz: float = op.z - pos.z
		if dx * dx + dz * dz >= r2:
			continue
		if dx * fwd_x + dz * fwd_z > 0.0:
			return true
	return false


# Tag-up anchor: just on the NZ side of the OZ blue line, preserving X
# so steering pulls us straight back. Buffer past the line so the
# host's has_tagged_up doesn't toggle on/off at the boundary.
func _tag_up_anchor(self_pos: Vector3) -> Vector3:
	var tag_z: float = -_own_goal_dir * (GameRules.BLUE_LINE_Z - OFFSIDE_HOLD_BUFFER_M)
	return _clamp_anchor(Vector3(self_pos.x, 0.0, tag_z))


# Give-and-go anchor: straight up-ice from the release point by
# GIVE_AND_GO_LEAD_M. Same X so the cut feels like a continuation of
# the bot's existing skating line rather than a teleport sideways.
# _clamp_anchor pulls it inside the rink and out of the crease.
func _compute_give_and_go_anchor(release_pos: Vector3) -> Vector3:
	var anchor_z: float = release_pos.z + (-_own_goal_dir) * GIVE_AND_GO_LEAD_M
	return _clamp_anchor(Vector3(release_pos.x, 0.0, anchor_z))


# Net-front screen check. Returns the screen anchor (centred X, ~1.5 m
# in front of the crease arc, on the puck-side of the goal line) when
# a teammate is currently in SLAPPER_CHARGE_WITH_PUCK AND I'm the
# closest non-shooter teammate to that anchor. Otherwise returns
# Vector3.ZERO meaning "no screen, fall through to role anchor."
#
# Bots only fire wristers themselves, so this fires when a HUMAN
# teammate is winding up a slapper from the point — the bot picks up
# the screen role automatically. The screen is dropped the moment the
# slapper releases (state moves to FOLLOW_THROUGH) or bails (back to
# SKATING_WITH_PUCK).
func _net_front_screen_anchor_or_zero(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var slapper_pid: int = 0
	for pid: int in snapshot.skater_states:
		if pid == _peer_id:
			continue
		if int(_team_id_resolver.call(pid)) != _team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		if s.shot_state == _SHOT_STATE_SLAPPER_CHARGE_WITH_PUCK:
			slapper_pid = pid
			break
	if slapper_pid == 0:
		return Vector3.ZERO
	# Anchor: ~1.5 m past the crease arc edge on the puck-side of the
	# attacking goal line. Centred in X (in front of the net mouth).
	var screen_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - SCREEN_OFFSET_FROM_GOAL_LINE_M)
	var screen_anchor := Vector3(0.0, 0.0, screen_z)
	# Closest non-shooter teammate (including me) wins the screen role.
	# Tie-break: peer_id ascending so the choice is stable.
	var my_dist: float = self_pos.distance_to(screen_anchor)
	for pid: int in snapshot.skater_states:
		if pid == _peer_id or pid == slapper_pid:
			continue
		if int(_team_id_resolver.call(pid)) != _team_id:
			continue
		var pos: Vector3 = snapshot.skater_states[pid].position
		var their_dist: float = pos.distance_to(screen_anchor)
		if their_dist < my_dist or (their_dist == my_dist and pid < _peer_id):
			return Vector3.ZERO
	return _clamp_anchor(screen_anchor)


# True iff this bot is caught up-ice during opp possession on our
# defensive half — i.e. the puck is BETWEEN us and our own net, and
# the opp (or a loose puck) is heading toward us. Triggers the
# emergency backcheck override that anchors us to the defensive slot
# instead of routing through man-to-man's mark anchor.
#
# Gates:
#   - Bot forward of puck (puck closer to own net than bot).
#   - Opp possession or loose puck (own possession is a breakout, not
#     a defensive scenario).
#   - Puck on our defensive half (NZ or DZ). In our OZ a "caught"
#     bot is forechecking, not backchecking — let normal anchors
#     handle that.
func _is_caught_up_ice(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	var puck_pos: Vector3 = snapshot.puck_state.position
	if _own_goal_dir * (self_pos.z - puck_pos.z) >= 0.0:
		return false
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier != -1 and int(_team_id_resolver.call(carrier)) == _team_id:
		return false
	if -_own_goal_dir * puck_pos.z > GameRules.BLUE_LINE_Z:
		return false
	return true


# Backcheck destination: BACKCHECK_BACK_OF_PUCK_M behind the puck
# (toward own net), centred X, capped at the defensive slot depth so
# we never overshoot into our own crease. Working in signed depth
# (own_goal_dir × z) so the same expression handles both teams —
# larger depth = closer to own net.
func _emergency_backcheck_anchor(snapshot: WorldSnapshot) -> Vector3:
	var puck_pos: Vector3 = snapshot.puck_state.position
	var puck_depth: float = _own_goal_dir * puck_pos.z
	var anchor_depth: float = puck_depth + BACKCHECK_BACK_OF_PUCK_M
	var max_depth: float = GameRules.GOAL_LINE_Z - BACKCHECK_MAX_DEPTH_FROM_GOAL_M
	var clamped: float = minf(anchor_depth, max_depth)
	return Vector3(0.0, 0.0, _own_goal_dir * clamped)


# True iff we're defending — opp has the puck (or it's loose) and the
# puck is on our defensive half (NZ or DZ). Man-to-man fires here so
# bots pick up assignments during the 1-2 s transition window when an
# opp rush is forming, not just after the puck crosses our blue line.
# Skipped in our OZ (forecheck zone — F2/F3 zone anchors handle it)
# and skipped under own possession (breakout, not defensive coverage).
func _should_play_man_to_man(snapshot: WorldSnapshot) -> bool:
	var puck_pos: Vector3 = snapshot.puck_state.position
	# Puck in OZ? (our attacking zone — opp's defensive zone). Skip man.
	if -_own_goal_dir * puck_pos.z > GameRules.BLUE_LINE_Z:
		return false
	# Don't play man if our team has possession — breakout, not defense.
	# Loose pucks DO trigger man (opp forwards are crashing, mark them).
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
# Returns the peer_id of our current man-to-man mark (the opponent we
# should be guarding), or 0 if not playing man (or no mark assigned).
# Used by `_state_off_puck` to exempt the mark from opponent repel —
# defenders are supposed to stand on top of their mark, not get
# pushed away. Reads `_team_brain.coverage_targets` which is
# populated at 6 Hz; keeps cadence consistent with role assignment.
func _current_mark_pid(snapshot: WorldSnapshot) -> int:
	if not _should_play_man_to_man(snapshot):
		return 0
	if _team_brain == null:
		return 0
	return _team_brain.get_coverage_target(_peer_id)


func _man_anchor(mark: SkaterNetworkState) -> Vector3:
	var lead_pos: Vector3 = AITrajectory.predict_at(
			mark.position, mark.velocity, MAN_LEAD_TIME_S)
	# Mark in/near our crease: don't try to step goal-side of them.
	# The anchor would land past the goal line and get clamped to the
	# crease arc, which (combined with opponent repel from the mark
	# itself) drifts the defender 4-5 m off the crease. Better to
	# stand shoulder-to-shoulder with the mark — see
	# `_apply_steering`'s exempt-opp logic so the mark doesn't repel
	# us.
	if CreaseRules.is_in_crease(Vector2(lead_pos.x, lead_pos.z)):
		return _clamp_anchor(lead_pos)
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


# Clamp a man-to-man anchor to stay on our DZ side of the blue line
# WHEN the puck is in our DZ. Without this, a defender's mark
# drifting toward the OZ blue line for a regroup setup pulled the
# defender out of the zone with them — gives up easy keep-ins and
# the bot has to backtrack on regroups. Real-hockey rule: defenders
# hold the zone during DZ defense, even if their mark wanders out.
# Clamp only fires when puck is in DZ; in NZ defense (e.g.
# transition coverage) the bot can mark across the line normally.
func _clamp_man_anchor_to_dz(anchor: Vector3, snapshot: WorldSnapshot) -> Vector3:
	var puck_depth: float = _own_goal_dir * snapshot.puck_state.position.z
	if puck_depth <= GameRules.BLUE_LINE_Z:
		return anchor   # puck not in our DZ — no clamp
	var anchor_depth: float = _own_goal_dir * anchor.z
	if anchor_depth >= GameRules.BLUE_LINE_Z:
		return anchor   # already on our DZ side
	return Vector3(anchor.x, anchor.y, _own_goal_dir * GameRules.BLUE_LINE_Z)


# F3 anchor — strong-side trailer / high man. Shades to the puck side
# (smaller magnitude than F2's apex offset so they don't stack) and
# sits 8 m back toward our own goal as a safety valve.
func _f3_anchor(puck_pos: Vector3, snapshot: WorldSnapshot) -> Vector3:
	var strong_x: float = _hysteretic_strong_x(puck_pos.x)
	var x: float = puck_pos.x + strong_x * F3_OFFSET_X_STRONG
	# In OZ: free-safety position. When OUR team has possession, plant
	# just inside the OZ blue line — the textbook 3v3 "F3 high" rule.
	# The whole point of F3 high is that a turnover at this depth doesn't
	# leak a clean breakaway. Anywhere deeper and we're gone before we
	# can recover. When the puck is loose or the opp has it, fall back
	# to the trail-with-clamp behavior: chasing a loose OZ puck is a
	# legit forecheck role and the "back of the dots" cap still applies.
	# In NZ / DZ: legacy above-puck trailer position.
	var z: float
	if -_own_goal_dir * puck_pos.z > GameRules.BLUE_LINE_Z:
		if _own_team_has_possession(snapshot):
			z = -_own_goal_dir * (GameRules.BLUE_LINE_Z + F3_OZ_OWN_POSSESSION_DEPTH_M)
		else:
			var trail_z: float = puck_pos.z + _own_goal_dir * F3_OZ_TRAIL_DEPTH_M
			var oz_blue_line_z: float = -_own_goal_dir * GameRules.BLUE_LINE_Z
			var oz_dot_back_z: float = -_own_goal_dir * (
					GameRules.ICING_FACEOFF_DOT_Z - F3_OZ_DOT_BACK_OFFSET_M)
			var lo: float = minf(oz_blue_line_z, oz_dot_back_z)
			var hi: float = maxf(oz_blue_line_z, oz_dot_back_z)
			z = clampf(trail_z, lo, hi)
	else:
		z = puck_pos.z + _own_goal_dir * F3_OFFSET_Z_BACK
	return _clamp_anchor(Vector3(x, 0.0, z))


# True iff the puck currently has a carrier on our team. Used by the F3
# "high man" branch to know whether to plant near the blue line (own
# possession → guard against the breakaway on a turnover) or fall back
# to the trail-and-chase clamp (loose puck or opp possession).
func _own_team_has_possession(snapshot: WorldSnapshot) -> bool:
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier == -1:
		return false
	return int(_team_id_resolver.call(carrier)) == _team_id


# True iff conditions favour pre-charging a slapper to demand the puck.
# Four gates, all must pass:
#   (1) Not ghosted. Ghosted (offside) bots can't legally receive a
#       pass — their collision masks are off — so the puck would
#       pass through them and the slapper would never fire. Tag up
#       first; `_off_puck_anchor` already routes ghosted bots to the
#       tag-up anchor, this gate keeps them there instead of letting
#       them transition into ONE_TIMER_CHARGE.
#   (2) A teammate carries the puck (own possession, not me).
#   (3) score_shoot from my current position clears the trigger
#       threshold — i.e. I have a real one-timer threat from here,
#       not just wandering the OZ.
#   (4) The carrier is on my NON-blade side. The slapper zone is
#       offset to the blade side; for the puck to enter the zone on
#       a pass, the puck path (carrier → me → continuation) must
#       cross the zone — which only happens if the carrier is on
#       the opposite side of my body from the blade. RH receiver
#       wants carrier on their LEFT; LH wants carrier on their
#       RIGHT. Without this gate, RH bots would pre-charge for
#       cross-passes coming from the wrong side and the puck would
#       miss the zone entirely.
#
# Uses _scratch_opponents which is populated by `_apply_steering`
# earlier in the OFF_PUCK tick, so callers must run after that.
func _should_pre_charge_slapper(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null or self_state.is_ghost:
		return false
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier == -1 or carrier == _peer_id:
		return false
	if int(_team_id_resolver.call(carrier)) != _team_id:
		return false
	# Geometry gate: carrier on non-blade side.
	var carrier_state: SkaterNetworkState = snapshot.skater_states.get(carrier)
	if carrier_state != null:
		var blade_dir: Vector2 = _blade_side_dir(self_state.facing)
		var to_carrier: Vector2 = Vector2(
				carrier_state.position.x - self_pos.x,
				carrier_state.position.z - self_pos.z)
		# Carrier on blade side → puck path won't cross the zone.
		if blade_dir.dot(to_carrier) >= 0.0:
			return false
	var goalie_pos: Vector3 = _predicted_goalie_pos(snapshot)
	var score: float = AIActionScoring.score_shoot(
			self_pos, _attacking_goal_pos, goalie_pos,
			GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
			_scratch_opponents)
	return score >= ONE_TIMER_TRIGGER_THRESHOLD


# Slapper zone position in world XZ. Mirrors SkaterController's
# `get_slapper_zone_global_position` based on facing + handedness.
# Zone is forward + lateral-blade-side from the player; for RH
# blade-side is "right of facing" (facing.y, -facing.x), for LH the
# opposite. Used by the release-distance check so we drop slap_held
# when the puck nears the actual zone, not just the player body.
func _compute_slapper_zone_pos(self_pos: Vector3, facing: Vector2) -> Vector3:
	var blade_dir: Vector2 = _blade_side_dir(facing)
	# Forward direction in world XZ is (facing.x, facing.y).
	return Vector3(
			self_pos.x + facing.x * SLAPPER_ZONE_FORWARD_M + blade_dir.x * SLAPPER_ZONE_LATERAL_M,
			0.0,
			self_pos.z + facing.y * SLAPPER_ZONE_FORWARD_M + blade_dir.y * SLAPPER_ZONE_LATERAL_M)


# Unit direction from player toward their blade side, in world XZ.
# RH player: blade on the right of their facing. LH: opposite.
# Right-of-facing in our (sin, cos)-of-bearing convention is
# (facing.y, -facing.x); LH negates.
func _blade_side_dir(facing: Vector2) -> Vector2:
	var sign: float = -1.0 if _is_left_handed else 1.0
	return Vector2(facing.y * sign, -facing.x * sign)


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
	var goalie_pos: Vector3 = _predicted_goalie_pos(snapshot)

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
	# beats it. EXCEPT: when the carrier is at or past the goal-line
	# buffer (the dead zone right at and behind the net), don't let
	# "stay here" win — force the search to pick a forward candidate.
	# Without this gate the bot would happily park behind the net if
	# pass score from there happened to be decent, even though shot
	# score is zeroed by `_is_past_goal_line`. Real hockey: behind the
	# net is a setup spot, not a destination.
	var current_past_goal_buffer: bool = (
			absf(self_pos.z) > absf(_attacking_goal_pos.z) - CARRY_GOAL_LINE_BUFFER_M)
	var best_pos: Vector3 = self_pos
	var best_score: float
	if current_past_goal_buffer:
		best_score = -INF
	else:
		best_score = AIActionScoring.carry_position_score(
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
# Shifts an intercept point toward the center-ice X axis by
# CHASE_ANGLE_BIAS_M relative to the carrier's CURRENT X. The shift
# magnitude is capped at the carrier's |X| so we never overshoot to
# the opposite side of center — that would put the bot on the carrier's
# OUTSIDE and open the middle, the exact pattern we're trying to avoid.
# Carriers within CHASE_ANGLE_BIAS_M of center are left alone (no
# inside to take away).
#
# Static + private so it's unit-testable without standing up a full SM.
static func _angle_intercept_inside(target: Vector3, carrier_pos: Vector3) -> Vector3:
	if absf(carrier_pos.x) <= CHASE_ANGLE_BIAS_M:
		return target
	var bias: float = -signf(carrier_pos.x) * CHASE_ANGLE_BIAS_M
	return Vector3(target.x + bias, target.y, target.z)


# True iff `aim_pos` sits inside the quick-shot blade ROM cone from
# `self_pos` given `facing_xz`. See PASS_REACHABLE_DOT_MIN comment for
# the underlying mechanic. Used by `_pick_action` to drop unreachable
# pass targets before scoring; receivers behind the bot's facing
# would otherwise be picked as "open" and the actual quick-shot would
# fire at the ROM edge instead. Static + private so it's
# unit-testable without standing up a full SM.
#
# `facing_xz` follows the SkaterNetworkState convention (Vector2 of
# unit-length world XZ). Degenerate aims (aim coincident with self)
# return true since there's no direction to constrain.
static func _is_pass_target_reachable(self_pos: Vector3, facing_xz: Vector2,
		aim_pos: Vector3) -> bool:
	var dx: float = aim_pos.x - self_pos.x
	var dz: float = aim_pos.z - self_pos.z
	var len_sq: float = dx * dx + dz * dz
	if len_sq < 0.0001:
		return true
	var inv: float = 1.0 / sqrt(len_sq)
	var dot: float = facing_xz.x * dx * inv + facing_xz.y * dz * inv
	return dot >= PASS_REACHABLE_DOT_MIN


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
		# Slapper charge resets on entry: tick counter to zero and aim
		# target cleared so we don't fire with a stale target if we
		# bail before tick 0 finishes.
		if s == State.SLAPPER_PRESSED:
			_slapper_charge_tick = 0
			_slapper_aim_target = Vector3.ZERO
		# ONE_TIMER_CHARGE has its own aim-then-fire flow — reset the
		# "slap fired" flag so the next entry re-runs the aim wait.
		if s == State.ONE_TIMER_CHARGE:
			_one_timer_slap_fired = false
		# Give-and-go ends the moment we have the puck again — return
		# pass succeeded (or we picked up our own dump). The CARRY state
		# uses _carry_anchor, not the off-puck override, so leaving the
		# timer set wouldn't actively misbehave, but clearing here keeps
		# the next OFF_PUCK transition (post-shot, e.g.) clean.
		# Intent + wait counter reset on CARRY entry so a new puck
		# pickup gets a fresh _pick_action evaluation rather than
		# inheriting stale state from a previous CARRY.
		if s == State.CARRY:
			_give_and_go_remaining_ticks = 0
			_intended_action = State.CARRY
			_intent_wait_ticks = 0
		_state = s
		_ticks_in_state = 0


func _reset_to_off_puck() -> void:
	_state = State.OFF_PUCK
	_ticks_in_state = 0
	_pass_target_peer_id = 0
