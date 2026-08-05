extends GutTest

# NetBladeCollision + NetGeometry — the stick's net, and the shared definition of
# where the net is.
#
# The geometry-parity block is the most important thing in this file. There used
# to be TWO nets (docs/net-play-plan.md §1): the loose puck collided with the real
# cage while the blade and the carried puck were clamped out of a flat box 10 cm
# wider and, at height, up to 33 cm deeper. These tests exist to stop that
# divergence reappearing.

const GL: float = GameRules.GOAL_LINE_Z
const HW: float = GameRules.NET_HALF_WIDTH
const ICE: float = 0.03
const GIVE: float = 0.12
const THICK: float = 0.012
const EPS: float = 0.001

var _r := NetBladeCollision.Result.new()


func _resolve(prev: Vector3, heel: Vector3, toe: Vector3) -> NetBladeCollision.Result:
	NetBladeCollision.resolve(prev, heel, toe, THICK, GIVE, _r)
	return _r


# A blade lying along +x (across the mouth) with its heel at `heel`.
func _flat_toe(heel: Vector3, length: float = 0.30) -> Vector3:
	return heel + Vector3(length, 0.0, 0.0)


# ── Geometry parity: one net, not two ─────────────────────────────────────────

func test_side_twine_sits_at_the_post_line_not_the_trapezoid_flare() -> void:
	# The old blade box used NET_HALF_WIDTH + NET_PUCK_BUFFER = 1.015, within half
	# a centimetre of the 1.02 flare the puck model was explicitly fixed to stop
	# using. The cage does not flare.
	assert_almost_eq(NetGeometry.cavity_half_width(), HW, EPS,
			"side twine is the post line")
	assert_lt(NetGeometry.cavity_half_width(), GameRules.NET_BACK_HALF_WIDTH,
			"and is strictly inside the trapezoid back width")


func test_back_twine_tapers_with_height() -> void:
	# The old blade box was flat at NET_DEPTH + buffer at every height.
	var at_ice: float = NetGeometry.back_depth_at_height(0.0)
	var at_bar: float = NetGeometry.back_depth_at_height(GameRules.NET_HEIGHT)
	assert_almost_eq(at_ice, GameRules.NET_DEPTH, EPS, "full depth at the ice")
	assert_almost_eq(at_bar, GameRules.NET_TOP_DEPTH, EPS, "shallow at the top shelf")
	assert_lt(at_bar, at_ice, "the twine leans back as it drops")
	# The height where the old flat box was worst wrong.
	assert_lt(NetGeometry.back_depth_at_height(0.6), 0.85,
			"at 0.6 m the real twine is far shallower than a flat 1.12 wall")


func test_blade_and_puck_stop_on_the_same_surfaces() -> void:
	# With both clearances at zero the two colliders must agree about where the
	# twine IS. This is the test that catches a second net being reintroduced.
	for y: float in [0.0, 0.2, 0.6, 1.0, 1.2]:
		var depth: float = NetGeometry.back_depth_at_height(y)
		var inside := Vector3(0.0, y, GL + depth + 0.05)
		# Puck view: interior clamp limit at this height.
		var puck_limit: float = GL + NetGeometry.back_depth_at_height(inside.y)
		# Blade view: same surface, offset only by the mesh give it is allowed.
		NetBladeCollision.resolve(
				Vector3(0.0, y, GL + 0.2), inside, inside, 0.0, 0.0, _r)
		var blade_stop: float = inside.z + _r.offset.z
		assert_almost_eq(blade_stop, puck_limit, EPS,
				"blade and puck share the back twine at y=%.2f" % y)


func test_interior_classification_is_shared() -> void:
	# Both colliders route their two-sided face choice through this one call.
	assert_true(NetGeometry.interior_or_mouth(Vector3(0.0, ICE, GL + 0.3)),
			"inside the cavity")
	assert_true(NetGeometry.interior_or_mouth(Vector3(0.0, ICE, GL - 0.1)),
			"in front of the mouth, within the posts")
	assert_false(NetGeometry.interior_or_mouth(Vector3(1.4, ICE, GL - 0.1)),
			"in front of the goal line but wide of the posts")
	assert_false(NetGeometry.interior_or_mouth(Vector3(0.0, ICE, GL + 2.0)),
			"behind the cage")
	assert_false(NetGeometry.interior_or_mouth(Vector3(0.0, 1.4, GL + 0.3)),
			"above the crossbar")


# ── The segment test — the case a point sample cannot see ─────────────────────

func test_blade_sweeping_across_the_post_is_caught() -> void:
	# THE wraparound case. Heel inside the mouth, toe outside the post: both
	# ENDPOINTS are clear of the 3 cm pipe, and the blade straddles it. A point
	# sample (which is what the net used to get) misses this entirely.
	var heel := Vector3(HW - 0.12, ICE, GL)
	var toe := Vector3(HW + 0.12, ICE, GL)
	var res: NetBladeCollision.Result = _resolve(heel, heel, toe)
	assert_true(res.hit(), "the straddling blade hits the post")
	assert_ne(res.pipe_normal, Vector3.ZERO, "and it is iron, not twine")


