extends GutTest

# PuckObstacleCollision — the analytic drill obstacle (the tutorial saucer board).
# ------------------------------------------------------------------------------
# The board's whole job is to be un-passable along the ice and clearable over the
# top, so the tests are framed as the two drill outcomes rather than as geometry:
# a flat shot rebounds, a saucer carries. The rest pin the properties the per-tick
# path depends on — nearest-contact-first, no re-reflect on a separating puck, and
# an empty list costing nothing.

const RADIUS: float = 0.076

# A knee-high board across a lane at the origin, facing ±Z: 2 m wide, 0.25 m tall,
# 0.1 m thick. Matches the drills' wall proportions.
const HALF: Vector3 = Vector3(1.0, 0.125, 0.05)

var _scratch: SweptDiscOBB.Result = null
var _result: PuckObstacleCollision.Result = null


func before_each() -> void:
	_scratch = SweptDiscOBB.Result.new()
	_result = PuckObstacleCollision.Result.new()


func _board(center: Vector3 = Vector3(0.0, 0.125, 0.0), yaw: float = 0.0) -> Array:
	var o := PuckObstacleCollision.Obstacle.new()
	o.transform = Transform3D(Basis(Vector3.UP, yaw), center)
	o.half_extents = HALF
	return [o]


func test_a_flat_shot_rebounds_off_the_board() -> void:
	# The drill's premise: along the ice, the board is a wall.
	var prev := Vector3(0.0, RADIUS, -1.0)
	var pos := Vector3(0.0, RADIUS, 0.2)
	var vel := Vector3(0.0, 0.0, 30.0)
	assert_true(
		PuckObstacleCollision.resolve(prev, pos, vel, RADIUS, _board(), _scratch, _result),
		"a flat shot should contact the board"
	)
	assert_lt(_result.velocity.z, 0.0, "the puck should be sent back the way it came")
	assert_lt(_result.position.z, 0.0, "the puck should be left on the near side of the board")


func test_a_saucer_clears_the_board() -> void:
	# The skill the drill teaches. Same lane, but lofted over the 0.25 m board.
	var prev := Vector3(0.0, 0.45, -1.0)
	var pos := Vector3(0.0, 0.44, 0.2)
	var vel := Vector3(0.0, -0.3, 30.0)
	assert_false(
		PuckObstacleCollision.resolve(prev, pos, vel, RADIUS, _board(), _scratch, _result),
		"a puck passing above the board should not contact it"
	)
	assert_eq(_result.position, pos, "a miss must leave the position untouched")
	assert_eq(_result.velocity, vel, "a miss must leave the velocity untouched")


func test_a_puck_passing_wide_of_the_board_is_untouched() -> void:
	# The board spans the lane, not the rink — a pass outside its width is legal.
	var prev := Vector3(3.0, RADIUS, -1.0)
	var pos := Vector3(3.0, RADIUS, 0.2)
	assert_false(PuckObstacleCollision.resolve(
			prev, pos, Vector3(0.0, 0.0, 30.0), RADIUS, _board(), _scratch, _result))


func test_the_rebound_loses_speed() -> void:
	# Restitution is below the goal pipe's: the board is padded, so a flat shot
	# drops in front of it rather than rocketing back at the shooter.
	var vel := Vector3(0.0, 0.0, 30.0)
	PuckObstacleCollision.resolve(Vector3(0.0, RADIUS, -1.0), Vector3(0.0, RADIUS, 0.2),
			vel, RADIUS, _board(), _scratch, _result)
	assert_lt(absf(_result.velocity.z), absf(vel.z), "the rebound should be slower than the shot")
	assert_almost_eq(absf(_result.velocity.z),
			absf(vel.z) * PuckObstacleCollision.BOARD_RESTITUTION, 0.001,
			"the normal component should scale by BOARD_RESTITUTION")


