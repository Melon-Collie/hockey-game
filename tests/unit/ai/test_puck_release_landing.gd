extends GutTest

# Closed-form released-puck landing (AITrajectory.puck_release_landing and the
# runout pair) — where a dumped/cleared puck actually comes to REST, and whether
# it reached a goal line on the way.
#
# The dump prices its concession at the spot it AIMS at. These functions exist to
# give it the spot the puck STOPS at instead, cheaply enough to ask per delivery
# inside the carrier compete (the stepped walk is ~1 us/step and a full runout is
# ~270 steps — see benchmarks/test_ai_micro_benchmark.gd).
#
# The load-bearing test in this file is the cross-validation: a closed form that
# disagrees with AITrajectory's own stepped integrator would be worse than no
# model at all, because every other consumer of puck paths (reception gate,
# chase election, shadow comparator) walks the stepped one.

const STEP_DT: float = 0.005


func _stepped_landing(origin: Vector3, vel: Vector3, seconds: float) -> Vector3:
	return AITrajectory.predict_final(
			origin, vel, int(seconds / STEP_DT), STEP_DT,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.PUCK_BOARD_BOUNCE,
			Vector3.ZERO, 0.0, GameRules.PUCK_BOARD_FRICTION)


func _landing(origin: Vector3, vel: Vector3, hang_s: float = 0.0) -> Vector3:
	return AITrajectory.puck_release_landing(origin, vel, hang_s).origin


# ── The runout pair ──────────────────────────────────────────────────────────

func test_runout_is_the_v_squared_over_2a_slide() -> void:
	# Hand-checked against the constants rather than the implementation:
	# 14^2 / (2 * 0.05 * 9.8) = 200 m.
	assert_almost_eq(AITrajectory.puck_runout_m(14.0), 200.0, 0.5,
			"quick-pass pace slides ~200 m — three rink lengths")
	assert_eq(AITrajectory.puck_runout_m(0.0), 0.0)


func test_runout_and_launch_speed_invert_each_other() -> void:
	for speed: float in [3.0, 6.6, 10.0, 14.0, 25.0]:
		var d: float = AITrajectory.puck_runout_m(speed)
		assert_almost_eq(AITrajectory.puck_launch_speed_for_runout(d), speed, 0.001,
				"launch_speed_for_runout inverts runout_m at %.1f m/s" % speed)


func test_no_release_the_bot_can_produce_dies_inside_the_rink() -> void:
	# The finding that shapes the dump's options: the softest release in the
	# wrister band, and the fixed quick-pass pace, both out-slide the rink. A
	# clear cannot be made to stop short of the far goal line by choosing a pace.
	var rink_length: float = 2.0 * GameRules.INNER_HALF_LENGTH
	assert_gt(AITrajectory.puck_runout_m(GameRules.DEFAULT_WRISTER_POWER_MIN_M_S),
			rink_length, "the softest wrister still out-slides the rink")
	assert_gt(AITrajectory.puck_runout_m(GameRules.DEFAULT_QUICK_PASS_POWER_M_S),
			rink_length, "the quick-pass pace still out-slides the rink")
	# What a legal clear WOULD need, reported so the number is visible rather
	# than re-derived: goal line to goal line, and from our blue line.
	gut.p("  legal-clear pace, our goal line -> theirs (%.1f m): %.2f m/s"
			% [2.0 * GameRules.GOAL_LINE_Z,
			AITrajectory.puck_launch_speed_for_runout(2.0 * GameRules.GOAL_LINE_Z)])
	gut.p("  legal-clear pace, our blue line -> their goal line (%.1f m): %.2f m/s"
			% [GameRules.BLUE_LINE_Z + GameRules.GOAL_LINE_Z,
			AITrajectory.puck_launch_speed_for_runout(
					GameRules.BLUE_LINE_Z + GameRules.GOAL_LINE_Z)])
	gut.p("  softest wrister (%.1f m/s) runout: %.1f m"
			% [GameRules.DEFAULT_WRISTER_POWER_MIN_M_S,
			AITrajectory.puck_runout_m(GameRules.DEFAULT_WRISTER_POWER_MIN_M_S)])


# ── Open ice: the closed form IS the runout ──────────────────────────────────

func test_open_ice_landing_is_the_runout_along_the_launch_line() -> void:
	# Slow enough to stop before any board, so there is one leg and the answer
	# is pure arithmetic.
	var origin := Vector3(0.0, 0.0, 10.0)
	var vel := Vector3(0.0, 0.0, -3.0)
	var landing: Vector3 = _landing(origin, vel)
	assert_almost_eq(landing.z, 10.0 - AITrajectory.puck_runout_m(3.0), 0.01,
			"stops at origin + runout down the launch line")
	assert_almost_eq(landing.x, 0.0, 0.01, "no lateral drift on a straight slide")


