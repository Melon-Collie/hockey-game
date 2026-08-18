extends GutTest

# Guards the net-geometry mirrors: HockeyGoal's frame constants MUST stay in sync
# with the GameRules constants of the same quantities. Six of these pairs already
# carry a "must match HockeyGoal.X" comment; this file is what makes those
# comments executable.
#
# Why it matters: HockeyGoal draws the net the player SEES, while every analytic
# path — NetGeometry, PuckGeometryCollision, GoalDetectionRules, the native puck
# step, and the AI's shot model — reasons against GameRules. The frame carries no
# collider, so a drift never shows up as a physics error anyone trips over. It
# shows up as a puck passing through a visible post, or stopping at empty air
# beside one, with nothing else in the codebase to catch it.
#
# NOT ASSERTED HERE: GameRules.NET_DEPTH (1.02) vs HockeyGoal.BASE_DEPTH (1.016).
# They are the same physical quantity — goal depth from the goal line to the back
# frame — and they currently disagree by 4 mm, so the collision net is fractionally
# deeper than the drawn one. 1.016 m is exactly 40" (the NHL rulebook value the
# HockeyGoal comment cites) and 1.02 is that number rounded, which reads as drift
# rather than intent. Resolving it means moving one of the two, which shifts either
# puck collision or the mesh, so it is a deliberate call rather than a mechanical
# fix. Add the assertion once the pair is single-sourced.


func test_post_half_width_mirrors_goal_width() -> void:
	assert_almost_eq(GameRules.NET_HALF_WIDTH, HockeyGoal.POST_HALF_WIDTH, 1e-6,
			"GameRules.NET_HALF_WIDTH must equal HockeyGoal.POST_HALF_WIDTH " +
			"(GOAL_WIDTH / 2) — the post centerlines the goal mouth is measured between.")


func test_post_radius_mirrors() -> void:
	assert_almost_eq(GameRules.NET_POST_RADIUS, HockeyGoal.POST_RADIUS, 1e-6,
			"GameRules.NET_POST_RADIUS must equal HockeyGoal.POST_RADIUS — the pipe " +
			"the puck-vs-post ejection solves against is the pipe that gets drawn.")


func test_crossbar_height_mirrors() -> void:
	assert_almost_eq(GameRules.NET_HEIGHT, HockeyGoal.NET_HEIGHT, 1e-6,
			"GameRules.NET_HEIGHT must equal HockeyGoal.NET_HEIGHT — the crossbar " +
			"centerline that bounds the goal mouth vertically.")


func test_crown_half_width_mirrors() -> void:
	assert_almost_eq(GameRules.NET_CROWN_HALF_WIDTH, HockeyGoal.CROWN_HALF_WIDTH, 1e-6,
			"GameRules.NET_CROWN_HALF_WIDTH must equal HockeyGoal.CROWN_HALF_WIDTH — " +
			"the top net panel's span, which NetGeometry uses to slope the back.")


func test_mouth_corner_radius_mirrors() -> void:
	assert_almost_eq(GameRules.NET_MOUTH_CORNER_RADIUS, HockeyGoal.MOUTH_CORNER_RADIUS, 1e-6,
			"GameRules.NET_MOUTH_CORNER_RADIUS must equal HockeyGoal.MOUTH_CORNER_RADIUS — " +
			"the post-to-crossbar bend. NetGeometry derives the straight post's top from it.")


func test_top_depth_mirrors() -> void:
	assert_almost_eq(GameRules.NET_TOP_DEPTH, HockeyGoal.TOP_DEPTH, 1e-6,
			"GameRules.NET_TOP_DEPTH must equal HockeyGoal.TOP_DEPTH — the depth of the " +
			"top shelf, which sets the back panel's slope in both the mesh and the solver.")


# The crown span is not independent: HockeyGoal derives it, and GameRules states it
# as a literal. Pinning the derivation catches a change to either input that only
# one side follows.
func test_crown_span_derivation_holds_on_both_sides() -> void:
	assert_almost_eq(HockeyGoal.CROWN_HALF_WIDTH,
			HockeyGoal.POST_HALF_WIDTH - HockeyGoal.MOUTH_CORNER_RADIUS, 1e-6,
			"HockeyGoal.CROWN_HALF_WIDTH is POST_HALF_WIDTH − MOUTH_CORNER_RADIUS by construction")
	assert_almost_eq(GameRules.NET_CROWN_HALF_WIDTH,
			GameRules.NET_HALF_WIDTH - GameRules.NET_MOUTH_CORNER_RADIUS, 1e-6,
			"GameRules states NET_CROWN_HALF_WIDTH as a literal — it must still satisfy " +
			"NET_HALF_WIDTH − NET_MOUTH_CORNER_RADIUS, or the two sides describe different frames.")