func test_an_angled_shot_keeps_its_tangential_travel() -> void:
	# Reflection, not absorption: a puck cutting across the board carries its
	# along-the-face motion through the bounce.
	var vel := Vector3(12.0, 0.0, 30.0)
	assert_true(PuckObstacleCollision.resolve(Vector3(-0.4, RADIUS, -1.0),
			Vector3(0.0, RADIUS, 0.2), vel, RADIUS, _board(), _scratch, _result))
	assert_almost_eq(_result.velocity.x, 12.0, 0.001, "tangential x should survive the bounce")
	assert_lt(_result.velocity.z, 0.0, "normal z should reverse")


func test_a_yawed_board_deflects_across_its_face() -> void:
	# The drills lay the board across whatever direction the lane runs, so the box
	# is oriented, not axis-aligned. A 45° board does NOT send the puck back the
	# way it came — it turns it sideways, which is the point of reflecting about
	# the box's own normal rather than just killing the incoming axis.
	var vel := Vector3(0.0, 0.0, 30.0)
	assert_true(PuckObstacleCollision.resolve(Vector3(0.0, RADIUS, -1.0),
			Vector3(0.0, RADIUS, 0.2), vel, RADIUS,
			_board(Vector3(0.0, 0.125, 0.0), PI * 0.25), _scratch, _result))
	assert_lt(_result.velocity.x, -1.0, "a 45° board should turn the puck across the lane")
	assert_lt(_result.velocity.z, vel.z, "and take most of the down-lane speed out of it")


func test_a_separating_puck_is_not_re_reflected() -> void:
	# The per-sub-step path re-tests a puck already ejected off the face. Without
	# the v·n guard it would re-reflect every sub-step and buzz along the board.
	var prev := Vector3(0.0, RADIUS, -0.2)
	var pos := Vector3(0.0, RADIUS, -0.5)
	assert_false(PuckObstacleCollision.resolve(
			prev, pos, Vector3(0.0, 0.0, -10.0), RADIUS, _board(), _scratch, _result),
			"a puck travelling away from the board must be left alone")


func test_the_nearest_obstacle_wins() -> void:
	# Two boards down one lane: the puck must bounce off the first one it reaches,
	# not whichever happens to sit earlier in the array.
	var far := PuckObstacleCollision.Obstacle.new()
	far.transform = Transform3D(Basis(), Vector3(0.0, 0.125, 0.0))
	far.half_extents = HALF
	var near := PuckObstacleCollision.Obstacle.new()
	near.transform = Transform3D(Basis(), Vector3(0.0, 0.125, -2.0))
	near.half_extents = HALF
	assert_true(PuckObstacleCollision.resolve(Vector3(0.0, RADIUS, -4.0),
			Vector3(0.0, RADIUS, 0.2), Vector3(0.0, 0.0, 30.0), RADIUS,
			[far, near], _scratch, _result))
	assert_lt(_result.position.z, -2.0,
			"the puck should stop at the NEAR board, not travel on to the far one")


func test_an_empty_obstacle_list_is_a_miss() -> void:
	# The match path. Every tick of every game takes this branch.
	var pos := Vector3(1.0, RADIUS, 2.0)
	var vel := Vector3(0.0, 0.0, 30.0)
	assert_false(PuckObstacleCollision.resolve(
			Vector3.ZERO, pos, vel, RADIUS, [], _scratch, _result))
	assert_eq(_result.position, pos)
	assert_eq(_result.velocity, vel)


func test_a_puck_resting_inside_the_box_is_ejected() -> void:
	# Degenerate but reachable: a wall staged on top of a stationary puck. It must
	# be pushed clear rather than left to sit inside the board forever.
	var inside := Vector3(0.0, 0.125, 0.0)
	assert_true(PuckObstacleCollision.resolve(inside, inside, Vector3.ZERO, RADIUS,
			_board(), _scratch, _result))
	assert_gt(_result.position.distance_to(inside), 0.0, "the puck should be moved out")


