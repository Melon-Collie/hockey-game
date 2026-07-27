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
#   • reaction_delay_s       — the reflexive leg-drop read latency, the goalie's
#     CORE save mechanism (it gates the butterfly drop that seals the five-hole
#     and the low corners). Higher → in-tight and quick-release low shots land
#     before the pads ever start moving. The single strongest "reacts, but
#     slower" lever.
#   • prearmed_reaction_delay_s — the primed (quiet-eye) read after watching a
#     visible windup. CRITICAL for the lower tiers: beginners telegraph every
#     shot (long deliberate wrister coils), which primes the goalie into its
#     FASTEST read — an untiered prearm makes Easy sharpest against exactly the
#     shots newcomers take. Higher → a telegraphed shot still beats him.
#   • butterfly_drop_s       — pads-to-floor time once the drop commits. Higher
#     → the five-hole and low ice stay open through a longer drop window.
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
#   • five_hole_base_m — the standing pad gap (m of separation each side). Higher
#     → a visibly leaky five-hole whenever the paddle is off-center (tracking,
#     active blade); the drop still seals it, just later on the lower tiers.
#
# AI MIRROR: the bots' shot/pass scoring predicts the live goalie with the same
# read model (leg/arm delays, drop time, lateral accel ramp, arm deploy). Those
# used to be compile-time constants — which is why the leg-drop read could not
# vary per tier — and are now static vars on AIActionScoring, synced from the
# match's profile via AIActionScoring.set_goalie_profile(profile) wherever
# GameManager selects goalie_skill_profile. Their defaults are the Hard/authored
# baselines, so unwired contexts (unit tests) score exactly today's goalie.
# STILL FIXED ACROSS TIERS: t_push_speed (the lateral slide TOP speed) — no tier
# varies it, so the scorer keeps it as a const (GOALIE_MAX_LATERAL_SPEED_MPS).
# Add it here only together with a set_goalie_profile field for it.
#
# To add a tier: add a Difficulty enum value, a factory, and a for_difficulty arm.
# To add a knob: add a field + _init param, set it in all three factories, and
# consume it in GoalieController._apply_skill_profile. If the bots' shot model
# reads the same quantity (see AI MIRROR above), also sync it in
# AIActionScoring.set_goalie_profile — otherwise the bots keep scoring against
# the Hard goalie's version of it.

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
# GO margin (s) for the behind-net rim stop — INF means the goalie never plays
# the puck. Timid puck play is a real weaker-goalie trait, so only the top
# tier leaves the net; it also means the feature carries zero risk on the
# tiers most players face.
var puck_play_go_margin_s: float
# Reflexive leg-drop read latency (s) — gates the butterfly drop that seals the
# five-hole and low ice. AI-mirrored (AIActionScoring.goalie_leg_delay_s).
var reaction_delay_s: float
# Primed (quiet-eye) read latency (s) after watching a visible windup — the
# floor BOTH reads shortcut to when the goalie is pre-armed.
var prearmed_reaction_delay_s: float
# Pads-to-floor time (s) once the butterfly commits. AI-mirrored
# (AIActionScoring.goalie_butterfly_drop_s).
var butterfly_drop_s: float
# Standing five-hole pad gap (m of separation each side of center).
var five_hole_base_m: float
# READ STALENESS (s) — how old the goalie's belief about WHERE the shot is going
# is when he commits to it. Distinct from every other knob here: the rest set
# WHEN he starts moving and HOW FAST he moves, all of which assume he knows the
# destination exactly. This one prices being WRONG. A shooter whose aim is stable
# through the wind-up is read perfectly at any lag (the stale sample equals the
# truth); a shooter who swings late beats the read by exactly this much. It also
# sets how fast he converges onto the true line once the puck is in flight, so a
# long shot is read correctly and an in-tight one is not.
# No RNG — the error is a pure function of what the shooter did with their aim.
#
# TUNING BAND. Measured against the height-deception sweep
# (tests/unit/ai/test_goalie_disguise_read.gd), goals out of 14 when the wind-up
# sells a low shot and the release goes high: 0.00 -> 6, 0.04 -> 7, 0.10 -> 11,
# and flat above that. So the responsive band is roughly 0-0.10 s and the tiers
# are anchored inside it; past ~0.10 the goalie is already fully committed to the
# wrong read and more staleness buys the shooter nothing. Values above the band
# are not "harder to beat", they are just indistinguishable.
var read_lag_s: float
# READ RE-SOLVE TIME (s) — how long it takes him to correct a WRONG belief once
# the puck is in flight and he can watch it. Split out of `read_lag_s`, which
# used to set both: how stale the pre-read is AND how fast it converges. Those
# are physically different — one is the age of a wind-up read, the other is how
# quickly a goalie re-solves a live puck he is now tracking — and tying them
# together meant you could not lengthen the deception window without also making
# the pre-read staler.
#
# It is the term that decides whether LATERAL deception pays. The belief is only
# wrong for this long, and the arms recover in whatever is left of the flight:
# at 0.05 s against a 0.21 s flight from 7 m he is wrong for under a quarter of
# it and a 5 m/s arm covers the rest easily.
#
# ANCHORED, not tuned: each tier re-solves in its own `reaction_delay_s`. Reading
# a line you got WRONG is a fresh read, not a refinement — you are not adjusting
# an estimate, you are discovering the estimate was of a different shot. So the
# cost is a full cold read, and a slower goalie stays wrong longer. That lands
# where the measurement saturates anyway: on the corner-deception sweep
# (test_goalie_disguise_read) goals out of 14 go 7 -> 8 -> 9 -> 10 across
# 0.05 / 0.08 / 0.10 / 0.13 s and are flat above, with the TELEGRAPHED control
# pinned at 7 throughout.
var read_converge_s: float


