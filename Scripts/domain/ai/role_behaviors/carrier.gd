class_name AIRoleCarrier
extends RefCounted

const _PhysicsConstants: GDScript = preload("res://Scripts/game/constants.gd")

# CARRIER role behavior: the puck-carrying utility AI. Scores SHOOT
# (wrister), PASS (per teammate), and CARRY (the candidate set _best_carry
# builds) on equal footing every PICK_ACTION_PERIOD_TICKS ticks. Hysteresis
# on the current intent prevents flicker between close-scoring fire options
# during pre-aim; CARRY does NOT get a hysteresis bonus — stand-still's shot
# branch IS the shoot-now score, so it ties with fire by construction and
# fire should win those ties.
#
# This module is stateful — it owns hysteresis state, scratch
# buffers, and the cooldown counter. SkaterAgentStateMachine creates
# one instance per agent in setup() and calls decide(ctx) every
# CARRY-state tick. Mirror fields the state machine reads after
# decide():
#   - intended_action  (INTENT_*)
#   - last_carry_anchor
#   - pass_target_peer_id
#   - shot_loft_level
#   - debug_*
#
# The state machine translates intended_action back into its own
# State enum for steering / pre-aim / press transitions.

# ── Intent enum ──────────────────────────────────────────────────────────────
# Local mirror of the relevant State values from
# SkaterAgentStateMachine. Ints rather than the State enum keep this
# file decoupled from the state machine for unit testing.
const INTENT_CARRY: int = 0
const INTENT_SHOOT: int = 1
const INTENT_PASS: int = 3
# Last-resort DUMP — fire the puck to a location (no receiver). The state machine
# maps it onto a PASS_PRESSED release aimed at `dump_target`.
const INTENT_DUMP: int = 5

# ── Giveaway floors: least value worth releasing the puck for ────────────────
# Tactical floors, not evaluation curves. Both are DENOMINATED IN THE SEAM'S
# CURRENCY (AIShotValue → XGBaseline): an honest NHL-calibrated goal
# probability, where a clean mid-slot look is ~0.12 and no real spot reaches
# 0.5. They are scale-bound to that model and move if it does — neither is
# transferable to the hole-geometry score, which saturates at 1.0 and would
# read these as a twentieth as strict.
#
# There are TWO because a shot and a pass forfeit different things.
#
# A SHOT hands the puck to the other team unless it goes in, so what it must
# out-value is the possession itself. Read the number through the baseline to
# see what it bans: a clear-lane shot straight on reaches 0.05 at about 14 m,
# so this is "nothing from beyond the top of the circles unless traffic, a
# screen, or a displaced keeper lifts it". Both halves matter — the distance
# bound stops a CONTAINED carrier trading the puck for a point shot instead of
# working it, and the lift keeps a genuine point blast through a screen legal.
const SHOT_MIN_VALUE: float = 0.05
# A PASS that connects KEEPS possession — it changes whose stick, not whose
# team — and the odds of it not connecting are already priced by the lane term
# inside the pass score. So the possession is not what a pass is spending, and
# holding a pass to the shot's bar would veto every breakout and regroup feed
# (a receiver at centre ice is worth ~0.017 as a shooter and is still the right
# play). This bar only rejects a release into nothing: a numerical residual on
# a dead lane, never a real outlet.
const PASS_MIN_VALUE: float = 0.02
# There is deliberately no third bar for the DUMP. A shot clears SHOT_MIN_VALUE
# and a pass PASS_MIN_VALUE because each is a RELEASE chosen on its merits, and a
# release that merely ties the carry must not win. The dump is not chosen on
# merits at all — it is what is left when the carry is worth nothing and no
# release qualifies (see the residual block in _pick_commit_phase), so there is
# nothing for a bar to gate.

# ── Settle doubt: how sure a FRESH carrier has to be to give the puck up ──────
# A bot that has only just gained the puck has not read the ice yet, so for a
# beat it discounts its own valuation of every ACTIVE option against that
# option's bar above: the option must be worth MORE than the standing bar to be
# worth the puck (ctx.settle_penalty_frac = 0.5 doubles every bar), and the
# discount decays as it settles. Difficulty knob — 0.0 at Hard and for the
# perfect bot.
#
# Charge it against the BAR, never against the carry it competes with. The
# stand-still carry candidate is BY CONSTRUCTION worth the same as firing from
# where the bot stands (see _best_carry), so a handicap inside the fire-vs-carry
# compete can only be a uniform DELAY — it holds the doorstep tap-in exactly as
# hard as the hopeless point shot.
#
# Constant-hazard decay, the same exp(-t/τ) form as AIActionScoring's delay
# discount. It never reaches exactly zero, which is harmless against an absolute
# bar (an option within an epsilon of its bar is a coin flip either way) but
# would not be inside the compete, where stand-still ties fire exactly and any
# residual penalty would suppress firing forever.
func _settle_penalty(ctx: RoleContext) -> float:
	if ctx.settle_penalty_frac <= 0.0:
		return 0.0
	return ctx.settle_penalty_frac * exp(
			-_settle_elapsed_s / maxf(ctx.settle_penalty_tau_s, 0.001))


# Move `value` away from being chosen by `penalty` of its own magnitude: a
# positive score shrinks toward zero, a negative one (the dump is a pure
# concession) deepens. Higher is better everywhere this is read, so the one form
# handicaps both signs.
static func _settle_handicap(value: float, penalty: float) -> float:
	return value - penalty * absf(value)

# Minimum forward distance (m) the PUCK must sit in front of the goal-line plane
# for a direct shot to be scored at all — below it (on/behind the line, or right
# at the post plane) the mouth faces away and the only play is a wrap/walk-out
# carry, not a rip. Guards the velocity-projected release from inventing a
# point-blank open net for a carrier whose body has skated past the line. Feel
# gate; a walk-out shooter is genuinely in front (well past this) by release.
const SHOT_MIN_FORWARD_OF_LINE_M: float = 0.3


# ── Release-offset sampling (shoot-now eval) ─────────────────────────────────
# The shot originates at the PUCK, and the carrier can put the puck anywhere in
# its blade's handling envelope before releasing — so the shoot-now eval samples
# a release on each lateral side of the projected puck spot (full forehand
# reach / none / full backhand reach) and commits the best. This is what buys
# the in-tight lateral finish (shifting the puck most of a metre moves the whole
# tangent-cone geometry) and the short-side tuck from beside the net. Two
# honesty terms, both physical: relocating the puck costs blade-travel time
# (offset / self_blade_speed), which extends the goalie's tracking window; and a
# backhand-side release fires at the build's backhand_power_coefficient of full
# pace (Hands un-penalizes it), so the backhand tuck wins exactly when geometry
# pays for the pace loss. Iteration order puts the un-relocated release first
# and the compare is strictly-greater, so ties keep the simple release. Sampled
# only in the top-level shoot eval (~30 Hz): carry candidates and pass receivers
# stay single-release — their geometry is a projection anyway, and the winning
# candidate gets the full sweep the moment it becomes the live shoot-now eval.
const RELEASE_SAMPLE_FRACS: Array[float] = [0.0, 1.0, -1.0]   # × usable reach; + = forehand

# Winning sample from the last shoot-now sweep: the release/goalie/pace the
# SHOOT commit's loft/aim/power must be computed against (so the executed shot
# is the one that won the compete), the offset the state machine folds into the
# wind-up, and whether it's a backhand-side release (drives the power remap).
var _shot_sample_release: Vector3 = Vector3.ZERO
var _shot_sample_goalie: Vector3 = Vector3.ZERO
var _shot_sample_speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
var _shot_sample_offset: Vector3 = Vector3.ZERO
var _shot_sample_backhand: bool = false
# True when the winning shoot read is the TIP rip (AIActionScoring.tip_ev):
# fired flat at full pace THROUGH the net-front teammate's blade at the net
# centre — the commit path aims it there instead of at a direct-model hole.
var _shot_sample_is_tip: bool = false


# Lateral envelope usable for a release offset: the handling reach less the
# forward carry the frozen blade still holds the puck out at (half the wind-up
# span ≈ the controllable carry distance), so a puck relocated laterally by this
# much stays inside ROM. The wrister's blade FREEZES at the release offset rather
# than sweeping out to a side-offset endpoint, so no ROM is reserved for
# BOT_WRISTER_SIDE_OFFSET_M: that side offset belongs to the fake wind-up cursor,
# not the blade, and must not shrink the lateral the scorer can price. Reserving
# it costs ~0.15 m of priced release the frozen mechanic can genuinely reach, so
# breakaway shot is scored (and executed) from the wider, honest angle.
# Pure geometry of real gesture measurements, not a knob.
static func _usable_release_offset(reach: float) -> float:
	var half_span: float = SkaterAgentStateMachine.BOT_WRISTER_WIND_UP_SPAN_M * 0.5
	return sqrt(maxf(reach * reach - half_span * half_span, 0.0))


# ── Smart-ping obedience ─────────────────────────────────────────────────────
# EV multipliers a live human ping applies inside the normal compete — a
# tactical ORDER (legitimately hand-set, like the blue-line valve), not an
# evaluation curve. A bias rather than a hard force on purpose: the grounded
# models still veto a hopeless order (a SHOOT ping never fires a zero-value
# look from behind the net, PASS_TO_ME never threads a dead lane — the giveaway
# floors still apply), but any remotely reasonable read now wins the compete, so
# the bot visibly obeys.
const PING_SHOOT_EV_MULT: float = 3.0
const PING_PASS_EV_MULT: float = 3.0

# ── Scoring constants ────────────────────────────────────────────────────────
# Re-evaluation cadence. CARRY runs every physics tick; without throttling the
# scoring (10 carry candidates × per-teammate pass × opponent
# projections) would fire every tick per bot. ~30 Hz is plenty — pre-aim
# convergence gates the actual transition, and humans react in 250 ms+.
const PICK_ACTION_PERIOD_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 30   # ~30 Hz re-eval
# Open-ice LOD (see decide()): with no opponent inside this radius and the
# committed answer CARRY, the compete re-arms at PERIOD × MULT (~10 Hz). The
# radius is a closing-speed margin, not a tuning feel: two skaters closing
# head-on cover ~18 m/s, so a threat first appearing here is ~0.36 s from a
# stick on the puck — several extended periods away.
const OPEN_ICE_LOD_RADIUS_M: float = 8.0
const OPEN_ICE_LOD_PERIOD_MULT: int = 3
# The hold-elapsed clock (see _pick_action) advances by the REAL physics ticks
# that elapsed since the previous re-eval (`_ticks_since_pick`), not a fixed
# per-call constant — decide() is called once per AI dispatch, so at lower
# difficulty tiers each call spans several physics ticks and a fixed increment
# would run the hold-decay clock several times too slow.

# Pass flight clamp. A 0.6 s lead lets the bot pass to a teammate up
# to ~16 m away (PASS_SPEED_M_S × 0.6); longer leads suffer from
# stale opponent projections.
const PASS_LEAD_MAX_S: float = 0.6

# Receiver drive-in credit (see _receiver_drive_in_value): the MAX distance an open
# pass receiver is credited with carrying toward the net (the actual reach is the
# clear extent of that path — a defender strips it early), and the closest to the net
# that drive is allowed to end (don't credit a drive into the crease / the goalie).
# The max is a horizon cap — long enough to carry a NZ/DZ outlet with a clear lane
# into the zone — kept finite because opponent projections go stale over a long carry.
# Feel tunables ("how far a wide-open man is trusted to skate it"), not an evaluation
# curve; the value at the reached spot is still the goalie-aware / potential read.
const RECEIVER_DRIVE_MAX_M: float = 12.0
const RECEIVER_DRIVE_MIN_NET_DIST_M: float = 3.0

# Forward-pressure discount on the CARRY (see _carrier_forward_clearance). The model
# prices the IMMEDIATE strip (a defender right on the puck) but not the IMPENDING
# contest — a defender sitting in the carrier's path to the objective it will have to
# beat to advance. So a lightly-pressured carrier reads its own (sidestep) carry as
# clean and grinds forward instead of moving the puck to an unimpeded teammate. This
# discounts the carry by how contested the path AHEAD is, so an impeded carrier
# prefers a clean outlet even at the cost of some real estate — the pass-first read.
# HORIZON is how far ahead the contest is felt; MIN_SCALE is the most a fully-blocked
# path discounts the carry (never to zero — a pressured carrier with no outlet still
# carries). Feel tunables (how pass-first / risk-averse), not an evaluation curve —
# the clearance itself is the grounded reachable-set read. Applied ONLY to the
# fire-vs-carry compete, never to the honest raw carry the dump is judged against.
const FORWARD_PRESSURE_HORIZON_M: float = 9.0
const FORWARD_PRESSURE_MIN_SCALE: float = 0.55

# ── Attacking blue-line keep-out bands ──────────────────────────────────────
# Both are physical measurements of how far play around the carried puck
# extends past the body, not shape parameters — they exist because the
# offside puck-line is the TRUE blue line while these decisions are made in
# body positions.
#
# RETREAT: how close to the line the OZ one-way valve lets a carry candidate
# sit (see _score_move_candidate). The charged pass windup sweeps the blade —
# and the carried puck — up to a stick's reach back from the body, and the
# ~135 ms charge drifts a still-retreating body further (~7 m/s × 0.135 s).
# A carrier parked closer than that windup envelope drags the puck back
# across the line mid-pass — a zone exit, so the pass re-entering lands the
# whole team offside. Retreating to the line for space stays legal; parking
# ON it does not.
const OZ_RETREAT_LINE_BUFFER_M: float = GameRules.DEFAULT_STICK_LENGTH_M + 1.0

# RECEIVE: how far inside the line a pass target's intercept lead must sit
# when the carrier is in the OZ (see _compute_best_pass). A tape at the line
# is a fragile target — the catch itself plays the puck up to a stick's
# reach around the body, and reception gives with the puck (~a stride) — so
# routine reception slop on a line-hugging target takes the puck out of the
# zone. Those blue-line feeds are also genuinely hard reads for a HUMAN
# receiver (catch while braking to stay onside), so they're excluded as
# targets, not just discounted.
const OZ_RECEIVE_LINE_BUFFER_M: float = GameRules.DEFAULT_STICK_LENGTH_M + 0.7

# The local step a carry candidate is never placed inside: the floor on the
# beat-scaled forward radii, and the horizon the space fan is sampled over.
const CARRY_SEARCH_STEP_M: float = 3.0
# Carry candidates are clamped inside the goal-line buffer and the
# rink-X inset — both defined on AIRoleHelpers (single source).

# Post-walkout candidates — the two legal carries out from BEHIND a goal
# line, one just outside each post, a step onto the rink side of the line.
# Generated only while the carrier's body is behind either goal line: every
# other candidate's straight route crosses the cage there (pruned by the
# net-path check), so without these a behind-the-net carrier had no
# representable way out and ground on the frame. Scored by the same EV
# pipeline as everything else: a walkout spot is rink-side, so it carries a
# real shot value of its own (behind the line every shot is honestly 0), and
# the two sides then compete on safety — which is also the natural wraparound
# setup (the goalie's RVH/VH post seals are the counter). The lateral clearance is
# physical: post half-span + a carried body's half-width + blade slop.
const WALKOUT_POST_CLEARANCE_M: float = 0.9
const WALKOUT_FRONT_M: float = 0.7

# The WHEEL (5v5 only — breakout plan §B): from at/behind our own goal line,
# the carry around the BACK of the cage and out the far half-wall — the
# researched escape when the retriever has a step on the chaser (the net is
# the screen; a committed F1 can't corner with him). The straight route to
# any far-side destination crosses the cage and prunes, and the walkouts
# only step to the near posts, so without these the behind-net retriever had
# no representable way to KEEP SKATING. Priced as an honest TWO-LEG carry
# through the behind-net apex (each leg runs the same lane/safety reads as
# every other candidate, defenders projected through leg one), so it wins
# exactly when the wheel is genuinely on: the escape-speed gate makes a
# committed same-side chaser read as beaten, while a waiting far-side body
# kills leg two. Exit depth = the top of the low battle ice
# (AIZoneCoverage.LOW_ZONE_DEPTH_M — the first stride of open wall past the
# boards battles); apex = the middle of the behind-net alley (cage back +
# half the gap to the boards).
const WHEEL_EXIT_UP_ICE_M: float = 8.0
const WHEEL_APEX_CLEARANCE_M: float = 0.75

# Zone-exit "wheel" routes — two extra long-range carry candidates up
# each boards lane to just past our own blue line, generated only while
# the carrier is in its own half. The slot anchor is the only other
# long-range candidate and its path runs through center ice — exactly
# where a forecheck sets up — so without these a deep carrier whose
# middle is clogged collapses to myopic 3 m steps and the (risk-priced)
# backpass. Scored by the exact same EV pipeline as every other carry
# candidate, so a wall exit wins precisely when it's genuinely the best
# route out (classic weak-side wheel when the forecheck overplays the
# strong side). Inset matches AIRoleBreakout.WALL_INSET_M so the carry
# lane and the strong-side outlet agree on where "the wall" is; the NZ
# lead puts the destination across the blue line — a completed exit.
const CARRY_EXIT_WALL_INSET_M: float = 2.0
const CARRY_EXIT_NZ_LEAD_M: float = 3.0

# Developing-outlet hold: how far ahead (seconds) a skating
# BREAKOUT_STRONG / OUTLET teammate's route is projected when valuing
# the breakout pass they are CREATING (see _developing_outlet_feed).
# Roughly one strong-side wall sample of travel at skating speed —
# "the spot they're getting open at," not a long-horizon prophecy.
# 1.2 s ≈ the drive a carrier genuinely holds for at a zone entry (the
# finisher's next two strides), still inside the pass-lead horizon by
# release time; the delay discount prices the wait. Much shorter (~0.7 s) and the
# window cannot see past the calibrated surface's dead mid-band, so a fresh entry
# reads "nothing developing" while the house drive is one stride from being the
# best play on the ice.
const OUTLET_DEVELOP_WINDOW_S: float = 1.2
# Below this speed the outlet isn't going anywhere — the spot it offers
# is the spot it's at, and the live pass scoring already prices that.
const OUTLET_DEVELOP_MIN_SPEED_M_S: float = 1.0

# REAR/LATERAL ring angles, relative to the carry direction — the half of the
# bearing circle the space fan does not span (it looks only ±70°, and only where
# the carrier is trying to GO). These are escape/reset moves whose value is
# "somewhere other than here".
#
# ONE ring, not two: the radii come from each bearing's own beat reach at two
# fractions, exactly as the forward candidates take theirs, so the near fraction
# IS the local reposition and the far one IS the committed peel-out — both sized
# to what the carrier can actually cover rather than to two hand-picked
# distances. That is also what keeps straight back (PI) worth representing: at a
# fixed 3 m a reverse is a shuffle inside the defender's re-close radius, and
# only the committed version is a real play.
const _REAR_ANGLES: Array[float] = [
		PI * 0.5, PI * 0.75, PI, -PI * 0.75, -PI * 0.5,
]

# A rear candidate below this displacement is not a distinct plan — the
# carrier's blade already reaches there without moving, and the directed
# evasion seam (also a candidate) covers body-scale repositioning properly,
# with real clearance math behind it. Grounded in the stick rather than picked:
# inside one stick length, "skate there" and "stand still and reach" are the
# same play, and stand-still is always in the compete.
const CARRY_REAR_MIN_STEP_M: float = AIActionScoring.EVADE_STICK_REACH_M

# FIELD-DERIVED FORWARD CANDIDATES (see the generator in _best_carry).
# BEARINGS: how many of the space fan's bearings become carry candidates. The
# fan has 7; taking the best 3 by control × forward projection covers the open
# side and the seam without re-scoring spokes the field already reported walled.
# RADII: fractions of the planning beat. Two of them, so the near gradient a
# standstill carrier steers on survives when the beat stretches out at speed.
# PLAN_BEAT_S: the horizon a carry candidate is a PLAN over rather than a
# steering nudge — one second of travel, which reduces to a 3 m local
# step at a standstill and reaches ~9 m (the blue line, from mid-neutral-zone)
# at a full stride. Physical: it is how far ahead the carrier commits, and the
# whole point is that it moves with his real pace instead of being pinned at a
# radius chosen for a stationary bot.
const CARRY_FIELD_BEARINGS: int = 3
const CARRY_FIELD_RADII: Array[float] = [0.5, 1.0]
const CARRY_PLAN_BEAT_S: float = 1.0
# Deke engagement gates (the cheap pre-filters before the manufactured-opening
# math runs — see AIActionScoring.deke_cut_side). ENGAGE_RANGE: the containing
# defender must be close enough that the duel is live but the fake still has
# room to develop — a step beyond the poke trigger's reach. MAX_CLOSING: the
# deke answers PATIENT containment; above this relative closing speed the
# pressure is committed and the brake check / seam cut own the moment. Both
# are physical duel measurements.
const DEKE_ENGAGE_RANGE_M: float = 3.5
const DEKE_CONTAIN_MAX_CLOSING_M_S: float = 2.0


# Haircut on the pass-OPTION value a carry candidate inherits (see
# _candidate_pass_option): the option is a coarse read — receiver valued at
# his CURRENT spot, lane judged against CURRENT defenders — and it still has
# to survive until the carrier actually arrives and releases. Tactical
# haircut, not an evaluation curve — the grounded terms (receiver value,
# lane, flight decay) are all inside the option itself. Candidates credit
# only the option's IMPROVEMENT over the same read at the current spot (see
# the subtraction in _score_move_candidate): a lane that is already open from
# here is the live pass's to take — fire wins ties — so repositioning earns
# option value only where it genuinely reopens something.
const PASS_OPTION_DISCOUNT: float = 0.8

# ── Puck-protect directionality (see the protect block in _pick_action) ──────
# A carrier driving at the net already screens the forward-held puck from a
# defender BEHIND it with its own body — no shield turn is needed to keep it
# away from a trailing stick. So the body-interposition protect read counts
# only defenders that are NOT already beaten: a defender projected (at the
# evasion horizon, so a fast back-checker who'll pull even by then still counts)
# more than this far behind the carrier along the netward line is screened for
# free and excluded. Without it a beaten checker trailing the rush keeps the
# shield engaged and the carrier stays turned side-on instead of squaring to the
# net the instant it clears its man — "protecting the puck after they've already
# beaten the guy pressuring them". A body-scale slack, the
# same band the state machine's man-to-beat test uses (CARRY_MAN_TO_BEAT_BEHIND_M):
# a defender even/beside the carrier still earns the shield; only one clearly
# skated past drops out. Physical screen measurement, not a shape knob.
const PROTECT_SCREEN_BEHIND_M: float = 0.75


# ── Persistent decision state ────────────────────────────────────────────────
# What the carrier currently wants to do. CARRY = no fire intent;
# fire intents persist across cooldown ticks so pre-aim keeps
# driving toward the chosen action.
var intended_action: int = INTENT_CARRY

# Seconds we've been HOLDING the puck for a developing cross-seam (see
# _pick_action). Feeds the existing carry decay so a wait that never pays off
# self-extinguishes — the bot takes the available shot — with no fixed timeout.
var _hold_elapsed_s: float = 0.0

# Seconds since this possession began — the clock the settle doubt decays on
# (see _settle_penalty). Armed to 0 on the first decide() after reset() (reset
# marks a genuine possession loss, so the next decide IS a fresh possession,
# including the very first one after spawn). clear_intent() deliberately does
# NOT re-arm it: a press-state bail back to CARRY is the same possession, not a
# new touch.
var _settle_arm_pending: bool = true
var _settle_elapsed_s: float = 0.0

# Set when intent commits to PASS. Consumed by the state machine
# when transitioning into PASS_PRESSED. -1 = no current pass target.
var pass_target_peer_id: int = -1

# Set alongside pass_target_peer_id when the chosen PASS is far enough
# that the carrier wrister-charges instead of quick-releasing. The
# state machine consumes this when entering PASS_PRESSED to branch
# between one-tick fire and ~250 ms wrister charge.
var pass_should_charge: bool = false

# LAUNCH speed for the chosen PASS (AIActionScoring.pass_launch_speed): set so
# the puck arrives on the teammate's tape at the magnet pace, friction-compensated
# by distance. The state machine maps this to the wrister charge fraction it winds
# up to, and leads the pass at this speed.
var pass_target_speed: float = AIActionScoring.PASS_SPEED_M_S

# Set alongside pass_target_peer_id when the chosen PASS is the saucer
# variant: a mid-lane defender contests the flat lane and the LOW-loft
# flip clears more of it (see _pass_variant_ev) — at a launch speed
# capped so the flip still lands with runway before the tape, which in
# close quarters means a genuinely soft flip. The state machine consumes
# this when entering PASS_PRESSED to set the loft level for the release;
# pass_target_speed carries the (possibly reduced) launch pace.
var pass_should_saucer: bool = false

# Set when intent commits to SHOOT: the loft (ShotMechanics.ELEVATION_*) of the
# best goalie hole the shot is aimed at — top corner → HIGH, bottom corner /
# five-hole → FLAT (see AIActionScoring.best_shot_loft).
# Consumed by the state machine's press-state handlers to drive the release loft.
var shot_loft_level: int = ShotMechanics.ELEVATION_FLAT

# Set alongside shot_loft_level: the world aim POINT of that same best hole (on
# the net plane), so the state machine aims the wrister exactly at the hole the
# loft was chosen for. INF until a SHOOT commit picks one.
var shot_aim_point: Vector3 = Vector3.INF

# Set alongside shot_loft_level: the release power fraction (0..1 over this
# bot's wrister band) of that same hole. Every hole fires full power — the
# contact-point solve adapts the launch angle, not the pace. For a
# backhand-side release the fraction is pre-compensated for the controller's
# backhand power penalty, so the executed pace matches the scored one (see
# the remap at the SHOOT commit).
var shot_power_t: float = 1.0

# Set alongside shot_loft_level: the world-space RELEASE OFFSET (relative to the
# projected release point) of the winning sample from the release-offset sweep —
# where in the blade's handling envelope the puck should sit at release. ZERO for
# the un-relocated release. The state machine folds it into the wind-up endpoint
# offsets so the blade actually carries the puck there (a backhand-side offset
# sweeps in the backhand chirality and pays the real power penalty — priced by
# the sampler).
var shot_release_offset: Vector3 = Vector3.ZERO

