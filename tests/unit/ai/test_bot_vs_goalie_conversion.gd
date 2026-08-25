extends GutTest

# ── BOT-vs-GOALIE CONVERSION, the number nothing else measures ───────────────
# A real bot picks the shot; the real goalie tries to stop it; the puck is
# marched against his posed collision. See bot_vs_goalie_harness.gd for what is
# real and what is approximated — the approximations decide how far these
# numbers can be pushed and are worth reading before quoting any of them.
#
# WHY IT EXISTS. The bot decides against `AIActionScoring`'s model of the
# goalie; the goalie plays as `GoalieController`; and until this file nothing
# compared their OUTCOMES. Every other sweep either scripts the shooter (the
# real-goalie harness, the xG benchmark, the beatability sweep) or models the
# save (rush_sim_harness), so the balance was set by the gap between two models
# that no test could see. That is why the sweeps read "wall" while the logged
# games read 0.614.
#
# HOW TO USE IT. The zone bands are deliberately identical to
# tools/goalie_shot_events_audit.sql, so this and the `shot_events` table are
# directly comparable. When they disagree, the disagreement is the finding — one
# of the two is wrong about the game and it is usually this one, because a
# harness with one skater cannot produce a rebound somebody buries.
#
# WHAT IT ASSERTS. Structural properties only, deliberately. Conversion levels
# are reported and NOT pinned: a level pinned here would be re-pinned on every
# tuning pass and would say nothing, and this file's whole purpose is to be the
# thing you re-measure against rather than a gate you satisfy. What it does gate
# is that the instrument still WORKS — bots still shoot, the goalie still makes
# saves, and the tiers still order — because a conversion instrument that has
# quietly stopped producing shots reports a fantastic save percentage.

