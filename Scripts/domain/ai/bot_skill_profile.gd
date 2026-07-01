class_name BotSkillProfile
extends RefCounted

# Per-difficulty bundle of DETERMINISTIC bot-skill knobs. Pure domain (no
# engine APIs, no RNG) so it stays unit-testable and replay-safe — the whole
# point of these levers is that the same situation produces the same bot
# behaviour at a given difficulty, every time.
#
# ── Why these four knobs ──────────────────────────────────────────────────────
# The "perfect bot" baseline was perfect in two separable ways:
#   1. Perfect EXECUTION — the blade snapped to the ideal aim point every tick
#      (mouse_max_speed effectively uncapped, lerp = 1.0), so every shot went
#      to the exact same corner and dekes were matched on the frame.
#   2. Perfect REACTION — the agent recognised DISCRETE events (a pass
#      released, the puck changing hands) the same physics tick they happened.
# Both are dialled back here without a single random number:
#   • mouse_max_speed_m_s — caps blade slew, so the blade TRAILS a moving aim
#     point. Because the goalie / defenders are moving, a capped blade releases
#     mid-converge and the actual release point varies WITH THE GEOMETRY — that
#     is what kills "every shot to the same spot" deterministically.
#   • mouse_lerp_factor — a mild second-stage tracking lag on top of the slew
#     cap (see SkaterAgent), so aim transitions read as a swing, not a snap.
#   • carrier_reaction_delay_s — how long the bot keeps acting on its PRIOR
#     read of who controls the puck before recognising a possession change.
#     This is the human "you can't react to a pass within a tick" lever. It is
#     applied ONLY to the discrete carrier signal — the bot still tracks every
#     position/velocity in REAL TIME (so it aims at the puck's actual spot, not
#     a stale one), and it knows its OWN possession instantly. See GameManager.
#   • dispatch_period_ticks — how often the full decision dispatch re-runs;
#     a slower cadence makes the bot commit to a read longer before adjusting.
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
#     not shots). Lower → the puck travels slower tape-to-tape, so the offensive
#     play develops in front of the human and is readable / interceptable rather
#     than zipping around. 1.0 = today's pace. Consumed via AIActionScoring
#     .pass_launch_speed at the carrier's own-pass sites (RoleContext carries it).
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
# defensive_anticipation_scale concede SPACE (positioning), pass_speed_scale
# concedes TEMPO (puck speed), check_aggression concedes THREAT (physicality).
#
# The GOALIE is intentionally NOT represented here — it stays consistent across
# difficulties (and the skater AI's goalie-slide prediction in AIActionScoring
# stays in lockstep with the live goalie regardless of tier).
#
# ── Tick-rate note (these knobs are tuned for PHYSICS_TICK = 120 Hz) ──────────
# mouse_max_speed_m_s (m/s) and carrier_reaction_delay_s (seconds) are
# tick-independent — they convert to a per-tick step / countdown against the
# real tick rate. dispatch_period_ticks and mouse_lerp_factor are NOT: a tick
# count and a per-tick exponential lerp both change meaning with the tick rate.
# They are calibrated against the current 120 Hz sim. If the sim tick rate ever
# changes, rescale them to preserve wall-clock feel: a dispatch period scales
# linearly with the rate, and a lerp factor f maps so that (1 - f') ^ new_rate
# == (1 - f) ^ old_rate (equal residual per second).
#
# To add a tier: add a Difficulty enum value, a factory, and a for_difficulty
# arm. To add a knob: add a field + _init param, set it in ALL THREE factories,
# and consume it where the relevant value is read (SkaterAgent for lerp,
# SkaterAgentStateMachine for max_speed / dispatch / the pace knobs it copies
# onto RoleContext, GameManager for the carrier reaction delay, and the role
# behaviors — pressure.gd / carrier.gd — for the pace knobs via RoleContext).

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

# Mouse-world lerp factor passed to SkaterAgent. 1.0 = snap (no extra lag).
# Per-tick exponential — tuned for 120 Hz (see tick-rate note above).
var mouse_lerp_factor: float

# Blade-slew cap (m/s) passed to SkaterAgentStateMachine. Caps the per-tick
# mouse step; the agent derives its arc-rate and pre-aim timeout from it.
# Tick-independent (converts to a per-tick step against the live delta).
var mouse_max_speed_m_s: float

# Full-dispatch cadence: physics ticks between decision re-evaluations during
# non-press states (press states always run full-rate). Higher = laggier reads.
# Tick-denominated — tuned for 120 Hz (see tick-rate note above).
var dispatch_period_ticks: int

# PACE: extra metres the on-puck PRESSURE defender drops its cut-off line back
# toward its own net (beyond the one-stick-length baseline). 0.0 = today's tight
# gap. Bigger = more time/space for the carrier. Distance, tick-independent.
var pursuit_standoff_m: float

# PACE: multiplier on the bot's own pass launch speed (passes only, not shots).
# 1.0 = today's pace; lower = slower puck around the zone, more readable. Unitless.
var pass_speed_scale: float

