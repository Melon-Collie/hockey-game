class_name SkaterAgentStateMachine
extends RefCounted

const _PhysicsConstants: GDScript = preload("res://Scripts/game/constants.gd")

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
	PASS_PRESSED,     # one-tick press window aimed at a teammate's lead position
	ONE_TIMER_PRESSED,   # off-puck FINISHER fire-on-contact when ready + puck in zone
}

# Margin from the goal line that anchors are clamped inside of. The
# matching X-inset lives on AIRoleHelpers.RINK_INSET_M (single source).
const RINK_Z_INSET: float = 1.0

# After CARRY's `_pick_action` chooses an action (PASS / SHOOT),
# the bot doesn't transition immediately — it pre-aims by setting
# the mouse target to the action's aim direction and waits for the
# motion-limited mouse to converge before firing. Without this, the
# action state's first tick fires with the mouse still mid-traversal
# from CARRY's previous target, so the quick-shot pass direction
# ends up at whatever angle the mouse happened to be at.
#
# AIM_CONVERGED_DIST_M is the distance treated as "converged" — a
# small slop budget for moving aim targets (receiver leads, goalie
# shadow drift). It lives on the CARRY_BLADE_AIM_FORWARD_M ring, so
# what it really gates is an ANGLE: 0.10 at the 1.3 m ring is ~±4.4°.
#
# INTENT_MAX_WAIT_TICKS is a safety timeout against convergence never
# landing (a receiver who keeps moving past the lead point, or
# numerical drift). Sized for the worst case under the arc-step model:
# a 180° swing at MOUSE_ARC_RATE_RAD_S = 7.5 rad/s takes π / 7.5 ≈
# 420 ms, so 120 ticks (500 ms) leaves a margin and then bails. Typical
# 30-60° swings converge in 60-120 ms, so this is an edge guard, not
# the dominant timing path. The arc-step in _step_mouse_aim is what
# keeps the body-aim angle inside the blade ROM during the swing.
const AIM_CONVERGED_DIST_M: float = 0.10

# Commit-then-aim safety margin (Aim-B2). The blade physically reaches anywhere
# inside the reach cone (_self_reach_cone_half_angle, ROM + torso twist ≈ 157°)
# from the FROZEN facing, so a shot/pass whose aim already falls inside the cone
# needs NO body rotation — the bot commits to the charge immediately and the blade
# swings to the aim while the body holds its heading (WRISTER_AIM freezes facing).
# Only aims in the narrow back wedge past the cone still pre-rotate the body, and
# only until the aim swings into the cone. This margin pulls the immediate-commit
# boundary a little inside the hard cone edge so the wind-up sweep (which draws the
# blade BACK past the aim before releasing through it) and the torso twist have
# headroom to develop over the short ~125 ms charge rather than committing on an
# aim the blade would still be clamping toward at release. A feel/safety knob —
# widen toward 0 if bots leave easy reachable aims on the table, tighten if a wide
# aim's blade visibly lags the release. FEEL, so hand-set (not an evaluator curve).
const AIM_COMMIT_CONE_MARGIN_RAD: float = deg_to_rad(25.0)

# Default / floor for the pre-aim convergence safety timeout (~500 ms).
# apply_profile() raises _intent_max_wait_ticks above this when a lower
# blade-slew cap slows a 180° swing, so the back-pass pre-aim always has time
# to converge before the bail fires regardless of difficulty.
const INTENT_MAX_WAIT_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 2   # ~500 ms
var _intent_max_wait_ticks: int = INTENT_MAX_WAIT_TICKS
# Execution error is a PER-RELEASE sample (see _sample_aim_error_rad /
# the aim-error block below), split shot-vs-pass per difficulty tier via
# BotSkillProfile.shot_aim_error_rad / pass_aim_error_rad. (Two older systems —
# per-tick output-cursor white noise, and a per-commit lateral-nudge wobble —
# were removed: the noise read as stick jitter, especially at the wobblier
# lower tiers.)
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
const ENGAGEMENT_COOLDOWN_MIN_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 10        # ~100 ms
const ENGAGEMENT_COOLDOWN_MAX_TICKS: int = _PhysicsConstants.PHYSICS_TICK * 2 / 5     # ~400 ms
const ENGAGEMENT_PROXIMITY_M: float = 2.0        # blade-on-puck range

# Reference top skating speed for chase intercept lookahead lives in
# AIActionScoring (`SKATER_REF_SPEED_M_S`) so it's a single source of
# truth across role behaviors + chase logic. Reference it directly
# below where needed.

# Cap on lead lookahead so a barely-moving puck doesn't project an
# intercept point a million seconds away. 3 s covers a full cross-ice
# race: with the speed-capped reachability model below, a long chase now
# resolves to a true far intercept instead of tail-aiming at the window's
# edge and re-aiming every dispatch (a pursuit curve that trails the play).
const CHASE_MAX_LOOKAHEAD_S: float = 3.0
# Steps per chase trajectory walk. Granular enough that the rink clamp
# catches a sliding puck hitting the boards mid-flight (so we don't aim
# at a point inside the wall), cheap enough at the dispatch cadence
# (same 0.125 s step as the original 1.5 s / 12-step walk).
const CHASE_TRAJECTORY_STEPS: int = 24
# Angling: when chasing an opposing CARRIER (not a loose puck), the
# intercept point is shaded one stick-reach toward OUR net
# (_shade_intercept_goal_side) so the approach comes in on the inside
# lane and forces the carrier outside. Real defenders don't chase
# straight-line at the puck — that lets the carrier cut to the middle.
# The shade distance is BLADE_REACH_M — the same real quantity
# PRESSURE's cut-off line uses — so the angling geometry scales with
# our actual poke range at every chase distance. (Replaced a flat
# 1.5 m center-ice X-shift that was invisible from range and ignored
# where the net actually was.)

# Kinematic chase intercept. At each step T of the puck trajectory walk,
# the bot is reachable iff the constant acceleration required to land at
# `puck_traj(T)` at time T (starting from current pos & velocity) has
# magnitude ≤ _chase_max_accel AND the resulting arrival speed stays within
# _self_max_speed (see _lead_intercept). Set to this bot's own thrust
# via apply_capabilities so the model reflects what the bot can
# actually pull off; the default below mirrors SkaterController.thrust's
# 12.0 default. The previous heuristic (effective_speed × T ≥ distance)
# ignored starting velocity direction except as a small ±50% bias, so a bot
# moving sideways relative to the puck would still be modelled as reaching
# the intercept by skating-from-rest at REF_SPEED — produced bad angles
# that the kinematic check rejects.
var _chase_max_accel: float = 12.0

# Per-peer velocity-history smoothing for acceleration estimation.
# Raw frame-over-frame velocity diffs at the physics rate are noisy (a thrust
# change adds ~0.05 m/s per tick which sits on top of float jitter); an
# IIR low-pass smooths to a usable signal. Half-life ≈ ln(2)/ALPHA
# ticks → 0.2 ≈ 14 ms half-life, enough damping to ignore single-
# tick spikes while still reacting inside a 400-600 ms pass window.
const ACCEL_SMOOTH_ALPHA: float = 0.2
# Clamp on the smoothed accel magnitude. Caps any pathological
# spike (e.g., teleport on respawn) at a value just above
# SkaterController.thrust so a legitimate hard turn still reads as
# full-thrust accel.
const ACCEL_CLAMP_M_S2: float = 14.0

# A loose puck above this speed is a live pass / stripped puck (not a puck to just
# skate onto): the chase AIMS the blade along its flight line rather than at a fixed
# intercept point, so the stick stays on the puck's path. The catch is decided by
# blade squareness + the puck's RELATIVE speed — its speed in the RECEIVER'S frame
# (puck − skater velocity; #373), the blade's own velocity still ignored. The bot
# collects a fast puck by squaring on the line (see _pass_receive_aim_and_steer),
# IN STRIDE by default — the arrival brake is only forced when the bot would
# otherwise arrive early enough to carry its blade past the line before the puck
# shows up, or when its own closing speed would stack over the catch ceiling.
# Squaring is what collects it; stopping is a wait, not a technique.
const LOOSE_PUCK_TRACK_SPEED_M_S: float = 8.0

# Pass-receive setup. When a fast loose puck (~pass) is heading near
# us along a straight trajectory, we stand offset to the SIDE of the
# puck's path so the stick spans perpendicular to the puck's velocity,
# putting the blade face square to the incoming line. Squaring is judged
# in the RECEIVER's frame (#373) — a receiver taking the feed in stride
# carries its own velocity into that frame, which is why the closing-speed
# ceiling is a separate check and not something squaring alone covers.
# That maximizes PuckReceptionRules'
# alignment bonus (up to +8 m/s at head-on), letting bots collect hard
# feeds that would otherwise bounce. See _pass_receive_aim_and_steer.
#
# Trigger threshold matches the deflect threshold: anything slower
# bot can collect at any angle, so the angle-optimal setup is
# unnecessary and would interfere with normal chase.
const RECEIVE_TRIGGER_PUCK_SPEED_M_S: float = 14.0
# Perpendicular distance cap. Bots farther than this from the puck's
# trajectory line don't consider it "their" pass — keeps non-receiver
# bots out of the setup, lets them keep doing whatever role they're
# assigned to. Sized generously so we cover any pass that would
# realistically end up at this bot.
const RECEIVE_TRIGGER_LATERAL_M: float = 5.0
# How far to stand SIDEWAYS of the puck's path. Derived from the
# bot's stick reach so the blade comfortably extends across to meet
# the puck — sit slightly inside full reach so the IK isn't at the
# ROM clamp (mirrors _blade_reach's outward buffer, just signed
# inward). Reach scales with this bot's own stick + blade span via
# apply_capabilities; the default below is the league baseline.
const RECEIVE_BODY_INSET_M: float = 0.2
var _receive_body_offset: float = (
		GameRules.DEFAULT_STICK_LENGTH_M
		+ GameRules.DEFAULT_BLADE_LENGTH_M
		- RECEIVE_BODY_INSET_M)
# Bot must reach the body anchor with this fraction of the puck's
# flight time to spare — otherwise the default lead-intercept (which
# gets the bot to the puck faster, even if at a worse angle) wins.
const RECEIVE_TIMING_MARGIN: float = 0.9
# Body-center inset from the boards for the receive stance anchor (a
# skater's collision radius, so the shoulder — not the anchor point —
# stops at the glass). Applies when the side-stand offset from a
# boards-hugging rim line would push the stance into the wall.
const RECEIVE_BODY_WALL_MARGIN_M: float = 0.5

# ── Board-aware reception path (rims) ────────────────────────────────────────
# The reception stance and the blade gate are solved on the puck's REAL path
# (AITrajectory.solve_reception_gate — friction, board caroms and all) rather
# than the straight ray off its current velocity. See that function's doc for
# why the straight ray specifically breaks on rims: the arrival time is measured
# along a chord instead of around the carom arc, and the blade squares to the
# pre-carom direction. Horizon covers a full corner wrap at rim pace; the step
# count is what a segment-entry solve needs (not point sampling), so this is a
# ~20-step scalar walk per receiving bot.
const RECEIVE_PATH_HORIZON_S: float = 2.0
const RECEIVE_PATH_STEPS: int = 20

# ── Wall kill (trapping a rim against the boards) ────────────────────────────
# A puck riding the boards is caught by putting the STICK ON THE GLASS and
# letting it come into the blade — there is no gap for it to slip through, and
# the wall does half the work of killing it. A blade parked out on the puck's
# line with daylight behind it just gets beaten by any bounce off the kickplate,
# which is the "bots can't retrieve off the boards" failure.
#
# Two things follow when the gate sits in the wall band, and both are geometry,
# not preference: the body must stand on the RINK side of the puck's line (the
# other side is inside the boards, so half the stance choices aren't real), and
# the blade target belongs ON the inner wall surface rather than on the path —
# a blade aimed at the path line leaves exactly the gap the puck squirts
# through. Outside the band nothing changes and the ordinary side-stand runs.
const WALL_KILL_BAND_M: float = 1.0

# ── Shot-aware reception (catch WITH shot intent) ─────────────────────────────
# When a pass is incoming and a shot from the reception area is on, the bot
# either ONE-TIMES it (redirect on contact, no possession) or catches it in a
# NET-WARD posture (possession, drive in) — instead of the default chase, which
# aims the cursor AT the puck and so rotates the body to face the puck to grab
# it. That rotation, then the rotation back to the net to shoot, is dead time
# that kills point-blank chances. Both modes keep facing net-ward by aiming at
# a net-FORWARD catch point and standing so the puck arrives there.
#
# Engage gates (else fall through to the normal possession catch):
#   - incoming puck is a real pass (fast, loose, heading to us) — same geometry
#     as _pass_receive_aim_and_steer.
#   - a redirect from the reception point scores >= SHOT_RECEPTION_SCORE_GATE.
#     (score_shoot at the soft redirect pace folds in range, angle, lane, goalie —
#     so this one gate also means "in shooting range with a real look.")
#
# Mode A (one-time redirect) vs Mode B (catch-in-stride):
#   A when the feed is a LATERAL cross-pass on the forehand side, far enough
#     out that skating in buys nothing, and the bot isn't already barrelling
#     net-ward. Lateral matters mechanically: the one-timer holds the shot but
#     the puck must still be RECEIVED for the fire to trigger, and a net-aimed
#     blade is only square to the incoming puck (alignment ≈ sin(redirect
#     angle)) when the puck arrives across the body — a shallow feed slides off
#     a net-pointed blade. Hence the angle BAND, not a "shallower is better."
#   B otherwise — straight/own-side feed, close, or carrying momentum: catch
#     facing the net and let CARRY take the closer or in-stride shot.
const SHOT_RECEPTION_SCORE_GATE: float = 0.30
# Redirect angle = turn from puck-travel direction to net direction at the
# catch point. The band brackets "lateral enough that a net-aimed blade catches
# it" — at the 50° edge, alignment = sin(50°) = 0.77 → deflect threshold
# 14 + 8·0.77 ≈ 20 m/s, comfortably above the charged-pass speed (~19), so a
# one-timer across the whole band actually receives before it fires; peak is a
# square cross-seam at 90°.
const ONE_TIME_MIN_REDIRECT_RAD: float = 0.873      # deg_to_rad(50)
const ONE_TIME_MAX_REDIRECT_RAD: float = 2.269      # deg_to_rad(130)
const ONE_TIME_MIN_NET_DIST_M: float = 6.0
# Net-ward closing speed above which we're committed to driving in (Mode B)
# rather than stopping to redirect (Mode A).
const ONE_TIME_MAX_DRIVE_SPEED_M_S: float = 4.0
# Squared-up cone for committing a Mode A redirect. The one-time press locks the
# slapper direction from the cursor almost immediately (see the controller's
# locked_slapper_dir at slap-press), so the body must ALREADY be facing near the
# net line to lock a clean shot. A chasing bot still facing the puck it was
# tracking can't rotate square inside the brief reception window — pressing then
# would lock a "wherever I was looking" direction (the wonky one-timer). Beyond
# this cone we fall through to Mode B and CATCH the feed instead of firing a bad
# redirect. Sized generously (a cross-seam catch is naturally ~net-ward already)
# so genuine one-timer looks still convert.
const ONE_TIME_MAX_SQUARE_UP_RAD: float = 0.960     # deg_to_rad(55)
# Reception-decision return codes (see _try_shot_reception).
const _RECV_NONE: int = 0           # not a shot reception — run the normal catch
const _RECV_CATCH_STRIDE: int = 1   # Mode B handled aim+steer; caller runs transitions
const _RECV_ONE_TIME: int = 2       # Mode A transitioned to ONE_TIMER_PRESSED; caller returns

# CARRY blade aim distance (m forward in goal direction) — the cursor ring the
# carry dangle, the pre-aim targets, and the arc-step all live on. Mouse on the
# goal plane (25+ m away) was useless for stickhandling: a 0.3 m lateral blade
# shift would need a ~22 m mouse offset. 1.3 m is ~80% of the league blade
# orbit (stick + blade = 1.6 m), INSIDE the blade's reach — so the blade
# genuinely holds AT the cursor, mid-extension with slack in every direction,
# rather than stretching to full extension toward a beyond-reach point. That
# also makes the model's assumed carried-puck position
# (self + this × forward — see _puck_pos_at, the stickhandle threat point,
# the poke-evade trigger) match the physical puck for the first time: at 2 m
# those reads sat ~0.4 m beyond where the clamped blade could actually hold
# it. Body facing still tracks toward the attacking goal because the forward
# direction IS the goal direction.
#
# COUPLING: anything denominated in metres ON THIS RING is really an angle —
# aim errors are stored as radians on BotSkillProfile precisely so they don't
# move when this does; the stickhandle offset and AIM_CONVERGED_DIST_M
# were rescaled with the 2.0 → 1.3 change to keep their angles identical.
const CARRY_BLADE_AIM_FORWARD_M: float = 1.3

# Behind-the-net cradle. A full CARRY_BLADE_AIM_FORWARD_M reach worked from behind
# the attacking cage chords the blade (and the offset puck riding on it) into the
# mesh; stick-on-net contact strips the carried puck — the behind-the-net
# giveaway. Bots live back there far more than a human, so they trip it far more.
# Shorten the forward reach toward CARRY_BEHIND_NET_CRADLE_M as the body enters
# the net's work zone (within the frame's lateral span plus a margin, ramping in
# over CARRY_BEHIND_NET_BAND_M as it crosses the goal line) so the puck rides in a
# tight cradle the body walks around the post with — the "carry it close and take
# it out clean" read. This is the SOFT layer: it keeps the blade away from the
# cage in the first place. NetClampRules on the puck pin (SkaterController) is the
# HARD backstop if the reach still grazes. Feel constants (hand-tuned), not an
# evaluator. Fire-tracking (a live shot/pass look) overrides carry aim, so this
# never blunts a real net-front shot — it only tames the behind-the-net cycle.
const CARRY_BEHIND_NET_CRADLE_M: float = 0.6
const CARRY_BEHIND_NET_BAND_M: float = 0.6      # ramp band around the goal line
const CARRY_BEHIND_NET_LATERAL_M: float = 1.0   # lateral reach past the frame side still cradled

# How far inside the boards the carry mouse target is clamped
# (GameRules.clamp_to_rink_inner). The blade IK chases the mouse; a target at
# or through the kickplate slams the stick into the wall and the impact knocks
# the carried puck loose — the bots' chronic boards giveaway. One blade length
# of standoff keeps the whole blade (the mouse steers its tip region) off the
# wall while still letting a carrier work the puck tight along the boards.
# Physical measurement, not a shape parameter.
const CARRY_BLADE_WALL_MARGIN_M: float = GameRules.DEFAULT_BLADE_LENGTH_M

# Minimum rink-side margin for the carry mouse target relative to the
# attacking goal line. Without this clamp, a carrier within 2 m of
# the goal line gets a mouse target that sits PAST the goal line —
# the blade IK extends through the net, the puck attached to the
# blade gets pushed into the goalie, rebound, repeat. The buffer
# distance lives on AIRoleHelpers.GOAL_LINE_BUFFER_M (single source).

# Stickhandling: shift the carrier's mouse perpendicular to the
# attacking-goal aim, AWAY from the nearest opposing blade. Pulls
# the puck off-side from where the defender's STICK is reaching —
# distance is measured blade-tip to puck (matches the poke mechanic),
# not body to body. Magnitude ramps in over a tight band so the
# response is decisive when a poke is imminent and silent when no
# one is close: full offset inside STICKHANDLE_FULL_OFFSET_RADIUS_M,
# tapering to zero at STICKHANDLE_THREAT_RADIUS_M. Per-tick
# smoothing happens automatically via `_step_mouse_toward`.
#
# Deliberately NOT gated on closing velocity: a defender standing
# still with his stick extended is just as much a poke threat as one
# skating in, and gating on closing speed leaves bots open to easy
# lifts from a coasting defender.
#
# QUIET HANDS: the offset cap is sized so the dangle works the MIDDLE of the
# blade's arc, not its edge. Body facing chases the carry cursor at every
# angle inside the reach cone, so any sustained cursor offset becomes body
# rotation — at the 1.3 m aim ring, 0.33 m is ~±14° of body wag when a
# defender camps one side. Sizing it much wider (~±22°) turns a threat crossing
# the line into a ~44° swing: the twitchy, loud carry. A real carrier
# stickhandles in front with small excursions and
# answers real pressure with a deliberate move; those deliberate answers (the
# protect blend below, the seam deke, the brake check) now own the big
# threats, so the baseline dangle stays quiet. Ring metres — rescale with
# CARRY_BLADE_AIM_FORWARD_M to preserve the angle.
const STICKHANDLE_THREAT_RADIUS_M: float = 3.0
const STICKHANDLE_FULL_OFFSET_RADIUS_M: float = 1.5
const STICKHANDLE_OFFSET_MAX_M: float = 0.33

# Face-the-route gates (see the FACE THE ROUTE block in _carry_mouse_aim).
# ROUTE_MIN_DIST: below this the anchor is underfoot — no meaningful travel
# direction, face the play. RETREAT_ADVANCE: the route direction's advance
# component along the attack axis below which the route is a genuine retreat
# (face the play and back out); −0.3 keeps pure-lateral and shallow-back
# routes faced (they're skated at speed), and only a route pointing clearly
# back toward our own net keeps the eyes up ice. Feel/tactical posture
# choices, hand-set.
const CARRY_FACE_ROUTE_MIN_DIST_M: float = 1.0
const CARRY_FACE_RETREAT_ADVANCE: float = -0.3

# "Man to beat" contest band (see _has_man_to_beat / the O-ZONE SQUARE block in
# _carry_mouse_aim). A GOAL-SIDE opponent within this distance of the carrier is
# close enough to poke/steal — a defender the carrier still has to beat. With NO
# such man while the carrier is in the offensive zone, there is nobody to beat,
# so the body points at the goalie (square to the net, all shot/pass options
# open) rather than skating on along a lateral route into an awkward angle — the
# reported "weird sideways shot" after a deke/protect move. A hair beyond the
# stickhandle threat radius so it anticipates a closing checker. Physical
# contest measurement, tier-agnostic (it needs no protect read, so the
# naive-carry tiers get it too).
const CARRY_MAN_TO_BEAT_RADIUS_M: float = 3.5
# A defender the carrier has skated PAST — this far behind it toward our own
# end along the netward line, with both bodies projected to the evasion horizon
# (see _has_man_to_beat) — is beaten and no longer a man to beat, so the carrier
# squares up the instant it clears him even with him trailing close behind
# (rather than waiting for the full contest radius to open). ~a body length.
# Physical measurement: the tolerance on the read, not a stand-in for the closing
# rate — the projection is what supplies that.
const CARRY_MAN_TO_BEAT_BEHIND_M: float = 0.75
# Hysteresis band on the man-to-beat contest (see _has_man_to_beat). Once a man
# is being beaten the radius AND the behind-slack both widen by this, so a
# defender riding the contest boundary doesn't flip the "square to the net"
# decision — and with it the whole carry-aim forward direction — every re-eval.
# Feel/debounce tunable, not an evaluation curve.
const CARRY_MAN_TO_BEAT_HYSTERESIS_M: float = 0.75

# How far off the play line the protect aim is allowed to swing the body. The
# domain seam (best_handle_protect_point) is the MAX-CLEARANCE point in the
# handling envelope, which for a checker on the hip sits ~directly away from
# him; aiming the blade there turns the body most of the way around (facing
# chases the carry cursor — see the QUIET HANDS block), the spun-out, edge-to-
# the-play posture that also strands the carrier skating sideways/backward out
# of the play. Cap the turn at side-on: the body rotates just enough to
# interpose, and the blade's ROM (the ~157° reach cone the pose coordinator's
# IK gate allows) extends to the seam from there — protection becomes REACH,
# not a spin. Less rotation keeps the carrier square to the play and on the
# fast forward stride while still shielding the puck. Feel/posture tunable (how
# much a shield is allowed to turn you), not an evaluation curve — the seam
# itself stays the grounded reachable-set read.
const CARRY_PROTECT_MAX_TURN_DEG: float = 90.0
# Rate (1/s) the carry blade's shield blend eases toward the carrier mirror's raw
# protect_gain / protect_offset (see _carry_mouse_aim). ~125 ms time constant: a
# low-pass on the shield so a defender crossing the directional screen filter (a
# hard on/off in the raw read) ramps the blade to/from the protect seam instead
# of snapping it. Feel tunable (how fast a shield engages), not an eval curve.
const CARRY_PROTECT_SMOOTH_RATE: float = 8.0

# Poke-evade maneuver. Layered on top of the continuous defender-
# avoidance forces (carrier threat-gated repel in steering, sum-of-
# forces stickhandle on the blade). Where those handle baseline
# elusiveness, this is the discrete "deke moment" — when an opponent's
# blade reaches into immediate poke range from the front, commit to a
# maneuver for a brief window: a full-thrust CUT toward the directed
# seam (past the man, toward the carry objective), or — when the
# carrier's re-eval read the braked hold as clearly better — a BRAKE
# CHECK (stop dead, the committed checker's poke sweeps through where
# we WOULD have been, then burst to the anchor through his vacated
# lane). Either way the defender's poke, timed for our current
# trajectory, swings through empty ice.
#
# Trigger band sized just outside the stickhandle DANGER_RADIUS
# (2.1 m) so the cut fires AHEAD of the blade jitter response — we
# want the body to redirect BEFORE the blade has to do all the work.
# Front-hemisphere gate is critical: braking/cutting helps when the
# defender is closing from in front, but a defender chasing from
# behind would just close faster if we cut sideways.
const POKE_EVADE_TRIGGER_REACH_M: float = 2.5
const POKE_EVADE_MIN_CLOSING_VEL_M_S: float = 1.0
const POKE_EVADE_MIN_SELF_SPEED_M_S: float = 2.0
# Active window: long enough for a visible cut (body's lateral
# velocity reaches a few m/s), short enough that anchor attraction
# pulls us back on line without the bot losing its play. 150 ms ≈
# PHYSICS_TICK × 3/20 ticks.
const POKE_EVADE_ACTIVE_TICKS: int = _PhysicsConstants.PHYSICS_TICK * 3 / 20   # ~150 ms
# Cooldown after evade ends, blocks immediate retrigger. Persistent
# threats (defender hanging in our face) would otherwise loop us
# into a constant cut — the cooldown forces us to commit back to
# normal steering between cuts.
const POKE_EVADE_COOLDOWN_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 2   # ~500 ms
# Least distance to the carrier's evasion seam that still defines a usable
# deke direction — under that the seam is basically underfoot: the model is
# saying HOLD, not cut, so no evade triggers (the protect blade-work owns
# that moment). There is deliberately no blind-perpendicular fallback: a cut
# without a seam read isn't a play, and on the Easy tier (protect gate
# closed, so never a seam) no deke at all is the intent — the naive carry a
# newcomer's poke-check genuinely beats.
const POKE_EVADE_SEAM_MIN_DIST_M: float = 0.75
# BRAKE-CHECK variant of the evade window: hold the real brake key for the full
# evasion horizon (AIActionScoring.EVADE_HORIZON_S — the read the maneuver was
# priced over), so the committed checker's momentum genuinely carries his reach
# past the stopped puck before steering resumes toward the anchor. The exit
# (re-accelerate into the lane he vacated) needs no window of its own: a beaten
# man no longer registers in the threat-gated repel, so normal anchor
# attraction bursts straight past him the tick the brake releases.
const POKE_EVADE_BRAKE_TICKS: int = int(
		AIActionScoring.EVADE_HORIZON_S * _PhysicsConstants.PHYSICS_TICK)   # ~400 ms

# FAKE-THEN-CUT deke windows — tick mirrors of AIActionScoring.DEKE_FAKE_S /
# DEKE_CUT_S (the shared eval/execution contract: the manufactured-opening
# math prices exactly the gesture these ticks perform). The cooldown is
# longer than the plain cut's so dekes read as deliberate, occasional moves
# — and a fake the defender didn't buy can't machine-gun.
const DEKE_FAKE_TICKS: int = int(
		AIActionScoring.DEKE_FAKE_S * _PhysicsConstants.PHYSICS_TICK)
const DEKE_CUT_TICKS: int = int(
		AIActionScoring.DEKE_CUT_S * _PhysicsConstants.PHYSICS_TICK)
const DEKE_COOLDOWN_TICKS: int = _PhysicsConstants.PHYSICS_TICK   # ~1 s

# ── Defensive poke jab (active stick-check to strip the carrier) ──────────────
# The host auto-strips the carrier whenever a defender's blade SWEEPS
# THROUGH the puck (PuckController._check_interactions → check_poke).
# Off-puck pressurers position perfectly next to the carrier but their
# ready-stance aim points the blade a fixed distance in the threat
# direction — it never reaches THROUGH the puck, so they shadow without
# ever stripping. The jab fixes that: when a puck-pressurer is within
# reach of the carrier's puck, it briefly aims its blade tip AT the puck
# so the IK swings the blade through it and the host detection fires.
#
# Discrete (jab + cooldown), not continuous, so it's a real reach-in
# that commits and can miss (a carrier can deke around it) rather than a
# permanent stick-on-puck that feels sticky/cheap. Mirrors the offensive
# poke-EVADE's lifecycle.
#
# Reach is the bot's own forehand stick reach plus the poke radius —
# the distance at which a blade sweep can actually contact the puck.
# Scales with this bot's stick + blade span via apply_capabilities;
# the default below is the league baseline.
var _poke_jab_reach: float = (
		GameRules.DEFAULT_STICK_LENGTH_M
		+ GameRules.DEFAULT_BLADE_LENGTH_M
		+ GameRules.POKE_RADIUS_M)
# Jab window: long enough for the blade to sweep through the puck at
# IK aim-step speed, short enough to read as a discrete poke. ~80 ms.
const POKE_JAB_ACTIVE_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 12   # ~80 ms
# Cooldown after a jab so the bot commits back to gap control between
# attempts instead of mashing the carrier's puck every tick.
const POKE_JAB_COOLDOWN_TICKS: int = _PhysicsConstants.PHYSICS_TICK * 3 / 8   # ~375 ms

# Longest a one-timer-ready stance is held across a carrier gap (pass/shot in
# flight) before it's dropped so the FINISHER resumes normal play. A real pass
# flight is well under this; the cap only catches passes that die / deflect and
# leave the puck loose, which would otherwise pin the bot camped forever (P2-13).
const ONE_TIMER_PRESERVE_MAX_TICKS: int = _PhysicsConstants.PHYSICS_TICK * 3 / 2   # ~1.5 s

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

# Half-width (m) of the corridor in front of the carrier checked for opponents
# when deciding a breakaway sprint (see _carry_has_open_lane). An opponent
# inside this perpendicular distance of the carrier→net line counts as in the
# way. ~1 m wider than the poke-threat radius so the burst only fires with
# genuine open ice, not when a defender is one stride off the lane.
const BREAKAWAY_CORRIDOR_M: float = 3.0

# Blade-reach radius. Inside this distance the bot's stick can already
# reach the puck where it actually is, so the blade IK should aim at
# the puck's CURRENT position instead of the lead intercept — otherwise
# the blade rides 0.5 m past a puck that's right at our feet and we
# fan on it. Steering still uses the lead so the body keeps closing.
# Sized as `stick_length + blade_length + 0.2 m buffer` so the snap
# kicks in slightly before the blade actually arrives — buffer is
# feel, the geometry is real.
#
# League-default reach. Kept as a const so cross-player / default consumers can
# read it off the class (e.g. the PRESSURE role's gap geometry, which positions
# against a carrier without knowing whose reach to use). The bot's OWN reach is
# `_blade_reach` below — apply_capabilities scales it to this bot's stick + blade
# (a bigger player has a longer reach); it seeds from this default so an unwired
# bot and the unit tests behave exactly as before.
const BLADE_REACH_BUFFER_M: float = 0.2
const BLADE_REACH_M: float = (
		GameRules.DEFAULT_STICK_LENGTH_M
		+ GameRules.DEFAULT_BLADE_LENGTH_M
		+ BLADE_REACH_BUFFER_M)
var _blade_reach: float = BLADE_REACH_M

# ── Wrister charge ───────────────────────────────────────────────────────────
# SHOOT_PRESSED and the charged PASS_PRESSED variant hold shoot_held for this
# many ticks while the blade sweeps from wind_up_start to aim_target, then
# release. Power no longer rides this window — bots set release power directly
# via input.bot_wrister_power_t (the controller converts it to the equivalent
# cursor speed) — so the geometry is a cosmetic wind-up. BUT the DURATION is not
# free: it IS the real commit→release delay, and the offensive scorer feeds it
# forward as BOT_WRISTER_LOOKAHEAD_S to predict where the goalie will be when the
# shot actually leaves the blade. They shrink TOGETHER (lookahead is derived
# below), so the prediction stays synced to reality at any duration.
#
# Since the #363 pure-mouse-speed model decoupled power from the charge, a bot no
# longer needs a long wind-up to build pace — so this is a quick-twitch ~125 ms
# release (was ~250 ms). The scorer predicting a goalie that has "barely moved" is
# now correct, not a bug: at 125 ms the keeper's reaction (~0.13 s leg / 0.18 s
# arm) has barely fired, so a set, squared goalie genuinely covers a straight-on
# range shot (the bot shouldn't fire it) while lateral lag, point-blank arm-deploy
# gaps, and the goalie-hole geometry still open the shots it SHOULD take. 15 ticks
# still lets the charge tracker accumulate the forehand/backhand swing chirality.
const BOT_WRISTER_CHARGE_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 8   # ~125 ms

# Shot target power fraction (0..1): shots aim for full power (the carry scorer
# assumes WRISTER_SHOT_SPEED_M_S = DEFAULT_WRISTER_POWER_MAX_M_S, so the bot
# should produce ~max). Fed to input.bot_wrister_power_t, which the controller
# converts to the equivalent cursor speed (pure mouse-speed model). Charged
# PASSES instead derive their power fraction per-pass from the distance-adaptive
# _pass_target_speed (see _state_pass_pressed) rather than a fixed fraction.
# Flat full power: the only response to pressure is the bail-on-close-opponent
# path in _state_shoot_pressed.
const BOT_WRISTER_SHOT_CHARGE_FRACTION: float = 1.0
# Straight-line span (m) of the synthesized wind-up gesture — how far the bot's
# fake cursor sweeps from wind-up start to release. Purely COSMETIC now that
# power rides bot_wrister_power_t (not sweep distance): it sizes the visible
# blade draw. A full-power shot uses the whole span; a soft pass scales it down
# so the gesture reads as gentle. A compact quick-twitch draw matching the
# ~125 ms charge — the pace is in the release, not a big wind-up, so it needs
# little ROM.
const BOT_WRISTER_WIND_UP_SPAN_M: float = 0.4
# Mid-charge bail radius. If an opponent gets inside this distance
# while we're charging, cancel via slap_pressed (the other shot button) —
# getting blasted in the slot mid-windup is worse than not shooting. The
# carry state can re-
# evaluate next tick (probably picks PASS or stays in CARRY).
const BOT_WRISTER_BAIL_RADIUS_M: float = 2.0
# Committed speed (m/s) at charge start below which the wind-up PLANTS (brakes
# in place) instead of steering to the projected release anchor. A near-still
# bot has no release spot to skate to, so steering it anywhere just lets the
# repulsion fields wander the body — the wind-up wobble. Above this it's a rush
# wrister that should arrive at the locked anchor in stride. Mirrors the plant
# that PASS_PRESSED already does from a held spot.
const BOT_WRISTER_PLANT_SPEED_M_S: float = 1.5
# Lookahead for scoring a wrister at COMMIT time — total time from
# the carrier picking SHOOT to the puck actually leaving the blade.
# Two phases:
#   1. Pre-aim: mouse + facing converge to the locked aim point
#      before the actual charge starts. With continuous-aim
#      (_carry_aim_track_fire keeps facing pre-tracked toward the
#      best fire option during CARRY), this is typically 0-50 ms.
#      The buffer accounts for typical mouse residual convergence.
#   2. Wrister charge: BOT_WRISTER_CHARGE_TICKS / PHYSICS_TICK = ~125 ms.
#
# Used both for projecting the shooter's release-pos AND for
# predicting where the goalie / opponents will be at release.
# Including pre-aim in the projection means the scored release-
# pos matches reality even when the bot is moving — no brake-
# during-pre-aim workaround needed to keep projection honest.
const BOT_PRE_AIM_BUFFER_S: float = 0.01
const BOT_WRISTER_LOOKAHEAD_S: float = (
		float(BOT_WRISTER_CHARGE_TICKS) / _PhysicsConstants.PHYSICS_TICK + BOT_PRE_AIM_BUFFER_S)

# Wind-up geometry for the visible blade sweep. The mouse cursor lerps
# from a wind-up start position to a release target across the charge,
# with the blade IK following 1:1 (both endpoints sit inside the bot's
# ROM by construction, so no clamping happens). The straight-line
# distance between endpoints equals the target charge — that's the
# entire knob for "how much power".
#
# SIDE_OFFSET keeps the stick visually on the forehand side (the lerp
# line is offset perpendicular to aim_dir). 0.15 m is small enough to
# stay inside ROM even at the bot's max charge target, but large enough
# that the wind-up reads as a forehand pose rather than a straight
# back-to-front jab through the body's centerline. The forehand/backhand
# classifier reads the SWING CHIRALITY (the rotational sense of the blade
# sweep — ShotMechanics.is_backhand_from_swing): a bot windup that sweeps
# from this forehand-side offset in toward the aim line rotates in the
# forehand sense, so the shot scores forehand and takes no penalty. A
# flipped (backhand-side) windup sweeps the other way and reads backhand.
const BOT_WRISTER_SIDE_OFFSET_M: float = 0.15

# Side-selection for wrister wind-up — defender within poke reach
# AND clearly on the forehand side flips the wind-up to backhand.
# Models the OPPONENT defender's stick-reach for a poke check
# (stick + small overhang), resolved per defender from _caps_by_peer
# so a long-stick threat flips the wind-up at his real reach; this
# constant is the league fallback for unresolvable peers. The lateral
# threshold ensures we only flip when the defender is laterally on
# the forehand side, not directly in front (where the forehand still
# clears their stick).
const BOT_POKE_REACH_BUFFER_M: float = 0.2
const BOT_FOREHAND_STICK_REACH_M: float = (
		GameRules.DEFAULT_STICK_LENGTH_M + BOT_POKE_REACH_BUFFER_M)
const BOT_FOREHAND_LATERAL_THRESHOLD_M: float = 0.3

# ── Unified mouse motion ─────────────────────────────────────────────────────
# Every state's `input.mouse_world_pos` goes through `_step_mouse_toward`,
# which simulates a real player's mouse motion with a max speed. This
# replaces a pile of per-state smoothing (smoothed aim direction, ik_gate
# clamp, smoothed stickhandle offset, etc.) with one consistent model:
#
#   target → "where the mouse would be if you moved toward it for
#             one frame, capped at MOUSE_MAX_SPEED_M_S"
#
# Pinned for the "perfect bot" baseline:
#   MOUSE_MAX_SPEED_M_S = 100 — effectively uncapped; the mouse can
#     reach its target inside a single tick at any normal distance,
#     so the wrister lerp endpoint matches `_shoot_aim_target` at
#     release instead of trailing it. Human-feel values are in the
#     5-20 m/s range (e.g. 15 lets a 6 m anchor flip resolve in
#     0.4 s, slow enough that per-tick target oscillations average
#     out); raising this here trades organic look for accuracy.
#
# MOUSE_MAX_SPEED_M_S is now the perfect-bot DEFAULT / back-compat fallback;
# the effective per-agent cap (_mouse_max_speed_m_s) is set from
# BotSkillProfile in apply_profile().
const MOUSE_MAX_SPEED_M_S: float = 100.0
var _mouse_max_speed_m_s: float = MOUSE_MAX_SPEED_M_S
# ── Per-release execution error ──────────────────────────────────────────────
# Live-bot aim error (radians on the release direction, uniform ±), split by release type
# — SHOT releases err on their own (larger, per-difficulty) budget, passes /
# dumps on the smaller pass budget. ONE sample per release, drawn at press-
# state entry (_set_state → _sample_aim_error_rad) and held constant through
# the windup: the blade sweeps smoothly to a slightly-wrong spot — a human
# who missed his spot, not a shaking hand. The SHOT error is calibrated with
# the entry-clamp inset the aim model reserves for it, and the same spread is
# what the SCORE demands as extra window
# (RoleContext.self_aim_spread_rad → the fit inset in _hole_open_angle).
# Values come from BotSkillProfile via apply_profile so raw test-constructed
# agents stay bit-deterministic (both default 0, and a zero budget never
# advances the RNG). RNG on the hands, never decision dice.
var _shot_aim_error_rad: float = 0.0
var _pass_aim_error_rad: float = 0.0
# The error sampled for the CURRENT committed release (radians on the aim
# arm; + rotates the aim CCW around Y). Sampled on press-state entry, applied
# to the press state's aim geometry, meaningless outside a press cycle.
var _committed_aim_error_rad: float = 0.0
# Motor timing variance on the SHOT release (max seconds late, from
# BotSkillProfile.shot_timing_error_s). Each SHOOT_PRESSED entry samples a
# hold in [0, max] ticks; the release fires that much after the charge
# completes. The carrier's shot evals budget the EXPECTED lateness (max/2,
# via RoleContext.shot_timing_error_s) into the goalie's tracking time, so
# a shot is scored at its median release: windows around the hand's slop
# are still attempted and the sampled delay decides them — an early draw
# beats the push, a late one meets a square goalie. Deliberately NOT the
# worst case, which would prune every thin window and read as the bot
# swallowing the puck instead of going for the doorstep beat.
var _shot_timing_error_s: float = 0.0
var _shoot_release_hold_ticks: int = 0
# Bots run at the host physics rate (120 Hz) so we can use a fixed
# delta. Using a constant keeps the mouse motion deterministic and
# avoids threading delta through every state handler call.
const MOUSE_TICK_DELTA: float = 1.0 / _PhysicsConstants.PHYSICS_TICK

# Cap on how fast the pre-aim mouse target sweeps around self_pos at the
# CARRY_BLADE_AIM_FORWARD_M radius. The target is otherwise a fixed point
# at `self_pos + ring_radius * aim_dir`, and `_step_mouse_toward` lerps in a
# straight line toward it. A near-180° aim swing (back-pass to a receiver
# behind the bot) draws a chord through self_pos: as the mouse crosses,
# (mouse_world − skater) flips discontinuously past
# rom_backhand_angle_max_deg + upper_body_max_twist_deg (~157°), tripping
# the IK gate in SkaterPoseCoordinator.apply_facing. Facing then freezes
# and the mouse settles at 180° from the frozen facing, so the gate
# never releases — pre-aim waits on a facing alignment that can't
# arrive, and the bot stands still until INTENT_MAX_WAIT_TICKS times out
# and fires in the wrong direction.
#
# Arcing the target around self_pos at this rate keeps the mouse on a
# circle (never crossing the body) and stays in tracking range of the
# body's facing lerp.
#
# Capped at the IK-gate ceiling (7.5 rad/s): above that, steady-state body
# lag (arc_rate / facing_drag_speed_braking) exceeds the ~157° facing twist
# the pose coordinator's IK gate allows and facing freezes. At 7.5 rad/s a
# 180° back-pass resolves in π/7.5 ≈ 420 ms and body lag is ~43°, leaving
# ~110° of gate headroom.
#
# The EFFECTIVE arc rate is the lesser of this ceiling and the per-agent
# blade-slew cap projected onto the blade's real orbit radius (its stick+blade
# span — see _apply_aim_slew; the cursor ring is virtual — the physical
# constraint is the blade's own orbit, so the cap projects onto the span). Above that linear cap the arc target's
# tangential speed would exceed the mouse's max step and `_step_mouse_toward`
# would chord-cut corners instead of tracing the arc. apply_capabilities()
# derives _mouse_arc_rate_rad_s from both; the const is the default / ceiling.
const MOUSE_ARC_RATE_RAD_S: float = 7.5
var _mouse_arc_rate_rad_s: float = MOUSE_ARC_RATE_RAD_S

# ── Owned state ──────────────────────────────────────────────────────────────
var _state: State = State.OFF_PUCK
var _ticks_in_state: int = 0
# Previous tick's brake-pivot decision — the hysteresis memory for
# AISteering.should_brake (engage at BRAKE_PIVOT_ANGLE_DEG, hold until
# BRAKE_PIVOT_RELEASE_ANGLE_DEG or the speed floor). Self-corrects within a
# tick of any teleport (the speed gate releases it at a standstill), so it
# needs no faceoff reset.
var _pivot_braking: bool = false
# Arrival-brake hysteresis (AISteering.should_arrival_brake) — held across
# ticks so the brake key doesn't strobe while speed sheds on approach.
var _arrival_braking: bool = false

# Identity / orientation
var _peer_id: int = 0
var _team_id: int = 0
# +1 if own goal is at +GOAL_LINE_Z (Team 0), -1 for Team 1.
# See GameManager._assign_goals_to_teams for the source of truth.
var _own_goal_dir: float = 1.0
var _attacking_goal_pos: Vector3 = Vector3.ZERO
var _team_brain: TeamBrain = null
# The strategy surface read during this dispatch — set at the top of dispatch()
# from _strategy(). See the dispatch-site comment and docs/ai-threading-plan.md.
var _current_strategy: TeamStrategyView = null


# The team-strategy surface for the current dispatch: the brain's frozen
# per-frame view when it exists (the off-thread-safe read path), falling back to
# the live brain when no view has been built (unit tests that dispatch without
# GameManager's per-frame build_view — single-threaded, so reading the live brain
# is safe). Null when no brain is wired.
func _strategy() -> TeamStrategyView:
	if _team_brain == null:
		return null
	var v: TeamBrainView = _team_brain.get_view()
	return v if v != null else _team_brain
# Live peer -> team_id dict owned by PlayerRegistry. Read via
# `_team_id_by_peer.get(pid, -1)` in hot loops (lane filters,
# closest-teammate checks). A dict rather than a Callable — the
# Callable.call overhead shows up at the dispatch rate.
var _team_id_by_peer: Dictionary = {}
# Live peer -> AISkaterCaps dict owned by PlayerRegistry (memoized, rebuilt only
# on spawn / picker). Copied by reference onto RoleContext.caps_by_peer each build
# so roles / scorers can read any player's real build. Empty when unwired.
var _caps_by_peer: Dictionary = {}
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
# Opponent velocities index-matched to _scratch_opponents — steering's
# carrier threat-gated repel reads defender MOMENTUM, not proximity
# (AISteering._carrier_threat_repel). Filled alongside the positions.
var _scratch_opponent_steer_vels: Array[Vector3] = []
# Teammate velocities index-matched to _scratch_teammates — steering's
# teammate repel reads their SWEPT PATH (where they're skating into) so
# crossing routes bend apart before the bodies meet. Filled alongside the
# teammate positions in _apply_steering.
var _scratch_teammate_steer_vels: Array[Vector3] = []
# Shared empty fallback so the per-tick cache reads don't allocate a `[]`
# default literal (Dictionary.get evaluates its default eagerly). Never mutated.
var _empty_ids: Array = []
# Shared empty velocity list — passed to steering for off-puck bots (plain
# proximity repel) so the per-tick call doesn't allocate a literal. Never mutated.
var _empty_vels: Array[Vector3] = []
# Reused fallback buffer for _opponent_ids when the per-frame team cache is
# empty (unit tests). Production always hits the cache and never touches this.
var _scratch_opp_ids: Array[int] = []
# Reused RoleContext — refilled (not reallocated) each dispatch so its scratch
# buffers persist across calls. Dispatch is sequential per bot, so a single
# instance is safe; the role decide() consumes everything before the next build.
var _role_ctx := RoleContext.new()
# Never-written stand-in for the brainless ctx build (no per-build literal —
# a {} in the hot path would allocate every dispatch).
var _empty_threat_memo: Dictionary[int, float] = {}
# Inert transition read for the no-brain path (tests, unwired agents): Mode.NONE
# with no attackers, so every consumer behaves as it did before the read existed.
var _inert_rush_read := AIRushRead.new()

# The slot + target this bot's role chose on the previous role dispatch —
# feeds RoleContext.prev_role_target for argmax switch-hysteresis (INF is
# stamped across a slot change so no role inherits another role's target).
var _prev_role_slot: int = AIRoleSlots.Slot.NONE
var _prev_role_target: Vector3 = Vector3.INF
# Zone soft-lock incumbent from the last dispatch (RoleDecision.
# locked_man_pid) — feeds RoleContext.prev_locked_man, reset on slot change.
var _prev_locked_man_pid: int = -1
# Incumbent for the offensive stations' control hysteresis (see
# RoleDecision.held_forward_stand).
var _prev_held_forward_stand: bool = false

# Per-peer velocity history for acceleration estimation. Each bot
# maintains its own cache because dispatch runs per-bot — the
# duplicated work across the 3 bots on a team is a few subtractions
# per peer per tick (negligible). Untyped Dictionary because GDScript
# 4.6's typed-dict story is rough; keys are peer_id ints, values are
# Vector3 (last tick's velocity or smoothed accel).
var _prev_velocity_by_peer: Dictionary = {}
var _accel_by_peer: Dictionary = {}
# Local per-peer heading turn rate (rad/s), the receiver-commitment fallback
# built alongside _accel_by_peer when the shared snapshot cache is absent.
var _heading_omega_by_peer: Dictionary = {}
# The accel source consumed this tick: the host's shared per-frame cache
# (snapshot.accel_by_peer) when present, else the local _accel_by_peer built by
# _update_acceleration_cache (unit tests hand-build snapshots without the shared
# cache). Set every dispatch — accel is read in ctx build and in PASS_PRESSED aim.
var _accel_ref: Dictionary = _accel_by_peer
# Heading-turn-rate source consumed this tick, resolved in lockstep with
# _accel_ref (shared snapshot cache when present, else the local fallback).
var _omega_ref: Dictionary = _heading_omega_by_peer

# Carrier-role decision behavior. Owns _pick_action's scoring +
# hysteresis + cooldown + scratch buffers. Lives for the full
# lifetime of this state machine; `_state_carry` calls
# `_carrier.decide(ctx)` every tick (the carrier internally
# throttles re-evaluation at PICK_ACTION_PERIOD_TICKS). Mirror
# fields below (_intended_action, _pass_target_peer_id,
# _shot_loft_level, _last_carry_anchor) are populated from
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
# Per-tick sprint reference for CHASE (the puck normally; the drive-through
# point during a live 50/50 contest so arrival easing doesn't bleed the
# committed speed). Reset after each _state_chase_puck tick.
var _chase_sprint_ref: Vector3 = Vector3.INF
var _prev_carrier_peer_id: int = -1

# Set when CARRY commits to SHOOT_PRESSED; consumed by _state_shoot_pressed
# to drive the release loft (ShotMechanics.ELEVATION_*). Mirrored from
# `_carrier.shot_loft_level` — the elevation of the best goalie hole aimed at.
var _shot_loft_level: int = ShotMechanics.ELEVATION_FLAT

# Mirrored from `_carrier.shot_aim_point` — the world aim point of that same best
# hole. When finite, the wrister locks its aim here at charge start so the shot
# goes exactly where it was scored (loft + aim from one hole). INF → fall back to
# the continuous _shot_aim_point geometry.
var _shot_aim_locked: Vector3 = Vector3.INF

# Mirrored from `_carrier.shot_power_t` — the release power fraction of that same
# hole. A roof (HIGH) commit carries the arrival-honest pace (the fastest release
# whose arc still arrives in the top band at this range — a soft flip in tight, a
# full rip from range); flat commits carry 1.0. Fed to input.bot_wrister_power_t.
var _shot_power_committed: float = 1.0

# Mirrored from `_carrier.shot_release_offset` — the winning release-offset
# sample (world offset relative to the projected release; ZERO = un-relocated).
# Folded into the wind-up endpoint offsets at charge start so the blade carries
# the puck to the sampled spot, and into the locked aim direction so the shot
# fires at the hole FROM that spot. Its lateral side also owns the wind-up side
# sign (a backhand-side offset sweeps in the backhand chirality and pays the
# real power penalty the sampler priced).
var _shot_release_offset_locked: Vector3 = Vector3.ZERO

# Last-resort DUMP target, mirrored from `_carrier.dump_target` at commit and
# frozen through pre-aim + release (like the shot aim/loft above). INF → not
# dumping; a normal PASS aims at its receiver lead. The dump reuses the
# PASS_PRESSED plumbing (see _state_from_carrier_intent), so this sentinel is
# what tells that state to aim at a LOCATION and skip the receiver-close bail.
# `_dump_is_soft` picks the loft: false = HIGH chip to clear the zone into the
# neutral ice, true = soft LOW flip to the corner (dump-in). Both fire as a
# one-tick quick release at the fixed quick-shot pace — a dump is a last resort
# under pressure, so getting the puck gone fast beats a 0.5 s charged wind-up
# that gets stripped mid-swing, and the moderate fixed pace stays short of icing.
var _dump_target: Vector3 = Vector3.INF
var _dump_is_soft: bool = false
var _dump_is_rim: bool = false

# Multi-tick wrister charge bookkeeping. SHOOT_PRESSED is no longer a
# one-tick quick-shot — the bot holds shoot_held for BOT_WRISTER_CHARGE_TICKS
# while sweeping mouse_screen_pos, so SkaterStateMachine fires a real wrister at
# release (direction = sweep direction, power = the committed bot_wrister_power_t).
var _shoot_charge_tick: int = 0
# Wind-up endpoint OFFSETS (relative to self_pos) — captured ONCE at
# SHOOT_PRESSED entry (tick 0) and held for the charge. Each tick the
# lerp position is added to CURRENT self_pos to get the world target,
# so both endpoints float with the bot's locomotion. Storing as offsets
# (not world positions) is critical: the charge tracker measures blade
# delta in the skater-translation-subtracted frame, so endpoints that
# stayed fixed in world would have locomotion CANCEL the lerp velocity
# in that frame and charge accumulation would stall on rushes.
var _shoot_wind_up_start: Vector3 = Vector3.ZERO
var _shoot_aim_target: Vector3 = Vector3.ZERO
# Committed shot direction (world XZ, normalized), locked at charge tick 0. The
# controller aims the positional wrister along this directly for bots (via
# InputState.bot_wrister_aim_dir) — the fake wind-up cursor is a near-body bubble
# and would give a garbage origin→cursor. This is the same aim_dir the old
# gestural model shot (release_pos → aim_point, execution error folded in).
var _shoot_aim_dir_locked: Vector3 = Vector3.ZERO
# Wind-up side decision for SHOOT_PRESSED: +1 = forehand, -1 = backhand.
# Captured at tick 0 (based on forehand-side pressure) and locked for the
# charge so the swing doesn't flip mid-press if a defender shuffles in
# and out of stick reach. PASS_PRESSED hardcodes +1 (no backhand passes).
var _shoot_side_sign: float = 1.0
# Locked steering destination for the wind-up. Captured ONCE at charge tick 0
# (projected release position) and held for the charge so the body has a STABLE
# anchor to settle toward. Recomputing it per tick from live velocity made the
# steer target self-referential — nothing fixed to settle on, so the repulsion
# fields wandered the body (the wind-up wobble). Locked exactly like the aim
# direction / wind-up side above. _shoot_wind_up_moving records whether it was a
# rush wrister (steer to the anchor) or a near-still one (plant / brake).
var _shoot_release_anchor: Vector3 = Vector3.ZERO
var _shoot_wind_up_moving: bool = false

# Handedness perpendicular sign — +1 for right-handed (top hand on right
# shoulder, blade on left), -1 for left-handed. Set once at setup from
# is_left_handed and never changes. Used by _wind_up_endpoint_offsets to
# orient the wind-up's lateral offset onto the forehand side.
var _handedness_perp_sign: float = 1.0

# Charged-pass bookkeeping. Mirrors the wrister charge structure
# but with the sweep aimed at the receiver lead, not the goal
# shadow. Set when the carrier picks PASS with pass_should_charge=
# true; PASS_PRESSED then holds shoot_held through BOT_WRISTER_CHARGE_TICKS
# instead of releasing on tick 0. See _state_pass_pressed.
var _pass_should_charge: bool = false
# Mirrored from _carrier.pass_target_speed: the distance-adaptive LAUNCH speed
# the chosen pass should fire at. Drives both the pass lead (so the fired aim
# matches the scored one) and the wrister charge fraction the wind-up targets.
var _pass_target_speed: float = AIActionScoring.PASS_SPEED_M_S
# Mirrored from _carrier.pass_should_saucer. When true, PASS_PRESSED
# toggles elevation on for the release so the puck lofts over a
# contested mid-lane defender (saucer pass). _pass_target_speed carries
# the matching launch pace — capped so the flip lands with runway before
# the tape, i.e. a genuinely soft flip in close quarters.
var _pass_should_saucer: bool = false
var _pass_charge_tick: int = 0
# Wind-up endpoint OFFSETS (relative to self_pos) for the charged pass —
# same geometry pattern as the SHOOT_PRESSED fields, but aim_dir points at the
# receiver lead and the target charge is derived from _pass_target_speed so the
# puck releases at the distance-adaptive launch speed instead of the wrister max.
var _pass_wind_up_start: Vector3 = Vector3.ZERO
var _pass_aim_target: Vector3 = Vector3.ZERO
# Committed charged-pass direction (world XZ, normalized), locked at tick 0 — the
# controller aims the positional wrister along this directly for bots (passes are
# always forehand, so no committed backhand). See _shoot_aim_dir_locked.
var _pass_aim_dir_locked: Vector3 = Vector3.ZERO

# This bot's own attribute-scaled capabilities, set by apply_capabilities (from
# AIController.apply_attributes). Used wherever the bot reasons about ITSELF —
# chase reach, own shot/pass speed, blade reach (above), engagement cooldown.
# Defaults equal the league baseline so an unwired bot (and the unit tests)
# behave exactly as before capabilities are applied. Cross-player reasoning
# (opponent ETA/reach, the loose-puck election) stays on the shared defaults.
var _self_max_speed: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
# Sprint ceiling multiplier — the chase walk races at the
# stamina-gated sprint cap (BotSprintRules.race_speed), because the body
# sprints its chases (_resolve_sprint) and a cruise-priced walk aimed at
# intercept points the sprinting body overruns.
var _self_sprint_mult: float = AISkaterCaps.LEAGUE_SPRINT_SPEED_MULT
var _self_wrister_shot_speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
var _self_loft_tans: Vector3 = AIActionScoring.DEFAULT_LOFT_TANS
var _self_lateral_grip: float = 1.0
# Body-check delivery (mass-emergent), so a defensive role can predict THIS
# bot's hit strength before committing to a check. League baselines until
# apply_capabilities runs.
var _self_weight: float = 1.0
var _self_body_check_transfer: float = 0.45
var _self_handle_reach: float = 0.9
# This bot's blade reach cone half-angle (ROM + torso twist) and Agility-scaled
# facing turn rate, so the carrier prices only genuine body-rotation aims (the
# narrow back wedge) and at this bot's real turn speed. League baselines until
# apply_capabilities runs.
var _self_reach_cone_half_angle: float = deg_to_rad(157.0)
var _self_facing_turn_rate: float = 6.0
# Release-offset sampling inputs (see RoleContext.self_blade_speed /
# .self_backhand_power_coefficient). League baselines until apply_capabilities.
var _self_blade_speed: float = 10.0
var _self_backhand_coefficient: float = 0.75

# Sticky state for _carry_aim_track_fire's mode (shot-aim vs carry-
# aim with stickhandle). Without it, when shoot vs carry scores are
# close, the per-re-eval flip between the two aim targets snaps the
# blade ~30 Hz (every decide() throttle window, ~33 ms) — visible
# as a wobble specifically when the bot is "deciding to shoot."
# Reset on CARRY entry via _set_state.
var _carry_tracking_fire: bool = false

# Temporally smoothed puck-protect shield, low-passed toward the carrier
# mirror's raw protect_gain / protect_offset every carry-aim tick (see
# _carry_mouse_aim). The raw read steps discontinuously when a defender crosses
# the directional screen filter (PROTECT_SCREEN_BEHIND_M) or the ~30 Hz mirror
# re-evaluates — a hard on/off that swung the carry blade between the play line
# and the protect seam. Smoothing eases the shield in/out instead. Reset to zero
# on CARRY entry (via _set_state) so a fresh pickup doesn't inherit a phantom
# shield from a previous carry.
var _carry_protect_gain_smooth: float = 0.0
var _carry_protect_offset_smooth: Vector3 = Vector3.ZERO
# Latched side of the man-to-beat contest (see _has_man_to_beat), debounced by
# CARRY_MAN_TO_BEAT_HYSTERESIS_M so a defender riding the boundary doesn't chatter
# the square-to-net facing. Reset on CARRY entry for a fresh contest read.
var _carry_has_man: bool = false

# Poke-evade lateral cut bookkeeping. While _active > 0, the
# modulator overrides move_vector with a perpendicular thrust away
# from the threat side; when it counts down to 0 the cooldown
# kicks in and blocks retrigger. Both reset on CARRY entry.
var _poke_evade_active_ticks: int = 0
var _poke_evade_cooldown_ticks: int = 0
# Deke direction LATCHED at trigger (a cut commits — re-reading it per tick
# would spiral the direction as our own velocity rotates mid-cut). Points at
# the carrier's directed evasion seam (a real cut past the pressure, cutback
# included). Non-zero whenever a CUT window is active — a directionless evade
# never triggers (see the trigger gate); ZERO otherwise, or during a BRAKE
# window (which steers by _last_carry_anchor instead).
var _poke_evade_dir: Vector2 = Vector2.ZERO
# Maneuver LATCHED at trigger: TRUE = this evade is a BRAKE CHECK (hold the
# real brake key; the committed checker's reach flies past the stopped puck),
# FALSE = the lateral cut. Chosen from the carrier's brake_check_favored mirror
# (AIActionScoring.prefers_brake_check at the last ~30 Hz re-eval).
var _poke_evade_braking: bool = false
# Maneuver LATCHED at trigger: the FAKE-THEN-CUT deke. Phase splits on the
# remaining active ticks (fake while > DEKE_CUT_TICKS, then the cut); both
# directions latched from the carrier's manufactured-opening read at trigger
# (a deke re-read mid-gesture would un-sell the fake).
var _poke_evade_deking: bool = false
var _deke_fake_dir: Vector2 = Vector2.ZERO
var _deke_cut_dir: Vector2 = Vector2.ZERO

# Defensive poke-jab bookkeeping (see POKE_JAB_* constants). While
# _active > 0 the bot aims its blade at the carrier's puck so the host
# strip detection fires; the cooldown then blocks retrigger so the jab
# is a discrete reach-in, not a permanent stick-on-puck.
var _poke_jab_active_ticks: int = 0
var _poke_jab_cooldown_ticks: int = 0

# One-timer readiness mirrored from the most recent OFF_PUCK role
# decision. Also published to TeamBrain (so the carrier reads it
# when scoring passes). Drives the fire-on-zone-entry transition in
# OFF_PUCK / CHASE_PUCK.
var _is_one_timer_ready: bool = false
# Physics ticks the ready flag has been PRESERVED across a carrier gap (pass/shot
# in flight). Bounded by ONE_TIMER_PRESERVE_MAX_TICKS so a pass that dies or
# deflects doesn't leave the FINISHER camped-and-ready forever, refusing to chase
# the now-loose puck. Reset whenever the flag is genuinely (re-)confirmed ready.
var _one_timer_preserve_ticks: int = 0

# Arrival tolerance for the one-timer's live-line settle anchor
# (_one_timer_line_anchor): inside this we stop seeking and brake/hold so the
# feed arrives into the armed slapper zone.
const ONE_TIMER_ANCHOR_ARRIVE_M: float = 0.6

# "Give with the puck" ceiling on an incoming feed's RECEIVER-FRAME speed:
# the catch gate (PuckReceptionRules) judges the puck's pace relative to the
# receiver — the any-angle deflect threshold is Puck.deflect_min_speed
# (22 m/s relative) — so a receiver skating INTO a feed stacks its own
# closing on top and knocks down a tape pass. Above this the chase brakes to
# shed its own closing (the skating half of soft hands) and never sprints at
# the feed. Sits BETWEEN the magnet solve and the deflect threshold: bot
# passes are launched to arrive at exactly PASS_TARGET_CLOSING (20) in the
# receiver's frame, so a ceiling at-or-under 20 would brake the receiver on
# every clean feed — only genuinely hot arrivals trip the give (a charging
# receiver, a rebound, an un-solved human feed).
const RECEIVE_GIVE_CEILING_M_S: float = 21.5
# Opponent-position scratch for the shot-quality check in _try_shot_reception.
# Separate from _scratch_opponents (owned by _apply_steering) so the reception
# eval doesn't clobber steering's list mid-tick. Caps index-matched (null for
# unwired peers) so the gate prices each lane defender's real reach.
var _scratch_shot_opponents: Array[Vector3] = []
var _scratch_shot_opponent_caps: Array[AISkaterCaps] = []

# Tick counter for ONE_TIMER_PRESSED — the bot holds slap_held (the REAL
# slapper one-timer charge) until the puck reaches the slapper zone / attaches
# (the controller's window), then drops it to release. The dead-feed bail
# (live line gone) usually exits long before the budget backstop below.
var _one_timer_press_tick: int = 0

# Whether ONE_TIMER_PRESSED has fired its slap press yet. The controller
# LOCKS the slapper direction from the mouse at the press tick
# (_enter_slapper_charge). Pressing while the cursor is still parked on the
# previous state's target would lock a watching-the-play aim and fire the
# one-timer wherever the bot had been LOOKING, so the press waits for the aim
# to settle into the reach cone first (see the press gate in
# _state_one_timer_pressed).
var _one_timer_slap_down: bool = false

# Backstop on that aim-settle wait: facing_drag covers the worst beyond-cone
# overshoot (~30°) well inside this, so hitting it means unreadable facing
# geometry — press anyway rather than eat the whole feed flight un-wound.
const ONE_TIMER_AIM_WAIT_MAX_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 5   # ~0.2 s

# How square to the shot line the stance must ALREADY be for the wind-up to
# start. The blade-reach cone (_aim_needs_no_rotation, ~132°) is the right gate
# for a CARRIED shot — the blade swings to the aim while the body holds its
# heading — but a one-timer has no carry: SkaterController._enter_slapper_charge
# SNAPS facing to the aim at the press tick, so committing from a wide stance
# whips the body a third of a turn in a single tick. A real one-timer is a stance
# you're already in — you open up to the seam BEFORE the feed arrives, not on the
# swing. A wide stance isn't rejected outright: the bot holds in ONE_TIMER_PRESSED
# with the cursor on the net, facing rotates toward it at facing_drag, and the
# press fires the moment it lands inside this angle; only a stance that can't
# square within ONE_TIMER_AIM_WAIT_MAX_TICKS bails to a catch. FEEL, so hand-set
# — widen if bots pass up one-timers they could have opened up for, tighten if the
# wind-up still reads as a body-whip.
const ONE_TIMER_SQUARE_UP_MAX_RAD: float = deg_to_rad(45.0)

# Cap on the feed-arrival lookahead the one-timer aim reads the goalie at —
# past this the feed is a long cross-ice saucer and the prediction is noise.
const ONE_TIMER_FEED_LOOKAHEAD_MAX_S: float = 1.2

# Budget backstop for ONE_TIMER_PRESSED, sized to outlast the longest scored
# feed: entry happens at feed RELEASE now (the flight time is what builds the
# visible wind-up), so the wait must cover a full pass flight (~PASS_LEAD_MAX_S
# of lead solving, ~1 s of real flight on a long diagonal) plus settle slack.
# The dead-feed bail handles every genuine failure earlier; this only catches
# pathological stasis.
const ONE_TIMER_PRESS_MAX_TICKS: int = _PhysicsConstants.PHYSICS_TICK * 6 / 5   # ~1.2 s

# The slapper one-timer pickup ZONE's offset in the skater's local frame
# (local +X = blade side, negative local Z = in front) — mirrors of
# SkaterController.slapper_zone_offset_x / slapper_zone_offset_z defaults, the
# same way the BOT_WRISTER_* constants mirror the wind-up gesture geometry.
# The wind-up blade is raised, so the ZONE (not the blade) makes the catch:
# the one-timer settle must place THIS point on the feed's live line.
const BOT_ONE_TIMER_ZONE_OFFSET_X_M: float = 1.0
const BOT_ONE_TIMER_ZONE_OFFSET_Z_M: float = -0.4

# Release radius (m) around the slapper zone centre for the wound-up one-timer's
# "on the centre beat" release. Kept INSIDE the controller's slapper pickup
# radius (slapper_zone_radius, 0.5) so a clean feed attaches first and fires the
# with-puck release (earning the centred bonus); this radius only catches a puck
# that slips through the zone without attaching. See _puck_at_slapper_zone.
const ONE_TIMER_RELEASE_RADIUS_M: float = 0.4


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

# Per-bot RNG for hands-side execution sampling (per-release aim/timing
# errors). Seeded once in setup() from peer_id and the
# host tick at spawn so each bot has its own deterministic but distinct
# stream (replay-safe).
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Decision-rate throttle. The full state-handler dispatch (role
# decisions, action scoring, steering compute, aim target selection)
# runs every DISPATCH_PERIOD_TICKS physics ticks during non-press
# states; skipped ticks reuse the cached move_vector and step the
# mouse toward the cached aim target so blade motion stays at the physics rate.
# Press states (SHOOT_PRESSED / PASS_PRESSED) always run full-rate —
# wrister charge timing and pre-aim convergence are tick-sensitive.
# State transitions reset the counter so the next dispatch runs full.
# DISPATCH_PERIOD_TICKS is the perfect-bot default / back-compat fallback;
# the effective per-agent cadence (_dispatch_period_ticks) is set from
# BotSkillProfile in apply_profile().
const DISPATCH_PERIOD_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 60   # ~60 Hz
var _dispatch_period_ticks: int = DISPATCH_PERIOD_TICKS

# The match's latched rule set (GameRules.RuleSet), stamped by AIController
# from the game state each tick. Drives RoleContext.offsides_enforced — the
# counter-channel blue-line clamp on offside-positioned opponents. Defaults
# to the game's default (ARCADE: offsides on) so unwired contexts (tests)
# model the standard game.
var rule_set: int = GameRules.DEFAULT_RULE_SET
var _dispatch_skip_counter: int = 0

# ── Loose-puck reactivity clock ──────────────────────────────────────────────
# The chase gate reads the REAL carrier (snapshot.real_puck_carrier_peer_id),
# not the reaction-delayed one on puck_state, and applies its own delay here.
#
# Why not just use the delayed carrier: that signal is a single GLOBAL settle
# timer owned by GameManager whose job is team-shape belief ("are we still on
# offense?"). Borrowing it as the chase gate conflated two different questions
# and made puck reactivity hostage to a possession belief that is deliberately
# slow — during its window no bot chased at all, and because it restarts on
# every carrier change, a scramble (repeated stick grazes) could defer the
# chase indefinitely. That is the "bot skates away from a live puck" read.
#
# So: team SHAPE keeps the slow, sticky, zone-aware possession belief; puck
# REACTIVITY gets this clock, which measures how long the puck has genuinely
# been nobody's. A momentary graze does not reset it — the puck has to be
# actually CONTROLLED (held CONTROL_CONFIRM_S continuously) to count as
# possessed again. So the delay stays a real difficulty lever without the
# unbounded stall.
const CONTROL_CONFIRM_S: float = 0.08   # continuous carry before a touch counts as control
var _chase_reaction_delay_s: float = 0.0
var _loose_elapsed_s: float = 0.0       # how long the puck has been genuinely loose
var _control_elapsed_s: float = 0.0     # how long the current carrier has held it
var _cached_move_vector: Vector2 = Vector2.ZERO

# Off-puck role-decision throttle. The role behaviors' positioning argmax
# (finisher/support/contain/mark/pressure/... each score ~10-18 candidates via
# score_pass/threat_surface) is the dominant AI cost — 4-5 bots run it every
# full dispatch. It's a slow-moving positional read, so re-evaluate it on the
# same ~30 Hz cadence the CARRIER already uses (AIRoleCarrier.PICK_ACTION_
# PERIOD_TICKS) and reuse the cached RoleDecision between re-evals; steering,
# aim, and all state transitions still run every full dispatch toward the cached
# target, so only the expensive scoring is throttled. Drained by the dispatch
# span so the wall-clock cadence holds across difficulty tiers, exactly like the
# carrier. Timing-critical reads bypass the throttle (see _state_off_puck): the
# FINISHER (one-timer trigger), a live one-timer-ready / body-check commit, a
# location ping, and a slot change all force an immediate re-eval.
const ROLE_DECISION_PERIOD_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 30  # ~30 Hz
# Far-from-play LOD radius (see the throttle site): beyond this distance from
# the puck the argmax runs at half rate. Physical grounding: at the ~33 m/s max
# shot speed the play needs ≥ 0.55 s to arrive from 18 m out, an order of
# magnitude above the ≤ 50 ms of latency the halved cadence adds.
const FAR_PLAY_LOD_RADIUS_M: float = 18.0
# Finisher full-rate ring (see the must_recompute doc): a loose/in-flight puck
# inside this radius can reach the blade within ~0.36 s at the max shot speed —
# only then are the one-timer trigger and crash read tick-critical.
const FINISHER_FLIGHT_NEAR_M: float = 12.0
var _role_decision_cooldown: int = 0
# The dispatch span armed by the most recent full dispatch (see the far-play
# dispatch LOD at the throttle site): the real tick gap between full
# dispatches, which the role-argmax cooldown drains by so its wall-clock
# cadences hold under the halved far shell instead of silently stretching.
# One arming stale at the far↔near boundary (±2 ticks, once) — the cadences
# here tolerate that.
var _dispatch_armed_span_ticks: int = DISPATCH_PERIOD_TICKS
# Full-dispatch counter (throttle-skipped ticks excluded). Read by the AI
# benchmarks to verify dispatch-thinning LODs actually thin; no gameplay
# consumer. One int increment per full dispatch.
var full_dispatch_count: int = 0


# True for slots whose positioning read tracks something that moves at play
# speed — the carrier (pressure/contain), an assigned or soft-locked man, a
# race, or a live one-timer camp. These keep the full ~30 Hz argmax cadence;
# everything else is a shape-holding post (points, lanes, valves, flanks,
# breathing zone anchors) that re-evals at ~20 Hz (see the throttle above).
func _is_reactive_slot(slot: int, snapshot: WorldSnapshot) -> bool:
	match slot:
		AIRoleSlots.Slot.PRESSURE, AIRoleSlots.Slot.F1_PRESSURE, \
		AIRoleSlots.Slot.MARK, \
		AIRoleSlots.Slot.CHASE, \
		AIRoleSlots.Slot.RUSH_D1, AIRoleSlots.Slot.RUSH_D2, \
		AIRoleSlots.Slot.TRACK_PUCK, AIRoleSlots.Slot.TRACK_MID_STRONG, \
		AIRoleSlots.Slot.TRACK_MID_WEAK, AIRoleSlots.Slot.TRACK_MID:
			return true
		AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK, \
		AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG, \
		AIRoleSlots.Slot.ZONE_W_WEAK:
			# The zone defender who OWNS pressure this tick runs the full
			# AIRolePressure cut-off argmax against a live carrier — the same job
			# PRESSURE does, so it wants the same cadence. Ownership MOVES with
			# the puck (AIZoneCoverage.pressure_owner), so it cannot be a fixed
			# slot: ZONE_D_STRONG was hardcoded here, which left a carrier in the
			# slot (ZONE_C) or the net-front box (ZONE_D_WEAK) pressured on the
			# shape-holding cadence instead. That path sets no locked_man_pid
			# either, so the soft-lock fallthrough below never caught it.
			if snapshot != null and snapshot.puck_state != null:
				var strong_x: float = _current_strategy.strong_x() \
						if _current_strategy != null else 1.0
				if AIZoneCoverage.pressure_owner(strong_x,
						_own_goal_dir * GameRules.GOAL_LINE_Z,
						snapshot.puck_state.position) == slot:
					return true
		AIRoleSlots.Slot.FINISHER, AIRoleSlots.Slot.NET_FRONT:
			# The one-timer camp's fast cadence buys a live seam read — which
			# only exists while the puck is IN the attacking zone. Elsewhere
			# (a regroup, a loose-puck scramble in the NZ) the finisher is
			# just staging a formation post, and its ten feed×shot candidate
			# evals were the single most expensive shape-hold in the 5v5
			# bill. The one-timer trigger itself always bypasses the throttle
			# (must_recompute), so arming stays tick-accurate regardless.
			if snapshot != null and snapshot.puck_state != null:
				return AIActionScoring.in_offensive_zone(
						snapshot.puck_state.position,
						Vector3(0.0, 0.0, -_own_goal_dir * GameRules.GOAL_LINE_Z))
			return true
	# A zone defender with a live soft-lock is covering a mover — reactive
	# while the lock holds, a breathing post once it releases.
	return _cached_role_decision != null \
			and _cached_role_decision.locked_man_pid != -1


# Seed the dispatch / role-argmax counters with a per-bot phase (see the
# setup() pacing comment). Multiplying by a prime before the modulo spreads
# consecutive bot ids (10000, 10001, …) across the role period instead of
# marching them through it in lockstep pairs. Gated to real bot peers: unit
# tests and the duel scenarios drive agents with small synthetic ids and pin
# tick-exact behavior off an immediate first dispatch — they keep phase 0.
func _stagger_cadence_phases() -> void:
	if _peer_id < NetworkManager.BOT_ID_BASE:
		return
	_dispatch_skip_counter = _peer_id % maxi(1, _dispatch_period_ticks)
	_role_decision_cooldown = (_peer_id * 3) % ROLE_DECISION_PERIOD_TICKS
var _cached_role_decision: RoleDecision = null
# True when the cached decision was built on a tick with a live location ping —
# the ping override mutates the cached decision's target_position in place, so
# the first tick after the ping expires must recompute a clean decision rather
# than reuse the stale ping target.
var _role_decision_pinged: bool = false

# Difficulty PACE knobs (from BotSkillProfile via apply_profile). Copied onto the
# RoleContext each tick so the role behaviors read them. No-op baselines (0.0 /
# 1.0) keep the perfect-bot default when no profile is applied.
var _pursuit_standoff_m: float = 0.0
var _pass_speed_scale: float = 1.0
var _check_aggression: float = 1.0
var _defensive_anticipation_scale: float = 1.0
# Post-possession settle beat (seconds) forwarded to the carrier via
# RoleContext.carry_settle_delay_s. 0.0 = fire the tick the compete says so.
var _carry_settle_delay_s: float = 0.0
# Difficulty COGNITION gates (from BotSkillProfile via apply_profile). True =
# the perfect-bot default. _reads_goalie_motion gates the across-the-grain
# velocity projection in _shot_aim_point (and rides RoleContext into the
# carrier's unsettled read); _holds_for_developing_feeds rides RoleContext into
# the carrier's hold; _angles_the_chase gates the inside-lane intercept shift
# in the chase state.
var _reads_goalie_motion: bool = true
var _holds_for_developing_feeds: bool = true
# _reads_receiver_commitment rides RoleContext into the carrier's pass EV — a
# turning receiver is priced as a riskier feed. False = blind, chucks passes at
# turning players.
var _reads_receiver_commitment: bool = true
var _angles_the_chase: bool = true
# _plays_rush_pass_lanes rides RoleContext into RUSH_D1's odd-man lane fan.
var _plays_rush_pass_lanes: bool = true
# _protects_the_puck gates the carrier's blade-level puck shielding (the carry
# mouse blends toward the carrier's protect seam under pressure) and the
# seam-directed poke-evade deke. False = naive forward carry — the puck stays
# presented ahead of the body, so a straight poke-check works (the beginner tier).
var _protects_the_puck: bool = true
# Sprint is decided alongside move_vector on full-dispatch ticks; skipped
# throttle ticks reuse this cached value so sprint_held doesn't flicker off at
# 60 Hz (which would halve the burst and strobe the facing turn-rate penalty).
# Also serves as the `was_sprinting` hysteresis input to BotSprintRules.
var _cached_sprint_held: bool = false
# The FINISHER raises the blade (stick_lift_held) to tip an elevated incoming
# shot, but that flag is only set on dispatch ticks. Cache + replay it on skipped
# ticks or blade_up strobes at 1-in-dispatch_period and never reaches the raised
# pose at Normal/Easy (the lift blend never leaves ~0).
var _cached_stick_lift_held: bool = false
# Updated inside `_step_mouse_toward` so skipped ticks can re-step
# toward the most recently decided target without re-running the
# state handler. ZERO sentinel suppresses stepping until the first
# full dispatch sets a real target.
var _cached_aim_target: Vector3 = Vector3.ZERO
var _has_cached_aim_target: bool = false
# The cursor-shaping mode that produced the cached target (_STEP_DIRECT / _ARC /
# _FACE), read by the skipped-tick re-step so it re-shapes the same way every
# physics frame — the arc keeps walking the body ring, the face clamp keeps
# re-evaluating against the current facing — instead of only on full-dispatch ticks.
var _cached_aim_mode: int = _STEP_DIRECT
# The linear + angular cursor rates that produced the cached target, so the
# skipped-tick re-step reuses them (a body-facing aim and a blade aim slew the
# cursor at different rates — see _step_mouse_face vs _step_mouse_aim).
var _cached_aim_max_speed: float = MOUSE_MAX_SPEED_M_S
var _cached_aim_arc_rate: float = MOUSE_ARC_RATE_RAD_S

# Off-puck ready-stance aim, re-derived live on the throttle's skipped ticks
# (the OFF_PUCK analogue of _chase_reception_aim_target — see the dispatch
# skipped-tick block). The DECISION stays throttled, but the ready-stance blade
# target is a pure function of current perception (self_pos + threat/anchor
# direction), so refreshing it every physics tick keeps the blade tracking the
# moving puck smoothly instead of staircasing at the ~13-20 Hz dispatch rate.
# `_off_puck_aim_live` gates it on: true only when the dispatch tick resolved to
# the plain ready-stance branch (NOT a poke-jab, one-timer pre-aim, or explicit
# aim override — those keep the throttled cached-target path so their lifecycles
# aren't accelerated). Anchor + near threshold are captured so the skipped-tick
# recompute matches the dispatch tick's _ready_stance_aim call exactly.
var _off_puck_aim_live: bool = false
var _off_puck_aim_anchor: Vector3 = Vector3.ZERO
var _off_puck_aim_near_m: float = 0.0
# Set when the dispatch tick resolved to an ACTIVE poke-jab (aiming through an
# opposing carrier's puck). On skipped ticks the aim then re-tracks the moving
# puck live so the stab sweeps smoothly onto it — check_poke is a swept blade-vs-
# puck segment test, so a staircased stab can skip a contact a live one catches.
# The jab's active/cooldown counters still advance on the dispatch cadence only.
var _off_puck_jab_live: bool = false
# Latched side of the far/near aim flip (see _compute_desired_aim_dir). True =
# NEAR (aiming the threat/puck), false = FAR (aiming the anchor). Debounced by
# FACE_NEAR_ANCHOR_HYSTERESIS_M so boundary-camping doesn't chatter the blade.
var _aim_near_anchor: bool = false
# Latched puck-too-close state for _face_threat_or_current, debounced by
# FACE_THREAT_MIN_DIST_HYSTERESIS_M. True = hold facing (puck within the geometry
# floor), false = aim at the puck.
var _threat_too_close: bool = false

# Captured at the top of each dispatch() so _step_mouse_toward can
# arc the per-tick mouse target around self_pos without re-threading
# self_pos / self_state through every call site. The arc keeps the
# mouse on a 2 m ring so straight-line chords across self_pos never
# trip the pose coordinator's IK gate (which permanently locks
# facing once the mouse-body angle exceeds ~157°). null until the
# first dispatch; arc-step falls back to no-op then.
var _current_self_pos: Vector3 = Vector3.ZERO
var _current_self_state: SkaterNetworkState = null
var _current_snapshot: WorldSnapshot = null
# The real frame delta captured at the top of each dispatch (including skipped
# ticks), so per-tick temporal smoothing (the carry protect blend) advances at
# the physics/read rate and stays frame-rate independent under host time dilation.
var _current_delta: float = 0.0

# Last action the bot actually fired (e.g. "SHOOT" /
# "PASS→Backdoor"). Set inside the press-state handlers at the
# moment the press is dispatched, not when intent is picked — so
# the label reflects what the bot did rather than what it
# considered. Persists until the next press fires.
var debug_last_decision: String = ""

# Gate for the COSTLY debug-readout strings. The readouts exist only to feed
# AIController's floating per-bot label, but they are built on the AI worker at
# dispatch rate (120 Hz × bots). The PASS/DUMP ones cost a strategy lookup plus
# `%` formatting per release — real hot-path work for a label that ships off, so
# they are gated. The bare-literal assignments (SHOOT / ONE_TIMER) are free and
# stay ungated; nothing reads debug_last_decision while the label is off.
# AIController.SHOW_DEBUG_LABEL derives from this so the flag lives in ONE place —
# flip it here to turn the labels back on.
const DEBUG_DECISIONS: bool = false


# Per-tick decision-scoring readout for the floating debug label.
# Populated by `_pick_action` every tick; AIController polls and
# refreshes the label only when content changes (so it doesn't
# flicker every frame). Slot label and carry direction are computed
# from the chosen peer / position at the same time.
var debug_shoot_score: float = 0.0
var debug_pass_score: float = 0.0
var debug_pass_peer_id: int = 0
var debug_carry_score: float = 0.0
var debug_carry_pos: Vector3 = Vector3.ZERO


# ── Setup ────────────────────────────────────────────────────────────────────

# Apply this bot's attribute-scaled self-capabilities. Called by
# AIController.apply_attributes (via SkaterAgent) on spawn and on every
# free-play picker change, so the AI's model of its own reach / speed / shot
# tracks the same scaled values the controller drives the body with. Null is a
# no-op (keeps the league-baseline defaults). Derives the three reach gates from
# the single blade span, the same way the baseline constants are built off the
# default stick + blade lengths.
func apply_capabilities(caps: AISkaterCaps) -> void:
	if caps == null:
		return
	_self_max_speed = caps.max_speed
	_self_sprint_mult = caps.sprint_speed_mult
	_chase_max_accel = caps.max_accel
	_blade_reach = caps.blade_span + BLADE_REACH_BUFFER_M
	_receive_body_offset = caps.blade_span - RECEIVE_BODY_INSET_M
	_poke_jab_reach = caps.blade_span + GameRules.POKE_RADIUS_M
	_self_wrister_shot_speed = caps.wrister_shot_speed
	_self_loft_tans = caps.loft_tans
	_self_lateral_grip = caps.lateral_grip
	_self_weight = caps.weight
	_self_body_check_transfer = caps.body_check_transfer
	_self_handle_reach = caps.handle_reach
	_self_reach_cone_half_angle = caps.reach_cone_half_angle
	_self_facing_turn_rate = caps.facing_turn_rate
	_self_blade_speed = caps.blade_speed
	_self_backhand_coefficient = caps.backhand_power_coefficient
	# Aim at the bot's REAL blade speed: the synthesized aim cursor slews
	# at the same rate the blade is physically clamped to, so aiming looks exactly
	# as fast as its hands are — no artificial per-difficulty slew. Difficulty comes
	# from reaction delay / decision cadence / the bot's own build, not a
	# hands-override. (The cursor tracking the blade keeps pre-aim convergence
	# honest — "aimed" means the blade is actually there.) The arc rate projects
	# that linear cap onto the BLADE's real orbit radius (its stick+blade span) —
	# the cursor ring is virtual; the blade's own orbit is the physical
	# constraint the swing cap has to respect.
	_apply_aim_slew(caps.blade_speed, caps.blade_span)


# This bot's target power fraction (0..1) for a charged pass at _pass_target_speed,
# over its own wrister band [DEFAULT_WRISTER_POWER_MIN_M_S, _self_wrister_shot_speed].
# Fed to input.bot_wrister_power_t; the controller converts it to the equivalent
# cursor speed (pure mouse-speed model). min power is the league baseline: the
# controller holds min_wrister at base for every build (soft-touch floor is
# universal).
func _pass_power_t() -> float:
	return clampf(
			(_pass_target_speed - GameRules.DEFAULT_WRISTER_POWER_MIN_M_S)
			/ maxf(_self_wrister_shot_speed - GameRules.DEFAULT_WRISTER_POWER_MIN_M_S, 0.001),
			0.0, 1.0)


func setup(peer_id: int, team_id: int, brain: TeamBrain, team_id_by_peer: Dictionary,
		is_left_handed: bool, caps_by_peer: Dictionary = {}) -> void:
	if brain == null:
		push_error("SkaterAgentStateMachine.setup: null TeamBrain for peer_id=%d team_id=%d — bot was spawned before GameManager.team_brains was populated. Bot will run without role assignments." % [peer_id, team_id])
	_peer_id = peer_id
	_team_id = team_id
	_own_goal_dir = 1.0 if team_id == 0 else -1.0
	# Aim point at the opposing goal mouth. Used as fallback aim and as
	# the net plane for shot-aim geometry. y=0 — blade IK is 2D for now.
	_attacking_goal_pos = Vector3(0.0, 0.0, -_own_goal_dir * GameRules.GOAL_LINE_Z)
	_team_brain = brain
	_team_id_by_peer = team_id_by_peer
	_caps_by_peer = caps_by_peer
	_is_left_handed = is_left_handed
	# Frame pacing: stagger this bot's dispatch and role-argmax phases by
	# peer id, so a full roster doesn't run every expensive re-eval on the
	# SAME physics tick. Host FPS is set by the worst tick, not the average
	# — with all counters starting equal, ten bots synchronized their full
	# dispatches (and 30 Hz argmaxes) into periodic spike ticks that alone
	# approached the 8.3 ms budget. Deterministic per bot (peer id), so
	# behavior is a fixed sub-tick phase offset, nothing else.
	_stagger_cadence_phases()
	# Perpendicular sign derived from handedness — used by _wind_up_endpoint_offsets
	# to put the wind-up on the bot's forehand side. Must match the codebase's
	# forehand convention: the release classifier (skater_controller.gd) treats
	# RH forehand as skater-local +X, and _try_shot_reception (this file, ~:1581)
	# defines RH forehand = -left_dir. With that convention the wind-up perp for a
	# right-hander is Vector3(-aim.z, 0, aim.x), i.e. _handedness_perp_sign = -1;
	# left-handers mirror to +1. Invert this and every bot charges its wrister/pass
	# on the backhand side and silently pays the backhand power penalty.
	# Set at setup, never changes.
	_handedness_perp_sign = 1.0 if _is_left_handed else -1.0
	# Seed the per-bot RNG. peer_id × prime spreads the bot id range
	# (10000+) across the seed space; XOR with NetworkManager.host_tick
	# at spawn salts the seed per-session, still deterministic for
	# replay within a session.
	_rng.seed = (peer_id * 1000003) ^ NetworkManager.host_tick


# Apply a difficulty skill profile (set from BotSkillProfile). Called once at
# spawn via SkaterAgent.apply_profile, before the first dispatch. Derives the
# two coupled values (arc rate, pre-aim timeout) from the blade-slew cap so
# changing only mouse_max_speed_m_s in the profile keeps the back-pass arc and
# convergence-bail invariants intact. Null is a no-op (keeps perfect defaults).
func apply_profile(profile: BotSkillProfile) -> void:
	if profile == null:
		return
	# Aim slew is NOT a difficulty knob anymore — it's the bot's real Hands blade
	# speed, set in apply_capabilities. Difficulty here is reaction/cadence/pace.
	_dispatch_period_ticks = maxi(1, profile.dispatch_period_ticks)
	_dispatch_armed_span_ticks = _dispatch_period_ticks
	# Cadence changed — re-derive this bot's pacing phase for the new period.
	_stagger_cadence_phases()
	_pursuit_standoff_m = profile.pursuit_standoff_m
	_pass_speed_scale = profile.pass_speed_scale
	_check_aggression = profile.check_aggression
	_defensive_anticipation_scale = profile.defensive_anticipation_scale
	_carry_settle_delay_s = profile.carry_settle_delay_s
	# Same lever the global carrier debounce uses, applied HERE for the chase
	# gate so puck reactivity has its own bounded clock (see _loose_elapsed_s).
	_chase_reaction_delay_s = maxf(profile.carrier_reaction_delay_s, 0.0)
	_reads_goalie_motion = profile.reads_goalie_motion
	_holds_for_developing_feeds = profile.holds_for_developing_feeds
	_reads_receiver_commitment = profile.reads_receiver_commitment
	_angles_the_chase = profile.angles_the_chase
	_plays_rush_pass_lanes = profile.plays_rush_pass_lanes
	_protects_the_puck = profile.protects_the_puck
	# Execution error for LIVE bots (raw test agents stay deterministic):
	# per-tier, split shot-vs-pass — the shot error is the tier's scoring
	# dial, the pass error stays small so passes keep connecting. Timing
	# error is the other hands-side humaniser.
	_shot_aim_error_rad = profile.shot_aim_error_rad
	_pass_aim_error_rad = profile.pass_aim_error_rad
	_shot_timing_error_s = profile.shot_timing_error_s


# Set the aim-cursor slew (and the arc rate + pre-aim timeout derived from it) to
# `slew` m/s — the bot's real Hands blade speed, so the cursor tracks the blade.
# `orbit_radius_m` is the blade's real orbit radius (stick + blade span): the
# angular swing the linear Hands cap physically allows is slew / THAT radius,
# not slew / the virtual cursor ring (the old 2 m ring projection
# under-rotated every carrier ~25-50% below what its hands could actually do,
# which read as "bots turn around too slowly with the puck"). Defaults to the
# ring radius; every live caller passes the real span.
func _apply_aim_slew(slew: float,
		orbit_radius_m: float = CARRY_BLADE_AIM_FORWARD_M) -> void:
	_mouse_max_speed_m_s = slew
	# Arc rate: lesser of the IK-gate ceiling and the linear slew cap projected
	# onto the blade's orbit radius — above either, the arc-step chord-cuts the
	# back-pass swing or the body-facing lag trips the pose IK gate.
	_mouse_arc_rate_rad_s = minf(MOUSE_ARC_RATE_RAD_S,
			_mouse_max_speed_m_s / maxf(orbit_radius_m, 0.1))
	# Pre-aim convergence timeout: time for a worst-case 180° swing at the
	# (possibly reduced) arc rate, plus a fixed margin — never below the perfect-bot
	# default. Keeps a slow blade from bailing pre-aim early on a
	# back-pass and firing in the wrong direction.
	var swing_ticks: int = int(ceil((PI / _mouse_arc_rate_rad_s) / MOUSE_TICK_DELTA))
	_intent_max_wait_ticks = maxi(INTENT_MAX_WAIT_TICKS, swing_ticks + 60)


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


# Returns "SHOOT" / "PASS" / "CARRY" / "—" identifying which option
# scored highest on the most recent _pick_action tick. Independent
# of commit (intent) — purely the live winner.
func debug_winner() -> String:
	# The wrister is the only shot type now.
	var best_shot_score: float = debug_shoot_score
	var fire_score: float = best_shot_score if best_shot_score >= debug_pass_score else debug_pass_score
	var fire_label: String = "SHOOT" if best_shot_score >= debug_pass_score else "PASS"
	if fire_score == 0.0 and debug_carry_score == 0.0:
		return "—"
	if fire_score >= debug_carry_score:
		return fire_label
	return "CARRY"


# String form of the bot's currently-committed intent ("SHOOT" /
# "PASS" / "CARRY"). Differs from debug_winner when the bot is
# mid-pre-aim or mid-charge.
func debug_intent() -> String:
	match _intended_action:
		State.SHOOT_PRESSED: return "SHOOT"
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
		AIPossessionState.State.BREAKOUT:
			return "Breakout"
		AIPossessionState.State.FORECHECK:
			return "Forecheck"
		_:
			return "?"


func _slot_label(slot: int) -> String:
	match slot:
		AIRoleSlots.Slot.CARRIER:
			return "Carrier"
		AIRoleSlots.Slot.PRESSURE:
			return "Pressure"
		AIRoleSlots.Slot.MARK:
			return "Mark"
		AIRoleSlots.Slot.RUSH_D1:
			return "RushD1"
		AIRoleSlots.Slot.RUSH_D2:
			return "RushD2"
		AIRoleSlots.Slot.TRACK_PUCK:
			return "TrackPuck"
		AIRoleSlots.Slot.TRACK_MID, AIRoleSlots.Slot.TRACK_MID_STRONG, \
		AIRoleSlots.Slot.TRACK_MID_WEAK:
			return "TrackMid"
		AIRoleSlots.Slot.FINISHER:
			return "Finisher"
		AIRoleSlots.Slot.OUTLET:
			return "Outlet"
		AIRoleSlots.Slot.SUPPORT:
			return "Support"
		AIRoleSlots.Slot.BREAKOUT_STRONG:
			return "BreakStrong"
		AIRoleSlots.Slot.BREAKOUT_WEAK:
			return "BreakWeak"
		AIRoleSlots.Slot.F1_PRESSURE:
			return "F1"
		AIRoleSlots.Slot.F2_MID:
			return "F2"
		AIRoleSlots.Slot.F3_HIGH:
			return "F3"
		AIRoleSlots.Slot.CHASE:
			return "Chase"
		AIRoleSlots.Slot.FLANK_L:
			return "FlankL"
		AIRoleSlots.Slot.FLANK_R:
			return "FlankR"
		AIRoleSlots.Slot.NET_FRONT:
			return "NetFront"
		AIRoleSlots.Slot.HIGH_SLOT:
			return "HighSlot"
		AIRoleSlots.Slot.POINT_STRONG:
			return "PointS"
		AIRoleSlots.Slot.POINT_WEAK:
			return "PointW"
		AIRoleSlots.Slot.F2_STRONG:
			return "F2S"
		AIRoleSlots.Slot.F2_WEAK:
			return "F2W"
		AIRoleSlots.Slot.DP_STRONG:
			return "DPointS"
		AIRoleSlots.Slot.DP_WEAK:
			return "DPointW"
		AIRoleSlots.Slot.ZONE_D_STRONG:
			return "ZDS"
		AIRoleSlots.Slot.ZONE_D_WEAK:
			return "ZDW"
		AIRoleSlots.Slot.ZONE_C:
			return "ZC"
		AIRoleSlots.Slot.ZONE_W_STRONG:
			return "ZWS"
		AIRoleSlots.Slot.ZONE_W_WEAK:
			return "ZWW"
		AIRoleSlots.Slot.BREAKOUT_D2:
			return "BreakD2"
		AIRoleSlots.Slot.BREAKOUT_C:
			return "BreakC"
		AIRoleSlots.Slot.BREAKOUT_STRETCH:
			return "Stretch"
		AIRoleSlots.Slot.WIDE_L:
			return "WideL"
		AIRoleSlots.Slot.WIDE_R:
			return "WideR"
		AIRoleSlots.Slot.TRAILER:
			return "Trailer"
		AIRoleSlots.Slot.DVALVE:
			return "DValve"
		AIRoleSlots.Slot.DBACK_L:
			return "DBackL"
		AIRoleSlots.Slot.DBACK_R:
			return "DBackR"
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
	# Cache for _step_mouse_toward's arc-step path. Refreshed every
	# dispatch including skipped ticks so the arc walks the cached
	# target around the body even between full re-evals. The snapshot ref feeds
	# the protect-side turn read (opponent blades) inside the arc step.
	_current_self_pos = self_pos
	_current_self_state = self_state
	_current_snapshot = snapshot
	_current_delta = input.delta
	# Frozen team-strategy view for this dispatch (AI threading Phase 3a): the
	# brain's per-frame TeamBrainView when built (production / benchmark harness),
	# else the live brain (single-threaded tests — no race). All dispatch-path
	# brain reads go through this so Phase 3c can run dispatch off-thread.
	_current_strategy = _strategy()
	# Self-possession is instant (proprioception) — read the REAL carrier, not
	# the reaction-delayed one on puck_state. Otherwise the bot would freeze
	# holding the puck for the reaction window after receiving it. Everything
	# else in this SM reads the delayed puck_state.carrier_peer_id so the bot
	# reacts to OTHERS' possession changes a beat late.
	var have_puck: bool = (snapshot.real_puck_carrier_peer_id == _peer_id)
	_update_loose_reaction_clock(snapshot, input.delta)
	_ticks_in_state += 1
	_update_engagement_cooldown(snapshot, self_state)
	# Per-skater acceleration feeds receiver lead in pass scoring + PASS_PRESSED
	# aim. Prefer the host's shared per-frame cache (computed once for all bots
	# in GameManager); fall back to a local compute only when the snapshot lacks
	# it (unit tests hand-build snapshots without the shared cache). Resolved
	# every dispatch — including skipped-throttle ticks — since press states read
	# it too.
	if not snapshot.accel_by_peer.is_empty():
		_accel_ref = snapshot.accel_by_peer
		_omega_ref = snapshot.heading_omega_by_peer
	else:
		_update_acceleration_cache(snapshot, input.delta)
		_accel_ref = _accel_by_peer
		_omega_ref = _heading_omega_by_peer

	# When we're ghosted (offside, can't interact with the puck), chase
	# behavior is degenerate — we'd skate at a puck we can't pick up. Drop
	# to OFF_PUCK so the tag-up override in _state_off_puck routes us back
	# to the blue line. The host clears is_ghost via has_tagged_up once we
	# cross over.
	if self_state.is_ghost and _state == State.CHASE_PUCK:
		_set_state(State.OFF_PUCK)

	# Decision throttle: outside press states, re-run the full state
	# handler every DISPATCH_PERIOD_TICKS ticks. On skipped ticks reuse
	# the last-decided move_vector and re-step the mouse toward the
	# cached aim target so blade motion stays smooth at the physics rate. State
	# transitions zero `_dispatch_skip_counter` (via `_set_state`) so a
	# fresh state always dispatches full on its first tick.
	var is_press_state: bool = (_state == State.SHOOT_PRESSED
			or _state == State.PASS_PRESSED
			or _state == State.ONE_TIMER_PRESSED)
	if not is_press_state and _dispatch_skip_counter > 0:
		_dispatch_skip_counter -= 1
		input.move_vector = _cached_move_vector
		input.sprint_held = _cached_sprint_held
		input.stick_lift_held = _cached_stick_lift_held
		# Aim runs at the physics rate even though the DECISION is throttled:
		# while chasing, re-derive the reception blade target from current
		# perception every tick so the blade tracks a puck crossing into reach
		# (steering stays on the cached move_vector). This is what stops a slow,
		# catchable feed from transiting an idle blade that only re-aimed on
		# dispatch ticks. Every other state / the far chase slews the cached aim.
		if _state == State.CHASE_PUCK:
			var live_recv_aim: Vector3 = _chase_reception_aim_target(snapshot, self_pos)
			if live_recv_aim.is_finite():
				input.mouse_world_pos = _step_mouse_toward(live_recv_aim)
				return
		elif _state == State.OFF_PUCK:
			# Re-derive the off-puck blade target from CURRENT perception so it
			# tracks the moving puck/threat continuously between dispatches (the
			# ready-stance hold AND the active poke-jab reach). Same _step_mouse_face
			# path as the dispatch tick — the snap-to-clamped facing is smooth
			# precisely because the target now moves every tick.
			var live_off_aim: Vector3 = _off_puck_live_aim(snapshot, self_pos)
			if live_off_aim.is_finite():
				input.mouse_world_pos = _step_mouse_face(live_off_aim)
				return
		elif _state == State.CARRY and _intended_action == State.CARRY:
			# Re-derive the carry blade target live between dispatches. Only while
			# actually carrying — a pre-aim (SHOOT/PASS pending) keeps the throttled
			# cached re-step so its convergence gate isn't advanced off-dispatch.
			_step_carry_cursor(input, snapshot, self_pos, self_state)
			return
		if _has_cached_aim_target:
			input.mouse_world_pos = _step_mouse_internal(
					_cached_aim_target, _cached_aim_mode,
					_cached_aim_max_speed, _cached_aim_arc_rate)
		return
	# FAR-FROM-PLAY DISPATCH LOD: an OFF_PUCK bot beyond FAR_PLAY_LOD_RADIUS_M
	# of the puck runs the full state handler (steering recompute, sprint
	# resolver, role predicates) at HALF the dispatch rate — the shell-level
	# twin of the role-argmax far LOD below, and the flat majority of the 5v5
	# AI bill (8-ish post-holders paying battle rates to hold formation).
	# Same approach-physics grounding as the argmax LOD (the play needs
	# ≥ ~0.55 s to arrive from 18 m out; the halved shell adds ≤ ~17 ms), and
	# the per-tick texture is preserved on skipped ticks regardless: blade aim
	# re-derives from live perception and steering re-steps the cached move
	# vector every physics tick. OFF_PUCK only — CARRY/CHASE track the puck
	# itself and the press states never enter this throttle. The FINISHER's
	# tick-critical ring (FINISHER_FLIGHT_NEAR_M = 12 m) sits inside the LOD
	# radius, so a bot arming a one-timer is never on the halved shell.
	var dispatch_span: int = _dispatch_period_ticks
	if _state == State.OFF_PUCK and snapshot.puck_state != null \
			and self_pos.distance_squared_to(snapshot.puck_state.position) \
			> FAR_PLAY_LOD_RADIUS_M * FAR_PLAY_LOD_RADIUS_M:
		dispatch_span = _dispatch_period_ticks * 2
		# Anti-lockstep: synchronized events (a possession flip transitions
		# many bots at once, zeroing their counters via _set_state) would
		# otherwise march every far bot on the same doubled period forever —
		# same total work, spikier per-tick distribution (host FPS is the
		# worst tick). Slightly-unequal periods drift the phases apart within
		# a few cycles — the same idiom the role-argmax cooldown uses
		# ((peer_id % 3) + period below).
		dispatch_span += _peer_id % 2
	_dispatch_armed_span_ticks = dispatch_span
	_dispatch_skip_counter = dispatch_span - 1
	full_dispatch_count += 1

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
		State.ONE_TIMER_PRESSED:
			_state_one_timer_pressed(input, snapshot, self_pos, have_puck)

	_cached_move_vector = input.move_vector
	# Mirror move_vector caching: press states leave sprint_held false (zeroed
	# each tick by SkaterAgent), so a shot/charge cleanly drops the cache to
	# false and the next OFF_PUCK/CARRY tick re-engages from a fresh state.
	_cached_sprint_held = input.sprint_held
	_cached_stick_lift_held = input.stick_lift_held


# ── State handlers ───────────────────────────────────────────────────────────

func _state_off_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)

	# Default: no live aim refresh on skipped ticks. The branches below re-arm
	# the one they hit — plain ready-stance (_off_puck_aim_live) or an active
	# poke-jab (_off_puck_jab_live). One-timer pre-aim / explicit aim override
	# leave both off so they keep the throttled cached-target path.
	_off_puck_aim_live = false
	_off_puck_jab_live = false

	# Tag-up override: when ghosted (offside), bot must clear back across
	# the blue line before doing anything else. Highest-priority override
	# above all slot logic — bypasses role dispatch entirely.
	if self_state != null and self_state.is_ghost:
		var tag_up: Vector3 = _tag_up_anchor(self_pos)
		# Velocity-matched seek: redirect cross-drift onto the line back to the
		# tag-up point rather than orbiting it (same as the role stations).
		_apply_steering(input, snapshot, self_pos, tag_up, false, _self_max_speed)
		# Race back to the blue line to clear the offside as fast as possible.
		_resolve_sprint(input, self_state, self_pos, tag_up, false, false)
		_arm_off_puck_live_aim(tag_up, FACE_TRAVEL_TAG_UP_NEAR_M)
		input.mouse_world_pos = _step_mouse_face(_ready_stance_aim(
				self_pos, tag_up, snapshot, FACE_TRAVEL_TAG_UP_NEAR_M))
		_set_one_timer_ready(false)
	else:
		# Role dispatch: each TeamBrain-assigned slot maps to a behavior
		# module that produces a RoleDecision (target_position +
		# optional aim override + optional fire intents). The default
		# fallback (AIRoleAnchorFollow) just steers to the brain anchor.
		var ctx: RoleContext = _build_role_context(snapshot, self_pos, self_state)
		# Throttle the expensive positioning argmax to ~30 Hz (ROLE_DECISION_
		# PERIOD_TICKS), reusing the cached decision between re-evals — the same
		# cadence the carrier uses. Bypass the throttle for timing-critical reads
		# so they stay full-rate: a finisher-type slot (FINISHER / 5v5 NET_FRONT)
		# WHILE THE PUCK IS IN FLIGHT (its reactive tip + one-timer arming race
		# the puck; with a carrier on the puck, re-arming at the 30 Hz cadence
		# costs ≤17 ms against ≥100 ms pass flights — the old unconditional
		# FINISHER bypass burned a full-rate argmax all game for that), a live
		# one-timer-ready or body-check commit already in the cache, a location
		# ping (its steering override mutates the decision each tick, so a stale
		# cache would strand the bot), and a slot change (a cached target from
		# the old role must not carry over). ctx (ping/aim reads) is rebuilt
		# every tick regardless — only _dispatch_role_decision is throttled.
		var slot: int = _current_strategy.get_slot(_peer_id) if _current_strategy != null \
				else AIRoleSlots.Slot.NONE
		var is_finisher_slot: bool = slot == AIRoleSlots.Slot.FINISHER \
				or slot == AIRoleSlots.Slot.NET_FRONT
		# Tick-fresh finisher reads are only trigger-critical while a loose /
		# in-flight puck is CONVERGING ON THIS BOT: inside the near ring a feed
		# can reach the blade within ~0.36 s even at the ~33 m/s max shot
		# speed, so the one-timer trigger and crash read get the full 120 Hz.
		# A flight the ring hasn't admitted yet cannot arrive faster than it
		# crosses the ring, so the throttled cadence (the reactive tier still
		# runs ~30 Hz with the puck in the OZ) loses nothing — while an O-zone
		# camper no longer re-argmaxes every tick of every rim, dump, and
		# far-side cycle flight. The ready-armed bypass rides the same ring:
		# arming is positional (set on arrival at the staging spot) and its
		# consumers — the carrier's feed compete, the wind-up hold — all run
		# at the ~30 Hz argmax anyway.
		var finisher_puck_near: bool = is_finisher_slot \
				and snapshot.puck_state != null \
				and snapshot.puck_state.carrier_peer_id == -1 \
				and snapshot.puck_state.position.distance_squared_to(self_pos) \
						<= FINISHER_FLIGHT_NEAR_M * FINISHER_FLIGHT_NEAR_M
		var must_recompute: bool = _cached_role_decision == null \
				or slot != _prev_role_slot \
				or finisher_puck_near \
				or ctx.ping_move_target.is_finite() \
				or _role_decision_pinged \
				or (_cached_role_decision.is_one_timer_ready \
						and (finisher_puck_near or not is_finisher_slot)) \
				or _cached_role_decision.commit_check
		var decision: RoleDecision
		if must_recompute or _role_decision_cooldown <= 0:
			decision = _dispatch_role_decision(ctx)
			_cached_role_decision = decision
			# Reactive roles (on the puck / on a man / arming a one-timer)
			# re-eval at the full ~30 Hz; pure shape-holding roles re-eval at
			# ~15 Hz — their targets are slow-moving formation posts behind
			# multi-second hysteresis, where tens of ms of extra staleness are
			# invisible but the argmax is the whole off-puck AI bill (steering
			# still runs every dispatch toward the cached target, and every
			# discrete event — slot change, ping, one-timer, check commit —
			# bypasses the throttle entirely).
			#
			# Per-peer period skew (+0..2 ticks): any synchronizing event —
			# a possession flip transitions many bots at once, and each
			# transition zeroes its cooldown for the fresh decision — would
			# otherwise leave them re-evaluating in LOCKSTEP forever, and the
			# coincident argmax ticks are what set worst-tick frame pacing
			# (host FPS is the worst tick, not the average). Slightly unequal
			# periods drift the phases apart again within a few cycles. The
			# cadence cost is ≤2 ticks (~17 ms), inside the tolerance the
			# 20 Hz shape-holder tier already accepts.
			var period: int = ROLE_DECISION_PERIOD_TICKS \
					if _is_reactive_slot(slot, snapshot) \
					else ROLE_DECISION_PERIOD_TICKS * 2
			# FAR-FROM-PLAY LOD: a bot beyond FAR_PLAY_LOD_RADIUS_M of the puck
			# re-evals at half rate. Grounded on approach physics, not feel: the
			# puck is the fastest thing on the ice (~33 m/s max shot), so the
			# play needs ≥ ~0.55 s to even arrive at this bot's vicinity, while
			# halving the period adds ≤ 50 ms of decision latency — under a
			# tenth of that minimum window — and every timing-critical read
			# still bypasses the throttle same-tick via must_recompute (slot
			# change, one-timer, ping, live check commit). Steering runs every
			# dispatch toward the cached target regardless, so only the argmax
			# thins. This is what keeps the weak side from paying battle rates
			# to conclude "hold my post".
			if snapshot.puck_state != null \
					and ctx.self_pos.distance_squared_to(
							snapshot.puck_state.position) \
					> FAR_PLAY_LOD_RADIUS_M * FAR_PLAY_LOD_RADIUS_M:
				period *= 2
			_role_decision_cooldown = (_peer_id % 3) + period
			_role_decision_pinged = ctx.ping_move_target.is_finite()
		else:
			# Drain by the REAL dispatch span (see _dispatch_armed_span_ticks):
			# under the far-play dispatch LOD the shell runs at half rate, and
			# draining by the base period there would stretch the argmax
			# cadences a second time on top of the argmax's own far LOD.
			_role_decision_cooldown -= _dispatch_armed_span_ticks
			decision = _cached_role_decision
		# Smart-ping GO_THERE override: a live location order from a human
		# teammate replaces the role's move target for its duration. The role
		# keeps supplying aim / lift / one-timer readiness — only the skating
		# destination is commandeered (and a check commit is stood down; the
		# order says go THERE, not through someone).
		if ctx.ping_move_target.is_finite():
			decision.target_position = _clamp_anchor(ctx.ping_move_target)
			decision.commit_check = false
		# Station-keeping: arrive AT the role destination (arrival brake)
		# instead of overshooting a spot that stopped moving — EXCEPT on a
		# body-check commit (wants maximum closing velocity through the
		# target) or when the role is pacing a MOVING waypoint and asks to
		# arrive at speed (OUTLET timing its rush entry — braking to a stop
		# at the advancing target would park it short of the line).
		#
		# Velocity-matched seek (match speed = our top speed) so an off-puck
		# bot drifting cross-ice redirects ONTO the line to its role spot
		# instead of orbiting past it — the same foresight the carrier uses.
		# It only cancels the cross-drift (never the along-line speed), so it
		# composes with the arrival brake (which still stops the station) and
		# with the commit/at-speed drives (which keep their momentum straight
		# at the target). See AISteering velocity-matched seek.
		_apply_steering(input, snapshot, self_pos, decision.target_position,
				not decision.commit_check and not decision.arrive_at_speed,
				_self_max_speed)
		if decision.commit_check:
			# Body-check commit: drive THROUGH the carrier at max closing
			# velocity. Force sprint even at short range — the gap gate would
			# otherwise ease off near contact, softening the hit. Respect the
			# hard exhaustion lockout.
			input.sprint_held = self_state != null and not self_state.sprint_locked
			# Commit to the check with the Hit button too — this is what delivers the
			# FULL transfer AIBodyCheck's predicted_impulse assumed (an uncommitted
			# drive lands only the passive fraction), and braces the checker against
			# the collision. Stamina-gated in the controller like sprint, so setting it
			# while gassed is a harmless no-op there.
			input.hit_held = true
		else:
			# Sprint to close a long gap to the role's destination — backcheck
			# racing home, forecheck closing from depth, breakout up-ice. The gap
			# gate keeps a bot camped near its anchor (or a pre-aimed FINISHER) off
			# the throttle; the turn gate keeps it from sprinting into a sharp cut.
			#
			# A tracking role overrides both gates (RoleDecision.sprint_override):
			# a backchecker is behind the play by definition and the entire job is
			# closing that distance, so easing off as the gap narrows — or as the
			# recovery lane bends — is precisely wrong. The hard exhaustion lockout
			# still applies, so this can never sprint a gassed bot.
			if decision.sprint_override:
				input.sprint_held = self_state != null and not self_state.sprint_locked
			else:
				_resolve_sprint(input, self_state, self_pos, decision.target_position, false, false)
		# Deflection routine: FINISHER raises its blade to tip an incoming
		# ELEVATED on-net shot (a grounded blade flies under it). Off-puck
		# only — the controller ignores voluntary lifts while carrying. The
		# committed HIGH level is the deflect MODE (bat the high feed down at
		# the mouth) and puts the lifted blade on the high-air plane.
		input.stick_lift_held = decision.lift_blade
		if decision.lift_blade:
			input.elevation_level = ShotMechanics.ELEVATION_HIGH
		# One-timer ready overrides the default ready-stance aim: point
		# mouse + facing at the open net so the bot is pre-aimed when
		# the puck arrives. Mouse aim is what drives blade IK + body
		# facing, so this gets the whole stance lined up.
		#
		# Preserve ready through pass flights: when the puck has no
		# carrier (mid-pass / shot in flight), FINISHER's positioning
		# can't evaluate pass quality (no source carrier to evaluate
		# `score_pass` from) and falls back to "not ready", but the
		# bot's physical stance hasn't moved. Keeping the prior flag
		# alive across the carrier gap is what lets the one-timer
		# trigger fire when the puck actually arrives — without this
		# the flag drops the instant the carrier releases the pass,
		# and the zone-entry transition never sees ready=true.
		var would_be_ready: bool = decision.is_one_timer_ready
		if would_be_ready:
			# Genuinely (re-)confirmed ready — reset the preserve budget.
			_one_timer_preserve_ticks = 0
		elif _is_one_timer_ready \
				and _in_attacking_zone(self_pos) \
				and (slot == AIRoleSlots.Slot.FINISHER
						or slot == AIRoleSlots.Slot.NET_FRONT) \
				and snapshot.puck_state != null \
				and (snapshot.puck_state.carrier_peer_id == -1
						or snapshot.real_puck_carrier_peer_id == -1) \
				and _one_timer_preserve_ticks < ONE_TIMER_PRESERVE_MAX_TICKS:
			# Preserve ready across the brief carrier gap of a pass/shot in flight,
			# but only for a bounded window — a pass that dies or deflects must not
			# leave the bot camped-and-ready forever, refusing to chase the puck.
			# The REAL carrier check matters: for carrier_reaction_delay_s after
			# the feed releases, the debounced carrier still reads as holding the
			# puck while its velocity already reads as a live pass — without it,
			# that window dropped ready on EVERY feed (the role decision goes
			# reactive on the fast puck and returns not-ready, and this preserve
			# refused to bridge a "held" puck), so the camped one-timer never
			# survived to the zone-entry trigger.
			#
			# Gated to an OFFENSIVE context so it bridges only OUR feed, never a
			# turnover: the shooter must still be in the attacking zone AND still
			# hold the FINISHER slot. A pass/shot in flight keeps possession
			# sticky-OZONE and the camped bot nearest the net keeps FINISHER, so
			# the legit bridge survives; the moment an opponent gains the puck the
			# slot flips off FINISHER (and a retreating bot leaves the zone), so
			# readiness can't leak into a defensive-zone one-timer. Rebound-safe:
			# a puck loose off the goalie stays OZONE/FINISHER.
			_one_timer_preserve_ticks += _dispatch_period_ticks
			would_be_ready = true
		_set_one_timer_ready(would_be_ready)
		# Defensive poke jab: a puck-pressurer within reach of the
		# carrier's puck aims its blade THROUGH the puck so the host strip
		# detection fires. Only evaluated when no offensive intent
		# (one-timer) is live — a pressurer is never one-timer-ready, but
		# gating here keeps the jab lifecycle from ticking during
		# offensive states. INF (no jab) falls through to the normal aim.
		var jab_aim: Vector3 = Vector3.INF
		if not would_be_ready:
			jab_aim = _poke_jab_aim(snapshot, self_pos)
		if jab_aim.is_finite():
			_off_puck_jab_live = true
			input.mouse_world_pos = _step_mouse_face(jab_aim)
		elif would_be_ready:
			input.mouse_world_pos = _step_mouse_face(_shot_aim_point(snapshot, self_pos, 0.0))
		elif decision.has_aim_override:
			input.mouse_world_pos = _step_mouse_face(decision.aim_world_pos)
		else:
			_arm_off_puck_live_aim(decision.target_position, FACE_THREAT_NEAR_ANCHOR_M)
			input.mouse_world_pos = _step_mouse_face(_ready_stance_aim(self_pos, decision.target_position, snapshot))

	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif _is_one_timer_ready and _in_attacking_zone(self_pos) \
			and (_one_timer_line_anchor(snapshot, self_pos).is_finite()
			or _puck_in_one_timer_zone(snapshot, self_pos)):
		# Commit the one-timer at feed RELEASE, not at contact: the press
		# state's slap wind-up needs the flight time to build (the visible,
		# diegetic charge), and its live-line settle needs the flight to walk
		# the slapper zone onto the pass's actual path. The zone-entry check
		# stays as the fallback trigger for feeds too soft/close to read as a
		# live line (and rebounds squirting through the stance).
		_set_state(State.ONE_TIMER_PRESSED)
	elif _is_one_timer_ready and not _loose_puck_in_reach_band(snapshot, self_pos):
		# Stay camped + pre-aimed even if the brain says we're closest
		# to a loose puck. Chasing would re-aim mouse toward the puck
		# and the FINISHER would lose the goal-aim lock; staying in
		# OFF_PUCK keeps facing + blade pointed at the net so the
		# press on feed release starts from a clean stance. Racing a
		# puck across the zone is another teammate's job — we're
		# committed to being the trigger.
		#
		# The reach band is the one exception, and it's not a tradeoff:
		# a puck arriving inside the camper's own stick is a puck he
		# takes without leaving the spot he's camped on, and standing
		# frozen while it slides through the crease is the single most
		# visible way this bot looks broken. Losing the one-timer to
		# gain the puck is a trade you always make.
		pass
	elif _should_chase_loose_puck(snapshot, self_pos) \
			or _incoming_pass_to_me(snapshot, self_pos):
		# Chase either the loose puck we're closest to, OR a pass released our way —
		# the latter gets us into the squared reception setup before the fast puck
		# arrives, rather than reacting only once it's on top of us.
		_set_state(State.CHASE_PUCK)


# Builds the read-only inputs every role-behavior decide() needs.
# Allocates a fresh RoleContext per call; cheap RefCounted, profile if
# this ever shows up in flame graphs.
func _build_role_context(snapshot: WorldSnapshot, self_pos: Vector3,
		self_state: SkaterNetworkState) -> RoleContext:
	var ctx := _role_ctx
	ctx.snapshot = snapshot
	ctx.self_pos = self_pos
	ctx.self_velocity = self_state.velocity if self_state != null else Vector3.ZERO
	ctx.team_id = _team_id
	ctx.peer_id = _peer_id
	ctx.attacking_goal_pos = _attacking_goal_pos
	ctx.defending_goal_pos = Vector3(0.0, 0.0, _own_goal_dir * GameRules.GOAL_LINE_Z)
	ctx.own_goal_dir = _own_goal_dir
	ctx.team_brain = _current_strategy
	ctx.team_id_by_peer = _team_id_by_peer
	ctx.acceleration_by_peer = _accel_ref
	ctx.heading_omega_by_peer = _omega_ref
	ctx.caps_by_peer = _caps_by_peer
	# This bot's own attribute-scaled speeds, so the carrier scores ITS shots /
	# passes / carry ETAs with real numbers (cross-player evals stay default).
	ctx.self_max_speed = _self_max_speed
	ctx.self_max_accel = _chase_max_accel
	ctx.self_wrister_shot_speed = _self_wrister_shot_speed
	ctx.self_loft_tans = _self_loft_tans
	ctx.self_lateral_grip = _self_lateral_grip
	# The scoring/aim spread budgets the SHOT error — that's the budget the
	# release that matters (a scored shot) is actually sampled on.
	ctx.self_aim_spread_rad = _shot_aim_error_rad
	# The pass counterpart: this bot's release-direction error on PASSES, which
	# the derived pass-miss probability projects to the tape over the pass length.
	ctx.self_pass_aim_error_rad = _pass_aim_error_rad
	# The shot evals give the goalie this much extra tracking time — the
	# release's own timing slop (see _shoot_release_hold_ticks).
	ctx.shot_timing_error_s = _shot_timing_error_s
	ctx.self_weight = _self_weight
	ctx.self_body_check_transfer = _self_body_check_transfer
	ctx.self_handle_reach = _self_handle_reach
	ctx.self_blade_reach = _blade_reach
	ctx.self_reach_cone_half_angle = _self_reach_cone_half_angle
	ctx.self_facing_turn_rate = _self_facing_turn_rate
	ctx.self_blade_speed = _self_blade_speed
	ctx.self_backhand_power_coefficient = _self_backhand_coefficient
	ctx.self_forehand_perp_sign = _handedness_perp_sign
	ctx.self_stagger_timer = self_state.stagger_timer if self_state != null else 0.0
	ctx.pursuit_standoff_m = _pursuit_standoff_m
	ctx.pass_speed_scale = _pass_speed_scale
	ctx.check_aggression = _check_aggression
	ctx.defensive_anticipation_scale = _defensive_anticipation_scale
	ctx.carry_settle_delay_s = _carry_settle_delay_s
	ctx.reads_goalie_motion = _reads_goalie_motion
	ctx.holds_for_developing_feeds = _holds_for_developing_feeds
	ctx.reads_receiver_commitment = _reads_receiver_commitment
	ctx.plays_rush_pass_lanes = _plays_rush_pass_lanes
	ctx.protects_the_puck = _protects_the_puck
	# The carrier runs its cooldown / hold-decay clock in real time, but decide()
	# is only called on dispatch ticks — hand it the span so it can compensate.
	ctx.dispatch_period_ticks = _dispatch_period_ticks
	# Ruleset read for the counter channels: only the OFF ruleset plays an
	# offside-positioned opponent as a live outlet (ARCADE/NHL both void him
	# until he tags up at the blue line). Latched like the match's other
	# rules; stamped every build since the ctx instance is reused.
	ctx.offsides_enforced = rule_set != GameRules.RuleSet.OFF
	if _current_strategy != null:
		var brain_anchor: Vector3 = _current_strategy.get_anchor(_peer_id, snapshot)
		ctx.anchor = brain_anchor if brain_anchor != Vector3.ZERO else self_pos
		ctx.strong_x = _current_strategy.strong_x()
		ctx.assigned_threat_peer = _current_strategy.assigned_threat(_peer_id)
		# The brain's shared threat memo, read off the strategy view (a frozen
		# copy in production). Re-stamped every build so the reused ctx never
		# carries another brain's dict.
		ctx.threat_shoot_base_by_opp = _current_strategy.get_threat_shoot_base_by_opp()
		# The team's shared transition read. Re-stamped every build for the same
		# reason as the memo above — the reused ctx must never carry another
		# brain's (or another tick's) read.
		ctx.rush_read = _current_strategy.get_rush_read()
		# 5v5 position identity (plan §1/§6). Re-stamped every build — the
		# reused ctx must never carry another match's team size.
		ctx.team_size = _current_strategy.get_team_size()
		var lobby_slot: int = _current_strategy.position_of(_peer_id)
		ctx.self_is_defense = PlayerRules.is_defense_slot(lobby_slot)
		ctx.self_home_side = _home_side_of(lobby_slot)
		# Live smart-ping directives on this bot (see AIPingDirectives). The
		# reused ctx instance must be re-stamped every build — a stale ping
		# field would keep obeying an expired order.
		ctx.ping_move_target = _current_strategy.ping_move_target(_peer_id)
		ctx.ping_shoot_active = _current_strategy.ping_shoot(_peer_id)
		ctx.ping_pass_target_peer = _current_strategy.ping_pass_target(_peer_id)
	else:
		ctx.anchor = self_pos
		# Match RoleContext.new()'s default when no brain is wired (tests),
		# since the reused instance would otherwise carry a stale value.
		ctx.strong_x = 1.0
		ctx.assigned_threat_peer = -1
		ctx.threat_shoot_base_by_opp = _empty_threat_memo
		ctx.rush_read = _inert_rush_read
		ctx.ping_move_target = Vector3.INF
		ctx.ping_shoot_active = false
		ctx.ping_pass_target_peer = -1
		ctx.team_size = GameRules.DEFAULT_TEAM_SIZE
		ctx.self_is_defense = false
		ctx.self_home_side = 0.0
	return ctx


# Home side sign of a lobby position: LW/LD rest on -X, RW/RD on +X, C
# center. World X is side-stable for both teams (see AIRoleSlots5).
func _home_side_of(lobby_slot: int) -> float:
	match lobby_slot:
		1, 3:
			return -1.0
		2, 4:
			return 1.0
		_:
			return 0.0


# Routes the bot's current slot to its role-behavior module. Returns a
# RoleDecision the state machine consumes to drive steering / aim /
# fire-intent transitions.
#
# CARRIER does not appear here — the state machine's _state_carry
# state owns carrier dispatch directly because the carrier needs
# its own steering rules (HOLD vs DRIFT during pre-aim) and press
# transitions (SHOOT_PRESSED / PASS_PRESSED). Phase 3 adds CARRIER
# here for the puck-in-flight case where the brain still has us
# slotted CARRIER but we don't have the puck.
func _dispatch_role_decision(ctx: RoleContext) -> RoleDecision:
	var slot: int = _current_strategy.get_slot(_peer_id) if _current_strategy != null else AIRoleSlots.Slot.NONE
	# Target switch-hysteresis input: the target this bot's role chose last
	# dispatch — INF across a slot change so no role inherits another's
	# target (see RoleContext.prev_role_target).
	ctx.prev_role_target = _prev_role_target if slot == _prev_role_slot else Vector3.INF
	# Zone soft-lock incumbent, same reset-across-slot-change contract.
	ctx.prev_locked_man = _prev_locked_man_pid if slot == _prev_role_slot else -1
	# Pinch-read hysteresis incumbent, same reset-across-slot-change contract.
	ctx.prev_held_forward_stand = _prev_held_forward_stand \
			if slot == _prev_role_slot else false
	var decision: RoleDecision
	match slot:
		AIRoleSlots.Slot.FINISHER:
			decision = AIRoleFinisher.decide(ctx)
		AIRoleSlots.Slot.SUPPORT:
			decision = AIRoleSupport.decide(ctx)
		AIRoleSlots.Slot.OUTLET:
			decision = AIRoleOutlet.decide(ctx)
		AIRoleSlots.Slot.BREAKOUT_STRONG:
			decision = AIRoleBreakout.decide(ctx, true)
		AIRoleSlots.Slot.BREAKOUT_WEAK:
			decision = AIRoleBreakout.decide(ctx, false)
		AIRoleSlots.Slot.F1_PRESSURE:
			# F1 reuses PRESSURE — goal-side cutoff of the carrier, already
			# loose-puck-safe; follows the puck out and accepts the tag-up
			# risk if the opp breaks out.
			decision = AIRolePressure.decide(ctx)
		AIRoleSlots.Slot.F2_MID:
			decision = AIRoleForecheck.decide(ctx, false)
		AIRoleSlots.Slot.F3_HIGH:
			decision = AIRoleForecheck.decide(ctx, true)
		AIRoleSlots.Slot.PRESSURE:
			decision = AIRolePressure.decide(ctx)
		AIRoleSlots.Slot.MARK:
			decision = AIRoleMark.decide(ctx)
		AIRoleSlots.Slot.RUSH_D1, AIRoleSlots.Slot.RUSH_D2:
			decision = AIRoleRushD.decide(ctx, slot)
		AIRoleSlots.Slot.TRACK_PUCK, AIRoleSlots.Slot.TRACK_MID_STRONG, \
		AIRoleSlots.Slot.TRACK_MID_WEAK, AIRoleSlots.Slot.TRACK_MID:
			decision = AIRoleTrack.decide(ctx, slot)
		AIRoleSlots.Slot.CHASE:
			decision = AIRoleChase.decide(ctx)
		AIRoleSlots.Slot.FLANK_L:
			decision = AIRoleFlank.decide(ctx, -1.0)
		AIRoleSlots.Slot.FLANK_R:
			decision = AIRoleFlank.decide(ctx, 1.0)
		# ── 5v5 slots (AIRoleSlots5) — plan §2–§5.
		AIRoleSlots.Slot.NET_FRONT:
			# The crease-edge screen/backdoor man — FINISHER's argmax already
			# owns that ice (one-timer camp + tip logic included).
			decision = AIRoleFinisher.decide(ctx)
		AIRoleSlots.Slot.HIGH_SLOT:
			decision = AIRoleHighSlot.decide(ctx)
		AIRoleSlots.Slot.POINT_STRONG, AIRoleSlots.Slot.POINT_WEAK, \
		AIRoleSlots.Slot.DP_STRONG, AIRoleSlots.Slot.DP_WEAK, \
		AIRoleSlots.Slot.DVALVE, \
		AIRoleSlots.Slot.DBACK_L, AIRoleSlots.Slot.DBACK_R:
			decision = AIRoleDefenseman.decide(ctx, slot)
		AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK, \
		AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG, \
		AIRoleSlots.Slot.ZONE_W_WEAK:
			decision = AIRoleZoneDefense.decide(ctx, slot)
		AIRoleSlots.Slot.F2_STRONG:
			decision = AIRoleForecheck.decide_f2(ctx, true)
		AIRoleSlots.Slot.F2_WEAK:
			decision = AIRoleForecheck.decide_f2(ctx, false)
		AIRoleSlots.Slot.BREAKOUT_D2:
			# Net-front reverse valve — the weak-side breakout outlet's job.
			decision = AIRoleBreakout.decide(ctx, false)
		AIRoleSlots.Slot.BREAKOUT_STRETCH:
			# Weak winger's stretch: OUTLET paces the far blue line legally.
			decision = AIRoleOutlet.decide(ctx)
		AIRoleSlots.Slot.BREAKOUT_C:
			decision = AIRoleBreakoutCenter.decide(ctx)
		AIRoleSlots.Slot.WIDE_L:
			decision = AIRoleWideLane.decide(ctx, -1.0)
		AIRoleSlots.Slot.WIDE_R:
			decision = AIRoleWideLane.decide(ctx, 1.0)
		AIRoleSlots.Slot.TRAILER:
			# High-slot trailer — SUPPORT's goal-side trail read.
			decision = AIRoleSupport.decide(ctx)
		_:
			decision = AIRoleAnchorFollow.decide(ctx)
	_prev_role_slot = slot
	_prev_role_target = decision.target_position
	_prev_locked_man_pid = decision.locked_man_pid
	_prev_held_forward_stand = decision.held_forward_stand
	return decision


# Reception blade-aim target for CHASE — the engagement pull-back, in-reach snap,
# and gate-park branches of the chase aim, factored out because each is a pure
# function of current perception (puck + self position/velocity) and cheap. The
# decision throttle re-runs the full chase handler only every dispatch_period_ticks,
# but this is called EVERY physics tick (including throttle-skipped ticks) so the
# blade tracks a puck crossing into reach at the physics rate instead of the
# dispatch rate — a slow, catchable feed used to transit an idle blade parked on a
# stale target. Returns Vector3.INF when no reception branch applies (far chase, or
# a carried / slow puck still out of reach) — the caller keeps its cached FACE aim
# at the intercept there.
func _chase_reception_aim_target(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	# Just got stripped / stick-checked: pull the blade back to the body so the
	# loose puck can settle without auto-magnetting straight back onto the stick.
	if _engagement_cooldown > 0:
		return Vector3(self_pos.x, 0.0, self_pos.z)
	var puck_pos: Vector3 = snapshot.puck_state.position
	# A teammate's blade is already first to it — take the stick OFF the puck
	# (same pull-back the engagement cooldown uses). Two of our blades on the
	# same puck is a contested pickup, and the contest is symmetric: it squirts
	# free and cools both blades down, so jamming a puck our own man already has
	# is a pure giveaway. He takes it, we support. The contest rule itself is
	# deliberately untouched — a real jam should still leave the puck loose.
	if _teammate_first_to_puck(snapshot, puck_pos):
		return Vector3(self_pos.x, 0.0, self_pos.z)
	# Inside reach: aim at the puck's ACTUAL position (leading here would put the
	# blade past a puck already on the stick).
	if self_pos.distance_to(puck_pos) <= _blade_reach:
		return puck_pos
	# Fast loose puck (an incoming feed): PARK at the gate — the earliest point on
	# the puck's travel line the blade can touch — and let the puck arrive into it.
	if snapshot.puck_state.carrier_peer_id == -1:
		var pv: Vector3 = snapshot.puck_state.velocity
		if pv.x * pv.x + pv.z * pv.z > LOOSE_PUCK_TRACK_SPEED_M_S * LOOSE_PUCK_TRACK_SPEED_M_S:
			return _blade_gate_on_puck_line(self_pos, puck_pos, pv)
	return Vector3.INF


func _state_chase_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Shot-aware reception first: if a pass is incoming and a shot from the
	# reception area is on, one-time it (Mode A → ONE_TIMER_PRESSED) or catch it
	# in a net-ward posture (Mode B, input set in-place) instead of turning to
	# grab. Mode A has already changed state, so return without running the
	# chase transitions below.
	var recv: int = _try_shot_reception(input, snapshot, self_pos)
	if recv == _RECV_ONE_TIME:
		return
	_chase_sprint_ref = snapshot.puck_state.position
	# An INBOUND fast loose puck (a feed coming AT us) is a reception, not a
	# race: the catch gate judges the puck's speed in OUR frame
	# (PuckReceptionRules, #373), so our own closing speed stacks onto the
	# puck's pace — sprinting at the feed (or skating hard into it) turns a
	# tape pass into a knock-down. Read the geometry once: the sprint gate
	# and the give-brake below both use it.
	var give_brake: bool = false
	if snapshot.puck_state.carrier_peer_id == -1:
		var pv: Vector3 = snapshot.puck_state.velocity
		var pv_speed_sq: float = pv.x * pv.x + pv.z * pv.z
		if pv_speed_sq > LOOSE_PUCK_TRACK_SPEED_M_S * LOOSE_PUCK_TRACK_SPEED_M_S:
			var pp: Vector3 = snapshot.puck_state.position
			var inbound: bool = pv.x * (self_pos.x - pp.x) \
					+ pv.z * (self_pos.z - pp.z) > 0.0
			if inbound:
				_chase_sprint_ref = self_pos   # gap 0 — sprint stays off
				var sv: Vector3 = Vector3.ZERO
				var give_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
				if give_state != null:
					sv = give_state.velocity
				# GIVE WITH THE PUCK: above the receivable ceiling in our
				# frame, the only lever we hold is shedding our own closing —
				# brake and let the feed come to the parked blade.
				var rel_x: float = pv.x - sv.x
				var rel_z: float = pv.z - sv.z
				give_brake = rel_x * rel_x + rel_z * rel_z \
						> RECEIVE_GIVE_CEILING_M_S * RECEIVE_GIVE_CEILING_M_S
	# Pass-receive setup: if a fast loose puck is heading near our
	# trajectory, stand perpendicular to its path for an angle-optimal
	# catch instead of chasing the puck position (default lead-intercept
	# gives the wrong stick orientation for the alignment bonus). The
	# helper returns false when the scenario doesn't apply and we fall
	# through to the default chase. Skipped entirely when Mode B already
	# set aim+steer (recv == _RECV_CATCH_STRIDE).
	if recv == _RECV_NONE and not _pass_receive_aim_and_steer(input, snapshot, self_pos):
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
		# Race at the sprint-aware cap — the body sprints this chase
		# (_resolve_sprint below), so a cruise-priced walk aimed at points
		# the sprinting body overruns.
		var race_cap: float = _self_max_speed
		if self_state2 != null:
			race_cap = BotSprintRules.race_speed(
					_self_max_speed, _self_sprint_mult,
					self_state2.stamina, self_state2.sprint_locked,
					Vector2(puck_pos.x - self_pos.x, puck_pos.z - self_pos.z).length())
		var target: Vector3 = _lead_intercept(
				self_pos, self_vel_3d, puck_pos, snapshot.puck_state.velocity, race_cap)
		# Angling: when an OPPONENT carries the puck, shade the intercept
		# toward OUR net so we approach on the inside lane and force them
		# outside. Loose pucks get the raw intercept — there's no carrier
		# to angle off of. Teammate-carried case is filtered upstream by the
		# F1→OFF_PUCK transition, so by the time we reach here a non-(-1)
		# carrier is necessarily an opponent. Cognition gate: a tier without
		# the angling read (_angles_the_chase false) chases straight at the
		# puck — taught defensive skill Easy doesn't have, so a human's
		# cutback to the middle works.
		var carrier_pid: int = snapshot.puck_state.carrier_peer_id
		if _angles_the_chase and carrier_pid != -1 and carrier_pid != _peer_id:
			var our_net := Vector3(0.0, 0.0, _own_goal_dir * GameRules.GOAL_LINE_Z)
			target = _shade_intercept_goal_side(target, our_net)

		# No "soft-hands" slow-down here: the catch is decided by blade squareness +
		# the puck's speed in OUR frame (PuckReceptionRules, #373), so easing the
		# approach doesn't help the pickup and only surrenders time on a race.
		# Getting to the puck fast and on a good blade angle is what matters.
		var puck_velocity: Vector3 = snapshot.puck_state.velocity
		var puck_speed_xz: float = sqrt(puck_velocity.x * puck_velocity.x
				+ puck_velocity.z * puck_velocity.z)

		# Contested 50/50: a slow loose puck an OPPONENT'S blade can also reach.
		# Hovering blade-first here bred endless re-contest loops — both bots
		# park at reach, the pinched squirt stays between them, engagement
		# cooldowns re-arm, repeat, with nobody committed enough to separate the
		# play. Commit the BODY through the contest instead: overshoot the puck
		# along our approach line so our skating momentum (a) weights the
		# contested squirt our way (PuckCollisionRules.contested_pickup_velocity
		# blends blade momentum — the moving blade wins the seed-pinch) and (b)
		# carries us THROUGH the 50/50 for real separation. Win or lose, the
		# standoff geometry breaks every contest.
		var contested: bool = carrier_pid == -1 \
				and puck_speed_xz <= LOOSE_PUCK_TRACK_SPEED_M_S \
				and _opponent_within_of(snapshot, puck_pos, ENGAGEMENT_PROXIMITY_M)
		if contested:
			var through: Vector3 = Vector3(
					puck_pos.x - self_pos.x, 0.0, puck_pos.z - self_pos.z)
			if through.length_squared() > 0.0001:
				target = puck_pos + through.normalized() * ENGAGEMENT_PROXIMITY_M
				# The drive-through is a SKATING route — it cannot pass
				# through a cage. A 50/50 at the crease edge used to
				# overshoot INTO the goal mouth (the bot crashing its own
				# net, bulldozing the goalie, shoveling the contest toward
				# the mesh). When the through-line crosses a net, engage at
				# the puck itself: the blade contest still happens, without
				# committing the body through the frame.
				if AIActionScoring.carry_path_blocked_by_net(puck_pos, target):
					target = puck_pos
				# Sprint gate reads the overshoot too — the easing that slows a
				# clean solo pickup must not bleed speed out of a contest.
				_chase_sprint_ref = target
		elif carrier_pid == -1:
			# BLADE-FIRST pickup route: steer the BODY to a point one carry
			# cradle SHORT of the intercept along the approach line, so the bot
			# arrives with the puck outstretched a blade-length ahead on its
			# skating line — the blade (which makes the actual pickup; the
			# close-range branch below snaps the aim onto the puck inside
			# reach) finally shapes the route. The raw intercept delivered the
			# CHEST onto the puck: the body overran the pickup point and the
			# puck was fished off the hip or from behind — the "orient then
			# skate" look. The pull-back also lands the puck exactly at the
			# carry cradle spot (CARRY_BLADE_AIM_FORWARD_M), so a clean pickup
			# flows into the first carrying stride with no gather. Inside one
			# cradle of the intercept the raw target stands (nothing left to
			# shape). Pursuit of a CARRIED puck keeps the raw intercept — body
			# pressure on the man is the point there — and the contested
			# overshoot above keeps its committed momentum drive.
			var approach: Vector3 = Vector3(
					target.x - self_pos.x, 0.0, target.z - self_pos.z)
			var approach_len: float = approach.length()
			if approach_len > CARRY_BLADE_AIM_FORWARD_M:
				target -= approach * (CARRY_BLADE_AIM_FORWARD_M / approach_len)
		_apply_steering(input, snapshot, self_pos, target)
		if give_brake:
			input.brake = true   # give with the puck — shed our own closing

		# Aim: normally blade-on-intercept, but during the engagement cooldown
		# (just got stripped or just stick-checked someone) pull the blade
		# back to our body so the puck can settle without auto-magnetting
		# back to us. Once the puck is inside our blade reach, snap the aim
		# to the puck's ACTUAL position — leading at this range puts the
		# blade past a puck that's already on our stick. For fast loose
		# pucks (incoming passes), PARK the blade at the GATE — the earliest
		# point on the puck's travel line our blade can touch — and let the
		# puck come to it. Aiming at the puck's current position instead
		# means the cursor (capped at Hands blade speed, ~10 m/s) chases a
		# ~20 m/s puck it can never catch: the blade trails the puck through
		# our reach and the pass transits untouched.
		# Reception aim — engagement pull-back / in-reach snap / gate-park — is a
		# pure function of current perception, factored into
		# _chase_reception_aim_target so the throttle's skipped-tick path can
		# refresh it live every physics tick (a slow catchable feed used to transit
		# an idle blade because this only re-aimed on dispatch ticks). INF = no
		# reception branch → FACE-aim the far chase.
		var recv_aim: Vector3 = _chase_reception_aim_target(snapshot, self_pos)
		if recv_aim.is_finite():
			input.mouse_world_pos = _step_mouse_toward(recv_aim)
		else:
			# FACE-aim the far chase at the intercept: the cursor is pure
			# pointing intent off-puck (nothing to dangle), so it snaps to the
			# cone-clamped target and the body turns at full facing_drag — the
			# bot LOOKS down its chase line (≈ the puck line) the whole run.
			# The old ARC walk swung the cursor at the blade slew rate, which
			# left seconds-long windows of skating one way while facing
			# another after a chase-entry flip. A target in the back wedge
			# clamps to the cone edge and the body walks around to it — the
			# same freeze-proofing the arc bought, without the slow swing.
			# Close-range precision is unaffected: inside _blade_reach the
			# reception helper aims direct at the puck itself.
			input.mouse_world_pos = _step_mouse_face(target)
	# Sprint to win the race to a loose / contested puck. Gap is measured to
	# the puck itself — the arrival easing inside ~1.5 m slows a clean solo
	# pickup — EXCEPT through a live contest, where the gap reads the drive-
	# through point instead so the bot arrives with its speed. Resolved after
	# both steering paths above so the turn gate sees the final heading.
	var chase_self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	_resolve_sprint(input, chase_self_state, self_pos, _chase_sprint_ref, false, false)
	_chase_sprint_ref = Vector3.INF

	# Transitions: chase ends as soon as someone has the puck, OR we're
	# no longer the closest teammate (let the new closest take over).
	# One-timer takes priority — if the FINISHER published ready and the
	# puck enters our zone while chasing, fire instead of picking up.
	if have_puck:
		_set_state(State.CARRY)
	elif _is_one_timer_ready and _in_attacking_zone(self_pos) \
			and _puck_in_one_timer_zone(snapshot, self_pos):
		_set_state(State.ONE_TIMER_PRESSED)
	elif not _should_chase_loose_puck(snapshot, self_pos) \
			and not _incoming_pass_to_me(snapshot, self_pos):
		# Stay in CHASE while a pass is still heading our way even if we aren't the
		# closest to the puck's CURRENT spot (it's near the passer early in flight) —
		# leaving now would drop the reception setup we entered to make.
		_set_state(State.OFF_PUCK)


# Pass-receive sub-behavior. When a fast loose puck is heading along
# a straight trajectory near us, set up perpendicular to the puck's
# path instead of chasing the puck position. Body stands offset to
# the side; stick reaches across to meet the puck on the path; blade
# face opens to the puck's incoming direction → maximum alignment
# bonus from PuckReceptionRules.
#
# Returns true if the helper handled the tick (caller skips default
# chase aim/steer). Returns false when the scenario doesn't apply —
# puck too slow, puck behind us, lateral too far, or we can't reach
# the receive position in time.
#
# v1 uses constant-velocity puck math instead of the friction-aware
# AITrajectory.predict_puck that lead-intercept uses. Fine for short
# receive windows where the speed drop is small; for very long
# stretch passes (>1 s flight) the puck arrives slower than
# predicted and the timing margin gives us slack.
func _pass_receive_aim_and_steer(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	if snapshot.puck_state.carrier_peer_id != -1:
		return false
	var puck_vel: Vector3 = snapshot.puck_state.velocity
	var puck_speed_sq: float = puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z
	if puck_speed_sq < RECEIVE_TRIGGER_PUCK_SPEED_M_S * RECEIVE_TRIGGER_PUCK_SPEED_M_S:
		return false
	var puck_pos: Vector3 = snapshot.puck_state.position
	# Meet the puck on its REAL path, not on the straight ray off its current
	# velocity (see RECEIVE_PATH_* / AITrajectory.solve_reception_gate): the
	# crossing point, WHEN it gets there, and the direction it is travelling
	# THEN all come off the same board-aware walk, so a rim is set up for
	# around the carom instead of along a chord that leaves the rink.
	AITrajectory.solve_reception_gate(puck_pos, puck_vel, self_pos,
			_receive_gate_reach(), RECEIVE_PATH_HORIZON_S, RECEIVE_PATH_STEPS)
	# Nothing to set up for when the path never brings it closer than it
	# already is. Path-based, not a dot product against the current velocity:
	# a rim running away down the far wall IS coming to us, it just has a
	# corner to turn first, and the old along-the-ray test bailed on exactly
	# that — which is why bots started their rim setup a corner too late.
	if not AITrajectory.gate_closes:
		return false
	var perp_foot: Vector3 = AITrajectory.gate_point
	var gate_vel: Vector3 = AITrajectory.gate_velocity
	var gate_speed: float = sqrt(gate_vel.x * gate_vel.x + gate_vel.z * gate_vel.z)
	if gate_speed < 0.001:
		return false
	var puck_dir: Vector3 = Vector3(gate_vel.x / gate_speed, 0.0, gate_vel.z / gate_speed)
	# The puck must still be coming TO us. A gate at t≈0 means it is already on
	# the blade (nothing to set up for); the walk finding nothing but a receding
	# closest approach means it is going away — chase from behind instead.
	var puck_eta: float = AITrajectory.gate_time_s
	if puck_eta <= 0.0:
		return false
	var perp_off: Vector3 = self_pos - perp_foot
	perp_off.y = 0.0
	var perp_dist: float = perp_off.length()
	if perp_dist > RECEIVE_TRIGGER_LATERAL_M:
		return false
	# Lateral direction: which side of the path the bot stands on. Its own side
	# minimizes skating distance. Degenerate case (bot on the path) — any
	# perpendicular, so the body still steps off it for a clean stick angle.
	var lateral: Vector3
	if perp_dist > 0.001:
		lateral = perp_off / perp_dist
	else:
		lateral = Vector3(-puck_dir.z, 0.0, puck_dir.x)
	# WALL KILL (see WALL_KILL_BAND_M): against the boards only one side of the
	# path is real ice, so the stance side is forced inward — standing "on our
	# side" of a rim line can mean standing in the glass, and the clamp that
	# used to rescue that put the body on the puck's line with the blade
	# swinging out over it. Inward is where a player takes a rim from.
	var wall_gate: Vector3 = perp_foot
	var board: Vector3 = _board_normal_and_gap(Vector2(perp_foot.x, perp_foot.z))
	if board.y <= WALL_KILL_BAND_M:
		wall_gate = Vector3(perp_foot.x - board.x * board.y, 0.0,
				perp_foot.z - board.z * board.y)
		lateral = Vector3(board.x, 0.0, board.z)
		perp_foot = wall_gate
	var body_anchor: Vector3 = perp_foot + lateral * _receive_body_offset
	# Wall reception: the side-stand offset from a boards-hugging line can
	# push the body target into/through the wall — keep the body's center a
	# body radius inside so the stance is standable and the blade (not the
	# chest) plays the rim line.
	var anchor_xz: Vector2 = GameRules.clamp_to_rink_inner(
			Vector2(body_anchor.x, body_anchor.z), RECEIVE_BODY_WALL_MARGIN_M)
	body_anchor = Vector3(anchor_xz.x, 0.0, anchor_xz.y)
	# Timing gate: do we have time to reach body_anchor before the puck
	# arrives at perp_foot? (puck_eta came off the path walk above — timed
	# around the carom, not along a chord.) If not, default lead-intercept
	# gets us closer even at a worse angle — bail and let it run.
	var self_vel: Vector3 = Vector3.ZERO
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state != null:
		self_vel = self_state.velocity
	var bot_eta: float = AIActionScoring.time_to_arrive(
			self_pos, body_anchor, self_vel, _self_max_speed)
	if bot_eta > puck_eta * RECEIVE_TIMING_MARGIN:
		return false
	# Commit. Receive IN STRIDE by default — brake only when waiting is
	# geometrically unavoidable. Settling buys nothing for the catch itself
	# (#373's relative frame: running with or across a magnet-pace feed keeps the
	# closing speed inside the catchable band — a perpendicular crossing at full
	# sprint adds ~2 m/s over the puck's own pace) and it kills the rush: a
	# stopped receiver pays full re-acceleration after the catch. The one case
	# that NEEDS the brake is arriving so early that continued motion carries the
	# blade past the puck's line before the puck shows up. The blade's own reach
	# buys a window around the line-crossing (~2 × gate reach / speed of covered
	# time); only when the puck is later than that window is waiting forced — and
	# then stopping square at the gate is the correct wait. A near-stationary bot
	# has an effectively unbounded window (nothing carries it past the line).
	var self_speed: float = sqrt(self_vel.x * self_vel.x + self_vel.z * self_vel.z)
	var blade_window: float = 2.0 * _receive_gate_reach() / maxf(self_speed, 0.001)
	_apply_steering(input, snapshot, self_pos, body_anchor,
			puck_eta > bot_eta + blade_window)
	# GIVE WITH THE PUCK: the catch gate judges the puck in OUR frame, and a
	# receiver with real closing speed INTO the feed stacks it on top of the
	# puck's pace — over the receivable ceiling, force the brake and shed our
	# own closing (a perpendicular crossing barely registers here; only
	# genuine into-the-feed motion trips it).
	if Vector2(puck_vel.x - self_vel.x, puck_vel.z - self_vel.z) \
			.length_squared() > RECEIVE_GIVE_CEILING_M_S * RECEIVE_GIVE_CEILING_M_S:
		input.brake = true
	# Aim: PARK the blade at the gate — the point where the puck's path meets our
	# reach — and let the puck arrive into it. Reuses `wall_gate` from the stance
	# solve above rather than re-walking the path for the same answer. Tracking
	# the puck's position (the
	# old aim) failed two ways: the cursor (capped at Hands blade speed ~10 m/s)
	# can't keep up with a ~20 m/s puck near the crossing, and pointing at a far
	# puck lays the stick SHAFT along the line, so the face is square to the
	# approach only in the last few ticks of a rate-limited swing. Parked at the
	# gate the shaft spans perpendicular and the face is square the whole way in.
	input.mouse_world_pos = _step_mouse_toward(wall_gate)
	return true


# The GATE: where the blade waits for an incoming loose puck — the earliest point
# on the puck's travel line the blade can touch (where the line enters a
# comfortable-extension circle around the body). Parking there beats tracking the
# puck's position: the cursor slews at Hands blade speed (~10 m/s baseline) while
# a pass sweeps past at ~20 m/s, so a blade CHASING the puck lags behind it
# through the reach envelope and the pass transits untouched. The gate itself
# moves at body speed (recomputed from self_pos each tick), which the cursor
# holds trivially — the puck arrives INTO the waiting blade. Falls back to the
# puck's own position when the puck has already passed our level (chase from
# behind) or is (near-)stationary.
func _blade_gate_on_puck_line(
		self_pos: Vector3, puck_pos: Vector3, puck_vel: Vector3) -> Vector3:
	var speed_sq: float = puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z
	if speed_sq < 0.0001:
		return puck_pos
	# Solve the gate on the puck's REAL path (caroms and friction included) —
	# see RECEIVE_PATH_* / AITrajectory.solve_reception_gate. Where the path is
	# straight this lands on the same point the old ray solve did; on a rim it
	# lands where the puck actually comes through instead of on a phantom line.
	if not AITrajectory.solve_reception_gate(puck_pos, puck_vel, self_pos,
			_receive_gate_reach(), RECEIVE_PATH_HORIZON_S, RECEIVE_PATH_STEPS):
		# No touchable point on the path. If the puck is moving AWAY right now
		# there is nothing to park for — chase it from behind, the same fallback
		# the straight-ray solve made on a negative along-distance. Otherwise
		# hold the blade toward the path's closest approach while the body
		# closes; the entry point appears once we are near enough.
		var to_self_x: float = self_pos.x - puck_pos.x
		var to_self_z: float = self_pos.z - puck_pos.z
		if puck_vel.x * to_self_x + puck_vel.z * to_self_z <= 0.0:
			return puck_pos
	# Wall kill: a gate against the boards is played with the blade ON the
	# glass, not out on the path line — see the WALL_KILL_BAND_M doc.
	return _wall_kill_aim(AITrajectory.gate_point)


# Comfortable blade extension for a parked reception: the blade span minus the
# same inset the side-stand stance uses, so the waiting blade isn't pinned at
# the IK ROM clamp (_blade_reach carries the outward pickup-check buffer —
# strip it back off).
func _receive_gate_reach() -> float:
	return maxf(_blade_reach - BLADE_REACH_BUFFER_M - RECEIVE_BODY_INSET_M, 0.4)


# The boards at `xz`: the unit INWARD normal packed in x/z, and the gap to the
# wall in y (negative off the surface). INF.y when the point is deeper in than
# the probe reaches — i.e. open ice, no wall to play.
#
# Geometry via the rink clamp rather than a per-wall distance formula, so the
# ROUNDED CORNERS come along for free — which is the half of the rink this
# matters most in. Clamping with a margin wider than the band projects the point
# onto the shrunk surface; that displacement IS the inward normal, and its
# length is (margin − gap), so one clamp call yields both. Packed into a Vector3
# because this runs on the per-tick reception path — value type, no allocation.
static func _board_normal_and_gap(xz: Vector2) -> Vector3:
	var probe_margin: float = WALL_KILL_BAND_M + 0.5
	var inward: Vector2 = GameRules.clamp_to_rink_inner(xz, probe_margin) - xz
	var inset: float = inward.length()
	if inset < 0.000001:
		return Vector3(0.0, INF, 0.0)
	return Vector3(inward.x / inset, probe_margin - inset, inward.y / inset)


# Is this point close enough to the boards that the rim is played against them?
static func _in_wall_band(xz: Vector2) -> bool:
	return _board_normal_and_gap(xz).y <= WALL_KILL_BAND_M


# Pushes a boards-hugging aim point out ONTO the inner wall surface, so the
# blade seals against the glass instead of leaving the puck a gap behind it.
# Returns `point` untouched when it isn't inside WALL_KILL_BAND_M.
static func _wall_kill_aim(point: Vector3) -> Vector3:
	var xz := Vector2(point.x, point.z)
	var board: Vector3 = _board_normal_and_gap(xz)
	if board.y > WALL_KILL_BAND_M:
		return point
	# Off the surface entirely (a phantom sample) → gap < 0 → this pulls the aim
	# back onto the wall, which is exactly where the blade belongs anyway.
	var on_wall: Vector2 = xz - Vector2(board.x, board.z) * board.y
	return Vector3(on_wall.x, 0.0, on_wall.y)


# Anticipation: is a fast loose puck (a pass) heading toward us right now? Same
# geometry as the reception steer — fast, loose, we're AHEAD of it (t > 0) and within
# the receive lateral of its line. Used to enter (and stay in) CHASE the instant a
# pass is released our way, instead of waiting to become the closest teammate to the
# puck as it arrives. At magnet pace that wait leaves no time to step square — the
# intended receiver reacts late and clatters the catch. Getting into CHASE early lets
# _pass_receive_aim_and_steer set up the squared reception in time.
func _incoming_pass_to_me(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	if snapshot == null or snapshot.puck_state == null \
			or snapshot.puck_state.carrier_peer_id != -1:
		return false
	var pv: Vector3 = snapshot.puck_state.velocity
	var speed_sq: float = pv.x * pv.x + pv.z * pv.z
	if speed_sq < RECEIVE_TRIGGER_PUCK_SPEED_M_S * RECEIVE_TRIGGER_PUCK_SPEED_M_S:
		return false
	var speed: float = sqrt(speed_sq)
	var dir := Vector3(pv.x / speed, 0.0, pv.z / speed)
	var puck_pos: Vector3 = snapshot.puck_state.position
	var to_self := Vector3(self_pos.x - puck_pos.x, 0.0, self_pos.z - puck_pos.z)
	var t: float = to_self.dot(dir)
	if t <= 0.0:
		return false
	var perp_foot: Vector3 = puck_pos + dir * t
	var perp_dx: float = self_pos.x - perp_foot.x
	var perp_dz: float = self_pos.z - perp_foot.z
	var my_d2: float = perp_dx * perp_dx + perp_dz * perp_dz
	if my_d2 > RECEIVE_TRIGGER_LATERAL_M * RECEIVE_TRIGGER_LATERAL_M:
		return false
	# Only the BEST-positioned receiver anticipates — the teammate nearest where the
	# puck crosses their level. Without this, a fast puck (a shot, or a pass to a
	# different teammate) flying within the lateral band of several bots would pull
	# them ALL toward it and out of position. Bounded scan (<= roster).
	for pid: int in snapshot.skater_states:
		if pid == _peer_id or _team_id_by_peer.get(pid, -1) != _team_id:
			continue
		var tp: Vector3 = snapshot.skater_states[pid].position
		var dx: float = tp.x - perp_foot.x
		var dz: float = tp.z - perp_foot.z
		if dx * dx + dz * dz < my_d2:
			return false
	return true


# Shot-aware reception decision (see the SHOT_RECEPTION_* constant block).
# Returns one of the _RECV_* codes:
#   _RECV_NONE         — not a shot reception; caller runs the normal catch.
#   _RECV_CATCH_STRIDE — Mode B: aim+steer set here (net-ward catch); caller
#                        falls through to the chase transitions (have_puck →
#                        CARRY, which then takes the in-stride/closer shot).
#   _RECV_ONE_TIME     — Mode A: transitioned to ONE_TIMER_PRESSED with a
#                        moving anchor; caller must return.
func _try_shot_reception(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3) -> int:
	var puck_state: PuckNetworkState = snapshot.puck_state
	# Only loose pucks are receivable; held pucks aren't a pass to catch.
	if puck_state.carrier_peer_id != -1:
		return _RECV_NONE
	var puck_vel: Vector3 = puck_state.velocity
	var puck_speed_sq: float = puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z
	if puck_speed_sq < RECEIVE_TRIGGER_PUCK_SPEED_M_S * RECEIVE_TRIGGER_PUCK_SPEED_M_S:
		return _RECV_NONE
	var puck_speed: float = sqrt(puck_speed_sq)
	var puck_dir: Vector3 = Vector3(puck_vel.x / puck_speed, 0.0, puck_vel.z / puck_speed)
	var puck_pos: Vector3 = puck_state.position
	# Foot of perpendicular from self onto the puck's path. t > 0: the puck
	# still has to travel to reach our level (it's coming to us). t <= 0: it's
	# already past — not a reception, let the normal chase run it down.
	var to_self: Vector3 = self_pos - puck_pos
	to_self.y = 0.0
	var t: float = to_self.dot(puck_dir)
	if t <= 0.0:
		return _RECV_NONE
	var perp_foot: Vector3 = puck_pos + puck_dir * t
	var perp_off: Vector3 = self_pos - perp_foot
	perp_off.y = 0.0
	if perp_off.length() > RECEIVE_TRIGGER_LATERAL_M:
		return _RECV_NONE
	# Is a shot from the catch point on? A fire-on-contact redirect gives the goalie
	# no slide time, so score it at his CURRENT position (goalie_now) and the soft
	# redirect pace (PASS_SPEED_M_S). This one gate also encodes "in shooting range
	# with a real look" (score_shoot folds in range / angle / lane / goalie).
	# Budget this bot's own shot spread like every scored shot — a one-timer is
	# the WORST-controlled release there is, so a wobbly-handed tier demands a
	# wider opening before committing to fire-on-contact.
	_gather_opponents(snapshot, _scratch_shot_opponents, _scratch_shot_opponent_caps)
	var goalie_now: Vector3 = _goalie_now(snapshot)
	var shot_score: float = AIActionScoring.score_shoot(
			perp_foot, _attacking_goal_pos, goalie_now,
			GameRules.NET_HALF_WIDTH, _scratch_shot_opponents,
			AIActionScoring.PASS_SPEED_M_S, 0.0, _scratch_shot_opponent_caps,
			-1.0, false, 0.0, false, _shot_aim_error_rad)
	if shot_score < SHOT_RECEPTION_SCORE_GATE:
		return _RECV_NONE
	# Net-forward geometry. Anchor = the catch point pulled back one blade-reach
	# AWAY from the net, so when the bot stands there its net-pointing blade
	# meets the puck at perp_foot and the puck arrives net-FORWARD of the body
	# (aiming there keeps facing net-ward, never turning to grab).
	var to_net: Vector3 = _attacking_goal_pos - perp_foot
	to_net.y = 0.0
	var net_len: float = to_net.length()
	if net_len < 0.001:
		return _RECV_NONE
	var net_dir: Vector3 = to_net / net_len
	var anchor: Vector3 = perp_foot - net_dir * _blade_reach
	# Mode A (one-time) eligibility: lateral redirect (in the band), forehand
	# side, far enough out, and not already driving hard at the net.
	var redirect_angle: float = acos(clampf(puck_dir.dot(net_dir), -1.0, 1.0))
	# Left of the net direction (up × net_dir). A left-handed shooter's forehand
	# is on the left, right-handed on the right (matches _handedness_perp_sign:
	# RH forehand sweeps to skater-local +X / right). "Right of net_dir" is
	# -left_dir, so RH forehand = -left_dir, LH forehand = +left_dir.
	var left_dir: Vector3 = Vector3(net_dir.z, 0.0, -net_dir.x)
	var forehand_dir: Vector3 = left_dir if _is_left_handed else -left_dir
	var from_forehand: bool = (puck_pos - self_pos).dot(forehand_dir) > 0.0
	var self_vel: Vector3 = Vector3.ZERO
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state != null:
		self_vel = self_state.velocity
	var net_ward_speed: float = self_vel.dot(net_dir)
	# Squared-up gate: the redirect locks its direction at the press tick, so the
	# body must already be facing near the shot line or it fires wonky. When we
	# can't square up in time, Mode A is off and the caller catches it (Mode B).
	var squared_up: bool = true
	if self_state != null and self_state.facing.length_squared() > 0.0001:
		var net_aim: Vector3 = _shot_aim_point(snapshot, self_pos, 0.0)
		var aim_dir := Vector2(net_aim.x - self_pos.x, net_aim.z - self_pos.z)
		if aim_dir.length_squared() > 0.0001:
			squared_up = absf(self_state.facing.angle_to(aim_dir)) <= ONE_TIME_MAX_SQUARE_UP_RAD
	var mode_a: bool = (redirect_angle >= ONE_TIME_MIN_REDIRECT_RAD
			and redirect_angle <= ONE_TIME_MAX_REDIRECT_RAD
			and from_forehand
			and net_len >= ONE_TIME_MIN_NET_DIST_M
			and net_ward_speed <= ONE_TIME_MAX_DRIVE_SPEED_M_S
			and squared_up)
	if mode_a:
		# One transitional tick of net-aimed steering before ONE_TIMER_PRESSED
		# takes over next dispatch (it presses slap on its tick 0 and settles
		# on the live line itself — no latched anchor to hand over).
		_apply_steering(input, snapshot, self_pos, anchor)
		input.mouse_world_pos = _step_mouse_toward(_shot_aim_point(snapshot, self_pos, 0.0))
		_set_state(State.ONE_TIMER_PRESSED)
		return _RECV_ONE_TIME
	# Mode B: catch in a net-ward posture. Steer to the net-forward anchor so the
	# puck arrives between us and the net, and PARK the blade at the gate — the
	# earliest point of the puck's line the blade can touch (see
	# _blade_gate_on_puck_line; tracking the puck's position loses the race to a
	# ~20 m/s feed). The gate sits on the puck's line net-ward of the anchored
	# body, so aiming at it still keeps facing net-ward (no turn-to-grab). No
	# brake — keep momentum to drive in (which also cushions a straight feed,
	# #373's relative frame). On contact the bot enters CARRY already net-facing,
	# so the follow-up shot needs no reorientation; near the net the carrier
	# scorer takes the quick pass.
	_apply_steering(input, snapshot, self_pos, anchor)
	input.mouse_world_pos = _step_mouse_toward(
			_blade_gate_on_puck_line(self_pos, puck_pos, puck_vel))
	return _RECV_CATCH_STRIDE


# Fills `out` with opposing-team skater positions. Cheap (≤3 opponents); used by
# the shot-quality check in _try_shot_reception.
func _gather_opponents(snapshot: WorldSnapshot, out: Array[Vector3],
		out_caps: Array[AISkaterCaps]) -> void:
	out.clear()
	out_caps.clear()
	for pid: int in snapshot.skater_states:
		if pid == _peer_id:
			continue
		if _team_id_by_peer.get(pid, -1) != _team_id:
			out.append(snapshot.skater_states[pid].position)
			out_caps.append(_caps_by_peer.get(pid))


func _state_carry(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	if not have_puck:
		_carrier.reset()
		_intended_action = State.CARRY
		_intent_wait_ticks = 0
		_pass_target_peer_id = -1
		_pass_should_charge = false
		_pass_should_saucer = false
		_shot_loft_level = ShotMechanics.ELEVATION_FLAT
		_shot_aim_locked = Vector3.INF
		_shot_power_committed = 1.0
		_shot_release_offset_locked = Vector3.ZERO
		_locked_pre_aim_point = Vector3.INF
		_dump_target = Vector3.INF
		_set_state(_post_puck_lost_state(snapshot))
		return

	# Run the carrier role behavior. Internally throttled at
	# PICK_ACTION_PERIOD_TICKS — between re-evals it returns the
	# cached intent + last_carry_anchor unchanged. Mirror its public
	# fields back into the state machine so press states (SHOOT /
	# PASS) and pre-aim convergence keep their existing reading
	# patterns.
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	var ctx: RoleContext = _build_role_context(snapshot, self_pos, self_state)
	_carrier.decide(ctx)

	# Support state from the carrier propagates every tick — press
	# states (SHOOT / PASS) and pre-aim convergence read these and
	# they need to stay fresh.
	_last_carry_anchor = _carrier.last_carry_anchor
	_pass_target_peer_id = _carrier.pass_target_peer_id
	_pass_should_charge = _carrier.pass_should_charge
	_pass_target_speed = _carrier.pass_target_speed
	_pass_should_saucer = _carrier.pass_should_saucer
	# Shot params are the ONE thing that must NOT keep tracking the carrier once a
	# fire intent is latched. The intent gate below already holds the INTENT through
	# pre-aim (a jagged score can't flip it back to CARRY); freezing the aim + loft
	# the moment we commit does the same for the SHOT itself, so the bot performs the
	# exact shot that won the compete, not whatever a later re-eval would have
	# picked. Only refresh while still deliberating (_intended_action == CARRY);
	# after commit the last-written values ride through pre-aim and the charge.
	if _intended_action == State.CARRY:
		_shot_loft_level = _carrier.shot_loft_level
		_shot_aim_locked = _carrier.shot_aim_point
		_shot_power_committed = _carrier.shot_power_t
		_shot_release_offset_locked = _carrier.shot_release_offset
		# Freeze the dump target the same way — captured at commit, held through
		# pre-aim and the release. (The always-fresh mirror above resets the pass
		# fields every tick; the dump carries its aim in _dump_target instead, so
		# a stale _pass_target_peer_id can't hijack a dump — _pass_aim_point reads
		# _dump_target first.)
		if _carrier.intended_action == AIRoleCarrier.INTENT_DUMP:
			_dump_target = _carrier.dump_target
			_dump_is_soft = _carrier.dump_is_soft
			_dump_is_rim = _carrier.dump_is_rim
		else:
			_dump_target = Vector3.INF
	debug_shoot_score = _carrier.debug_shoot_score
	debug_pass_score = _carrier.debug_pass_score
	debug_pass_peer_id = _carrier.debug_pass_peer_id
	debug_carry_score = _carrier.debug_carry_score
	debug_carry_pos = _carrier.debug_carry_pos

	# Intent transitions are gated on "currently in CARRY." Once a
	# fire intent (SHOOT / PASS) is selected we hold it
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
				State.SHOOT_PRESSED:
					# Prefer the carrier's locked hole aim so pre-aim faces the
					# exact hole the charge will shoot at (no side-flip wiggle).
					_locked_pre_aim_point = (_shot_aim_locked
							if _shot_aim_locked.is_finite()
							else _shot_aim_point(snapshot, self_pos))
				State.PASS_PRESSED:
					_locked_pre_aim_point = _pass_aim_point(snapshot, self_pos)
		_intended_action = new_intent

	# Steering depends on which action is locked.
	#
	# CARRY: drift toward the carry destination.
	#
	# SHOOT_PRESSED pre-aim: steer toward the projected release
	# position so the bot keeps moving on the rush. Continuous-aim
	# (_carry_aim_track_fire) keeps pre-aim near 0 ms in normal
	# play — the goalie-pickup-mid-pre-aim risk only existed when
	# pre-aim was long, and continuous-aim is the proper fix for
	# that. Brake-during-pre-aim was the workaround we no longer
	# need.
	#
	# PASS_PRESSED: brake. Pass leads aim from a held spot.
	if _intended_action == State.CARRY:
		# Velocity-matched seek (match speed = our top speed): the carry anchor
		# pull cancels cross-momentum instead of pure-seeking, so a carrier
		# drifting cross-ice redirects onto a central carry point rather than
		# orbiting past it (see AISteering velocity-matched seek). Skated through
		# at pace — no deceleration.
		_apply_steering(input, snapshot, self_pos, _last_carry_anchor,
				false, _self_max_speed)
		# Discrete "deke moment" on top of continuous body steering:
		# brief perpendicular cut away from an imminent poke threat.
		# Pre-aim states (SHOOT/PASS pending) skip this — they have
		# their own steering targets that the cut would override.
		_poke_evade_modulate_steering(input, snapshot, self_pos)
		# Breakaway burst: a carrier only sprints with a clear lane to the net
		# (carrying drains stamina ~1.6× faster and the wide turn radius wrecks
		# dangling, so it's reckless in traffic). Resolved after the poke-evade
		# cut so the turn gate sees the real heading. Pre-aim / shot / pass
		# branches below never sprint — sprint_held stays false (zeroed each
		# tick), so a wind-up is always at full agility.
		_resolve_sprint(input, self_state, self_pos, _last_carry_anchor,
				true, _carry_has_open_lane(snapshot, self_pos))
	elif _intended_action == State.SHOOT_PRESSED:
		var hv: Vector3 = Vector3.ZERO
		if self_state != null:
			hv = Vector3(self_state.velocity.x, 0.0, self_state.velocity.z)
		_apply_steering(input, snapshot, self_pos,
				self_pos + hv * BOT_WRISTER_LOOKAHEAD_S)
	else:
		_apply_brake_steering(input, snapshot, self_pos)

	# Mouse target depends on intent: carry uses normal goal-aim (or the
	# deke's committed sell-and-snap while that maneuver is live), fire
	# states pre-aim toward action direction.
	var mouse_target: Vector3
	if _intended_action == State.CARRY:
		# Pure carry: cursor factored into _step_carry_cursor so the throttle's
		# skipped-tick path re-derives it every physics tick (the carry blade then
		# tracks the protect seam / stickhandle offset / square-up continuously
		# instead of staircasing at the ~20 Hz dispatch rate).
		_step_carry_cursor(input, snapshot, self_pos, self_state)
	else:
		mouse_target = _aim_target_for_intent(snapshot, self_pos)
		# ARC pre-aim swing: the convergence/commit logic below reads the arc; the
		# cached FINAL mouse_target drives the convergence check so the bot fires
		# only when the body has reached the real aim. (A pure CARRY front reach
		# steps DIRECT instead — see _step_carry_cursor.)
		input.mouse_world_pos = _step_mouse_aim(mouse_target)

	# If pre-aiming, wait for mouse convergence (or timeout) before
	# transitioning to the action state. Body facing is no longer
	# gated: the arc-step in _step_mouse_toward keeps the mouse on
	# the carry aim ring around the bot so the angle to facing stays inside
	# the blade ROM regardless of body rotation lag, which is what
	# the old facing-alignment gate was guarding against.
	if _intended_action != State.CARRY:
		# Distance in XZ only — mouse_pos is forced to y=0 in
		# _step_mouse_toward but _aim_target_for_intent inherits
		# self_pos.y (~1.0). A 3D distance would carry that constant
		# y-mismatch and never reach AIM_CONVERGED_DIST_M = 0.10,
		# so pre-aim would silently time out every time. Rink is
		# flat, only XZ matters.
		var dx: float = _mouse_pos.x - mouse_target.x
		var dz: float = _mouse_pos.z - mouse_target.z
		var aim_dist: float = sqrt(dx * dx + dz * dz)
		var aim_converged: bool = aim_dist < AIM_CONVERGED_DIST_M
		# Commit-then-aim (Aim-B2): if the aim already sits inside the blade reach
		# cone of the CURRENT facing, the blade can swing to it with the body frozen
		# — commit to the charge NOW instead of arcing the mouse (and dragging the
		# body) all the way around to it. This is what stops the bot pivoting its
		# whole body toward a reachable lateral pass / off-wing shot. Back-wedge aims
		# (outside the cone) fail this and fall through to the arc-and-converge path,
		# which rotates the body just until the aim swings into the cone and then
		# this fires. self_state guards a rare null snapshot entry (keep old timing).
		var aim_reachable_no_turn: bool = self_state != null and _aim_needs_no_rotation(
				self_state.facing,
				Vector2(mouse_target.x - self_pos.x, mouse_target.z - self_pos.z))
		if aim_converged or aim_reachable_no_turn \
				or _intent_wait_ticks >= _intent_max_wait_ticks:
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
			# Advance by the dispatch span, not 1: this runs once per dispatch but
			# _intent_max_wait_ticks is sized in physics ticks, so a per-run +1 would
			# stretch the pre-aim bail timeout by the dispatch period at low tiers.
			_intent_wait_ticks += _dispatch_period_ticks


# True when `aim_dir` (world XZ, from the bot to its aim point) already falls
# inside the blade reach cone of `facing` MINUS the commit safety margin — i.e.
# the blade can reach the aim with the body's heading frozen, so no pre-aim body
# rotation is needed (Aim-B2). Cone + margin are the bot's real, attribute-scaled
# reach (`_self_reach_cone_half_angle`, threaded from AISkaterCaps) less
# AIM_COMMIT_CONE_MARGIN_RAD headroom for the wind-up sweep / torso twist. Pure
# geometry — unit-tested directly.
func _aim_needs_no_rotation(facing: Vector2, aim_dir: Vector2) -> bool:
	if facing.length_squared() < 0.0001 or aim_dir.length_squared() < 0.0001:
		return false
	var angle: float = abs(facing.angle_to(aim_dir))
	return angle <= maxf(_self_reach_cone_half_angle - AIM_COMMIT_CONE_MARGIN_RAD, 0.0)


# Maps the carrier's INTENT_* enum (intentionally decoupled from
# State for unit testing) back into the state machine's State enum.
func _state_from_carrier_intent(intent: int) -> State:
	match intent:
		AIRoleCarrier.INTENT_SHOOT:
			return State.SHOOT_PRESSED
		AIRoleCarrier.INTENT_PASS:
			return State.PASS_PRESSED
		AIRoleCarrier.INTENT_DUMP:
			# A dump is a pass to a LOCATION (no receiver) — reuse the PASS_PRESSED
			# release path; _dump_target (finite) redirects the aim and the bail.
			return State.PASS_PRESSED
		_:
			return State.CARRY


# Returns the mouse target (in world XZ) the bot should be aiming at
# while pre-aiming for `_intended_action`. Always one ring radius out in the
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
			return _aim_ring_toward(self_pos, target)
		State.SHOOT_PRESSED:
			var target: Vector3 = (_locked_pre_aim_point
					if _locked_pre_aim_point.is_finite()
					else _shot_aim_point(snapshot, self_pos))
			return _aim_ring_toward(self_pos, target)
		_:
			return _carry_mouse_aim(snapshot, self_pos)


# Returns a point on the carry aim ring (CARRY_BLADE_AIM_FORWARD_M) from
# `self_pos` heading toward `aim_world`. Used
# to put the mouse close to the bot in the correct DIRECTION for an
# upcoming shot/pass, so it converges quickly under the motion model.
# This is a PRE-AIM target only. It is safe to collapse the distance here
# because the charged release rebuilds its own cursor from the wind-up
# endpoints and takes its direction from the charge drag — but it is NOT a
# usable release cursor: release_wrister's is_quick_pass branch aims
# blade→cursor, and the blade is the ROM-projection of that same cursor, so
# a cursor this close to the body carries no direction at all (see the snap
# in _state_pass_pressed's one-tick branch).
#
# Returns the FINAL aim point — the pre-aim convergence check
# (`_state_carry`) compares the mouse against this to decide when to
# fire, so it must be the final destination, not an intermediate
# arc step. `_arc_step_mouse_target` is what threads the mouse target
# around self_pos on the way here.
func _aim_ring_toward(self_pos: Vector3, aim_world: Vector3) -> Vector3:
	var to_aim: Vector3 = aim_world - self_pos
	to_aim.y = 0.0
	if to_aim.length_squared() < 0.0001:
		# Fall back to the attacking direction (team-aware). Vector3.FORWARD
		# is (0, 0, -1), which is correct for team 0 but inverts for team 1.
		return self_pos + Vector3(0.0, 0.0, -_own_goal_dir) * CARRY_BLADE_AIM_FORWARD_M
	return self_pos + to_aim.normalized() * CARRY_BLADE_AIM_FORWARD_M


# ── Protect-side turn ────────────────────────────────────────────────────────
# A carrier's turn-around sweeps the puck along the arc the mouse walks. The
# SHORT way around may drag the puck straight through a defender's poke reach
# while the LONG way keeps the body between the puck and the pressure — a real
# carrier turns away from the checker even when it's the longer rotation. When
# a big swing starts, both sweep sides are read at their midpoint (worst point
# of the sweep, at the blade's own orbit radius) against the nearest opposing
# blade; the long way is taken iff the short side is inside poke threat and the
# long side is meaningfully clearer. The choice COMMITS (sign latched) until
# the swing passes halfway (shortest direction agrees) or completes — an
# uncommitted per-tick re-read would flip direction mid-sweep and shimmy.
const PROTECT_TURN_MIN_SWING_RAD: float = deg_to_rad(100.0)
# A stick's poke reach off the swept puck — inside this, the short sweep is a
# strip waiting to happen (mirrors POKE_EVADE_TRIGGER_REACH_M's read).
const PROTECT_TURN_THREAT_RADIUS_M: float = 2.5
# The long way must beat the short way's clearance by this much — a marginal
# gain isn't worth the extra rotation time.
const PROTECT_TURN_MARGIN_M: float = 0.5
# Committed long-way sweep sign; 0.0 = no commitment (shortest way).
var _arc_protect_sign: float = 0.0


# The sweep sign for a carry-arc swing of `diff` (wrapped desired−current):
# signf(diff) (shortest way) unless the short sweep drags the puck into poke
# threat and the long sweep is meaningfully clearer. Pure read, no state —
# _arc_step_mouse_target owns the commitment.
func _protect_turn_direction(self_pos: Vector3, current_angle: float,
		diff: float, snapshot: WorldSnapshot) -> float:
	var short_sign: float = signf(diff)
	if snapshot == null:
		return short_sign
	var short_mid: float = current_angle + diff * 0.5
	var short_puck := Vector3(
			self_pos.x + sin(short_mid) * _blade_reach, 0.0,
			self_pos.z + cos(short_mid) * _blade_reach)
	var short_clear: float = _nearest_opponent_blade_dist(snapshot, short_puck)
	if short_clear >= PROTECT_TURN_THREAT_RADIUS_M:
		return short_sign
	var long_mid: float = current_angle + (diff - short_sign * TAU) * 0.5
	var long_puck := Vector3(
			self_pos.x + sin(long_mid) * _blade_reach, 0.0,
			self_pos.z + cos(long_mid) * _blade_reach)
	var long_clear: float = _nearest_opponent_blade_dist(snapshot, long_puck)
	if long_clear > short_clear + PROTECT_TURN_MARGIN_M:
		return -short_sign
	return short_sign


# Distance from `point` to the nearest opposing blade (body position when the
# blade telemetry isn't populated yet). Pure read over the roster; no allocation.
func _nearest_opponent_blade_dist(snapshot: WorldSnapshot, point: Vector3) -> float:
	var nearest: float = INF
	for peer_id: int in _opponent_ids(snapshot):
		var opp_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		var threat_pos: Vector3 = opp_state.blade_contact_world
		if threat_pos == Vector3.ZERO:
			threat_pos = opp_state.position
		var dx: float = threat_pos.x - point.x
		var dz: float = threat_pos.z - point.z
		var d: float = sqrt(dx * dx + dz * dz)
		if d < nearest:
			nearest = d
	return nearest


# Is the desired blade direction in the body's BACK hemisphere (>90° off the
# current facing)? Gates the long-way protect orbit to genuine turn-arounds. A
# null/degenerate facing returns false — bias toward the short-way reach, never
# an unprovoked spin.
func _target_is_behind(desired_dir: Vector3, self_state: SkaterNetworkState) -> bool:
	if self_state == null or self_state.facing.length_squared() < 0.0001:
		return false
	var facing: Vector2 = self_state.facing.normalized()
	return desired_dir.x * facing.x + desired_dir.z * facing.y < 0.0


# Returns an intermediate mouse target on the carry aim ring around self_pos
# that walks toward `final_target` at no more than MOUSE_ARC_RATE_RAD_S.
# See MOUSE_ARC_RATE_RAD_S comment for why arcing is required — straight
# chords across a 180° swing pass through self_pos and trip the IK gate.
# `_step_mouse_toward`'s straight-line lerp tracks this slowly-moving
# target with sub-tick error, so the mouse describes the same arc.
func _arc_step_mouse_target(self_pos: Vector3, final_target: Vector3,
		self_state: SkaterNetworkState, arc_rate: float) -> Vector3:
	var to_final: Vector3 = final_target - self_pos
	to_final.y = 0.0
	if to_final.length_squared() < 0.0001:
		return final_target
	var desired_dir: Vector3 = to_final.normalized()

	# Seed the current angle from the mouse's current offset from self_pos
	# when it's far enough away to define a direction unambiguously (the
	# typical case — the mouse is held a ring radius out by previous calls). Fall
	# back to facing when the mouse is parked on top of self_pos (e.g. the
	# danger-zone cradle in `_carry_mouse_aim`); seeding from facing rather
	# than snapping to desired_dir keeps the next-tick chord from crossing
	# self_pos when desired_dir points behind the bot.
	var current_offset := Vector2(_mouse_pos.x - self_pos.x, _mouse_pos.z - self_pos.z)
	var seed_dir: Vector3
	if _mouse_pos_initialized and current_offset.length_squared() >= 0.04:
		seed_dir = Vector3(current_offset.x, 0.0, current_offset.y).normalized()
	elif self_state != null \
			and Vector2(self_state.facing.x, self_state.facing.y).length_squared() > 0.0001:
		seed_dir = Vector3(self_state.facing.x, 0.0, self_state.facing.y).normalized()
	else:
		seed_dir = desired_dir

	var current_angle: float = atan2(seed_dir.x, seed_dir.z)
	var desired_angle: float = atan2(desired_dir.x, desired_dir.z)
	var diff: float = wrapf(desired_angle - current_angle, -PI, PI)
	var max_step: float = arc_rate * MOUSE_TICK_DELTA
	# Protect-side turn (carriers only — see PROTECT_TURN_*): pick which way a
	# big swing sweeps the puck, latch it, and hold it until the shortest way
	# agrees (swung past halfway) or the swing completes.
	if _state != State.CARRY:
		_arc_protect_sign = 0.0
	elif _arc_protect_sign != 0.0:
		if signf(diff) == _arc_protect_sign or absf(diff) <= max_step:
			_arc_protect_sign = 0.0
	elif absf(diff) >= PROTECT_TURN_MIN_SWING_RAD and _target_is_behind(desired_dir, self_state):
		# Long-way orbit only for a genuine TURN-AROUND — the desired blade spot is
		# behind the body (a regroup, an anchor that flipped after a re-eval). There
		# the big rotation is unavoidable, so sweep the puck the way that keeps the
		# body shielding it. A FRONT-hemisphere target is a protect REACH, not a
		# turn: take the short way and let the blade's ROM extend across the front,
		# rather than spinning the long way around the back to reach a spot that's
		# only off to the side. Reach, not orbit — keeps the carrier square to the
		# play (see CARRY_PROTECT_MAX_TURN_DEG, which caps that reach at side-on).
		var protect_sign: float = _protect_turn_direction(
				self_pos, current_angle, diff, _current_snapshot)
		if protect_sign != signf(diff):
			_arc_protect_sign = protect_sign
	var stepped_angle: float
	if _arc_protect_sign != 0.0:
		stepped_angle = current_angle + _arc_protect_sign * max_step
	else:
		stepped_angle = current_angle + clampf(diff, -max_step, max_step)
	return self_pos + Vector3(sin(stepped_angle), 0.0, cos(stepped_angle)) * CARRY_BLADE_AIM_FORWARD_M


# FACE-mode cursor placement: a point on the body ring in the direction the bot
# wants to point, but CLAMPED into the reachable cone (_self_reach_cone_half_angle
# − FACE_GATE_MARGIN_RAD) of its current facing. Inside the cone the cursor points
# straight at the target (the body turns to it at facing_drag_speed); in the back
# wedge it's clamped to the cone edge on the target's side, so facing rotates to
# that edge without the pose IK gate freezing, the target's relative angle shrinks
# as the body turns, and the clamp releases — the bot walks all the way around.
func _clamp_aim_to_reach_cone(self_pos: Vector3, target: Vector3,
		self_state: SkaterNetworkState) -> Vector3:
	var to_target := Vector2(target.x - self_pos.x, target.z - self_pos.z)
	if to_target.length_squared() < 0.0001:
		return target
	var target_dir: Vector2 = to_target.normalized()
	var facing := Vector2(0.0, 1.0)
	if self_state != null and self_state.facing.length_squared() > 0.0001:
		facing = self_state.facing.normalized()
	var ang: float = facing.angle_to(target_dir)
	var gate: float = maxf(_self_reach_cone_half_angle - FACE_GATE_MARGIN_RAD, 0.0)
	var out_dir: Vector2 = target_dir if absf(ang) <= gate \
			else facing.rotated(signf(ang) * gate)
	return self_pos + Vector3(out_dir.x, 0.0, out_dir.y) * CARRY_BLADE_AIM_FORWARD_M


func _state_shoot_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lost the puck mid-charge — bail. SkaterStateMachine's release path
	# is a no-op without the puck, so we don't need to force a release.
	if not have_puck:
		_set_state(_post_puck_lost_state(snapshot))
		return

	# Mid-charge bail on a body check: a hit landed while winding up knocks
	# the bot off-balance (stagger_timer set), so cancel the charge rather
	# than flail a shot through it. Any-direction (a hit from behind staggers
	# too), unlike the forward-only opponent bail below.
	var charge_self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if _shoot_charge_tick > 0 and charge_self_state != null \
			and charge_self_state.stagger_timer > 0.0:
		input.slap_pressed = true
		_set_state(State.CARRY)
		return

	# Mid-charge bail: opponent closing in from the front. slap_pressed (the
	# other shot button) cancels WRISTER_AIM back to SKATING_WITH_PUCK without a
	# release. Skipped on tick 0 — we just made the decision, give it at least
	# one frame to commit. Forward-only check: a defender behind the
	# shooter (between us and our own net) can't realistically disrupt a
	# wrister windup, and bailing on them was throwing away clean shots
	# any time a backchecker happened to be within 2 m. Matches the
	# pressure cube falloff intuition (behind/sideways = not a threat).
	if _shoot_charge_tick > 0 and _opponent_within_forward(
			snapshot, self_pos, _attacking_goal_pos - self_pos,
			BOT_WRISTER_BAIL_RADIUS_M):
		input.slap_pressed = true
		_set_state(State.CARRY)
		return

	# Lock the steering destination ONCE at charge start. The projected
	# release position (current + velocity × wrister_lookahead) is the spot
	# the carrier scorer assumed and what won SHOOT over CARRY, so a rush
	# wrister should arrive THERE rather than braking back to commit pos.
	# Capturing it once (not recomputing from live velocity every tick) gives
	# the body a STABLE anchor for the wind-up — the per-tick recompute was
	# self-referential (the target moved with the bot's own heading), so the
	# repulsion fields had nothing fixed to settle against and wandered the
	# body: the wind-up wobble. See _shoot_release_anchor.
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if _shoot_charge_tick == 0:
		var hv0: Vector3 = Vector3.ZERO
		if self_state != null:
			hv0 = Vector3(self_state.velocity.x, 0.0, self_state.velocity.z)
		_shoot_release_anchor = self_pos + hv0 * BOT_WRISTER_LOOKAHEAD_S
		_shoot_wind_up_moving = hv0.length() > BOT_WRISTER_PLANT_SPEED_M_S
	# Moving (rush) wrister: steer to the locked anchor so it fires from the
	# scored spot in stride. Near-still wrister: plant (brake in place) like a
	# charged pass — a stationary bot has no release spot to skate to, so any
	# steering just invites the repulsion-field wobble.
	if _shoot_wind_up_moving:
		_apply_steering(input, snapshot, self_pos, _shoot_release_anchor)
	else:
		_apply_brake_steering(input, snapshot, self_pos)
	# Loft the release to the aimed hole's height (FLAT / LOW / HIGH). The level
	# is absolute per input frame (flat default in _zero_input), so just set it
	# on every charge tick through the release.
	input.elevation_level = _shot_loft_level

	# First tick: capture aim, compute wind-up start (forehand side,
	# behind bot), fire shoot_pressed edge so SkaterStateMachine enters
	# WRISTER_AIM. The forehand/backhand read is the sticky carry face
	# (Skater._carry_side), advanced every tick from the blade pose — so
	# mouse_world_pos must be at the wind-up position THIS tick so
	# apply_blade_from_mouse (still running in SKATING_WITH_PUCK before
	# the transition) keeps the blade — and the carried face — on the
	# forehand side through the wind-up.
	if _shoot_charge_tick == 0:
		debug_last_decision = "SHOOT"
		# Project the release position forward by BOT_WRISTER_LOOKAHEAD_S
		# so the locked aim direction is the one that hits the chosen
		# aim point from where the bot will ACTUALLY BE at release, not
		# from where it is right now. With endpoint OFFSETS (relative to
		# self_pos) the lerp follows the bot's locomotion automatically,
		# but the AIM DIRECTION still needs projecting — a bot rushing
		# laterally at 3 m/s during the 250 ms charge moves ~0.75 m
		# sideways, and without projection the locked aim would be
		# computed from the commit position, not the release position,
		# easily missing past the post on a corner shot. Goalie prediction
		# inside `_shoot_aim_dir` already used the wrister lookahead, so
		# anchoring the aim_dir lookup on the projected release matches.
		# Same projected release the steering anchor uses — captured just above
		# this tick, so reuse it rather than recomputing the projection — PLUS
		# the committed release offset: the blade carries the puck to the
		# sampled spot, so that's where the shot actually leaves from.
		var release_pos: Vector3 = _shoot_release_anchor + _shot_release_offset_locked
		# Read aim_point directly (not just direction) so we can pass aim
		# distance into _wind_up_endpoint_offsets for side-offset compensation.
		# Prefer the carrier's locked hole aim — the exact hole the shot's score
		# and loft were picked for — so the shot goes where it was evaluated. The
		# aim POINT is fixed on the net plane; the direction is still taken from
		# the current release_pos, so it tracks the bot's own locomotion. Falls
		# back to the continuous geometry aim if no hole was locked.
		var aim_point: Vector3 = (_shot_aim_locked
				if _shot_aim_locked.is_finite()
				else _shot_aim_point(snapshot, release_pos))
		var aim_vec: Vector3 = Vector3(aim_point.x - release_pos.x, 0.0, aim_point.z - release_pos.z)
		# This release's committed execution error (sampled at press entry):
		# rotate the whole aim frame once, so the windup sweeps cleanly to a
		# slightly-wrong spot and the release direction carries the error.
		if _committed_aim_error_rad != 0.0:
			aim_vec = aim_vec.rotated(Vector3.UP, _committed_aim_error_rad)
		var aim_dir_init: Vector3 = aim_vec.normalized() if aim_vec.length_squared() > 0.0001 else Vector3(0.0, 0.0, 1.0)
		var aim_distance: float = aim_vec.length()
		# Lock the committed shot direction for the charge — the controller aims the
		# positional wrister along this directly (bot_wrister_aim_dir below).
		_shoot_aim_dir_locked = aim_dir_init
		# aim_dir is captured once into the wind-up endpoint offsets below
		# and held for the charge. A shuffling goalie cannot flip the
		# chosen arc mid-swing because the endpoint offsets are frozen at
		# tick 0; no per-tick aim recompute exists.
		var forehand_perp_init: Vector3 = Vector3(
				aim_dir_init.z * _handedness_perp_sign, 0.0, -aim_dir_init.x * _handedness_perp_sign)

		# Pick wind-up side. A committed release offset OWNS the side: the
		# sampler already priced its lateral side (a backhand-side offset was
		# scored at backhand pace), so the sweep must run on that side for the
		# chirality classifier to charge the same shot — poke-avoidance must
		# not flip it to the opposite side of a relocation the score depends
		# on. Otherwise forehand by default, flipped to backhand if a defender
		# is within stick reach AND clearly on the forehand side — they'd poke
		# the puck off a forehand wind-up. Locked for the charge so no
		# mid-swing oscillation.
		var offset_side_dot: float = _shot_release_offset_locked.x * forehand_perp_init.x \
				+ _shot_release_offset_locked.z * forehand_perp_init.z
		if _shot_release_offset_locked.length_squared() > 0.0001:
			_shoot_side_sign = 1.0 if offset_side_dot >= 0.0 else -1.0
		else:
			_shoot_side_sign = 1.0
			for peer_id: int in snapshot.skater_states:
				if peer_id == _peer_id:
					continue
				if _team_id_by_peer.get(peer_id, -1) == _team_id:
					continue
				var opp_pos: Vector3 = snapshot.skater_states[peer_id].position
				var rel_x: float = opp_pos.x - self_pos.x
				var rel_z: float = opp_pos.z - self_pos.z
				var rel_len_sq: float = rel_x * rel_x + rel_z * rel_z
				# THIS defender's poke reach — his real stick + the overhang
				# buffer, league fallback when his build isn't wired.
				var opp_caps: AISkaterCaps = _caps_by_peer.get(peer_id)
				var reach: float = BOT_FOREHAND_STICK_REACH_M if opp_caps == null \
						else opp_caps.stick_reach + BOT_POKE_REACH_BUFFER_M
				if rel_len_sq > reach * reach:
					continue
				var forehand_dot: float = rel_x * forehand_perp_init.x + rel_z * forehand_perp_init.z
				if forehand_dot > BOT_FOREHAND_LATERAL_THRESHOLD_M:
					_shoot_side_sign = -1.0
					break

		# Wind-up endpoint OFFSETS captured at tick 0 (relative to self_pos)
		# and held constant for the charge. Sized to the COSMETIC wind-up span
		# (power rides bot_wrister_power_t, not this distance) — a full-power
		# shot draws the whole span. Each tick the lerp is anchored at CURRENT
		# self_pos so the endpoints float with the bot — both world positions
		# move forward at the bot's locomotion speed, leaving the blade's
		# rel-skater motion as pure aim_dir lerp at the target rate. The
		# committed release offset translates BOTH endpoints (the sweep runs
		# through the sampled spot; direction — and thus the shot — unchanged),
		# and the blade drags the puck there over the charge's early ticks, the
		# blade-travel time the sampler priced into the goalie's budget.
		var shot_span: float = BOT_WRISTER_WIND_UP_SPAN_M * _shot_power_committed
		var endpoints: Dictionary = _wind_up_endpoint_offsets(aim_dir_init, aim_distance, shot_span, _shoot_side_sign)
		_shoot_wind_up_start = endpoints.start + _shot_release_offset_locked
		_shoot_aim_target = endpoints.target + _shot_release_offset_locked
		# Snap the smoothed cursor straight to the wind-up start world pos.
		# Without this, _step_mouse_toward needs several ticks to bridge the
		# gap from the pre-aim cursor (a ring radius ahead of the bot) to the wind-up start
		# (~0.35m behind). During those ticks, intent_delta points -aim_dir
		# (catch-up direction), which then flips +aim_dir once the cursor
		# catches up — burning a direction-variance reset and leaking
		# directional bias if the reset lands awkwardly. Snapping leaves
		# a clean 60-tick lerp at pure +aim_dir for the charge tracker.
		_mouse_pos = self_pos + _shoot_wind_up_start
		_mouse_pos_initialized = true
		input.shoot_pressed = true

	# Lerp mouse_world_pos from wind-up start to aim target across the
	# charge. The fields hold OFFSETS; world position = self_pos + lerp(offsets).
	# Endpoints move with the bot, so charge accumulates at the intended
	# per-tick rate regardless of locomotion speed during the wind-up.
	# Clamped at 1: during the sampled late-release hold the blade sits at
	# the aim target (a human hanging on the trigger a beat).
	var t: float = minf(
			float(_shoot_charge_tick) / float(BOT_WRISTER_CHARGE_TICKS), 1.0)
	input.mouse_world_pos = _step_mouse_toward(self_pos + _shoot_wind_up_start.lerp(_shoot_aim_target, t))

	# Synthesize mouse_screen_pos walking along the compensated aim direction
	# (= lerp endpoints' world direction). The charge tracker reads its
	# DIRECTION from screen-pos delta, which the bot doesn't naturally have
	# — fake it so the per-tick screen delta matches the world sweep.
	# Magnitude is irrelevant (tracker only reads the normalized direction);
	# we just need consecutive ticks to differ by a consistent direction.
	var sweep_dir_3d: Vector3 = (_shoot_aim_target - _shoot_wind_up_start).normalized()
	input.mouse_screen_pos = Vector2(sweep_dir_3d.x, sweep_dir_3d.z) * float(_shoot_charge_tick)
	# Shot power: the committed hole's pace (full for flat holes; the
	# arrival-honest solved pace for a roof). The controller reads this (not the
	# synthesized sweep speed) so the bot deterministically fires the shot the
	# scorer actually evaluated.
	input.bot_wrister_power_t = _shot_power_committed
	# Commit the aim direction and hand DIRECTLY (the fake cursor is now purely the
	# cosmetic wind-up coil): the controller shoots the positional wrister along
	# this for bots and reads forehand/backhand from the committed side, not the
	# near-body cursor sweep. Set every tick so it's live on the release tick.
	input.bot_wrister_aim_dir = _shoot_aim_dir_locked
	input.bot_wrister_backhand = _shoot_side_sign < 0.0
	# Freeze the puck at the SCORED lateral offset, not the centered carry pose.
	# The wrister freeze pins the puck where the blade holds it; centered, that
	# rides into the goalie's poke radius on a breakaway and the shot whiffs.
	# The scorer priced an offset release (release_pos = anchor + this) — honor it
	# so the puck freezes off the poke line where the scorer put it.
	input.bot_wrister_origin_offset = _shot_release_offset_locked

	if _shoot_charge_tick < BOT_WRISTER_CHARGE_TICKS + _shoot_release_hold_ticks:
		# Still charging (or hanging on the sampled late-release hold —
		# the motor timing variance a human release carries). The shot
		# was scored at the EXPECTED lateness, so a draw on the late half
		# of the hold can genuinely lose the race it committed to — the
		# goalie arrives square and robs him. That's the design: thin
		# windows get attempted and convert only sometimes.
		input.shoot_held = true
		_shoot_charge_tick += 1
	else:
		# Release this tick: shoot_held drops, SkaterStateMachine's
		# _state_wrister_aim sees not shoot_held → release_wrister fires
		# with the committed power and sweep direction.
		#
		# RE-DERIVE the direction from where the puck ACTUALLY is. The aim was
		# locked at press entry against a PREDICTED release (the projected body
		# plus the scored offset) while the puck leaves from the live blade, and
		# the two disagree in two ways that both put shots off the net:
		#   - with no committed release offset the blade is frozen at the CURRENT
		#     carry pose, most of a stick off-centre (measured 1.2-1.8 m from the
		#     assumed release, against 0.12-0.72 m when an offset was committed);
		#   - on a sharp-angle look the shot runs nearly parallel to the goal
		#     line, so even 15 cm of release DEPTH error swings the crossing
		#     point over half a metre (measured: a 0.16 m gap became a 0.64 m
		#     miss from the side of the net).
		# This is not re-deciding: the aim POINT and the committed execution
		# error both stay locked, so a shuffling goalie still cannot flip the
		# chosen arc mid-swing. It aims at the same target from where the puck
		# actually sits, which is what the wind-up was supposed to deliver.
		_retarget_release_dir(input, snapshot, self_pos)
		input.shoot_held = false
		_set_state(State.CARRY)


# Returns the normalised aim direction from self_pos toward the
# shot's open-net aim point. Falls back to forward when degenerate.
func _shoot_aim_dir(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var clean_aim: Vector3 = _shot_aim_point(snapshot, self_pos)
	var dir_xz: Vector3 = Vector3(clean_aim.x - self_pos.x, 0.0, clean_aim.z - self_pos.z)
	if dir_xz.length_squared() > 0.0001:
		return dir_xz.normalized()
	return Vector3(0.0, 0.0, 1.0)


# Computes wind-up endpoint OFFSETS (relative to self_pos) for a wrister
# charge. Caller adds current self_pos when consuming each tick so the
# endpoints move with the bot — critical because tick_wrister_charge
# measures blade delta in the skater-translation-subtracted frame, so
# world-fixed endpoints would have a forward-rushing bot's locomotion
# CANCEL the lerp velocity in that frame (charge accumulation would
# stall or invert direction on rushes).
#
# Inside the helper, aim_dir is pre-tilted to compensate for the lateral
# release offset (see _aim_dir_compensated_for_side_offset). With the
# compensation, the puck's trajectory from the release position passes
# exactly through the aim point instead of flying parallel-offset to it.
#
# Endpoint offsets (in the compensated frame):
#   start  = -aim_dir' * (span/2) + forehand_perp' * side_sign * SIDE_OFFSET
#   target = +aim_dir' * (span/2) + forehand_perp' * side_sign * SIDE_OFFSET
# Both lie inside ROM (span ≤ BOT_WRISTER_WIND_UP_SPAN_M ≈ 0.7 m,
# half ≤ 0.35 m, side ≤ 0.15 m), so the blade IK chases the mouse 1:1
# without clamping. Per-tick delta in rel-skater frame = +aim_dir' *
# (span/ticks), so the gesture sweeps cleanly along aim_dir' and
# prev_blade_dir at release = aim_dir' (the tilt-compensated direction).
func _wind_up_endpoint_offsets(aim_dir: Vector3, aim_distance_m: float, wind_up_span_m: float, side_sign: float) -> Dictionary:
	var half: float = wind_up_span_m * 0.5
	var compensated: Vector3 = _aim_dir_compensated_for_side_offset(aim_dir, aim_distance_m, side_sign)
	var forehand_perp: Vector3 = Vector3(
			compensated.z * _handedness_perp_sign, 0.0, -compensated.x * _handedness_perp_sign)
	var perp: Vector3 = forehand_perp * side_sign
	return {
		"start":  -compensated * half + perp * BOT_WRISTER_SIDE_OFFSET_M,
		"target": +compensated * half + perp * BOT_WRISTER_SIDE_OFFSET_M,
	}


# Re-points the committed release direction from the live blade to the locked
# aim point, carrying the same per-release execution error the press sampled.
# No-op when no aim was locked (the continuous-geometry fallback path) or the
# blade is unavailable, so those keep the press-entry direction.
func _retarget_release_dir(input: InputState, snapshot: WorldSnapshot,
		self_pos: Vector3) -> void:
	if not _shot_aim_locked.is_finite():
		return
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		return
	var blade: Vector3 = self_state.blade_contact_world
	if blade == Vector3.ZERO:
		blade = self_pos
	var aim_vec := Vector3(
			_shot_aim_locked.x - blade.x, 0.0, _shot_aim_locked.z - blade.z)
	if aim_vec.length_squared() < 0.0001:
		return
	# The SAME committed error the press drew — re-aiming must not re-roll the
	# execution dice, or the tier's spread would be sampled twice per shot.
	if _committed_aim_error_rad != 0.0:
		aim_vec = aim_vec.rotated(Vector3.UP, _committed_aim_error_rad)
	_shoot_aim_dir_locked = aim_vec.normalized()
	input.bot_wrister_aim_dir = _shoot_aim_dir_locked


# Pre-tilts aim_dir to compensate for the wind-up's lateral release
# offset. With symmetric perp offsets on both endpoints (start and
# target both at +perp*SIDE_OFFSET), the puck releases SIDE_OFFSET meters
# perpendicular to the aim line and flies in pure aim_dir — missing the
# aim point by SIDE_OFFSET at every distance.
#
# Rotating the wind-up frame by θ = asin(SIDE_OFFSET / aim_distance)
# toward -perp makes the puck trajectory pass exactly through the aim
# point. Closed-form solve: setting up the puck flight from the rotated
# release in the rotated aim_dir and requiring it to pass through
# (aim_distance, 0) in the original frame yields side/sin(θ) = aim_distance.
#
# Practical impact at SIDE_OFFSET = 0.15 m:
#   aim_distance = 5 m   → θ ≈ 1.72° (~3% of goal width corrected)
#   aim_distance = 20 m  → θ ≈ 0.43° (smaller absolute correction, but
#                                     more important — defenders fill the
#                                     lane harder past 10 m)
# Degenerate guard: if aim_distance is ≤ SIDE_OFFSET, the aim point is
# inside the wind-up zone (unreachable shot setup); return raw aim_dir
# rather than asin'ing past 1.
func _aim_dir_compensated_for_side_offset(aim_dir: Vector3, aim_distance_m: float, side_sign: float) -> Vector3:
	if aim_distance_m <= BOT_WRISTER_SIDE_OFFSET_M:
		return aim_dir
	var theta: float = asin(BOT_WRISTER_SIDE_OFFSET_M / aim_distance_m)
	var forehand_perp: Vector3 = Vector3(
			aim_dir.z * _handedness_perp_sign, 0.0, -aim_dir.x * _handedness_perp_sign)
	return aim_dir * cos(theta) - forehand_perp * side_sign * sin(theta)


func _state_pass_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lost the puck mid-charge — bail. Mirrors SHOOT_PRESSED's bail
	# path; release-without-puck is a no-op on the controller side.
	if not have_puck:
		_pass_target_peer_id = -1
		_pass_should_charge = false
		_pass_should_saucer = false
		_dump_target = Vector3.INF
		_set_state(_post_puck_lost_state(snapshot))
		return

	# Dump override: a last-resort fling at a LOCATION, not a receiver. Force the
	# one-tick quick release (fixed quick-pass pace) and lift it by kind: HIGH to
	# chip the DZ clear over sticks into the neutral zone, LOW to flip a dump-in
	# into the corner. Elevation is set directly here (not via the saucer flag) so
	# the quick release below reads it; done in the press state, after _state_carry
	# has stopped clobbering the pass fields.
	# `_dump_target` is an AIM point, not where the puck stops: at the quick-pass
	# pace the puck's runout under PUCK_ICE_DECEL_M_S2 exceeds the rink, so a dump
	# runs until the boards take the speed out of it.
	var is_dump: bool = _dump_target.is_finite()
	if is_dump:
		_pass_should_charge = false
		_pass_should_saucer = false
		_pass_target_peer_id = -1
		# Delivery kind: soft LOW flip (dump-in), FLAT rim along our wall (the
		# bank-pass delivery the posted winger meets — breakout plan §B), or
		# the HIGH chip clear over every stick.
		if _dump_is_soft:
			input.elevation_level = ShotMechanics.ELEVATION_LOW
		elif _dump_is_rim:
			input.elevation_level = ShotMechanics.ELEVATION_FLAT
		else:
			input.elevation_level = ShotMechanics.ELEVATION_HIGH

	_apply_brake_steering(input, snapshot, self_pos)
	# Saucer: LOW loft so the pass flies over a contested mid-lane defender's
	# stick, lands, and slides to the receiver. Set every PASS_PRESSED tick
	# through the release (the level is absolute per frame, flat default).
	if _pass_should_saucer:
		input.elevation_level = ShotMechanics.ELEVATION_LOW
	# Resolve the receiver's slot label NOW for the debug readout —
	# `_pass_target_peer_id` gets cleared below, and the slot is what
	# tells the watcher who actually got the puck (e.g. "PASS→Backdoor").
	var target_slot_label: String = "?"
	if DEBUG_DECISIONS and _current_strategy != null and _pass_target_peer_id != -1:
		target_slot_label = _slot_label(_current_strategy.get_slot(_pass_target_peer_id))
	# Aim point is the receiver's lead — speed-aware via
	# _pass_aim_point so a charged pass leads less than a quick-shot
	# (puck arrives sooner, receiver covers less ground in flight) —
	# rotated by this release's committed execution error (sampled at
	# press entry on the pass budget; small enough that the magnet
	# still corrals almost every feed, with the occasional honest one
	# in the skates).
	var clean_pass_aim: Vector3 = _apply_committed_aim_error(
			self_pos, _pass_aim_point(snapshot, self_pos))

	if not _pass_should_charge:
		# ── Quick-shot pass: one-tick release ──
		# Point cursor at the receiver and fire. The charged path skips
		# this and computes its own mouse_world_pos via the wind-up lerp
		# below — calling _step_mouse_toward on BOTH targets per tick
		# fights itself (_mouse_pos walks halfway to each in turn) and
		# produces noisy cursor deltas, which the charge tracker reads as
		# bizarre release directions on long charged passes.
		#
		# SNAP the cursor ONTO the aim before firing, the same reset
		# SHOOT_PRESSED and the charged pass do at press entry — this
		# release happens on the tick it is decided, so a motion-limited
		# step (MOUSE_MAX_SPEED_M_S, ~0.83 m per tick) would fire from
		# wherever the carry left the cursor. Two things break without it,
		# and a dump is the only release that takes this path:
		#   DIRECTION — the carry cursor sits on the CARRY_BLADE_AIM_FORWARD_M
		#     ring at the protect seam, so the release left on the puck's
		#     shielding side rather than the scored line (worst exactly when
		#     it matters: a dump commits under pressure, which is when the
		#     protect swing is widest). Pre-aim can't cover this — Aim-B2's
		#     reach-cone shortcut commits on the first dispatch, by design.
		#   CONDITIONING — release_wrister's is_quick_pass branch aims
		#     blade→cursor, and apply_blade_from_mouse resolves the blade by
		#     ROM-projecting that same cursor on the same tick. A cursor
		#     inside the stick's reach projects to ~itself, collapsing the
		#     difference onto the blade's lateral carry offset, so the
		#     direction stopped depending on the target at all. This is why
		#     the aim must land on the TARGET and not on the aim ring, which
		#     is well inside that degenerate band.
		# The step call stays so _step_mouse_internal's cache (the
		# skipped-tick re-shape path) still sees this target; post-snap it
		# resolves to the aim exactly.
		_mouse_pos = Vector3(clean_pass_aim.x, 0.0, clean_pass_aim.z)
		_mouse_pos_initialized = true
		input.mouse_world_pos = _step_mouse_toward(clean_pass_aim)
		if DEBUG_DECISIONS:
			debug_last_decision = ("DUMP%s" % ("↝corner" if _dump_is_soft
					else ("↝rim" if _dump_is_rim else "↝out"))) \
					if is_dump else "PASS→%s" % target_slot_label
		# Instant quick pass via the dedicated button flag — fires this tick from
		# carry (player→blade snap at the fixed pass power), same semantics the
		# one-tick shoot release used to produce before the timing classifier was
		# removed. Clear target so a future PASS/DUMP picks a fresh one.
		input.quick_pass_pressed = true
		_pass_target_peer_id = -1
		_dump_target = Vector3.INF
		_set_state(State.CARRY)
		return

	# ── Charged wrister pass ──
	# Mid-charge bail: opponent closes in from the front during the
	# windup. Same logic as SHOOT_PRESSED bail — getting blasted mid-
	# windup is worse than not firing. Skipped on tick 0 (just committed).
	if _pass_charge_tick > 0:
		var receiver_state: SkaterNetworkState = snapshot.skater_states.get(_pass_target_peer_id)
		if receiver_state != null:
			var forward: Vector3 = receiver_state.position - self_pos
			if _opponent_within_forward(snapshot, self_pos, forward, BOT_WRISTER_BAIL_RADIUS_M):
				input.slap_pressed = true
				_pass_target_peer_id = -1
				_pass_should_charge = false
				_pass_should_saucer = false
				_set_state(State.CARRY)
				return

	if DEBUG_DECISIONS:
		debug_last_decision = "PASS+→%s" % target_slot_label

	if _pass_charge_tick == 0:
		# Capture aim direction toward the receiver and build wind-up endpoint
		# offsets (same helper as SHOOT_PRESSED). The wind-up span is COSMETIC —
		# power rides bot_wrister_power_t (set below) — so a softer pass scales
		# the visible draw down by its power fraction, keeping a gentle gesture
		# reading gentle. aim_dir is taken from clean_pass_aim (the receiver's
		# lead) rather than the stepped mouse so a single-tick mouse residual
		# can't tilt it.
		var sweep: Vector3 = clean_pass_aim - self_pos
		sweep.y = 0.0
		var aim_distance: float = sweep.length()
		var aim_dir_init: Vector3 = sweep.normalized() if aim_distance > 0.01 else Vector3(0.0, 0.0, 1.0)
		_pass_aim_dir_locked = aim_dir_init
		var pass_span: float = BOT_WRISTER_WIND_UP_SPAN_M * maxf(_pass_power_t(), 0.35)
		# Pass always sweeps on the forehand side — no defender-aware
		# side flip like SHOOT_PRESSED (passes don't justify backhand power
		# penalty trade-offs the same way).
		var endpoints: Dictionary = _wind_up_endpoint_offsets(aim_dir_init, aim_distance, pass_span, +1.0)
		_pass_wind_up_start = endpoints.start
		_pass_aim_target = endpoints.target
		# Snap the smoothed cursor to the wind-up start — same reasoning as
		# the SHOOT_PRESSED snap. For passes the jump is even larger (cursor
		# was at the receiver position 10m+ in front, wind-up start is just
		# behind the bot), so the catch-up would otherwise consume most of
		# the 60-tick window.
		_mouse_pos = self_pos + endpoints.start
		_mouse_pos_initialized = true
		input.shoot_pressed = true

	# Override the top-of-function "step toward clean_pass_aim" with the
	# wind-up lerp so the blade actually sweeps. Endpoints are offsets;
	# add current self_pos so they float with the bot (see
	# _wind_up_endpoint_offsets doc for why).
	var t: float = float(_pass_charge_tick) / float(BOT_WRISTER_CHARGE_TICKS)
	input.mouse_world_pos = _step_mouse_toward(self_pos + _pass_wind_up_start.lerp(_pass_aim_target, t))

	# Synthesize mouse_screen_pos walking along the compensated aim direction
	# — same reasoning as the SHOOT_PRESSED synthesis. Charge tracker reads
	# direction from screen-pos delta; we fake it from the lerp endpoints.
	var sweep_dir_3d: Vector3 = (_pass_aim_target - _pass_wind_up_start).normalized()
	input.mouse_screen_pos = Vector2(sweep_dir_3d.x, sweep_dir_3d.z) * float(_pass_charge_tick)
	# Pass power: the fraction of the bot's own wrister band that hits the
	# distance-adaptive target speed. The controller reads this directly.
	input.bot_wrister_power_t = _pass_power_t()
	# Commit the pass aim directly (forehand — no backhand passes); the cursor is
	# purely the cosmetic wind-up. Set every tick so it's live on the release tick.
	input.bot_wrister_aim_dir = _pass_aim_dir_locked
	input.bot_wrister_backhand = false

	if _pass_charge_tick < BOT_WRISTER_CHARGE_TICKS:
		input.shoot_held = true
		_pass_charge_tick += 1
	else:
		# Release: shoot_held drops, controller's wrister_aim sees the
		# falling edge and fires release_wrister with the committed power
		# and sweep direction.
		input.shoot_held = false
		_pass_target_peer_id = -1
		_pass_should_charge = false
		_pass_should_saucer = false
		_set_state(State.CARRY)


# One-timer fire from off-puck. Entered from OFF_PUCK / CHASE_PUCK
# when the FINISHER is ready AND the puck enters the one-timer zone.
# We can't reuse the one-tick quick-release pattern because the
# bot doesn't have the puck at press time — the controller picks up
# the puck mid-flight, and shoot_held has to stay true through the
# pickup so WRISTER_AIM is the active controller state when the
# blade contact happens. Once have_puck flips true, drop shoot_held
# to fire.
#
# Release power rides input.bot_wrister_power_t like every bot wrister (the
# controller converts it to the equivalent cursor speed) — set explicitly to
# full each tick below. Without it the scratch InputState's field leaked
# whatever the LAST press state committed (a soft pass fraction, or the type
# default), so one-timer pace was whatever happened to be lying around.
func _state_one_timer_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# THE REAL SLAPPER ONE-TIMER (SkaterStateMachine.SLAPPER_CHARGE_WITHOUT_PUCK):
	# press slap on tick 0 and HOLD — the controller runs the diegetic wind-up
	# (the pose fills over max_slapper_charge_time, the visible "shot coming"
	# tell) and arms the slapper pickup zone; the feed's flight time is what
	# builds the charge, exactly the human one-timer economy. Releasing
	# (dropping slap_held) fires through the controller's own paths: puck
	# attached mid-charge → the one-timer window → release_slapper with the
	# centre-timing bonus; puck at the zone but not attached →
	# try_one_timer_release's leniency buffer.
	#
	# The old wrister hold could never fire here: on_puck_picked_up_network
	# forces SKATING_WITH_PUCK for every state EXCEPT the slapper charge, so
	# the wrister release edge always landed in a state that ignored it — bots
	# silently caught the feed and re-deliberated (through the settle beat)
	# instead of one-timing it, with no wind-up ever visible.
	#
	# SETTLE ON THE LIVE LINE: the body target is re-derived from the live
	# puck line every tick (_one_timer_line_anchor — the slapper ZONE, not the
	# body, is what must sit on the line) instead of an arrival point latched
	# at commit; a feed slightly off the anticipated line meets the zone
	# because the body micro-shuffles onto the real line — one-timer footwork.
	var line_anchor: Vector3 = _one_timer_line_anchor(snapshot, self_pos)
	if line_anchor.is_finite() \
			and self_pos.distance_to(line_anchor) > ONE_TIMER_ANCHOR_ARRIVE_M:
		_apply_steering(input, snapshot, self_pos, line_anchor)
	else:
		_apply_brake_steering(input, snapshot, self_pos)
	# AIM FROM THE RELEASE POINT, NOT THE CURRENT BODY. The slapper direction
	# locks at the press tick and NEVER re-steers (release_slapper fires the
	# frozen locked_slapper_dir), yet the bot may enter this state up to
	# RECEIVE_TRIGGER_LATERAL_M off the feed line and micro-shuffle onto it before
	# the puck arrives. Aiming from self_pos bakes that still-to-travel lateral
	# offset into the locked line as a PARALLEL MISS — the "aim, then move, and
	# it's off target" bug. So build the aim from where the shot will actually
	# fire from: the slapper zone centre once the body has SETTLED on the live
	# feed line (perp foot of the pass), which is exactly the spot the release
	# trigger fires at. Falls back to the current zone when there's no live line.
	var release_point: Vector3 = _slapper_zone_center(
			line_anchor if line_anchor.is_finite() else self_pos)
	# Mouse + facing stay on the open net for the entire wait — FACE-aimed
	# (this is pre-aim: the cursor is pure pointing intent, cone-clamped;
	# facing_drag is the real rotation limit) at the hole read AGAINST THE
	# FEED'S ARRIVAL: the goalie is mid-re-square while the pass flies, so
	# the aim targets the hole he concedes at contact, not the one he is
	# currently vacating — read from the RELEASE POINT so the goalie-shadow
	# geometry matches the spot the puck leaves from.
	var net_hole: Vector3 = _shot_aim_point(snapshot, release_point,
			_one_timer_feed_time_s(snapshot, self_pos))
	# COMMIT the direction (input.bot_slapper_aim_dir), like every other bot
	# release: release_point → net_hole, rotated by this release's committed
	# execution error (shot budget, sampled at press entry; constant through the
	# wait). The controller's human lock measures BLADE→cursor, and the blade's
	# world point is a shoulder-anchored, attribute-scaled offset ~1 m off the body
	# — no cursor the bot can place cancels it, so aiming through the cursor
	# parallel-shifted every one-timer by about a net width, and swung it wildly in
	# tight where the shot vector is shorter than the offset itself.
	# The cursor stays pure pointing intent, aimed along the same committed line
	# from the body — which is exactly what the press-tick facing snap wants.
	var shot_vec: Vector3 = net_hole - release_point
	var clean_aim: Vector3 = _apply_committed_aim_error(self_pos, self_pos + shot_vec)
	var committed_dir := Vector3(
			clean_aim.x - self_pos.x, 0.0, clean_aim.z - self_pos.z)
	if committed_dir.length_squared() > 0.0001:
		input.bot_slapper_aim_dir = committed_dir.normalized()
	input.mouse_world_pos = _step_mouse_face(clean_aim)

	# The controller LOCKS the direction at the press tick and never re-steers, so
	# the press waits until the aim has actually settled into the reach cone. A
	# late-ready commit / zone-fallback trigger enters still watching the play, and
	# a bot that can't swing through the shot line has no business firing it: the
	# cursor is cone-clamped, so the press-tick facing snap would put the body on
	# the cone edge while the committed line went at the net — a shot fired
	# sideways out of the stance. If it NEVER squares up within the wind-up, don't
	# fire it into the corner — abort and catch the feed instead (the "worried
	# about missing the net" guard). Degenerate facing reads as settled (nothing to
	# rotate), so it presses cleanly rather than false-aborting.
	if not _one_timer_slap_down:
		if _one_timer_aim_settled(snapshot, self_pos, clean_aim):
			debug_last_decision = "ONE_TIMER"
			input.slap_pressed = true
			_one_timer_slap_down = true
		elif _one_timer_press_tick >= ONE_TIMER_AIM_WAIT_MAX_TICKS:
			# Can't square to the net inside the wind-up → the shot misses. Nothing
			# was pressed yet, so there's no slapper charge to cancel — just leave
			# the one-timer and receive.
			debug_last_decision = "ONE_TIMER_ABORT_WIDE"
			_set_state(_post_puck_lost_state(snapshot))
			return

	if have_puck:
		# Attached mid-charge — the controller opened the one-timer window
		# (SLAPPER_CHARGE_WITH_PUCK). Drop the button inside it: release_slapper
		# fires the full one-timer. CARRY is one tick of cleanup (the puck is
		# gone next tick).
		input.slap_held = false
		_set_state(State.CARRY)
		return

	if _puck_at_slapper_zone(snapshot, self_pos):
		# On the CENTRE beat but not attached (a puck slipping through the zone) —
		# drop the button and let the controller's release buffer sweep the
		# leniency zone. Clean feeds attach a hair earlier (the have_puck branch
		# above) and fire the with-puck release instead; both earn the same graded
		# centre-timing bonus. Releasing here on the centre beat (not at blade
		# reach, ~1.5 m early) is what stops the old −10%/whiff on the salvage.
		input.slap_held = false
		_set_state(_post_puck_lost_state(snapshot))
		return

	if not line_anchor.is_finite():
		# The feed died — picked off, deflected dead, or it crossed outside
		# the zone. Drop the swing (an honest, visible whiff through the
		# follow-through) and get back into the play.
		input.slap_held = false
		_set_state(_post_puck_lost_state(snapshot))
		return

	# Feed still inbound — keep the wind-up building (once pressed).
	input.slap_held = _one_timer_slap_down
	_one_timer_press_tick += 1

	# Budget backstop (see ONE_TIMER_PRESS_MAX_TICKS) — the dead-feed bail
	# above handles every genuine failure earlier.
	if _one_timer_press_tick >= ONE_TIMER_PRESS_MAX_TICKS:
		input.slap_held = false
		_set_state(_post_puck_lost_state(snapshot))


# True when the one-timer's committed aim can fire from the current STANCE: the
# body is already square to the shot line within ONE_TIMER_SQUARE_UP_MAX_RAD, and
# (belt-and-braces for an unusually narrow build) the aim is inside the blade
# reach cone with the commit margin. Unreadable facing (degenerate state) never
# blocks: missing data must not starve the wind-up.
func _one_timer_aim_settled(snapshot: WorldSnapshot, self_pos: Vector3,
		aim: Vector3) -> bool:
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null or self_state.facing.length_squared() < 0.0001:
		return true
	var aim_dir := Vector2(aim.x - self_pos.x, aim.z - self_pos.z)
	if aim_dir.length_squared() < 0.0001:
		return false
	var gate: float = minf(ONE_TIMER_SQUARE_UP_MAX_RAD,
			maxf(_self_reach_cone_half_angle - AIM_COMMIT_CONE_MARGIN_RAD, 0.0))
	return absf(self_state.facing.angle_to(aim_dir)) <= gate


# Remaining feed-flight time: the distance along the puck's live line to my
# perpendicular foot, over its current speed (the same geometry as
# _one_timer_line_anchor). 0 when there's no readable live feed — a dead or
# held puck reads as "arriving now", so the aim falls back to the goalie as
# he stands.
func _one_timer_feed_time_s(snapshot: WorldSnapshot, self_pos: Vector3) -> float:
	if snapshot.puck_state == null:
		return 0.0
	var pv: Vector3 = snapshot.puck_state.velocity
	var speed_sq: float = pv.x * pv.x + pv.z * pv.z
	if speed_sq < RECEIVE_TRIGGER_PUCK_SPEED_M_S * RECEIVE_TRIGGER_PUCK_SPEED_M_S:
		return 0.0
	var speed: float = sqrt(speed_sq)
	var puck_pos: Vector3 = snapshot.puck_state.position
	var along: float = Vector3(
			self_pos.x - puck_pos.x, 0.0, self_pos.z - puck_pos.z) \
			.dot(Vector3(pv.x / speed, 0.0, pv.z / speed))
	return clampf(along / speed, 0.0, ONE_TIMER_FEED_LOOKAHEAD_MAX_S)


# Helper: writes one-timer-ready to TeamBrain. Off-puck role decision
# carries the flag; the state machine forwards it so the carrier on
# the opposite side of the brain (well — same brain) can read it via
# `_team_brain.is_one_timer_ready(peer_id)`.
func _set_one_timer_ready(ready: bool) -> void:
	# Local only — the write to the shared brain is deferred to
	# push_one_timer_ready(), called on the main thread after dispatch (AI
	# threading Phase 3c), so the worker never writes team state. The brain read
	# side is already frozen into the per-frame view, so the cross-agent signal
	# was one frame late since Phase 3a regardless; the collection preserves that.
	_is_one_timer_ready = ready


# Main-thread collection of this agent's one-timer readiness into the shared
# brain (called by the AI coordinator / duel harness after dispatch). Idempotent:
# pushes the current local flag every frame, so a false erases the entry.
func push_one_timer_ready() -> void:
	if _team_brain != null:
		_team_brain.set_one_timer_ready(_peer_id, _is_one_timer_ready)


# The LIVE-line body anchor for a one-timer reception: place the slapper
# pickup ZONE (the wind-up blade is raised — the zone, not the blade, makes
# the catch) on the incoming feed's live travel line, re-derived from the
# live puck every call instead of latched at commit. This is the real
# one-timer footwork: the shooter stays wound on the net and micro-shuffles
# the BODY onto the pass's actual line as it reveals itself. Without it, a
# feed an arm's length off the anticipated line parked the bot at a stale
# anchor and the catchable puck slid through the reachable ROM untouched.
# Body = perp foot of self on the line, minus the zone's offset in the
# net-facing frame (local +X = blade side, negative local Z = in front —
# the BOT_ONE_TIMER_ZONE_OFFSET_* mirrors).
#
# Vector3.INF when there is no live inbound feed to settle on: puck held
# (REAL carrier — the pre-armed shooter reads the release instantly, same
# rationale as _puck_in_one_timer_zone), too slow to be a feed, already past
# our level (the chase owns it), crossing outside the reception band, or a
# TEAMMATE is better positioned for it (the _incoming_pass_to_me filter —
# someone else's feed must not drag this shooter off its station). Same
# trigger constants as the rest of the reception family, so "a feed worth
# settling on" means the same thing everywhere.
func _one_timer_line_anchor(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	if snapshot.puck_state == null or snapshot.real_puck_carrier_peer_id != -1:
		return Vector3.INF
	var pv: Vector3 = snapshot.puck_state.velocity
	var speed_sq: float = pv.x * pv.x + pv.z * pv.z
	if speed_sq < RECEIVE_TRIGGER_PUCK_SPEED_M_S * RECEIVE_TRIGGER_PUCK_SPEED_M_S:
		return Vector3.INF
	var speed: float = sqrt(speed_sq)
	var dir := Vector3(pv.x / speed, 0.0, pv.z / speed)
	var puck_pos: Vector3 = snapshot.puck_state.position
	var to_self := Vector3(self_pos.x - puck_pos.x, 0.0, self_pos.z - puck_pos.z)
	var t: float = to_self.dot(dir)
	if t <= 0.0:
		return Vector3.INF
	var perp_foot := Vector3(puck_pos.x + dir.x * t, 0.0, puck_pos.z + dir.z * t)
	var perp_dx: float = self_pos.x - perp_foot.x
	var perp_dz: float = self_pos.z - perp_foot.z
	var my_d2: float = perp_dx * perp_dx + perp_dz * perp_dz
	if my_d2 > RECEIVE_TRIGGER_LATERAL_M * RECEIVE_TRIGGER_LATERAL_M:
		return Vector3.INF
	# Best-positioned-receiver filter (mirror of _incoming_pass_to_me): a feed
	# crossing nearer a teammate is theirs.
	for pid: int in snapshot.skater_states:
		if pid == _peer_id or _team_id_by_peer.get(pid, -1) != _team_id:
			continue
		var tp: Vector3 = snapshot.skater_states[pid].position
		var dx: float = tp.x - perp_foot.x
		var dz: float = tp.z - perp_foot.z
		if dx * dx + dz * dz < my_d2:
			return Vector3.INF
	var to_net: Vector3 = _attacking_goal_pos - perp_foot
	to_net.y = 0.0
	var net_len: float = to_net.length()
	if net_len < 0.001:
		return Vector3.INF
	var f: Vector3 = to_net / net_len
	var right := Vector3(-f.z, 0.0, f.x)
	var side: float = -1.0 if _is_left_handed else 1.0
	var zone_offset: Vector3 = right * (side * BOT_ONE_TIMER_ZONE_OFFSET_X_M) \
			- f * BOT_ONE_TIMER_ZONE_OFFSET_Z_M
	return perp_foot - zone_offset


# The bot's slapper pickup-zone CENTRE in world space — self plus the zone offset
# in the net-facing frame (the mirror of the body anchor in _one_timer_line_anchor:
# body = perp_foot − zone_offset, so zone centre = self + zone_offset). The
# centre-timing bonus is graded by how close the puck is to THIS point at release.
func _slapper_zone_center(self_pos: Vector3) -> Vector3:
	var to_net: Vector3 = _attacking_goal_pos - self_pos
	to_net.y = 0.0
	var net_len: float = to_net.length()
	if net_len < 0.001:
		return self_pos
	var f: Vector3 = to_net / net_len
	var right := Vector3(-f.z, 0.0, f.x)
	var side: float = -1.0 if _is_left_handed else 1.0
	var zone_offset: Vector3 = right * (side * BOT_ONE_TIMER_ZONE_OFFSET_X_M) \
			- f * BOT_ONE_TIMER_ZONE_OFFSET_Z_M
	return self_pos + zone_offset


# Release trigger for a wound-up one-timer: is the puck (projected one tick) right
# AT the slapper zone centre? This fires the release on the CENTRE beat — a human
# releases "on the beat" and the leniency buffer covers the swing. The old
# trigger released the instant the puck entered blade reach (~2 m out, ~1.5 m
# from the zone centre): far too early, which scored the −10% end of the
# centre-timing bonus and whiffed slower feeds outright. Sized INSIDE the pickup
# radius so a clean feed ATTACHES first (→ the with-puck release, which earns the
# centred bonus); this only fires as a salvage for a puck that slips through the
# zone without attaching.
func _puck_at_slapper_zone(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	if snapshot.puck_state == null or snapshot.real_puck_carrier_peer_id != -1:
		return false
	var zone_center: Vector3 = _slapper_zone_center(self_pos)
	var pv: Vector3 = snapshot.puck_state.velocity
	var pp: Vector3 = snapshot.puck_state.position
	var dx: float = (pp.x + pv.x * MOUSE_TICK_DELTA) - zone_center.x
	var dz: float = (pp.z + pv.z * MOUSE_TICK_DELTA) - zone_center.z
	return dx * dx + dz * dz <= ONE_TIMER_RELEASE_RADIUS_M * ONE_TIMER_RELEASE_RADIUS_M


# A one-timer is a scoring-area mechanic: the shooter must be inside the
# attacking zone (past the far blue line). This is the guard that makes a
# defensive-zone one-timer impossible — readiness preserved across a possession
# flip can't survive the bot retreating out of the offensive zone, and the fire
# triggers themselves refuse from our own end. `-_own_goal_dir * z` is the
# distance into attacking territory (same frame the possession-state zone test
# uses); > BLUE_LINE_Z means fully in the attacking zone. The FINISHER stages
# ~SLOT_DIST_M off the net, deep inside this, so no legit one-timer is affected.
func _in_attacking_zone(self_pos: Vector3) -> bool:
	return -_own_goal_dir * self_pos.z > GameRules.BLUE_LINE_Z


# Returns true when the puck (projected one tick forward by its
# velocity to cover input → controller latency) is within blade reach
# of the bot AND forward of the bot relative to the current aim
# direction. Forward gate prevents firing when the puck is behind the
# bot — the swing can't connect cleanly in that case.
#
# All three primitives are pre-existing constants:
#   _blade_reach       — stick + blade + buffer (radius gate)
#   aim_dir             — current shot-aim-point direction (forward axis)
#   MOUSE_TICK_DELTA    — single-tick latency horizon for puck projection
func _puck_in_one_timer_zone(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	if snapshot.puck_state == null:
		return false
	if snapshot.real_puck_carrier_peer_id != -1:
		# Puck is held — there's nothing to one-time. Read the REAL carrier,
		# not the reaction-debounced one: the pre-armed FINISHER is WAITING on
		# this exact feed (that's what the ready stance means), so recognizing
		# "the puck left his stick toward me" isn't a reaction the difficulty
		# delay should slow. Under the debounced read, a short feed spent its
		# whole flight nominally "held" and the trigger never fired.
		return false
	var puck_pos: Vector3 = snapshot.puck_state.position
	var puck_vel: Vector3 = snapshot.puck_state.velocity
	var puck_next := Vector3(
			puck_pos.x + puck_vel.x * MOUSE_TICK_DELTA,
			puck_pos.y,
			puck_pos.z + puck_vel.z * MOUSE_TICK_DELTA)
	var to_puck_x: float = puck_next.x - self_pos.x
	var to_puck_z: float = puck_next.z - self_pos.z
	var dist_sq: float = to_puck_x * to_puck_x + to_puck_z * to_puck_z
	if dist_sq > _blade_reach * _blade_reach:
		return false
	# Forward-hemisphere gate via dot with aim_dir. Uses the quick-shot
	# aim (release_lookahead_s = 0) since one-timers fire on contact —
	# the planned shot direction is the same as the bot's pre-aimed
	# direction in the ready stance, not the wrister-window aim.
	var clean_aim: Vector3 = _shot_aim_point(snapshot, self_pos, 0.0)
	var aim_x: float = clean_aim.x - self_pos.x
	var aim_z: float = clean_aim.z - self_pos.z
	return aim_x * to_puck_x + aim_z * to_puck_z > 0.0


# Hold-position steering during fire-state commits (SHOOT_PRESSED,
# PASS_PRESSED) and CARRY pre-aim. The bot has decided where to
# fire from — they shouldn't keep skating forward during the
# wrister charge (60 ticks ≈ 250 ms), which would otherwise drift
# them up to ~4 m closer to the net before the puck releases.
# Anchor = self_pos
# zeroes the seek force so ice friction bleeds momentum naturally;
# repel forces (defenders, boards, crease) still apply via
# `_apply_steering`. Each fire state sets `input.mouse_world_pos`
# itself because the aim differs (goal-shadow vs receiver lead).
func _apply_hold_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	_apply_steering(input, snapshot, self_pos, self_pos)


# Brake steering — actively decelerate by pointing the steering anchor
# behind the bot's current velocity. The opposed direction trips the
# brake-pivot in _apply_steering (`AISteering.should_brake` → the real
# brake key above the pivot speed floor, reverse thrust below it), much
# faster deceleration than passive friction during coast (hold).
# Falls back to hold once velocity drops below BRAKE_MIN_SPEED so the
# bot doesn't start gliding backward after stopping. Used during
# fire-action pre-aim convergence and during the wrister wind-up
# — without this, a bot rushing at top speed coasts past the
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
	# Dump: aim at the fixed location, not a receiver lead. Checked first so a
	# stale _pass_target_peer_id (never cleared for a dump) can't override it.
	if _dump_target.is_finite():
		return _dump_target
	var receiver: SkaterNetworkState = snapshot.skater_states.get(_pass_target_peer_id)
	if receiver == null:
		return _attacking_goal_pos
	# Speed-aware lead: a faster pass arrives sooner, so the receiver covers
	# less ground in flight — leading at the quick-shot speed would over-lead
	# and the puck would sail past. Use the distance-adaptive launch speed
	# locked in at intent commit (what the controller will actually fire at).
	var pass_speed: float = _pass_target_speed
	var accel: Vector3 = _accel_ref.get(_pass_target_peer_id, Vector3.ZERO)
	# Intercept-aware lead, shared with the carrier's pass scoring so the fired aim
	# matches the scored one (AIPassLead) — including the receiver's real build, so
	# the release leads exactly where the score assumed. Origin = the carried PUCK
	# (the blade — the real release point), matching the carrier's scoring origin;
	# leading from the body center systematically over-led close feeds.
	var receiver_caps: AISkaterCaps = _caps_by_peer.get(_pass_target_peer_id)
	var origin: Vector3 = self_pos
	if snapshot.puck_state != null and snapshot.puck_state.carrier_peer_id == _peer_id:
		origin = Vector3(
				snapshot.puck_state.position.x, 0.0, snapshot.puck_state.position.z)
	var lead: Vector3 = AIPassLead.lead_point(
			origin, receiver, accel, pass_speed, AIRoleCarrier.PASS_LEAD_MAX_S, receiver_caps)
	# Net guard on the FIRED lane: the scored lane was net-checked at commit, but
	# the lead re-solves every tick and a receiver drifting near the net plane can
	# walk it into the cage (the classic behind-the-net feed that rings off the
	# outside of the frame). If the led lane crosses a net but the receiver's body
	# line doesn't, fire at the body — a catch on the tape beats a clank.
	if AIActionScoring.pass_lane_blocked_by_net(origin, lead) \
			and not AIActionScoring.pass_lane_blocked_by_net(origin, receiver.position):
		return Vector3(receiver.position.x, 0.0, receiver.position.z)
	return lead


# `arrive` opts into the arrival brake (AISteering.should_arrival_brake):
# station-keeping callers (off-puck role destinations) brake to STOP at the
# anchor instead of overshooting a target that slowed down. Waypoint-style
# callers (carry steps, puck chase, check commits, tag-up) leave it false —
# they either re-pick the anchor continuously or WANT to arrive at speed.
func _apply_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3,
		anchor: Vector3, arrive: bool = false, velocity_match_speed: float = 0.0) -> void:
	# Standard potential-field steering with brake-pivot.
	# Use the per-team roster published by GameManager._enrich_snapshot_for_ai
	# instead of re-partitioning snapshot.skater_states every physics tick.
	# Fall back to a live partition when the cache is empty (unit tests).
	_scratch_teammates.clear()
	_scratch_teammate_steer_vels.clear()
	_scratch_opponents.clear()
	_scratch_opponent_steer_vels.clear()
	if not snapshot.teammate_ids_by_team.is_empty():
		var team_ids: Array = snapshot.teammate_ids_by_team[_team_id] \
				if snapshot.teammate_ids_by_team.has(_team_id) else _empty_ids
		for peer_id: int in team_ids:
			if peer_id == _peer_id:
				continue
			_scratch_teammates.append(snapshot.skater_states[peer_id].position)
			_scratch_teammate_steer_vels.append(snapshot.skater_states[peer_id].velocity)
		for other_team: int in snapshot.teammate_ids_by_team:
			if other_team == _team_id:
				continue
			var opp_ids: Array = snapshot.teammate_ids_by_team[other_team]
			for peer_id: int in opp_ids:
				_scratch_opponents.append(snapshot.skater_states[peer_id].position)
				_scratch_opponent_steer_vels.append(snapshot.skater_states[peer_id].velocity)
	else:
		for peer_id: int in snapshot.skater_states:
			if peer_id == _peer_id:
				continue
			if _team_id_by_peer.get(peer_id, -1) == _team_id:
				_scratch_teammates.append(snapshot.skater_states[peer_id].position)
				_scratch_teammate_steer_vels.append(snapshot.skater_states[peer_id].velocity)
			else:
				_scratch_opponents.append(snapshot.skater_states[peer_id].position)
				_scratch_opponent_steer_vels.append(snapshot.skater_states[peer_id].velocity)

	# Shot-lane endpoints: only set when a teammate (not us, not opp) is
	# the carrier — keeps off-puck bots out of the carrier's lane to the
	# attacking goal. Carrier-side bots pass zero (they aren't repelled
	# from their own lane).
	var lane_start: Vector3 = Vector3.ZERO
	var lane_end: Vector3 = Vector3.ZERO
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier != -1 and carrier != _peer_id:
		if _team_id_by_peer.get(carrier, -1) == _team_id:
			var carrier_state: SkaterNetworkState = snapshot.skater_states.get(carrier)
			if carrier_state != null:
				# Lead the carrier — the lane we want to clear is where
				# they'll shoot from, not where they are right now.
				lane_start = AITrajectory.predict_at(
						carrier_state.position, carrier_state.velocity,
						SHOT_LANE_LEAD_TIME_S)
				lane_end = _attacking_goal_pos

	# Carrier-specific repel: when WE have the puck, defender avoidance runs
	# threat-gated and route-around (momentum-reach instead of raw proximity,
	# never pushed backwards off the carry line — see
	# AISteering._carrier_threat_repel), at the heavier carry weight. Off-puck
	# bots keep the plain proximity field (velocities withheld).
	var opp_repel: float = AISteering.OPPONENT_REPEL_WEIGHT
	var steer_vels: Array[Vector3] = _empty_vels
	if carrier == _peer_id:
		opp_repel = AISteering.OPPONENT_REPEL_WEIGHT_CARRY
		steer_vels = _scratch_opponent_steer_vels
	# Velocity-matched seek to the anchor when the caller opts in
	# (velocity_match_speed > 0 — the carrier path): the anchor pull cancels
	# cross-momentum so the bot redirects onto the line instead of orbiting past
	# it. Read our own velocity from the snapshot for the match.
	var match_self_vel: Vector3 = Vector3.ZERO
	if velocity_match_speed > 0.0:
		var self_st: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
		if self_st != null:
			match_self_vel = self_st.velocity
	var desired: Vector2 = AISteering.compute_move_vector(
			self_pos, anchor, _scratch_teammates, _scratch_opponents,
			lane_start, lane_end,
			GameRules.RINK_HALF_WIDTH, GameRules.RINK_HALF_LENGTH,
			opp_repel, steer_vels, _scratch_teammate_steer_vels,
			match_self_vel, velocity_match_speed)

	# Brake-pivot: if our current velocity is roughly opposite the desired
	# direction (~180° transition), stopping hard beats carving a wide arc.
	# The bot presses the REAL brake key and keeps move_vector on the exit
	# direction — the input shape a human uses — so the physics gets the
	# heavy brake friction and the cosmetic layer reads a genuine hockey
	# stop into a dig-in restart. While brake is held the movement rules
	# ignore move_vector, so the exit direction costs nothing until the
	# brake releases (hysteresis + speed floor in AISteering.should_brake)
	# and thrust resumes toward it instantly.
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state != null:
		var v: Vector3 = self_state.velocity
		_pivot_braking = AISteering.should_brake(desired, Vector2(v.x, v.z), _pivot_braking)
		# Arrival brake (opt-in per call site): stop AT a station target
		# instead of overshooting one that slowed down and doubling back.
		# The pivot brake wins when both would fire (it already implies
		# maximal braking).
		if arrive and not _pivot_braking:
			_arrival_braking = AISteering.should_arrival_brake(
					self_pos, anchor, Vector2(v.x, v.z), _arrival_braking)
		else:
			_arrival_braking = false
		input.brake = _pivot_braking or _arrival_braking
		# Body-level offside guard: keep an attacking non-carrier from
		# skating its body across the attacking blue line before the puck
		# (instant ghost in ARCADE). Applied after the brake-pivot so the
		# hard constraint wins. The role-level target filter can't hold a
		# momentum-driven body to the line on its own.
		desired = AISteering.offside_brake(
				desired, self_pos, v, _own_goal_dir,
				snapshot.puck_state.position.z, carrier == _peer_id)
	input.move_vector = desired


# Decide whether to hold sprint this tick and write it onto `input`. Reads the
# bot's own stamina + lockout from the perception snapshot (both replicated on
# SkaterNetworkState) and the live steering output, then defers to the pure
# BotSprintRules gate. `target` is the steering destination the closing gap is
# measured against; `carrying` / `breakaway` gate the carrier case. Must be
# called AFTER _apply_steering / _apply_brake_steering so input.move_vector is
# the final heading the turn gate evaluates.
func _resolve_sprint(input: InputState, self_state: SkaterNetworkState,
		self_pos: Vector3, target: Vector3, carrying: bool, breakaway: bool) -> void:
	if self_state == null:
		input.sprint_held = false
		return
	var gap: float = Vector2(target.x - self_pos.x, target.z - self_pos.z).length()
	var vel_xz := Vector2(self_state.velocity.x, self_state.velocity.z)
	input.sprint_held = BotSprintRules.should_sprint(
			_cached_sprint_held, gap, vel_xz, input.move_vector,
			self_state.stamina, self_state.sprint_locked, carrying, breakaway,
			self_state.facing)


# Opponent peer ids, read straight from the per-frame roster cache published by
# GameManager._enrich_snapshot_for_ai (no allocation, no per-peer team lookup).
# Falls back to a live partition into a reused buffer when the cache is empty
# (unit tests); production on the host always hits the cache.
func _opponent_ids(snapshot: WorldSnapshot) -> Array:
	var opp_team: int = 1 - _team_id
	if snapshot.teammate_ids_by_team.has(opp_team):
		return snapshot.teammate_ids_by_team[opp_team]
	_scratch_opp_ids.clear()
	for pid: int in snapshot.skater_states:
		if pid != _peer_id and _team_id_by_peer.get(pid, -1) != _team_id:
			_scratch_opp_ids.append(pid)
	return _scratch_opp_ids


# True iff the carrier has a clear lane to the attacking goal — no opponent
# skater ahead of it (toward the net) inside a narrow corridor. A clean
# breakaway is the one case a carrier sprints: open ice means the wide turn
# radius doesn't bite and the burst beats the backcheck to the net. Goalies
# aren't in skater_states, so they never block the lane (the goalie is the
# thing you're skating in on). Conservative by design — false positives would
# have the carrier sprint into traffic and lose the agility to dangle.
func _carry_has_open_lane(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	var to_net: Vector3 = _attacking_goal_pos - self_pos
	to_net.y = 0.0
	var dist_net: float = to_net.length()
	if dist_net < 0.01:
		return false
	var net_dir: Vector3 = to_net / dist_net
	for pid: int in _opponent_ids(snapshot):
		var opp_pos: Vector3 = snapshot.skater_states[pid].position
		var to_opp: Vector3 = opp_pos - self_pos
		to_opp.y = 0.0
		var along: float = to_opp.dot(net_dir)
		if along <= 0.0 or along > dist_net:
			continue  # behind us, or past the net — not in the lane
		var perp: float = (to_opp - net_dir * along).length()
		if perp < BREAKAWAY_CORRIDOR_M:
			return false
	return true


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


# Our OWN goalie's current world position, or Vector3.INF when its state isn't
# buffered yet. Used by the carry-cursor blade cradle: the same stick-through-
# goalie feedback loop that dislodges the puck at the ATTACKING net is an
# OWN-GOAL when it happens at our own cage (a defender carrying across its own
# crease waves the blade through its own goalie, the puck pops free in the
# slot). The blade must cradle off our goalie exactly like it does off theirs.
func _own_goalie_now(snapshot: WorldSnapshot) -> Vector3:
	var own_goalie: GoalieNetworkState = snapshot.goalie_states.get(_team_id)
	if own_goalie == null:
		return Vector3.INF
	return Vector3(own_goalie.position_x, 0.0, own_goalie.position_z)


# Wraps AIActionScoring.predict_goalie_pos for the common case where
# the puck-at-release is the position we're scoring a shot from.
# `release_time_s` is the time from now until the bot fires (e.g.,
# wrister charge time + any path/flight time before the fire).
func _predict_goalie_at(snapshot: WorldSnapshot, release_time_s: float,
		puck_pos_at_release: Vector3) -> Vector3:
	return AIActionScoring.predict_goalie_pos(
			_goalie_now(snapshot), _attacking_goal_pos,
			release_time_s, puck_pos_at_release)


# CARRY-state mouse target: one ring radius forward along the carry ROUTE
# (the live anchor's direction — face where you're going; the attacking-goal
# direction when settling or genuinely retreating — see the FACE THE ROUTE
# block), plus a stickhandling offset perpendicular to that
# direction to evade the closest incoming defender. Body facing
# tracks the forward axis; blade IK lands
# comfortably in front of the body where small mouse shifts produce
# real blade motion (instead of clamping to ROM extreme as it would
# at goal-plane distance).
# Continuously aim toward the likely SHOT target during CARRY so when
# the carrier eventually commits to SHOOT, the facing is already
# aligned and pre-aim convergence is near-instant. Pass-favored ticks
# fall through to the default carry aim — predictively rotating
# toward a pass receiver caused weird neutral-zone behavior (the
# best pass can flip per tick to teammates spread across the rink,
# and the body would twist back and forth chasing transient leads).
# Passes still pre-aim correctly inside the press-state handler.
#
# CRITICAL: project the aim DIRECTION to a point CARRY_BLADE_AIM_FORWARD_M
# from the bot, matching what _aim_target_for_intent does during
# pre-aim. The mouse target distance must match across CARRY and
# pre-aim — otherwise the mouse target jumps ~8 m at commit and
# the motion-limited mouse takes 100+ ticks to traverse, blowing
# past INTENT_MAX_WAIT_TICKS and timing out pre-aim entirely.
func _carry_aim_track_fire(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	const FIRE_AIM_THRESHOLD: float = 0.05
	# Debounce band for the aim-mode flip below. ABSOLUTE, deliberately
	# not AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC (the proportional
	# intent hysteresis): this band filters per-re-eval score wobble
	# around the fixed FIRE_AIM_THRESHOLD, so its width is anchored to
	# that threshold's scale — a fraction of a near-zero score would be
	# a near-zero band and the blade would wobble at ~30 Hz again.
	const FIRE_AIM_HYSTERESIS_BAND: float = 0.05
	# Wrister dominance triggers the pre-track toward the goalie shadow.
	var best_shot_score: float = debug_shoot_score
	# Hysteresis on the tracking-fire decision: once we're tracking
	# the shot, require the shot score to drop meaningfully below
	# threshold (or below pass score) before falling back to carry
	# aim. Without this margin the per-re-eval flip between the two
	# aim modes wobbles the blade at ~30 Hz when the bot is deciding
	# to shoot. Margin direction is signed by _carry_tracking_fire so
	# entry requires being CLEARLY past the thresholds; exit requires
	# being CLEARLY below them.
	var margin: float = FIRE_AIM_HYSTERESIS_BAND
	var threshold_gate: float
	var pass_gate: float
	if _carry_tracking_fire:
		threshold_gate = FIRE_AIM_THRESHOLD - margin
		pass_gate = debug_pass_score - margin
	else:
		threshold_gate = FIRE_AIM_THRESHOLD + margin
		pass_gate = debug_pass_score + margin
	var should_track: bool = (best_shot_score >= threshold_gate
			and best_shot_score >= pass_gate)
	_carry_tracking_fire = should_track
	if not should_track:
		return _carry_mouse_aim(snapshot, self_pos)
	return _aim_ring_toward(self_pos, _shot_aim_point(snapshot, self_pos))


# Computes and steps the CARRY-intent mouse cursor: the deke sell-and-snap while
# a deke is live, else the carry-or-fire track aim. A FRONT-hemisphere reach
# steps DIRECT (a straight chord at the blade slew — the blade leads and body
# facing lags at its own turn rate, the hands-lead-body carry read); a
# turn-around (target BEHIND the body) steps ARC so the chord doesn't cross
# self_pos and trip the pose IK gate. Its callees only READ dispatch-throttled
# state (cached shot/pass scores in _carry_aim_track_fire, latched deke dirs in
# _deke_mouse_target), so the skipped-tick path calls it every physics tick to
# keep the carry blade tracking continuously between dispatches.
func _step_carry_cursor(input: InputState, snapshot: WorldSnapshot,
		self_pos: Vector3, self_state: SkaterNetworkState) -> void:
	var deke_mouse: Vector3 = _deke_mouse_target(self_pos)
	var mouse_target: Vector3 = deke_mouse if deke_mouse.is_finite() \
			else _carry_aim_track_fire(snapshot, self_pos)
	var to_target := Vector3(mouse_target.x - self_pos.x, 0.0, mouse_target.z - self_pos.z)
	if not _target_is_behind(to_target, self_state):
		# No arc walk on a front reach — clear any long-way orbit latched by a
		# prior turn-around so the next ARC swing re-evaluates from scratch.
		_arc_protect_sign = 0.0
		input.mouse_world_pos = _step_mouse_toward(mouse_target)
	else:
		input.mouse_world_pos = _step_mouse_aim(mouse_target)


# Forward carry reach, cradled tight when the body is behind/beside EITHER net
# (see CARRY_BEHIND_NET_CRADLE_M). Returns the full reach everywhere else.
func _carry_reach_behind_net(self_pos: Vector3) -> float:
	# Wide of the cage laterally — carrying up the wall / in the corner, not net-
	# working — keep the full reach (the wall margin + net_safe_blade_target own
	# that side).
	if absf(self_pos.x) > GameRules.NET_BACK_HALF_WIDTH + CARRY_BEHIND_NET_LATERAL_M:
		return CARRY_BLADE_AIM_FORWARD_M
	# Signed distance PAST a goal line toward its end boards (>0 = behind that net,
	# in the band where the full-reach blade would chord through the cage). BOTH
	# nets cradle now, taking whichever the body is behind:
	#   - Attacking net (was the only case): net-working a wraparound / walkout.
	#   - OUR net (added): a defender retrieving or wheeling behind its own cage is
	#     the WORSE case — the residual blade-into-net contact net_safe_blade_target
	#     can't fully absorb pops the puck loose IN OUR CREASE (own goal) and, tick
	#     after tick, re-pins the bot back there unable to skate it out (the
	#     "stuck behind our own net" report). Cradling tight kills that loop and
	#     lets the body wheel the puck out cleanly.
	var past_att: float = (self_pos.z - _attacking_goal_pos.z) * (-_own_goal_dir)
	var past_own: float = (self_pos.z - _own_goal_dir * GameRules.GOAL_LINE_Z) * _own_goal_dir
	var past: float = maxf(past_att, past_own)
	# Ramp: full reach until a band's width in front of the line, tight cradle once
	# at/behind it. In FRONT of the attacking net a genuine scoring drive is
	# fire-tracked (overrides this), so cradling only the last stride before the
	# line — and everything behind — never blunts a shot. In front of OUR net there's
	# no shot to blunt: cradling the puck tight there is purely protection.
	var t: float = clampf((past + CARRY_BEHIND_NET_BAND_M) / CARRY_BEHIND_NET_BAND_M, 0.0, 1.0)
	return lerpf(CARRY_BLADE_AIM_FORWARD_M, CARRY_BEHIND_NET_CRADLE_M, t)


func _carry_mouse_aim(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	# Danger zone: when the bot's body is within _blade_reach of the
	# goalie, the default forward aim drives the blade through the
	# goalie. Stick-on-goalie contact dislodges the puck (a game
	# mechanic), the bot reacquires the loose puck a tick later
	# without the engagement cooldown firing, the mouse points forward
	# again, and the cycle repeats — a physical feedback loop, not a
	# decision. Crease itself is fine; the goalie's body is the
	# specific thing the stick has to stay off of, so the threshold
	# is distance to the goalie, not distance to the goal line.
	#
	# Pulling the mouse to the bot's own position parks the blade in
	# a tight cradle: zero forward extension, no goalie contact
	# possible. Body facing isn't driven (zero direction vector → pose
	# coordinator holds last facing), so the bot keeps facing however
	# they were facing on entry. Body steering still does whatever
	# _best_carry wants — including skating backward toward the carry
	# anchor via brake-pivot. The hockey-real "back out facing the
	# play" behavior emerges from facing being held rather than reset.
	#
	# BOTH goalies gate this, not just theirs: waving the blade through
	# OUR goalie in OUR crease pops the puck loose in our own slot — an
	# own goal, the worst version of the same feedback loop. A defender
	# carrying across its own doorstep must cradle exactly the same way.
	var goalie_pos: Vector3 = _goalie_now(snapshot)
	if self_pos.distance_to(goalie_pos) < _blade_reach:
		return self_pos
	var own_goalie_pos: Vector3 = _own_goalie_now(snapshot)
	if own_goalie_pos.is_finite() and self_pos.distance_to(own_goalie_pos) < _blade_reach:
		return self_pos

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
	# FACE THE ROUTE: while actually driving somewhere, the carry cursor —
	# and with it body facing — defaults to the live carry anchor's
	# direction, not the goal's. Movement speed classes are facing-relative
	# (forward > crossover > backward), so a goal-facing carrier thrusting
	# toward a lateral anchor (a wall exit, the seam it just deked to) skated
	# the whole route in the slow crossover class — beaten defenders caught
	# back up, and the sideways posture also kept the far side of the ice
	# out of the blade's reach cone. Facing the route gives the fast forward
	# stride and centers the reach cone on the play. The GOAL-facing default
	# above still owns two cases: a route too short to define a direction
	# (settling on a spot — face the play), and a genuine RETREAT (advance
	# component below CARRY_FACE_RETREAT_ADVANCE — a regroup backs out
	# facing the play, the real posture, paying the honest backward-speed
	# cost). Fire-tracking (_carry_aim_track_fire) overrides all of this
	# with the shot aim whenever a live look exists.
	# O-ZONE SQUARE: once the carrier is in the offensive zone with no man to
	# beat, point the body straight at the GOALIE — square to the net, every
	# shot/pass option open — instead of skating on along a lateral carry route
	# into the awkward sideways angle (the "weird sideways shot" after a deke).
	# This owns the facing outright in that case (skips FACE THE ROUTE): a slot
	# repositioning with nobody to beat is walked facing the net, the real
	# shooter's posture, not skated back-to-play. Outside the O-zone, and while a
	# man still has to be beaten, FACE THE ROUTE below keeps the fast forward
	# stride down a lateral escape / wall-exit route.
	var squared_to_net: bool = false
	if AIActionScoring.in_offensive_zone(self_pos, _attacking_goal_pos) \
			and not _has_man_to_beat(snapshot, self_pos):
		var goalie_square: Vector3 = _goalie_now(snapshot)
		var to_goalie: Vector3 = goalie_square - self_pos
		to_goalie.y = 0.0
		if to_goalie.length_squared() > 0.0001:
			forward_dir = to_goalie.normalized()
			squared_to_net = true
	var route: Vector3 = _last_carry_anchor - self_pos
	route.y = 0.0
	if not squared_to_net \
			and route.length_squared() >= CARRY_FACE_ROUTE_MIN_DIST_M * CARRY_FACE_ROUTE_MIN_DIST_M:
		var route_dir: Vector3 = route.normalized()
		if route_dir.z * attacking_z >= CARRY_FACE_RETREAT_ADVANCE:
			forward_dir = route_dir
	# Cradle the puck tight to the body when working behind/beside the net so the
	# blade (and the offset puck on it) stays out of the cage — see
	# _carry_reach_behind_net. Full reach everywhere else.
	var reach: float = _carry_reach_behind_net(self_pos)
	var base: Vector3 = self_pos + forward_dir * reach
	# Stickhandling offset is raw — `_step_mouse_toward` provides the
	# motion smoothing across ticks. When two defenders converge from
	# opposite sides and the raw target alternates per tick, the
	# motion model averages them out (mouse oscillates within a small
	# range bounded by the per-tick step). Folded in BEFORE the protect
	# blend below, so shielding pressure attenuates it along with
	# everything else: a blade pinned to the protect seam doesn't get
	# pulled back into the checker's reach.
	var target: Vector3 = base + _stickhandle_offset(snapshot, self_pos, forward_dir)
	# Puck protection (protects_the_puck tiers): swing the blade from the
	# presented-forward carry toward the protected seam of the handling envelope
	# — typically the hip away from the checker, putting the body between puck and
	# stick. The blend weight is the carrier's protect_gain: the SAFETY the shield
	# buys (seam clearance − forward clearance), so it engages exactly to the
	# degree shielding actually helps and stays at 0 when the forward puck is
	# already safe or no safer seam exists — necessity AND ability, with no
	# pressure floor (see AIRoleCarrier's protect mirror). The seam offset is
	# re-based on the LIVE body position (the carrier mirror refreshes at ~30 Hz)
	# and projected out to the carry aim ring: the arc-step in `_step_mouse_aim`
	# reads direction only, so a short raw offset would under-weight the protect
	# side in a positional lerp.
	# Low-pass the shield toward the carrier mirror's raw read so the blend eases
	# in/out instead of stepping when the raw value flips — a defender crossing the
	# directional screen filter (PROTECT_SCREEN_BEHIND_M) or the ~30 Hz mirror
	# re-eval used to snap protect_gain, swinging the blade between the play line
	# and the seam. Runs every carry-aim tick (including when the raw read is zero,
	# so a disengaging shield decays smoothly); reset to zero on CARRY entry so a
	# pickup starts unshielded. Non-protect tiers hold the raw read at zero.
	var raw_gain: float = _carrier.protect_gain if _protects_the_puck else 0.0
	var raw_offset: Vector3 = _carrier.protect_offset if _protects_the_puck else Vector3.ZERO
	var smooth_t: float = clampf(CARRY_PROTECT_SMOOTH_RATE * _current_delta, 0.0, 1.0)
	_carry_protect_gain_smooth = lerpf(_carry_protect_gain_smooth, raw_gain, smooth_t)
	_carry_protect_offset_smooth = _carry_protect_offset_smooth.lerp(raw_offset, smooth_t)
	var protect_w: float = _carry_protect_gain_smooth
	if _protects_the_puck and protect_w > 0.0:
		var protect_dir: Vector3 = _carry_protect_offset_smooth
		protect_dir.y = 0.0
		if protect_dir.length_squared() > 0.0025:
			# Shield with REACH, not a spin: clamp how far the protect aim swings off
			# the play line (CARRY_PROTECT_MAX_TURN_DEG). The body turns only to
			# side-on to interpose; the blade ROM covers the rest of the seam.
			var prot2 := Vector2(protect_dir.x, protect_dir.z).normalized()
			var fwd2 := Vector2(forward_dir.x, forward_dir.z)
			if fwd2.length_squared() > 0.0001:
				fwd2 = fwd2.normalized()
				var turn: float = fwd2.angle_to(prot2)
				var max_turn: float = deg_to_rad(CARRY_PROTECT_MAX_TURN_DEG)
				if absf(turn) > max_turn:
					prot2 = fwd2.rotated(signf(turn) * max_turn)
			var protect_target: Vector3 = self_pos \
					+ Vector3(prot2.x, 0.0, prot2.y) * reach
			target = target.lerp(protect_target, minf(protect_w, 1.0))
	# Clamp the carry mouse so it stays on the rink side of the
	# attacking goal line — the blade IK chases the mouse, and a mouse
	# target past the goal line punches the blade through the net.
	var goal_line_z: float = _attacking_goal_pos.z
	var max_forward_z: float = goal_line_z + AIRoleHelpers.GOAL_LINE_BUFFER_M * _own_goal_dir
	if (target.z - max_forward_z) * _own_goal_dir < 0.0:
		target.z = max_forward_z
	# ...and inside the boards by a blade of standoff (see
	# CARRY_BLADE_WALL_MARGIN_M): the forward aim + stickhandle/protect
	# offsets have no wall awareness of their own, so a carrier maneuvering
	# along the boards would otherwise drive its blade into the kickplate and
	# knock its own puck loose. Clamped last so every offset above is covered;
	# pinned tight, the target slides ALONG the wall instead of into it.
	var on_ice: Vector2 = GameRules.clamp_to_rink_inner(
			Vector2(target.x, target.z), CARRY_BLADE_WALL_MARGIN_M)
	target.x = on_ice.x
	target.z = on_ice.y
	# ...and never THROUGH a net frame (the same standard, cage edition): a
	# behind-the-net carrier's forward/route aim chords straight through the
	# cage, the blade IK chases it into the mesh, and stick-on-net contact
	# dislodges the carried puck — the behind-the-net giveaway. The chord is
	# swung around the nearer post — the blade-level mirror of the body's
	# AISteering._net_detour.
	return AIActionScoring.net_safe_blade_target(self_pos, target)


# True when any GOAL-SIDE opponent is inside the contest band
# (CARRY_MAN_TO_BEAT_RADIUS_M) of the carrier — a defender ahead toward the net,
# close enough to poke/steal, i.e. a man the carrier still has to beat. A
# defender the carrier has already skated past (behind it toward our own end by
# more than CARRY_MAN_TO_BEAT_BEHIND_M along the netward line) is beaten and does
# NOT count, so the carrier squares up the instant it clears him. With no such
# man the carrier is unobstructed. Measured from the body so a checker on any
# side ahead counts.
#
# BOTH BODIES ARE PROJECTED to the evasion horizon, matching the read the protect
# screen filter already runs (AIRoleCarrier._fill_protect_opponents). "Have I
# beaten him?" is a question about the CLOSING RATE, and a frozen snapshot cannot
# answer it: a chaser half a stride behind and losing ground is gone, while one
# in the same spot and pulling even is the man you still have to beat. Reading
# raw positions, the carrier kept both — so a beaten checker riding the hip held
# the square-to-net facing off for as long as he trailed inside the slack, and
# the carrier drove the zone at a lateral angle with its options shut down (the
# "holds the stickhandling angle after cleanly beating his man" report), while a
# back-checker about to pull even was written off a beat early. The slack and the
# hysteresis stay what they are — a body length of tolerance and a debounce — but
# they now sit on a read that can see who is actually going where. Runs on the
# carrier only (~1 bot/team) and loops the small opponent set, so it's hot-path
# cheap.
func _has_man_to_beat(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	# Sticky contest (see CARRY_MAN_TO_BEAT_HYSTERESIS_M): while a man is already
	# being beaten, widen the radius AND the behind-slack so a defender riding the
	# boundary keeps the same answer rather than flipping the square-to-net facing.
	var radius: float = CARRY_MAN_TO_BEAT_RADIUS_M
	var behind: float = CARRY_MAN_TO_BEAT_BEHIND_M
	if _carry_has_man:
		radius += CARRY_MAN_TO_BEAT_HYSTERESIS_M
		behind += CARRY_MAN_TO_BEAT_HYSTERESIS_M
	var r2: float = radius * radius
	var to_net: Vector3 = _attacking_goal_pos - self_pos
	to_net.y = 0.0
	var net_len: float = to_net.length()
	var have_net: bool = net_len > 0.001
	var nx: float = to_net.x / net_len if have_net else 0.0
	var nz: float = to_net.z / net_len if have_net else 0.0
	var horizon: float = AIActionScoring.EVADE_HORIZON_S
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	var self_x: float = self_pos.x
	var self_z: float = self_pos.z
	if self_state != null:
		self_x += self_state.velocity.x * horizon
		self_z += self_state.velocity.z * horizon
	var found: bool = false
	for peer_id: int in _opponent_ids(snapshot):
		var opp_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		var dx: float = opp_state.position.x + opp_state.velocity.x * horizon - self_x
		var dz: float = opp_state.position.z + opp_state.velocity.z * horizon - self_z
		if dx * dx + dz * dz >= r2:
			continue
		# Goal-side (ahead toward the net) beyond the beaten-behind slack.
		if not have_net or dx * nx + dz * nz > -behind:
			found = true
			break
	_carry_has_man = found
	return found


# Computes the perpendicular puck-evade offset for stickhandling.
# Sums signed-lateral forces from every opposing blade within
# STICKHANDLE_THREAT_RADIUS_M of our puck (carry-arm extension
# forward of body), each weighted by its distance ramp. Returns
# an XZ offset perpendicular to `forward_dir`, away from the
# threat side, clamped to STICKHANDLE_OFFSET_MAX_M magnitude.
#
# Summing instead of picking-nearest-then-flipping kills the jitter
# the earlier nearest-threat version produced when surrounded: the
# "nearest" could swap between defenders per tick, snapping the
# offset between full-left and full-right. With a sum, opposite-side
# threats cancel (nowhere safe to go, blade holds central — correct
# tactically) and same-side threats reinforce (clamped at the same
# per-tick max as before). Threats nearly directly ahead contribute
# near-zero lateral instead of sign-flipping at the perpendicular
# boundary.
#
# Uses `opp_state.blade_contact_world` — host-only field, populated
# for every skater on the host. Bots only run on the host
# (AIController is host-gated via PlayerRegistry.spawn_bot), so this
# read is safe; the ZERO-check below covers the first-tick window
# before SkaterController has populated it.
func _stickhandle_offset(snapshot: WorldSnapshot, self_pos: Vector3, forward_dir: Vector3) -> Vector3:
	# Right-axis (XZ): forward rotated 90° CW around Y.
	var right_axis: Vector3 = Vector3(forward_dir.z, 0.0, -forward_dir.x)
	# Carrier's puck sits near the blade target, ~CARRY_BLADE_AIM_FORWARD_M
	# forward of the body. Measure threat distance from THIS point so we
	# react to actual stick-on-puck reach, not stick-on-body distance.
	var carry_pos: Vector3 = self_pos + forward_dir * CARRY_BLADE_AIM_FORWARD_M
	# Accumulated lateral force in [-summed, +summed]. Positive = pull
	# toward +right_axis (because we negate per-threat lateral_unit:
	# threat on right → lateral_unit > 0 → contribution -ramp ×
	# lateral_unit < 0 → pulls puck to the left, away from threat).
	# Clamped post-sum so multiple same-side threats don't push past
	# the per-tick max offset.
	var lateral_force: float = 0.0
	for peer_id: int in _opponent_ids(snapshot):
		var opp_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		var threat_pos: Vector3 = opp_state.blade_contact_world
		if threat_pos == Vector3.ZERO:
			threat_pos = opp_state.position
		var to_threat: Vector3 = threat_pos - carry_pos
		to_threat.y = 0.0
		var dist: float = to_threat.length()
		if dist > STICKHANDLE_THREAT_RADIUS_M or dist < 0.001:
			continue
		# Per-threat distance ramp: full inside the inner radius,
		# tapering linearly to zero at the outer radius.
		var ramp: float = clampf(inverse_lerp(
				STICKHANDLE_THREAT_RADIUS_M,
				STICKHANDLE_FULL_OFFSET_RADIUS_M,
				dist), 0.0, 1.0)
		# Lateral component of the unit direction TOWARD the threat in
		# [-1, 1]. Direct-ahead → ~0, direct-side → ±1. Multiplying
		# by ramp gives a smooth per-threat contribution; summing
		# blends all of them.
		var lateral_unit: float = right_axis.dot(to_threat) / dist
		lateral_force -= lateral_unit * ramp
	var magnitude: float = clampf(lateral_force, -1.0, 1.0) * STICKHANDLE_OFFSET_MAX_M
	return right_axis * magnitude



# Poke-evade maneuver. Overrides the steering inputs for a brief committed
# window when a poke is imminent: a CUT toward the carrier's directed
# evasion seam on the protects_the_puck tiers (a real deke past the
# pressure toward the carry objective — the direction is latched at
# trigger, see _seam_cut_direction; perpendicular fallback otherwise), or
# a BRAKE CHECK (real brake key held for POKE_EVADE_BRAKE_TICKS, exit
# direction on the stick) when the carrier's re-eval read the braked hold
# as clearly beating the cut (_carrier.brake_check_favored). Continuous
# defender avoidance (threat-gated repel in body steering + stickhandle
# offset on the blade) handles the baseline; this is the discrete "deke
# moment" when a defender's blade is close enough that a poke is imminent
# — the committed window breaks the defender's projected interception
# line.
#
# Lifecycle (counters live on the state machine, both reset on
# CARRY entry):
#   - Active > 0: brake mid-evade. Decrement; on hitting 0, kick
#     off the cooldown.
#   - Cooldown > 0: no retrigger. Decrement; fall through to normal
#     steering so anchor attraction pulls us back on line.
#   - Both zero: scan for trigger. First qualifying opp activates.
#
# Trigger criteria (ALL must hold):
#   - Own velocity ≥ POKE_EVADE_MIN_SELF_SPEED_M_S (cutting from
#     near-standstill is pointless and just looks like a wiggle).
#   - Opp blade within POKE_EVADE_TRIGGER_REACH_M of our puck.
#   - Opp in our FRONT hemisphere relative to our velocity (cutting
#     when defender chases from behind would just help them catch up).
#   - RELATIVE closing between us and the opp ≥ MIN_CLOSING_VEL_M_S — the
#     carrier driving at a waiting defender closes the gap too, so it triggers
#     the deke (only a defender neither approaching nor being approached is skipped).
func _poke_evade_modulate_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	if _poke_evade_active_ticks > 0:
		_drive_poke_evade_cut(input, self_pos)
		# Decrement by the dispatch span (this runs once per dispatch, but the
		# window is sized in physics ticks) so the cut lasts its intended wall time
		# instead of dispatch_period× longer at Normal/Easy.
		_poke_evade_active_ticks -= _dispatch_period_ticks
		if _poke_evade_active_ticks <= 0:
			_poke_evade_active_ticks = 0
			_poke_evade_cooldown_ticks = DEKE_COOLDOWN_TICKS \
					if _poke_evade_deking else POKE_EVADE_COOLDOWN_TICKS
			_poke_evade_braking = false
			_poke_evade_deking = false
		return
	if _poke_evade_cooldown_ticks > 0:
		_poke_evade_cooldown_ticks = maxi(0, _poke_evade_cooldown_ticks - _dispatch_period_ticks)
		return
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		return
	var vel_xz := Vector2(self_state.velocity.x, self_state.velocity.z)
	var speed: float = vel_xz.length()
	if speed < POKE_EVADE_MIN_SELF_SPEED_M_S:
		# Too slow for the lateral cut (it would read as a wiggle) — but the
		# STANDSTILL duel is exactly the fake-then-cut deke's home: a patient
		# container parked in front, nobody moving. Commit the deke when the
		# carrier's re-eval says the fake manufactures an opening.
		if _carrier.deke_go:
			_start_deke(input, self_pos)
		return
	var forward: Vector2 = vel_xz / speed
	# Puck pos approximation — same carry-arm offset the stickhandle
	# uses, so the trigger band is consistent across the two defenses.
	var forward_3d := Vector3(forward.x, 0.0, forward.y)
	var carry_pos: Vector3 = self_pos + forward_3d * CARRY_BLADE_AIM_FORWARD_M
	var trigger_threat: SkaterNetworkState = null
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if _team_id_by_peer.get(peer_id, -1) == _team_id:
			continue
		var opp_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		var threat_pos: Vector3 = opp_state.blade_contact_world
		if threat_pos == Vector3.ZERO:
			threat_pos = opp_state.position
		var blade_to_puck: Vector3 = threat_pos - carry_pos
		blade_to_puck.y = 0.0
		if blade_to_puck.length() > POKE_EVADE_TRIGGER_REACH_M:
			continue
		# Front-hemisphere gate vs OUR velocity direction (not facing).
		# The defender's poke is timed for where we're MOVING, not
		# where we're looking — and the brief cut breaks momentum
		# projection. Defender body relative to us, dotted with our
		# velocity dir, must be positive (defender is "ahead").
		var to_opp_3d: Vector3 = opp_state.position - self_pos
		to_opp_3d.y = 0.0
		var to_opp_len: float = to_opp_3d.length()
		if to_opp_len < 0.001:
			continue
		var to_opp_norm: Vector3 = to_opp_3d / to_opp_len
		if to_opp_norm.x * forward.x + to_opp_norm.z * forward.y <= 0.0:
			continue
		# RELATIVE closing along the bot-to-opp line — the carrier's OWN approach
		# counts, not just the defender's. Skating into a stationary / angled defender
		# closes the gap just as surely as one stepping up, and that's exactly when the
		# carrier needs to deke past it. The old defender-only closing never fired
		# against a waiting defender the carrier drove at — the bot skated straight
		# into the poke instead of cutting around it.
		var closing: float = (self_state.velocity - opp_state.velocity).dot(to_opp_norm)
		if closing < POKE_EVADE_MIN_CLOSING_VEL_M_S:
			continue
		trigger_threat = opp_state
		break
	if trigger_threat == null:
		# CONTAINMENT trigger — the stalemate the poke scan can't see: a
		# patient container never closes fast enough to register as an
		# imminent poke, so nothing ever fired and the duel stood still.
		# When the carrier's re-eval says a fake would MANUFACTURE an
		# opening that doesn't exist (deke_go), commit the deke here.
		if _carrier.deke_go:
			_start_deke(input, self_pos)
		return
	# Maneuver pick, latched for the whole window — priority by what each
	# answers: a BRAKE CHECK when the carrier's last re-eval read the braked
	# hold as clearly beating the cut (committed pressure — let his reach fly
	# past the stopped puck); else the FAKE-THEN-CUT deke when a fake
	# manufactures the opening (patient pressure); else the committed cut
	# toward the directed seam (clearance that already exists). NO usable
	# maneuver — no seam direction (Easy's closed protect gate, or a seam
	# underfoot), no brake read, no deke read — means no trigger at all: the
	# window and its cooldown are only ever spent on a committed move. Easy
	# simply has no deke (its poke-evade never fires — the naive carry a
	# poke-check beats, per the tier doc), and a protect-tier carrier whose
	# seam is underfoot is being told to HOLD, which the protect blade-work
	# already handles.
	var braking: bool = _carrier.brake_check_favored
	if not braking and _carrier.deke_go:
		_start_deke(input, self_pos)
		return
	var cut_dir: Vector2 = _seam_cut_direction(self_pos)
	if cut_dir == Vector2.ZERO and not braking:
		return
	_poke_evade_braking = braking
	_poke_evade_dir = cut_dir
	_poke_evade_active_ticks = POKE_EVADE_BRAKE_TICKS if braking \
			else POKE_EVADE_ACTIVE_TICKS
	_drive_poke_evade_cut(input, self_pos)


# The latched deke direction: toward the carrier's DIRECTED evasion seam — the
# reachable-set escape with the most progress toward the carry objective, from
# the last carrier re-eval (≤ ~33 ms stale, re-based on the live body
# position). The seam already reads every defender's momentum, so a committed
# charger's cut resolves BEHIND him (the cutback that lets him overshoot) and a
# jockeying defender's resolves past his open side. ZERO when this tier doesn't
# protect the puck, no seam is computed yet, or the seam is underfoot — all of
# which mean "no usable deke", and (absent a brake read) the poke-evade then
# doesn't trigger at all.
func _seam_cut_direction(self_pos: Vector3) -> Vector2:
	if not _protects_the_puck:
		return Vector2.ZERO
	var seam: Vector3 = _carrier.evade_seam_world
	if not seam.is_finite():
		return Vector2.ZERO
	var to_seam := Vector2(seam.x - self_pos.x, seam.z - self_pos.z)
	if to_seam.length() < POKE_EVADE_SEAM_MIN_DIST_M:
		return Vector2.ZERO
	return to_seam.normalized()


# Latch and start the FAKE-THEN-CUT deke: one committed window covering both
# phases; the drive below splits them on the remaining ticks. Directions come
# from the carrier's manufactured-opening read (same axis frame as the eval,
# so the gesture performed is the gesture priced).
func _start_deke(input: InputState, self_pos: Vector3) -> void:
	_poke_evade_deking = true
	_deke_fake_dir = _carrier.deke_fake_dir
	_deke_cut_dir = _carrier.deke_cut_dir
	_poke_evade_dir = Vector2.ZERO
	_poke_evade_active_ticks = DEKE_FAKE_TICKS + DEKE_CUT_TICKS
	_drive_poke_evade_cut(input, self_pos)


# One active-window tick of the committed maneuver. DEKE: thrust the fake
# side while the fake phase lasts, then explode across to the cut side (the
# carry cursor sells and snaps with it — see _deke_mouse_target). BRAKE
# CHECK: the real brake key with move_vector held on the exit direction (the
# live carry anchor) — the same input shape as the brake-pivot, so the
# physics gets the heavy brake friction and thrust resumes toward the anchor
# the instant the window releases; the beaten checker no longer registers in
# the threat-gated repel, so the exit bursts straight past him. CUT: the seam
# direction latched at trigger (guaranteed non-zero — a directionless evade
# never triggers).
func _drive_poke_evade_cut(input: InputState, self_pos: Vector3) -> void:
	if _poke_evade_deking:
		input.move_vector = _deke_fake_dir \
				if _poke_evade_active_ticks > DEKE_CUT_TICKS else _deke_cut_dir
		return
	if _poke_evade_braking:
		input.brake = true
		var exit := Vector2(_last_carry_anchor.x - self_pos.x,
				_last_carry_anchor.z - self_pos.z)
		if exit.length_squared() > 0.01:
			input.move_vector = exit.normalized()
		return
	input.move_vector = _poke_evade_dir


# The deke's carry-cursor override: sell the fake WITH THE PUCK — the
# defender's read tracks the puck, not the chest — then snap it across for
# the cut; the pull through the wide ROM is the visible toe-drag. INF when no
# deke is active (the normal carry aim runs). Board + net clamps keep the
# blade legal against the walls and the cage.
func _deke_mouse_target(self_pos: Vector3) -> Vector3:
	if not _poke_evade_deking or _poke_evade_active_ticks <= 0:
		return Vector3.INF
	var dir: Vector2 = _deke_fake_dir \
			if _poke_evade_active_ticks > DEKE_CUT_TICKS else _deke_cut_dir
	if dir == Vector2.ZERO:
		return Vector3.INF
	var target := Vector3(
			self_pos.x + dir.x * CARRY_BLADE_AIM_FORWARD_M, 0.0,
			self_pos.z + dir.y * CARRY_BLADE_AIM_FORWARD_M)
	var on_ice: Vector2 = GameRules.clamp_to_rink_inner(
			Vector2(target.x, target.z), CARRY_BLADE_WALL_MARGIN_M)
	target.x = on_ice.x
	target.z = on_ice.y
	return AIActionScoring.net_safe_blade_target(self_pos, target)


# Defensive poke jab. Returns the aim point (the carrier's puck
# position) when a puck-pressurer should reach its blade through the
# puck to trigger a host strip; Vector3.INF when no jab is active.
#
# Runs the discrete jab lifecycle (mirror of the offensive poke-evade):
#   - active > 0: keep aiming at the puck; decrement, start cooldown at 0.
#   - cooldown > 0: decrement, no jab (commit back to gap control).
#   - both 0: trigger a fresh jab iff we're an on-puck defensive role and
#     within reach of an opposing carrier's puck.
# Only the puck-pressurer slots jab (PRESSURE / F1_PRESSURE / the rush pair) —
# the backside roles keep pure positioning, so the team doesn't collapse
# two bots onto the puck.
func _poke_jab_aim(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	if _poke_jab_active_ticks > 0:
		# Dispatch-span decrement (see _poke_evade_modulate_steering): the ~80 ms
		# jab window is in physics ticks but this runs once per dispatch.
		_poke_jab_active_ticks -= _dispatch_period_ticks
		if _poke_jab_active_ticks <= 0:
			_poke_jab_active_ticks = 0
			_poke_jab_cooldown_ticks = POKE_JAB_COOLDOWN_TICKS
		return _carrier_puck_pos(snapshot)
	if _poke_jab_cooldown_ticks > 0:
		_poke_jab_cooldown_ticks = maxi(0, _poke_jab_cooldown_ticks - _dispatch_period_ticks)
		return Vector3.INF
	if not _is_puck_pressurer_slot(snapshot):
		return Vector3.INF
	if snapshot.puck_state == null:
		return Vector3.INF
	# Must be an opposing carrier (not loose, not a teammate carrying).
	var carrier_pid: int = snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1 or _team_id_by_peer.get(carrier_pid, -1) == _team_id:
		return Vector3.INF
	var puck_pos: Vector3 = snapshot.puck_state.position
	var dx: float = puck_pos.x - self_pos.x
	var dz: float = puck_pos.z - self_pos.z
	if dx * dx + dz * dz > _poke_jab_reach * _poke_jab_reach:
		return Vector3.INF
	_poke_jab_active_ticks = POKE_JAB_ACTIVE_TICKS
	return puck_pos


# True if our current brain slot is an on-puck defensive pressurer —
# the only roles that actively jab. (PRESSURE is DZONE; F1_PRESSURE is
# FORECHECK; RUSH_D1 is the transition gap defender on the carrier and
# TRACK_PUCK is the backchecker running him down — both are on the puck by
# definition, and a backchecker who catches a carrier without being allowed to
# poke at him is just escorting. In 5v5's
# zone DZONE, the pressurer is whichever area role currently OWNS the puck —
# AIZoneCoverage.pressure_owner — so exactly one zone defender ever jabs.)
func _is_puck_pressurer_slot(snapshot: WorldSnapshot) -> bool:
	if _current_strategy == null:
		return false
	var slot: int = _current_strategy.get_slot(_peer_id)
	if slot == AIRoleSlots.Slot.PRESSURE \
			or slot == AIRoleSlots.Slot.F1_PRESSURE \
			or slot == AIRoleSlots.Slot.RUSH_D1 \
			or slot == AIRoleSlots.Slot.TRACK_PUCK:
		return true
	match slot:
		AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK, \
		AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG, \
		AIRoleSlots.Slot.ZONE_W_WEAK:
			if snapshot == null or snapshot.puck_state == null:
				return false
			return AIZoneCoverage.pressure_owner(
					_current_strategy.strong_x(),
					_own_goal_dir * GameRules.GOAL_LINE_Z,
					snapshot.puck_state.position) == slot
	return false


# The opposing carrier's puck position, or Vector3.INF if no carrier.
# Used as the jab aim point — aiming the blade at the puck makes the IK
# sweep the blade through it, which the host strip detection picks up.
func _carrier_puck_pos(snapshot: WorldSnapshot) -> Vector3:
	if snapshot.puck_state == null or snapshot.puck_state.carrier_peer_id == -1:
		return Vector3.INF
	return snapshot.puck_state.position


# Shot aim past the goalie's projected shadow. Uses the goalie's
# predicted position at `release_lookahead_s` from now — defaults to
# the wrister window for a charged shot, override to 0.0 for a
# quick-shot (no charge → goalie hasn't slid by release). Threads
# the goalie's CURRENT lateral velocity into the aim — a goalie
# sliding right will drift further right by the time the puck
# arrives, so the aim biases LEFT (the recovery side). Captures the
# "shoot back across the grain" pattern — unless this tier is
# goalie-motion blind (_reads_goalie_motion false: it shoots at where
# the goalie IS, the cognition gate's aim-side half).
func _shot_aim_point(snapshot: WorldSnapshot, self_pos: Vector3,
		release_lookahead_s: float = BOT_WRISTER_LOOKAHEAD_S) -> Vector3:
	var goalie: Vector3 = _predict_goalie_at(
			snapshot, release_lookahead_s, self_pos)
	var goalie_vx: float = 0.0
	var opp_team_id: int = 1 - _team_id
	var opp_goalie_state: GoalieNetworkState = snapshot.goalie_states.get(opp_team_id)
	if opp_goalie_state != null and _reads_goalie_motion:
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
#
# The near threshold matches the sprint-engage gap (BotSprintRules.
# GAP_ENGAGE_M): a move long enough to sprint is a committed skate —
# face the travel direction for full thrust; anything shorter is
# positioning, and positioning happens eyes-on-the-play (crossovers /
# shuffles), like a real off-puck player. The old 2 m threshold meant
# bots faced their travel direction almost always — role anchors move
# continuously, so station-keeping bots were forever "far" from a
# drifting anchor and visibly looked away from the play.
const READY_STANCE_AIM_FORWARD_M: float = 2.0
const FACE_THREAT_NEAR_ANCHOR_M: float = BotSprintRules.GAP_ENGAGE_M
# Debounce band around FACE_THREAT_NEAR_ANCHOR_M for the far→anchor / near→threat
# aim flip (see _compute_desired_aim_dir). A bot must cross this far past the
# threshold before the aim direction switches, so orbiting at the boundary
# doesn't swing the blade between the anchor and the puck every tick.
const FACE_NEAR_ANCHOR_HYSTERESIS_M: float = 0.75
# Below this puck→self distance the direction is too short to aim by, so the
# threat read holds current facing instead (see _face_threat_or_current). A
# geometry floor, debounced by FACE_THREAT_MIN_DIST_HYSTERESIS_M so a puck
# dancing across it doesn't flip the ready-stance aim (now that off-puck aim
# refreshes live, a bare threshold would chatter at the tick rate).
const FACE_THREAT_MIN_DIST_M: float = 0.3
const FACE_THREAT_MIN_DIST_HYSTERESIS_M: float = 0.15
# Tag-up override: a ghosted bot racing back to the blue line faces its
# travel direction until nearly there — the tag-up is a sprint, not
# positioning, so it keeps the old tight face-travel threshold.
const FACE_TRAVEL_TAG_UP_NEAR_M: float = 2.0

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
# the tick budget. First call snaps to the target.
#
# Two entry points wrap the shared `_step_mouse_internal`:
#
#   _step_mouse_aim — arcs the target around self_pos on the carry aim ring
#   before stepping. Use for "body-aim" targets (CARRY, OFF_PUCK,
#   tag-up). The arc keeps the mouse-body angle inside the pose
#   coordinator's IK gate (~157°) so facing can always track the
#   mouse, even when the target flips 180° (anchor behind us after
#   a role re-eval, or transitioning out of a back-pass press with
#   the mouse parked behind the body). Without it, a single straight
#   chord across self_pos trips the gate and leaves facing
#   permanently locked opposite to where the bot is skating.
#
#   _step_mouse_toward — direct chord, no arc. Use for press states
#   (wrister windup interpolates a specific blade path that
#   arc-snapping would distort; facing is locked during press
#   states anyway, so the gate trip can't strand it) and for the
#   chase state's CLOSE-RANGE aims — the puck inside blade reach and
#   the blade gate on a fast puck's line, where the exact point
#   matters for the pickup and a ring projection would overshoot
#   it. The chase's FAR intercept aim arcs (_step_mouse_aim): a
#   direct chord to an intercept behind the bot crosses the body and
#   freezes facing in the IK gate's back wedge.
# Cursor-shaping modes for _step_mouse_internal:
#   DIRECT — chord straight toward the target at the slew cap (chase / press).
#   ARC    — walk the target around the body ring at the blade slew (CARRY / blade
#            pre-aim), keeping the mouse-body angle inside the IK gate mid-swing.
#   FACE   — snap the cursor to where the bot wants to point, clamped to the
#            reachable cone; facing_drag_speed is the sole turn limit.
const _STEP_DIRECT: int = 0
const _STEP_ARC: int = 1
const _STEP_FACE: int = 2

# Headroom below the pose IK gate (_self_reach_cone_half_angle) that a FACE-mode
# cursor is clamped to, so it never sits exactly on the freeze boundary. Only
# affects a target in the back wedge; the body still walks all the way around to
# it as facing rotates and the clamp releases.
const FACE_GATE_MARGIN_RAD: float = deg_to_rad(6.0)


func _step_mouse_aim(target: Vector3) -> Vector3:
	return _step_mouse_internal(target, _STEP_ARC, _mouse_max_speed_m_s, _mouse_arc_rate_rad_s)


# Body-FACING aim (off-puck ready stance, tag-up, one-timer/jab pre-aim): places
# the cursor DIRECTLY at where the bot wants to point — like a human flicking the
# mouse — with NO slew smoothing. There's no puck on the blade to dangle off-puck,
# so the cursor is pure pointing intent; the body then turns toward it at
# facing_drag_speed in the pose coordinator, which is the ONE real
# rotation limit and exactly the limit a human plays under. The only shaping is a
# clamp to the reachable cone (see _clamp_aim_to_reach_cone): the pose IK gate
# FREEZES facing if the cursor sits in the back wedge, so a target behind the bot
# is clamped to the cone edge on its side — facing rotates to that edge at full
# speed, the target's relative angle shrinks, and the body walks around to it. Any
# implied blade motion stays clamped to the real max_blade_speed downstream.
func _step_mouse_face(target: Vector3) -> Vector3:
	return _step_mouse_internal(target, _STEP_FACE, MOUSE_MAX_SPEED_M_S, MOUSE_ARC_RATE_RAD_S)


func _step_mouse_toward(target: Vector3) -> Vector3:
	return _step_mouse_internal(target, _STEP_DIRECT, _mouse_max_speed_m_s, _mouse_arc_rate_rad_s)


# Sample this release's execution error from the given per-tier budget —
# both radians on the release direction, so no ring-radius conversion exists
# to drift when the carry aim ring moves (the scoring spread reads the same
# angle directly). Called once per press-state entry (_set_state); uniform ±
# so the release-tick distribution matches the old per-tick noise the scoring
# budget was calibrated against. Zero budget (raw test agents) returns 0
# WITHOUT advancing the RNG, keeping the bare state machine bit-deterministic.
func _sample_aim_error_rad(budget_rad: float) -> float:
	if budget_rad == 0.0:
		return 0.0
	return _rng.randf_range(-1.0, 1.0) * budget_rad


# Sample this shot's late-release hold (ticks past the completed charge) from
# the per-tier motor timing variance. Uniform in [0, max] — the eval budgeted
# the MEAN (max/2) into the goalie's tracking time, so the score is the
# median outcome and the two halves of this draw decide the thin windows:
# below the mean beats the race the score priced, above it hands the goalie
# more time than the score conceded and the shot can get robbed. Zero
# variance (raw test agents / perfect baseline) returns 0 without advancing
# the RNG.
func _sample_release_hold_ticks() -> int:
	if _shot_timing_error_s == 0.0:
		return 0
	return _rng.randi_range(
			0, int(round(_shot_timing_error_s * _PhysicsConstants.PHYSICS_TICK)))


# Rotate an aim point around `pivot` by the committed per-release error.
# Applied to press-state aim geometry only — the error is a property of the
# RELEASE gesture, not of tracking (which stays clean and smooth).
func _apply_committed_aim_error(pivot: Vector3, aim_point: Vector3) -> Vector3:
	if _committed_aim_error_rad == 0.0:
		return aim_point
	var offset: Vector3 = aim_point - pivot
	return pivot + offset.rotated(Vector3.UP, _committed_aim_error_rad)


func _step_mouse_internal(target: Vector3, mode: int,
		max_speed: float, arc_rate: float) -> Vector3:
	# Cache the FINAL un-shaped target, mode, and rates so the skipped-tick path can
	# re-shape fresh every physics frame (the arc must re-walk, and the face clamp
	# must re-evaluate against the current facing); otherwise shaping would only
	# advance on full-dispatch ticks and a swing would take DISPATCH_PERIOD_TICKS×
	# too long.
	_cached_aim_target = target
	_has_cached_aim_target = true
	_cached_aim_mode = mode
	_cached_aim_max_speed = max_speed
	_cached_aim_arc_rate = arc_rate
	var step_target: Vector3 = target
	if mode == _STEP_ARC:
		step_target = _arc_step_mouse_target(
				_current_self_pos, target, _current_self_state, arc_rate)
	elif mode == _STEP_FACE:
		# Snap the cursor to the clamped point (facing_drag_speed does all the
		# smoothing), so return straight out without the linear slew below.
		step_target = _clamp_aim_to_reach_cone(
				_current_self_pos, target, _current_self_state)
		_mouse_pos = Vector3(step_target.x, 0.0, step_target.z)
		_mouse_pos_initialized = true
		return Vector3(_mouse_pos.x, 0.0, _mouse_pos.z)
	if not _mouse_pos_initialized:
		_mouse_pos = Vector3(step_target.x, 0.0, step_target.z)
		_mouse_pos_initialized = true
	var to_target_x: float = step_target.x - _mouse_pos.x
	var to_target_z: float = step_target.z - _mouse_pos.z
	var dist: float = sqrt(to_target_x * to_target_x + to_target_z * to_target_z)
	var max_step: float = max_speed * MOUSE_TICK_DELTA
	if dist > max_step:
		var inv: float = 1.0 / dist
		_mouse_pos.x += to_target_x * inv * max_step
		_mouse_pos.z += to_target_z * inv * max_step
	else:
		_mouse_pos.x = step_target.x
		_mouse_pos.z = step_target.z
	# Output IS the smooth _mouse_pos — no per-tick noise. Execution
	# imperfection lives in the per-release sampled aim error (press-state
	# geometry), which moves the TARGET smoothly instead of shaking the cursor.
	return Vector3(_mouse_pos.x, 0.0, _mouse_pos.z)


# Record the ready-stance anchor + threshold so the dispatch throttle's
# skipped-tick path can re-derive the same _ready_stance_aim target live every
# physics tick (see the dispatch skipped-tick block). Only the plain
# ready-stance branches call this — jab / one-timer / aim-override leave
# _off_puck_aim_live false so their throttled cadence is preserved.
func _arm_off_puck_live_aim(anchor: Vector3, near_anchor_m: float) -> void:
	_off_puck_aim_live = true
	_off_puck_aim_anchor = anchor
	_off_puck_aim_near_m = near_anchor_m


# The off-puck blade target the dispatch tick's aim resolution would produce
# from CURRENT perception, for the throttle's skipped-tick re-derive. INF when
# the resolved branch isn't one we refresh live (one-timer pre-aim / explicit
# override — those keep the throttled cached path). The DECISION stays throttled;
# only the blade TARGET re-derives every physics tick.
func _off_puck_live_aim(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	if _off_puck_jab_live:
		return _carrier_puck_pos(snapshot)
	if _off_puck_aim_live:
		return _ready_stance_aim(
				self_pos, _off_puck_aim_anchor, snapshot, _off_puck_aim_near_m)
	return Vector3.INF


# Returns a target position 2 m in front of the bot. Direction is
# anchor when far, threat when near. The actual mouse position is
# stepped toward this target by `_step_mouse_toward` (the unified
# motion model), which gives the smoothing for free.
func _ready_stance_aim(self_pos: Vector3, anchor: Vector3, snapshot: WorldSnapshot,
		near_anchor_m: float = FACE_THREAT_NEAR_ANCHOR_M) -> Vector3:
	var desired_dir: Vector3 = _compute_desired_aim_dir(
			self_pos, anchor, snapshot, near_anchor_m)
	desired_dir = _deflect_safe_aim_dir(self_pos, desired_dir, snapshot)
	return self_pos + desired_dir * READY_STANCE_AIM_FORWARD_M


# ── Own-net blade discipline ─────────────────────────────────────────────────
# In the house in front of our own net, a passively parked blade sitting in
# the puck→our-mouth corridor is a deflection surface: glancing contact keeps
# the along-face pace (PuckCollisionRules), and in tight the redirect finds
# the mouth — the own-goal tip ("bots keep their sticks too close"). Real
# doctrine agrees: in tight you take your stick OUT of the shooting lane and
# let the goalie see the puck. Only the BLADE clears the corridor — the body
# stays where the role put it (a body block deadens; positioning is the
# role's call). Applies to the passive ready stance only: active plays
# (chase-gate interceptions, poke jabs, pickups) keep the blade on the
# puck's line — breaking up the play ends the danger.

# Depth of the discipline zone from our goal center — the house, where a
# redirect still fits inside the mouth angle (tactical staging constant).
const OWN_NET_BLADE_DISCIPLINE_M: float = 8.0
# Clearance the parked blade keeps off the puck→mouth corridor: a blade
# length plus the puck's contact radius, with a step of margin.
const BLADE_LANE_CLEAR_M: float = (
		GameRules.DEFAULT_BLADE_LENGTH_M + GameRules.PUCK_COLLISION_RADIUS + 0.2)


# Returns `dir` unchanged outside the discipline conditions; otherwise the
# minimal rotation that slides the parked blade point to the edge of the
# puck→our-mouth corridor on its current side.
func _deflect_safe_aim_dir(
		self_pos: Vector3, dir: Vector3, snapshot: WorldSnapshot) -> Vector3:
	if snapshot == null or snapshot.puck_state == null:
		return dir
	# Runs every physics tick per off-puck bot (live-aim path): the house
	# test goes first — pure arithmetic that exits for everyone but the 1-3
	# net-front bodies, before any dictionary lookups.
	var own_net := Vector3(0.0, 0.0, _own_goal_dir * GameRules.GOAL_LINE_Z)
	var net_dx: float = own_net.x - self_pos.x
	var net_dz: float = own_net.z - self_pos.z
	if net_dx * net_dx + net_dz * net_dz \
			> OWN_NET_BLADE_DISCIPLINE_M * OWN_NET_BLADE_DISCIPLINE_M:
		return dir
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier != -1 and _team_id_by_peer.get(carrier, -1) == _team_id:
		return dir   # our puck — offensive stance, no lane to guard
	var puck_pos: Vector3 = snapshot.puck_state.position
	var pdx: float = puck_pos.x - self_pos.x
	var pdz: float = puck_pos.z - self_pos.z
	if pdx * pdx + pdz * pdz <= _blade_reach * _blade_reach:
		return dir   # contest range — play the puck, don't concede it
	var lane: Vector3 = own_net - puck_pos
	lane.y = 0.0
	var lane_len: float = lane.length()
	if lane_len < 0.001:
		return dir
	var u: Vector3 = lane / lane_len
	var blade_pt: Vector3 = self_pos + dir * READY_STANCE_AIM_FORWARD_M
	var t: float = (blade_pt.x - puck_pos.x) * u.x \
			+ (blade_pt.z - puck_pos.z) * u.z
	if t <= 0.0 or t >= lane_len:
		return dir   # parked blade outside the corridor's span
	var foot := Vector3(puck_pos.x + u.x * t, 0.0, puck_pos.z + u.z * t)
	var perp := Vector3(blade_pt.x - foot.x, 0.0, blade_pt.z - foot.z)
	var perp_len: float = perp.length()
	if perp_len >= BLADE_LANE_CLEAR_M:
		return dir
	var side: Vector3
	if perp_len > 0.001:
		side = perp / perp_len
	else:
		side = Vector3(-u.z, 0.0, u.x)   # on the line — either edge works
	# Park the blade ON the corridor-edge line at the full stance length:
	# intersect the stance circle (radius READY_STANCE_AIM_FORWARD_M around
	# the body) with the edge line, taking the crossing nearest the original
	# park (least rotation). No crossing → the stance can't reach the edge;
	# hold the blade perpendicular-off for the max clearance available.
	var p0: Vector3 = puck_pos + side * BLADE_LANE_CLEAR_M
	var d0x: float = self_pos.x - p0.x
	var d0z: float = self_pos.z - p0.z
	var along: float = d0x * u.x + d0z * u.z
	var hx: float = d0x - u.x * along
	var hz: float = d0z - u.z * along
	var h_sq: float = hx * hx + hz * hz
	var r_sq: float = READY_STANCE_AIM_FORWARD_M * READY_STANCE_AIM_FORWARD_M
	if h_sq >= r_sq:
		return side
	var half_span: float = sqrt(r_sq - h_sq)
	var s_pick: float = along + half_span if absf(along + half_span - t) \
			< absf(along - half_span - t) else along - half_span
	var safe_dir: Vector3 = p0 + u * s_pick - self_pos
	safe_dir.y = 0.0
	if safe_dir.length_squared() < 0.0001:
		return dir
	return safe_dir.normalized()


# Picks the desired raw aim direction: anchor direction when far,
# threat direction when near anchor — except the OPEN-HIPS catch stance: a
# TEAMMATE has the puck and we're in the offensive zone, so we're a candidate
# receiver, and the stance splits between the play and the net (the puck-net
# bisector — both stay comfortably inside the blade cone). The catch then
# lands with the shot already loaded instead of needing a full post-catch
# rotation toward a net that was at our back. Defensive watching (loose puck
# or an opponent carrier) keeps eyes-on-the-threat.
func _compute_desired_aim_dir(self_pos: Vector3, anchor: Vector3, snapshot: WorldSnapshot,
		near_anchor_m: float = FACE_THREAT_NEAR_ANCHOR_M) -> Vector3:
	var to_anchor: Vector3 = anchor - self_pos
	# Hysteresis on the far→anchor / near→threat flip: a bot orbiting right at
	# near_anchor_m used to toggle the whole aim direction (anchor vs puck — often
	# far apart) every dispatch, swinging the blade back and forth. Latch the mode
	# and require the distance to cross a full band past the threshold before
	# flipping, so boundary-camping holds one direction. Now that the aim also
	# refreshes every physics tick (skipped-tick path), an un-debounced boundary
	# would chatter at the tick rate — the band is what keeps that smooth.
	var dist: float = to_anchor.length()
	if _aim_near_anchor:
		if dist > near_anchor_m + FACE_NEAR_ANCHOR_HYSTERESIS_M:
			_aim_near_anchor = false
	elif dist < near_anchor_m - FACE_NEAR_ANCHOR_HYSTERESIS_M:
		_aim_near_anchor = true
	if not _aim_near_anchor:
		if dist < 0.0001:
			return _face_threat_or_current(snapshot, self_pos)
		return to_anchor.normalized()
	var threat_dir: Vector3 = _face_threat_or_current(snapshot, self_pos)
	if snapshot.puck_state == null:
		return threat_dir
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier == -1 or carrier == _peer_id \
			or _team_id_by_peer.get(carrier, -1) != _team_id \
			or not AIActionScoring.in_offensive_zone(self_pos, _attacking_goal_pos):
		return threat_dir
	var to_net: Vector3 = _attacking_goal_pos - self_pos
	to_net.y = 0.0
	if to_net.length_squared() < 0.01:
		return threat_dir
	var open_hips: Vector3 = threat_dir + to_net.normalized()
	if open_hips.length_squared() < 0.01:
		return threat_dir   # puck and net dead-opposite — degenerate bisector
	return open_hips.normalized()


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
	var dist: float = to_puck.length()
	# Debounced geometry floor (see FACE_THREAT_MIN_DIST_HYSTERESIS_M): once inside
	# the floor hold facing until the puck clears it by a full band, and vice
	# versa, so a puck hovering at the boundary doesn't flip the aim per tick.
	if _threat_too_close:
		if dist > FACE_THREAT_MIN_DIST_M + FACE_THREAT_MIN_DIST_HYSTERESIS_M:
			_threat_too_close = false
	elif dist < FACE_THREAT_MIN_DIST_M - FACE_THREAT_MIN_DIST_HYSTERESIS_M:
		_threat_too_close = true
	if _threat_too_close or dist < 0.0001:
		return _read_facing_3d(snapshot)
	return to_puck / dist



# Clamp an anchor to the playable rink with a small margin so steering
# doesn't pull the bot into the boards or behind the goal line.
# True iff any opponent is within `radius` of `self_pos` AND in the
# forward half-plane defined by `forward_dir`. Used by the wrister
# mid-charge bail check — defenders behind or perpendicular
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
		if _team_id_by_peer.get(peer_id, -1) == _team_id:
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


# Shades a carrier-chase intercept point one stick-reach along the
# intercept→our-net line, so the chaser's approach arrives on the
# DEFENSIVE side of the contact — the inside lane — and the carrier's
# only escape is outside, toward the boards. Same construction as
# PRESSURE's cut-off line (search center shifted BLADE_REACH_M toward
# our net): the shade is exactly the distance our stick can poke, so
# the blade still reaches the puck at the shaded body position, and the
# geometry holds at every chase range (a flat lateral offset was
# negligible from distance and arbitrary in tight). Shade is clamped to
# the available ice so an intercept at the doorstep never projects the
# chaser past his own goal line. Static + private so it's unit-testable.
static func _shade_intercept_goal_side(target: Vector3, our_net: Vector3) -> Vector3:
	var to_net: Vector3 = our_net - target
	var dist: float = Vector2(to_net.x, to_net.z).length()
	if dist < 0.001:
		return target
	var shade: float = minf(BLADE_REACH_M, dist)
	var inv: float = shade / dist
	return Vector3(target.x + to_net.x * inv, target.y, target.z + to_net.z * inv)


# `vmax` overrides the speed cap for the reachability walk (< 0 → the cruise
# _self_max_speed). The chase passes its sprint-aware race cap — see
# _chase_race_vmax.
func _lead_intercept(self_pos: Vector3, self_vel: Vector3, puck_pos: Vector3,
		puck_vel: Vector3, vmax: float = -1.0) -> Vector3:
	var cap: float = vmax if vmax > 0.0 else _self_max_speed
	var dt: float = CHASE_MAX_LOOKAHEAD_S / float(CHASE_TRAJECTORY_STEPS)
	# Use puck-physics-aware prediction (ice friction + board bounces).
	# Constant-velocity over 1.5 s consistently overshot where a sliding
	# puck actually ends up; the new model matches Jolt's resolution.
	var traj: Array[Vector3] = AITrajectory.predict_puck(
			puck_pos, puck_vel, CHASE_TRAJECTORY_STEPS, dt)
	# Kinematic reachability: for each step T on the puck trajectory,
	# solve for the constant control acceleration `a` that would land
	# the bot at `traj[i]` at time T starting from (self_pos, self_vel):
	#
	#     traj[i] = self_pos + self_vel·T + ½·a·T²
	#  ⇒  a = 2·(traj[i] − self_pos − self_vel·T) / T²
	#
	# The bot is reachable iff BOTH necessary conditions hold:
	#   1. |a| ≤ _chase_max_accel — the thrust to bend the current velocity
	#      onto the target exists (this is what charges a bot moving the
	#      WRONG way for its turn). Compared in squared form to skip the
	#      sqrt and per-step T² divisions:
	#          |a|² ≤ A_max²  ⇔  A_max²·T⁴ − 4·|residual|² ≥ 0
	#   2. The top-speed cap: the distance to traj[i] must fit inside what
	#      an accelerate-then-cruise sprint covers in T — accelerate along
	#      the target line from the CURRENT velocity component v₀ at A_max
	#      until _self_max_speed, then cruise (see _cruise_distance).
	#      Constraint 1 alone claimed ½·A·T² of travel from rest (13.5 m in
	#      1.5 s at A=12 — ~40% beyond what a speed-capped skater covers),
	#      so the bot picked intercept points EARLIER on the puck's path
	#      than its body could make, arrived after the puck had passed, and
	#      trailed the whole race — the "bad chase angle".
	#   Both are necessary, neither sufficient alone; their conjunction can
	#   still be a touch optimistic vs. true optimal control (the cruise
	#   bound doesn't charge for shedding perpendicular velocity), and the
	#   per-dispatch re-evaluation absorbs that residual error.
	#
	# First step where both hold is the intercept. When the accel bracket
	# spans two steps (prev < 0 ≤ curr), linear-interp T inside the step
	# instead of always returning traj[i] (over-runs by up to dt); a
	# speed-cap flip takes traj[i] directly (no comparable surplus units).
	var a_max_sq: float = _chase_max_accel * _chase_max_accel
	# Fast pucks demand arrival SLACK, not a dead heat: reachability is
	# tested against t − KILL_SETUP_MARGIN_S so the aim point sits far
	# enough along the path that the body genuinely arrives early and sets
	# (blade to the gate) instead of meeting the puck at pace. Zero-slack
	# aims produced the sliding-intercept treadmill on rims: miss by a
	# hair, re-solve to a new dead-heat point further along, miss again.
	# Slow pucks keep the exact test — the intercept converges on its own.
	var setup_margin: float = AILoosePuckChase.KILL_SETUP_MARGIN_S \
			if AILoosePuckChase.is_fast_puck(puck_vel) else 0.0
	var prev_surplus: float = -INF
	var prev_pos: Vector3 = self_pos
	for i: int in traj.size():
		var t_step: float = (i + 1) * dt - setup_margin
		if t_step <= 0.0:
			prev_surplus = -INF
			prev_pos = traj[i]
			continue
		var t_sq: float = t_step * t_step
		var t_4: float = t_sq * t_sq
		var residual_x: float = traj[i].x - self_pos.x - self_vel.x * t_step
		var residual_z: float = traj[i].z - self_pos.z - self_vel.z * t_step
		var residual_sq: float = residual_x * residual_x + residual_z * residual_z
		var surplus: float = a_max_sq * t_4 - 4.0 * residual_sq
		var dist_x: float = traj[i].x - self_pos.x
		var dist_z: float = traj[i].z - self_pos.z
		var dist: float = sqrt(dist_x * dist_x + dist_z * dist_z)
		var speed_ok: bool = true
		if dist > 0.001:
			var v0_along: float = (self_vel.x * dist_x + self_vel.z * dist_z) / dist
			speed_ok = _cruise_distance(v0_along, t_step, cap) >= dist
		if surplus >= 0.0 and speed_ok:
			if prev_surplus > -INF and prev_surplus < 0.0:
				var frac: float = -prev_surplus / (surplus - prev_surplus)
				return prev_pos.lerp(traj[i], frac)
			return traj[i]
		prev_surplus = surplus if speed_ok else -INF
		prev_pos = traj[i]
	# Puck unreachable inside the lookahead window — aim at the last
	# projected position so we at least head in the right direction.
	return traj[traj.size() - 1] if traj.size() > 0 else puck_pos


# Distance a sprint covers along one axis in `t` seconds: accelerate from
# `v0` (the current velocity component along the target line — negative when
# moving away, so the turn-around is charged) at _chase_max_accel until the
# speed cap, then cruise at it. The 1D leg of _lead_intercept's reachability
# check (constraint 2 above). `vmax` < 0 → the cruise _self_max_speed.
func _cruise_distance(v0: float, t: float, vmax: float = -1.0) -> float:
	var cap: float = vmax if vmax > 0.0 else _self_max_speed
	var v_start: float = minf(v0, cap)
	var t_acc: float = (cap - v_start) / maxf(_chase_max_accel, 0.001)
	if t <= t_acc:
		return v_start * t + 0.5 * _chase_max_accel * t * t
	return v_start * t_acc + 0.5 * _chase_max_accel * t_acc * t_acc \
			+ cap * (t - t_acc)


# True iff a TEAMMATE (not me, not opp) currently has the puck. Used to
# suppress CHASE_PUCK so non-carrier bots don't sprint at their own
# teammate carrier with their blade out.
func _teammate_has_puck(snapshot: WorldSnapshot) -> bool:
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier == -1 or carrier == _peer_id:
		return false
	return _team_id_by_peer.get(carrier, -1) == _team_id


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
	# Bots that are still ghosted (offside / icing penalty) must stay
	# OFF_PUCK — without this check, the next tick transitions them to
	# CHASE_PUCK and the dispatch-time guard catches it, but for one
	# tick they think they're chasing.
	if s == null or s.is_ghost:
		return State.OFF_PUCK
	return State.CHASE_PUCK if _is_closest_teammate_to_puck_at(snapshot, s.position) else State.OFF_PUCK


# True iff the puck is loose (no carrier) AND we are the closest
# teammate to it. Used by OFF_PUCK→CHASE_PUCK and CHASE_PUCK exit.
# Replaces the v1 "is F1?" gate — slot labels don't directly drive
# chase decisions in v2.
# Advances the loose-puck reactivity clock. Runs BEFORE the dispatch throttle so
# a skipped tick can't drop time out of the reaction delay. See the field block.
func _update_loose_reaction_clock(snapshot: WorldSnapshot, delta: float) -> void:
	if snapshot == null or delta <= 0.0:
		return
	if snapshot.real_puck_carrier_peer_id == -1:
		_loose_elapsed_s += delta
		_control_elapsed_s = 0.0
		return
	# Someone is touching it — but a graze isn't possession. Only a sustained
	# carry clears the loose clock, so a scramble's flicker can't keep resetting
	# the whole team's reaction the way the global debounce does.
	_control_elapsed_s += delta
	if _control_elapsed_s >= CONTROL_CONFIRM_S:
		_loose_elapsed_s = 0.0


func _should_chase_loose_puck(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	if snapshot == null or snapshot.puck_state == null:
		return false
	# REAL carrier, not the reaction-delayed one: the delayed signal is the team's
	# possession BELIEF (deliberately slow, and restart-prone under scramble
	# noise). Puck reactivity runs on its own bounded clock instead.
	if snapshot.real_puck_carrier_peer_id != -1:
		return false  # someone has the puck
	if _loose_elapsed_s < _chase_reaction_delay_s:
		return false  # hasn't been loose long enough for us to have reacted
	# Smart-ping GET_PUCK: an ordered bot chases regardless of the natural
	# election and the race-lost decline below — an order is an order (the
	# election override in GameManager._enrich_snapshot_for_ai keeps a second
	# natural chaser from doubling up).
	if _current_strategy != null and _current_strategy.ping_chase_peer() == _peer_id:
		return true
	# A free puck at your feet is yours, election or not. The election picks ONE
	# chaser per team, which is right for a race across the zone and wrong for a
	# puck whose own path runs through this bot's reach: he'd hold his station
	# and let it slide past his stick because a teammate scored a better ETA to
	# it. Bounded to the reach band (see AILoosePuckChase.puck_comes_to_reach),
	# so this can't turn into a second bot abandoning his job to converge.
	# Placed above the election AND the race-lost decline: inside your own reach
	# there is no race to lose — you contest it, and that contest is the 50/50.
	if _loose_puck_in_reach_band(snapshot, self_pos):
		return true
	if not _is_closest_teammate_to_puck_at(snapshot, self_pos):
		return false
	# A race an opponent has already won isn't worth running: pushing after a
	# clearly-lost puck skates the chaser out of the play while the counter
	# develops (the missed-pass failure). Declining CHASE drops the bot to its
	# role positioning — where the NEUTRAL CHASE slot pre-contains the pickup.
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	var self_vel: Vector3 = self_state.velocity if self_state != null else Vector3.ZERO
	return not AIRoleHelpers.loose_puck_race_lost(
			snapshot, self_pos, self_vel, _self_max_speed,
			_team_id, _team_id_by_peer, _caps_by_peer, _peer_id, _own_goal_dir)


# Does the loose puck's own path cross inside our reach band? The incidental
# pickup read — see AILoosePuckChase.puck_comes_to_reach for the model. False
# whenever the puck isn't genuinely loose, so a teammate's carry can never trip
# it. Cheap enough for the OFF_PUCK dispatch: the path walk is memoized on the
# puck state, so the whole team shares one walk per tick.
func _loose_puck_in_reach_band(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	if snapshot == null or snapshot.puck_state == null \
			or snapshot.real_puck_carrier_peer_id != -1:
		return false
	# A DEAD loose puck (goalie smother / phase lock) publishes a -1 election
	# for every team — see AILoosePuckChase.elect's puck_playable. The band
	# bypasses the election, so it has to honor that veto itself or the whole
	# team crowds a puck nobody can legally touch. An EMPTY cache means the
	# snapshot was never enriched (unit tests), not a dead puck.
	if not snapshot.closest_to_puck_by_team.is_empty() \
			and snapshot.closest_to_puck_by_team.get(_team_id, -1) == -1:
		return false
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null or self_state.is_ghost:
		return false
	# Never let the band walk us into a contested pickup with our own man: if a
	# teammate's blade is already first to it, the puck is his.
	if _teammate_first_to_puck(snapshot, snapshot.puck_state.position):
		return false
	return AILoosePuckChase.puck_comes_to_reach(
			snapshot.puck_state.position, snapshot.puck_state.velocity,
			self_pos, self_state.velocity, _self_max_speed, _blade_reach)


# Is a teammate's blade clearly first to this puck? See
# AILoosePuckChase.teammate_first_to_puck — deadlock-free, so we can never both
# yield and leave the puck sitting.
func _teammate_first_to_puck(snapshot: WorldSnapshot, puck_pos: Vector3) -> bool:
	# has()+index, not get(_team_id, []): GDScript builds the default eagerly, so
	# the literal would heap-allocate an Array on EVERY call — and this runs per
	# tick while chasing (the live aim refresh re-derives on skipped ticks too).
	if not snapshot.teammate_ids_by_team.has(_team_id):
		return false
	var mates: Array = snapshot.teammate_ids_by_team[_team_id]
	if mates.is_empty():
		return false
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		return false
	return AILoosePuckChase.teammate_first_to_puck(
			snapshot.skater_states, mates, _peer_id,
			self_state.blade_contact_world, puck_pos)


# Returns true if this bot is the closest teammate to the current
# puck position. Used as the loose-puck-chase trigger.
# Reads the per-team closest-to-puck cache published by
# GameManager._enrich_snapshot_for_ai. Falls back to a live scan only
# when the cache is empty (e.g. unit tests that hand-build snapshots).
func _is_closest_teammate_to_puck_at(snapshot: WorldSnapshot, self_pos: Vector3) -> bool:
	if not snapshot.closest_to_puck_by_team.is_empty():
		return snapshot.closest_to_puck_by_team.get(_team_id, -1) == _peer_id
	var puck_pos: Vector3 = snapshot.puck_state.position
	var dx: float = self_pos.x - puck_pos.x
	var dz: float = self_pos.z - puck_pos.z
	var my_d2: float = dx * dx + dz * dz
	for pid: int in snapshot.skater_states:
		if pid == _peer_id:
			continue
		if _team_id_by_peer.get(pid, -1) != _team_id:
			continue
		var pos: Vector3 = snapshot.skater_states[pid].position
		var ox: float = pos.x - puck_pos.x
		var oz: float = pos.z - puck_pos.z
		if ox * ox + oz * oz < my_d2:
			return false
	return true


# Frame-over-frame velocity diff per peer, low-passed into
# _accel_by_peer. Stale peers (left the snapshot — disconnect, swap)
# get pruned so the dict size stays bounded. First-sight peers seed
# prev_velocity from the current value and contribute zero accel so
# a respawn doesn't register as a thrust spike.
func _update_acceleration_cache(snapshot: WorldSnapshot, delta: float) -> void:
	if delta <= 0.0:
		return
	var inv_delta: float = 1.0 / delta
	var seen: Dictionary = {}
	for peer_id: int in snapshot.skater_states:
		seen[peer_id] = true
		var s: SkaterNetworkState = snapshot.skater_states[peer_id]
		var curr_v: Vector3 = s.velocity
		var prev_v: Vector3 = _prev_velocity_by_peer.get(peer_id, curr_v)
		_prev_velocity_by_peer[peer_id] = curr_v
		var raw_a: Vector3 = (curr_v - prev_v) * inv_delta
		raw_a.y = 0.0
		var smoothed: Vector3 = _accel_by_peer.get(peer_id, Vector3.ZERO)
		smoothed = smoothed.lerp(raw_a, ACCEL_SMOOTH_ALPHA)
		var mag: float = sqrt(smoothed.x * smoothed.x + smoothed.z * smoothed.z)
		if mag > ACCEL_CLAMP_M_S2:
			var scale: float = ACCEL_CLAMP_M_S2 / mag
			smoothed.x *= scale
			smoothed.z *= scale
		_accel_by_peer[peer_id] = smoothed
		# Heading turn rate fallback — mirrors AIAccelerationTracker exactly so a
		# unit-test snapshot (no shared cache) reads the same receiver-commitment
		# signal the host serves.
		var raw_omega: float = 0.0
		var prev_speed: float = sqrt(prev_v.x * prev_v.x + prev_v.z * prev_v.z)
		var curr_speed: float = sqrt(curr_v.x * curr_v.x + curr_v.z * curr_v.z)
		if prev_speed > AIAccelerationTracker.OMEGA_MIN_SPEED_M_S \
				and curr_speed > AIAccelerationTracker.OMEGA_MIN_SPEED_M_S:
			var dot: float = prev_v.x * curr_v.x + prev_v.z * curr_v.z
			var cross: float = prev_v.x * curr_v.z - prev_v.z * curr_v.x
			raw_omega = atan2(cross, dot) * inv_delta
		var omega: float = lerpf(_heading_omega_by_peer.get(peer_id, 0.0),
				raw_omega, AIAccelerationTracker.OMEGA_SMOOTH_ALPHA)
		omega = clampf(omega, -AIAccelerationTracker.OMEGA_CLAMP_RAD_S,
				AIAccelerationTracker.OMEGA_CLAMP_RAD_S)
		_heading_omega_by_peer[peer_id] = omega
	# Prune peers that left the snapshot (rare — swap / disconnect)
	# so the dicts don't grow over a long match. Iterate a copy of
	# the key list because `erase` during dict iteration is unsafe.
	var existing_ids: Array = _prev_velocity_by_peer.keys()
	for peer_id: int in existing_ids:
		if not seen.has(peer_id):
			_prev_velocity_by_peer.erase(peer_id)
			_accel_by_peer.erase(peer_id)
			_heading_omega_by_peer.erase(peer_id)


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
# True when any OPPONENT skater is within `r` of `point` (XZ) — the "their
# blade can reach this puck too" contest read (r = blade-on-puck range).
func _opponent_within_of(snapshot: WorldSnapshot, point: Vector3, r: float) -> bool:
	for pid: int in snapshot.skater_states:
		if pid == _peer_id or _team_id_by_peer.get(pid, -1) == _team_id:
			continue
		var p: Vector3 = snapshot.skater_states[pid].position
		var dx: float = p.x - point.x
		var dz: float = p.z - point.z
		if dx * dx + dz * dz < r * r:
			return true
	return false


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
			var ratio: float = clampf(speed / _self_max_speed, 0.0, 1.0)
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
		# sweep direction, fresh tick count. SkaterStateMachine seeds the
		# charge tracker from the blade's current position at the entry edge.
		# Every press entry also draws its execution samples HERE — one aim
		# error per release (shot vs pass budget), plus the shot's
		# late-release hold — so the whole windup commits to a single
		# slightly-imperfect gesture instead of wobbling per tick.
		if s == State.SHOOT_PRESSED:
			_shoot_charge_tick = 0
			_committed_aim_error_rad = _sample_aim_error_rad(_shot_aim_error_rad)
			_shoot_release_hold_ticks = _sample_release_hold_ticks()
		if s == State.PASS_PRESSED:
			_pass_charge_tick = 0
			_committed_aim_error_rad = _sample_aim_error_rad(_pass_aim_error_rad)
		if s == State.ONE_TIMER_PRESSED:
			_one_timer_press_tick = 0
			_one_timer_slap_down = false
			# A one-timer is the worst-controlled release there is — it reads
			# the SHOT budget (matching the reception gate's spread budget).
			_committed_aim_error_rad = _sample_aim_error_rad(_shot_aim_error_rad)
		# Intent + wait counter reset on CARRY entry so a new puck
		# pickup gets a fresh re-evaluation rather than inheriting
		# stale state from a previous CARRY. _carrier.clear_intent()
		# also forces an immediate re-eval (cooldown to 0) on the
		# next decide() call.
		if s == State.CARRY:
			_intended_action = State.CARRY
			_intent_wait_ticks = 0
			_one_timer_preserve_ticks = 0
			_carry_tracking_fire = false
			_carry_protect_gain_smooth = 0.0
			_carry_protect_offset_smooth = Vector3.ZERO
			_carry_has_man = false
			_poke_evade_active_ticks = 0
			_poke_evade_cooldown_ticks = 0
			_poke_evade_dir = Vector2.ZERO
			_poke_evade_braking = false
			_poke_evade_deking = false
			_deke_fake_dir = Vector2.ZERO
			_deke_cut_dir = Vector2.ZERO
			_poke_jab_active_ticks = 0
			_poke_jab_cooldown_ticks = 0
			_carrier.clear_intent()
		_state = s
		_ticks_in_state = 0
		# Force the next dispatch to run the full state handler so the
		# new state starts from a fresh decision rather than reusing the
		# previous state's cached move_vector / aim target.
		_dispatch_skip_counter = 0
		# Force a fresh off-puck role decision on the first tick of the new
		# state (cooldown <= 0 recomputes), so a re-entry into OFF_PUCK never
		# steers on a RoleDecision cached from a previous stint.
		_role_decision_cooldown = 0


func _reset_to_off_puck() -> void:
	_state = State.OFF_PUCK
	_ticks_in_state = 0
	_pass_target_peer_id = -1
	_carrier.reset()
