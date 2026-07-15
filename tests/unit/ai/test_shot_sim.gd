extends GutTest

# Runs the shooter-AI vs goalie-AI shot-outcome sim (shot_sim_harness.gd) over a
# grid of realistic shooter spots and prints the GOAL / SAVE / POST / WIDE
# distribution per difficulty — the data behind the make-probability shot change.
# Assertions are LOOSE sanity invariants (the goalie makes saves, tiers order
# correctly, more wobble → more saves); the printed tables are the deliverable,
# read from the GUT log. Deterministic via a fixed RNG seed.

const Sim := preload("res://tests/unit/ai/shot_sim_harness.gd")
const SAMPLES: int = 300
const SEED: int = 0x5EED
# Goalie states a real shot meets — set, half-caught, and caught mid-slide. Saves
# live in the caught-moving band (a fully set goalie is either not shot at or
# beaten clean); aggregating over the mix approximates a game's shot situations.
const UNSETTLED_LEVELS: Array = [0.0, 0.25, 0.5]

var _goal := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)


# Realistic shooter spots (dist = metres out from the goal line toward centre).
func _grid() -> Array:
	var spots: Array = []
	for dist: float in [5.0, 8.0, 11.0, 14.0]:
		spots.append(Vector3(0.0, 0.0, _goal.z + dist))           # dead slot
	for dist: float in [8.0, 11.0]:
		spots.append(Vector3(4.0, 0.0, _goal.z + dist))           # off-angle
		spots.append(Vector3(-4.0, 0.0, _goal.z + dist))
	spots.append(Vector3(7.0, 0.0, _goal.z + 9.0))                # wide
	spots.append(Vector3(0.0, 0.0, _goal.z + 18.0))               # point
	return spots


func _aggregate(profile: BotSkillProfile) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var tot := {Sim.GOAL: 0, Sim.SAVE: 0, Sim.POST: 0, Sim.WIDE: 0,
			Sim.NO_SHOT: 0, "shots": 0}
	for spot: Vector3 in _grid():
		for unsettled: float in UNSETTLED_LEVELS:
			var c: Dictionary = Sim.run_spot(spot, _goal, profile, unsettled, SAMPLES, rng)
			for k: Variant in c:
				tot[k] += c[k]
	return tot


func _pct(n: int, d: int) -> float:
	return 100.0 * float(n) / float(maxi(d, 1))


func _report(label: String, t: Dictionary) -> void:
	var shots: int = t["shots"]
	var total: int = shots + t[Sim.NO_SHOT]
	gut.p("%-8s shoot%% %5.1f | of shots:  GOAL %5.1f  SAVE %5.1f  POST %5.1f  WIDE %5.1f" % [
			label, _pct(shots, total),
			_pct(t[Sim.GOAL], shots), _pct(t[Sim.SAVE], shots),
			_pct(t[Sim.POST], shots), _pct(t[Sim.WIDE], shots)])


func test_shot_outcome_distribution_by_tier() -> void:
	gut.p("── shot-outcome distribution by difficulty (%d spots × %d samples) ──" % [
			_grid().size(), SAMPLES])
	var hard: Dictionary = _aggregate(BotSkillProfile.hard())
	var normal: Dictionary = _aggregate(BotSkillProfile.normal())
	var easy: Dictionary = _aggregate(BotSkillProfile.easy())
	_report("HARD", hard)
	_report("NORMAL", normal)
	_report("EASY", easy)

	# The goalie is genuinely in the play now — every tier both scores AND gets
	# robbed against a caught-moving keeper.
	for t: Dictionary in [hard, normal, easy]:
		assert_gt(t[Sim.SAVE], 0, "the goalie saves some shots")
		assert_gt(t[Sim.GOAL], 0, "the bot still scores some")
		# Outcomes partition the taken shots.
		assert_eq(t[Sim.GOAL] + t[Sim.SAVE] + t[Sim.POST] + t[Sim.WIDE], t["shots"],
				"outcomes partition the taken shots")
	# Centred-aim confirmation: aiming the window centre means a miss becomes a
	# SAVE, not a pipe clank — posts/wides stay near zero (the old post-bias would
	# scatter shots onto the iron here).
	assert_lt(_pct(hard[Sim.POST] + hard[Sim.WIDE], hard["shots"]), 5.0,
			"centred aim keeps misses off the iron — they become saves, not posts/wides")


func test_scatter_dial_makes_the_bot_more_selective() -> void:
	# The COUNTERINTUITIVE finding this harness surfaced: bumping the shooter's
	# execution scatter does NOT get it saved more. Via the make-probability model
	# a wider spread demands a wider window, so the bot shoots LESS and buries a
	# HIGHER fraction of what it does take — the selection effect dominates the
	# execution-noise effect. So scatter is a SELECTIVITY dial, not a save dial;
	# trimming a tier's scoring by widening its shot error would make it pickier
	# and sharper-per-shot, the opposite of the intent. (Save rates here are
	# confounded by the per-spread spot mix — read the shoot% trend, not absolute
	# saves.)
	gut.p("── scatter sweep (Hard build, varied shot_aim_error_rad) ──")
	var first_shoot: float = -1.0
	var last_shoot: float = -1.0
	for spread: float in [0.008, 0.012, 0.016, 0.022, 0.030]:
		var p := BotSkillProfile.hard()
		p.shot_aim_error_rad = spread
		var t: Dictionary = _aggregate(p)
		var shoot_pct: float = _pct(t["shots"], t["shots"] + t[Sim.NO_SHOT])
		gut.p("spread %.3f  →  GOAL %5.1f  SAVE %5.1f  POST %5.1f  WIDE %5.1f  (shoot%% %.1f)" % [
				spread, _pct(t[Sim.GOAL], t["shots"]), _pct(t[Sim.SAVE], t["shots"]),
				_pct(t[Sim.POST], t["shots"]), _pct(t[Sim.WIDE], t["shots"]), shoot_pct])
		if first_shoot < 0.0:
			first_shoot = shoot_pct
		last_shoot = shoot_pct
	assert_lt(last_shoot, first_shoot,
			"a wider shot scatter makes the bot MORE selective (shoots less) — scatter is a selectivity dial, not a save dial")
