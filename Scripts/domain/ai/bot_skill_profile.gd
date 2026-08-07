class_name BotSkillProfile
extends RefCounted

# Per-difficulty bundle of deterministic bot-skill knobs. Pure domain (no engine
# APIs, no RNG in this file) so it stays unit-testable and replay-safe.
#
# Three independent axes — see Scripts/domain/ai/CLAUDE.md for the rules that
# keep them honest:
#   PRECISION  how sharp the bot is        (reaction, cadence, execution error)
#   PACE       how much time/space a human gets (standoff, anticipation, checking)
#   COGNITION  which reads exist in its model at all (the bool gates)
#
# The only RNG is per-release execution sampling (hands, never decision dice),
# seeded per bot. Aim slew is NOT a tier knob — a bot slews its aim cursor at its
# real Hands blade speed (AISkaterCaps.blade_speed), so execution difficulty
# rides the bot's attribute build.
#
# The GOALIE is deliberately not represented here — it stays consistent across
# difficulties.
#
# Tick rate: seconds-denominated knobs are tick-independent. dispatch_period_ticks
# is NOT — it is calibrated against the 120 Hz sim and must be rescaled linearly
# if the tick rate ever changes.
#
# To add a tier: add a Difficulty value, a factory, and a for_difficulty arm.
# To add a knob: add a field + _init param, set it in ALL THREE factories, and
# consume it where it is read — SkaterAgentStateMachine (dispatch, execution
# error, and the knobs it copies onto RoleContext), GameManager (carrier reaction
# delay), pressure.gd / carrier.gd (via RoleContext).

enum Difficulty {
	EASY = 0,     # the floor — well-late reads, swimmy blade, commits hard to stale reads
	NORMAL = 1,   # clearly beatable — laggier reads, trailing blade, slower cadence
	HARD = 2,     # the ceiling — "strong but human", a light humanising touch only
}

# How long the bot keeps treating the previous carrier as the carrier after the
# puck changes hands — its reaction time to a discrete possession event. Applied
# only to the carrier signal: positions stay real-time and self-possession is
# instant. Debounced globally by GameManager on the shared AI snapshot.
var carrier_reaction_delay_s: float

# Physics ticks between full decision re-evaluations during non-press states
# (press states always run full-rate). Higher = laggier reads.
var dispatch_period_ticks: int

# Execution error on SHOT releases (radians of release-direction error; one
# uniform ± sample per release, held through the windup so the blade sweeps
# smoothly to a slightly wrong spot). THE conversion dial per tier — the
# shot-outcome sim (tests/unit/ai/test_shot_sim.gd) measures goals-per-shot
# falling smoothly and monotonically with it: 0.010 → 87%, 0.030 → 62%,
# 0.040 → 53%, 0.050 → 47%, 0.075 → 34%.
#
# Two things make it the right dial rather than a way of making bots look drunk,
# and both have edges worth knowing:
#
# The bot is SELF-HONEST — the same value feeds the score's required-window inset
# (RoleContext.self_aim_spread_rad), so it aims a window it actually fits and its
# misses land on the GOALIE. Posts+wides stay ~1% of shots up to ~0.05 and only
# then climb (0.075 → 6%, 0.090 → 12%). Past that edge the tier stops looking
# beaten and starts looking incompetent. Feeding the score a SMALLER spread than
# the hand executes was measured and is not the lever it sounds like: goals-per-
# shot barely moves (62% → 64%) because the extra wobble only walks the aim onto
# the pipe — 14% posts at believed 0.010 / executed 0.030.
#
# The selectivity feedback is REAL BUT WEAK. A wider believed spread demands a
# wider window, so in principle the bot also shoots less; measured on the sim's
# grid the shoot rate does not move at all from 0.010 to 0.050, because those
# spots clear the fire bar either way. It only bites on shots already near the
# bar. Selectivity is what settle_penalty_frac is for — this knob is conversion.
var shot_aim_error_rad: float

# Execution error on PASS releases and the dump, sampled the same way.
# Deliberately much smaller than shot error at the lower tiers — completed
# passes are fun to play against, every shot going in is not.
var pass_aim_error_rad: float

