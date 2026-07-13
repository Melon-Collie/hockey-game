class_name BotSkillProfile
extends RefCounted

# Per-difficulty bundle of DETERMINISTIC bot-skill knobs. Pure domain (no
# engine APIs, no RNG) so it stays unit-testable and replay-safe — the whole
# point of these levers is that the same situation produces the same bot
# behaviour at a given difficulty, every time.
#
# ── Why these knobs ───────────────────────────────────────────────────────────
# The "perfect bot" baseline was perfect in two separable ways:
#   1. Perfect EXECUTION — the blade snapped to the ideal aim point every tick,
#      so every shot went to the exact same corner and dekes were matched on the
#      frame.
#   2. Perfect REACTION — the agent recognised DISCRETE events (a pass
#      released, the puck changing hands) the same physics tick they happened.
# Both are dialled back here deterministically — the only RNG anywhere in the
# bot is the per-release execution sampling described below (hands, never
# decision dice):
#   • Aim speed is NO LONGER a difficulty knob — a bot slews its aim cursor at its
#     own REAL Hands blade speed (SkaterController.max_blade_speed, via
#     AISkaterCaps.blade_speed), so aiming looks exactly as fast as its hands are,
#     and a lower-Hands build is naturally slower/less precise. This retired the
#     old artificial mouse_max_speed slew, which capped every bot's blade at a flat
#     per-difficulty rate regardless of Hands. Execution difficulty now rides the
#     bot's attribute BUILD, not a hands-override. (A second-stage per-tick
#     exponential cursor lerp in SkaterAgent — mouse_lerp_factor — was likewise
#     retired: it added only milliseconds of lag, and its straight-line world
#     blending chord-cut the SM's shaped cursor paths across the body on big
#     flips, tripping the pose IK gate's facing freeze. The natural swing feel
#     it bought now comes from the Hands slew + carry sway instead.)
#   • carrier_reaction_delay_s — how long the bot keeps acting on its PRIOR
#     read of who controls the puck before recognising a possession change.
#     This is the human "you can't react to a pass within a tick" lever. It is
#     applied ONLY to the discrete carrier signal — the bot still tracks every
#     position/velocity in REAL TIME (so it aims at the puck's actual spot, not
#     a stale one), and it knows its OWN possession instantly. See GameManager.
#   • dispatch_period_ticks — how often the full decision dispatch re-runs;
#     a slower cadence makes the bot commit to a read longer before adjusting.
#   • shot_aim_error_m / pass_aim_error_m — the execution-error levers (RNG on
#     the hands, never decision dice). ONE error is sampled PER RELEASE at the
#     press commit (uniform ±, on the 2 m aim arm) and held constant through
#     the windup, so the blade sweeps smoothly to a slightly-wrong spot — a
#     human who missed his spot, not a shaking hand. (This replaced per-tick
#     white noise on the output cursor, which read as stick jitter at the
#     lower tiers.) The release-tick error distribution is identical, so the
#     shot SCORE still budgets the same spread as extra required window
#     (RoleContext.self_aim_spread_rad): a wobblier hand both misses more and
#     stops taking low-percentage looks from range. Split by release type:
#     SHOT error is the scoring dial (a spread corner snipe becomes
#     goals/saves/misses instead of always finding twine); PASS error stays
#     small at every tier — completed passes are fun to play against, every
#     shot going in is not. Deterministic per tier; only the per-release
#     samples are RNG (per-bot seeded).
#   • shot_timing_error_s — motor timing variance on the SHOT release (the
#     "less automatic" lever). A human can't hit a physics tick: each
#     SHOOT_PRESSED samples a late-release hold in [0, this] and the shot
#     leaves that much after the intended tick. The EXPECTED lateness (half
#     this, the mean of that draw) is budgeted into the goalie's
#     react-then-push time wherever the carrier scores its own shot
#     (shoot-now sweep + carry-candidate final race), so each shot is scored
#     at its MEDIAN release. The result on the doorstep lateral cut — the
#     razor window that used to convert every time: the bot still goes for
#     it (deliberately — a laterally moving goalie in tight SHOULD be
#     vulnerable, and pruning the attempt read as swallowing the puck), but
#     the sampled delay decides it: the early half of the draw beats the
#     push, the late half meets a square goalie. Conversion scales with how
#     fat the window really is instead of being 100%. Grounded as a physical
#     measurement (human release-timing variance), not a shape parameter.
#   • carry_sway_m — natural stickhandling sway: a smooth low-frequency
#     lateral oscillation of the carry cursor (per-bot RNG phase, amplitude
#     and rhythm wander) so a carrying bot dangles the puck like a human hand
#     instead of holding a rail. Purely organic feel — it lives only in CARRY
#     deliberation; the blade steadies the moment the bot lines up a release
#     (which doubles as a readable tell, like a real shooter settling). This,
#     not cursor noise, is the "hands are alive" texture now.
#   • carry_settle_delay_s — how long after gaining possession the carrier may
#     ONLY carry before a SHOOT / PASS / DUMP commit is allowed. This is the
#     "human can't release the instant the puck touches the tape" lever: the
#     hard bot's tick-zero touch pass reads as inhuman, and the settle beat is
#     also a real defensive window (pressure a fresh Normal/Easy carrier and
#     you arrive before the outlet fires). Consumed in AIRoleCarrier via
#     RoleContext; reception one-timers are NOT gated here (the puck never
#     settles on the tape) — they're already throttled by the reaction delay
#     and by the shot-spread budget on the reception gate.
#
# ── Pace knobs (a SEPARATE axis from the precision knobs above) ───────────────
# The four knobs above tune how SHARP the bot is — its hands, its shots, its
# reads. They do NOT change the PACE a human feels: how much time/space they get
# on the puck and how fast the play comes at them. Those are identical across
# tiers unless the levers below move, and pace is what a human feels on EVERY
# possession (precision only shows up on the bot's finish). Two pace levers, both
# the bot's OWN positioning/decision (no RNG, no AI-scoring-mirror — the goalie /
# receiver threat model stays on league-default constants), so they're as
# replay-safe as the precision knobs:
#   • pursuit_standoff_m — how far the on-puck PRESSURE defender sets its cut-off
#     line BACK toward its own net, beyond the one-stick-length baseline. Bigger
#     → defenders sag off the carrier, so a human gets a beat to look up and make
#     a play instead of the play collapsing on them. Consumed in pressure.gd.
#   • pass_speed_scale — multiplies the bot's OWN pass launch speed (passes only,
#     not shots). RETIRED TO 1.0 AT EVERY TIER: the launch solve already lands
#     the puck on the tape at the receiver-relative magnet pace (a deliberately
#     soft arrival), so scaling below 1.0 under-delivered that solved speed and
#     starved passes short of the receiver — it produced missed passes, not a
#     more readable game. Tempo concessions live on the other pace knobs.
#     The lever + plumbing are kept (AIActionScoring.pass_launch_speed via
#     RoleContext) in case a future tier wants a *solved-for* softer arrival.
#   • check_aggression — how hard the on-puck pressurer hunts BODY CHECKS. 1.0 =
#     today's hit-hunting; below 1.0 raises the required separating-hit impulse
#     inversely so an easier bot only commits to the hardest hits; 0.0 = never
#     commits a check, pure containment. The single biggest "scary vs relaxed"
#     lever — getting lined up and staggered is the most intense moment in the
#     game. Consumed in AIRoleHelpers.evaluate_body_check.
#   • defensive_anticipation_scale — multiplies DEFENSIVE_ANTICIPATION_S, how far
#     the backline LEADS a moving man. 1.0 = today; lower → defenders react to
#     where you ARE, not where you're GOING, sitting a step behind so there's
#     space everywhere (not just off the puck-carrier, which pursuit_standoff_m
#     handles). Consumed in AIRoleHelpers.lead_threat via the cover roles.
#
# Note the pace knobs split by WHAT a lower tier concedes: pursuit_standoff_m and
# defensive_anticipation_scale concede SPACE (positioning), check_aggression
# concedes THREAT (physicality). (pass_speed_scale — TEMPO — is retired at 1.0,
# see its bullet above.)
#
# ── Cognition gates (a THIRD axis: what the bot can even SEE) ─────────────────
# The knobs above degrade how well the bot executes and how hard it pushes.
# These bools degrade its hockey IQ — which reads and plays exist in its model
# at all. The rule that keeps them honest: the shared evaluators are NEVER
# corrupted per tier; a gate either removes an INPUT the evaluator consumes
# (perception — the lower tier scores with less information) or removes an
# OPTION from the compete (repertoire — the play is simply not considered).
# Deterministic bools, no RNG, no scoring fudge factors.
#   • reads_goalie_motion — elite shooters exploit a MOVING goalie two ways:
#     aiming back across the grain of a slide (AIShotAim's velocity-projected
#     shadow) and valuing the re-square race a cross-seam feed wins (the
#     goalie_unsettled term in the pass / one-timer EV). False = the bot models
#     the goalie as always set and shoots at where he IS: it stops timing plays
#     to catch him mid-slide and stops manufacturing cross-crease chaos on
#     purpose. The biggest single scoring cut, through cognition not wobble.
#   • holds_for_developing_feeds — valuing a play that doesn't exist yet (a
#     finisher still skating to the back door, an outlet still opening up) and
#     protecting the puck until it does is elite anticipation
#     (carrier._best_developing_feed). False = the bot plays only what's in
#     front of it right now.
#   • angles_the_chase — approaching an opposing carrier from the inside to
#     force them to the boards (_shade_intercept_goal_side) is taught defensive
#     skill. False = the bot chases straight at the puck, so a human's cutback
#     to the middle actually works.
#   • plays_rush_pass_lanes — the last man back on a rush reading the carrier's
#     PASSING options and splitting toward an uncovered receiver's feed lane
#     ("play the pass, the goalie takes the shooter" — the 2-on-1 doctrine;
#     AIRoleContain's lane fan). False = CONTAIN sees only the carrier and
#     retreats on the carrier→net line, so a human's odd-man cross-crease
#     feed connects — the classic newcomer glory play.
#
# The GOALIE is intentionally NOT represented here — it stays consistent across
# difficulties (and the skater AI's goalie-slide prediction in AIActionScoring
# stays in lockstep with the live goalie regardless of tier).
#
# ── Tick-rate note (these knobs are tuned for PHYSICS_TICK = 120 Hz) ──────────
# carrier_reaction_delay_s (seconds) is tick-independent — it converts to a
# per-tick countdown against the real tick rate. dispatch_period_ticks is NOT:
# a tick count changes meaning with the tick rate. It is calibrated against
# the current 120 Hz sim; if the sim tick rate ever changes, rescale it
# linearly with the rate to preserve wall-clock feel.
#
# To add a tier: add a Difficulty enum value, a factory, and a for_difficulty
# arm. To add a knob: add a field + _init param, set it in ALL THREE factories,
# and consume it where the relevant value is read (SkaterAgentStateMachine for
# dispatch / the execution errors + sway / the pace + settle knobs it copies
# onto RoleContext, GameManager for the carrier reaction delay, and the role
# behaviors — pressure.gd / carrier.gd — for the pace + settle + timing knobs
# via RoleContext).

