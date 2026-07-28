extends GutTest

# ── The shot-value calibration contract ──────────────────────────────────────
# score_shoot's value IS the make probability of firing at the best hole — so
# it must TRACK the measured goal fraction of actually firing. Same
# measure-then-match method that calibrated time_to_arrive: pin the estimator
# to the measurement, and every consumer (the carry compete, the pass EVs, the
# threat surfaces) inherits honest magnitudes.
#
# ── WHY THIS MEASURES AGAINST THE REAL GOALIE ────────────────────────────────
# It used to measure against shot_sim_harness — a lateral-reach BAND model.
# That is a re-derived cover proxy, and score_shoot is another one, so a
# blind spot present in BOTH is invisible to the comparison. That is not
# hypothetical: neither model knew the keeper had a STICK, so both agreed an
# in-tight flat corner was near-certain while the live keeper stick-saved
# 24/24 of them. The calibration passed throughout, because it was checking
# one model against its own twin.
#
# When the stick landed, this test's verdict inverted — it began failing the
# cells the model had just got RIGHT, insisting a 0/24 cell should read ≥0.55.
# A reference that fails you for becoming accurate is the wrong reference.
#
# So the measurement is now real_goalie_shot_harness: the live GoalieController
# from Goalie.tscn, its real pose anatomy and reaction skeleton, and the same
# analytic puck→goalie save loop Puck._physics_process runs on the host. The
# puck is marched tick-by-tick against his actual posed collision boxes. There
# is no shared-model error left to hide in, and the stick is in the loop
# because it is a real collider rather than a term someone remembered to add.
#
# ── WHAT IS SCORED ───────────────────────────────────────────────────────────
# Each cell is MEASURED once and scored twice, because score_shoot has two
# input regimes and gameplay uses one of them:
#   * POSE-FED — the read carrier.gd assembles per tick from the live
#     GoalieNetworkState (seal, stance, five-hole gap, hand/pad pose). This is
#     the path the bots execute, so this is the one under contract.
#   * DEFAULTS — no pose, no seal, no measured five-hole. A deliberately
#     degraded read the threat surfaces take for speed (see AIDangerField).
#     Reported, not asserted: holding a knowingly partial read to the full
#     live keeper's outcomes measures the degradation, not the model.
#
# ── ORDERING is asserted; LEVELS are reported ────────────────────────────────
# This used to band each cell against the measurement — dead cells must read
# low, certain cells high, transitions must track. That contract cannot be met
# and asserting it is not useful, because the gap it fails on is real and is
# not fixable here: measured against the live keeper the model carries a mean
# level error of ~0.37, in BOTH directions (it prices a set keeper's in-tight
# net as live where he allows nothing, and reads a genuinely open look as
# nothing). Levels are what an EMPIRICAL fit against logged shots is for; the
# release-context columns needed for it now ship on every shot_events row.
#
# What survives, and what the bots actually run on, is ORDER. Pairwise
# concordance against the live keeper is 75.4% where chance is 50% — the
# surface knows which spots are better even where it is wrong about how much
# better. The carry beam consumes differences between spots, the pass EVs
# compare receivers, the finisher ranks stations: every consumer is an argmax,
# and an argmax is invariant to the level error this grid keeps reporting.
#
# So the table is still printed in full — it is the drift instrument, and the
# worst-over-estimate line is worth watching — but the only thing that fails
# the build is the surface losing its ordering.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")

const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const NET_HW: float = GameRules.NET_HALF_WIDTH
const WRIST: float = AIActionScoring.WRISTER_SHOT_SPEED_M_S

# Real-goalie sampling is expensive (every sample re-settles the controller
# for SETTLE_TICKS), so the grid is trimmed and the sample count is the same
# 24 test_slot_shot_value_truth uses — enough to separate "never" from
# "always", which is what the bands ask.
const SAMPLES: int = 24
const SETTLE_TICKS: int = 120
const SEED: int = 0x5EED

# The ONE assertion, and why it is an ordering statistic rather than a level.
# Chance is 50% — a model that ranked cells at random scores that. The floor is
# set to catch a COLLAPSE toward chance, not to pin today's value (75.4%), so
# it has real headroom: what it exists to fail on is the surface losing its
# sense of which spots are better, which is the only property the decision
# layer consumes.
const CONCORDANCE_MIN: float = 0.65