# Motor timing variance on the SHOT release (seconds). Each shot samples a
# late-release hold in [0, this]. Half of it (the expected lateness) is budgeted
# into the goalie's tracking time wherever the carrier scores its own shot, so a
# thin window is scored at its median release — still attempted, converted only
# when the sample lands early enough.
var shot_timing_error_s: float

# SETTLE DOUBT — how much a freshly-possessed carrier discounts its own read of
# every ACTIVE option (shoot / pass / dump) when deciding whether that option is
# worth giving the puck up for. A fraction in [0, 1): the option's value is
# handicapped by this much against its giveaway bar, so at 0.5 the bar it must
# clear is effectively doubled. Decays exp(-t / settle_penalty_tau_s) from the
# moment possession is gained.
#
# This is a SELECTIVITY dial, not a delay: an obvious play (a doorstep look, a
# wide-open outlet) out-values any raised bar and fires on the first tick, while
# a marginal one — the point shot, the feed threaded through traffic — is simply
# not worth the puck yet and gets taken only once the doubt drains. The bot
# visibly deliberates over close calls and is decisive on clear ones, which is
# the shape of a human read; a flat "may not commit for N seconds" gate produced
# the opposite (dithering on gimmes, then firing everything at once).
#
# The old flat gate is the frac → 1.0 limit of this, so nothing is lost by it.
# Reception one-timers are not gated at all — the puck never settles on the tape.
var settle_penalty_frac: float

# Seconds for the settle doubt above to fall by 1/e — how long the bot takes to
# get comfortable with the puck. ~3τ is when it is effectively gone.
var settle_penalty_tau_s: float

# PACE: extra metres the on-puck PRESSURE defender drops its cut-off line back
# toward its own net, beyond the one-stick-length baseline. Consumed in
# pressure.gd. Must stay under a stick length — see normal().
var pursuit_standoff_m: float

# PACE: multiplier on the pace this bot's passes ARRIVE at (passes only, not
# shots) — AIActionScoring.pass_launch_speed then solves the launch that delivers
# it, so a softened feed still reaches the tape and still catches a streaking
# receiver. 0.85 puts the puck on the stick at 17 m/s instead of 20.
#
# The most direct "how much time does the human get" dial there is: a 12 m feed
# at 0.85 spends 0.71 s in flight instead of 0.60 s, which is most of a stride
# for a defender reading it. And the bot is SELF-HONEST about it — every pass
# scoring site solves its lane clearance and miss probability at this same
# reduced pace, so a lower tier also stops ATTEMPTING the feeds its slower puck
# can no longer thread, rather than throwing them and getting picked.
#
# It scaled the finished LAUNCH before, which is why it sat retired at 1.0 for
# every tier — see the pass_launch_speed doc block for what that broke.
var pass_speed_scale: float

# PACE: how hard the on-puck pressurer hunts body checks. 1.0 = full hit-hunting;
# below 1.0 raises the required separating-hit impulse inversely so only the
# hardest hits commit; 0.0 = pure containment. The biggest "scary vs relaxed"
# lever — getting lined up is the most intense moment in the game. Consumed in
# AIRoleHelpers.evaluate_body_check.
var check_aggression: float

# PACE: multiplier on DEFENSIVE_ANTICIPATION_S, how far ahead a defender READS
# the other attackers when pricing what the carrier can do with them — PRESSURE's
# and FORECHECK's pass-lane set, the unassigned marker's recovery. Lower = the
# bot scores the threats where they ARE, not where they're going.
#
# It no longer moves any defender's STAND. A cover point and a gap stand ride
# their man (AIRoleHelpers.cover_threat), so leading the anchor as well would
# double-count his motion; the on-puck space concession is pursuit_standoff_m.
var defensive_anticipation_scale: float

# COGNITION: exploit a MOVING goalie — aiming back across the grain of a slide
# (AIShotAim's velocity-projected shadow) and valuing the re-square race a
# cross-seam feed wins. False = models the goalie as always set and shoots where
# he IS. The biggest single scoring cut, through cognition rather than wobble.
var reads_goalie_motion: bool