enum Difficulty {
	EASY = 0,     # the floor — well-late reads, swimmy blade, commits hard to stale reads
	NORMAL = 1,   # clearly beatable — laggier reads, trailing blade, slower cadence
	HARD = 2,     # the ceiling — "strong but human", a light humanising touch only
}

# How long (seconds) the bot keeps treating the previous carrier as the carrier
# after the puck actually changes hands — i.e. its reaction time to a discrete
# possession event (pass released, reception, strip). Consumed globally by
# GameManager, which debounces the carrier signal on the shared AI snapshot.
# Positions stay real-time and self-possession is instant; 0.0 = perfect
# (frame-tick) reaction. Tick-independent (a seconds countdown).
var carrier_reaction_delay_s: float

# Full-dispatch cadence: physics ticks between decision re-evaluations during
# non-press states (press states always run full-rate). Higher = laggier reads.
# Tick-denominated — tuned for 120 Hz (see tick-rate note above).
var dispatch_period_ticks: int

# Execution error on SHOT releases (metres on the 2 m aim arm; ONE uniform ±
# sample per release, held through the windup). ≈ error / 2 m aim arm in
# radians; the same value feeds the shot-aim entry budget and the shot score's
# required-window inset (RoleContext.self_aim_spread_rad), so a wobblier hand
# also shoots more selectively. THE scoring dial per tier. Tick-independent.
var shot_aim_error_m: float

