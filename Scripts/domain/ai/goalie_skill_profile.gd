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
# A lesser goalie must play like a WEAKER goalie, not a dumb one — every lever
# here is a trait a real weaker goalie actually has, so every tier still reads as
# a goalie (tracks the play, squares up, drops butterfly; he just gives up the
# net and can't rob you). Two groups:
#
# Read-latency / stick group (Normal already eased these; Easy eases them more):
#   • arm_reaction_delay_s   — glove/blocker read latency. Higher → the arms
#     start later, so top-corner and quick-release shots beat him more.
#   • cross_crease_react_delay_s — back-door read latency. Higher → he loses the
#     cross-crease race more readily (the 2-on-1 / royal-road one-timer).
#   • poke_radius_m          — stick-strip reach on a carried puck. Lower → dekes
#     and in-tight puckhandling get through more often.
#   • screen_max_extra_delay_s — CAP (s) on the grounded screen-occlusion pickup
#     delay (how long a body hides the puck from the goalie — see GoalieBehavior
#     Rules.screen_occlusion_delay). Higher → point shots through traffic beat him
#     more (a weaker goalie loses a screened puck for longer).
#   • move_read_max_delay_s  — extra read latency when caught moving / unset.
#     Higher → he is punished harder for shots taken while he is still sliding.
#
# Positioning / save group (the "give up the net" levers — added so the scale is
# a real ladder, not just reaction latency):
#   • depth_aggressive_m / depth_base_m — challenge depth on the depth chart.
#     Lower → the goalie sits DEEPER, cutting less angle, so there's more net to
#     shoot at from everywhere. The strongest "beatable but realistic" lever — a
#     positionally-passive goalie giving you the net.
#   • glove_react_max_speed_mps / blocker_react_max_speed_mps — arm reach speed.
#     Lower → he can't pull the corner back, so corner shots score.
#   • pad_toe_out_butterfly_deg — rebound steering. Lower → saves kick back into
#     the slot instead of to the corner, so second chances appear.
#   • lateral_accel_mps2 — how fast a lateral push ramps up (NOT the top speed).
#     Lower → he's slow to get moving side-to-side, beaten across on quick plays.
#
# DELIBERATELY NOT HERE: reaction_delay (the leg-drop read) and t_push_speed (the
# lateral slide TOP speed). AIActionScoring mirrors BOTH as compile-time constants
# (GOALIE_REACTION_DELAY_S, GOALIE_MAX_LATERAL_SPEED_MPS = GameRules defaults) so
# the bots' shot/pass scoring predicts the live goalie's position. Varying either
# per-difficulty here WITHOUT threading the same value into AIActionScoring would
# desync the bots' read (they'd rate the goalie as covering more than it does).
# Every knob above is AI-safe: the positioning levers are read from the goalie's
# LIVE position by the scorer (depth, lateral_accel ramp) or not modelled at all
# (arm speed, rebound steering, the read latencies), so they vary freely. Slowing
# the base leg-drop read / lateral top speed is a follow-up that must also
# parameterise the AI scorer.
#
# To add a tier: add a Difficulty enum value, a factory, and a for_difficulty arm.
# To add a knob: add a field + _init param, set it in all three factories, and
# consume it in GoalieController._apply_skill_profile (confirm it is not an
# AI-mirrored value first).

enum Difficulty {
	EASY = 0,     # the floor — positionally deep, slow arms, fat rebounds, laggy reads
	NORMAL = 1,   # the middle — a fair fight, clearly softer than Hard
	HARD = 2,     # the ceiling — exactly today's tuned goalie
}

