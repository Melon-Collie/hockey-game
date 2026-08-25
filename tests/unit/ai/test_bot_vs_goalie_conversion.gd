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


# ── THE THREE WAYS BOTS SCORE, split apart ──────────────────────────────────
# From play, bots beat the keeper three ways, and only two of them are a goalie
# problem:
#
#   1 DRIVE-IN   skate straight at him and release from an extreme point picked
#                to clear his butterfly. Almost no lateral pace at the release.
#   2 FLYBY      cross the face and shoot AHEAD of him, into the side he has not
#                caught up to. This is the one a tracking trail pays for.
#   3 PLAYMAKING beat him fair off a pass. Out of scope here — this file has one
#                skater, so nothing it measures is mode 3.
#
# Split on the carrier's LATERAL pace at the release, which is what physically
# separates 1 from 2, and report whether the aim LEADS the keeper — on the side
# he is crossing toward, past where he actually is. A flyby that leads him is
# mode 2 by construction.
const FLYBY_LATERAL_M_S: float = 1.5


func test_report_the_way_each_goal_was_scored() -> void:
	var rows: Array[Dictionary] = _sweep(BotSkillProfile.hard())
	var drive := [0, 0, 0.0]      # shots, goals, summed predicted EV
	var flyby := [0, 0, 0.0]
	var flyby_lead := [0, 0]      # of the flybys, those aimed AHEAD of him
	var flyby_behind := [0, 0]
	var margins: Array[float] = []
	for r: Dictionary in rows:
		if r["outcome"] == BotGoalie.NO_SHOT:
			continue
		var scored: bool = r["outcome"] == BotGoalie.GOAL
		var lat: float = r["lat_speed"]
		var bucket: Array = drive if absf(lat) < FLYBY_LATERAL_M_S else flyby
		bucket[0] += 1
		bucket[2] += r["shoot_ev"]
		if scored:
			bucket[1] += 1
		if absf(lat) >= FLYBY_LATERAL_M_S:
			# Did he aim into the side the carrier was crossing toward?
			var leads: bool = signf(r["aim"].x - r["goalie_x"]) == signf(lat)
			var b2: Array = flyby_lead if leads else flyby_behind
			b2[0] += 1
			if scored:
				b2[1] += 1
		margins.append(absf(r["aim"].x - r["goalie_x"]))
	gut.p("── how the bot beat him (mode 3, playmaking, is out of scope here) ──")
	_mode_line("1 DRIVE-IN (lateral < %.1f m/s)" % FLYBY_LATERAL_M_S, drive)
	_mode_line("2 FLYBY    (lateral >= %.1f m/s)" % FLYBY_LATERAL_M_S, flyby)
	gut.p("     of the flybys — aimed AHEAD of him: %d shots %d goals | behind: %d shots %d goals"
			% [flyby_lead[0], flyby_lead[1], flyby_behind[0], flyby_behind[1]])
	var m: float = 0.0
	for v: float in margins:
		m += v
	gut.p("   mean |aim - goalie.x| at release: %.3f m over %d shots"
			% [m / float(maxi(margins.size(), 1)), margins.size()])
	assert_true(true, "report")


# One mode's line, with the bot's own shoot score beside what actually happened.
#
# ⚠️ `debug_shoot_score` IS NOT A GOAL PROBABILITY. It is the ranking utility the
# shoot/pass/carry compete argmaxes over, carrying `ACTION_HYSTERESIS_MARGIN_FRAC`
# on top, and it reads well above the value seam's ~0.45 ceiling — so it cannot
# be read as "the bot expected to score this often". What it IS good for is
# ORDERING: if the bot scores one mode above another while the outcomes run the
# other way, its ranking disagrees with the ice, and that disagreement is what
# decides which shot it takes.
func _mode_line(label: String, b: Array) -> void:
	var shots: int = b[0]
	gut.p("   %-32s shots %2d  goals %2d (%5.1f%%)   bot score %.3f (rank only)" % [
			label, shots, b[1],
			100.0 * float(b[1]) / float(maxi(shots, 1)),
			b[2] / float(maxi(shots, 1))])