# Execution error on PASS releases (and the dump), same per-release sampling.
# Deliberately much smaller than shot error at the lower tiers: bots keep
# completing passes, they just stop burying everything. Tick-independent.
var pass_aim_error_m: float

# Motor timing variance on the SHOT release (seconds). Each shot samples a
# late-release hold in [0, this]; HALF of it (the expected lateness) is
# budgeted into the goalie's tracking time in the carrier's own shot evals,
# so a thin window is scored at its median release — still attempted, and
# converted only when the sampled delay lands early enough. 0.0 =
# tick-perfect release. The "lateral doorstep beats stop being automatic
# (but stay attempted)" lever. Tick-independent.
var shot_timing_error_s: float

# Natural stickhandling sway amplitude (metres, lateral on the carry cursor).
# A smooth ~1–1.5 Hz oscillation with per-bot RNG rhythm/amplitude wander —
# the organic dangle texture while carrying. Feel-only (CARRY deliberation;
# never active during a windup or release). 0.0 = rail-steady carry.
var carry_sway_m: float

# How long (seconds) after gaining possession the carrier may only CARRY
# before any SHOOT / PASS / DUMP commit is allowed — the "settle the puck
# before you can move it" beat. 0.0 = today's instant release. Consumed by
# AIRoleCarrier via RoleContext.carry_settle_delay_s. Tick-independent.
var carry_settle_delay_s: float