# Cached carry destination from the most recent re-eval. Read by the
# state machine to drive steering during CARRY.
var last_carry_anchor: Vector3 = Vector3.ZERO

# How far down the chosen launch line the dump's aim point is placed. Distance
# is not direction, but it has to clear the blade: the quick release aims
# blade->cursor and the blade is the ROM-projection of that same cursor, so a
# cursor inside the stick's reach carries no direction at all. Comfortably
# outside any reach.
const DUMP_AIM_STANDOFF_M: float = 20.0

# Set when intent commits to DUMP: the world spot to fire the puck at (no
# receiver), and the delivery kind — a soft flip (dump-and-chase into the OZ
# corner), a FLAT rim up our own wall (5v5 — the bank-pass delivery the wall
# winger meets; breakout plan §B), or the HIGH chip clear (neither flag).
# Read by the state machine's dump release.
var dump_target: Vector3 = Vector3.INF
var dump_is_soft: bool = false
var dump_is_rim: bool = false
# Launch pace (m/s) the soft dump-in's release must fire at — the winner of
# solve_dump_in's pace ladder, and the whole reason that ladder can place a
# puck. Only the soft dump-in reads it; the clear and the rim are fixed-pace
# one-tick releases.
var dump_launch_speed: float = AIActionScoring.PASS_SPEED_M_S

# ── Puck-protect mirror (read by the state machine's carry blade aim) ────────
# Where in the blade's handling envelope the puck is safest right now, as an
# OFFSET from the body (the state machine re-applies it to the live body
# position each tick), and the shield WEIGHT — how far the blade should swing
# from the presented-forward carry toward that protected seam (0 = keep the
# forward carry; 1 = pull the puck fully to the seam, body between puck and
# checker). The weight is the SAFETY THE SHIELD BUYS: the seam's reachable
# clearance less the forward spot's, so it rises only when the forward puck is
# genuinely covered AND a safer seam exists to pull it to (necessity AND
# ability), and falls to 0 the instant either is missing — no pressure floor,
# the shield engages exactly to the degree it helps. Zeroed while
# ctx.protects_the_puck is false (the naive-carry tier) and on possession loss.
# Refreshed every _pick_action re-eval (~30 Hz); staleness between re-evals is
# absorbed by the body-relative offset and the mouse motion smoothing.
var protect_offset: Vector3 = Vector3.ZERO
var protect_gain: float = 0.0
# Metres of room the PRESENTED-FORWARD puck has from every un-beaten defender's
# momentum-projected stick over the evasion horizon — negative when somebody can
# get a blade on it. This is the "necessity" half of the shield weight above,
# published because it is also the whole of the question the state machine's
# square-to-net facing asks: is there still a man to beat, i.e. would carrying
# the puck out in front of me right now give it away? Unlike the shield it is
# NOT gated on ctx.protects_the_puck — facing is a posture every tier holds, and
# the read is a physical contest measurement with no protect logic in it.
# EVADE_SAFE_MARGIN_M (what reach_clearance reports against nobody) until first
# computed, so a fresh carrier squares up rather than hunching over the puck.
var forward_puck_clearance: float = AIActionScoring.EVADE_SAFE_MARGIN_M
# The body-scale evasion seam from the same re-eval (world point) — the
# OBJECTIVE-DIRECTED seam (AIActionScoring.best_evade_point_toward): the safe
# spot with the most progress toward the live carry anchor, so the poke-evade
# deke cuts PAST the pressure toward where the carrier wants to go, falling
# back to pure max clearance only when nothing safe exists. Vector3.INF until
# first computed.
var evade_seam_world: Vector3 = Vector3.INF
# Whether a brake check (stop dead, let the committed checker's reach fly past)
# currently beats the seam cut against the live pressure —
# AIActionScoring.prefers_brake_check from the same re-eval. Latched by the
# state machine's poke-evade trigger to pick the maneuver; protect-tier only.
var brake_check_favored: bool = false
# Fake-then-cut deke read (AIActionScoring.deke_cut_side): true when faking
# one way manufactures a safe cut past the containing defender that doesn't
# exist right now — the answer to PATIENT containment (the seam cut needs
# clearance to already exist; the brake check needs the defender committed).
# The dirs are world-XZ units for the two committed phases, latched by the
# state machine's trigger. Protect-tier only; refreshed every re-eval.
var deke_go: bool = false
var deke_fake_dir: Vector2 = Vector2.ZERO
var deke_cut_dir: Vector2 = Vector2.ZERO

# ── Throttle ─────────────────────────────────────────────────────────────────
var _pick_action_cooldown: int = 0
# Physics ticks elapsed since the last _pick_action re-eval (accumulated per
# decide() call by ctx.dispatch_period_ticks), so the hold clock advances in
# real time regardless of the AI dispatch cadence. Reset when a commit runs.
var _ticks_since_pick: int = 0

# ── Compete time-slice ───────────────────────────────────────────────────────
# The full re-eval is the host's worst per-tick AI spike (~1.7–2.7 ms in the
# ai_micro bench — over a quarter of the 8333 µs tick budget in one call).
# Steady-state re-evals therefore split across two consecutive dispatches:
# the FIRE phase (_pick_fire_phase — opponent lists, seam/protect/deke reads,
# pass-option cache, SHOOT + PASS scoring) runs at cooldown expiry, and the
# COMMIT phase (_pick_commit_phase — carry candidates, dump, the fire-vs-carry
# compete) runs on the NEXT dispatch against a fresh snapshot, roughly halving
# the per-tick spike. The slice's cost is staleness, not cadence: at commit
# the fire scores are one dispatch (~2 ticks at the perfect-bot 60 Hz) old —
# well inside the ~135 ms windup the fired-puck lanes are already priced
# across — and the post-commit cooldown is shortened by the dispatch the
# commit phase consumed, so commits land at the same wall-clock cadence a
# single-call eval would. Single-call full evals still run for:
#   - the FIRST eval of a possession (reset()) and the first after a
#     press-state bail (clear_intent()): no cached plan exists yet, and the
#     fresh touch / bail is the contested moment where a dispatch of commit
#     latency would show;
#   - tiers whose dispatch span already covers the eval period (slicing
#     would halve their decision cadence — a behavior change, not a
#     scheduling one).
var _commit_phase_pending: bool = false
var _full_eval_pending: bool = true
# Fire-phase products consumed by the commit phase (instance fields so a
# sliced eval hands them across the dispatch boundary):
var _phase_current_safety: float = 0.0
var _phase_shoot_score: float = -1.0
var _phase_best_pass_peer: int = -1
var _phase_best_pass_score: float = -1.0
var _phase_best_pass_saucer: bool = false
# Opposing-goalie env captured alongside the winning shot sample, so the
# commit's loft/aim/power solve reads the same goalie the score saw:
var _shot_env_unsettled: float = 0.0
var _shot_env_five_hole: float = -1.0
var _shot_env_goalie_down: bool = false
var _shot_env_seal_x: float = 0.0
var _shot_env_seal_tall: bool = false
var _shot_env_hands: Vector4 = Vector4.INF
var _shot_env_pads: Vector4 = Vector4.INF

# ── Transition-exposure appetite (5v5 only — plan §6) ────────────────────────
# The per-position risk-aversion FEEL scalar on the counter-rush cost (the
# legitimate hand-set knob: the model does the seeing, this sets the
# appetite). Defensemen price the counter at face value; forwards discount
# it — the F3-high rotation is expected to absorb a forward caught deep, so
# an activist forward isn't scared out of the cycle. 3v3 pays zero (gated
# on ctx.team_size — protects shipping 3v3 tuning).
const EXPOSURE_APPETITE_DEFENSE: float = 1.0
const EXPOSURE_APPETITE_FORWARD: float = 0.7
# Loss probabilities below this skip the counter read entirely (hot-path
# floor, not a tuning knob: at 4% × a bounded threat the term is noise).
const EXPOSURE_PROB_FLOOR: float = 0.04

# ── Scratch buffers (reused across ticks, refilled per call) ────────────────
var _scratch_opponents: Array[Vector3] = []
# Velocities index-matched to _scratch_opponents, so the fired-puck lane
# model can dead-reckon a defender bearing down on a passing lane.
var _scratch_opponent_vels: Array[Vector3] = []
# AISkaterCaps index-matched to _scratch_opponents (entries may be null), so the
# reachable-set model reads each defender's real Agility/Size reach. Filled
# alongside the positions in _build_action_opponents_lists.
var _scratch_opponent_caps: Array[AISkaterCaps] = []
# Sprint pools index-matched to _scratch_opponents, the exhaustion lockout
# folded in as 0.0 — the counter-rush racer's stamina-gated race cap
# (counter_rush_cost / BotSprintRules.race_speed).
var _scratch_opponent_stamina: Array[float] = []
# Opponent positions advanced to the RELEASE instant — current pos + velocity ×
# the commit→release windup (BOT_WRISTER_LOOKAHEAD_S). Both the wrister SHOOT
# lane and the charged PASS lane/reception fire ~135 ms after the intent commits,
# so they read the puck out of a lane as it exists at release, not at decision
# time — a forechecker skating into a breakout lane has closed real ground during
# the windup. Index-matched to _scratch_opponent_vels / _scratch_opponent_caps
# (same fill order in _build_action_opponents_lists).
var _scratch_opponents_release: Array[Vector3] = []
var _scratch_opponents_pass: Array[Vector3] = []
var _scratch_opponents_path: Array[Vector3] = []
# Two-leg (wheel/apex) projections: filled at the apex arrival time for the
# second leg's reach read, then refilled at destination arrival for that
# leg's lane/pressure read.
var _scratch_opponents_cont: Array[Vector3] = []
var _scratch_teammate_ids: Array[int] = []
# Our skaters excluding the carrier — the defenders that reduce the
# opponent's threat in the turnover-cost term (the carrier just got
# beat, so they don't count). Rebuilt once per _pick_action; caps
# index-matched so the threat prices each defender's real blade.
var _scratch_our_defenders: Array[Vector3] = []
var _scratch_our_defender_caps: Array[AISkaterCaps] = []
# Teammate velocities, in the same order — the dump's chase clock is
# momentum-honest (see _best_dump), so the race needs their motion too.
var _scratch_our_defender_vels: Array[Vector3] = []
# Caller-owned out-param for the dump-in landing solve, so the release search
# returns its resting spot without allocating on the compete path.
var _scratch_dump_landing: Array[Vector3] = [Vector3.ZERO]
# Teammate ETAs to the counter point (transition exposure, 5v5) — rebuilt
# with _scratch_our_defenders, candidate-invariant across one compete.
var _scratch_exposure_mate_etas: Array[float] = []
# Lane of the last FLAT _pass_variant_ev (0.0 when the variant filtered out
# before its lane solve). The saucer gate reads it — see _compute_best_pass.
var _last_flat_variant_lane: float = 0.0
# The forward-space read _pass_ev resolved for the receiver it just priced, so
# the flat and saucer variants of one feed share a single solve (see the lazy
# note in _compute_best_pass). Reset to -1 before each receiver's first variant.
var _last_receiver_space: float = -1.0
# Per-bearing control from the carrier's own forward-space read, filled once per
# re-eval by _carrier_forward_clearance and consumed by _best_carry's candidate
# generator. Sized once to the fan's bearing count; the generator overwrites
# entries as it consumes them, so it is rebuilt (not appended to) every read.
var _scratch_bearing_control: Array[float] = []
# Counter-threat memo by covering-body count (see counter_rush_cost) —
# -1-seeded alongside the ETAs each compete.
var _scratch_exposure_threat_memo: Array[float] = []
# Our chasers for a dump race: our defenders plus ourselves (we dump and chase),
# and their velocities index-matched — the race is run on ETAs, so a chaser's
# momentum is part of it. Rebuilt inside _best_dump.
var _scratch_our_chasers: Array[Vector3] = []
var _scratch_our_chaser_vels: Array[Vector3] = []
# Legal DZ-clear launches and where each comes to rest, index-matched
# (AIActionScoring.dump_clear_candidates fills them; _best_dump prices them).
var _scratch_clear_vels: Array[Vector3] = []
var _scratch_clear_spots: Array[Vector3] = []
# Each clear candidate's recovery odds, filled by _best_dump's first pass so the
# second doesn't re-race the same bodies to the same spots.
var _scratch_clear_recovery: Array[float] = []
# Directional-filtered opponents for the puck-protect read (see the protect
# block in _pick_action): the full opponent set minus defenders the carrier's
# body already screens (beaten / behind, per PROTECT_SCREEN_BEHIND_M). Kept
# separate from _scratch_opponents so the shot / pass / carry lanes still see
# every defender. Index-matched triple, refilled every re-eval by
# _fill_protect_opponents.
var _scratch_protect_opponents: Array[Vector3] = []
var _scratch_protect_vels: Array[Vector3] = []
var _scratch_protect_caps: Array[AISkaterCaps] = []
# Pass-OPTION cache (see _candidate_pass_option): each legal receiver's
# position and spot value at its CURRENT location, computed once per
# _pick_action re-eval so the per-candidate option read only prices the LANE
# from the candidate. Index-matched pair; refilled every re-eval.
var _scratch_option_receiver_pos: Array[Vector3] = []
var _scratch_option_receiver_val: Array[float] = []
# The pass-option read at the current puck spot — candidates credit only their
# improvement over this (recomputed every re-eval in _pick_action).
var _pass_option_at_self: float = 0.0
# Best cached receiver value × PASS_OPTION_DISCOUNT — the exact upper bound on
# any candidate's option read (recomputed every re-eval in _pick_action).
var _pass_option_ceiling: float = 0.0

# Reused decision object returned by decide() — repopulated each call rather than
# freshly allocated, so the per-carry-dispatch call doesn't churn a RefCounted.
var _decision: RoleDecision = RoleDecision.new()

# ── Carry-candidate beam (two-ply search budget) ─────────────────────────────
# The two-ply pass-OPTION read is ~90% of a carry candidate's cost, and the exact incumbent-bound prunes lose their teeth
# exactly where the compete is at its most expensive — open ice, where
# safety/lane ≈ 1 for every spot so no candidate's ceiling falls below the
# running best. The beam bounds that worst case by POLICY instead: pass 1
# (_score_move_candidate_base) scores every candidate ONE-PLY — safety ×
# lane × decay × arrival-shot − turnover, a strict LOWER bound on its full
# value since the two-ply reads only ever RAISE a spot — and pass 2
# (_upgrade_candidate_two_ply) completes the two-ply reads for the
# CARRY_BEAM_WIDTH best one-ply rows only, best-first, under the same exact
# incumbent-bound prunes as before. This makes the argmax approximate — a
# spot whose entire winning margin lives in the second ply can miss the
# beam — accepted as a SEARCH-BUDGET policy (how much lookahead the bot
# buys), not an evaluation-model change: every score computed is still the
# same grounded model, and candidates outside the beam keep their one-ply
# totals, which can never win (the beam holds the K best lower bounds and
# upgrades only raise them). Guarded by the duel scenarios (beat-your-man
# sequences are exactly where a second-ply-only spot would matter) and the
# ai_micro / host-cost benches.
const CARRY_BEAM_WIDTH: int = 5
# Beam rows — one entry per base-scored candidate this re-eval, index-matched
# (cleared per _best_carry; clear() keeps capacity, so steady state allocates
# nothing). _beam_upgraded marks rows already completed by pass 2.
var _beam_pos: Array[Vector3] = []
var _beam_total: Array[float] = []
var _beam_dest: Array[float] = []
var _beam_lane: Array[float] = []
var _beam_decay: Array[float] = []
var _beam_safety: Array[float] = []
var _beam_cost: Array[float] = []
var _beam_time: Array[float] = []
# Pass-1 running prune bound: stand-still's secured total, tightened to the
# BEST one-ply total seen so far. Exact for the argmax even though it can
# prune candidates out of the beam: a candidate whose ceiling ≤ the best
# one-ply row can never out-upgrade that row (upgrades only raise values),
# so it can't win from inside the beam either — and that incumbent-bound
# strength is what keeps the CONTESTED case cheap (under pressure most
# candidates die at the lane/safety ceilings before paying for their
# arrival-shot read). Reset per _best_carry.
var _beam_prune_bound: float = -INF

# ── Debug readout ────────────────────────────────────────────────────────────
# Populated every re-eval; the state machine forwards these to its
# own debug_* fields for AIController / floating label.
var debug_shoot_score: float = 0.0
var debug_pass_score: float = 0.0
var debug_pass_peer_id: int = 0
var debug_carry_score: float = 0.0
var debug_carry_pos: Vector3 = Vector3.ZERO
var debug_dump_score: float = 0.0


# ── Public API ───────────────────────────────────────────────────────────────

# Top-level entry. Throttled at PICK_ACTION_PERIOD_TICKS. Mutates
# own state; the state machine reads `intended_action`,
# `pass_target_peer_id`, `shot_loft_level`, `last_carry_anchor`,
# and the debug_* fields after this returns.
#
# Returns the reused `_decision` member (populated below), NOT a fresh
# `RoleDecision` per call. The state machine's live path drives the carrier
# through this object's public fields and discards the return, but the return
# contract is kept (sibling roles and the test `_CarrierStub` share the
# `decide() -> RoleDecision` shape). Reusing one instance keeps a `RoleDecision.new()`
# off the per-carry-dispatch path — see CLAUDE.md -> hot-path discipline.
func decide(ctx: RoleContext) -> RoleDecision:
	# decide() is called once per AI dispatch; each call spans this many physics
	# ticks (1 at the perfect-bot default). Draining the cooldown by the real span
	# keeps the re-eval cadence ~PICK_ACTION_PERIOD_TICKS of wall time at every
	# difficulty tier instead of stretching it by the dispatch period.
	var step_ticks: int = maxi(1, ctx.dispatch_period_ticks)
	# Possession clock: zeroed on the first decide() of a fresh touch, then run in
	# real time. _pick_commit_phase reads it through _settle_penalty to handicap
	# the active options against their giveaway bars.
	if _settle_arm_pending:
		_settle_arm_pending = false
		_settle_elapsed_s = 0.0
	else:
		_settle_elapsed_s += float(step_ticks) / float(_PhysicsConstants.PHYSICS_TICK)
	_ticks_since_pick += step_ticks
	if _commit_phase_pending:
		# Second dispatch of a sliced re-eval: carry/dump scoring + the commit
		# compete against a fresh snapshot (see the slice doc above
		# _commit_phase_pending). The post-commit cooldown is shortened by the
		# dispatch this phase consumed so the commit cadence matches the old
		# single-call evals.
		_commit_phase_pending = false
		_pick_commit_phase(ctx, true)
		_arm_pick_cooldown(ctx, maxi(PICK_ACTION_PERIOD_TICKS - step_ticks, 0))
		_ticks_since_pick = 0
	elif _pick_action_cooldown <= 0:
		if _full_eval_pending or step_ticks >= PICK_ACTION_PERIOD_TICKS:
			# reads _ticks_since_pick for the hold-clock advance
			_full_eval_pending = false
			_pick_action(ctx)
			_arm_pick_cooldown(ctx, PICK_ACTION_PERIOD_TICKS)
			_ticks_since_pick = 0
		else:
			_pick_fire_phase(ctx)
			_commit_phase_pending = true
	else:
		_pick_action_cooldown -= step_ticks

	# Populate and return the reused decision (see the doc-block above). Fire
	# flags are reset each call so a stale intent from a prior tick can't leak.
	_decision.target_position = last_carry_anchor
	_decision.shoot_intent = false
	_decision.pass_intent = false
	_decision.pass_target_peer_id = -1
	match intended_action:
		INTENT_SHOOT:
			_decision.shoot_intent = true
		INTENT_PASS:
			_decision.pass_intent = true
			_decision.pass_target_peer_id = pass_target_peer_id
	return _decision


# Post-commit cooldown from `base_ticks` (the eval period, less any dispatch a
# sliced eval's commit phase already consumed), extended by the open-ice LOD
# (see OPEN_ICE_LOD_RADIUS_M) when the argmax answered CARRY with nobody near.
# Fire/pass intents keep the full cadence — their follow-through is
# timing-critical.
func _arm_pick_cooldown(ctx: RoleContext, base_ticks: int) -> void:
	_pick_action_cooldown = base_ticks
	if intended_action != INTENT_CARRY:
		return
	var lod_sq: float = OPEN_ICE_LOD_RADIUS_M * OPEN_ICE_LOD_RADIUS_M
	for opp: Vector3 in _scratch_opponents:
		if opp.distance_squared_to(ctx.self_pos) < lod_sq:
			return
	_pick_action_cooldown = base_ticks \
			+ PICK_ACTION_PERIOD_TICKS * (OPEN_ICE_LOD_PERIOD_MULT - 1)


# Clear all carrier state. Called by the state machine when leaving
# CARRY for OFF_PUCK / CHASE_PUCK (puck lost). Forces a fresh re-eval
# next time the bot enters CARRY.
func reset() -> void:
	intended_action = INTENT_CARRY
	pass_target_peer_id = -1
	pass_should_charge = false
	pass_target_speed = AIActionScoring.PASS_SPEED_M_S
	pass_should_saucer = false
	shot_loft_level = ShotMechanics.ELEVATION_FLAT
	shot_aim_point = Vector3.INF
	shot_power_t = 1.0
	shot_release_offset = Vector3.ZERO
	last_carry_anchor = Vector3.ZERO
	dump_target = Vector3.INF
	dump_is_soft = false
	dump_launch_speed = AIActionScoring.PASS_SPEED_M_S
	protect_offset = Vector3.ZERO
	protect_gain = 0.0
	forward_puck_clearance = AIActionScoring.EVADE_SAFE_MARGIN_M
	evade_seam_world = Vector3.INF
	brake_check_favored = false
	deke_go = false
	deke_fake_dir = Vector2.ZERO
	deke_cut_dir = Vector2.ZERO
	_hold_elapsed_s = 0.0
	_pick_action_cooldown = 0
	_ticks_since_pick = 0
	# A half-finished sliced eval is void with the possession (its fire reads
	# priced a puck we no longer hold); the fresh touch runs a single-call
	# full eval (see the slice doc above _commit_phase_pending).
	_commit_phase_pending = false
	_full_eval_pending = true
	# The puck is gone — the next decide() is a fresh possession, so re-arm the
	# settle clock (see _settle_arm_pending).
	_settle_arm_pending = true
	_settle_elapsed_s = 0.0


# Clear just the persistent intent (not last_carry_anchor / debug).
# Called by the state machine when committing to a press state, so
# the next CARRY entry starts with no stale intent and re-evaluates
# from scratch. Does NOT re-arm the settle clock — a press bail back to
# CARRY is the same possession, not a new touch.
func clear_intent() -> void:
	intended_action = INTENT_CARRY
	pass_target_peer_id = -1
	pass_should_charge = false
	pass_target_speed = AIActionScoring.PASS_SPEED_M_S
	pass_should_saucer = false
	dump_target = Vector3.INF
	dump_is_soft = false
	dump_launch_speed = AIActionScoring.PASS_SPEED_M_S
	_pick_action_cooldown = 0
	_ticks_since_pick = 0
	# A press bail re-enters CARRY mid-play with no live intent — the next
	# decide() answers same-call (single full eval) rather than paying a
	# dispatch of slice latency at a timing-critical seam.
	_commit_phase_pending = false
	_full_eval_pending = true


# ── Implementation ──────────────────────────────────────────────────────────

# Scores SHOOT (wrister), PASS (per teammate), and CARRY (all
# candidates) on equal footing. Hysteresis on fire intents only —
# carry does not get a hysteresis bonus (stand-still ties with the
# best fire from the same position by construction). FIRE WINS TIES;
# CARRY only beats fire on STRICTLY better future-action value.
# Mutates pass_target_peer_id when PASS wins, shot_loft_level when
# SHOOT wins, last_carry_anchor + intended_action always.
#
# Split into two phases so decide() can time-slice a steady-state re-eval
# across two dispatches (see the slice doc above _commit_phase_pending);
# this single-call form runs both back-to-back.
func _pick_action(ctx: RoleContext) -> void:
	_pick_fire_phase(ctx)
	_pick_commit_phase(ctx, false)