func test_airborne_time_carries_the_puck_without_spending_runout() -> void:
	# A chip's hang time is frictionless: it covers launch_speed * hang_s of
	# ground for free, then begins its slide. This is why loft is a real lever
	# on where a dump ends up and pace alone is not.
	var origin := Vector3(0.0, 0.0, 10.0)
	var vel := Vector3(0.0, 0.0, -3.0)
	var flat: Vector3 = _landing(origin, vel, 0.0)
	var chipped: Vector3 = _landing(origin, vel, 0.9)
	assert_almost_eq(flat.z - chipped.z, 3.0 * 0.9, 0.01,
			"hang time adds launch_speed * hang_s of carry, no runout spent")


# ── Cross-validation against the stepped integrator ──────────────────────────

func test_matches_the_stepped_walk_in_open_ice() -> void:
	var origin := Vector3(-4.0, 0.0, 12.0)
	var vel := Vector3(1.5, 0.0, -4.0)
	var closed: Vector3 = _landing(origin, vel)
	var stepped: Vector3 = _stepped_landing(origin, vel, 12.0)
	assert_almost_eq(closed.x, stepped.x, 0.25, "open-ice landing x matches the walk")
	assert_almost_eq(closed.z, stepped.z, 0.25, "open-ice landing z matches the walk")


func test_matches_the_stepped_walk_through_a_side_board() -> void:
	# Fired into the side wall at a steep angle — the contact that actually
	# sheds speed, so both the carom direction and the bleed have to agree.
	var origin := Vector3(0.0, 0.0, 0.0)
	var vel := Vector3(6.0, 0.0, -3.0)
	var closed: Vector3 = _landing(origin, vel)
	var stepped: Vector3 = _stepped_landing(origin, vel, 20.0)
	assert_almost_eq(closed.x, stepped.x, 0.6, "post-carom landing x matches the walk")
	assert_almost_eq(closed.z, stepped.z, 0.6, "post-carom landing z matches the walk")


func test_matches_the_stepped_walk_around_a_corner() -> void:
	# The rim into the corner — the delivery the dump model exists to price.
	#
	# This is the closed form's WEAK case and the tolerances say so. A corner rim
	# takes many near-tangential contacts, and on an arc the inward normal turns
	# with the contact point, so a few centimetres of disagreement about where a
	# contact happened rotates the next leg and compounds. The two models agree
	# closely on the axis the decision usually rests on (the puck ends deep in
	# the far end) and only loosely across the ice.
	#
	# The x spread here exceeds AIActionScoring.CHASE_CONTEST_MARGIN_M, so it is
	# large enough to flip a recovery race. That is the argument for spending one
	# stepped walk to CONFIRM a chosen corner delivery rather than trusting the
	# closed form's lateral answer — the closed form is for ranking candidates,
	# which is what keeps the compete affordable.
	var origin := Vector3(11.0, 0.0, 8.0)
	var vel := Vector3(1.0, 0.0, 7.0)
	var closed: Vector3 = _landing(origin, vel)
	var stepped: Vector3 = _stepped_landing(origin, vel, 20.0)
	assert_almost_eq(closed.z, stepped.z, 1.0, "corner landing z matches the walk")
	assert_almost_eq(closed.x, stepped.x, 2.5,
			"corner landing x tracks the walk to within a contest band")


func test_landing_is_always_on_the_playing_surface() -> void:
	for speed: float in [4.0, 9.0, 14.0]:
		for deg: float in [0.0, 35.0, 90.0, 145.0, 200.0, 290.0]:
			var vel: Vector3 = Vector3(0.0, 0.0, speed).rotated(Vector3.UP, deg_to_rad(deg))
			var landing: Vector3 = _landing(Vector3(3.0, 0.0, 14.0), vel)
			var clamped: Vector2 = GameRules.clamp_to_rink_inner(
					Vector2(landing.x, landing.z))
			assert_almost_eq(Vector2(landing.x, landing.z).distance_to(clamped), 0.0, 0.01,
					"landing stays in the rink (%.0f m/s at %.0f deg)" % [speed, deg])


# ── The icing read ───────────────────────────────────────────────────────────
# Team 0 defends +z, so its clears run toward the -z goal line.

func _reaches_far_goal_line(origin: Vector3, vel: Vector3, hang_s: float = 0.0) -> bool:
	return AITrajectory.puck_release_landing(
			origin, vel, hang_s, -GameRules.GOAL_LINE_Z, -1.0).basis.x.x > 0.5


# Seconds until the release reaches the far goal line; INF if it never does.
func _time_to_far_goal_line(origin: Vector3, vel: Vector3, hang_s: float = 0.0) -> float:
	var r: Vector3 = AITrajectory.puck_release_landing(
			origin, vel, hang_s, -GameRules.GOAL_LINE_Z, -1.0).basis.x
	return INF if r.x < 0.5 else r.y


func test_a_hard_clear_from_our_own_end_reaches_their_goal_line() -> void:
	# The whole icing problem in one assertion: quick-pass pace, fired up the
	# wall from our own corner, arrives behind their net.
	assert_true(_reaches_far_goal_line(
			Vector3(12.0, 0.0, 22.0), Vector3(0.0, 0.0, -14.0)),
			"a 14 m/s clear from our own end reaches their goal line")