# PACE: extra metres the on-puck PRESSURE defender drops its cut-off line back
# toward its own net (beyond the one-stick-length baseline). 0.0 = today's tight
# gap. Bigger = more time/space for the carrier. Distance, tick-independent.
var pursuit_standoff_m: float

# PACE: multiplier on the bot's own pass launch speed (passes only, not shots).
# Retired at 1.0 for every tier — scaling below 1.0 under-delivers the solved
# receiver-relative arrival speed and passes die short (see the doc block).
var pass_speed_scale: float

# PACE: how hard the on-puck pressurer hunts body checks. 1.0 = today; 0.0 =
# never commits a check (pure containment). Unitless.
var check_aggression: float

# PACE: multiplier on the backline's defensive anticipation lead. 1.0 = today;
# lower = defenders sit a step behind the play. Unitless.
var defensive_anticipation_scale: float

# COGNITION: exploit the moving goalie (across-the-grain aim + the unsettled
# re-square race in pass/one-timer EV). False = models the goalie as always set.
var reads_goalie_motion: bool

# COGNITION: value a developing play (staging finisher / opening outlet) and
# hold the puck for it. False = plays only what exists right now.
var holds_for_developing_feeds: bool

# COGNITION: angle the carrier-chase intercept to the inside lane, forcing the
# carrier to the boards. False = straight-line chase, cutbacks work.
var angles_the_chase: bool

# COGNITION: the rush gap defender (CONTAIN) reads the carrier's passing
# options and splits toward an uncovered receiver's feed lane — the 2-on-1
# "play the pass" doctrine. False = it retreats purely on the carrier→net
# line, conceding the odd-man cross-crease feed.
var plays_rush_pass_lanes: bool