# COGNITION: value a play that doesn't exist yet — a finisher still skating to
# the back door, an outlet still opening — and protect the puck until it does
# (carrier._best_developing_feed). False = plays only what's in front of it.
var holds_for_developing_feeds: bool

# COGNITION: price a receiver's smoothed heading turn rate as catch-point
# uncertainty, so a teammate mid-cut is a riskier feed and an elite passer waits
# for them to come out of the turn. False = blind to it, chucks feeds at turning
# players. A settled receiver reads ~0 either way, so this never slows a clean
# quick feed.
var reads_receiver_commitment: bool

# COGNITION: approach an opposing carrier from the inside to force them to the
# boards (_shade_intercept_goal_side). False = straight-line chase, so a human's
# cutback to the middle works.
var angles_the_chase: bool

# COGNITION: the last man back on a rush reads the carrier's PASSING options and
# splits toward an uncovered receiver's feed lane — the 2-on-1 "play the pass,
# the goalie takes the shooter" doctrine. False = RUSH_D1 sees only the carrier
# and retreats on the carrier→net line, so the cross-crease feed connects.
var plays_rush_pass_lanes: bool

# COGNITION: shield the puck with the body — a pressured carrier pulls the puck
# off the presented forward spot to the protected side of the reachable-set seam,
# and the poke-evade moment commits a real maneuver. False = the puck stays
# presented ~2 m ahead at all times and no deke exists at all, so a newcomer's
# straight-line poke-check genuinely works.
var protects_the_puck: bool


func _init(p_carrier_reaction_delay_s: float,
		p_dispatch_period_ticks: int,
		p_shot_aim_error_rad: float, p_pass_aim_error_rad: float,
		p_shot_timing_error_s: float,
		p_settle_penalty_frac: float, p_settle_penalty_tau_s: float,
		p_pursuit_standoff_m: float, p_pass_speed_scale: float,
		p_check_aggression: float, p_defensive_anticipation_scale: float,
		p_reads_goalie_motion: bool, p_holds_for_developing_feeds: bool,
		p_angles_the_chase: bool, p_plays_rush_pass_lanes: bool,
		p_protects_the_puck: bool,
		p_reads_receiver_commitment: bool) -> void:
	carrier_reaction_delay_s = p_carrier_reaction_delay_s
	dispatch_period_ticks = p_dispatch_period_ticks
	shot_aim_error_rad = p_shot_aim_error_rad
	pass_aim_error_rad = p_pass_aim_error_rad
	shot_timing_error_s = p_shot_timing_error_s
	settle_penalty_frac = p_settle_penalty_frac
	settle_penalty_tau_s = p_settle_penalty_tau_s
	pursuit_standoff_m = p_pursuit_standoff_m
	pass_speed_scale = p_pass_speed_scale
	check_aggression = p_check_aggression
	defensive_anticipation_scale = p_defensive_anticipation_scale
	reads_goalie_motion = p_reads_goalie_motion
	holds_for_developing_feeds = p_holds_for_developing_feeds
	reads_receiver_commitment = p_reads_receiver_commitment
	angles_the_chase = p_angles_the_chase
	plays_rush_pass_lanes = p_plays_rush_pass_lanes
	protects_the_puck = p_protects_the_puck


# Hard reads as a very strong human rather than a frame-perfect robot: ~50 ms
# reaction, dispatch at the engine baseline cadence, a flat ±0.6° of execution
# error on both releases, and 0.10 s of release slop — so the doorstep lateral
# beat is still hunted but a window in the ~0.05–0.10 s band is a coin flip the
# goalie sometimes robs. No settle doubt, pace knobs at their no-op baseline,
# every cognition gate open.
#
# Tune carrier_reaction_delay_s UP if it matches passes too readily.
static func hard() -> BotSkillProfile:
	return BotSkillProfile.new(0.05, 2, 0.01, 0.01, 0.10, 0.0, 0.25,
			0.0, 1.0, 1.0, 1.0,
			true, true, true, true, true, true)