# ── Composition: the drill outcome over a real multi-tick flight ──────────────
# The tests above resolve ONE segment. What the drills actually depend on is the
# composition the puck drive runs — step_frame_substep then the obstacle resolve,
# per sub-step, for as many ticks as the flight lasts. These run the real board
# dimensions the drills stage (tutorial_manager._PASS_WALL_SIZE) so a change to
# either half that lets a flat shot through fails here.

const DT: float = 1.0 / 120.0
const ICE: float = 0.0175
const MAX_SPEED: float = 38.0
const MAX_HEIGHT: float = 3.0
const DRILL_WALL: Vector3 = Vector3(1.8, 0.12, 0.08)  # the drills' own board


# Runs `ticks` of the shared puck step with `obstacles` registered, exactly as
# Puck._drive_analytic composes them. Returns the final position.
func _fly(pos: Vector3, vel: Vector3, obstacles: Array, ticks: int) -> Vector3:
	var frame := PuckGeometryCollision.Result.new()
	var tick_result := PuckAuthorityRules.TickResult.new()
	for _t in ticks:
		var substeps: int = PuckAuthorityRules.frame_substeps(pos.z, vel.length(), DT)
		var sub_dt: float = DT / float(substeps)
		for _s in substeps:
			var sub_prev: Vector3 = pos
			PuckAuthorityRules.step_frame_substep(pos, vel, sub_dt, RADIUS,
					MAX_SPEED, ICE, MAX_HEIGHT, frame, tick_result)
			pos = tick_result.position
			vel = tick_result.velocity
			if PuckObstacleCollision.resolve(sub_prev, pos, vel, RADIUS,
					obstacles, _scratch, _result):
				pos = _result.position
				vel = _result.velocity
	return pos


func _drill_board(z: float) -> Array:
	var o := PuckObstacleCollision.Obstacle.new()
	o.transform = Transform3D(Basis(), Vector3(0.0, DRILL_WALL.y * 0.5, z))
	o.half_extents = DRILL_WALL * 0.5
	return [o]


func test_a_hard_flat_shot_does_not_get_through_the_drill_board() -> void:
	# The bug this file exists for: at 30 m/s the puck covers 0.25 m per tick
	# against an 8 cm board, so only a SWEPT test stops it. Anything that lets it
	# through makes both saucer drills completable without a saucer.
	var end: Vector3 = _fly(Vector3(0.0, ICE, -4.0), Vector3(0.0, 0.0, 30.0),
			_drill_board(0.0), 40)
	assert_lt(end.z, 0.0, "a flat shot must not end up past the board")


func test_a_slow_flat_pass_does_not_get_through_the_drill_board() -> void:
	# The other end of the range — a soft pass must die on the board too, not
	# creep through it between sub-steps.
	var end: Vector3 = _fly(Vector3(0.0, ICE, -4.0), Vector3(0.0, 0.0, 8.0),
			_drill_board(0.0), 120)
	assert_lt(end.z, 0.0, "a slow pass must not end up past the board")


func test_a_saucer_clears_the_drill_board_and_lands_beyond_it() -> void:
	# The skill the drill teaches must still work: lofted over the 12 cm board,
	# landing on the far side. Launched at the tutorial's low-saucer shape.
	var end: Vector3 = _fly(Vector3(0.0, ICE, -4.0), Vector3(0.0, 2.6, 14.0),
			_drill_board(0.0), 60)
	assert_gt(end.z, 0.0, "a saucer must carry past the board")


func test_the_board_is_inert_when_it_is_not_registered() -> void:
	# The match path: with no obstacle registered the flight is untouched, so the
	# obstacle code cannot change a game.
	var without: Vector3 = _fly(Vector3(0.0, ICE, -4.0), Vector3(0.0, 0.0, 30.0), [], 40)
	assert_gt(without.z, 0.0, "with no board registered the shot carries through")