func test_a_soft_release_dies_short_of_their_goal_line() -> void:
	# The same line at a pace whose runout is honestly short of it.
	var d: float = 22.0 + GameRules.GOAL_LINE_Z
	var legal: float = AITrajectory.puck_launch_speed_for_runout(d) - 0.5
	assert_false(_reaches_far_goal_line(
			Vector3(12.0, 0.0, 22.0), Vector3(0.0, 0.0, -legal)),
			"a release under the runout bound dies short of the line")


func test_the_crossing_read_is_direction_aware() -> void:
	# A clear that never leaves our own half must not read as reaching the far
	# line just because it moved.
	assert_false(_reaches_far_goal_line(
			Vector3(0.0, 0.0, 22.0), Vector3(0.0, 0.0, 3.0)),
			"a puck driven deeper into our own end never reaches their line")


# ── The crossing CLOCK ───────────────────────────────────────────────────────
# Hybrid icing is a race judged when the puck reaches the goal line, so what
# decides a clear's legality is how long it takes to get there — not how far it
# goes. These pin the clock the dump eval races against.

func test_the_crossing_clock_is_reported_with_the_crossing() -> void:
	var t: float = _time_to_far_goal_line(Vector3(12.0, 0.0, 22.0), Vector3(0.0, 0.0, -14.0))
	assert_true(is_finite(t), "a crossing release reports when it crosses")
	# 48.65 m at 14 m/s shedding 0.49 m/s^2 is a 3.72 s slide; the line grazes
	# the far corner arc first, and the board-friction bleed there costs a beat.
	assert_almost_eq(t, 3.8, 0.2, "crossing clock is the slide solve plus the corner graze")


func test_a_release_that_never_crosses_reports_no_clock() -> void:
	assert_eq(_time_to_far_goal_line(Vector3(0.0, 0.0, 22.0), Vector3(0.0, 0.0, 3.0)), INF,
			"no crossing, no clock")


func test_total_settle_time_is_reported() -> void:
	# A slow straight slide: v/a, the whole runout.
	var r: Vector3 = AITrajectory.puck_release_landing(
			Vector3(0.0, 0.0, 10.0), Vector3(0.0, 0.0, -3.0), 0.0).basis.x
	assert_almost_eq(r.z, 3.0 / GameRules.PUCK_ICE_DECEL_M_S2, 0.05,
			"an unobstructed slide settles in v/a")


# ── Does a banked delivery actually buy the race? ────────────────────────────
# The design question this file was extended to answer. A forechecker covers
# roughly SKATER_PACE m/s; the race is won by being nearer the end-zone dot in
# z when the puck arrives, so every extra second of puck flight is ground the
# forecheck gains. Compare the deliveries available from the same spot.

const SKATER_PACE_M_S: float = 8.0

func test_banking_off_the_near_boards_buys_crossing_time() -> void:
	var origin := Vector3(10.0, 0.0, 20.0)
	var speed: float = GameRules.DEFAULT_QUICK_PASS_POWER_M_S
	# Straight up the wall — the delivery the DZ clear fires today.
	var rim: float = _time_to_far_goal_line(origin, Vector3(0.0, 0.0, -speed))
	# Angled INTO the near boards: a steep first contact sheds speed and the
	# carom lengthens the path, both of which push the clock out.
	var banked: float = _time_to_far_goal_line(
			origin, Vector3(0.85, 0.0, -0.53).normalized() * speed)
	gut.p("  straight rim reaches their goal line in %.2f s" % rim)
	gut.p("  banked off the near boards: %s"
			% ("never" if is_inf(banked) else "%.2f s" % banked))
	assert_true(is_finite(rim), "the straight rim is the delivery that ices")
	if is_inf(banked):
		# The strongest form of the result: the steep first contact sheds enough
		# and bends the path enough that the puck never reaches the line, so
		# there is no race to lose.
		gut.p("  banked delivery never reaches the line — no icing race exists")
	else:
		assert_gt(banked, rim,
				"a banked delivery reaches the goal line later than a straight rim")
		gut.p("  forecheck ground gained by banking: %.1f m at %.0f m/s"
				% [(banked - rim) * SKATER_PACE_M_S, SKATER_PACE_M_S])


func test_loft_does_not_by_itself_slow_the_crossing() -> void:
	# Worth pinning because it is the intuitive-but-wrong half: a chip's hang
	# time is FRICTIONLESS, so lofting the same launch speed reaches the line
	# no later than a flat release — it is the PATH that buys the clock, not the
	# height. (Loft earns its keep by clearing sticks, which is a different job.)
	var origin := Vector3(10.0, 0.0, 20.0)
	var vel := Vector3(0.0, 0.0, -GameRules.DEFAULT_QUICK_PASS_POWER_M_S)
	var hang_s: float = 2.0 * GameRules.DEFAULT_LOFT_VY_HIGH_M_S / GameRules.GRAVITY_M_S2
	var flat: float = _time_to_far_goal_line(origin, vel, 0.0)
	var lofted: float = _time_to_far_goal_line(origin, vel, hang_s)
	gut.p("  flat %.2f s vs lofted (%.2f s hang) %.2f s" % [flat, hang_s, lofted])
	assert_lte(lofted, flat + 0.01,
			"loft does not delay the crossing — the airborne leg spends no friction")