# FIRE phase of the compete: opponent lists, the evasion / brake-check / deke /
# protect reads, the pass-option cache, and the SHOOT + PASS scoring. Leaves
# its products in the _phase_* / _shot_env_* / _shot_sample_* fields (plus the
# _scratch_* buffers) for _pick_commit_phase.
func _pick_fire_phase(ctx: RoleContext) -> void:
	var snapshot: WorldSnapshot = ctx.snapshot
	var self_pos: Vector3 = ctx.self_pos
	var attacking_goal: Vector3 = ctx.attacking_goal_pos

	_build_action_opponents_lists(ctx)

	# Our current possession safety, from the reachable-set evasion model: can we
	# retain the puck against the defenders' momentum-reach? We read it as our
	# EVADABILITY — the clearance at the best seam we could handle the puck into —
	# so pressure we can dance out of (a committed charger) doesn't read as danger,
	# while a stick actually on the puck does. Feeds the hold's keep-probability
	# in the commit phase.
	var cur_puck_pos: Vector3 = _puck_pos_at(self_pos, attacking_goal)
	var evade_seam: Vector3 = AIActionScoring.best_evade_point(
			cur_puck_pos, ctx.self_velocity, _scratch_opponents, _scratch_opponent_vels,
			ctx.self_handle_reach, _scratch_opponent_caps)
	_phase_current_safety = AIActionScoring.clearance_to_safety(
			AIActionScoring.reach_clearance(evade_seam, AIActionScoring.EVADE_HORIZON_S,
					_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps))
	# The DIRECTED seam — where to put the puck to get PAST the pressure toward
	# the spot this carrier actually wants (the live carry anchor; the attacking
	# goal until the first re-eval of a possession picks one). This is the deke
	# direction the state machine latches and the seam candidate _best_carry
	# scores; the max-clearance seam above stays the honest safety read only.
	# The anchor is ≤ one re-eval stale as an objective, which is fine — the
	# seam is a body-scale step, not a route.
	var seam_objective: Vector3 = last_carry_anchor
	if seam_objective == Vector3.ZERO:
		seam_objective = attacking_goal
	var directed_seam: Vector3 = AIActionScoring.best_evade_point_toward(
			cur_puck_pos, ctx.self_velocity, seam_objective,
			_scratch_opponents, _scratch_opponent_vels,
			ctx.self_handle_reach, _scratch_opponent_caps)
	evade_seam_world = directed_seam
	# Brake-check read (AIActionScoring.prefers_brake_check): against this exact
	# pressure, does planting the feet — letting the committed checker's reach
	# fly past the physically-stopped puck — beat cutting to the seam? Mirrored
	# for the state machine's poke-evade trigger to pick the maneuver. Gated
	# with the other protect-tier reads: the brake check is taught puck skill.
	brake_check_favored = ctx.protects_the_puck \
			and AIActionScoring.prefers_brake_check(
					cur_puck_pos, ctx.self_velocity, directed_seam,
					_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps)

	# Fake-then-cut deke read (see the mirror fields' doc): find the PATIENT
	# container — the nearest opponent inside the duel range, ahead on the
	# objective line, with small relative closing (committed pressure belongs
	# to the brake check / seam) — and ask the manufactured-opening math
	# whether faking one way buys a safe cut past him that doesn't exist now.
	# The axis frame (puck → his projected spot, plus its perpendicular) is
	# built HERE and the returned side is converted with the same frame, so
	# the eval and the executed gesture agree by construction.
	deke_go = false
	deke_fake_dir = Vector2.ZERO
	deke_cut_dir = Vector2.ZERO
	if ctx.protects_the_puck:
		var obj_dir: Vector3 = seam_objective - cur_puck_pos
		obj_dir.y = 0.0
		if obj_dir.length_squared() > 0.0001:
			obj_dir = obj_dir.normalized()
			var deked_idx: int = -1
			var deked_dist: float = DEKE_ENGAGE_RANGE_M
			for i: int in _scratch_opponents.size():
				var to_opp: Vector3 = _scratch_opponents[i] - cur_puck_pos
				to_opp.y = 0.0
				var d: float = to_opp.length()
				if d >= deked_dist or d < 0.001:
					continue
				if to_opp.dot(obj_dir) <= 0.0:
					continue   # behind the play — not the man to beat
				var closing: float = (ctx.self_velocity - _scratch_opponent_vels[i]) \
						.dot(to_opp / d)
				if absf(closing) > DEKE_CONTAIN_MAX_CLOSING_M_S:
					continue   # committed pressure — other maneuvers own it
				deked_dist = d
				deked_idx = i
			if deked_idx != -1:
				var d_proj: Vector3 = _scratch_opponents[deked_idx] \
						+ _scratch_opponent_vels[deked_idx] \
								* (AIActionScoring.DEKE_FAKE_S + AIActionScoring.DEKE_CUT_S)
				var axis: Vector3 = d_proj - cur_puck_pos
				axis.y = 0.0
				if axis.length_squared() > 0.0001:
					axis = axis.normalized()
					var perp := Vector3(axis.z, 0.0, -axis.x)
					var side: int = AIActionScoring.deke_cut_side(
							cur_puck_pos, ctx.self_velocity, ctx.self_handle_reach,
							axis, perp, deked_idx,
							_scratch_opponents, _scratch_opponent_vels,
							_scratch_opponent_caps)
					if side != 0:
						var cut3: Vector3 = (axis + perp * float(side)).normalized()
						deke_go = true
						deke_cut_dir = Vector2(cut3.x, cut3.z)
						deke_fake_dir = Vector2(-perp.x * float(side), -perp.z * float(side))

	# Puck-protect read (see the mirror fields' doc): where in the blade envelope
	# alone the puck is safest, and the shield gain — how much safety pulling it
	# there buys over the presented-forward spot. The state machine blends the
	# carry mouse between the two by that gain — pure stick work, steering and the
	# carry destination are untouched.
	# Directional screen filter (see PROTECT_SCREEN_BEHIND_M): a carrier driving
	# at the net already shields the forward-held puck from a defender BEHIND it
	# with its own body, so a beaten checker trailing the rush must not keep the
	# shield on and hold the body side-on. Drop those defenders before the
	# pressure / seam read so it answers only genuine side/front pressure and the
	# carrier squares to the net the instant its man is beaten. The shot / pass /
	# carry lanes above still see every defender.
	#
	# The forward-puck clearance off that set runs for EVERY tier, because the
	# facing read consumes it too (see forward_puck_clearance) and facing is not
	# a protect skill. Only the seam work below is gated.
	_fill_protect_opponents(ctx)
	var horizon: float = AIActionScoring.EVADE_HORIZON_S
	var fwd_spot: Vector3 = _puck_pos_at(
			self_pos + ctx.self_velocity * horizon, attacking_goal)
	forward_puck_clearance = AIActionScoring.reach_clearance(fwd_spot, horizon,
			_scratch_protect_opponents, _scratch_protect_vels,
			_scratch_protect_caps)
	if ctx.protects_the_puck:
		var fwd_safety: float = AIActionScoring.clearance_to_safety(
				forward_puck_clearance)
		# HOW MUCH to shield and WHERE to put the puck are two questions answered
		# by two seams (see best_handle_protect_point). The WEIGHT reads the
		# MAX-clearance seam — the safety the best available shield buys.
		var max_seam: Vector3 = AIActionScoring.best_handle_protect_point(
				self_pos, ctx.self_velocity, _scratch_protect_opponents,
				_scratch_protect_vels, ctx.self_handle_reach, _scratch_protect_caps)
		# Shield WEIGHT = the safety the shield actually buys. best_handle_protect_point
		# projects the body to the same horizon, so proj + offset is the seam world
		# point; its clearance less the forward spot's is how much safer shielding
		# makes the puck. Positive only under genuine coverage (necessity: the
		# forward puck is inside a stick's reach) AND with somewhere safer to hide it
		# (ability: the seam clears more), zero the instant either is missing — the
		# grounded alternative to a pressure floor, which would gate a raw coverage
		# read by a hand-picked number and shield pre-emptively against near
		# defenders who aren't actually threatening the puck.
		var seam_world: Vector3 = self_pos + ctx.self_velocity * horizon + max_seam
		var seam_safety: float = AIActionScoring.clearance_to_safety(
				AIActionScoring.reach_clearance(seam_world, horizon,
						_scratch_protect_opponents, _scratch_protect_vels,
						_scratch_protect_caps))
		protect_gain = clampf(seam_safety - fwd_safety, 0.0, 1.0)
		# …and the DIRECTION is the least-committal seam that is still safe,
		# directed at the presented-forward spot. Shield strength is unchanged
		# (that is the weight above); this only stops the blade going further off
		# the play line than the safety actually requires.
		protect_offset = AIActionScoring.best_handle_protect_point(
				self_pos, ctx.self_velocity, _scratch_protect_opponents,
				_scratch_protect_vels, ctx.self_handle_reach,
				_scratch_protect_caps, fwd_spot)
	else:
		protect_gain = 0.0
		protect_offset = Vector3.ZERO

	# Teammate ids — used by every score_at evaluation (top + inner).
	# Reused scratch buffer; receivers only read from it.
	_scratch_teammate_ids.clear()
	for peer_id: int in snapshot.skater_states:
		if peer_id == ctx.peer_id:
			continue
		if ctx.team_id_by_peer.get(peer_id, -1) == ctx.team_id:
			_scratch_teammate_ids.append(peer_id)

	# Pass-OPTION cache: each legal receiver's spot value at its CURRENT
	# position (goalie arc-squared to it), computed once per re-eval so the
	# per-candidate option read (_candidate_pass_option) only prices the LANE
	# from the candidate — the thing repositioning actually changes. Legality
	# mirrors _compute_best_pass: no ghosts, and an OZ carrier only counts
	# receivers safely inside the zone.
	_scratch_option_receiver_pos.clear()
	_scratch_option_receiver_val.clear()
	var in_oz_now: bool = AIActionScoring.in_offensive_zone(self_pos, attacking_goal)
	for pid: int in _scratch_teammate_ids:
		var tm: SkaterNetworkState = snapshot.skater_states[pid]
		if tm.is_ghost:
			continue
		if in_oz_now and not AIActionScoring.in_offensive_zone(
				tm.position, attacking_goal, OZ_RECEIVE_LINE_BUFFER_M):
			continue
		var tm_caps: AISkaterCaps = ctx.caps_by_peer.get(pid)
		var tm_shot_speed: float = tm_caps.wrister_shot_speed if tm_caps != null \
				else AIActionScoring.WRISTER_SHOT_SPEED_M_S
		var tm_goalie: Vector3 = AIActionScoring.goalie_squared_pos(
				_goalie_now(ctx), attacking_goal, tm.position)
		_scratch_option_receiver_pos.append(tm.position)
		_scratch_option_receiver_val.append(_score_at(
				ctx, tm.position, self_pos, _scratch_opponents, tm_goalie,
				tm_shot_speed, 0.0))
	# The same option read at the CURRENT puck spot — the baseline candidates'
	# option credit is measured against (see _score_move_candidate): an option
	# already available from here belongs to the live pass in the fire
	# compete, so only the IMPROVEMENT motivates a carry. Subtracting the
	# at-self read also cancels the coarse option model's bias against the
	# fully-priced pass common-mode.
	_pass_option_at_self = _candidate_pass_option(ctx, cur_puck_pos)
	# Ceiling on ANY candidate's option (lane/miss/decay all ≤ 1): the best
	# cached receiver value at full discount. When even that can't improve on
	# the at-self read, no candidate's per-receiver lane loop can either — the
	# whole option read skips per candidate (see _score_move_candidate). Exact.
	_pass_option_ceiling = 0.0
	for v: float in _scratch_option_receiver_val:
		if v * PASS_OPTION_DISCOUNT > _pass_option_ceiling:
			_pass_option_ceiling = v * PASS_OPTION_DISCOUNT

	# Projected RELEASE position for SHOOT scoring. The wrister charge
	# window means the puck actually leaves the blade ~0.25s after
	# the SHOOT intent commits; a bot rushing into the slot should
	# be scoring the spot they'll release from, not the spot they're
	# at now. This also lets the bot start the wind-up early — the
	# score that wins is for the future spot, and by the time the
	# charge completes, the bot has skated into it.
	var self_velocity: Vector3 = ctx.self_velocity
	var horizontal_velocity: Vector3 = Vector3(self_velocity.x, 0.0, self_velocity.z)
	# Goalie's CURRENT position (squared to whoever currently holds the puck —
	# that's us as the carrier). This is where the goalie actually is, used to
	# clamp the wrister release, since the goalie is a body the release can't cross.
	var goalie_now: Vector3 = _goalie_now(ctx)
	# The shot originates where the PUCK is — the carried puck rides the blade, up
	# to a stick's reach from the body — so the release ref is the puck's current
	# spot led by our body velocity, not the body center. At range the offset is
	# noise; in tight it's the difference between measuring the net from your
	# chest and from the puck (closer, and shifted to the forehand side — a real
	# angle change around the goalie). Using the same release point as the
	# keeper's tracking target below is slightly generous to HIM (his quiet-eye
	# smoothing actually rides the body line, absorbing the dangle) — the safe
	# side of that asymmetry.
	var puck_now: Vector3 = self_pos
	if ctx.snapshot.puck_state != null:
		puck_now = Vector3(
				ctx.snapshot.puck_state.position.x, 0.0,
				ctx.snapshot.puck_state.position.z)
	var wrister_base_release: Vector3 = puck_now \
			+ horizontal_velocity * SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
	# No shot when the PUCK ITSELF is on/behind the goal line. score_shoot already
	# zeroes a release behind the line, but it scores the velocity-projected
	# release (puck led by body speed) and clamps a behind-the-goalie release to a
	# jam point in FRONT of him — so a carrier whose body is past the line but
	# whose projected blade lands a hair in front scores a phantom point-blank open
	# net and fires a zero-angle rip off the outer pipe. The mouth faces up-ice: from on/behind
	# the line there is no direct shot, only a wrap or a walk-out CARRY. Gate on the
	# real puck's forward distance, not the projection.
	var puck_forward_of_line: float = (puck_now.z - attacking_goal.z) \
			* -signf(attacking_goal.z)
	var shot_from_behind_line: bool = puck_forward_of_line <= SHOT_MIN_FORWARD_OF_LINE_M

	# ...and no shot at all from OUTSIDE the attacking zone while the keeper is
	# HOME. This is the same proof threat_surface_shoot and _score_at already
	# run: at that range a direct shot is dead by score_shoot's own
	# arrival-honest coverage math — he is square long before the puck arrives —
	# so the goalie hole geometry, the three-sample release sweep and the tip
	# read below all resolve to ~0 on every neutral- and defensive-zone dispatch.
	#
	# The reason to gate it is the GUARANTEE, not the cost: measured on the
	# micro-bench's out-of-zone carrier the saving is ~26 us of a ~1850 us
	# compete (~1.4%, inside the run-to-run noise), because the carry beam
	# dominates that number. Do not cite this as a perf win. The giveaway bar
	# (SHOT_MIN_VALUE) already made a own-zone shot unreachable in practice, but
	# only by arithmetic that runs downstream of two multipliers — the fire
	# hysteresis and the smart-ping SHOOT bias — both of which scale a live
	# score upward before the bar is checked. With the score never computed there
	# is nothing for either to lift: SHOOT cannot win a compete outside the zone
	# by any route.
	#
	# The keeper-home condition is load-bearing and is why this is not a blanket
	# zone gate: a DISPLACED or PULLED keeper voids the proof, and an empty net
	# genuinely scores from centre ice. That shot has to stay available, exactly
	# as it does in the other two consumers.
	var shot_unavailable: bool = shot_from_behind_line \
			or (not AIActionScoring.in_offensive_zone(self_pos, attacking_goal)
					and goalie_now.distance_to(attacking_goal)
							< AIActionScoring.THREAT_GOALIE_HOME_M)

	# The five-hole as it physically exists RIGHT NOW, from the replicated pose:
	# standing = the real ~0.20 m slot between the pads (sealable by dropping —
	# the model gates on the reach time vs the drop), down = the residual leak.
	# Instance fields (_shot_env_*), so the commit phase's loft/aim/power solve
	# reads the same goalie env the winning sample was scored against.
	_shot_env_unsettled = 0.0
	_shot_env_five_hole = -1.0
	_shot_env_goalie_down = false
	_shot_env_seal_x = 0.0
	_shot_env_seal_tall = false
	_shot_env_hands = Vector4.INF
	_shot_env_pads = Vector4.INF
	var opp_goalie_state: GoalieNetworkState = ctx.snapshot.goalie_states.get(1 - ctx.team_id)
	if opp_goalie_state != null and not shot_unavailable:
		_shot_env_goalie_down = opp_goalie_state.is_down()
		# Hand + pad positions off the same replicated pose (hole-model v3):
		# the HIGH cover races from where the glove/blocker actually are,
		# the LOW cover from the measured pad edges.
		_shot_env_hands = opp_goalie_state.hands_read(ctx.attacking_goal_pos.z)
		_shot_env_pads = opp_goalie_state.pads_read(ctx.attacking_goal_pos.z)
		_shot_env_five_hole = GoalieBehaviorRules.five_hole_gap_m(
				_shot_env_goalie_down, opp_goalie_state.five_hole_openness)
		# Post-seal stance (VH/RVH): the goalie is committed to a post and the
		# pose IS the coverage — see the seal model in _hole_open_angle. A
		# committed post stance also does not re-square: he holds the post
		# while the sharp-angle threat lasts (the state we read is refreshed
		# every tick), so score the shot against where he's actually parked,
		# not a hypothetical arc-squared keeper — the squared model both
		# invents coverage he'd need to leave the post to provide AND hides
		# the far-side opening his commitment concedes.
		_shot_env_seal_x = opp_goalie_state.post_seal_x_sign(attacking_goal.z)
		_shot_env_seal_tall = opp_goalie_state.is_post_seal_tall()

	# Top-level SHOOT: the release-offset sweep (see RELEASE_SAMPLE_FRACS). Each
	# sample relocates the projected release across the blade envelope, prices
	# the relocation's blade-travel time into the goalie's tracking budget and a
	# backhand-side release at the build's backhand pace, then runs the same
	# score_shoot the single release ran. Per sample, the goalie at puck ARRIVAL
	# is react-then-slide from where he ACTUALLY is toward the arc-square of the
	# release, over everything the shot gives him — the charge lookahead (plus
	# the relocation) plus the whole flight. Static or long-range releases he
	# covers square with room to spare; a HARD LATERAL CUT IN TIGHT is a race
	# his accel-ramped push genuinely loses — and the sweep adds the blade's own
	# lateral relocation on top of the skating cut. Unsettled stays 0: the
	# shortfall IS the caught-moving effect, expressed positionally.
	# _scratch_opponent_caps is index-matched to _scratch_opponents (and thus to
	# _scratch_opponents_release, built in the same order), so a lane defender's
	# real reach and speed price the shot lane.
	var shot_dir: Vector3 = attacking_goal - wrister_base_release
	shot_dir.y = 0.0
	shot_dir = shot_dir.normalized() if shot_dir.length_squared() > 0.0001 \
			else Vector3(0.0, 0.0, -signf(attacking_goal.z))
	var forehand_perp: Vector3 = Vector3(shot_dir.z, 0.0, -shot_dir.x) \
			* ctx.self_forehand_perp_sign
	var usable_offset: float = _usable_release_offset(ctx.self_handle_reach)
	_phase_shoot_score = -1.0
	for frac: float in RELEASE_SAMPLE_FRACS:
		if shot_unavailable:
			break
		var offset: Vector3 = forehand_perp * (frac * usable_offset)
		var sample_speed: float = ctx.self_wrister_shot_speed
		if frac < 0.0:
			sample_speed *= ctx.self_backhand_power_coefficient
		var release: Vector3 = AIActionScoring.release_ahead_of_goalie(
				wrister_base_release + offset, attacking_goal, goalie_now)
		var shift_s: float = absf(frac) * usable_offset \
				/ maxf(ctx.self_blade_speed, 0.1)
		var flight_s: float = release.distance_to(attacking_goal) \
				/ maxf(sample_speed, 1.0)
		# The goalie's tracking budget includes this bot's EXPECTED release
		# lateness — the mean of the uniform [0, max] hold the execution
		# samples (ctx.shot_timing_error_s × 0.5), so the score is the MEDIAN
		# outcome of the release the hand will actually produce. This is what
		# un-automates the razor lateral beats without swallowing them: a
		# window around the median slop is still taken (it scores as the
		# thin-but-real look it is) and the sampled delay then decides it —
		# early enough beats the push, late enough meets a square goalie.
		# Windows the median release can't hit score ~0 through the hole
		# geometry and lose the compete on their own.
		# The shooter's own netward pace backs the keeper in over the wind-up +
		# flight (the planning depth model) — a release taken while driving
		# meets a retreating keeper, a standstill one meets the chart.
		var shot_closing: float = AIActionScoring.closing_toward(
				ctx.self_pos, ctx.self_velocity, attacking_goal)
		var sample_goalie: Vector3 = goalie_now if _shot_env_seal_x != 0.0 \
				else AIActionScoring.predict_goalie_pos(
						goalie_now, attacking_goal,
						SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S + shift_s
								+ flight_s + ctx.shot_timing_error_s * 0.5,
						release, shot_closing)
		# Own traffic screens: the in-zone teammates (_scratch_option_receiver_pos,
		# filled above) ride along as sightline bodies — the net-front man parked
		# in the goalie's eyes is what makes the point blast a real chance.
		# THE SEAM, same as the carry and pass legs. The fire-vs-carry-vs-pass
		# compete is a comparison, so all three sides must be denominated in the
		# same currency: the saturating hole model on the shoot leg against
		# NHL-calibrated xG on the others makes SHOOT win outright, a 1.0 ceiling
		# against a 0.4 one (the backdoor-feed and peel-out fixtures catch it).
		#
		# The replicated pose (_shot_env_hands / _pads / _five_hole) drops out
		# of the GATE and stays where it is truth: picking aim / loft / power
		# once SHOOT has won, below.
		var shot_disp: float = AIShotValue.displacement_deficit_m(
				goalie_now, attacking_goal, release,
				SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
						+ flight_s + ctx.shot_timing_error_s * 0.5)
		var s: float = AIActionScoring.score_shoot_value(
				release, attacking_goal, sample_goalie, shot_disp,
				GameRules.NET_HALF_WIDTH, _scratch_opponents_release,
				sample_speed, _scratch_opponent_caps)
		if s > _phase_shoot_score:
			_phase_shoot_score = s
			_shot_sample_release = release
			_shot_sample_goalie = sample_goalie
			_shot_sample_speed = sample_speed
			_shot_sample_offset = offset
			_shot_sample_backhand = frac < 0.0

	# Shoot-for-tip: the same rip at the net can score by DEFLECTION off a
	# stationed net-front teammate — the point-blast-plus-tipper play. An
	# alternative AIM of the same fire action (through the tipper's blade vs
	# at a direct-model hole), so it competes with the direct read by max(),
	# never additively. Scored against the in-zone teammates already gathered
	# for the pass options; goalie taken set at his current spot (conservative
	# — the tip's whole edge is the collapsed post-contact read, which the
	# hole geometry prices via t_reach).
	_shot_sample_is_tip = false
	if not shot_unavailable and not _scratch_option_receiver_pos.is_empty():
		var tip_release: Vector3 = AIActionScoring.release_ahead_of_goalie(
				wrister_base_release, attacking_goal, goalie_now)
		for tip_man: Vector3 in _scratch_option_receiver_pos:
			var tip_s: float = AIActionScoring.tip_ev(
					tip_release, tip_man, attacking_goal, goalie_now,
					GameRules.NET_HALF_WIDTH, _scratch_opponents_release,
					ctx.self_wrister_shot_speed, _scratch_opponent_caps)
			if tip_s > _phase_shoot_score:
				_phase_shoot_score = tip_s
				_shot_sample_release = tip_release
				_shot_sample_goalie = goalie_now
				_shot_sample_speed = ctx.self_wrister_shot_speed
				_shot_sample_offset = Vector3.ZERO
				_shot_sample_backhand = false
				_shot_sample_is_tip = true

	# Top-level PASS — per teammate, score_at(receiver_lead) × lane × time.
	var self_state: SkaterNetworkState = snapshot.skater_states[ctx.peer_id]
	var best_pass: Array = _compute_best_pass(
			ctx, self_state.facing, _scratch_teammate_ids)
	_phase_best_pass_peer = best_pass[0]
	_phase_best_pass_score = best_pass[1]
	_phase_best_pass_saucer = best_pass[2]


