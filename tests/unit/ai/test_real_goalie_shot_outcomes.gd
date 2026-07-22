extends GutTest

# ── Ground-truth shot-outcome measurement (measure-then-match, #4) ────────────
# Fires representative flat vs top-corner shots at the REAL GoalieController +
# REAL analytic save collision (real_goalie_shot_harness) and reports the goal
# rate per (range × loft). This is the reference the lateral-band instrument
# (shot_sim_harness) and score_shoot's HIGH/LOW cover are reconciled to.
#
# The user-observed behaviour under test: a well-placed top-corner shot "does go
# in," yet the bot's model de-emphasises it. The report columns are what let us
# see whether the live goalie is actually beaten up high more than the band
# model + score_shoot believe — and by how much, so the reconciliation is a
# measurement, not a hand-cranked dial.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const Sim := preload("res://tests/unit/ai/shot_sim_harness.gd")

const SAMPLES: int = 16
const RESETTLE_TICKS: int = 75
const SEED: int = 0x5EED

var _goal := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
var _h: RefCounted = null


func before_each() -> void:
	var goalie: Node = load("res://Scenes/Goalie.tscn").instantiate()
	var puck: Node = load("res://Scenes/Puck.tscn").instantiate()
	var shooter: Skater = load("res://Scenes/Skater.tscn").instantiate() as Skater
	add_child_autofree(goalie)
	add_child_autofree(puck)
	add_child_autofree(shooter)
	var ctrl := GoalieController.new()
	add_child_autofree(ctrl)
	_h = Harness.new()
	_h.setup(goalie, puck, ctrl, shooter)


# Top-corner aim on `side` (-1 left / +1 right): just inside the post laterally,
# a puck-radius under the crossbar, at the goal line.
func _top_corner_aim(side: float) -> Vector3:
	var x: float = side * (GameRules.NET_HALF_WIDTH
			- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS)
	var y: float = GameRules.NET_HEIGHT - GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS
	return Vector3(x, y, _goal.z)


# Low-corner aim on `side`: just inside the post, along the ice.
func _low_corner_aim(side: float) -> Vector3:
	var x: float = side * (GameRules.NET_HALF_WIDTH
			- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS)
	return Vector3(x, 0.0, _goal.z)


func _goal_frac(counts: Dictionary) -> float:
	var shots: int = counts["shots"]
	return float(counts[Harness.GOAL]) / float(maxi(shots, 1))


func test_report_real_goalie_goal_rates_by_loft() -> void:
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	var rng := RandomNumberGenerator.new()
	gut.p("range side | pick(loft) goal%% | forced-HIGH goal%% | forced-FLAT goal%%   (real goalie, %d samples)" % SAMPLES)
	var spots := [
		Vector3(0.0, 0.0, _goal.z + 5.0),
		Vector3(0.0, 0.0, _goal.z + 8.0),
		Vector3(0.0, 0.0, _goal.z + 11.0),
		Vector3(3.5, 0.0, _goal.z + 7.0),
		Vector3(3.5, 0.0, _goal.z + 10.0),
	]
	var pick_beats_flat_intight: bool = false
	var high_beats_flat_intight: bool = false
	for spot: Vector3 in spots:
		# Aim to the side AWAY from the shooter's x (the open far corner); dead
		# centre defaults to the glove side (-1) as the conventional pick.
		var side: float = -signf(spot.x) if absf(spot.x) > 0.1 else -1.0
		var dist: float = spot.distance_to(_goal)
		var g2 := Vector3(0.0, 0.0, 0.0)  # bot uses its predicted set goalie
		_h.settle(spot, 90)
		g2 = Vector3(_h._goalie.global_position.x, 0.0, _h._goalie.global_position.z)
		var pick_aim: Vector3 = AIActionScoring.best_shot_aim(spot, _goal, g2,
				GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				0.0, -1.0, false, spread)
		var pick_loft: int = AIActionScoring.best_shot_loft(spot, _goal, g2,
				GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				0.0, -1.0, false, 0.0, false, spread)
		var pick_pt: float = AIActionScoring.best_shot_power_t(spot, _goal, g2,
				GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				0.0, -1.0, false, 0.0, false, spread)
		rng.seed = SEED
		var pick: Dictionary = _h.run_spot(spot, pick_aim, pick_loft, pick_pt,
				spread, SAMPLES, RESETTLE_TICKS, rng)
		rng.seed = SEED
		var high: Dictionary = _h.run_spot(spot, _top_corner_aim(side),
				ShotMechanics.ELEVATION_HIGH, 1.0, spread, SAMPLES, RESETTLE_TICKS, rng)
		rng.seed = SEED
		var low: Dictionary = _h.run_spot(spot, _low_corner_aim(side),
				ShotMechanics.ELEVATION_FLAT, 1.0, spread, SAMPLES, RESETTLE_TICKS, rng)
		var pf: float = _goal_frac(pick)
		var hf: float = _goal_frac(high)
		var lf: float = _goal_frac(low)
		gut.p("%4.1fm %+d  |  %d: %5.1f%%      |    %5.1f%%       |    %5.1f%%" % [
				dist, int(side), pick_loft, pf * 100.0, hf * 100.0, lf * 100.0])
		if pf > 0.001:
			pick_beats_flat_intight = true
		if hf > 0.001 or lf > 0.001:
			high_beats_flat_intight = true
	# Robust invariant (not a calibration target — the per-cell rates are the
	# measurement, read them from the report): a beatable-realism goalie must
	# concede SOME goals to a well-placed shot across the slot, and the bot's own
	# picked shot must score somewhere too. If either goes fully dry, the harness
	# is broken (or the goalie became a brick wall), not merely noisy.
	assert_true(high_beats_flat_intight,
			"a placed corner beats the real goalie somewhere across the slot")
	assert_true(pick_beats_flat_intight,
			"the bot's own picked shot scores somewhere across the slot")