func test_blade_clear_of_the_post_is_untouched() -> void:
	var heel := Vector3(0.0, ICE, GL - 0.4)
	assert_false(_resolve(heel, heel, _flat_toe(heel)).hit(),
			"a blade out in the slot collides with nothing")


func test_blade_in_the_open_mouth_is_untouched() -> void:
	# The mouth is open. This is the whole reason legality needs no separate rule.
	var heel := Vector3(0.0, ICE, GL + 0.05)
	var prev := Vector3(0.0, ICE, GL - 0.1)
	assert_false(_resolve(prev, heel, heel + Vector3(0.2, 0.0, 0.0)).hit(),
			"a blade riding in through the mouth is free")


func test_blade_above_the_crossbar_is_untouched() -> void:
	var heel := Vector3(0.0, GameRules.NET_HEIGHT + 0.3, GL + 0.3)
	assert_false(_resolve(heel, heel, _flat_toe(heel)).hit(),
			"a raised stick over the net is not the blade collider's business")


# ── Twine is compliant and does not strip ─────────────────────────────────────

func test_blade_sinks_into_side_twine_from_outside_and_stops() -> void:
	# Reaching in from beside the cage: the stick buries itself in the mesh and
	# goes no further. It is not teleported to a face and it is NOT iron.
	var prev := Vector3(HW + 0.4, ICE, GL + 0.5)
	var heel := Vector3(HW - 0.5, ICE, GL + 0.5)
	var res: NetBladeCollision.Result = _resolve(prev, heel, heel)
	assert_true(res.hit(), "the side mesh stops the reach")
	assert_eq(res.pipe_normal, Vector3.ZERO, "twine is not iron — no strip signal")
	var stopped_x: float = heel.x + res.offset.x
	assert_almost_eq(stopped_x, HW - GIVE, EPS,
			"stopped exactly one mesh-give inside the twine")


func test_blade_sinks_into_back_twine_from_outside_and_stops() -> void:
	var prev := Vector3(0.0, ICE, GL + 1.6)
	var heel := Vector3(0.0, ICE, GL + 0.6)
	var res: NetBladeCollision.Result = _resolve(prev, heel, heel)
	assert_true(res.hit(), "the back mesh stops a reach from behind")
	assert_eq(res.pipe_normal, Vector3.ZERO, "still twine")
	var moved: Vector3 = heel + res.offset
	assert_gt(NetGeometry.back_plane_distance(moved), -GIVE - EPS,
			"never pulled through the back twine into the cavity")


func test_blade_inside_the_cavity_is_held_inside() -> void:
	# A legal occupant driving outward is stopped by the same twine, from the
	# other side. No mouth column, no lateral coin flip — just the mesh.
	var prev := Vector3(0.0, ICE, GL + 0.3)
	var heel := Vector3(HW + 0.5, ICE, GL + 0.3)
	var res: NetBladeCollision.Result = _resolve(prev, heel, heel)
	assert_true(res.hit(), "pressing the side mesh from inside")
	var stopped_x: float = heel.x + res.offset.x
	assert_almost_eq(stopped_x, HW + GIVE, EPS, "held at the twine plus its give")


# ── Iron reports itself, so the caller can strip ──────────────────────────────

func test_post_contact_reports_an_outward_normal() -> void:
	var heel := Vector3(HW - 0.01, ICE, GL)
	var res: NetBladeCollision.Result = _resolve(heel, heel, heel)
	assert_true(res.hit(), "on the pipe")
	assert_ne(res.pipe_normal, Vector3.ZERO, "iron reports itself")
	assert_almost_eq(res.pipe_normal.length(), 1.0, EPS, "normal is unit")
	assert_almost_eq(res.pipe_normal.y, 0.0, EPS, "a vertical pipe pushes horizontally")
	# The blade ends up clear of the pipe.
	var moved: Vector3 = heel + res.offset
	var gap: float = Vector2(moved.x - HW, moved.z - GL).length()
	assert_almost_eq(gap, GameRules.NET_POST_RADIUS + THICK, EPS,
			"ejected flush against the iron")


func test_both_ends_are_handled_for_either_end_of_the_rink() -> void:
	for sign_z: float in [1.0, -1.0]:
		var gl: float = GL * sign_z
		var heel := Vector3(HW - 0.01, ICE, gl)
		var res: NetBladeCollision.Result = _resolve(heel, heel, heel)
		assert_ne(res.pipe_normal, Vector3.ZERO,
				"post contact detected at the %s end" % ("+Z" if sign_z > 0.0 else "-Z"))


func test_result_is_reset_between_resolves() -> void:
	# The Result is shared scratch on the hot path; a stale pipe_normal would
	# fabricate a strip.
	var post_heel := Vector3(HW - 0.01, ICE, GL)
	_resolve(post_heel, post_heel, post_heel)
	assert_ne(_r.pipe_normal, Vector3.ZERO, "primed with a pipe hit")
	var clear := Vector3(0.0, ICE, GL - 3.0)
	var res: NetBladeCollision.Result = _resolve(clear, clear, _flat_toe(clear))
	assert_false(res.hit(), "clear of everything")
	assert_eq(res.pipe_normal, Vector3.ZERO, "and the stale strip signal is gone")