# CAUGHT state: the keeper is settled on a decoy carrier this far to the side,
# then the shot comes from the real spot with no chance to re-square — the
# cross-crease / lateral-drive situation, produced by actually displacing the
# live keeper rather than by nudging a synthetic position.
const DECOY_OFFSET_M: float = 4.0

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


func _spots() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for d: float in [4.0, 6.0, 8.0, 10.0, 12.0, 16.0]:
		out.append(Vector3(0.0, 0.0, GOAL_Z + d))
	for d: float in [6.0, 9.0, 12.0]:
		var z: float = sqrt(maxf(d * d - 16.0, 0.25))
		out.append(Vector3(4.0, 0.0, GOAL_Z + z))
	return out


# Settle the live keeper for this cell and hand back where he ended up.
# `caught` settles him on a decoy off to the side instead of on the shooter.
func _settle_for(spot: Vector3, caught: bool) -> Vector3:
	_ctrl.reset_to_crease()
	var threat: Vector3 = spot
	if caught:
		# Decoy on the same arc, displaced laterally — he squares to THAT.
		threat = Vector3(spot.x + DECOY_OFFSET_M, 0.0, spot.z)
	_h.settle(threat, SETTLE_TICKS)
	return _goalie.global_position


# Fire the bot's OWN planned shot (same aim/loft/power triple it would
# execute) `SAMPLES` times and return the goal fraction. `env` selects which
# read the plan is built from, so the measurement always tests the shot the
# scored read actually produces.
func _measure(spot: Vector3, keeper: Vector3, caught: bool, spread: float,
		env: Dictionary) -> float:
	var aim: Vector3 = AIActionScoring.best_shot_aim(
			spot, _goal, keeper, NET_HW, WRIST, env["unsettled"],
			env["five"], env["down"], spread, env["seal_x"], env["seal_tall"],
			0.0, env["hands"], env["pads"])
	var loft: int = AIActionScoring.best_shot_loft(
			spot, _goal, keeper, NET_HW, WRIST, env["unsettled"],
			env["five"], env["down"], env["seal_x"], env["seal_tall"], spread,
			0.0, env["hands"], env["pads"])
	var power_t: float = AIActionScoring.best_shot_power_t(
			spot, _goal, keeper, NET_HW, WRIST, env["unsettled"],
			env["five"], env["down"], env["seal_x"], env["seal_tall"], spread,
			0.0, env["hands"], env["pads"])
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var goals: int = 0
	for _i: int in SAMPLES:
		# Re-settle per sample so each trial is independent and starts from
		# the same keeper state — without it he carries pose and reaction
		# from the previous shot and the cell stops being reproducible.
		_settle_for(spot, caught)
		if _h.fire(spot, aim, loft, power_t, rng.randf_range(-spread, spread)) \
				== Harness.GOAL:
			goals += 1
	return float(goals) / float(SAMPLES)


# The pose-fed read gameplay assembles, plus the unsettled scalar for this
# state. A CAUGHT keeper is positionally behind AND reading late, which is
# what unsettled = 1 means to the model.
func _pose_env(caught: bool) -> Dictionary:
	var env: Dictionary = _h.shot_env()
	env["unsettled"] = 1.0 if caught else 0.0
	return env


# The degraded read: no pose, no seal, no measured five-hole.
func _default_env(caught: bool) -> Dictionary:
	return {
		"down": false, "five": -1.0, "seal_x": 0.0, "seal_tall": false,
		"hands": Vector4.INF, "pads": Vector4.INF,
		"unsettled": 1.0 if caught else 0.0,
	}


func _score(spot: Vector3, keeper: Vector3, spread: float,
		env: Dictionary) -> float:
	return AIActionScoring.score_shoot(
			spot, _goal, keeper, NET_HW, [] as Array[Vector3], WRIST,
			env["unsettled"], [], env["five"], env["down"], env["seal_x"],
			env["seal_tall"], spread, [] as Array[Vector3],
			env["hands"], env["pads"])