func _init(p_carrier_reaction_delay_s: float,
		p_dispatch_period_ticks: int,
		p_shot_aim_error_m: float, p_pass_aim_error_m: float,
		p_shot_timing_error_s: float, p_carry_sway_m: float,
		p_carry_settle_delay_s: float,
		p_pursuit_standoff_m: float, p_pass_speed_scale: float,
		p_check_aggression: float, p_defensive_anticipation_scale: float,
		p_reads_goalie_motion: bool, p_holds_for_developing_feeds: bool,
		p_angles_the_chase: bool, p_plays_rush_pass_lanes: bool) -> void:
	carrier_reaction_delay_s = p_carrier_reaction_delay_s
	dispatch_period_ticks = p_dispatch_period_ticks
	shot_aim_error_m = p_shot_aim_error_m
	pass_aim_error_m = p_pass_aim_error_m
	shot_timing_error_s = p_shot_timing_error_s
	carry_sway_m = p_carry_sway_m
	carry_settle_delay_s = p_carry_settle_delay_s
	pursuit_standoff_m = p_pursuit_standoff_m
	pass_speed_scale = p_pass_speed_scale
	check_aggression = p_check_aggression
	defensive_anticipation_scale = p_defensive_anticipation_scale
	reads_goalie_motion = p_reads_goalie_motion
	holds_for_developing_feeds = p_holds_for_developing_feeds
	angles_the_chase = p_angles_the_chase
	plays_rush_pass_lanes = p_plays_rush_pass_lanes


# Hard ≈ today's bot, with a light humanising pass so it reads as a very strong
# human rather than a frame-perfect robot: a short ~50 ms reaction to possession
# changes (elite-but-not-instant). Its blade aims at its real Hands speed like
# every bot now (no per-tier slew), so a Hard bot's precision rides its build.
# Dispatch at PHYSICS_TICK/60 = 2 ticks matches the engine baseline cadence. Tune
# carrier_reaction_delay UP if it matches passes too readily. Execution error is
# the pre-split flat value on both releases (0.02 m ≈ ±0.6° per release —
# spreads the identical corner snipe into goals/saves/misses without ever
# reading as a botched shot). Release timing slop 0.10 s — an elite hand, but
# no longer tick-perfect: the doorstep lateral beat is still hunted (scored
# at the median ~0.05 s-late release), but a window in the ~0.05–0.10 s band
# is a coin flip decided by the sampled delay — the goalie robs the late
# draws — and only genuinely fat windows still convert every time. A subtle
# 0.08 m carry sway keeps the hands alive without costing control. No settle
# beat — Hard releases the tick the compete says fire. Pace knobs all at
# their no-op baseline (standoff 0.0, pass scale 1.0,
# check aggression 1.0, anticipation 1.0) — Hard keeps today's tight
# forecheck, full puck pace, hit-hunting, and anticipating backline. All
# cognition gates open: Hard reads the moving goalie, holds for developing
# plays, angles its chase, and plays the pass on odd-man rushes — the full
# hockey IQ.
static func hard() -> BotSkillProfile:
	return BotSkillProfile.new(0.05, 2, 0.02, 0.02, 0.10, 0.08, 0.0,
			0.0, 1.0, 1.0, 1.0,
			true, true, true, true)