const BotGoalie := preload("res://tests/unit/ai/bot_vs_goalie_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
# Approach angles around the net, and the ranges a rush is launched from. Angles
# mirror the 1v1 sweeps already in test_real_rush_sim so the two files describe
# the same rushes.
const ANGLES_DEG: Array[float] = [-75.0, -45.0, -25.0, 0.0, 25.0, 45.0, 75.0]
const START_RADIUS: Array[float] = [8.0, 11.0, 14.0]
# Pace into the release, swept rather than fixed: how fast the carrier is moving
# decides how much of the keeper's push is spent when the puck arrives, and it is
# the axis the whole set-vs-moving split turns on. Three speeds also triples the
# sample, which a 21-rush grid badly needed — one goal was 4.8 points.
const RUSH_SPEEDS: Array[float] = [3.5, 5.0, 6.5]

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _bg: RefCounted = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	_ctrl = GoalieController.new()
	for n: Node in [_goalie, _puck, _shooter, _ctrl]:
		add_child_autofree(n)
	_shooter.set_physics_process(false)
	_shooter.set_process(false)
	_bg = BotGoalie.new()
	_bg.setup(_goalie, _puck, _ctrl, _shooter)


# Sweep every angle x start radius for one tier. Returns the raw records.
func _sweep(profile: BotSkillProfile) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var net := Vector3(0.0, 0.0, GOAL_Z)
	for radius: float in START_RADIUS:
		for deg: float in ANGLES_DEG:
			for speed: float in RUSH_SPEEDS:
				var a: float = deg_to_rad(deg)
				var start: Vector3 = net + Vector3(sin(a), 0.0, cos(a)) * radius
				var vel: Vector3 = (net - start).normalized() * speed
				_ctrl.reset_to_crease()
				out.append(_bg.run_rush(start, vel, profile))
	return out


func _summarise(rows: Array[Dictionary], label: String) -> Dictionary:
	var shots: int = 0
	var goals: int = 0
	var reb_goals: int = 0
	var held: int = 0
	var no_shot: int = 0
	var by_dist: Dictionary = {}
	for r: Dictionary in rows:
		if r["outcome"] == BotGoalie.NO_SHOT:
			no_shot += 1
			continue
		shots += 1
		var scored: bool = r["outcome"] == BotGoalie.GOAL
		if scored:
			goals += 1
		if r["rebound_goal"]:
			reb_goals += 1
		if r["rebound_held"]:
			held += 1
		var z: Dictionary = BotGoalie.zone_of(r["release"])
		var b: String = z["dist_band"]
		if not by_dist.has(b):
			by_dist[b] = [0, 0, 0]
		by_dist[b][0] += 1
		if scored:
			by_dist[b][1] += 1
		if r["rebound_goal"]:
			by_dist[b][2] += 1
	gut.p("── %s ── %d rushes: %d shots, %d never fired" % [
			label, rows.size(), shots, no_shot])
	gut.p("   first-shot goals %d  (%.1f%%)   rebound goals %d   pucks held %d" % [
			goals, 100.0 * float(goals) / float(maxi(shots, 1)), reb_goals, held])
	var keys: Array = by_dist.keys()
	keys.sort()
	for k: String in keys:
		var v: Array = by_dist[k]
		gut.p("     %-11s shots %2d  goals %2d (%5.1f%%)  +reb %d" % [
				k, v[0], v[1], 100.0 * float(v[1]) / float(maxi(v[0], 1)), v[2]])
	return {"shots": shots, "goals": goals, "no_shot": no_shot,
			"reb_goals": reb_goals, "held": held}


func test_the_instrument_produces_shots_and_saves() -> void:
	# THE TEETH. A conversion instrument that has stopped producing shots, or
	# whose keeper has stopped touching them, reports a wonderful save
	# percentage and means nothing. Both halves have to stay alive for any
	# number in this file to be worth reading.
	var rows: Array[Dictionary] = _sweep(BotSkillProfile.hard())
	var s: Dictionary = _summarise(rows, "HARD")
	assert_gt(s["shots"], rows.size() / 2,
			"the bots must actually shoot — most rushes producing no shot means "
			+ "the compete changed, not that the goalie got better")
	assert_gt(s["goals"], 0,
			"and some must go in — a shutout across every angle and range is an "
			+ "instrument failure, not a goalie")
	assert_lt(s["goals"], s["shots"],
			"and the keeper must save some — if he stops nothing the collision "
			+ "or the release reconstruction has broken")


func test_conversion_by_tier_is_ordered() -> void:
	# The one comparative property worth gating: an EASY keeper concedes more of
	# the bot's chosen shots than a HARD one. It is the cheapest end-to-end check
	# that the difficulty ladder reaches the thing a player actually experiences,
	# and nothing else in the suite asserts it against real saves.
	#
	# Bot skill is held at HARD across all three so only the KEEPER varies —
	# otherwise a weaker shooter's worse aim masks a weaker goalie.
	var rates: Dictionary = {}
	for tier: String in ["HARD", "NORMAL", "EASY"]:
		_ctrl.apply_skill_profile(GoalieSkillProfile.for_difficulty(
				GoalieSkillProfile.Difficulty.HARD if tier == "HARD"
				else GoalieSkillProfile.Difficulty.NORMAL if tier == "NORMAL"
				else GoalieSkillProfile.Difficulty.EASY))
		var rows: Array[Dictionary] = _sweep(BotSkillProfile.hard())
		var s: Dictionary = _summarise(rows, "goalie " + tier)
		rates[tier] = float(s["goals"]) / float(maxi(s["shots"], 1))
	gut.p("conversion: HARD %.3f  NORMAL %.3f  EASY %.3f" % [
			rates["HARD"], rates["NORMAL"], rates["EASY"]])
	assert_gte(rates["EASY"], rates["HARD"],
			"an EASY keeper must concede at least as much as a HARD one")


func test_report_the_goalie_state_the_bot_shoots_into() -> void:
	# REPORT. The logged games say he saves 72.3% when set and 46.7% in motion,
	# with 45% of shots arriving while he is moving. That split is the largest
	# single term in the live save percentage, and this is the only instrument
	# that can say whether the BOTS are finding it — a bot that only ever shoots
	# at a set keeper is not exercising the case that decides the real number.
	var rows: Array[Dictionary] = _sweep(BotSkillProfile.hard())
	var buckets: Dictionary = {"a set (<0.1)": [0, 0], "b 0.1-0.3": [0, 0],
			"c 0.3-0.6": [0, 0], "d in motion (0.6+)": [0, 0]}
	var stances: Dictionary = {}
	for r: Dictionary in rows:
		if r["outcome"] == BotGoalie.NO_SHOT:
			continue
		var u: float = r["unset"]
		var k: String = "d in motion (0.6+)"
		if u < 0.1: k = "a set (<0.1)"
		elif u < 0.3: k = "b 0.1-0.3"
		elif u < 0.6: k = "c 0.3-0.6"
		buckets[k][0] += 1
		if r["outcome"] == BotGoalie.GOAL:
			buckets[k][1] += 1
		var st: String = str(GoalieStateMachine.State.keys()[r["stance"]]) \
				if r["stance"] >= 0 else "?"
		stances[st] = int(stances.get(st, 0)) + 1
	gut.p("── what state is he in when a bot shoots? (logged games: 45%% in motion) ──")
	var keys: Array = buckets.keys()
	keys.sort()
	for k: String in keys:
		var v: Array = buckets[k]
		gut.p("   %-20s shots %2d  goals %2d" % [k, v[0], v[1]])
	gut.p("   stances at release: %s" % str(stances))
	assert_true(true, "report")