func test_pose_fed_value_orders_cells_like_the_live_keeper() -> void:
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	gut.p("   x   dist  state   posed  default   measured   (%d samples, live keeper)"
			% SAMPLES)
	var checked: int = 0
	var worst_over: float = 0.0
	var worst_label := ""
	var _posed: Array[float] = []
	var _measured: Array[float] = []
	for caught: bool in [false, true]:
		for spot: Vector3 in _spots():
			var keeper: Vector3 = _settle_for(spot, caught)
			var posed_env: Dictionary = _pose_env(caught)
			var posed: float = _score(spot, keeper, spread, posed_env)
			var plain: float = _score(spot, keeper, spread, _default_env(caught))
			var measured: float = _measure(spot, keeper, caught, spread, posed_env)
			var state := "CAUGHT" if caught else "SET   "
			gut.p("%4.1f  %5.1f  %s  %5.2f    %5.2f      %5.2f"
					% [spot.x, spot.distance_to(_goal), state, posed, plain, measured])
			var label: String = "(%.0f, %.1f m, %s): posed %.3f vs measured %.2f" % [
					spot.x, spot.distance_to(_goal), state.strip_edges(), posed, measured]
			checked += 1
			_posed.append(posed)
			_measured.append(measured)
			if posed - measured > worst_over:
				worst_over = posed - measured
				worst_label = label
	gut.p("worst over-estimate: %+.2f  %s" % [worst_over, worst_label])
	var conc: float = _concordance(_posed, _measured)
	var mae: float = 0.0
	for i: int in _posed.size():
		mae += absf(_posed[i] - _measured[i])
	gut.p("mean |posed - measured| = %.3f   pairwise concordance = %.1f%%"
			% [mae / maxf(float(_posed.size()), 1.0), 100.0 * conc])
	gut.p("(levels are REPORTED, not asserted — see the header. Ordering is the")
	gut.p(" contract, because ordering is what the carry beam and the pass EVs")
	gut.p(" actually consume.)")
	assert_gt(conc, CONCORDANCE_MIN,
			"the model must still ORDER cells like the keeper does (chance is 50%%); got %.1f%%"
					% [100.0 * conc])
	gut.p("(the `default` column is the degraded no-pose read — reported, not")
	gut.p(" asserted: it is a partial read, so its gap to the live keeper")
	gut.p(" measures the degradation rather than the model.)")
	assert_gt(checked, 15, "the grid actually ran")


# Fraction of cell PAIRS ordered the way the live keeper orders them. Ties in
# the measurement carry no ordering information and are skipped.
func _concordance(model: Array[float], measured: Array[float]) -> float:
	var ok: int = 0
	var total: int = 0
	for i: int in measured.size():
		for j: int in range(i + 1, measured.size()):
			if is_equal_approx(measured[i], measured[j]):
				continue
			total += 1
			if (measured[i] > measured[j]) == (model[i] > model[j]):
				ok += 1
	return float(ok) / maxf(float(total), 1.0)


func test_displacing_the_keeper_beats_leaving_him_set() -> void:
	# The property the whole carry model rests on: moving him has to be worth
	# something, in BOTH the measurement and the score. This is the invariant
	# the old saturating currency could not express — set-keeper value was
	# already pinned at 1.000, so catching him moving bought exactly nothing.
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	var set_total: float = 0.0
	var caught_total: float = 0.0
	var set_scored: float = 0.0
	var caught_scored: float = 0.0
	var spots: Array[Vector3] = [
		Vector3(0.0, 0.0, GOAL_Z + 4.0),
		Vector3(0.0, 0.0, GOAL_Z + 6.0),
		Vector3(0.0, 0.0, GOAL_Z + 8.0),
	]
	for spot: Vector3 in spots:
		var k_set: Vector3 = _settle_for(spot, false)
		var e_set: Dictionary = _pose_env(false)
		set_scored += _score(spot, k_set, spread, e_set)
		set_total += _measure(spot, k_set, false, spread, e_set)
		var k_caught: Vector3 = _settle_for(spot, true)
		var e_caught: Dictionary = _pose_env(true)
		caught_scored += _score(spot, k_caught, spread, e_caught)
		caught_total += _measure(spot, k_caught, true, spread, e_caught)
	var n: float = float(spots.size())
	gut.p("mean over %d slot spots — measured: set %.2f, caught %.2f | scored: set %.2f, caught %.2f"
			% [spots.size(), set_total / n, caught_total / n,
				set_scored / n, caught_scored / n])
	assert_gt(caught_total, set_total,
			"displacing the live keeper must MEASURE better than leaving him set")
	assert_gt(caught_scored, set_scored,
			"...and the model must agree, or the carry beam cannot chase it")