# COMMIT phase of the compete: the CARRY candidate argmax, the DUMP read, and
# the fire-vs-carry-vs-hold compete that commits the intent. Consumes the fire
# phase's _phase_* / _shot_env_* / _shot_sample_* products. `rebuild_lists` is
# true on the second dispatch of a SLICED eval: the fire phase's opponent
# lists are one dispatch old there, so the carry/dump scoring rebuilds them
# from the fresh snapshot (the fire SCORES stay the older reads — the
# accepted slice staleness; single-call evals skip the rebuild).
func _pick_commit_phase(ctx: RoleContext, rebuild_lists: bool) -> void:
	var snapshot: WorldSnapshot = ctx.snapshot
	var self_pos: Vector3 = ctx.self_pos
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	if rebuild_lists:
		_build_action_opponents_lists(ctx)
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var puck_now: Vector3 = self_pos
	if snapshot.puck_state != null:
		puck_now = Vector3(
				snapshot.puck_state.position.x, 0.0,
				snapshot.puck_state.position.z)
	var directed_seam: Vector3 = evade_seam_world
	var current_safety: float = _phase_current_safety
	var shoot_score: float = _phase_shoot_score
	var best_pass_peer: int = _phase_best_pass_peer
	var best_pass_score: float = _phase_best_pass_score
	var best_pass_saucer: bool = _phase_best_pass_saucer

	# Top-level CARRY — the best candidate _best_carry builds, each scored
	# uniformly as score_at(candidate, projected_opps) × path_clear × time_decay.
	# Time uses momentum-aware effective speed, so reverse candidates
	# self-discount through their longer arrival.
	# Smart-ping SHOOT: a teammate ordered this carrier to fire (see
	# PING_SHOOT_EV_MULT — bias, not force; a zero shot stays zero).
	# Stand-still's shot branch shares the raw shoot-now score (see _best_carry)
	# — captured before the ping bias, which is a FIRE-compete thumb only (an
	# ordered "shoot!" must not make holding look better too).
	var raw_shoot_score: float = shoot_score
	if ctx.ping_shoot_active and shoot_score > 0.0:
		shoot_score *= PING_SHOOT_EV_MULT

	# The forward-space read runs BEFORE the carry search, because the search
	# feeds on its by-product: the per-bearing control profile
	# (_scratch_bearing_control) is where the forward carry candidates come from
	# (see _best_carry). One read, two consumers — the discount below and the
	# candidate generator — so the profile costs nothing extra.
	var forward_space: float = _carrier_forward_clearance(ctx)

	var carry_result: Array = _best_carry(
			ctx, raw_shoot_score, directed_seam)
	var carry_score: float = carry_result[0]
	last_carry_anchor = carry_result[1]
	var raw_carry_score: float = carry_result[2]
	# Pass-first under pressure: discount the carry by how contested the path AHEAD is,
	# so a lightly-impeded carrier moves the puck to an unimpeded teammate rather than
	# grinding forward (even giving up some real estate). Only the fire-vs-carry
	# compete sees this — the dump still judges against the honest raw carry.
	carry_score *= lerpf(FORWARD_PRESSURE_MIN_SCALE, 1.0, forward_space)
	# …but judge SELF by the same currency a pass receiver gets: _pass_ev credits
	# a receiver with the best shot he can REACH by driving in (drive-in credit).
	# Without the mirror, two equally-covered wingers at the blue line each rate
	# the OTHER man's future above their own present — my carry pays the forward-
	# pressure discount while his drive-in does not — and the puck ping-pongs
	# along the line (an offside factory) instead of ever entering the zone. The
	# same formula on MY OWN spot floors the carry: a symmetric mate can never
	# out-score me by proxy, so the pass only wins when he is GENUINELY more
	# open, and a free entry gets taken by the man who already has the puck.
	# Priced at our OWN velocity, exactly as the receiver's is (_pass_ev passes
	# receiver_vel): the drive-in is momentum-honest — a man in stride carries his
	# pace into the drive while one curling back must brake it out first — so
	# omitting it here would price every carrier as standing still and credit a
	# gliding mate with momentum the man holding the puck is denied.
	var drive_in_value: float = _receiver_drive_in_value(
			ctx, self_pos, ctx.self_wrister_shot_speed,
			ctx.caps_by_peer.get(ctx.peer_id), ctx.self_velocity)
	carry_score = maxf(carry_score, drive_in_value)

	# Hysteresis on FIRE intents only — prevents flicker between two
	# close-scoring fire options during pre-aim. Proportional (×(1 +
	# FRAC), positive scores only — see ACTION_HYSTERESIS_MARGIN_FRAC)
	# so stickiness scales with the score's magnitude instead of
	# swamping the small-score defensive-zone regime. CARRY does NOT
	# get a hysteresis bonus: stand-still's shot branch IS the raw
	# shoot-now score (shared into _best_carry), so stand can never
	# exceed fire, and we want fire to win those ties (see tiebreak
	# below). A CARRY hysteresis bonus would push stand-still above
	# fire on every re-eval and the bot would never fire.
	if intended_action == INTENT_SHOOT and shoot_score > 0.0:
		shoot_score *= 1.0 + AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC
	elif intended_action == INTENT_PASS and best_pass_score > 0.0:
		best_pass_score *= 1.0 + AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC

	# Debug snapshot of the per-tick scores for the floating label.
	# State machine forwards these to its own debug_* fields; AIController
	# polls and refreshes only when content changes.
	debug_shoot_score = shoot_score
	debug_pass_score = best_pass_score
	debug_pass_peer_id = best_pass_peer
	debug_carry_score = carry_score
	debug_carry_pos = last_carry_anchor

	# The wrister is the only shot type — a paced release covers everything from a
	# soft in-tight roof to a full-power rip (see #363). A separate no-charge quick
	# snap earns nothing: the fast ~125 ms wrister out-scores it even into a set
	# goalie point-blank.
	var best_shot_score: float = shoot_score
	var best_shot_intent: int = INTENT_SHOOT

	# Settle doubt: a fresh carrier's discount on its own read of every ACTIVE
	# option, charged against that option's giveaway bar only (see _settle_penalty
	# for why it must not enter the compete itself). 0 for Hard / the perfect bot.
	var settle_penalty: float = _settle_penalty(ctx)

	# Best fire option — the best of those that clear their OWN giveaway bar
	# (SHOT_MIN_VALUE / PASS_MIN_VALUE). Qualifying each option before the max
	# rather than after it is what keeps the two bars independent: taking the
	# max first would let a mediocre shot mask a perfectly legal outlet pass and
	# veto the whole fire leg, so raising the shot's bar would silently suppress
	# passing too. Nothing qualifying leaves fire at -INF, which loses every
	# compete below — the puck is never given away for nothing.
	#
	# The bar is cleared by the DOUBTED value, the compete below is entered at the
	# HONEST one: the doubt says whether this option is worth the puck yet, not
	# what it is worth. Handicapping the compete score too would just re-time the
	# option instead of de-selecting it (again, see _settle_penalty).
	var fire_score: float = -INF
	var fire_intent: int = best_shot_intent
	if _settle_handicap(best_shot_score, settle_penalty) > SHOT_MIN_VALUE:
		fire_score = best_shot_score
	if _settle_handicap(best_pass_score, settle_penalty) > PASS_MIN_VALUE \
			and best_pass_score > fire_score:
		fire_score = best_pass_score
		fire_intent = INTENT_PASS

	# Compete fire vs carry. FIRE WINS TIES — when a fire option scores the same as
	# the best carry candidate (typically stand-still, whose shot branch is the
	# shoot-now score itself), fire. Carry should only beat fire when a movement
	# candidate has a STRICTLY better future-action value, i.e. there is a real
	# reason to keep moving instead of firing now.
	#
	# EXCEPT: fire must clear the GIVEAWAY FLOOR to win. Firing surrenders the puck
	# (shot up-ice, or a pass); holding/carrying retains it and its optionality. So a
	# low-value fire must not beat a collapsing hold — a carrier swarmed deep in
	# its own zone (pass = 0, all lanes covered, carry collapsing toward 0) must skate
	# clear, not fling a hopeless shot away, and a CONTAINED one must work the puck
	# rather than trade it for a point shot. A bare `> 0` is nowhere near enough: on
	# the seam's NHL-calibrated scale a long clear-lane look still scores a real few
	# percent, which beats a contained carry's own honest value. SHOT_MIN_VALUE is
	# what a possession is worth, PASS_MIN_VALUE only rejects a release into
	# nothing; a genuine in-range shot scores well above its bar and still wins ties.
	#
	# ALSO: don't START a fire while staggered. A body check knocks the
	# bot off-balance (thrust penalty on stagger_timer); winding up a
	# shot/pass through it flails the release. Hold the puck and protect
	# it until the brief stagger decays — carry still computes normally,
	# this only blocks fire from winning the compete.
	#
	# The settle doubt is NOT a second gate here — a fresh carrier's hesitation is
	# already spent above, as the raised bar each active option had to clear to
	# reach this compete at all.
	var staggered: bool = ctx.self_stagger_timer > 0.0

	# Opportunity cost of firing NOW: the value of keeping the puck for a
	# developing cross-seam one-timer a teammate is staging. Same EV currency as
	# the shot/pass — P(keep the puck) × the feed's value — decayed by how long
	# we've already held, via the SAME carry delay-discount the rest of the model
	# uses. No bonus, no threshold, no fixed timeout: it just competes in the max.
	#   - keep_prob from the reachable evadability → under pressure we can't dance
	#     out of, the hold is risky and loses; in open ice it's ~1 and can win.
	#   - decay(elapsed) → a wait that never materialises self-extinguishes (the
	#     developing value shrinks until the available shot wins).
	# When the teammate flags ready, the developing feed drops to 0 here but the
	# normal pass scoring jumps (one-timer), so PASS wins and feeds it.
	# keep_prob is our current possession safety, computed once at the top of
	# _pick_action — the hold only holds its value while we can actually keep it.
	var keep_prob: float = current_safety
	var hold_value: float = (_best_developing_feed(ctx)
			* keep_prob * AIActionScoring.delay_discount(_hold_elapsed_s))

	var new_intent: int
	# Only filled when the delivery search actually runs (the dump branch below);
	# -INF on the label means "nothing was conceded", not "a dump scored -INF".
	debug_dump_score = -INF
	# ── The dump is a RESIDUAL, not an option ────────────────────────────────
	# Never score the dump and enter it in the value compete. That asks a dumped
	# puck's whole future to be commensurable with a carry's next beat, in one
	# currency, at every point on the rink, and it is not: the dump reaches a
	# spot the carry is forbidden to name (its credit is horizon-capped), so it
	# out-scores an OPEN carrier on an EMPTY RINK; it wins by being the SAFE play
	# whenever the carry is contested, though the real cost of a failed entry and
	# a dump-in are within a hair of each other; and the softest release on the
	# ladder keeps winning because its landing solve puts the puck in the slot.
	#
	# Real hockey does not make this choice on value either. Every coaching
	# source states it as an ordering, not a comparison: carry when you have
	# speed and space; if the gap is soft and you have a passing option, use it;
	# dumping when you have time and space is a mistake; the dump-in is a LAST
	# RESORT, not a default. The evidence agrees on the ordering's direction — a
	# controlled entry generates 2-5x the shots of a dump-in, a dump-in is
	# recovered only 22-29% of the time, and the conclusion drawn from it is that
	# players give the puck up at the blue line too easily.
	#
	# So the question is not "is a dump worth more than a carry" but "is there
	# anything else left". Retention is HOPELESS only when keeping the puck
	# is honestly worth nothing — the strip-point-priced carry has non-positive
	# EV AND there is no drive-in to skate into — which is an ABSOLUTE read with
	# no reference to the dump and no bar to tune. A qualified fire then beats
	# the concession outright (that is the "you have a passing option" clause),
	# and only with no carry and no fire does the search run at all, purely to
	# pick the best DELIVERY. Which also means it stops running 36 landing solves
	# and two race solves on every tick the bot was always going to carry.
	#
	# Both readings of "keeping the puck is worth something" have to fail,
	# because each is blind where the other sees. The raw carry is honest but
	# ONE BEAT AHEAD, so it cannot see the entry a carrier skates into by beating
	# his man; the drive-in sees exactly that but is benefit-only, so it cannot
	# go negative and cannot by itself say a carry is doomed.
	#
	# …except in OUR OWN ZONE, where the alternative is a CLEAR and the drive-in
	# gets no vote. The two are not the same errand and never were: the drive-in
	# prices skating the length of the ice from our own corner, benefit-only, so
	# it is positive for any carrier with a sliver of a lane and would veto every
	# clear a pinned bot ever wanted to make. A carrier buried on his own wall
	# with two forecheckers on him is not going to skate out of it, and "when in
	# doubt, get it out" is the whole of the doctrine there. Past centre the
	# drive-in earns its vote back, because there the alternative is an offensive
	# dump-in and a free entry must never be flung away.
	var in_own_zone: bool = AIActionScoring.in_offensive_zone(
			self_pos, ctx.defending_goal_pos)
	var retention_hopeless: bool = raw_carry_score <= 0.0 \
			and (in_own_zone or drive_in_value <= 0.0)
	# Fire if it beats retention (carrying + holding for the developing play) —
	# or, when retention is hopeless, at all. A release that cleared its own
	# giveaway bar is a live play and a dump is what is left when there is none,
	# so the ordering is fire-then-dump with nothing to compare: an unqualified
	# fire arrives here as -INF and loses both branches, which is the only test
	# that matters.
	if ((fire_score >= carry_score and fire_score >= hold_value)
			or (retention_hopeless and fire_score > -INF)) \
			and not staggered:
		_hold_elapsed_s = 0.0
		new_intent = fire_intent
		if new_intent == INTENT_PASS:
			pass_target_peer_id = best_pass_peer
			# Every pass is a paced wrister now (the #363 pure-mouse-speed model
			# makes release pace reliable, so there's no reason to keep the fixed-
			# power quick snap): distance-adaptive launch speed — a genuinely soft
			# touch for a close feed, harder (still catchable) for a long one — all
			# from the one charged release, capped at this bot's own max wrister.
			var receiver: SkaterNetworkState = ctx.snapshot.skater_states.get(best_pass_peer)
			if receiver != null:
				# Receiver-relative launch: fire so the puck lands on the tape at
				# the magnet CLOSING speed in the receiver's frame (#373) — harder
				# onto a streaking receiver, softer to one curling back — not a
				# fixed world speed that arrives hot or soft depending on his motion.
				# Distance and direction from the PUCK (the real release point).
				var to_receiver: Vector3 = receiver.position - puck_now
				to_receiver.y = 0.0
				var pass_dir: Vector3 = to_receiver.normalized()
				pass_target_speed = AIActionScoring.pass_launch_speed(
						puck_now.distance_to(receiver.position),
						ctx.self_wrister_shot_speed, ctx.pass_speed_scale,
						receiver.velocity, pass_dir)
			else:
				pass_target_speed = AIActionScoring.PASS_SPEED_M_S * ctx.pass_speed_scale
			pass_should_charge = true
			# Saucer it over a contested mid-lane defender (see
			# _pass_variant_ev). The launch is capped at the receivability
			# bound for the current distance — a flip that arrives still
			# airborne flies over the receiver's grounded blade — so a
			# close-quarters saucer commits as a genuinely soft flip even
			# after the receiver-relative pace solve above.
			pass_should_saucer = best_pass_saucer
			if best_pass_saucer and receiver != null:
				pass_target_speed = clampf(
						AIActionScoring.saucer_max_launch_speed(
								puck_now.distance_to(receiver.position)),
						GameRules.DEFAULT_WRISTER_POWER_MIN_M_S,
						pass_target_speed)
		elif new_intent == INTENT_SHOOT and _shot_sample_is_tip:
			# TIP rip: flat and full pace THROUGH the net-front blade at the
			# net centre — the line the tipper's reactive mode steps onto
			# (AIRoleFinisher._try_reactive_decision). Flat keeps the puck on
			# the blade plane; full pace keeps the arrival above the deflect
			# threshold so contact redirects instead of catching.
			shot_loft_level = ShotMechanics.ELEVATION_FLAT
			shot_aim_point = Vector3(
					attacking_goal.x, 0.0, attacking_goal.z)
			shot_power_t = 1.0
			shot_release_offset = Vector3.ZERO
		elif new_intent == INTENT_SHOOT:
			# Loft AND aim from the same goalie-hole geometry score_shoot used —
			# the chosen hole's elevation and net-plane target, scored at the
			# WINNING SAMPLE's release/goalie/pace so the executed shot is
			# exactly the one that won the compete. Roofs a set goalie
			# (top-corner window), stays flat on a five-hole / low corner, and
			# aims exactly at that hole.
			# Same screened read the score saw (score_shoot derives this
			# internally from the same bodies) — so a shot taken BECAUSE the
			# screen opens a hole is aimed at that hole, not at the narrower
			# window a clean-look goalie would leave.
			var shot_screen_dist: float = AIActionScoring.screen_along_m(
					_shot_sample_release, _shot_sample_goalie,
					_scratch_opponents_release, _scratch_option_receiver_pos)
			shot_loft_level = AIActionScoring.best_shot_loft(
					_shot_sample_release, attacking_goal, _shot_sample_goalie,
					GameRules.NET_HALF_WIDTH, _shot_sample_speed,
					_shot_env_unsettled, _shot_env_five_hole, _shot_env_goalie_down,
					_shot_env_seal_x, _shot_env_seal_tall, ctx.self_aim_spread_rad,
					shot_screen_dist, _shot_env_hands, _shot_env_pads, ctx.self_loft_tans)
			shot_aim_point = AIActionScoring.best_shot_aim(
					_shot_sample_release, attacking_goal, _shot_sample_goalie,
					GameRules.NET_HALF_WIDTH, _shot_sample_speed,
					_shot_env_unsettled, _shot_env_five_hole, _shot_env_goalie_down,
					ctx.self_aim_spread_rad,
					_shot_env_seal_x, _shot_env_seal_tall, shot_screen_dist,
					_shot_env_hands, _shot_env_pads, ctx.self_loft_tans)
			# Full power for every hole: the contact-point solve adapts the
			# LAUNCH ANGLE, so pace only buys flight time and toe-clamp relief.
			shot_power_t = 1.0
			shot_release_offset = _shot_sample_offset
			if _shot_sample_backhand:
				# The controller applies backhand_power_coefficient to the FINAL
				# power, while the sampler already scored at the penalized pace —
				# so pre-divide: solve the fraction over the full wrister band
				# whose penalized result is the pace the sample was scored (and
				# power_t solved) at. Full backhand rip maps back to t = 1.
				var min_v: float = GameRules.DEFAULT_WRISTER_POWER_MIN_M_S
				var target_v: float = min_v \
						+ shot_power_t * maxf(_shot_sample_speed - min_v, 0.0)
				var coef: float = maxf(ctx.self_backhand_power_coefficient, 0.05)
				shot_power_t = clampf(
						(target_v / coef - min_v)
							/ maxf(ctx.self_wrister_shot_speed - min_v, 0.001),
						0.0, 1.0)
	elif retention_hopeless and not staggered:
		# Last resort, and the ONLY place the delivery search runs: keeping the puck
		# is worth nothing and no qualified fire exists, so clear our zone or
		# dump-and-chase. The search's whole job here is to pick WHICH delivery —
		# its score is read only as availability (-INF where no dump applies: the
		# own-side neutral zone, or a DZ from which every launch either ices or dies
		# in our own end). With none available there is nothing to concede TO, so
		# keep skating and let the next re-eval look again.
		var dump_result: Array = _best_dump(ctx, our_goalie)
		debug_dump_score = dump_result[0]
		if dump_result[0] > -INF:
			_hold_elapsed_s = 0.0
			new_intent = INTENT_DUMP
			dump_target = dump_result[1]
			dump_is_soft = dump_result[2]
			dump_is_rim = dump_result[3]
			dump_launch_speed = dump_result[5]
		else:
			_hold_elapsed_s = 0.0
			new_intent = INTENT_CARRY
	else:
		# Not firing. Advance the hold clock only while the developing play is the
		# reason (it out-scores plain carrying); a normal carry resets it so the
		# next genuine hold starts fresh at full value.
		if hold_value > carry_score and hold_value > 0.0:
			_hold_elapsed_s += float(_ticks_since_pick) / float(_PhysicsConstants.PHYSICS_TICK)
		else:
			_hold_elapsed_s = 0.0
		new_intent = INTENT_CARRY

	intended_action = new_intent


# Populates the scratch lists used by _pick_action's scoring:
# - _scratch_opponents: current opponent positions, for dump scoring / the
#   evasion + protect reads (all present-time).
# - _scratch_opponents_release: positions predicted forward by the commit→
#   release windup (BOT_WRISTER_LOOKAHEAD_S), for the FIRED-puck lanes — the
#   wrister shot AND the charged pass both leave the blade ~135 ms after intent
#   commits, so the lane they thread is priced at release-time defender spots.
# Pass scoring uses a third per-receiver list (_scratch_opponents_pass)
# rebuilt inside `_compute_best_pass` because the lookahead varies per
# teammate.
func _build_action_opponents_lists(ctx: RoleContext) -> void:
	_scratch_opponents.clear()
	_scratch_opponent_vels.clear()
	_scratch_opponent_caps.clear()
	_scratch_opponent_stamina.clear()
	_scratch_opponents_release.clear()
	_scratch_our_defenders.clear()
	_scratch_our_defender_caps.clear()
	_scratch_our_defender_vels.clear()
	for peer_id: int in ctx.snapshot.skater_states:
		if peer_id == ctx.peer_id:
			continue
		var s: SkaterNetworkState = ctx.snapshot.skater_states[peer_id]
		if ctx.team_id_by_peer.get(peer_id, -1) != ctx.team_id:
			_scratch_opponents.append(s.position)
			_scratch_opponent_vels.append(s.velocity)
			_scratch_opponent_caps.append(ctx.caps_by_peer.get(peer_id))
			_scratch_opponent_stamina.append(0.0 if s.sprint_locked else s.stamina)
			_scratch_opponents_release.append(AITrajectory.predict_at(
					s.position, s.velocity, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S))
		else:
			# Our teammate — a defender for the turnover-cost term.
			_scratch_our_defenders.append(s.position)
			_scratch_our_defender_caps.append(ctx.caps_by_peer.get(peer_id))
			_scratch_our_defender_vels.append(s.velocity)
	# Transition-exposure precompute (5v5): each teammate's ETA to the
	# counter point is candidate-invariant, so race them once per re-eval
	# instead of once per counter_rush_cost call (~25 calls/compete).
	if ctx.team_size >= 5:
		AIActionScoring.fill_counter_cover_etas(
				ctx.defending_goal_pos, _scratch_our_defenders,
				_scratch_exposure_mate_etas)
		_scratch_exposure_threat_memo.resize(_scratch_our_defenders.size() + 2)
		_scratch_exposure_threat_memo.fill(-1.0)


# Refills the directional protect-opponent triple (see the protect block in
# _pick_action) from the full opponent lists, dropping every defender the
# carrier's body already screens: projected to the evasion horizon, a defender
# more than PROTECT_SCREEN_BEHIND_M behind the carrier along the netward line is
# beaten and excluded. Both bodies are projected to the SAME instant so a fast
# back-checker who'll pull even by then still counts as pressure. The netward
# direction runs from the body to the attacking goal; when that is degenerate
# (carrier on the goal), no defender is dropped. Reuses member scratch arrays —
# carrier-only (~1 bot/team) at the ~30 Hz re-eval, no per-call allocation.
func _fill_protect_opponents(ctx: RoleContext) -> void:
	_scratch_protect_opponents.clear()
	_scratch_protect_vels.clear()
	_scratch_protect_caps.clear()
	var horizon: float = AIActionScoring.EVADE_HORIZON_S
	var to_goal: Vector3 = ctx.attacking_goal_pos - ctx.self_pos
	var len_sq: float = to_goal.x * to_goal.x + to_goal.z * to_goal.z
	var have_dir: bool = len_sq > 0.0001
	var nx: float = 0.0
	var nz: float = 0.0
	if have_dir:
		var inv: float = 1.0 / sqrt(len_sq)
		nx = to_goal.x * inv
		nz = to_goal.z * inv
	var self_proj_x: float = ctx.self_pos.x + ctx.self_velocity.x * horizon
	var self_proj_z: float = ctx.self_pos.z + ctx.self_velocity.z * horizon
	for i: int in _scratch_opponents.size():
		if have_dir:
			var opp_proj_x: float = _scratch_opponents[i].x \
					+ _scratch_opponent_vels[i].x * horizon
			var opp_proj_z: float = _scratch_opponents[i].z \
					+ _scratch_opponent_vels[i].z * horizon
			var ahead: float = (opp_proj_x - self_proj_x) * nx \
					+ (opp_proj_z - self_proj_z) * nz
			if ahead < -PROTECT_SCREEN_BEHIND_M:
				continue   # beaten — the body screens the forward puck for free
		_scratch_protect_opponents.append(_scratch_opponents[i])
		_scratch_protect_vels.append(_scratch_opponent_vels[i])
		_scratch_protect_caps.append(_scratch_opponent_caps[i])


# Refills `out_buf` with each opponent's position projected forward
# by `time_s`. Used by carry-candidate scoring (per-candidate arrival
# time) and pass scoring (per-receiver flight time) — same buffer is
# reused, refilled before each scoring call.
func _project_opponents_to(ctx: RoleContext, time_s: float,
		out_buf: Array[Vector3]) -> void:
	out_buf.clear()
	for peer_id: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(peer_id, -1) != ctx.team_id and peer_id != ctx.peer_id:
			var s: SkaterNetworkState = ctx.snapshot.skater_states[peer_id]
			out_buf.append(AITrajectory.predict_at(s.position, s.velocity, time_s))