# Normal is the beatable tier, pushed firmly off the Hard ceiling: a ~220 ms
# reaction (it recognises a pass a clear beat late and no longer matches
# one-timers) at a third of Hard's re-decide rate. Shot error ±2.3° ≈ ±0.48 m at
# the net from 12 m, so a well-picked corner becomes goals AND saves, and the
# score's spread budget stops the from-range snipes entirely; pass error stays
# near-Hard so the passing game keeps connecting. Measured on
# the shot-outcome sim it buries 53% of what it takes against 87% for Hard, with
# the misses landing on the keeper — posts ~1%, wides ~0%.
#
# Passes ARRIVE at 0.85 pace (17 m/s on the tape rather than 20), which is the
# tier's readability dial: an extra ~0.1 s of flight on a routine feed is most of
# a stride for the human reading it, and the bot prices its own lanes at that
# same pace so it also stops trying the ones the slower puck can't thread.
#
# The 0.60 settle doubt is the tier's INDECISION dial: for the first beat of a
# possession an option must be worth ~2.5× its giveaway bar to be worth the puck
# — a slot look or a clean outlet still goes at once, while the point shot and
# the feed threaded past two sticks wait for the doubt to drain (τ = 0.30 s, so
# ~1.25× by 0.3 s and gone by ~0.9 s). This is most of what stops Normal reading
# as "Hard with extra lag": it no longer finds EVERY pass on the first touch, and
# pressuring a fresh carrier off a marginal outlet is a real play.
#
# Cognition gates are ALL open, same as Hard — the two tiers are deliberately the
# same PLAYER separated only by continuous tuning, so the gap reads as "sharper"
# rather than "knows moves the other doesn't". Easy is where the gates close.
#
# pursuit_standoff_m must stay well under a stick length: at 1.5 m the pressurer
# sits permanently outside blade reach and can never poke, which playtests read
# as "bots never challenge". At 0.75 the carrier's own motion brings the puck
# transiently into contest range while the human still gets his beat.
#
# Tuning order: shot error moves goals without making bots look drunk, so reach
# for it first. If Normal plays like a pushover, raise the precision knobs back
# toward Hard and let the pace knobs keep it beatable; if it still feels
# superhuman, soften pace (standoff UP, anticipation / aggression DOWN) before
# touching precision. If it makes plays a human wouldn't SEE (rather than plays
# it executes too well), that is the settle doubt — raise the frac for a higher
# bar, the τ for a longer one.
static func normal() -> BotSkillProfile:
	return BotSkillProfile.new(0.22, 6, 0.04, 0.015, 0.16, 0.60, 0.30,
			0.75, 0.85, 0.65, 0.6,
			true, true, true, true, true, true)


# Easy is the newcomer floor: a ~340 ms reaction (visibly human-slow) and a slow
# cadence, so it commits hard to a stale read and can be dragged out of position.
# Still plays positionally and shoots / passes — a real but soft opponent, not a
# stationary one. Shot error ±3.2° ≈ ±0.65 m from 12 m, so even good looks
# routinely find the goalie or the glass and the spread budget keeps it from
# pulling the trigger except in tight or on a gaping hole. The 0.85 settle doubt
# (τ = 0.55 s) means nothing short of a gimme is worth the puck for the first
# half-second and the bar is still noticeably up a second later — a newcomer
# watches it receive, gather, and THEN decide, so closing on a fresh carrier
# reliably forces the turnover.
#
# Pace is low-energy across the board — defenders sag ~3 m, barely lead the play,
# never hunt body checks, and put the puck on a teammate's tape at 0.75 pace
# (15 m/s), a floaty feed a newcomer has time to step in front of — which is most
# of what makes Easy feel easy.
#
# Cognition: all gates closed, beginner hockey IQ to match the beginner hands.
# The cutback to the middle, the straight-line poke-check, and the cross-crease
# 2-on-1 glory feed all genuinely work against it.
static func easy() -> BotSkillProfile:
	return BotSkillProfile.new(0.34, 9, 0.055, 0.0225, 0.24, 0.85, 0.55,
			3.0, 0.75, 0.0, 0.2,
			false, false, false, false, false, false)


static func for_difficulty(difficulty: int) -> BotSkillProfile:
	match difficulty:
		Difficulty.EASY:
			return easy()
		Difficulty.NORMAL:
			return normal()
		_:
			return hard()
