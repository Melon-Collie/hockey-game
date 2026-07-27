extends GutTest

# ── Why the carrier back-passed out of the slot: the currency had no range ────
# REPORT-ONLY, and the readout for the soft-edge rework in
# AIActionScoring.open_net_danger. The three reports below are the before/after
# for that change; the commentary describes the defect they were written to
# expose. Still report-only: the post-fix surface is not calibrated yet, so
# asserting it would cement a number nobody has playtested.
#
# The bots do NOT decide on `expected_goals`. They decide on `open_net_danger`,
# and the two are different functions living twenty lines apart:
#
#   expected_goals   = erf(window / 2·√2·σ) …then floored at XG_COVERED_LEAK
#                      → a smooth Gaussian placement probability, never 0, never 1
#   open_net_danger  = clamp(window / (2 · aim_spread), 0, 1)
#                      → a RAMP that saturates, with hard 0 and hard 1 ends
#
# `aim_spread` is the bot's own execution error: 0.01 rad on Hard, and floored
# at MIN_RELEASE_SPREAD_RAD (0.01) for everyone. So the ramp spans a window of
# 0 → 0.02 rad and is pinned at 1.000 above it. For scale, the whole empty net
# subtends 0.30 rad from the dot line — so a window of one-fifteenth of an open
# net already saturates the scorer. In the offensive zone the decision currency
# is therefore very nearly the BOOLEAN "is there a window wider than ~1.1°".
#
# Three consequences, one per report below:
#
#   A. No gradient to steer on. Most of the dangerous ice reads exactly 1.000
#      and the rest reads exactly 0.000, non-monotonically in both distance and
#      angle. A carry beam that ranks destinations by this cannot prefer a
#      better shooting spot, because the spots it is choosing between all score
#      the same. Ties then fall to the safety / turnover / lane terms and to the
#      15% incumbent-action hysteresis, which is what surfaces as the back-pass.
#
#   B. Unsettling the keeper is unrewardable. The planner DOES compute the
#      unsettle read for carry candidates (carrier.gd's cand_unsettled), and it
#      fires correctly — a cross-slot drive reads 1.00. But the value it feeds
#      is already at the 1.000 ceiling for a SET keeper, so catching him moving
#      buys nothing. There is no headroom above "set goalie" in which the reward
#      for moving him could exist.
#
#   C. …and it is worth a lot. Against the live keeper, the same in-tight shot
#      converts 2–4x better when he is caught wide. That is real value the
#      compete has no way to see.
#
# The companion defect is in test_slot_shot_value_truth.gd: where this surface
# saturates at 1.000 it is also wrong by +1.00, because the keeper's STICK is
# not in the cover model. The two compound — the currency is maximally
# confident exactly where it is maximally wrong.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")

const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const WRIST: float = AIActionScoring.WRISTER_SHOT_SPEED_M_S
const NET_HW: float = GameRules.NET_HALF_WIDTH
const SETTLE_TICKS: int = 120

# Aim grid for the live-fire reports: ±0.84 m in 14 cm steps, the mouth minus
# the pipe, matching test_goalie_exhaustive_beatability's column spacing.
const AIM_STEPS: int = 13
const AIM_FROM_M: float = -0.84
const AIM_STEP_M: float = 0.14
const FIRE_SPEEDS: Array[float] = [29.0, 33.0]

var _goal := Vector3(0.0, 0.0, GOAL_Z)
var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	_ctrl = GoalieController.new()
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_shooter)
	add_child_autofree(_ctrl)
	_h = Harness.new()
	_h.setup(_goalie, _puck, _ctrl, _shooter)


# The keeper's real settled pose for a carrier at `spot`. reset_to_crease first
# so each cell starts clean — otherwise he carries depth and pose from the
# previous cell and the grid stops being reproducible.
func _settled(spot: Vector3) -> Vector3:
	_ctrl.reset_to_crease()
	_h.settle(spot, SETTLE_TICKS)
	return _goalie.global_position