# Loops every legal pass target and returns [best_pid, best_score]. A
# pass takes 0.5–1.1 s of flight time, so the receiver and every
# defender are projected forward by that flight time for the receiver's
# inner score_at (pressure when the puck arrives). The lane-interception
# term uses the reaction-window pass model on CURRENT defender positions
# instead, since lane_clear models defenders closing over the flight.
# Top-level pass scoring under the universal model:
#
#   pass_score(receiver) = score_at(receiver_lead, projected_opps)
#                          × lane_clear(self → receiver_lead, pass_speed)
#                          × pow(decay, pass_flight_time)
#
# score_at recursively considers what the receiver could do (shoot, pass to
# others, carry to slot) — a real future-action eval rather than a bundle of
# receiver-quality heuristics.
#
# Filters:
#   - Skip ghosted teammates (puck passes through them).
#   - Skip receivers predicted past our own goal line (own-goal risk).
#   - Carrier in OZ → receiver must also be in OZ (offside protection),
#     and the intercept lead must sit OZ_RECEIVE_LINE_BUFFER_M inside the
#     blue line — a tape at the line loses the zone on routine reception
#     slop (see the constant's doc).
#   - Behind-the-back receivers are NOT skipped: an aim inside the real
#     ±157° reach cone fires with no body turn, and only the narrow back
#     wedge pays — as rotation time priced into the EV's delay via
#     _facing_rotation_time. A hard ROM skip would discard feeds the cone
#     genuinely covers.
#   - Hard zero for net-blocker (segment crosses net body) and
#     own-DZ slot crossing (intercepted = goal-against).
#
# Each receiver is scored as up to TWO variants competing on EV: the flat
# feed at the magnet pace, and — when the flat lane is contested — a
# saucer at min(magnet pace, the receivability bound
# AIActionScoring.saucer_max_launch_speed), i.e. a soft flip in close
# quarters, full pace on a stretch feed. The saucer pays
# SAUCER_EXTRA_MISS_PROB for its fiddlier landing, so it wins exactly when
# the sticks it flies over are worth more than the landing risk.
func _compute_best_pass(ctx: RoleContext, self_facing_xz: Vector2,
		teammate_ids: Array[int]) -> Array:
	var snapshot: WorldSnapshot = ctx.snapshot
	var self_pos: Vector3 = ctx.self_pos
	var best_pass_peer: int = 0
	var best_pass_score: float = 0.0
	# Whether the winning pass should be lofted (saucer) over a contested
	# mid-lane defender. Tracked alongside best_pass_score so it reflects
	# the pass that actually wins, not the last one evaluated.
	var best_pass_saucer: bool = false
	# Our goalie + defenders feed the turnover-cost term: how much an
	# interception would help the opponent, dampened by our coverage.
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	# One-way valve: a carrier already in the offensive zone won't pass the puck
	# back out of it (mirrors the carry-side exclusion in _score_move_candidate).
	var carrier_in_oz: bool = AIActionScoring.in_offensive_zone(self_pos, attacking_goal)
	var pass_origin: Vector3 = _pass_origin(ctx)
	for peer_id: int in teammate_ids:
		var receiver_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		if receiver_state.is_ghost:
			continue
		if carrier_in_oz and not AIActionScoring.in_offensive_zone(
				receiver_state.position, attacking_goal):
			continue
		var receiver_is_one_timer: bool = (ctx.team_brain != null
				and ctx.team_brain.is_one_timer_ready(peer_id))
		# Match the speed the state machine will actually fire at: the
		# distance-adaptive launch speed (capped at this bot's own max
		# wrister). Threading the actual speed here makes the lead and
		# opponent projections match reality — without it, a 15 m pass
		# scored at 14 m/s overestimates defender presence on the line and
		# leads past the receiver, both of which depress long-pass scores
		# below where they should be.
		var dist: float = pass_origin.distance_to(receiver_state.position)
		# Receiver-relative, matching the FIRE site exactly (the _pick_action
		# INTENT_PASS block): the launch is solved so the puck lands at the
		# magnet pace in the RECEIVER'S frame — harder onto a streaker, softer
		# to one curling back. Scoring at the static pace while firing the
		# relative one over-credits every feed to a receiver curling toward the
		# play: the lane prices at ~20 m/s while the real puck leaves soft,
		# handing defenders the longer flight to close and beating the saucer
		# variant with a flat EV the flat feed never had.
		var to_recv: Vector3 = receiver_state.position - pass_origin
		to_recv.y = 0.0
		var scored_pass_dir: Vector3 = to_recv.normalized() \
				if to_recv.length_squared() > 0.0001 else Vector3.ZERO
		var pass_speed: float = AIActionScoring.pass_launch_speed(
				dist, ctx.self_wrister_shot_speed, ctx.pass_speed_scale,
				receiver_state.velocity, scored_pass_dir)
		var receiver_accel: Vector3 = ctx.acceleration_by_peer.get(peer_id, Vector3.ZERO)
		# Receiver's heading turn rate — the commitment read. A commitment-blind
		# tier (Easy) reads 0, so it prices a turning receiver like a straight one
		# and chucks the feed; Normal/Hard price the turn (see _pass_variant_ev).
		var receiver_omega: float = ctx.heading_omega_by_peer.get(peer_id, 0.0) \
				if ctx.reads_receiver_commitment else 0.0
		var receiver_caps: AISkaterCaps = ctx.caps_by_peer.get(peer_id)
		# How much room this MAN has — solved AT MOST ONCE per receiver, and only
		# if a variant actually gets far enough to need it. Space is a property of
		# the receiver and the ice around him, not of the pass that reaches him
		# (the flat and saucer leads differ by well under a stick's reach, and the
		# read is a smooth field), so computing it per variant would pay for the
		# same answer twice on the hottest path in the compete and let the two
		# variants disagree about how open the same teammate is. It stays LAZY because
		# it is the dominant cost here and _pass_ev's hard-zero gates (net-blocked
		# lane, own-slot crossing, dead lane) reject a receiver before his value
		# is ever priced — a covered man must not be paid for.
		_last_receiver_space = -1.0
		# Exact prune floor for this receiver: the running best, un-scaled by any
		# bonus applied to him AFTER scoring. A ping target's EV is multiplied by
		# PING_PASS_EV_MULT below, so pruning him at the raw best would discard a
		# feed that goes on to win — divide the floor by the same factor and the
		# bound stays sound.
		var prune_floor: float = best_pass_score
		if peer_id == ctx.ping_pass_target_peer:
			prune_floor /= PING_PASS_EV_MULT
		# Flat feed at the magnet pace.
		_last_flat_variant_lane = 0.0
		var s: float = _pass_variant_ev(
				ctx, receiver_state, receiver_accel, receiver_omega, receiver_caps,
				pass_origin, pass_speed, false, receiver_is_one_timer,
				self_facing_xz, our_goalie, carrier_in_oz, -1.0, prune_floor)
		var receiver_space: float = _last_receiver_space
		var use_saucer: bool = false
		# Saucer variant: the fastest RECEIVABLE flip — the magnet pace when
		# the feed is long enough to land with runway, a genuinely soft flip
		# in close quarters — competing on EV against the flat feed. Below
		# the soft-touch wrister floor no legal saucer exists (the physical
		# minimum saucer distance, ~6.5 m).
		var saucer_speed: float = minf(
				pass_speed, AIActionScoring.saucer_max_launch_speed(dist))
		# Saucer competes only when the FLAT feed is contested — that is the
		# variant's own first filter (SAUCER_SKIP_WHEN_LANE_CLEAR), read here
		# off the flat variant's already-solved lane so a clear-lane receiver
		# skips the whole second lead-solve + lane + EV — the filter's intent is
		# the lane of the feed that would actually fire. A flat variant that filtered before
		# its lane solve leaves 0.0 — "contested" — so the saucer still gets
		# its own look at leads the flat pass couldn't take.
		if saucer_speed >= GameRules.DEFAULT_WRISTER_POWER_MIN_M_S \
				and _last_flat_variant_lane < AIActionScoring.SAUCER_SKIP_WHEN_LANE_CLEAR:
			var s_saucer: float = _pass_variant_ev(
					ctx, receiver_state, receiver_accel, receiver_omega, receiver_caps,
					pass_origin, saucer_speed, true, receiver_is_one_timer,
					self_facing_xz, our_goalie, carrier_in_oz, receiver_space,
					maxf(prune_floor, s))
			if s_saucer > s:
				s = s_saucer
				use_saucer = true
		# Smart-ping PASS_TO_ME / IM_OPEN: the pinger asked for the puck (see
		# PING_PASS_EV_MULT — bias, not force; a dead lane still scores 0).
		if peer_id == ctx.ping_pass_target_peer and s > 0.0:
			s *= PING_PASS_EV_MULT
		if s > best_pass_score:
			best_pass_score = s
			best_pass_peer = peer_id
			best_pass_saucer = use_saucer
	return [best_pass_peer, best_pass_score, best_pass_saucer]


# EV of ONE pass variant (flat, or saucer at a possibly-reduced launch
# speed) to `receiver_state`. Solves the intercept lead at the variant's
# actual speed, applies the per-variant filters, then prices it through
# the shared _pass_ev. Returns 0.0 when the variant is filtered out
# (illegal lead, unreceivable saucer, or a loft that clears nothing).
#
# Filters here (the receiver-independent ones live in the caller's loop):
#   - Lead past our own goal line (own-goal risk).
#   - Carrier in OZ → lead must sit OZ_RECEIVE_LINE_BUFFER_M inside the
#     blue line (see the constant's doc — a tape at the line loses the
#     zone on routine reception slop).
#   - Saucer only: the lead must leave the flip landing runway
#     (airborne carry + SAUCER_LANDING_RUN_M — a closing receiver can
#     shrink the solved lead under what the current distance allowed),
#     the flat lane must actually be contested
#     (SAUCER_SKIP_WHEN_LANE_CLEAR), and the loft must clear MORE of the
#     lane than staying flat — otherwise there is nothing to fly over.
#
# One-timer-ready receivers fire on contact (no wrister windup), so the
# goalie only gets the pass flight to react — the caller resolves that
# flag once per receiver and threads it here.
func _pass_variant_ev(ctx: RoleContext, receiver_state: SkaterNetworkState,
		receiver_accel: Vector3, receiver_omega: float, receiver_caps: AISkaterCaps,
		pass_origin: Vector3, pass_speed: float, saucer: bool,
		receiver_is_one_timer: bool, self_facing_xz: Vector2,
		our_goalie: Vector3, carrier_in_oz: bool,
		receiver_space: float = -1.0,
		useless_below: float = -INF) -> float:
	# Intercept-aware lead, shared with the state machine's firing aim.
	# flight_t is the SOLVED time (refined against the predicted
	# intercept), used downstream for opponent/goalie projection and
	# the time-decay term. The receiver's real build (Speed/Agility) bounds
	# how far it can actually get to — a fast, agile receiver is led further.
	var lead: Array = AIPassLead.lead(
			pass_origin, receiver_state, receiver_accel, pass_speed,
			PASS_LEAD_MAX_S, receiver_caps)
	var receiver: Vector3 = lead[0]
	var flight_t: float = lead[1]
	if ctx.own_goal_dir * receiver.z > GameRules.GOAL_LINE_Z:
		return 0.0
	if carrier_in_oz and not AIActionScoring.in_offensive_zone(
			receiver, ctx.attacking_goal_pos, OZ_RECEIVE_LINE_BUFFER_M):
		return 0.0
	var lane: float
	# Derived execution-miss (see AIActionScoring.pass_miss_prob): this bot's own
	# release-direction error projected to the receiver over the pass distance, vs
	# the receiver's catch envelope (its Hands handle reach) — so a long feed or a
	# wobblier-handed bot misses more, over the irreducible base floor.
	var catch_radius: float = receiver_caps.handle_reach if receiver_caps != null \
			else AIActionScoring.EVADE_CARRY_HANDLE_M
	# Receiver-commitment term: a receiver mid-cut curves off the straight-line
	# lead, adding catch-point uncertainty the passer's hand can't lead out. Zero
	# for a settled receiver (or a commitment-blind tier — the caller passes
	# receiver_omega 0), so a clean quick feed is unaffected.
	var receiver_speed: float = sqrt(
			receiver_state.velocity.x * receiver_state.velocity.x
			+ receiver_state.velocity.z * receiver_state.velocity.z)
	var turn_uncertainty: float = AIActionScoring.receiver_heading_uncertainty_m(
			receiver_speed, receiver_omega, flight_t)
	var miss_prob: float = AIActionScoring.pass_miss_prob(
			pass_origin.distance_to(receiver), ctx.self_pass_aim_error_rad,
			catch_radius, turn_uncertainty)
	if saucer:
		# Small tolerance: a speed sitting exactly on the receivability
		# bound round-trips through the kinematics to the exact distance.
		if pass_origin.distance_to(receiver) \
				< AIActionScoring.saucer_airborne_distance_m(pass_speed) \
				+ AIActionScoring.SAUCER_LANDING_RUN_M - 0.01:
			return 0.0
		var lane_flat: float = AIActionScoring.lane_clear(
				pass_origin, receiver, _scratch_opponents_release, pass_speed,
				_scratch_opponent_vels, _scratch_opponent_caps, true)
		if lane_flat >= AIActionScoring.SAUCER_SKIP_WHEN_LANE_CLEAR:
			return 0.0
		lane = AIActionScoring.lane_clear_saucer(
				pass_origin, receiver, _scratch_opponents_release, pass_speed,
				_scratch_opponent_vels, _scratch_opponent_caps)
		if lane <= lane_flat:
			return 0.0
		miss_prob += AIActionScoring.SAUCER_EXTRA_MISS_PROB
	else:
		lane = AIActionScoring.lane_clear(
				pass_origin, receiver, _scratch_opponents_release, pass_speed,
				_scratch_opponent_vels, _scratch_opponent_caps, true)
		_last_flat_variant_lane = lane
	var receiver_release_t: float = flight_t
	if not receiver_is_one_timer:
		receiver_release_t += SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
	var rotation_time: float = _facing_rotation_time(
			self_facing_xz, ctx.self_pos, receiver,
			ctx.self_reach_cone_half_angle, ctx.self_facing_turn_rate)
	return _pass_ev(ctx, receiver, pass_speed, flight_t,
			receiver_release_t, flight_t + rotation_time, our_goalie,
			receiver_caps, lane, miss_prob, receiver_state.velocity,
			receiver_space, useless_below)


# Expected value of firing a pass from our current position to
# `receiver_spot`. Shared by the live per-teammate pass scoring
# (_compute_best_pass) and the developing-outlet hold
# (_developing_outlet_feed), so "the pass this wait is creating" and
# "the pass I can fire now" are priced identically — the hold
# self-terminates the instant the real pass matches it (fire wins ties).
#
# Benefit = P(complete) × value of us having it at the receiver, decayed
# by `delay_s` (flight + any facing rotation). P(complete) folds THREE
# loss modes: lane interception (lane_clear), residual execution miss
# (AIActionScoring.pass_miss_prob — overled / fumbled on an otherwise clear
# lane, derived from this bot's hand + the pass length), and a reception
# strip (a defender on the catch — see reception_safety below).
#
# Cost = the value the OPPONENT gains from each loss mode's location:
#   - intercepted in flight → the interceptor's spot on the lane
#     (lane_loss_point), probability 1 − lane.
#   - execution miss → the puck dies past the receiver
#     (pass_miss_loss_point), probability lane × miss_prob.
# Same threat surface both ways, so the exchange rate is 1 (no aversion
# knob) and both costs self-localize — ~0 for offensive-zone losses,
# large for own-zone ones. This is what makes a low-upside backpass deep
# in our own end lose to skating: its benefit barely beats carrying, but
# its miss mode surrenders the ice in front of our net.
#
# Lane interception uses the reaction-window PASS model (lane_clear) on
# RELEASE-TIME defender positions (_scratch_opponents_release — current pos
# advanced by the commit→release windup), not the geometric carry-path check.
# A pass is a fired puck that leaves the blade ~135 ms after the intent commits
# (every bot pass is a charged wrister), so a forechecker actively skating into
# the lane has closed real ground before the puck is even released. Price the lane
# at PRESENT-time spots and those breakout feeds read as open, shipping the puck
# straight into the closing stick. lane_clear then models the further closing over
# the flight from that release-time start, scaled by the actual pass speed.
# Opponents are projected to flight time for the receiver's inner score_at
# (lanes/pressure when the puck arrives).
# `lane` may be precomputed by the caller (the variant scorer computes
# flat vs saucer lanes itself); pass < 0 to have the grounded lane
# computed here. `miss_prob` is the execution-miss probability for this
# variant (a saucer adds its landing risk on top of the flat default).
#
# Predicts the goalie at `receiver_release_t` (flight + the receiver's
# wrister charge, or flight alone for one-timer-ready receivers — the
# caller decides). A cross-seam feed leaves the goalie mid-slide, so the
# receiver's shot is scored against that unsettled goalie (the goalie-hole
# geometry opens up when he's caught moving). Receiver shot speed stays the
# league default (we don't carry teammates' attributes).
func _pass_ev(ctx: RoleContext, receiver_spot: Vector3, pass_speed: float,
		flight_t: float, receiver_release_t: float, delay_s: float,
		our_goalie: Vector3, receiver_caps: AISkaterCaps = null,
		lane: float = -1.0,
		miss_prob: float = AIActionScoring.PASS_MISS_BASE_PROB,
		receiver_vel: Vector3 = Vector3.ZERO,
		receiver_space: float = -1.0,
		useless_below: float = -INF) -> float:
	var self_pos: Vector3 = ctx.self_pos
	# The pass flies from the PUCK (the blade), not the body — judge the lane
	# the puck actually travels. From behind the net the two differ by up to a
	# stick's reach, which is exactly where "clear from the chest, clanks the
	# frame from the blade" lives. (self_pos stays the carrier-body reference for
	# the receiver scoring / loss-point terms below.)
	var origin: Vector3 = _pass_origin(ctx)
	# Hard zeros: net-blocker (segment crosses a net body) and own-DZ
	# slot crossing (intercepted = goal-against).
	if AIActionScoring.pass_lane_blocked_by_net(origin, receiver_spot):
		return 0.0
	if AIActionScoring.pass_crosses_own_slot(
			origin, receiver_spot, ctx.own_goal_dir * GameRules.GOAL_LINE_Z):
		return 0.0
	if lane < 0.0:
		lane = AIActionScoring.lane_clear(
				origin, receiver_spot, _scratch_opponents_release, pass_speed,
				_scratch_opponent_vels, _scratch_opponent_caps, true)
	if lane <= 0.0:
		return 0.0
	# RELEASE CONTEST — the cough-up loss mode. The pass leaves the blade
	# ~135 ms after the intent commits, with the carried puck swept through
	# the windup; a forechecker whose stick reaches the release point inside
	# that window pokes it off the blade before it ever flies — the same
	# race the shot's pressure factor runs (release_contest_clean). Without
	# it a defender on the carrier's HIP is invisible unless he happens to
	# sit on the lane line, and a swarmed defenseman fires "clean" breakout
	# feeds straight into pokes. Raced from
	# CURRENT opponent spots (the windup starts now); the poke surrenders
	# the puck AT the blade — the most expensive loss point a breakout pass
	# has. This is also what makes a pressured carrier move the puck EARLY:
	# holding while the forechecker closes degrades every pass it is
	# still holding.
	var release_clean: float = AIActionScoring.release_contest_clean(
			AIActionScoring.release_point_toward(self_pos, receiver_spot),
			_scratch_opponents, _scratch_opponent_caps)
	_project_opponents_to(ctx, flight_t, _scratch_opponents_pass)
	# A receiver streaking netward backs the keeper in over the feed's flight,
	# same planning depth model the carrier's own reads use.
	var receiver_closing: float = AIActionScoring.closing_toward(
			receiver_spot, receiver_vel, ctx.attacking_goal_pos)
	var receiver_goalie: Vector3 = _predict_goalie_at(
			ctx, receiver_release_t, receiver_spot, receiver_closing)
	var receiver_unsettled: float = _goalie_unsettled_at(
			ctx, receiver_release_t, receiver_spot, receiver_closing)
	# Score the receiver's shot at ITS real release speed — a hard-shooting
	# teammate one-times harder, beating the goalie more, so it's a better feed.
	var receiver_shot_speed: float = receiver_caps.wrister_shot_speed if receiver_caps != null \
			else AIActionScoring.WRISTER_SHOT_SPEED_M_S
	# The feed's whole edge, measured: the puck relocates the shot origin at
	# ~25 m/s while the keeper re-squares at 3.8. Over the flight plus the
	# receiver's release, how much of the arc-match demand can he actually
	# cover? What he cannot is the seam. This is the same quantity the carry
	# leg reads, and it is why a cross-crease feed and a back pass score so
	# differently without a rule saying so.
	var receiver_displacement: float = AIShotValue.displacement_deficit_m(
			_goalie_now(ctx), ctx.attacking_goal_pos, receiver_spot,
			receiver_release_t)
	var receiver_value: float = _score_at(ctx, receiver_spot, self_pos,
			_scratch_opponents_pass, receiver_goalie,
			receiver_shot_speed, receiver_unsettled, 0.0,
			receiver_displacement)
	# An OPEN receiver isn't limited to a one-timer from where they catch it — they
	# can carry into a better look, exactly like the carrier's own best_carry. In the
	# offensive zone the plain score_at above is shot-ONLY (xG's domain), so a
	# wide-open man in a modest spot (e.g. a 6.6 m dead-slot look the set goalie
	# covers) is under-valued and loses to the carrier's own speculative drive. Credit
	# the best shot the receiver can REACH with a short drive toward the net, gated by
	# an open lane (they must actually be able to get there) and time-discounted — so a
	# wide-open teammate correctly out-scores forcing a carry through a defender.
	# _score_at already prices "drive to slot" via position_potential OUTSIDE the zone,
	# so this only bites in the OZ where that's switched off. (Re-projects
	# _scratch_opponents_pass, now free — the instant value above already consumed it.)
	receiver_value = maxf(receiver_value, _receiver_drive_in_value(
			ctx, receiver_spot, receiver_shot_speed, receiver_caps, receiver_vel))
	var time_decay: float = AIActionScoring.delay_discount(delay_s)
	# Reception pressure — "how pressured is the receiver," from the same
	# reachable-set model the carrier reads on ITSELF (current_safety). A defender
	# draped on the receiver's back is invisible to the two existing loss modes:
	# he is off the passing lane (lane_clear misses him) and off the receiver's
	# forward-to-net cone (the receiver's own shot pressure_factor misses him),
	# yet he strips the catch the instant it arrives. This prices exactly that:
	# the clearance at the reception spot when the puck gets there — defenders'
	# bodies momentum-projected from their RELEASE-TIME spots
	# (_scratch_opponents_release, already advanced by the windup) over the
	# flight, sticks maneuvering over the short reception window (EVADE_HORIZON_S
	# — see reach_clearance). A feed to a blanketed man reads as the giveaway
	# it is, and one to a man a defender is skating onto during the windup no
	# longer reads clear.
	var reception_safety: float = AIActionScoring.clearance_to_safety(
			AIActionScoring.reach_clearance(receiver_spot, flight_t,
					_scratch_opponents_release, _scratch_opponent_vels,
					_scratch_opponent_caps, AIActionScoring.EVADE_HORIZON_S))
	# Four completion loss modes now, mutually exclusive and summing to 1 with
	# the retained case: poked at the release (1 − release_clean), lane
	# interception (release_clean × (1 − lane)), execution miss
	# (release_clean × lane × miss), and a strip on reception (clean lane, no
	# miss, but a stick on the catch).
	var clean_lane: float = lane * (1.0 - miss_prob)   # reaches the tape, in flight
	var completion: float = release_clean * clean_lane * reception_safety
	# CEILING PRUNE (exact). The space toll and every turnover cost below can only
	# LOWER this feed's EV — space multiplies by at most 1.0, costs subtract — so
	# the undiscounted benefit is a hard upper bound. A receiver who cannot beat
	# the best feed found so far even at full marks is decided, and pricing him
	# further is pure hot-path cost. This matters because the space read is the
	# dominant term here and it runs PER TEAMMATE: in 5v5 that is four solves
	# every re-eval to use one. Same exact-bound pattern as
	# _score_move_candidate_base's prune ladder.
	if receiver_value * completion * time_decay <= useless_below:
		return 0.0
	# The receiver pays the SAME forward-pressure toll the carrier's own score
	# does — the other half of the mirror the carry leg documents: his value is
	# what he can do with the puck from HIS spot, so symmetric coverage gives
	# symmetric discount and the pass wins only when the mate is genuinely
	# clearer. Priced at the receiver's OWN velocity and build, exactly as the
	# carrier's side is (see _forward_clearance_at), so a mate curling back reads
	# less space than one in stride through the same ice.
	# Solved once per receiver by _compute_best_pass and shared across its
	# variants; < 0 means "compute it here" (the developing-outlet feed, which
	# prices a single hypothetical spot).
	if receiver_space < 0.0:
		receiver_space = _forward_clearance_at(
				ctx, receiver_spot, receiver_vel, receiver_caps)
	# Published for the caller's per-receiver reuse (see _compute_best_pass).
	_last_receiver_space = receiver_space
	receiver_value *= lerpf(FORWARD_PRESSURE_MIN_SCALE, 1.0, receiver_space)
	# Clean per-action EV: prob(complete) × value(teammate has puck at receiver)
	# minus the turnover cost of each loss mode. The pressure the
	# carrier is under is priced by the CARRY/HOLD alternatives' own strip cost
	# (they lose value under pressure) — the pass wins when it out-EVs them, with
	# no separate "escape" bonus, which would double-count the pressure.
	var benefit: float = receiver_value * completion * time_decay
	# Poked at the release: the puck squirts loose at the blade — the most
	# expensive loss point a breakout pass has.
	var cost: float = AIActionScoring.turnover_cost(
			origin, 1.0 - release_clean, ctx.defending_goal_pos, our_goalie,
			GameRules.NET_HALF_WIDTH, _scratch_our_defenders,
			_scratch_our_defender_caps)
	var loss_point: Vector3 = AIActionScoring.lane_loss_point(
			self_pos, receiver_spot, _scratch_opponents_release, pass_speed,
			_scratch_opponent_vels, _scratch_opponent_caps)
	cost += AIActionScoring.turnover_cost(
			loss_point, release_clean * (1.0 - lane), ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders,
			_scratch_our_defender_caps)
	cost += AIActionScoring.turnover_cost(
			AIActionScoring.pass_miss_loss_point(self_pos, receiver_spot),
			release_clean * lane * miss_prob, ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders,
			_scratch_our_defender_caps)
	# Reception strip: the puck dies AT the receiver, in whatever traffic he was
	# about to catch it in.
	cost += AIActionScoring.turnover_cost(
			receiver_spot, release_clean * clean_lane * (1.0 - reception_safety),
			ctx.defending_goal_pos, our_goalie,
			GameRules.NET_HALF_WIDTH, _scratch_our_defenders,
			_scratch_our_defender_caps)
	# Transition exposure (5v5): each loss mode also prices the COUNTER-RUSH
	# it hands over — the carrier stays at self_pos through a pass, so his
	# own recovery race starts from here (plan §6).
	cost += _counter_exposure_cost(ctx, loss_point, 1.0 - lane,
			self_pos, our_goalie)
	cost += _counter_exposure_cost(ctx, receiver_spot,
			clean_lane * (1.0 - reception_safety), self_pos, our_goalie)
	return benefit - cost


# Transition-exposure cost of losing the puck at `loss_point` with
# probability `loss_prob`, while this carrier would be recovering from
# `recover_from` — the additive counter-rush half of the turnover price
# (AIActionScoring.counter_rush_cost; design in plan §6). 5v5-gated: 3v3
# pays zero, protecting its shipped tuning. The per-position appetite is
# the hand-set feel scalar (see EXPOSURE_APPETITE_*).
func _counter_exposure_cost(ctx: RoleContext, loss_point: Vector3,
		loss_prob: float, recover_from: Vector3, our_goalie: Vector3) -> float:
	# Probability floor: a candidate that barely risks the puck (open-ice
	# carries, clean lanes) prices its counter at ~0 anyway — skip the
	# score_shoot. Same spirit as PASS_MISS_BASE_PROB's magnitude.
	if ctx.team_size < 5 or loss_prob <= EXPOSURE_PROB_FLOOR:
		return 0.0
	var appetite: float = EXPOSURE_APPETITE_DEFENSE if ctx.self_is_defense \
			else EXPOSURE_APPETITE_FORWARD
	return appetite * AIActionScoring.counter_rush_cost(
			loss_point, loss_prob, ctx.defending_goal_pos, our_goalie,
			GameRules.NET_HALF_WIDTH, _scratch_our_defenders,
			recover_from, ctx.self_max_speed,
			_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps,
			_scratch_exposure_mate_etas, _scratch_exposure_threat_memo,
			_scratch_opponent_stamina)


