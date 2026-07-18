extends GutTest

# Drives the full-rush sim (rush_sim_harness.gd): a real tracking goalie stepped
# along scripted rushes, then a real shot against wherever the tracking left him.
# Unlike the set-goalie shot-outcome sim, the caught-moving state is EMERGENT, so
# the save rates are trustworthy. Prints the GOAL/SAVE/POST/WIDE distribution per
# rush shape and per tier (the deliverable); assertions are loose invariants.
# Deterministic via a fixed seed.

const Rush := preload("res://tests/unit/ai/rush_sim_harness.gd")
const Shot := preload("res://tests/unit/ai/shot_sim_harness.gd")
const SAMPLES: int = 400
const SEED: int = 0x1CE

var _goal := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)


# Named rush shapes → per-tick carrier paths.
func _scenarios() -> Dictionary:
	var gz: float = _goal.z
	return {
		"straight-slot": Rush.drive(
				Vector3(0.0, 0.0, gz + 14.0), Vector3(0.0, 0.0, gz + 6.0)),
		"off-wing":      Rush.drive(
				Vector3(6.0, 0.0, gz + 14.0), Vector3(1.5, 0.0, gz + 7.0)),
		"cross-carry":   Rush.drive(
				Vector3(6.0, 0.0, gz + 10.0), Vector3(-3.0, 0.0, gz + 7.0)),
		"cross-pass":    Rush.cross_seam_pass(
				Vector3(6.0, 0.0, gz + 8.0), Vector3(-4.0, 0.0, gz + 7.0), 24),
	}


func _pct(n: int, d: int) -> float:
	return 100.0 * float(n) / float(maxi(d, 1))


func _row(label: String, t: Dictionary) -> void:
	var shots: int = t["shots"]
	var total: int = shots + t[Shot.NO_SHOT]
	gut.p("  %-13s shoot%% %5.1f | GOAL %5.1f  SAVE %5.1f  POST %5.1f  WIDE %5.1f" % [
			label, _pct(shots, total),
			_pct(t[Shot.GOAL], shots), _pct(t[Shot.SAVE], shots),
			_pct(t[Shot.POST], shots), _pct(t[Shot.WIDE], shots)])


func _blank() -> Dictionary:
	return {Shot.GOAL: 0, Shot.SAVE: 0, Shot.POST: 0, Shot.WIDE: 0,
			Shot.NO_SHOT: 0, "shots": 0}


func _add(into: Dictionary, from: Dictionary) -> void:
	for k: Variant in from:
		into[k] += from[k]


func test_rush_outcome_distribution() -> void:
	var scenarios: Dictionary = _scenarios()
	for tier: String in ["HARD", "NORMAL", "EASY"]:
		var profile: BotSkillProfile = (BotSkillProfile.hard() if tier == "HARD"
				else BotSkillProfile.normal() if tier == "NORMAL"
				else BotSkillProfile.easy())
		gut.p("── %s ──" % tier)
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED
		var tier_tot: Dictionary = _blank()
		for name: String in scenarios:
			var c: Dictionary = Rush.run_rush(scenarios[name], _goal, profile, SAMPLES, rng)
			_row(name, c)
			_add(tier_tot, c)
		_row("ALL", tier_tot)
		# The goalie is genuinely in the play across a mix of rushes (every tier).
		assert_gt(tier_tot[Shot.SAVE], 0, "%s: the goalie makes saves on the rush" % tier)
		assert_eq(tier_tot[Shot.GOAL] + tier_tot[Shot.SAVE] + tier_tot[Shot.POST]
				+ tier_tot[Shot.WIDE], tier_tot["shots"],
				"%s: outcomes partition the shots" % tier)


func test_tier_scoring_gradient_on_the_rush() -> void:
	# The robust, mix-independent signal: a sharper hand converts a higher share
	# of its rush shots — Hard buries more than Easy against the same active
	# goalie. (Absolute per-scenario rates are NOT trustworthy — see the harness
	# doc; the tier ORDERING is what holds across scenario choices.)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var scen: Dictionary = _scenarios()
	var hard := _blank()
	var easy := _blank()
	for name: String in scen:
		_add(hard, Rush.run_rush(scen[name], _goal, BotSkillProfile.hard(), SAMPLES, rng))
		_add(easy, Rush.run_rush(scen[name], _goal, BotSkillProfile.easy(), SAMPLES, rng))
	assert_gt(hard[Shot.GOAL], 0, "Hard scores on the rush")
	assert_gt(_pct(hard[Shot.GOAL], hard["shots"]), _pct(easy[Shot.GOAL], easy["shots"]),
			"Hard converts a higher share of its rush shots than Easy")