# ── A. The value surface the carry beam ranks destinations with ──────────────
func test_report_the_decision_currency_saturates() -> void:
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	var net_angle: float = 2.0 * atan(NET_HW / 6.096)
	gut.p("open_net_danger — the value the O-zone carry beam maximises.")
	gut.p("  hard aim spread %.3f rad -> the ramp saturates at a %.3f rad window;"
			% [spread, 2.0 * spread])
	gut.p("  the whole empty net subtends %.3f rad from the dot line (%.0f%% of it)."
			% [net_angle, 100.0 * 2.0 * spread / net_angle])
	var dists: Array[float] = [2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 13.0]
	var header := "        "
	for d: float in dists:
		header += "%7.1f" % d
	gut.p("  rows = lateral offset, cols = distance to net")
	gut.p(header)
	var pinned: int = 0
	var zeroed: int = 0
	var total: int = 0
	for x: float in [0.0, 1.5, 3.0, 5.0]:
		var row := "x=%4.1f " % x
		for d: float in dists:
			var z: float = sqrt(maxf(d * d - x * x, 0.25))
			var spot := Vector3(x, 0.0, GOAL_Z + z)
			var keeper: Vector3 = _settled(spot)
			var env: Dictionary = _h.shot_env()
			var v: float = AIActionScoring.open_net_danger(
					spot, _goal, keeper, NET_HW, WRIST, 0.0, env["five"],
					env["down"], env["seal_x"], env["seal_tall"], spread, 0.0,
					env["hands"], env["pads"])
			row += "%7.3f" % v
			total += 1
			if v >= 0.999:
				pinned += 1
			elif v <= 0.001:
				zeroed += 1
		gut.p(row)
	gut.p("  %d/%d cells pinned at 1.000, %d/%d at exactly 0.000 — %d%% of the"
			% [pinned, total, zeroed, total,
				roundi(100.0 * float(pinned + zeroed) / float(total))])
	gut.p("  surface carrying no gradient at all. Every such cell is a spot the")
	gut.p("  carry beam cannot rank against its neighbours.")
	gut.p("  (Pre-fix baseline, for comparison: 9/32 pinned and 14/32 dead, 72%,")
	gut.p("   non-monotonic — x=1.5 dipped to 0.455 at 4 m and recovered to 1.000")
	gut.p("   at 6 m, i.e. a teammate further out scored better than the slot.)")
	assert_true(true, "report")


# ── B. What the planner's unsettle read is worth ─────────────────────────────
# Reproduces carrier.gd's exact chain for one carry candidate: predict the
# keeper over the CARRY (predict_goalie_pos), then read how unsettled he is over
# the RELEASE window from that tracked spot (goalie_unsettled).
func _planner_read(start: Vector3, candidate: Vector3,
		carry_speed: float) -> Dictionary:
	var keeper_now: Vector3 = _settled(start)
	var local_time: float = start.distance_to(candidate) / maxf(carry_speed, 0.001)
	var arrive_vel: Vector3 = (candidate - start).normalized() * carry_speed
	var carry_closing: float = (start.distance_to(_goal)
			- candidate.distance_to(_goal)) / maxf(local_time, 0.001)
	var tracked: Vector3 = AIActionScoring.predict_goalie_pos(
			keeper_now, _goal, local_time, candidate, carry_closing)
	var look: float = SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
	var release: Vector3 = AIActionScoring.release_ahead_of_goalie(
			candidate + arrive_vel * look, _goal, tracked)
	var release_t: float = look + release.distance_to(_goal) / WRIST
	var release_closing: float = AIActionScoring.closing_toward(
			candidate, arrive_vel, _goal)
	var unsettled: float = AIActionScoring.goalie_unsettled(
			tracked, _goal, release_t, release, release_closing)
	var at_release: Vector3 = AIActionScoring.predict_goalie_pos(
			tracked, _goal, release_t, release, release_closing)
	return {
		"time": local_time,
		"unsettled": unsettled,
		"scored": AIActionScoring.open_net_danger(
				release, _goal, at_release, NET_HW, WRIST, unsettled),
		"if_set": AIActionScoring.open_net_danger(
				release, _goal, at_release, NET_HW, WRIST, 0.0),
	}