# Rotation time: how long the bot needs to rotate facing to point at
# `target` before the blade can fire there. The blade reaches anywhere inside
# the reach cone (`cone_half_angle` = ROM + torso twist, ~157° — the exact IK
# gate the pose coordinator enforces), so a shot/pass to ANY in-cone target
# fires from the current facing with NO body turn (rotation_time = 0). Only aims
# in the narrow back wedge past the cone pay, and then only for the OVERSHOOT
# (angle minus cone), rotated at this bot's real Agility-scaled turn rate.
func _facing_rotation_time(self_facing_xz: Vector2, self_pos: Vector3,
		target: Vector3, cone_half_angle: float, turn_rate: float) -> float:
	var to_target_x: float = target.x - self_pos.x
	var to_target_z: float = target.z - self_pos.z
	var to_target_len: float = sqrt(
			to_target_x * to_target_x + to_target_z * to_target_z)
	if to_target_len <= 0.001:
		return 0.0
	var inv_len: float = 1.0 / to_target_len
	var cos_angle: float = clampf(
			self_facing_xz.x * to_target_x * inv_len
			+ self_facing_xz.y * to_target_z * inv_len, -1.0, 1.0)
	var angular_distance: float = acos(cos_angle)
	var overshoot: float = maxf(0.0, angular_distance - cone_half_angle)
	return overshoot / maxf(turn_rate, 0.001)


# Is a carry candidate on ice this bot can legally stand and handle on?
#
# The front-of-net rule is the plain clamp: rink side of both goal lines, a body's
# width off the boards. The interesting case is `allow_behind`.
#
# Without it a carrier BEHIND a net has almost no representable move set: every
# local candidate back there fails the goal-line clamp, and the ones aimed out
# front prune on carry_path_blocked_by_net, leaving only the two post walkouts,
# the zone exits and stand-still. Under real pressure both walkouts read unsafe,
# so the compete falls through to stand-still — the bot plants itself on the end
# wall with the puck and gets stripped, and every attempt to work out of there has
# to be a single all-or-nothing walkout. That is the "bots get stuck behind the
# net and turn it over" failure, and it is a missing REPRESENTATION rather than a
# bad evaluation. There is no move in the search for the ones a real player
# makes back there — reverse off the wall, slide across the back of the cage,
# hold at the far post and wait for a lane.
#
# So a carrier already behind a goal line keeps its local candidates in that
# ice, subject only to what is genuinely illegal there: off the playing surface
# (the end boards, corners included), and inside the cage itself. The route to
# each candidate is still checked against the net by _score_move_candidate_base,
# so a step that would drag the puck through the mesh still prunes — the bot
# gains the lateral walk it was missing, not a licence to skate through the net.
func _candidate_ice_legal(candidate: Vector3, allow_behind: bool) -> bool:
	if absf(candidate.x) > GameRules.RINK_HALF_WIDTH - AIRoleHelpers.RINK_INSET_M:
		return false
	if absf(candidate.z) <= GameRules.GOAL_LINE_Z - AIRoleHelpers.GOAL_LINE_BUFFER_M:
		return true
	if not allow_behind:
		return false
	# On the surface (rounded corners honoured) with a body's clearance.
	var xz := Vector2(candidate.x, candidate.z)
	if not GameRules.clamp_to_rink_inner(xz, AIRoleHelpers.RINK_INSET_M) \
			.is_equal_approx(xz):
		return false
	# Outside the cage (the same exclusion box the skater body is held clear of).
	return GameRules.push_out_of_net(xz).is_equal_approx(xz)


# Returns [best_score, best_pos] across all carry candidates:
#   - Stand-still (current position, encodes patience)
#   - Up to 6 field-derived FORWARD candidates: the space fan's best bearings
#     at two fractions of the planning beat (see CARRY_FIELD_*)
#   - Up to 10 REAR/LATERAL candidates: the five bearings the fan does not
#     span, each at two fractions of that bearing's OWN beat reach, so an
#     unavailable direction produces none (see _REAR_ANGLES)
#   - The OZ slot anchor (long-range "drive at slot")
#   - Two zone-exit wall routes when in our own half (see CARRY_EXIT_*)
#   - Two post walkouts when behind either goal line (see WALKOUT_*)
#   - The objective-directed evasion seam
#
# Each movement candidate scored uniformly and in TWO PASSES (see
# CARRY_BEAM_WIDTH): every candidate gets the one-ply base score
# (_score_move_candidate_base), then only the beam's best rows pay for the
# two-ply reads (_upgrade_candidate_two_ply). Time uses momentum-aware
# effective speed (backward candidates self-discount via longer arrival),
# and a candidate whose straight route crosses a net frame prunes (the
# walkouts are the exempt, around-the-post routes).
#
# `shoot_now_score` is the top-level SHOOT eval (pre-ping, pre-hysteresis):
# stand-still's shot branch shares it verbatim — see the stand-still block.
func _best_carry(ctx: RoleContext, shoot_now_score: float,
		directed_seam: Vector3) -> Array:
	var self_pos: Vector3 = ctx.self_pos
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	var own_goal_dir: float = ctx.own_goal_dir
	# Our goalie feeds the turnover-cost term (how much a strip helps the
	# opponent, dampened by our net coverage). Resolved once for all
	# carry candidates. _scratch_our_defenders is already built by
	# _build_action_opponents_lists earlier in _pick_action.
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var slot_pos: Vector3 = _slot_anchor(own_goal_dir)
	# Polar forward direction: toward slot. Fallback to attacking-goal
	# axis when degenerate (bot exactly at slot).
	var to_slot_x: float = slot_pos.x - self_pos.x
	var to_slot_z: float = slot_pos.z - self_pos.z
	var to_slot_len_sq: float = to_slot_x * to_slot_x + to_slot_z * to_slot_z
	var fwd_x: float
	var fwd_z: float
	if to_slot_len_sq < 0.001:
		fwd_x = 0.0
		fwd_z = -own_goal_dir
	else:
		var inv: float = 1.0 / sqrt(to_slot_len_sq)
		fwd_x = to_slot_x * inv
		fwd_z = to_slot_z * inv

	# Movement candidates are scored first; stand-still is compared last and
	# only wins if STRICTLY greater than the best of them. By construction
	# stand-still ties with the
	# best fire option from the same instant (its shot branch IS the
	# shoot-now score, and outside the zone its potential branch prices
	# holding ground) — so stand-still ties with fire whenever the shot
	# is the hold's whole value. Resolving carry ties toward
	# movement keeps the bot from dawdling when slot-drive is the play.
	var best_pos: Vector3 = self_pos
	var best_score: float = -INF

	# Stand-still is COMPUTED up front (its comparison stays last — see the
	# tail comment for the strictly-greater tie rule) because it doubles as
	# an exact pruning floor: stand always participates in this argmax, so
	# every movement candidate whose ceiling can't strictly beat stand_total
	# can't affect the outcome — it seeds the beam's pass-1 prune bound and
	# the pass-2 incumbent bound from the very first candidate.
	var stand_score: float = shoot_now_score
	if not AIActionScoring.in_offensive_zone(self_pos, attacking_goal):
		var stand_potential: float = AIActionScoring.position_potential(
				self_pos, attacking_goal, _scratch_opponents)
		var stand_realization: float = AIActionScoring.potential_realization_discount(
				self_pos, attacking_goal)
		stand_score = maxf(stand_score, stand_potential * stand_realization)
	var stand_puck_pos: Vector3 = _puck_pos_at(self_pos, attacking_goal)
	var stand_safety: float = AIActionScoring.carry_safety(
			stand_puck_pos, stand_puck_pos, AIActionScoring.EVADE_HORIZON_S,
			_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps)
	var stand_cost: float = AIActionScoring.turnover_cost(
			stand_puck_pos, 1.0 - stand_safety, ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders,
			_scratch_our_defender_caps)
	stand_cost += _counter_exposure_cost(ctx, stand_puck_pos,
			1.0 - stand_safety, self_pos, our_goalie)
	var stand_total: float = stand_score * stand_safety - stand_cost

	# ── Pass 1 (beam base): one-ply rows for every legal candidate ───────────
	# Candidates stay ordered forward-first: the prune bound tightens to the
	# best one-ply total as rows land (exact — see _beam_prune_bound), so a
	# strong early spot still prunes the tail's ceiling ladder cheaply.
	_beam_pos.clear()
	_beam_total.clear()
	_beam_dest.clear()
	_beam_lane.clear()
	_beam_decay.clear()
	_beam_safety.clear()
	_beam_cost.clear()
	_beam_time.clear()
	_beam_prune_bound = stand_total

	# Behind-the-net ice is playable ice for a carrier ALREADY back there — see
	# _candidate_ice_legal. Resolved once; every candidate ring below shares it.
	var behind_net: bool = absf(self_pos.z) > GameRules.GOAL_LINE_Z

	# FORWARD candidates — generated from the space field's per-bearing profile
	# (_scratch_bearing_control, filled by the forward-space read in
	# _pick_commit_phase), not from a fixed ring of spokes. Fixed spokes spend
	# most of their samples on directions the field already knows are walled, and
	# none on the seam between two of them.
	#
	# The radius is one PLANNING BEAT of travel at the carrier's real speed. A
	# fixed radius is a steering question dressed as a plan: at 3 m a bot moving
	# 9 m/s chooses between spots 0.33 s away while re-deciding every 33 ms, and
	# nothing samples the range where a zone entry is actually decided. Beat
	# scaling reduces to a 3 m step at a standstill and reaches the blue line at
	# a full stride.
	#
	# The profile is ranked by control × forward projection — control alone would
	# rate a wide-open sideways bearing above a merely-good netward one, and the
	# cos is the same foreshortening the space aggregate itself weights by. Top
	# CARRY_FIELD_BEARINGS bearings are taken, each at the full beat and at half
	# it, so the near gradient a standstill carrier needs survives at speed.
	var beat_r: float = clampf(
			ctx.self_max_speed * CARRY_PLAN_BEAT_S,
			CARRY_SEARCH_STEP_M, FORWARD_PRESSURE_HORIZON_M)
	if ctx.self_velocity.length_squared() > 1.0:
		beat_r = clampf(
				sqrt(ctx.self_velocity.x * ctx.self_velocity.x
						+ ctx.self_velocity.z * ctx.self_velocity.z) * CARRY_PLAN_BEAT_S,
				CARRY_SEARCH_STEP_M, FORWARD_PRESSURE_HORIZON_M)
	for _rank: int in CARRY_FIELD_BEARINGS:
		var best_bi: int = -1
		var best_w: float = -1.0
		for bi: int in _scratch_bearing_control.size():
			var ang: float = AIActionScoring.SPACE_SAMPLE_ANGLES[bi]
			var wgt: float = _scratch_bearing_control[bi] * cos(ang)
			if wgt > best_w:
				best_w = wgt
				best_bi = bi
		if best_bi < 0:
			break
		var angle: float = AIActionScoring.SPACE_SAMPLE_ANGLES[best_bi]
		# Consume it so the next rank picks a different bearing.
		_scratch_bearing_control[best_bi] = -1.0
		var c: float = cos(angle)
		var s_a: float = sin(angle)
		var dir_x: float = fwd_x * c - fwd_z * s_a
		var dir_z: float = fwd_x * s_a + fwd_z * c
		for frac: float in CARRY_FIELD_RADII:
			var r: float = maxf(beat_r * frac, CARRY_SEARCH_STEP_M * 0.5)
			var candidate := Vector3(
					self_pos.x + dir_x * r, 0.0, self_pos.z + dir_z * r)
			if not _candidate_ice_legal(candidate, behind_net):
				continue
			_beam_score_base(ctx, candidate, our_goalie, false)

	# REAR/LATERAL ring — the bearings the forward fan does not span, at two
	# fractions of each bearing's OWN beat reach (see _REAR_ANGLES). This is the
	# merged local-plus-retreat arc: one pass over five angles.
	#
	# The radius is per BEARING, not the shared forward beat_r. beat_r is how
	# far this carrier travels forward in a beat, so reusing it back here would
	# grow the rear radii with speed — precisely backwards. Travelling forward
	# at pace, a spot behind you is not somewhere you can go: reaching it means
	# shedding cross-speed, braking out the reversal and re-accelerating. Fixed
	# radii ignore that entirely and offer the same five spots at 9 m/s as at a
	# standstill, paying full candidate cost for every one.
	#
	# beat_reach_along returns negative when the bearing is off the reachable
	# disc altogether, so an unavailable direction simply produces no candidate
	# — the filtering is geometry rather than a gate bolted on afterwards, and
	# what the ring offers narrows and stretches with the carrier's real state.
	for angle: float in _REAR_ANGLES:
		var c: float = cos(angle)
		var s_a: float = sin(angle)
		var dir_x: float = fwd_x * c - fwd_z * s_a
		var dir_z: float = fwd_x * s_a + fwd_z * c
		var reach: float = AIActionScoring.beat_reach_along(
				ctx.self_velocity, dir_x, dir_z, ctx.self_max_accel,
				CARRY_PLAN_BEAT_S)
		if reach < CARRY_REAR_MIN_STEP_M:
			continue
		for frac: float in CARRY_FIELD_RADII:
			var step: float = reach * frac
			if step < CARRY_REAR_MIN_STEP_M:
				continue
			var candidate := Vector3(
					self_pos.x + dir_x * step, 0.0, self_pos.z + dir_z * step)
			if not _candidate_ice_legal(candidate, behind_net):
				continue
			_beam_score_base(ctx, candidate, our_goalie, false)

	# Slot anchor — long-range candidate, valid from anywhere on the
	# rink. NZ bots reach the slot via this; OZ bots near the slot
	# already cover it via local polar candidates.
	_beam_score_base(ctx, slot_pos, our_goalie, false)

	# Zone-exit wall routes — see CARRY_EXIT_* doc. Only generated in our own
	# DEFENSIVE ZONE: an exit route is meaningless once the puck is out, and
	# out there the slot anchor + local candidates already cover the up-ice
	# gradient.
	#
	# Gating on own HALF instead would include the near half of the neutral zone,
	# where the route is not merely redundant but backwards: the exit target sits
	# just inside the blue line, so a carrier already past that line is offered a
	# spot BEHIND itself. Over the benchmark scenarios every one of this ring's
	# argmax wins came from inside the defensive zone (10 DZ / 0 NZ / 0 OZ).
	if own_goal_dir * self_pos.z > GameRules.BLUE_LINE_Z:
		var exit_x: float = GameRules.RINK_HALF_WIDTH - CARRY_EXIT_WALL_INSET_M
		var exit_z: float = own_goal_dir * (GameRules.BLUE_LINE_Z - CARRY_EXIT_NZ_LEAD_M)
		_beam_score_base(ctx, Vector3(exit_x, 0.0, exit_z), our_goalie, false)
		_beam_score_base(ctx, Vector3(-exit_x, 0.0, exit_z), our_goalie, false)

	# Post walkouts — see WALKOUT_* doc: the only representable carries out
	# from behind a goal line (everything else's straight route crosses the
	# cage and prunes). One candidate outside each post; EV picks the side.
	if absf(self_pos.z) > GameRules.GOAL_LINE_Z:
		var behind_sign: float = signf(self_pos.z)
		var walk_z: float = behind_sign * (GameRules.GOAL_LINE_Z - WALKOUT_FRONT_M)
		var walk_x: float = GameRules.NET_HALF_WIDTH + WALKOUT_POST_CLEARANCE_M
		for side: float in [-1.0, 1.0]:
			_beam_score_base(
					ctx, Vector3(side * walk_x, 0.0, walk_z), our_goalie, true)

	# Evasion seam — the reachable-set escape, in its objective-DIRECTED form
	# (best_evade_point_toward, computed once per re-eval in _pick_action): the
	# safe spot in our handling envelope with the most progress toward the carry
	# objective. Adding it as a carry candidate is what turns the safety model
	# into PLAYMAKING — the bot cuts past a committed defender into the lane he
	# vacates instead of only surviving pressure. Scored like any candidate, so
	# it only wins when the space it opens is actually worth carrying to.
	_beam_score_base(ctx, directed_seam, our_goalie, false)

	# ── Pass 2: complete the two-ply reads for the beam's best rows ──────────
	# Best-first, consuming each row as it upgrades, under the same running
	# incumbent bound the inline compete used (stand's secured value, then the
	# best upgraded total — which after the first upgrade already dominates
	# every remaining one-ply row). Rows outside the beam keep their one-ply
	# totals and can never win (see the CARRY_BEAM_WIDTH doc).
	for rank: int in CARRY_BEAM_WIDTH:
		var bi: int = -1
		var bt: float = -INF
		for j: int in _beam_total.size():
			if _beam_total[j] > bt:
				bt = _beam_total[j]
				bi = j
		if bi == -1:
			break
		var up_total: float = _upgrade_candidate_two_ply(ctx, bi)
		if up_total > best_score:
			best_score = up_total
			best_pos = _beam_pos[bi]
		_beam_total[bi] = -INF   # consumed — next rank takes the next-best row

	# WHEEL exits (5v5, own end only — see WHEEL_* doc): the far half-wall
	# via the behind-net apex. Only priced for destinations whose straight
	# route the cage blocks — a side the straight line reaches is already
	# covered by the normal candidates above. Already a complete two-leg
	# read, so it competes after the beam, against the post-beam bound.
	if absf(self_pos.z) > GameRules.GOAL_LINE_Z \
			and ctx.team_size >= 5 and own_goal_dir * self_pos.z > 0.0:
		var wheel_x: float = GameRules.RINK_HALF_WIDTH - CARRY_EXIT_WALL_INSET_M
		var wheel_z: float = own_goal_dir \
				* (GameRules.GOAL_LINE_Z - WHEEL_EXIT_UP_ICE_M)
		for side: float in [-1.0, 1.0]:
			var wheel := Vector3(side * wheel_x, 0.0, wheel_z)
			if not AIActionScoring.carry_path_blocked_by_net(self_pos, wheel):
				continue
			var wheel_total: float = _score_wheel_candidate(
					ctx, wheel, our_goalie, maxf(best_score, stand_total))
			if wheel_total > best_score:
				best_score = wheel_total
				best_pos = wheel

	# Stand-still last. Only wins on STRICTLY greater than the best
	# movement candidate — patience must be earned. Its SHOT branch is the
	# top-level shoot-now score, shared verbatim: "hold and fire from here"
	# and SHOOT are the same physical act (the wind-up runs either way, and
	# momentum carries the release downstream over it). Pricing stand's shot
	# separately at the CURRENT spot lets a mid-cut hold read richer than the
	# fire from the same instant — the projected release sits past the cut's
	# apex while "here" still reads pre-apex — so the bot holds at exactly the
	# moment the window is open. Sharing the number makes the compete's
	# fire-wins-ties construction hold by definition: stand_total =
	# shoot_now × safety − cost ≤ shoot_now ≤ fire. Outside the zone the hold
	# also prices its position potential, realization-discounted like every
	# other candidate. Same EV shape as the movement candidates: poke-safety
	# discounts the benefit AND its complement is the strip probability
	# feeding turnover_cost. Without the cost term stand-still is the only
	# candidate that does not price losing the puck, so under a converging
	# forechecker every escape route goes EV-negative while freezing stays
	# positive and the bot plants itself at exactly the moment it should skate
	# clear. Safety is the static reachable-clearance read (a closing
	# defender still registers from its momentum over the reaction window).
	if stand_total > best_score:
		best_score = stand_total
		best_pos = self_pos

	# [floored, best_pos, RAW]. Floored is the "keep the puck" floor for the fire
	# compete; raw keeps the honest sign for the dump's expected-keep (a pinned
	# carry that will be stripped must read negative, not clamped to 0).
	return [maxf(best_score, 0.0), best_pos, best_score]


# Two clears priced within this of each other are the same clear as far as the
# compete is concerned, so depth breaks the tie (see _best_dump). Sized well
# under the shot-threat scale everything here is denominated in — a real
# difference in what we are handing over is worth far more than this.
const CLEAR_PRICE_TIE_BAND: float = 0.001


# What handing the puck over at `spot` costs us: the immediate threat there, plus
# the counter-rush the loss opens (5v5). Returns (concede, recovery) packed into
# a Vector2 — a value type, so pricing a whole candidate set allocates nothing.
#
# The clear's search ranks its candidates with this and _best_dump reports the
# winner with it, so the delivery that is chosen is the delivery the compete is
# told about — one number, one currency (see
# AIActionScoring.dump_clear_candidates).
func _dump_concession(ctx: RoleContext, spot: Vector3, our_goalie: Vector3,
		defending_goal: Vector3, known_recovery: float = -1.0) -> Vector2:
	var recovery: float = known_recovery
	if recovery < 0.0:
		recovery = AIActionScoring.chase_recovery(
				spot, _scratch_our_chasers, _scratch_opponents,
				_scratch_our_chaser_vels, _scratch_opponent_vels)
	var loss: float = 1.0 - recovery
	var concede: float = AIActionScoring.turnover_cost(
			spot, loss, defending_goal, our_goalie,
			GameRules.NET_HALF_WIDTH, _scratch_our_defenders,
			_scratch_our_defender_caps)
	concede += _counter_exposure_cost(ctx, spot, loss, ctx.self_pos, our_goalie)
	return Vector2(concede, recovery)


# Last-resort DUMP, zone-gated. Returns
# [dump_value, aim_point, is_soft, is_rim, settle_point, launch_speed]; -INF
# when no dump applies here (own-side neutral zone, or already in the OZ).
#
# The aim point and the settle point are DIFFERENT and both are returned: the
# aim is where the stick points (a standoff down the launch line), the settle is
# where the puck ends up, and every EV term below is priced at the settle. One
# number cannot do both jobs — a dump at any pace the bot can produce out-slides
# the rink several times over, so the aim is a place the puck passes through at
# speed, and pricing the giveaway there understates it wherever the aim is far
# from our net (a clear cheap enough to beat carries that had real space).
#
# Both dumps are therefore chosen by SEARCHING RELEASES (AIActionScoring's
# dump_clear_candidates / solve_dump_in) and pricing where the puck comes to
# rest. A launch angled into the near boards IS the rim, and the landing solver
# walks the real carom, so there is no separate two-leg rim pricing.
#
# The two dumps are different errands and are priced as such:
#   DZ CLEAR — every launch that neither ices nor dies in our own zone is a legal
#     candidate, and the one we concede LEAST by is the clear. Still a pure
#     concession: no gain term, so its value cannot exceed zero.
#   NZ DUMP-IN — an offensive play. Get it deep, win it back, forecheck. Its
#     gain is the race, and it cannot be icing by construction (offered only
#     past the red line; icing needs a release from our own half).
func _best_dump(ctx: RoleContext, our_goalie: Vector3) -> Array:
	var self_pos: Vector3 = ctx.self_pos
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	var defending_goal: Vector3 = ctx.defending_goal_pos
	var in_own_zone: bool = AIActionScoring.in_offensive_zone(self_pos, defending_goal)
	var past_center: bool = AIActionScoring.past_center_toward_attack(
			self_pos, attacking_goal)
	if not in_own_zone and not (past_center
			and not AIActionScoring.in_offensive_zone(self_pos, attacking_goal)):
		return [-INF, Vector3.INF, false, false, Vector3.INF, 0.0]

	var origin: Vector3 = _pass_origin(ctx)
	# Our chasers = teammates + ourselves; theirs = the opponents already gathered.
	_scratch_our_chasers.clear()
	_scratch_our_chaser_vels.clear()
	for i: int in _scratch_our_defenders.size():
		_scratch_our_chasers.append(_scratch_our_defenders[i])
		_scratch_our_chaser_vels.append(_scratch_our_defender_vels[i])
	_scratch_our_chasers.append(self_pos)
	_scratch_our_chaser_vels.append(ctx.self_velocity)

	var launch: Vector3
	var settle: Vector3
	var is_soft: bool
	# (concede, recovery) for the delivery finally chosen — filled by the clear's
	# own ranking below, or computed once for the dump-in.
	var priced := Vector2.ZERO
	if in_own_zone:
		# HIGH is doctrine here rather than a searched axis: the clear's job is to
		# leave the zone, and the loft is what carries it over the sticks between
		# us and the blue line. It buys no time (an airborne leg spends no
		# friction) — it buys passage.
		is_soft = false
		var n: int = AIActionScoring.dump_clear_candidates(
				origin, -ctx.own_goal_dir, AIActionScoring.PASS_SPEED_M_S,
				ShotMechanics.ELEVATION_HIGH, defending_goal,
				_scratch_clear_vels, _scratch_clear_spots)
		if n == 0:
			# Every launch either ices or dies in our own zone: there is no legal
			# clear from here. Decline rather than fire one — the carry/pass
			# compete is a better place to lose the puck than a whistle in our own
			# end, or a "clear" that never left it.
			return [-INF, Vector3.INF, false, false, Vector3.INF, 0.0]
		# Rank the legal launches by what conceding at each actually costs — the
		# same number this function is about to report to the compete. Depth
		# survives only as the tie-break, which is the job it can still do
		# honestly: when two clears cost the same (both uncontested, both free),
		# take the one that leaves the puck nearer neutral ice rather than the one
		# whose bearing happens to come first.
		#
		# The RACE runs first and alone decides it whenever anyone wins one
		# outright. Every term in the concession carries the loss probability as a
		# factor (turnover_cost and counter_rush_cost both scale by it), so a
		# candidate we are certain to recover concedes exactly ZERO — the most any
		# clear can score, since there is no gain term to lift one above it. So
		# once a free clear exists, nothing dearer can win and none of the threat
		# surfaces below need computing at all. An EXACT prune, not a search
		# budget: it discards only candidates that provably cannot win.
		_scratch_clear_recovery.resize(n)
		var free_exists: bool = false
		for i: int in n:
			var rec: float = AIActionScoring.chase_recovery(
					_scratch_clear_spots[i], _scratch_our_chasers, _scratch_opponents,
					_scratch_our_chaser_vels, _scratch_opponent_vels)
			_scratch_clear_recovery[i] = rec
			free_exists = free_exists or rec >= 1.0
		var target_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
		var best_price: float = -INF
		var best_miss: float = INF
		for i: int in n:
			var rec: float = _scratch_clear_recovery[i]
			if free_exists and rec < 1.0:
				continue
			var spot: Vector3 = _scratch_clear_spots[i]
			var spot_priced := Vector2(0.0, rec)
			if rec < 1.0:
				spot_priced = _dump_concession(ctx, spot, our_goalie, defending_goal, rec)
			var price: float = -spot_priced.x
			var miss: float = absf(spot.z - target_z)
			if price <= best_price - CLEAR_PRICE_TIE_BAND:
				continue
			if price < best_price + CLEAR_PRICE_TIE_BAND and miss >= best_miss:
				continue
			best_price = maxf(price, best_price)
			best_miss = miss
			launch = _scratch_clear_vels[i]
			settle = spot
			priced = spot_priced
	else:
		is_soft = true
		_scratch_dump_landing[0] = origin
		# The pace ladder runs over the dumper's OWN release band, and the
		# winning pace is carried out to the release (dump_launch_speed) — a
		# dump-in placed by a searched pace is only a placed dump if the puck
		# actually leaves at that pace.
		launch = AIActionScoring.solve_dump_in(
				origin, attacking_goal, ctx.self_wrister_shot_speed,
				ShotMechanics.ELEVATION_FLAT,
				_scratch_our_chasers, _scratch_opponents, _goalie_now(ctx),
				_scratch_dump_landing, _scratch_our_chaser_vels,
				_scratch_opponent_vels)
		if launch == Vector3.ZERO:
			return [-INF, Vector3.INF, false, false, Vector3.INF, 0.0]
		settle = _scratch_dump_landing[0]
		priced = _dump_concession(ctx, settle, our_goalie, defending_goal)

	# Everything below prices the RESTING spot.
	var recovery: float = priced.y
	var concede: float = priced.x
	# Only the DUMP-IN earns a gain. It is an offensive errand — get it deep, win
	# it back — so it is paid for the race it is trying to win.
	#
	# The CLEAR is left as a pure concession, and the recovery race reaches its
	# value through `concede` instead: a winger posted where the puck comes to
	# rest raises recovery, which lowers what we hand over. Paying the clear a
	# gain term as well breaks the compete: it makes a clear score positive
	# outright, so it beats CARRYING wherever a clean regroup exists — the
	# dump-with-space failure in reverse. What a recovered clear is worth in the
	# carry's own currency is a live calibration question, not something to
	# settle with a term that happens to balance.
	var gain: float = 0.0
	if is_soft:
		# MOMENTUM-HONEST chase clock, the same one every other arrival in the
		# model uses. Never price it as `nearest_distance / max_speed`: that is an
		# instant full-speed sprint from a standstill, worth about a second over a
		# routine 11 m chase, and worth it in exactly one direction — the dump
		# reaches the puck at a pace no skater can produce while the carry it
		# competes with pays time_to_arrive's real ramp, so flinging it ahead
		# beats skating it in over the SAME ground. Nearest by ETA, not by metres:
		# the man already moving that way is the chaser even when someone
		# flat-footed stands closer.
		var chase_t: float = AIActionScoring.time_to_arrive(
				self_pos, settle, ctx.self_velocity, ctx.self_max_speed,
				ctx.self_max_accel, ctx.self_lateral_grip)
		for i: int in _scratch_our_defenders.size():
			var mate_caps: AISkaterCaps = _scratch_our_defender_caps[i]
			chase_t = minf(chase_t, AIActionScoring.time_to_arrive(
					_scratch_our_defenders[i], settle, _scratch_our_defender_vels[i],
					mate_caps.max_speed if mate_caps != null else ctx.self_max_speed,
					mate_caps.max_accel if mate_caps != null else ctx.self_max_accel))
		var chase_decay: float = AIActionScoring.delay_discount(chase_t)
		# The settle spot's potential is FUTURE value — recovering the puck deep
		# is not a shot, it is a spot the winner still has to skate in from — so
		# it pays the same realization discount every other future-value read in
		# the model pays (see potential_realization_discount). Skipping it here is
		# what makes a dump trigger-happy: a carry candidate's potential arrives
		# already discounted over the travel that cashes it, so an UNdiscounted
		# deep settle spot competes against discounted neutral-zone ones — a deep
		# spot's raw value against a near spot's realized value. With the
		# term in, the two legs telescope on both sides (chase decay x settle
		# realization = travel decay x candidate realization = the same
		# realization from HERE), and the compete reduces to what it should
		# always have been: recovery x potential(settle) against
		# safety x lane x potential(candidate). Dump when the entry is
		# genuinely contested; carry when it is not.
		gain = recovery * AIActionScoring.position_potential(
				settle, attacking_goal, _scratch_opponents) * chase_decay \
				* AIActionScoring.potential_realization_discount(
						settle, attacking_goal)

	# The aim handed to the release is a point far down the chosen launch line,
	# NOT the resting spot: the quick release takes its direction blade->cursor,
	# and a cursor near the body has no direction in it (see the snap in
	# SkaterAgentStateMachine._state_pass_pressed).
	var aim: Vector3 = origin + launch.normalized() * DUMP_AIM_STANDOFF_M
	return [gain - concede, aim, is_soft, false, settle, launch.length()]


