class_name GoalieSkillProfile
extends RefCounted

# Per-difficulty bundle of goalie tuning knobs — the sibling of BotSkillProfile,
# for the AI goalie instead of the AI skaters. Pure domain (no engine APIs, no
# RNG) so it stays unit-testable and replay-safe. GoalieController.setup() reads
# a profile and writes these onto its @exports before building its cached rule
# configs; HARD leaves every value at the controller's authored default, so Hard
# is *exactly* today's goalie by construction and carries zero regression risk.
#
# ── Why these knobs, and which are deliberately ABSENT ───────────────────────
# Normal must play like a LESSER goalie, not a dumb one — every lever here is a
# trait a real weaker goalie actually has, so Normal still reads as a goalie:
#   • arm_reaction_delay_s   — glove/blocker read latency. Higher → the arms
#     start later, so top-corner and quick-release shots beat him more.
#   • cross_crease_react_delay_s — back-door read latency. Higher → he loses the
#     cross-crease race more readily (the 2-on-1 / royal-road one-timer).
#   • poke_radius_m          — stick-strip reach on a carried puck. Lower → dekes
#     and in-tight puckhandling get through more often.
#   • screen_max_extra_delay_s — extra read latency when screened. Higher → point
#     shots through traffic beat him more.
#   • move_read_max_delay_s  — extra read latency when caught moving / unset.
#     Higher → he is punished harder for shots taken while he is still sliding.
#
# DELIBERATELY NOT HERE: reaction_delay (the leg-drop read) and t_push_speed (the
# lateral slide speed). AIActionScoring mirrors BOTH as compile-time constants
# (GOALIE_REACTION_DELAY_S, GOALIE_MAX_LATERAL_SPEED_MPS = GameRules defaults) so
# the bots' shot/pass scoring predicts the live goalie's position. Varying either
# per-difficulty here WITHOUT threading the same value into AIActionScoring would
# desync the bots' read on Normal (they'd rate the goalie as covering more than
# it does). The knobs above are not in the bot's model, so they vary freely and
# still make Normal clearly beatable. Slowing the base read / lateral speed for
# Normal is a follow-up that must also parameterise the AI scorer.
#
# To add a tier: add a Difficulty enum value, a factory, and a for_difficulty arm.
# To add a knob: add a field + _init param, set it in both factories, and consume
# it in GoalieController._apply_skill_profile (confirm it is not an AI-mirrored
# value first).

enum Difficulty {
	NORMAL = 0,   # clearly beatable — laggier reads, less active stick
	HARD = 1,     # the ceiling — exactly today's tuned goalie
}

# Glove/blocker read latency (s) before the elevated-shot reach starts.
var arm_reaction_delay_s: float
# Back-door read latency (s) before the standing cross-crease drive engages.
var cross_crease_react_delay_s: float
# Stick-strip reach (m): the goalie pokes a carried puck within this radius.
var poke_radius_m: float
# Extra read latency (s) for a fully-screened shot.
var screen_max_extra_delay_s: float
# Extra read latency (s) when fully unset / caught moving.
var move_read_max_delay_s: float


func _init(p_arm_reaction_delay_s: float, p_cross_crease_react_delay_s: float,
		p_poke_radius_m: float, p_screen_max_extra_delay_s: float,
		p_move_read_max_delay_s: float) -> void:
	arm_reaction_delay_s = p_arm_reaction_delay_s
	cross_crease_react_delay_s = p_cross_crease_react_delay_s
	poke_radius_m = p_poke_radius_m
	screen_max_extra_delay_s = p_screen_max_extra_delay_s
	move_read_max_delay_s = p_move_read_max_delay_s


# Hard == the GoalieController @export defaults verbatim. Keep these in sync with
# the controller so applying Hard is a true no-op (the ceiling we've tuned).
static func hard() -> GoalieSkillProfile:
	return GoalieSkillProfile.new(0.18, 0.12, 0.25, 0.15, 0.12)


# Normal is the beatable tier: arms and the back-door read start a clear beat
# late (more corner and cross-crease goals), the stick strips less (dekes get
# through), and screened / caught-moving shots punish him harder. First-pass
# numbers — tune against the bots on a 2-on-1 and an in-tight deke.
static func normal() -> GoalieSkillProfile:
	return GoalieSkillProfile.new(0.28, 0.20, 0.16, 0.24, 0.20)


static func for_difficulty(difficulty: int) -> GoalieSkillProfile:
	match difficulty:
		Difficulty.NORMAL:
			return normal()
		_:
			return hard()
