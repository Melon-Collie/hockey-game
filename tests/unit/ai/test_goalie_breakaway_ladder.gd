extends GutTest

# ── THE DIFFICULTY LADDER ON THE PLAY THAT ACTUALLY GETS PLAYED ─────────────
# This project's own player scores overwhelmingly on breakaways, and the move is
# always the same one `test_human_wraparound` models: drive at him, pull the puck
# across to commit him, walk around him, tuck it. So the ladder that matters is
# the ladder ON THAT MOVE, and it does not go the way the tiers do.
#
#   EASY   0 of 7 aim points open
#   NORMAL 2 of 7
#   HARD   4 of 7
#
# Every measurement below fires the same seven-point aim fan at the same release
# point after the same bait, so the count IS how much net is open — not whether
# a shooter who already knows the answer can find it.
#
# ── AND IT IS ONE KNOB ──────────────────────────────────────────────────────
# `depth_base_m` alone reproduces the whole spread. The other twelve tier levers
# — every read latency, every reach speed, the drop time, the five-hole, the
# poke, the toe-out — change NOTHING on this play, to the shot. So the tier
# ladder here is not "a slower goalie is easier to beat", it is "a goalie who
# challenges the rush harder is easier to walk around", which is the ladder
# running backwards through its own primary lever.
#
# ── THE TRADE IS REAL, AND IT HAS A MINIMUM ────────────────────────────────
# Pulling `depth_base_m` in is not free — it concedes the centre-lane rush shot
# from 5 m, which is exactly what challenge depth exists to cut off. Open aim
# points, walkaround plus a 6-cell rush grid (49 shots in total per row):
#
#   depth_base   walkaround   rush   total
#   1.30 (HARD)      4         7      11
#   1.00             2         6       8
#   0.80             2         8      10
#   0.60 (EASY)      0        11      11
#
# So the authored 1.30 is past the optimum on both counts: it gives up the
# walkaround and buys nothing on the rush over 1.00.
#
# ⚠️ THIS IS NOT A LICENCE TO SET IT TO 1.00. 1.30 is not a tuning number — it is
# `CreaseRules.STRAIGHT_DEPTH`, heels at the crease top, the taught B position.
# Replacing a rink landmark with a number that won a 49-shot sweep trades a model
# for a magic constant, which is the thing this codebase spends its effort not
# doing. Read the table as evidence about what the COMMIT costs from that depth,
# and fix the commit.

const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const Harness := preload("res://tests/unit/ai/human_wraparound_harness.gd")
const SkaterScene := preload("res://Scenes/Skater.tscn")
const AIM_X: Array[float] = [-0.85, -0.55, -0.25, 0.0, 0.25, 0.55, 0.85]
const START_M: float = 9.0
const DRIVE_M_S: float = 5.0
const PULL_M: float = 1.1
const PULL_S: float = 0.25
const PULL_AT_M: float = 3.5

var _h: RefCounted = null
var _ctrl: GoalieController = null


func before_each() -> void:
	var goalie: Node = load("res://Scenes/Goalie.tscn").instantiate()
	var puck: Node = load("res://Scenes/Puck.tscn").instantiate()
	var shooter: Skater = SkaterScene.instantiate() as Skater
	_ctrl = GoalieController.new()
	for n: Node in [goalie, puck, shooter, _ctrl]:
		add_child_autofree(n)
	_h = Harness.new()
	_h.setup(goalie, puck, _ctrl, shooter)


# ⚠️ OVERRIDES GO ON THE PROFILE, NEVER ON THE CONTROLLER AFTERWARDS.
# `apply_skill_profile` rebuilds the cached rule configs, so a field written
# after it is set but never read again — and a sweep done that way reports the
# baseline for every arm and reads as "this lever does nothing".
func _apply(over: Dictionary) -> void:
	var p: GoalieSkillProfile = GoalieSkillProfile.hard()
	for k: String in over:
		p.set(k, over[k])
	_ctrl.apply_skill_profile(p)


# How much net the walkaround opens, as a count of the aim fan.
func _walkaround_open(over: Dictionary) -> int:
	var open: int = 0
	for ax: float in AIM_X:
		_apply(over)
		_h.settle_ready(Vector3(0.0, 0.0, GOAL_Z + START_M))
		_h.begin_trial()
		_h.bait_commit(0.0, START_M, 0.9, DRIVE_M_S, PULL_M, PULL_S, PULL_AT_M)
		var rel: Vector3 = _h.wrap_to(-1.35, 0.70, 4.0)
		if _h.fire_release_at(rel, Vector3(ax, 0.0, GOAL_Z), 0, 18.0, 0.0) == 0:
			open += 1
	return open