# Pass-1 candidate entry (see CARRY_BEAM_WIDTH): base-score `candidate` into
# the beam rows and tighten the running prune bound to the best one-ply
# total so far (see _beam_prune_bound for why that stays exact).
func _beam_score_base(ctx: RoleContext, candidate: Vector3,
		our_goalie: Vector3, is_post_walkout: bool) -> void:
	var total: float = _score_move_candidate_base(
			ctx, candidate, our_goalie, is_post_walkout, _beam_prune_bound)
	if total > _beam_prune_bound:
		_beam_prune_bound = total


# EV of one movement carry candidate — the uniform scoring every
# non-stand-still candidate (field bearing, rear step, slot anchor, wall exit,
# post walkout, evasion seam) runs:
#
#   benefit − turnover_cost, where
#   benefit = score_at(candidate, projected_opps) × path_clear
#             × time_decay × safety
#
# Time uses momentum-aware effective speed, so reverse candidates
# self-discount via longer arrival. Returns -INF when the path is
# fully blocked (candidate unusable).
#
# `safety` is the reachable carry_clearance over the PUCK's path from our current
# spot to the candidate spot across the arrival time: the tightest point where a
# defender's momentum-reach could get a stick to it, capturing both a defender
# converging on the ROUTE and one waiting at the DESTINATION. A committed charger
# whose momentum carries him past reads as clear; a stick on the line does not.
#
# Expected-value shape: benefit (offensive upside) minus the turnover cost.
# keep_prob = safety is the possession-protection probability; (1 - keep_prob)
# is the strip probability, so the loss-probability lives in exactly one place
# (no double-count with the benefit, whose safety multiplier is the "value of
# arriving with the puck" discount). Loss point = the EARLIEST covered point on the
# route (carry_strip_point) — where the strip actually happens — NOT the
# destination: a carry that ends in open ice but threads our own slot must pay the
# slot's turnover cost. Cost self-localizes: ~0 driving into the OZ, large when the
# route drags the puck through our own slot.
#
# ONE-PLY pass of the beam (see CARRY_BEAM_WIDTH): everything above except the
# two-ply reads, which _upgrade_candidate_two_ply adds for the beam's winners.
# Every finite score also appends a beam row stashing the intermediates the
# upgrade needs, so pass 2 recomputes nothing.
func _score_move_candidate_base(ctx: RoleContext, candidate: Vector3,
		our_goalie: Vector3, is_post_walkout: bool = false,
		best_so_far: float = -INF) -> float:
	var self_pos: Vector3 = ctx.self_pos
	# One-way valve: once the puck is in the offensive zone, don't carry it back
	# out. Establishing the zone is worth keeping — a carry that surrenders it (a
	# retreat past the blue line) is pruned so it can never win. Buffered by
	# OZ_RETREAT_LINE_BUFFER_M: a candidate ON the line is as good as out,
	# because the pass windup sweeps the carried puck a stick's reach behind
	# the body — retreating to the line and then passing dragged the puck
	# across it mid-windup (a zone exit that landed the whole team offside on
	# the pass). Stand-still (self, in-zone) never trips this, so the candidate
	# set is never empty; a carrier already inside the band only keeps deeper
	# candidates, easing it off the line. Mirrors the receiver-side exclusion
	# in _compute_best_pass (OZ_RECEIVE_LINE_BUFFER_M).
	if AIActionScoring.in_offensive_zone(self_pos, ctx.attacking_goal_pos) \
			and not AIActionScoring.in_offensive_zone(
					candidate, ctx.attacking_goal_pos, OZ_RETREAT_LINE_BUFFER_M):
		return -INF
	# The cage is a wall: a candidate whose straight route runs through either
	# net frame is unreachable as priced (the time/lane/safety math below all
	# assume the straight traverse). The designated POST-WALKOUT candidates are
	# exempt — they're constructed to be reached around the post (the steering
	# net-detour walks the corner), which the straight-segment test can't see.
	if not is_post_walkout \
			and AIActionScoring.carry_path_blocked_by_net(self_pos, candidate):
		return -INF
	var local_time: float = AIActionScoring.time_to_arrive(
			self_pos, candidate, ctx.self_velocity, ctx.self_max_speed,
			ctx.self_max_accel, ctx.self_lateral_grip)
	# CEILING PRUNES (exact): the candidate's score is dest_score × lane ×
	# decay × safety − cost, with dest_score ≤ 1, cost ≥ 0 — so each partial
	# product of the ≤-1 factors is a hard upper bound, checked in cost
	# order: decay alone (free) before the opponent projection, lane × decay
	# before the safety read, lane × decay × safety before the arrival-shot /
	# strip machinery. Candidates are ordered forward-first,
	# so a strong early spot prunes the tail; under pressure SAFETY is the
	# killer, and pruning on it before the goalie block is what keeps a
	# swarmed carrier's compete from paying full price for doomed spots.
	var decay: float = AIActionScoring.delay_discount(local_time)
	if decay <= best_so_far:
		return -INF
	_project_opponents_to(ctx, local_time, _scratch_opponents_path)
	var lane: float = AIActionScoring.carry_lane_clearance(
			self_pos, candidate, local_time, _scratch_opponents, _scratch_opponent_vels,
			ctx.self_max_speed)
	if lane <= 0.0:
		return -INF
	if lane * decay <= best_so_far:
		return -INF
	var cand_puck_pos: Vector3 = _puck_pos_at(candidate, ctx.attacking_goal_pos)
	var cur_puck_pos: Vector3 = _puck_pos_at(self_pos, ctx.attacking_goal_pos)
	# apply_escape: a defender the carrier out-skates on this drive is being beaten
	# and can't sustain the strip — so driving PAST a man reads as winnable, not as a
	# wall (the "if I keep going I've beaten him" read).
	var safety: float = AIActionScoring.carry_safety(
			cur_puck_pos, cand_puck_pos, local_time,
			_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps,
			true)
	if lane * decay * safety <= best_so_far:
		return -INF
	# The candidate's shot is taken ARRIVING AT PACE, not from a dead stop —
	# carry steps are skated at speed (the arrival brake deliberately skips
	# carry waypoints), so the shot on arrival is the same moving-release
	# wrister the shoot-now eval prices, and the candidate must read the same
	# physics. Two-phase keeper:
	#   1. TRACK: he follows the whole carry — full budget toward the
	#      candidate's arc-square (generous to him: assumes he never falls
	#      behind en route).
	#   2. FINAL RACE: from that square he races the wind-up + flight against
	#      a release still sliding at the arrival speed — the identical final
	#      race the top-level shoot-now scoring runs, which a hard lateral cut
	#      in tight genuinely wins (his reaction + push ramp cover ~0.2 m in
	#      the ~0.28 s the shot gives him).
	# Phase 2 is what lets a STANDSTILL 1v1 price "skate the cut, then fire" as
	# one candidate. Read the release as STATIC instead and every one-step spot
	# against a set keeper honestly scores ~0 (he arrives square over any carry),
	# so a flat-footed carrier has no gradient toward building the lateral speed
	# that opens the window and dithers instead of winding up the cut. The
	# ever-receding-cut pathology stays dead regardless: the keeper is
	# assumed SQUARE at every candidate before the final race, so each further
	# cut prices only the honest last-quarter-second window, which shrinks as
	# the angle forecloses.
	#
	# The candidate's arrival UNSETTLE is credited honestly, from the TRACKED
	# keeper over the FINAL window only (windup + flight): he follows the
	# whole carry (phase 1 above), so the carry itself never catches him —
	# only the re-square the RELEASE still demands can. That residual is the
	# moving-release displacement: a candidate arrived at pace releases
	# arrive_vel × windup past the square he tracked to, and at short range
	# that lateral jump outruns his push — the hard cut in tight scores its
	# real window. A slow straight drive leaves ~zero (he tracked it all the
	# way in), so crease-smother drives earn nothing. Measuring from the goalie's
	# CURRENT position over the whole carry instead double-charges him for a swing
	# his tracking already covers, turning every doorstep drive into a phantom
	# caught-moving goalie.
	var to_cand: Vector3 = candidate - self_pos
	to_cand.y = 0.0
	var cand_dist: float = to_cand.length()
	var arrive_vel: Vector3 = Vector3.ZERO
	if cand_dist > 0.001 and local_time > 0.001:
		# Arrival pace consistent with time_to_arrive's constant-effective-speed
		# travel model, capped at this bot's real top end.
		var arrive_speed: float = minf(cand_dist / local_time, ctx.self_max_speed)
		arrive_vel = to_cand * (arrive_speed / cand_dist)
	# The keeper backs in as the carry closes on him (AIActionScoring's planning
	# depth model): over the carry his depth follows the chart / rush-backflow
	# curve, so a candidate deeper in the zone meets a keeper who has retreated,
	# not one frozen out at challenge depth swallowing the whole net. Closing is
	# the rate this carry shortens the puck's distance to the goal.
	var carry_closing: float = (self_pos.distance_to(ctx.attacking_goal_pos)
			- candidate.distance_to(ctx.attacking_goal_pos)) / maxf(local_time, 0.001)
	var tracked_goalie: Vector3 = AIActionScoring.predict_goalie_pos(
			_goalie_now(ctx), ctx.attacking_goal_pos, local_time, candidate,
			carry_closing)
	var cand_release: Vector3 = AIActionScoring.release_ahead_of_goalie(
			candidate + arrive_vel * SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S,
			ctx.attacking_goal_pos, tracked_goalie)
	var cand_flight: float = cand_release.distance_to(ctx.attacking_goal_pos) \
			/ maxf(ctx.self_wrister_shot_speed, 1.0)
	# Same expected-lateness budget as the shoot-now sweep (mean of the
	# uniform hold = max × 0.5): the candidate's future shot is priced at
	# its median release, so building a lateral cut toward a thin-but-real
	# window keeps its gradient — the executed release then converts it or
	# gets robbed, it isn't pruned at the plan stage.
	# Final-race closing: the release is fired while still carrying the arrival
	# pace, so the keeper is still backing in over the wind-up + flight.
	var release_closing: float = AIActionScoring.closing_toward(
			candidate, arrive_vel, ctx.attacking_goal_pos)
	var cand_goalie: Vector3 = AIActionScoring.predict_goalie_pos(
			tracked_goalie, ctx.attacking_goal_pos,
			SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S + cand_flight
					+ ctx.shot_timing_error_s * 0.5,
			cand_release, release_closing)
	var cand_unsettled: float = 0.0
	if ctx.reads_goalie_motion:
		cand_unsettled = AIActionScoring.goalie_unsettled(
				tracked_goalie, ctx.attacking_goal_pos,
				SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
						+ cand_flight + ctx.shot_timing_error_s * 0.5,
				cand_release, release_closing)
	# Displacement at the release: from where he is NOW over everything the
	# play gives him — carry, wind-up and flight. He tracks throughout, so the
	# residual at release is the honest budget.
	#
	# Measured at the DESTINATION, deliberately — never as a max over route
	# samples. The carrier re-decides at ~30 Hz, so it already walks the route
	# one tick at a time and re-prices the shot at every point on it; pricing
	# the future shot INTO the carry as well double-counts that loop, and a max
	# over K samples is optimistically biased against the shoot and pass legs,
	# which get one estimate each.
	var release_t: float = local_time + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S \
			+ cand_flight + ctx.shot_timing_error_s * 0.5
	var cand_displacement: float = AIShotValue.displacement_deficit_m(
			_goalie_now(ctx), ctx.attacking_goal_pos, cand_release, release_t)
	var dest_score: float = _score_at(ctx, cand_release, self_pos,
			_scratch_opponents_path, cand_goalie,
			ctx.self_wrister_shot_speed, cand_unsettled, ctx.self_aim_spread_rad,
			cand_displacement)
	var keep_prob: float = safety
	var cost: float = 0.0
	# A fully safe route pays no turnover cost at all — skip localizing a
	# strip that cannot happen (the strip-point walk is a per-defender loop;
	# this is the common open-ice case).
	if keep_prob < 1.0:
		# Price the loss where the strip actually happens — the earliest covered
		# point on the route — not the (often safe) destination. A candidate that
		# ends in open ice but threads a defender through our own slot must pay the
		# slot's turnover cost, not the destination's. This is what keeps a doomed
		# carry honestly negative.
		var strip_point: Vector3 = AIActionScoring.carry_strip_point(
				cur_puck_pos, cand_puck_pos, local_time,
				_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps, true)
		cost = AIActionScoring.turnover_cost(
				strip_point, 1.0 - keep_prob, ctx.defending_goal_pos,
				our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders,
				_scratch_our_defender_caps)
		# Transition exposure (5v5): a strip on this route also hands over the
		# counter-rush. The carrier's recovery race starts from the CANDIDATE —
		# the spot this carry commits him to (plan §6: the one-up-one-back read).
		cost += _counter_exposure_cost(ctx, strip_point, 1.0 - keep_prob,
				candidate, our_goalie)
	var total: float = dest_score * lane * decay * safety - cost
	# Beam row: the intermediates _upgrade_candidate_two_ply needs. The row is
	# this candidate's FINAL value unless pass 2 elects and upgrades it.
	_beam_pos.append(candidate)
	_beam_total.append(total)
	_beam_dest.append(dest_score)
	_beam_lane.append(lane)
	_beam_decay.append(decay)
	_beam_safety.append(safety)
	_beam_cost.append(cost)
	_beam_time.append(local_time)
	return total


# TWO-PLY pass of the beam (see CARRY_BEAM_WIDTH): completes beam row `i` with
# the reads the base pass deferred, under the same exact incumbent-bound
# prunes the inline compete ran.
#
# The pass OPTION the spot opens (see _candidate_pass_option): what the
# carrier can DO from a candidate includes moving the puck, not just shooting
# from it — the missing half of "back off to create space". A retreat that
# reopens a lane to a valuable teammate inherits (a discounted cut of) that
# value, which is what finally lets a contained carrier peel out instead of
# grinding on the defender in front of a dead shot. Credited as the
# IMPROVEMENT over the same read at the current spot: a lane already open
# from here is the live pass's to take (fire wins ties), so holding a
# cashable option is never a reason to keep carrying. CEILING PRUNE (exact):
# the option credit is maxf'd in and can't exceed _pass_option_ceiling −
# at_self, so when even that can't raise dest_score the per-receiver lane
# loop is already decided and skips wholesale.
#
# There is no second speculative carry leg here: separating "cut in behind the
# beaten man" from "orbit the perimeter" is already in the one-ply value seam.
func _upgrade_candidate_two_ply(ctx: RoleContext, i: int) -> float:
	var candidate: Vector3 = _beam_pos[i]
	var dest_score: float = _beam_dest[i]
	var lane: float = _beam_lane[i]
	var decay: float = _beam_decay[i]
	var safety: float = _beam_safety[i]
	if _pass_option_ceiling - _pass_option_at_self > dest_score:
		dest_score = maxf(dest_score, maxf(
				0.0, _candidate_pass_option(ctx, candidate,
						dest_score + _pass_option_at_self) - _pass_option_at_self))
	return dest_score * lane * decay * safety - _beam_cost[i]


# One-shot FULL eval of a single candidate — base + two-ply upgrade in one
# call, the pre-beam semantics. Kept for the single-candidate consumers
# (unit tests, the ai_micro bench); the compete itself runs the two-pass
# beam form. Leaves the candidate's row in the beam scratch, which the next
# _best_carry clears.
func _score_move_candidate(ctx: RoleContext, candidate: Vector3,
		our_goalie: Vector3, is_post_walkout: bool = false,
		best_so_far: float = -INF) -> float:
	var rows_before: int = _beam_total.size()
	var base: float = _score_move_candidate_base(
			ctx, candidate, our_goalie, is_post_walkout, best_so_far)
	if _beam_total.size() == rows_before:
		return base   # ceiling-pruned — no row to upgrade
	return _upgrade_candidate_two_ply(ctx, _beam_total.size() - 1)


# EV of a WHEEL candidate (see the WHEEL_* doc): the two-leg carry around
# the back of the cage — self → the behind-net apex → the far half-wall
# exit. The same pricing pieces as _score_move_candidate, applied PER LEG
# with the defense projected through leg one, because every straight-line
# read for this route would sample the inside of the cage. The escape gate
# (apply_escape) is what makes the wheel price well exactly when the
# retriever has a step on his chaser — the researched trigger — while a
# body already waiting on the far side kills leg two honestly.
func _score_wheel_candidate(ctx: RoleContext, dest: Vector3,
		our_goalie: Vector3, best_so_far: float) -> float:
	var self_pos: Vector3 = ctx.self_pos
	var apex := Vector3(0.0, 0.0, ctx.own_goal_dir
			* (GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH + WHEEL_APEX_CLEARANCE_M))
	var t1: float = AIActionScoring.time_to_arrive(
			self_pos, apex, ctx.self_velocity, ctx.self_max_speed,
			ctx.self_max_accel, ctx.self_lateral_grip)
	# Carry pace through the apex, consistent with the arrival model.
	var to_dest: Vector3 = dest - apex
	to_dest.y = 0.0
	var apex_speed: float = minf(
			self_pos.distance_to(apex) / maxf(t1, 0.001), ctx.self_max_speed)
	var v_apex: Vector3 = to_dest.normalized() * apex_speed \
			if to_dest.length_squared() > 0.0001 else Vector3.ZERO
	var t2: float = AIActionScoring.time_to_arrive(
			apex, dest, v_apex, ctx.self_max_speed, ctx.self_max_accel, ctx.self_lateral_grip)
	# The same exact ceiling ladder as _score_move_candidate, per leg.
	var decay: float = AIActionScoring.delay_discount(t1 + t2)
	if decay <= best_so_far:
		return -INF
	var lane1: float = AIActionScoring.carry_lane_clearance(
			self_pos, apex, t1, _scratch_opponents, _scratch_opponent_vels,
			ctx.self_max_speed)
	if lane1 <= 0.0 or lane1 * decay <= best_so_far:
		return -INF
	var cur_puck: Vector3 = _puck_pos_at(self_pos, ctx.attacking_goal_pos)
	var apex_puck: Vector3 = _puck_pos_at(apex, ctx.attacking_goal_pos)
	var dest_puck: Vector3 = _puck_pos_at(dest, ctx.attacking_goal_pos)
	var safety1: float = AIActionScoring.carry_safety(
			cur_puck, apex_puck, t1, _scratch_opponents,
			_scratch_opponent_vels, _scratch_opponent_caps, true)
	if lane1 * decay * safety1 <= best_so_far:
		return -INF
	# Leg two starts where the defense has skated to during leg one.
	_project_opponents_to(ctx, t1, _scratch_opponents_cont)
	var lane2: float = AIActionScoring.carry_lane_clearance(
			apex, dest, t2, _scratch_opponents_cont, _scratch_opponent_vels,
			ctx.self_max_speed)
	if lane2 <= 0.0:
		return -INF
	var safety2: float = AIActionScoring.carry_safety(
			apex_puck, dest_puck, t2, _scratch_opponents_cont,
			_scratch_opponent_vels, _scratch_opponent_caps, true)
	var keep: float = safety1 * safety2
	var ceiling: float = lane1 * lane2 * decay * keep
	if ceiling <= best_so_far:
		return -INF
	_project_opponents_to(ctx, t1 + t2, _scratch_opponents_cont)
	var dest_score: float = _score_at(ctx, dest, self_pos,
			_scratch_opponents_cont, _goalie_now(ctx),
			ctx.self_wrister_shot_speed, 0.0, ctx.self_aim_spread_rad)
	var benefit: float = dest_score * ceiling
	if keep >= 1.0:
		return benefit
	# The strip is priced on whichever leg is the unsafe one.
	var strip_point: Vector3
	if safety1 <= safety2:
		strip_point = AIActionScoring.carry_strip_point(
				cur_puck, apex_puck, t1, _scratch_opponents,
				_scratch_opponent_vels, _scratch_opponent_caps, true)
	else:
		_project_opponents_to(ctx, t1, _scratch_opponents_cont)
		strip_point = AIActionScoring.carry_strip_point(
				apex_puck, dest_puck, t2, _scratch_opponents_cont,
				_scratch_opponent_vels, _scratch_opponent_caps, true)
	var cost: float = AIActionScoring.turnover_cost(
			strip_point, 1.0 - keep, ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders,
			_scratch_our_defender_caps)
	cost += _counter_exposure_cost(ctx, strip_point, 1.0 - keep, dest, our_goalie)
	return benefit - cost