# PACE: how hard the on-puck pressurer hunts body checks. 1.0 = today; 0.0 =
# never commits a check (pure containment). Unitless.
var check_aggression: float

# PACE: multiplier on the backline's defensive anticipation lead. 1.0 = today;
# lower = defenders sit a step behind the play. Unitless.
var defensive_anticipation_scale: float


func _init(p_carrier_reaction_delay_s: float, p_mouse_lerp_factor: float,
		p_mouse_max_speed_m_s: float, p_dispatch_period_ticks: int,
		p_pursuit_standoff_m: float, p_pass_speed_scale: float,
		p_check_aggression: float, p_defensive_anticipation_scale: float) -> void:
	carrier_reaction_delay_s = p_carrier_reaction_delay_s
	mouse_lerp_factor = p_mouse_lerp_factor
	mouse_max_speed_m_s = p_mouse_max_speed_m_s
	dispatch_period_ticks = p_dispatch_period_ticks
	pursuit_standoff_m = p_pursuit_standoff_m
	pass_speed_scale = p_pass_speed_scale
	check_aggression = p_check_aggression
	defensive_anticipation_scale = p_defensive_anticipation_scale


# Hard ≈ today's bot, with a light humanising pass so it reads as a very strong
# human rather than a frame-perfect robot: a short ~50 ms reaction to possession
# changes (elite-but-not-instant) and a blade that can no longer teleport, so
# snipes spray slightly by approach geometry. Dispatch at PHYSICS_TICK/60 = 2
# ticks matches the engine baseline cadence. Tune mouse_max_speed DOWN toward
# Normal if Hard still feels robotic; carrier_reaction_delay UP if it still
# matches passes too readily. Pace knobs all at their no-op baseline (standoff
# 0.0, pass scale 1.0, check aggression 1.0, anticipation 1.0) — Hard keeps
# today's tight forecheck, full puck pace, hit-hunting, and anticipating backline.
static func hard() -> BotSkillProfile:
	return BotSkillProfile.new(0.05, 0.85, 30.0, 2, 0.0, 1.0, 1.0, 1.0)


# Normal is the beatable tier, pushed firmly off the Hard ceiling so the gap
# reads consistently in play: a ~220 ms reaction to possession changes (human-
# or-slower — it recognises a pass / turnover a clear beat late, no longer
# matching one-timers), a more trailing blade (lerp 0.5, slew 11) so snipes
# spray by approach and dangles are slower to strip from, and a slower decision
# cadence (6 ticks = a third of Hard's re-decide rate, ~50 ms). Tune
# carrier_reaction_delay DOWN toward 0.18 if it feels a step slow rather than
# beatable; mouse_max_speed UP toward 14 if its shots feel too wild.
#
# Pace: defenders sag ~1.5 m off the cut-off line, lead the play ~60% as far,
# the puck moves at 85% pace, and hit-hunting is dialed back (check_aggression
# 0.65 → only the harder hits commit). A human gets a beat of time and the play
# develops more readably — the difference felt every possession. The precision
# knobs above and these pace knobs are INDEPENDENT dials: if Normal plays like a
# pushover, raise the precision knobs back toward Hard (sharper hands/reads) and
# let these pace knobs keep it beatable; if it still feels superhuman, soften the
# pace knobs further (standoff UP, pass scale / anticipation / aggression DOWN)
# before touching precision.
static func normal() -> BotSkillProfile:
	return BotSkillProfile.new(0.22, 0.5, 11.0, 6, 1.5, 0.85, 0.65, 0.6)


# Easy is the newcomer floor: a ~340 ms reaction to possession changes (it
# reacts to a pass a beat and a half late — visibly human-slow), a swimmy blade
# (lerp 0.38, slew 8) so its shots are imprecise and its carried puck is easy to
# poke off, and a slow decision cadence (9 ticks ≈ 75 ms) so it commits hard to a
# stale read and can be dragged out of position. Still plays positionally and
# shoots / passes — a real but soft opponent, not a stationary one. First-pass
# numbers — tune carrier_reaction_delay / mouse_max_speed against play if a
# newcomer still can't string possessions together.
#
# Pace: defenders sag ~3 m off (lots of room to carry and look up), barely lead
# the play (anticipation 0.2 → a step behind), the puck moves at 70% pace (slow,
# readable, easy to pick off), and bots NEVER hunt body checks (check_aggression
# 0.0 → pure containment, no getting lined up). Low-energy across the board,
# which is most of what makes Easy feel easy.
static func easy() -> BotSkillProfile:
	return BotSkillProfile.new(0.34, 0.38, 8.0, 9, 3.0, 0.70, 0.0, 0.2)


static func for_difficulty(difficulty: int) -> BotSkillProfile:
	match difficulty:
		Difficulty.EASY:
			return easy()
		Difficulty.NORMAL:
			return normal()
		_:
			return hard()
