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
# arm. To add a knob: add a field + _init param, set it in both factories, and
# consume it where the relevant const used to be read (SkaterAgent for lerp,
# SkaterAgentStateMachine for max_speed / dispatch, GameManager for the carrier
# reaction delay).

enum Difficulty {
	NORMAL = 0,   # clearly beatable — laggier reads, trailing blade, slower cadence
	HARD = 1,     # the ceiling — "strong but human", a light humanising touch only
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


func _init(p_carrier_reaction_delay_s: float, p_mouse_lerp_factor: float,
		p_mouse_max_speed_m_s: float, p_dispatch_period_ticks: int) -> void:
	carrier_reaction_delay_s = p_carrier_reaction_delay_s
	mouse_lerp_factor = p_mouse_lerp_factor
	mouse_max_speed_m_s = p_mouse_max_speed_m_s
	dispatch_period_ticks = p_dispatch_period_ticks


# Hard ≈ today's bot, with a light humanising pass so it reads as a very strong
# human rather than a frame-perfect robot: a short ~50 ms reaction to possession
# changes (elite-but-not-instant) and a blade that can no longer teleport, so
# snipes spray slightly by approach geometry. Dispatch at PHYSICS_TICK/60 = 2
# ticks matches the engine baseline cadence. Tune mouse_max_speed DOWN toward
# Normal if Hard still feels robotic; carrier_reaction_delay UP if it still
# matches passes too readily.
static func hard() -> BotSkillProfile:
	return BotSkillProfile.new(0.05, 0.85, 30.0, 2)


# Normal is the beatable tier: a ~150 ms reaction to possession changes (it
# recognises a pass / turnover a clear beat late), a noticeably trailing blade,
# and a slower decision cadence (4 ticks = half Hard's re-decide rate). Tune
# carrier_reaction_delay UP toward 0.22 to make it more forgiving; DOWN toward
# 0.10 if it feels a step slow rather than beatable.
static func normal() -> BotSkillProfile:
	return BotSkillProfile.new(0.15, 0.6, 14.0, 4)


static func for_difficulty(difficulty: int) -> BotSkillProfile:
	match difficulty:
		Difficulty.NORMAL:
			return normal()
		_:
			return hard()