# Position-value scorer at `pos`, evaluated from the carrier at `from_pos`.
#
#   carrier in the offensive zone:  score_shoot(pos) only
#   carrier outside the zone:        max(score_shoot(pos), position_potential(pos))
#
# The regime is gated on the CARRIER (from_pos), not on `pos`. This is the whole
# trick that lets the two value scales coexist without a bridging floor: a carrier
# already in the zone reads real, goalie-aware shot danger for every (in-zone,
# valve-guaranteed) candidate — the O-zone is xG's domain, a strictly better read
# than any positional proxy, and it drives the bot to the slot rather than a
# "high-potential" spot that doesn't score. A carrier OUTSIDE prices every
# candidate — including an entry target across the blue line — on the position_
# potential scale, whose closeness gradient climbs toward the slot, so driving into
# the zone out-scores staying out. Because of offsides the two never need to be
# compared: the only in-vs-out choice is the carry into the zone, made entirely in
# potential currency. The max with score_shoot lets a genuinely open entry look
# (a breakaway) still register its shot value on the way in.
#
# The potential branch pays the realization discount (see
# AIActionScoring.potential_realization_discount): potential is future
# value that still has to be skated to the slot, so it decays over that
# remaining travel exactly like every other future action. Leave stand-still's
# potential undecayed and it strictly beats a step toward the net in open ice —
# the blue-line freeze. Applied uniformly here so carry candidates, stand-still,
# and pass receivers all price potential in the same currency.
#
# `opps` should already be projected to the time the actor will be
# at `pos` (caller's responsibility — score_pass does this for
# receivers, _best_carry does it for carry candidates).
# `shot_speed_m_s` is the SHOOTER's charged-shot speed. Carry/stand candidates
# evaluate THIS bot's future shot, so they pass its attribute-scaled speed; the
# receiver eval (score from a teammate's spot) keeps the default since we don't
# carry teammates' attributes — same cross-player boundary as elsewhere.
func _score_at(ctx: RoleContext, pos: Vector3, from_pos: Vector3,
		opps: Array[Vector3],
		predicted_goalie_pos: Vector3,
		shot_speed_m_s: float = AIActionScoring.WRISTER_SHOT_SPEED_M_S,
		goalie_unsettled_factor: float = 0.0,
		_aim_spread_rad: float = 0.0,
		keeper_displacement_m: float = 0.0) -> float:
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	# All the carrier's opponent arrays (path / pass / stand projections) are built
	# in the same snapshot order as _scratch_opponent_caps, so the defenders in the
	# shot lane are priced at their real reach and speed. (lane_clear falls back to
	# league defaults if a count ever mismatches, so this is safe regardless.)
	# `aim_spread_rad` is the SHOOTER's execution wobble: self-evals (carry/stand)
	# pass this bot's own spread so a noisy hand demands wider windows in shot
	# selection; receiver evals leave 0 (cross-player boundary — a teammate may be
	# a human whose hand we don't model, so we don't handicap the feed).
	# Predicted post-seal for THIS spot — the same RVH/VH wall the live goalie
	# adopts at a sharp near-goal-line angle (AIActionScoring.derive_post_seal_x_sign).
	# Threading it here is what makes the predictive paths (carry candidates, pass
	# receivers) score the sharp-angle look against the SAME sealed keeper the
	# shoot-now eval reads live — no phantom far-side open net a bot would carry to
	# but never shoot. 0.0 (no seal) for every normal in-front look, so slot/mid
	# scoring is untouched.
	# Hot-path skip, mirrored from threat_surface_shoot (see its doc): with
	# the keeper HOME, a direct shot from OUTSIDE the attacking zone is dead
	# by score_shoot's own arrival-honest coverage math — the potential
	# branch below always wins the max. Don't pay the hole geometry per
	# carry candidate to find ~0; NZ/DZ carries hit this on every candidate.
	# A displaced/pulled goalie voids the proof (breakaway into an open net
	# reads on the way in), so it computes fully.
	# (Settled keeper only — an unsettled factor voids the coverage proof the
	# same way displacement does.)
	var out_of_zone: bool = not AIActionScoring.in_offensive_zone(pos, attacking_goal)
	if out_of_zone and goalie_unsettled_factor <= 0.0 \
			and not AIActionScoring.in_offensive_zone(from_pos, attacking_goal) \
			and predicted_goalie_pos.distance_to(attacking_goal) \
					< AIActionScoring.THREAT_GOALIE_HOME_M:
		var potential_nz: float = AIActionScoring.position_potential(
				pos, attacking_goal, opps)
		return potential_nz * AIActionScoring.potential_realization_discount(
				pos, attacking_goal)
	# THE SEAM (AIShotValue): the public xG form plus a keeper-displacement
	# term. The ranking decisions are priced here rather than by the five-hole
	# geometry (which still picks aim / loft / power once SHOOT wins), because a
	# max over five holes with structural cliffs cannot supply the small,
	# meaningful DIFFERENCES a carry beam consumes. Displacement arrives as a
	# measured metre figure rather than the 0..1 unsettled scalar, which
	# saturates the moment he is caught moving at all and so cannot say HOW
	# beaten he is.
	#
	# The seam does NOT model the shooter: `_aim_spread_rad` is unused here, xG
	# being a property of the chance rather than of who is shooting. So on this
	# path the per-tier scatter dial does not act as the SELECTIVITY lever
	# BotSkillProfile describes — a wobblier hand does not decline marginal
	# shots.
	var shoot_s: float = AIActionScoring.score_shoot_value(
			pos, attacking_goal, predicted_goalie_pos, keeper_displacement_m,
			GameRules.NET_HALF_WIDTH, opps, shot_speed_m_s,
			_scratch_opponent_caps)
	if AIActionScoring.in_offensive_zone(from_pos, attacking_goal):
		# PURE xG in the offensive zone — position_potential (the progression
		# value map) is not consulted here; once a goalie is in play a real shot
		# probability is the better read of a spot.
		#
		# No possession floor is needed under this read. A flat currency (one
		# that returns the same constant wherever no shot is available) leaves
		# the argmax to fall through to turnover cost and the carrier orbiting
		# the perimeter, which is what an additive floor exists to mask. A
		# smooth xG surface does not go flat: a spot with no shot right now
		# still scores by its distance and angle, so the gradient is real.
		return shoot_s
	var potential_s: float = AIActionScoring.position_potential(
			pos, attacking_goal, opps)
	var realization: float = AIActionScoring.potential_realization_discount(
			pos, attacking_goal)
	return maxf(shoot_s, potential_s * realization)


# The pass OPTION a carry candidate opens: the best cached receiver value
# reachable through a CLEAR lane from the candidate spot. Backing off a
# containing defender is valuable precisely because separation reopens
# passing lanes; priced on the spot's own shot/potential alone, a contained
# carrier's retreat earns nothing and it pacifies against the man instead.
# Coarse by design: receivers valued at
# their CURRENT spots (cached once per re-eval in _pick_action), lanes judged
# against CURRENT defenders — this only has to rank SPOTS; the fired pass is
# still fully solved at fire time. Priced as a future action: lane ×
# completion odds × the pass's own flight decay × PASS_OPTION_DISCOUNT.
func _candidate_pass_option(ctx: RoleContext, candidate: Vector3,
		useless_below: float = 0.0) -> float:
	var best: float = 0.0
	for i: int in _scratch_option_receiver_pos.size():
		# Receiver ceiling (exact): lane/miss/decay all ≤ 1, so a receiver
		# whose full-discount value can't beat the running best — or the
		# caller's own uselessness floor — can't win the loop.
		if _scratch_option_receiver_val[i] * PASS_OPTION_DISCOUNT \
				<= maxf(best, useless_below):
			continue
		var rpos: Vector3 = _scratch_option_receiver_pos[i]
		if AIActionScoring.pass_lane_blocked_by_net(candidate, rpos):
			continue
		if AIActionScoring.pass_crosses_own_slot(
				candidate, rpos, ctx.own_goal_dir * GameRules.GOAL_LINE_Z):
			continue
		var dist: float = candidate.distance_to(rpos)
		var pass_speed: float = AIActionScoring.pass_launch_speed(
				dist, ctx.self_wrister_shot_speed, ctx.pass_speed_scale)
		var lane: float = AIActionScoring.lane_clear(
				candidate, rpos, _scratch_opponents, pass_speed,
				_scratch_opponent_vels, _scratch_opponent_caps)
		if lane <= 0.0:
			continue
		var option: float = _scratch_option_receiver_val[i] \
				* lane * (1.0 - AIActionScoring.pass_miss_prob(
						dist, ctx.self_pass_aim_error_rad)) \
				* AIActionScoring.delay_discount(dist / maxf(pass_speed, 1.0)) \
				* PASS_OPTION_DISCOUNT
		if option > best:
			best = option
	return best


# The value of an open pass receiver DRIVING IN: the best value they can reach by
# carrying toward the net, not just a one-timer / potential from where they catch it.
# Models "a wide-open man walks into a better chance" (OZ) and "an ahead man with a
# clear path skates it into the zone" (NZ/DZ) — both of which the score_at above
# omits (OZ is shot-only; a static receiver isn't credited for advancing).
#
# The reach is the REACHABLE SET, not a fixed step: the receiver carries toward the
# net up to RECEIVER_DRIVE_MAX_M, but only as far as the path stays clear — a defender
# in the way strips it early (carry_strip_point), a very clear lane lets it run the
# whole way. So a teammate a little farther back with a WIDE-OPEN path is credited
# for the deep spot they can reach, while a covered one earns nothing. Value =
# score_at(reached spot) × keep-probability × decay(time to reach it); the pass-flight
# decay is applied to the max() by the caller. Goalie squared to the reached spot, and
# the whole thing uses the SAME reach/clearance/score machinery as the carrier's own
# carry candidates, so both sides of the pass are valued consistently. Bounded — one
# carry, leaf value, no further passing — so no recursion. Reuses _scratch_opponents_pass.
func _receiver_drive_in_value(ctx: RoleContext, receiver_spot: Vector3,
		receiver_shot_speed: float, receiver_caps: AISkaterCaps,
		receiver_vel: Vector3 = Vector3.ZERO) -> float:
	var to_net_x: float = ctx.attacking_goal_pos.x - receiver_spot.x
	var to_net_z: float = ctx.attacking_goal_pos.z - receiver_spot.z
	var d: float = sqrt(to_net_x * to_net_x + to_net_z * to_net_z)
	# Already tight to the net — no room to improve by driving; instant shot covers it.
	if d <= RECEIVER_DRIVE_MIN_NET_DIST_M + 0.1:
		return 0.0
	var reach: float = minf(RECEIVER_DRIVE_MAX_M, d - RECEIVER_DRIVE_MIN_NET_DIST_M)
	var inv: float = 1.0 / d
	var dir_x: float = to_net_x * inv
	var dir_z: float = to_net_z * inv
	var target := Vector3(
			receiver_spot.x + dir_x * reach, 0.0, receiver_spot.z + dir_z * reach)
	if not AIRoleHelpers.is_legal_position(target):
		return 0.0
	var recv_speed: float = receiver_caps.max_speed if receiver_caps != null \
			else ctx.self_max_speed
	var recv_accel: float = receiver_caps.max_accel if receiver_caps != null \
			else ctx.self_max_accel
	# MOMENTUM-HONEST drive time (the calibrated phase model): a receiver
	# already streaking netward carries his pace into the drive; one
	# RETREATING must brake the retreat out and ramp from rest, paying the
	# reversal in real time (and thus decay). A plain `reach / max_speed` credits a
	# receiver back-pedalling out of the zone with the same instant full-speed drive
	# as a streaker — one blindness that both over-values the backpass to a
	# retreating man and under-values the stretch feed to one in stride.
	var reach_time: float = AIActionScoring.time_to_arrive(
			receiver_spot, target, receiver_vel, recv_speed, recv_accel)
	# Reachable-set safety + strip point over the drive, using the SAME current-opponent
	# reach model the carrier's carry uses (carry_clearance/strip project the defenders
	# in by their velocity + closing reach). A clear lane keeps ~1 and reaches `target`;
	# a defender in the way drops keep and pulls the reached spot back to the strip.
	# apply_escape: driving in past a man you out-skate is winnable, not a wall —
	# the same read the carrier's own carry candidates use (the drive-in credit that
	# floors the carry is exactly "the shot I skate into by beating my man").
	var keep: float = AIActionScoring.carry_safety(
			receiver_spot, target, reach_time,
			_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps,
			true)
	if keep <= 0.0:
		return 0.0
	var reached: Vector3 = AIActionScoring.carry_strip_point(
			receiver_spot, target, reach_time,
			_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps, true)
	var t: float = reach_time if reached == target \
			else AIActionScoring.time_to_arrive(
					receiver_spot, reached, receiver_vel, recv_speed, recv_accel)
	_project_opponents_to(ctx, t, _scratch_opponents_pass)
	# The keeper backs in over the receiver's drive exactly as he does over the
	# carrier's own (planning depth model) — both sides of the carry-vs-pass
	# compete must read the same keeper, or the feed inherits a phantom wall.
	var goalie: Vector3 = AIActionScoring.goalie_squared_pos(
			_goalie_now(ctx), ctx.attacking_goal_pos, reached, t,
			(receiver_spot.distance_to(ctx.attacking_goal_pos)
					- reached.distance_to(ctx.attacking_goal_pos)) / maxf(t, 0.001))
	# score_at, not score_shoot: OZ → goalie-aware shot from the reached spot; NZ/DZ →
	# position potential of the reached spot (advanced toward the zone). Same regime
	# the carrier's own carry candidates use, so the ahead man on the clear path is
	# credited for continuing the rush exactly as the carrier would credit itself.
	var advanced: float = _score_at(ctx, reached, ctx.self_pos,
			_scratch_opponents_pass, goalie, receiver_shot_speed, 0.0)
	return advanced * keep * AIActionScoring.delay_discount(t)


# How much room the carrier has to OPERATE toward the attacking objective —
# the controlled fraction of the forward cone over FORWARD_PRESSURE_HORIZON_M.
# 1.0 when the ice ahead is his, dropping toward 0 as defenders take it away.
# Feeds the carry's pass-first discount (see FORWARD_PRESSURE_*).
func _carrier_forward_clearance(ctx: RoleContext) -> float:
	# Size once, then reuse: controlled_space refills every entry each call.
	if _scratch_bearing_control.size() != AIActionScoring.SPACE_SAMPLE_ANGLES.size():
		_scratch_bearing_control.resize(
				AIActionScoring.SPACE_SAMPLE_ANGLES.size())
	return AIActionScoring.controlled_space(
			ctx.self_pos, ctx.self_velocity, ctx.caps_by_peer.get(ctx.peer_id),
			ctx.attacking_goal_pos, FORWARD_PRESSURE_HORIZON_M,
			_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps,
			_scratch_bearing_control)


# Forward-pressure read for ANY spot: the space available to a carrier standing
# at `pos` with velocity `vel` and build `caps`. Shared by the carrier's own
# discount and the pass receiver's (see _pass_ev) so both sides of a
# carry-vs-pass compete pay the same toll for the same clogged ice.
#
# The read is AIActionScoring.controlled_space — a fan of carry paths across the
# forward cone, each priced by the same carry_safety the real carry candidates
# use, area-weighted; that block doc carries the model and why a single netward
# ray cannot serve as this discount. The momentum credit is not a term here: it
# falls out of pricing each sample at its honest time_to_arrive.
func _forward_clearance_at(ctx: RoleContext, pos: Vector3, vel: Vector3,
		caps: AISkaterCaps) -> float:
	return AIActionScoring.controlled_space(
			pos, vel, caps, ctx.attacking_goal_pos, FORWARD_PRESSURE_HORIZON_M,
			_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps)


# Value (EV) of the best DEVELOPING feed — a play a teammate is still
# creating, worth keeping the puck for. Two kinds, both self-gating
# (a teammate whose developing spot scores a poor feed gives no reason
# to hold):
#
#   - Cross-seam ONE-TIMER (FINISHER slot): a FINISHER-slotted teammate
#     in the OZ, not yet one-timer-ready, settling into its spot. We
#     score the feed to where they ARE now as a one-timer (release =
#     pass flight only, with goalie-motion): the value the feed gets
#     the instant they flag ready. Until then the normal pass scoring
#     rates them mid-windup (goalie re-squares) and under-values the
#     play; this is the reason to keep the puck and wait.
#
#   - Breakout OUTLET (BREAKOUT_STRONG / OUTLET slots): an outlet
#     skating its route toward open ice — see _developing_outlet_feed.
#     This is the reason a pressured own-zone carrier protects the puck
#     and skates instead of forcing a low-value backpass: the pass the
#     outlet is CREATING out-values everything available right now.
#
# Returns 0 if nothing is developing.
# Cognition gate: a tier that doesn't hold for developing plays
# (ctx.holds_for_developing_feeds false) sees nothing here by definition —
# it plays only what exists right now.
func _best_developing_feed(ctx: RoleContext) -> float:
	if not ctx.holds_for_developing_feeds:
		return 0.0
	if ctx.team_brain == null:
		return 0.0
	var self_pos: Vector3 = ctx.self_pos
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var self_state: SkaterNetworkState = ctx.snapshot.skater_states.get(ctx.peer_id)
	var self_facing: Vector2 = self_state.facing if self_state != null else Vector2.ZERO
	var best: float = 0.0
	for pid: int in _scratch_teammate_ids:
		var slot: int = ctx.team_brain.get_slot(pid)
		var tm: SkaterNetworkState = ctx.snapshot.skater_states.get(pid)
		if tm == null:
			continue
		var feed: float = 0.0
		if slot == AIRoleSlots.Slot.FINISHER:
			# Ghosted (offside) finisher can't receive — the live pass
			# scoring skips ghosts, so holding for one would be waiting
			# for a feed we're never allowed to make. Already-flagged —
			# the normal pass scoring feeds it; nothing to wait for.
			#
			# The play that WILL exist, not just the one that does: a
			# finisher still skating to his staging spot is valued at the
			# spot he's DRIVING TO — position projected along velocity, the
			# same primitive as the developing outlet below — so a fresh
			# zone entry holds for the mates still arriving instead of
			# settling for the weak from-the-top shot the moment the carrier
			# crosses the line. As he settles the projection converges to
			# his position, the live pass scoring converges to this value,
			# and fire wins the tie — the hold can't outlive the play it's
			# waiting for (and _hold_elapsed_s decays a wait that never
			# materialises). The OZ gate reads the projected spot for the
			# same reason: a finisher a stride outside the line, driving in,
			# IS the developing cross-seam. Buffered by the same reception
			# keep-out band the live pass filter enforces — holding for a
			# feed to a spot the pass scoring will never be allowed to hit
			# would be waiting forever.
			var fin_vel: Vector3 = tm.velocity
			var spot := Vector3(
					tm.position.x + fin_vel.x * OUTLET_DEVELOP_WINDOW_S, 0.0,
					tm.position.z + fin_vel.z * OUTLET_DEVELOP_WINDOW_S)
			if tm.is_ghost or ctx.team_brain.is_one_timer_ready(pid) \
					or not AIActionScoring.in_offensive_zone(
							spot, ctx.attacking_goal_pos, OZ_RECEIVE_LINE_BUFFER_M) \
					or not AIRoleHelpers.is_legal_position(spot):
				continue
			var dist: float = self_pos.distance_to(spot)
			var pass_speed: float = AIActionScoring.pass_launch_speed(
					dist, ctx.self_wrister_shot_speed, ctx.pass_speed_scale)
			var flight_t: float = clampf(dist / pass_speed, 0.0, PASS_LEAD_MAX_S)
			_project_opponents_to(ctx, flight_t, _scratch_opponents_pass)
			# On the seam, like the live pass leg — this value is compared
			# directly against fire_score (see score_pass_value). The keeper
			# gets the flight AND the driving finisher's wrister charge to
			# re-square, the same clock _pass_ev bills a non-one-timer.
			feed = AIActionScoring.score_pass_value(
					self_pos, spot, ctx.attacking_goal_pos,
					AIShotValue.displacement_deficit_m(
							_goalie_now(ctx), ctx.attacking_goal_pos, spot,
							flight_t + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S),
					_scratch_opponents_pass, pass_speed, _scratch_opponent_caps)
		elif slot == AIRoleSlots.Slot.BREAKOUT_STRONG \
				or slot == AIRoleSlots.Slot.OUTLET \
				or slot == AIRoleSlots.Slot.BREAKOUT_D2:
			# BREAKOUT_D2 (5v5): the OVER — the D-to-D behind the net that
			# reverses the flow when F1 overcommits strong-side. Holding a
			# beat for the partner still SKATING to the valve is the
			# researched play (unlike the weak-side valve below, which is
			# always priceable live); the min-speed gate below means a
			# partner already parked there never reads as developing.
			feed = _developing_outlet_feed(ctx, tm, our_goalie, self_facing, ctx.caps_by_peer.get(pid))
		if feed > best:
			best = feed
	return best


# EV of the breakout feed a skating outlet is CREATING. The outlet's
# position is projected OUTLET_DEVELOP_WINDOW_S along its velocity —
# the spot it's getting open at — and the pass to that spot is priced
# through the SAME _pass_ev as the live pass scoring. That parity is
# the termination guarantee: as the outlet arrives, the live pass
# converges to this developing value, fire wins the tie, and the puck
# goes — the hold can't outlive the play it's waiting for (and the
# _hold_elapsed_s decay in _pick_action erodes a wait that never
# materialises).
#
# BREAKOUT_WEAK is deliberately excluded: the weak-side reverse valve
# stays goal-side of the carrier by role contract, so "waiting for it
# to develop" would mean holding for a backpass — the exact play this
# hold exists to avoid forcing. The valve is an escape hatch the live
# pass scoring prices on its own.
func _developing_outlet_feed(ctx: RoleContext, tm: SkaterNetworkState,
		our_goalie: Vector3, self_facing_xz: Vector2,
		receiver_caps: AISkaterCaps = null) -> float:
	if tm.is_ghost:
		return 0.0
	var vel: Vector3 = tm.velocity
	if vel.x * vel.x + vel.z * vel.z \
			< OUTLET_DEVELOP_MIN_SPEED_M_S * OUTLET_DEVELOP_MIN_SPEED_M_S:
		return 0.0
	var spot := Vector3(
			tm.position.x + vel.x * OUTLET_DEVELOP_WINDOW_S, 0.0,
			tm.position.z + vel.z * OUTLET_DEVELOP_WINDOW_S)
	if not AIRoleHelpers.is_legal_position(spot):
		return 0.0
	var dist: float = ctx.self_pos.distance_to(spot)
	var pass_speed: float = AIActionScoring.pass_launch_speed(
			dist, ctx.self_wrister_shot_speed, ctx.pass_speed_scale)
	var flight_t: float = clampf(dist / pass_speed, 0.0, PASS_LEAD_MAX_S)
	# Breakout receivers carry on reception (no one-timer), so the goalie
	# gets flight + their wrister charge before any shot — same release
	# model the live pass scoring applies to a non-ready receiver.
	var release_t: float = flight_t + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
	var rotation_time: float = _facing_rotation_time(self_facing_xz, ctx.self_pos, spot,
			ctx.self_reach_cone_half_angle, ctx.self_facing_turn_rate)
	return _pass_ev(ctx, spot, pass_speed, flight_t, release_t,
			flight_t + rotation_time, our_goalie, receiver_caps)


# Approximate puck-rest position when the carrier is at `body_pos`.
# The puck rides ~CARRY_BLADE_AIM_FORWARD_M in front of the body in
# the attacking-goal direction (see SkaterAgentStateMachine._carry_mouse_aim
# — the carry mouse aims at this point and the blade IK puts the puck
# there). Used by poke-safety scoring so the omnidirectional threat
# penalty measures opp-body → our-puck (the real poke geometry), not
# opp-body → our-body. Degenerate case (body_pos == attacking_goal,
# excluded by goal-line buffer in candidate gen) falls back to body
# position to avoid NaN.
func _puck_pos_at(body_pos: Vector3, attacking_goal: Vector3) -> Vector3:
	var to_goal: Vector3 = attacking_goal - body_pos
	to_goal.y = 0.0
	var len_sq: float = to_goal.x * to_goal.x + to_goal.z * to_goal.z
	if len_sq < 0.0001:
		return body_pos
	var inv: float = 1.0 / sqrt(len_sq)
	return body_pos + to_goal * (inv * SkaterAgentStateMachine.CARRY_BLADE_AIM_FORWARD_M)


# OZ slot anchor — recursion terminator and a permanent carry
# candidate. Slot depth from goal line is fixed.
func _slot_anchor(own_goal_dir: float) -> Vector3:
	var slot_z: float = -own_goal_dir * (GameRules.GOAL_LINE_Z - GameRules.SLOT_DIST_M)
	return Vector3(0.0, 0.0, slot_z)


# Where a pass physically leaves from: the carried puck (riding the blade, up
# to a stick's reach from the body), falling back to the body center when the
# snapshot has no puck. Mirrors the shot model's puck-origin release ref: the
# lead solve, the friction-compensated launch speed, and the net/lane checks
# all measure the real flight, not a flight from the passer's chest, where the
# ~1 m origin error is a systematic over-lead on a close feed.
func _pass_origin(ctx: RoleContext) -> Vector3:
	if ctx.snapshot.puck_state != null:
		return Vector3(
				ctx.snapshot.puck_state.position.x, 0.0,
				ctx.snapshot.puck_state.position.z)
	return ctx.self_pos


# Returns the opposing goalie's CURRENT world position. Used as input
# to AIActionScoring.predict_goalie_pos. Falls back to the attacking
# goal when goalie state isn't buffered yet (first-frame edge case).
func _goalie_now(ctx: RoleContext) -> Vector3:
	var opp_goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(1 - ctx.team_id)
	if opp_goalie == null:
		return ctx.attacking_goal_pos
	return Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z)


# Wraps AIActionScoring.predict_goalie_pos for the common case where
# the puck-at-release is the position we're scoring a shot from.
# `release_time_s` is the time from now until the bot fires (e.g.,
# wrister charge time + any path/flight time before the fire).
func _predict_goalie_at(ctx: RoleContext, release_time_s: float,
		puck_pos_at_release: Vector3, closing_speed_m_s: float = 0.0) -> Vector3:
	return AIActionScoring.predict_goalie_pos(
			_goalie_now(ctx), ctx.attacking_goal_pos,
			release_time_s, puck_pos_at_release, closing_speed_m_s)


# Companion to _predict_goalie_at: how unsettled [0,1] the goalie is at that same
# release, threaded into score_shoot so a shot catching the goalie mid-slide
# (cross-seam one-timer) rates higher than the same shot at a set goalie.
# Cognition gate: a goalie-motion-blind tier (ctx.reads_goalie_motion false)
# models the keeper as always set — the re-square race this term wins is
# invisible to it, so it stops manufacturing cross-crease chaos on purpose.
# The evaluator itself is untouched; the bot just loses the input.
func _goalie_unsettled_at(ctx: RoleContext, release_time_s: float,
		puck_pos_at_release: Vector3, closing_speed_m_s: float = 0.0) -> float:
	if not ctx.reads_goalie_motion:
		return 0.0
	return AIActionScoring.goalie_unsettled(
			_goalie_now(ctx), ctx.attacking_goal_pos,
			release_time_s, puck_pos_at_release, closing_speed_m_s)
