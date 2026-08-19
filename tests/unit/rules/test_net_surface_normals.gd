extends GutTest

# NetGeometry.nearest_surface_normal — the outward direction of whichever twine
# surface a point lies nearest.
#
# It exists so the net shader can push a bulge along ONE direction per impact
# instead of along each panel's own face normal. The panels meet at right
# angles, so face normals move the two sides of a seam apart: at the 0.20 m
# bulge cap that is a ~0.28 m hole torn in the twine, worst in the back corner,
# which is exactly where a puck ends up on a goal.
#
# The classifier is itself discontinuous at a seam — "back" on one side of it,
# "side" on the other — and that is harmless, because HockeyGoal evaluates it
# ONCE, at the impact origin, and hands the single answer to every vertex. The
# no-tear property is asserted where it actually lives, in
# test_goal_net_impacts.gd.
#
# Scope: points ON the twine, because that is the only place it is ever asked
# about — net_impact is reached from a net CONTACT, so the puck is within its own
# radius of a surface. Deep in the middle of the cavity every surface is far and
# which one wins is arbitrary; asserting anything there would be pinning
# behaviour the game never reaches.
#
# Both ends of the rink, always: the normals mirror, and a test that only looked
# at +z would pass with the sign hard-coded.

const _EPS := Vector3(1e-5, 1e-5, 1e-5)
# Puck-radius-ish standoff: how far off the twine a real contact sits.
const _STANDOFF: float = 0.03


func test_against_the_back_mesh_reports_the_back_normal() -> void:
	for s: float in [1.0, -1.0]:
		for x: float in [-0.6, 0.0, 0.6]:
			for y: float in [0.15, 0.6, 1.0]:
				# On the slanted back twine at this height, stood off into the cavity.
				var depth: float = NetGeometry.back_depth_at_height(y) - _STANDOFF
				var p := Vector3(x, y, s * (GameRules.GOAL_LINE_Z + depth))
				var n: Vector3 = NetGeometry.nearest_surface_normal(p)
				assert_gt(n.z * s, 0.0,
						"at %s the nearest twine is the back mesh, whose outward normal " % p +
						"points away from centre ice")
				assert_gt(n.y, 0.0,
						"and it leans UP, because the back twine leans back as it drops")


func test_against_the_side_twine_reports_the_side_normal() -> void:
	for s: float in [1.0, -1.0]:
		for x_side: float in [1.0, -1.0]:
			for y: float in [0.15, 0.6, 1.0]:
				var p := Vector3(x_side * (GameRules.NET_HALF_WIDTH - _STANDOFF), y,
						s * (GameRules.GOAL_LINE_Z + 0.25))
				assert_almost_eq(NetGeometry.nearest_surface_normal(p),
						Vector3(x_side, 0.0, 0.0), _EPS,
						"hard against the side twine at %s the push is straight out" % p)


func test_under_the_roof_reports_up() -> void:
	for s: float in [1.0, -1.0]:
		for x: float in [-0.6, 0.0, 0.6]:
			var p := Vector3(x, GameRules.NET_HEIGHT - _STANDOFF,
					s * (GameRules.GOAL_LINE_Z + 0.25))
			assert_almost_eq(NetGeometry.nearest_surface_normal(p), Vector3(0.0, 1.0, 0.0),
					_EPS, "a puck kicked up under the roof at %s lifts it" % p)


# Whatever surface is named, its normal must point THROUGH the twine from where
# the puck is — a body inside the cage is pushed outward, never dragged deeper.
# This is the property a flipped sign in any one branch would break.
func test_the_named_surface_is_always_pushed_outward() -> void:
	for s: float in [1.0, -1.0]:
		for p: Vector3 in _on_twine_samples(s):
			var n: Vector3 = NetGeometry.nearest_surface_normal(p)
			assert_almost_eq(n.length(), 1.0, 1e-5, "normals are unit (at %s)" % p)
			# Stepping along the normal must carry the point out through the back
			# plane, past a side plane, or above the roof — whichever it named.
			var stepped: Vector3 = p + n * (_STANDOFF * 2.0)
			var escaped: bool = (
					NetGeometry.back_plane_distance(stepped) > NetGeometry.back_plane_distance(p)
					or absf(stepped.x) > absf(p.x)
					or stepped.y > p.y)
			assert_true(escaped,
					"the normal at %s (%s) must push out through the twine, not deeper in"
					% [p, n])


# Points sitting on each of the three surfaces, at the end whose goal line is
# `end_sign` * GOAL_LINE_Z — the only places net_impact is ever asked about.
func _on_twine_samples(end_sign: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for y: float in [0.15, 0.5, 0.9, 1.15]:
		for x: float in [-0.7, -0.2, 0.3, 0.8]:
			var depth: float = NetGeometry.back_depth_at_height(y) - _STANDOFF
			out.append(Vector3(x, y, end_sign * (GameRules.GOAL_LINE_Z + depth)))
		for x_side: float in [1.0, -1.0]:
			out.append(Vector3(x_side * (GameRules.NET_HALF_WIDTH - _STANDOFF), y,
					end_sign * (GameRules.GOAL_LINE_Z + 0.3)))
	for x: float in [-0.7, 0.0, 0.7]:
		out.append(Vector3(x, GameRules.NET_HEIGHT - _STANDOFF,
				end_sign * (GameRules.GOAL_LINE_Z + 0.3)))
	return out