const _OUTCOME := ["GOAL", "SAVE", "POST", "WIDE", "NO_SHOT"]
const _PART := ["STICK", "PAD", "BLOCKER", "CHEST", "GLOVE"]


func _part_name(p: int) -> String:
	return _PART[p] if p >= 0 and p < _PART.size() else "none"


func test_debug_single_shots() -> void:
	# Deterministic (no scatter) probe: fire the BOT-PICKED shot and forced
	# corners from a few spots, print outcome + contact so I can see whether the
	# real goalie is genuinely covering or the harness is over-saving.
	for dist: float in [6.0, 8.0, 10.0, 13.0]:
		var spot := Vector3(0.0, 0.0, _goal.z + dist)
		_h.settle(spot, 120)
		var goalie_set: Vector3 = _h._goalie.global_position
		# The bot's own pick.
		var g2 := Vector3(goalie_set.x, 0.0, goalie_set.z)
		var aim: Vector3 = AIActionScoring.best_shot_aim(spot, _goal, g2,
				GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				0.0, -1.0, false, 0.0)
		var loft: int = AIActionScoring.best_shot_loft(spot, _goal, g2,
				GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				0.0, -1.0, false, 0.0, false, 0.0)
		var pt: float = AIActionScoring.best_shot_power_t(spot, _goal, g2,
				GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				0.0, -1.0, false, 0.0, false, 0.0)
		_h.settle(spot, 90)
		var o_pick: int = _h.fire(spot, aim, loft, pt, 0.0)
		gut.p("%.0fm goalie@(%.2f,%.2f) | PICK aim(%.2f,%.2f) loft=%d pt=%.2f -> %s part=%s cross=%s" % [
				dist, goalie_set.x, goalie_set.z, aim.x, aim.y, loft, pt,
				_OUTCOME[o_pick], _part_name(_h.last_part),
				str(_h.last_cross)])
		# Forced top-corner high.
		_h.settle(spot, 90)
		var o_hi: int = _h.fire(spot, _top_corner_aim(-1.0), ShotMechanics.ELEVATION_HIGH, 1.0, 0.0)
		gut.p("      HIGH corner -> %s part=%s contact=%s cross=%s" % [
				_OUTCOME[o_hi], _part_name(_h.last_part),
				str(_h.last_contact_pos.snappedf(0.01)), str(_h.last_cross.snappedf(0.01))])
		# Forced low-corner flat.
		_h.settle(spot, 90)
		var o_lo: int = _h.fire(spot, _low_corner_aim(-1.0), ShotMechanics.ELEVATION_FLAT, 1.0, 0.0)
		gut.p("      LOW  corner -> %s part=%s contact=%s cross=%s" % [
				_OUTCOME[o_lo], _part_name(_h.last_part),
				str(_h.last_contact_pos.snappedf(0.01)), str(_h.last_cross.snappedf(0.01))])
	assert_true(true, "report-only")


func test_report_band_instrument_vs_real_on_top_corner() -> void:
	# Side-by-side: the band instrument's goal fraction (what score_shoot is
	# calibrated to) vs the real goalie, on the SAME top-corner shots. A large
	# gap here is the miscalibration to fix.
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	var rng := RandomNumberGenerator.new()
	gut.p("range | HIGH real goal%% | HIGH band goal%%   (top corner, full pace)")
	for dist: float in [5.0, 8.0, 11.0, 14.0]:
		var spot := Vector3(0.0, 0.0, _goal.z + dist)
		var aim: Vector3 = _top_corner_aim(-1.0)
		rng.seed = SEED
		var real: Dictionary = _h.run_spot(spot, aim, ShotMechanics.ELEVATION_HIGH,
				1.0, spread, SAMPLES, RESETTLE_TICKS, rng)
		# Band instrument on the same top-corner triple.
		var goalie: Vector3 = Sim.goalie_set_pos(spot, _goal)
		rng.seed = SEED
		var band_goals: int = 0
		for _i: int in SAMPLES:
			var err: float = rng.randf_range(-spread, spread)
			if Sim.classify_shot(spot, _goal, goalie, aim,
					ShotMechanics.ELEVATION_HIGH, 1.0, err, 0.0) == Sim.GOAL:
				band_goals += 1
		gut.p("%4.1fm |   %5.1f%%        |   %5.1f%%" % [
				dist, _goal_frac(real) * 100.0,
				float(band_goals) / float(SAMPLES) * 100.0])
	assert_true(true, "report-only")