# ── MODE 1, measured off the bot's OWN release-offset sweep ─────────────────
# The carrier scores three release points (`RELEASE_SAMPLE_FRACS` = no
# relocation / full forehand reach / full backhand reach) and commits the best.
# The mode play produces is the flanking pair: the bot arrives on top of a keeper
# who is already DOWN, and the forehand and backhand release points sit on
# OPPOSITE sides of his butterfly, so one of them is outside his coverage and the
# net is open however he is squared.
#
# So the classifier is the bot's own decision rather than a scripted approach:
# a FLANK release is one it relocated the puck for, and mode 1 is a flank
# release taken point-blank at a keeper who is down.
const FLANK_OFFSET_M: float = 0.15      # relocated at all, vs the straight release
const POINT_BLANK_M: float = 2.0        # release-to-keeper distance


func test_report_the_flank_release_at_a_down_keeper() -> void:
	var rows: Array[Dictionary] = _sweep(BotSkillProfile.hard())
	var cells: Dictionary = {}
	for r: Dictionary in rows:
		if r["outcome"] == BotGoalie.NO_SHOT:
			continue
		var off: float = Vector2(r["release_offset"].x, r["release_offset"].z).length()
		var flank: bool = off >= FLANK_OFFSET_M
		var gp: Vector3 = r["goalie_pos"]
		var close: bool = gp != Vector3.INF \
				and Vector2(r["release"].x - gp.x, r["release"].z - gp.z).length() <= POINT_BLANK_M
		var down: bool = r["stance"] == GoalieStateMachine.State.BUTTERFLY \
				or r["stance"] == GoalieStateMachine.State.SLIDING \
				or r["stance"] == GoalieStateMachine.State.COILING
		var k: String = "%s / %s / %s" % [
				"FLANK " if flank else "STRAIGHT",
				"point-blank" if close else "off      ",
				"keeper DOWN" if down else "keeper up  "]
		if not cells.has(k):
			cells[k] = [0, 0, 0.0]
		cells[k][0] += 1
		if r["outcome"] == BotGoalie.GOAL:
			cells[k][1] += 1
		cells[k][2] += off
	# IS HE BETTER PLACED WHEN HE GOES DOWN, or simply down less often? The
	# butterfly cannot translate once committed, so what decides a flank release
	# against a down keeper is where his pads were at the drop. Measured as the
	# release's lateral gap from him against the pad edge he actually presents
	# (pad_local_offset + butterfly_pad_half_width): inside it he covers the
	# release, outside it the net is open however square he is.
	var edge: float = _ctrl.pad_local_offset + _ctrl.butterfly_pad_half_width
	var gap_sum: float = 0.0
	var gap_n: int = 0
	var outside: int = 0
	var outside_goals: int = 0
	var inside_goals: int = 0
	var inside_n: int = 0
	for r: Dictionary in rows:
		if r["outcome"] == BotGoalie.NO_SHOT or r["goalie_pos"] == Vector3.INF:
			continue
		var down2: bool = r["stance"] == GoalieStateMachine.State.BUTTERFLY \
				or r["stance"] == GoalieStateMachine.State.SLIDING \
				or r["stance"] == GoalieStateMachine.State.COILING
		if not down2:
			continue
		var gap: float = absf(r["release"].x - r["goalie_x"])
		gap_sum += gap
		gap_n += 1
		if gap > edge:
			outside += 1
			if r["outcome"] == BotGoalie.GOAL:
				outside_goals += 1
		else:
			inside_n += 1
			if r["outcome"] == BotGoalie.GOAL:
				inside_goals += 1
	gut.p("── against a DOWN keeper: where did the release sit vs his pad edge (%.2f m)? ──"
			% edge)
	gut.p("   mean |release.x - goalie.x| %.3f m over %d shots" % [
			gap_sum / float(maxi(gap_n, 1)), gap_n])
	gut.p("   OUTSIDE the pad edge: %2d shots %2d goals (%5.1f%%) | INSIDE: %2d shots %2d goals (%5.1f%%)"
			% [outside, outside_goals,
					100.0 * float(outside_goals) / float(maxi(outside, 1)),
					inside_n, inside_goals,
					100.0 * float(inside_goals) / float(maxi(inside_n, 1))])
	gut.p("── mode 1: the release-offset sweep, by what it produced ──")
	var keys: Array = cells.keys()
	keys.sort()
	for k: String in keys:
		var v: Array = cells[k]
		gut.p("   %-42s shots %2d  goals %2d (%5.1f%%)  mean offset %.2f m" % [
				k, v[0], v[1], 100.0 * float(v[1]) / float(maxi(v[0], 1)),
				v[2] / float(maxi(v[0], 1))])
	assert_true(true, "report")
