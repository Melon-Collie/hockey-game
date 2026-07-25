extends GutTest

# expected_goals (the xG stat) — SHAPE contract at the DEFAULT (settled) release
# spread: bounded, goalie-aware, and decoupled from the bot's aim-spread knob.
# The execution half of the model (release spread, context, floor/ceiling) and
# the sanity band against the location-only baseline live in
# test_expected_goals_calibration.gd.


const GOAL := Vector3(0.0, 0.0, -30.0)   # a goal line; exact z is irrelevant to shape
const SPEED: float = 28.0

func _nhw() -> float:
	return GameRules.NET_HALF_WIDTH


func _xg(shooter: Vector3, goalie: Vector3) -> float:
	return AIActionScoring.expected_goals(shooter, GOAL, goalie, _nhw(), SPEED)


func test_bounded_in_zero_to_xg_max() -> void:
	# Sweep a grid of shooter/goalie geometries; every value stays in [0, XG_MAX].
	for dist: float in [2.0, 6.0, 10.0, 16.0, 22.0]:
		var shooter := Vector3(0.0, 0.0, GOAL.z + dist)
		for gx: float in [-1.0, 0.0, 1.0]:
			var goalie := Vector3(gx, 0.0, GOAL.z + 1.2)
			var xg := _xg(shooter, goalie)
			assert_between(xg, 0.0, AIActionScoring.XG_MAX,
					"xG in [0, XG_MAX] at dist=%.0f gx=%.1f (%.3f)" % [dist, gx, xg])


func test_beaten_goalie_beats_a_square_goalie() -> void:
	# The core grounded property: a goalie pulled off the shot line leaves open
	# net → higher xG than a goalie squared on the puck at the same shot.
	var shooter := Vector3(0.0, 0.0, GOAL.z + 6.0)
	var square := Vector3(0.0, 0.0, GOAL.z + 1.5)          # on the puck→net line
	var beaten := Vector3(_nhw() + 0.4, 0.0, GOAL.z + 0.3) # stranded at the far post
	assert_gt(_xg(shooter, beaten), _xg(shooter, square),
			"a beaten goalie yields more open net than a square one")


func test_deeper_goalie_leaves_more_net_in_tight() -> void:
	# Depth is a real trade-off: sitting deep exposes more net angularly, but
	# buys more flight time to react to it. Pinned IN TIGHT, where the flight is
	# too short for the reaction to pay and the angular term dominates — a
	# challenging goalie 1.25 m off the puck geometrically eclipses the net.
	# (At long range the model resolves the same trade-off the other way, toward
	# reaction time; that's defensible, so it is deliberately not asserted.)
	var shooter := Vector3(0.0, 0.0, GOAL.z + 3.0)
	var deep := Vector3(0.0, 0.0, GOAL.z + 0.3)
	var challenging := Vector3(0.0, 0.0, GOAL.z + 1.75)
	assert_gt(_xg(shooter, deep), _xg(shooter, challenging),
			"in tight, a deep goalie exposes more net than one challenging out")


func test_wide_open_look_approaches_the_cap() -> void:
	# Point-blank with the goalie stranded post-to-post — a near-certain look
	# should sit near XG_MAX (and never exceed it).
	var shooter := Vector3(0.0, 0.0, GOAL.z + 3.0)
	var beaten := Vector3(_nhw() + 0.6, 0.0, GOAL.z + 0.2)
	var xg := _xg(shooter, beaten)
	assert_gt(xg, 0.6, "a wide-open point-blank look is a high-danger chance")
	assert_lte(xg, AIActionScoring.XG_MAX, "never exceeds the cap")


func test_decoupled_from_bot_aim_spread() -> void:
	# The stat must not move when bot aim/difficulty is retuned. open_net_danger
	# (the bot decision) changes with aim_spread; expected_goals takes no spread —
	# it is a single fixed value for the same geometry.
	var shooter := Vector3(0.0, 0.0, GOAL.z + 7.0)
	var goalie := Vector3(0.4, 0.0, GOAL.z + 1.5)
	var sharp := AIActionScoring.open_net_danger(shooter, GOAL, goalie, _nhw(), SPEED,
			0.0, -1.0, false, 0.0, false, 0.02)
	var loose := AIActionScoring.open_net_danger(shooter, GOAL, goalie, _nhw(), SPEED,
			0.0, -1.0, false, 0.0, false, 0.20)
	assert_ne(sharp, loose, "open_net_danger moves with the bot aim-spread knob")
	# expected_goals is stable — calling it is deterministic and spread-free.
	assert_eq(_xg(shooter, goalie), _xg(shooter, goalie),
			"expected_goals has no aim-spread input to move it")