func test_report_unsettling_the_keeper_is_unrewardable() -> void:
	gut.p("The carry beam's own read, per candidate. 'unsettled' is what it feeds")
	gut.p("score_shoot; 'if_set' is the same candidate scored as if the keeper were")
	gut.p("fully square. The gap between them is all the reward a bot can earn for")
	gut.p("moving him.")
	var cases: Array = [
		["straight in  6 -> 3 m", Vector3(0.0, 0.0, GOAL_Z + 6.0),
				Vector3(0.0, 0.0, GOAL_Z + 3.0)],
		["cross slot +3 -> -3 @6", Vector3(3.0, 0.0, GOAL_Z + 5.2),
				Vector3(-3.0, 0.0, GOAL_Z + 5.2)],
		["cross slot +4 -> -4 @5", Vector3(4.0, 0.0, GOAL_Z + 3.0),
				Vector3(-4.0, 0.0, GOAL_Z + 3.0)],
		["diagonal (4,8) -> (0,3)", Vector3(4.0, 0.0, GOAL_Z + 7.0),
				Vector3(0.0, 0.0, GOAL_Z + 3.0)],
		["hard cut  +2 -> -2 @3 m", Vector3(2.0, 0.0, GOAL_Z + 2.2),
				Vector3(-2.0, 0.0, GOAL_Z + 2.2)],
	]
	for speed: float in [5.0, 8.0]:
		gut.p("  --- carry speed %.1f m/s ---" % speed)
		for c: Array in cases:
			var r: Dictionary = _planner_read(c[1], c[2], speed)
			gut.p("  %-24s t=%.2fs  unsettled=%.2f  scored=%.3f  if_set=%.3f  gain=%+.3f"
					% [c[0], r["time"], r["unsettled"], r["scored"], r["if_set"],
						r["scored"] - r["if_set"]])
	gut.p("  The unsettle read fires correctly and buys nothing: the set-keeper")
	gut.p("  value is already at the ceiling, so there is no headroom to pay into.")
	assert_true(true, "report")


# ── C. What unsettling him is actually worth against the live keeper ─────────
# Settle him on a threat off to one side, then fire from the middle — the
# keeper is caught where the decoy left him, which is what a cross-crease play
# or a hard lateral drive actually produces.
func _fire_grid(spot: Vector3) -> Dictionary:
	var goals: int = 0
	var shots: int = 0
	var row := ""
	for loft: int in [ShotMechanics.ELEVATION_FLAT, ShotMechanics.ELEVATION_LOW,
			ShotMechanics.ELEVATION_HIGH]:
		for i: int in AIM_STEPS:
			var aim := Vector3(AIM_FROM_M + float(i) * AIM_STEP_M, 0.0, GOAL_Z)
			var cell := "s"
			for speed: float in FIRE_SPEEDS:
				shots += 1
				if _h.fire_at(spot, aim, loft, speed, 0.0) == Harness.GOAL:
					cell = "G"
					goals += 1
					break
			row += cell
	return {"row": row, "goals": goals, "shots": shots}


func _report_grid(label: String, spot: Vector3) -> float:
	var r: Dictionary = _fire_grid(spot)
	var rate: float = float(r["goals"]) / maxf(float(r["shots"]), 1.0)
	gut.p("    %-26s |%s|  %2d goals / %2d shots  (%.1f%%)"
			% [label, r["row"], r["goals"], r["shots"], 100.0 * rate])
	return rate


func test_report_a_moved_keeper_is_genuinely_easier_to_beat() -> void:
	gut.p("Live keeper, perfect execution. Each row is FLAT|LOW|HIGH x 13 aim")
	gut.p("points, best over %d speeds. G = goal." % FIRE_SPEEDS.size())
	for d: float in [3.0, 4.0, 5.0]:
		var spot := Vector3(0.0, 0.0, GOAL_Z + d)
		gut.p("  shooting from dead centre, %.1f m out:" % d)
		var _unused: Vector3 = _settled(spot)
		var set_rate: float = _report_grid("SET on the shooter", spot)
		var moved: float = 0.0
		for decoy_x: float in [4.0, -4.0]:
			_ctrl.reset_to_crease()
			_h.settle(Vector3(decoy_x, 0.0, GOAL_Z + d), SETTLE_TICKS)
			moved += _report_grid("caught wide (%+.0f m decoy)" % decoy_x, spot)
		moved *= 0.5
		gut.p("    -> catching him moving is worth %.1fx the set-keeper rate"
				% (moved / maxf(set_rate, 0.0001)))
	gut.p("  The compete cannot express any of this: see report B.")
	assert_true(true, "report")