# Normal is the beatable tier, pushed firmly off the Hard ceiling so the gap
# reads consistently in play: a ~220 ms reaction to possession changes (human-
# or-slower — it recognises a pass / turnover a clear beat late, no longer
# matching one-timers) and a slower decision cadence (6 ticks = a third of
# Hard's re-decide rate, ~50 ms). Tune carrier_reaction_delay DOWN toward 0.18 if it
# feels a step slow rather than beatable. (Aim speed is the bot's real Hands
# blade speed now — give Normal bots a lower-Hands build if their shots feel too
# sharp, rather than an artificial slew.)
#
# Finish: shot error 0.06 m (≈ ±1.7° per release — ~±0.35 m of spread at the
# net from a 12 m look, so a well-picked corner becomes goals AND saves AND the
# odd wide one, and the score's spread budget stops the from-range snipes
# entirely); pass error stays near-Hard at 0.03 m so the passing game keeps
# connecting. Release timing slop 0.16 s — Normal still tries the tight
# plays but a set goalie regularly wins the late draws. Carry sway 0.14 m: a visibly
# loose, human dangle. Settle beat 0.30 s — the puck visibly arrives on the
# tape before the next play starts, and pressuring a fresh carrier is a real
# play now. Tune shot error first when Normal's scoring is off: it's the dial
# that moves goals without making the bots look drunk.
#
# Pace: defenders sag ~1.5 m off the cut-off line, lead the play ~60% as far,
# and hit-hunting is dialed back (check_aggression 0.65 → only the harder hits
# commit). Passes launch at the full solved receiver-relative pace (the old
# 85% reduction under-delivered the arrival solve and passes died short). A
# human gets a beat of time and the play develops more readably — the
# difference felt every possession. The precision knobs above and these pace
# knobs are INDEPENDENT dials: if Normal plays like a pushover, raise the
# precision knobs back toward Hard (sharper hands/reads) and let these pace
# knobs keep it beatable; if it still feels superhuman, soften the pace knobs
# further (standoff UP, anticipation / aggression DOWN) before touching
# precision.
#
# Cognition: goalie-motion BLIND — Normal doesn't shoot across the grain or
# time feeds to catch the keeper mid-slide, which cuts its scoring through
# hockey IQ rather than more wobble (so it never looks drunk, just ordinary).
# It still holds for developing plays, angles its chase, and plays the pass
# on odd-man rushes (youth-hockey fundamentals) — a competent league player,
# not a student of the game.
static func normal() -> BotSkillProfile:
	return BotSkillProfile.new(0.22, 6, 0.06, 0.03, 0.16, 0.14, 0.30,
			1.5, 1.0, 0.65, 0.6,
			false, true, true, true)


# Easy is the newcomer floor: a ~340 ms reaction to possession changes (it
# reacts to a pass a beat and a half late — visibly human-slow) and a slow
# decision cadence (9 ticks ≈ 75 ms)
# so it commits hard to a stale read and can be dragged out of position. Still
# plays positionally and shoots / passes — a real but soft opponent, not a
# stationary one. First-pass numbers — tune carrier_reaction_delay against play,
# or hand Easy bots a lower-Hands build for genuinely softer aim, if a newcomer
# still can't string possessions together.
#
# Finish: shot error 0.11 m (≈ ±3.2° per release — ~±0.65 m of net-plane
# spread from 12 m, so even good looks routinely find the goalie or the glass;
# the spread budget means Easy only pulls the trigger in tight or on a
# genuinely gaping hole, and even those aren't automatic); pass error 0.045 m
# keeps tape-to-tape mostly connecting with the occasional honest bobble.
# Release timing slop 0.24 s — Easy telegraphs and fires a beat late. Carry
# sway 0.22 m — the loose, swimmy handle a newcomer reads instantly. Settle
# beat 0.55 s — a newcomer can watch an Easy bot receive, gather, and THEN
# decide, and closing on a fresh carrier reliably forces the turnover.
#
# Pace: defenders sag ~3 m off (lots of room to carry and look up), barely lead
# the play (anticipation 0.2 → a step behind), and bots NEVER hunt body checks
# (check_aggression 0.0 → pure containment, no getting lined up). Passes launch
# at the full solved receiver-relative pace — the old 70% reduction just
# starved them short (missed passes, not readable ones). Low-energy across the
# board, which is most of what makes Easy feel easy.
#
# Cognition: all gates closed — Easy shoots at where the goalie IS, plays
# only what's in front of it (no holding for a staging finisher), chases the
# carrier in a straight line (a newcomer's cutback to the middle genuinely
# works), and retreats on the carrier line on odd-man rushes (the glory
# cross-crease 2-on-1 feed connects). Beginner hockey IQ to match the
# beginner hands.
static func easy() -> BotSkillProfile:
	return BotSkillProfile.new(0.34, 9, 0.11, 0.045, 0.24, 0.22, 0.55,
			3.0, 1.0, 0.0, 0.2,
			false, false, false, false)


static func for_difficulty(difficulty: int) -> BotSkillProfile:
	match difficulty:
		Difficulty.EASY:
			return easy()
		Difficulty.NORMAL:
			return normal()
		_:
			return hard()