# The other half of the trade: a shot taken OFF the drive, no attempt to get
# around him. Elevated and hard, which is the rush shot challenge depth exists
# to cut the angle on.
func _rush_open(over: Dictionary, lane: float, dist: float) -> int:
	var open: int = 0
	for ax: float in AIM_X:
		_apply(over)
		_h.settle_ready(Vector3(lane, 0.0, GOAL_Z + 14.0))
		_h.begin_trial()
		_h.bait_commit(lane, 14.0, dist, 6.0)
		var spot := Vector3(lane, 0.0, GOAL_Z + dist)
		if _h.fire_release_at(spot, Vector3(ax, 0.0, GOAL_Z), 1, 28.0, 0.0) == 0:
			open += 1
	return open


# ── 1. THE LADDER RUNS BACKWARDS ─────────────────────────────────────────────
# Pinned as the defect it is. When the ladder is fixed this test fails, and the
# correct response is to flip the assertion — not to loosen it.
func test_the_difficulty_ladder_is_inverted_on_a_walkaround() -> void:
	var open: Dictionary = {}
	for tier: int in [GoalieSkillProfile.Difficulty.EASY,
			GoalieSkillProfile.Difficulty.NORMAL,
			GoalieSkillProfile.Difficulty.HARD]:
		var p: GoalieSkillProfile = GoalieSkillProfile.for_difficulty(tier)
		open[tier] = _walkaround_open({
			"depth_aggressive_m": p.depth_aggressive_m,
			"depth_base_m": p.depth_base_m,
			"reaction_delay_s": p.reaction_delay_s,
			"lateral_accel_mps2": p.lateral_accel_mps2,
			"butterfly_drop_s": p.butterfly_drop_s,
			"arm_reaction_delay_s": p.arm_reaction_delay_s,
			"read_lag_s": p.read_lag_s,
			"five_hole_base_m": p.five_hole_base_m,
		})
		gut.p("tier %d -> %d of %d aim points open" % [tier, open[tier], AIM_X.size()])
	assert_gt(open[GoalieSkillProfile.Difficulty.HARD] as int,
			open[GoalieSkillProfile.Difficulty.EASY] as int,
			"HARD leaks MORE net on a walkaround than EASY — the ladder is backwards here")


# ── 2. AND IT IS ONE KNOB ────────────────────────────────────────────────────
# The teeth: if a tier lever is ever added or retuned so that it moves this play,
# this fails, and that is worth knowing — right now the only thing the ladder
# does to a breakaway walkaround is change how far out he stands.
func test_depth_base_is_the_only_tier_lever_this_play_can_feel() -> void:
	var baseline: int = _walkaround_open({})
	var inert: Dictionary = {
		"reaction_delay_s": 0.30,
		"lateral_accel_mps2": 2.4,
		"butterfly_drop_s": 0.32,
		"arm_reaction_delay_s": 0.45,
		"read_lag_s": 0.06,
		"five_hole_base_m": 0.30,
		"poke_radius_m": 0.08,
		"move_read_scramble_delay_s": 0.35,
		"cross_crease_react_delay_s": 0.40,
		"pad_toe_out_butterfly_deg": 5.0,
		"glove_react_max_speed_mps": 5.0,
		"depth_aggressive_m": 0.90,
	}
	for k: String in inert:
		var open: int = _walkaround_open({k: inert[k]})
		assert_eq(open, baseline,
				"%s at its EASY value must not move the walkaround" % k)
	var moved: int = _walkaround_open({"depth_base_m": 0.60})
	gut.p("baseline %d of %d open; depth_base 0.60 -> %d"
			% [baseline, AIM_X.size(), moved])
	assert_lt(moved, baseline, "depth_base is the lever, and it is the only one")


# ── 3. THE TRADE, PRICED ─────────────────────────────────────────────────────
# Characterisation. Both halves at once so neither can be improved quietly at the
# other's expense — a depth change that only reports the walkaround has been
# checked against the half it helps.
func test_the_depth_base_trade_has_a_minimum() -> void:
	var best_total: int = 99
	var best_base: float = 0.0
	for base: float in [1.30, 1.00, 0.80, 0.60]:
		var over := {"depth_base_m": base}
		var walk: int = _walkaround_open(over)
		var rush: int = 0
		for lane: float in [0.0, 2.5]:
			for dist: float in [5.0, 8.0, 11.0]:
				rush += _rush_open(over, lane, dist)
		var total: int = walk + rush
		gut.p("depth_base %.2f | walkaround %d/%d  rush %d/%d  total %d/%d"
				% [base, walk, AIM_X.size(), rush, 6 * AIM_X.size(), total,
				7 * AIM_X.size()])
		if total < best_total:
			best_total = total
			best_base = base
	gut.p("least net conceded overall at depth_base %.2f (%d open)"
			% [best_base, best_total])
	assert_lt(best_base, 1.30,
			"the authored crease-top depth is past the optimum on this pair of plays")