func _init(p_arm_reaction_delay_s: float, p_cross_crease_react_delay_s: float,
		p_poke_radius_m: float, p_screen_max_extra_delay_s: float,
		p_move_read_max_delay_s: float, p_depth_aggressive_m: float,
		p_depth_base_m: float, p_glove_react_max_speed_mps: float,
		p_blocker_react_max_speed_mps: float, p_pad_toe_out_butterfly_deg: float,
		p_lateral_accel_mps2: float, p_puck_play_go_margin_s: float,
		p_reaction_delay_s: float, p_prearmed_reaction_delay_s: float,
		p_butterfly_drop_s: float, p_five_hole_base_m: float,
		p_read_lag_s: float = 0.13,
		p_read_converge_s: float = 0.13) -> void:
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
	read_lag_s = p_read_lag_s
	read_converge_s = p_read_converge_s
	puck_play_go_margin_s = p_puck_play_go_margin_s
	reaction_delay_s = p_reaction_delay_s
	prearmed_reaction_delay_s = p_prearmed_reaction_delay_s
	butterfly_drop_s = p_butterfly_drop_s
	five_hole_base_m = p_five_hole_base_m


# Hard == the GoalieController @export defaults verbatim. Keep these in sync with
# the controller so applying Hard is a true no-op (the ceiling we've tuned).
static func hard() -> GoalieSkillProfile:
	return GoalieSkillProfile.new(0.18, 0.12, 0.25, 0.30, 0.12,
			1.75, 1.30, 5.0, 5.0, 18.0, 14.0, 0.9,
			0.13, 0.07, 0.20, 0.02, 0.05, 0.13)


# Normal is the middle tier: enough goalie to punish a lazy shot, soft enough
# that a well-picked corner, a quick release off the catch, or a cross-crease
# play genuinely scores — the tier where shooting AND playmaking are both live
# options. Sits roughly mid-ladder on every axis: reads a beat slower than Hard
# (0.18 s legs ≈ the real elite cold-read floor, so the anticipation edge Hard
# keeps is gone), a step deeper on the arc, and arms that get most — not all —
# of the way to the corner.
static func normal() -> GoalieSkillProfile:
	return GoalieSkillProfile.new(0.28, 0.22, 0.16, 0.45, 0.20,
			1.35, 0.95, 3.8, 3.8, 11.0, 10.0, INF,
			0.18, 0.10, 0.25, 0.035, 0.10, 0.18)


# Easy is the newcomer floor, tuned so ANY decently-aimed shot scores: he sits
# nearly on his goal line (net open from everywhere), the leg-drop read + slow
# butterfly leave the five-hole and low corners open from inside the slot, the
# arms start late and crawl (top corners open), the primed read barely beats the
# cold one (telegraphed beginner windups still score), and he's slow to get
# moving across. Only a shot more or less AT him gets saved. Still tracks,
# squares, and drops butterfly — a real but weak goalie, never a statue.
static func easy() -> GoalieSkillProfile:
	return GoalieSkillProfile.new(0.45, 0.40, 0.08, 0.70, 0.35,
			0.90, 0.60, 2.4, 2.4, 5.0, 6.0, INF,
			0.30, 0.16, 0.32, 0.06, 0.16, 0.30)


static func for_difficulty(difficulty: int) -> GoalieSkillProfile:
	match difficulty:
		Difficulty.EASY:
			return easy()
		Difficulty.NORMAL:
			return normal()
		_:
			return hard()