# Glove/blocker read latency (s) before the elevated-shot reach starts.
var arm_reaction_delay_s: float
# Back-door read latency (s) before the standing cross-crease drive engages.
var cross_crease_react_delay_s: float
# Stick-strip reach (m): the goalie pokes a carried puck within this radius.
var poke_radius_m: float
# Cap (s) on the grounded screen-occlusion pickup delay (worst-case time a body
# can hide the puck from the goalie before the read starts).
var screen_max_extra_delay_s: float
# Extra read latency (s) when fully unset / caught moving.
var move_read_max_delay_s: float
# Challenge depth (m) at the doorstep / mid-range on the depth chart. Lower sits
# the goalie deeper in the net, giving up shooting angle.
var depth_aggressive_m: float
var depth_base_m: float
# Glove / blocker reach speed cap (m/s) during elevated-shot saves. Lower → can't
# pull the corner back.
var glove_react_max_speed_mps: float
var blocker_react_max_speed_mps: float
# Butterfly rebound-steering pad toe-out (deg). Lower → rebounds kick to the slot.
var pad_toe_out_butterfly_deg: float
# Lateral push ramp acceleration (m/s²) — NOT the top speed. Lower → slow to get
# moving side-to-side.
var lateral_accel_mps2: float


func _init(p_arm_reaction_delay_s: float, p_cross_crease_react_delay_s: float,
		p_poke_radius_m: float, p_screen_max_extra_delay_s: float,
		p_move_read_max_delay_s: float, p_depth_aggressive_m: float,
		p_depth_base_m: float, p_glove_react_max_speed_mps: float,
		p_blocker_react_max_speed_mps: float, p_pad_toe_out_butterfly_deg: float,
		p_lateral_accel_mps2: float) -> void:
	arm_reaction_delay_s = p_arm_reaction_delay_s
	cross_crease_react_delay_s = p_cross_crease_react_delay_s
	poke_radius_m = p_poke_radius_m
	screen_max_extra_delay_s = p_screen_max_extra_delay_s
	move_read_max_delay_s = p_move_read_max_delay_s
	depth_aggressive_m = p_depth_aggressive_m
	depth_base_m = p_depth_base_m
	glove_react_max_speed_mps = p_glove_react_max_speed_mps
	blocker_react_max_speed_mps = p_blocker_react_max_speed_mps
	pad_toe_out_butterfly_deg = p_pad_toe_out_butterfly_deg
	lateral_accel_mps2 = p_lateral_accel_mps2


# Hard == the GoalieController @export defaults verbatim. Keep these in sync with
# the controller so applying Hard is a true no-op (the ceiling we've tuned).
static func hard() -> GoalieSkillProfile:
	return GoalieSkillProfile.new(0.18, 0.12, 0.25, 0.30, 0.12,
			1.75, 1.30, 5.0, 5.0, 18.0, 14.0)


# Normal is the middle tier: it keeps Hard's read knobs eased AND takes
# half-strength positioning/arm/rebound levers, so Normal↔Hard is a real gap
# rather than just reaction latency — a fair fight that's clearly softer than the
# ceiling. First-pass numbers — tune against the bots on a 2-on-1 and an in-tight
# deke.
static func normal() -> GoalieSkillProfile:
	return GoalieSkillProfile.new(0.28, 0.20, 0.16, 0.42, 0.20,
			1.45, 1.05, 4.1, 4.1, 12.0, 11.0)


# Easy is the newcomer floor: positionally deep (gives up the net), slow arms
# (can't rob the corners), fat rebounds (second chances), slow to push across,
# and a clear beat late on every read. Still tracks, squares, and drops butterfly
# — a real but weak goalie. First-pass numbers — tune against bot offense, since
# a skilled human scores on any tier and can't feel this one by playing it.
static func easy() -> GoalieSkillProfile:
	return GoalieSkillProfile.new(0.36, 0.28, 0.11, 0.55, 0.28,
			1.15, 0.80, 3.25, 3.25, 6.0, 8.0)


static func for_difficulty(difficulty: int) -> GoalieSkillProfile:
	match difficulty:
		Difficulty.EASY:
			return easy()
		Difficulty.NORMAL:
			return normal()
		_:
			return hard()
