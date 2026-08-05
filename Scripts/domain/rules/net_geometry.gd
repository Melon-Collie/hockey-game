class_name NetGeometry

# Where the net IS — one definition, read by everything that collides with it.
#
# This file exists because there used to be two. `PuckGeometryCollision` modelled
# the real cage (pipes at their true radius, side twine at the post line, a back
# mesh leaning ~21°), while the blade and the carried puck were clamped out of a
# flat axis-aligned box 10 cm wider and — at height — up to 33 cm deeper. A
# player crossing between a loose puck and a carried one crossed between two
# different nets, which is what made the area feel broken rather than merely
# hard. See `docs/net-play-plan.md` §1.
#
# Nothing here knows about restitution, pucks, or sticks. Consumers bring their
# own clearance (a puck's radius, a blade's half-thickness) and their own
# response. The surfaces are shared; the reactions are not.

# The back twine leans: full NET_DEPTH at the ice, tapering to NET_TOP_DEPTH
# under the crossbar, because a real NHL goal is shallow at the top shelf.
# Negative — the twine gets shallower as it rises.
const BACK_SLOPE: float = (GameRules.NET_TOP_DEPTH - GameRules.NET_DEPTH) / GameRules.NET_HEIGHT

# Goal-line Z of whichever end `z` is nearer to, signed.
static func near_end_z(z: float) -> float:
	return GameRules.GOAL_LINE_Z if z >= 0.0 else -GameRules.GOAL_LINE_Z

# Half-width of the cavity's SIDE twine. The visible side panels are straight
# vertical planes at the post line, so this is constant with depth — the cage
# does NOT flare out to NET_BACK_HALF_WIDTH. An earlier model that did let a
# corner-driven puck settle ~10 cm outside the visible mesh.
static func cavity_half_width() -> float:
	return GameRules.NET_HALF_WIDTH

# Goal-line-relative depth of the slanted back mesh at height `y`.
static func back_depth_at_height(y: float) -> float:
	var t: float = clampf(y / GameRules.NET_HEIGHT, 0.0, 1.0)
	return lerpf(GameRules.NET_DEPTH, GameRules.NET_TOP_DEPTH, t)

# Length of the (depth, y) plane normal (1, -BACK_SLOPE) — the divisor that
# turns the plane equation into a true distance.
static func back_plane_norm() -> float:
	return sqrt(1.0 + BACK_SLOPE * BACK_SLOPE)

# Signed PERPENDICULAR distance from `p` to this end's back-mesh plane, positive
# on the EXTERIOR (behind the twine) side. Sign alone classifies which face a
# body is on, which is robust where a depth-shell comparison sat on a knife edge
# against the ejection point it had to agree with.
static func back_plane_distance(p: Vector3) -> float:
	var depth: float = absf(p.z) - GameRules.GOAL_LINE_Z
	return (depth - GameRules.NET_DEPTH - BACK_SLOPE * p.y) / back_plane_norm()

# Unit outward normal of the back mesh at the end whose depth grows along
# `end_sign` * +z. Leans back AND UP, since the twine leans back as it drops.
static func back_plane_normal(end_sign: float) -> Vector3:
	var inv: float = 1.0 / back_plane_norm()
	return Vector3(0.0, -BACK_SLOPE * inv, end_sign * inv)

# True when `p` is on the INTERIOR side of the netting — inside the cavity, or in
# front of the goal line within the open mouth (about to enter the way a scored
# puck does). Callers classify the START of a swept segment with this to choose
# which face of the two-sided twine applies.
#
# The back test uses the slant's own plane, not a depth box: the wedge above the
# slant is real ice BEHIND the twine and must classify exterior however shallow
# it is.
static func interior_or_mouth(p: Vector3) -> bool:
	if p.y > GameRules.NET_HEIGHT:
		return false
	var az: float = absf(p.z)
	if az <= GameRules.GOAL_LINE_Z:
		# In front of the goal-line plane: the only interior entry is the open mouth.
		return absf(p.x) <= GameRules.NET_HALF_WIDTH
	if back_plane_distance(p) >= 0.0:
		return false
	return absf(p.x) < cavity_half_width()

# Closest approach between the XZ segment `a`→`b` and the vertical post pipe at
# (`post_x`, `end_z`), as (overlap, normal.x, normal.z) packed into a Vector3 —
# overlap > 0 means contact, and the normal points from the pipe axis out toward
# the segment. `clearance` is the colliding body's own reach (a puck radius, a
# blade's half-thickness) added to the pipe radius.
#
# Genuinely a SEGMENT test, not two endpoint tests: a post is 3 cm across and a
# blade is ~30 cm long, so the case that decides wraparound goals — a stick
# sweeping across the post with both ends clear of it — is exactly the one
# endpoint sampling misses.
static func post_overlap_xz(
		a: Vector2, b: Vector2, post_x: float, end_z: float, clearance: float) -> Vector3:
	var center := Vector2(post_x, end_z)
	var span: Vector2 = b - a
	var len_sq: float = span.length_squared()
	var closest: Vector2 = a
	if len_sq > 0.000001:
		closest = a + span * clampf((center - a).dot(span) / len_sq, 0.0, 1.0)
	var offset: Vector2 = closest - center
	var d: float = offset.length()
	var reach: float = GameRules.NET_POST_RADIUS + clearance
	if d >= reach:
		return Vector3.ZERO
	# Degenerate (segment through the pipe axis): push along +x, an arbitrary but
	# stable choice — the caller only needs A separating direction.
	var n := Vector2(1.0, 0.0) if d < 0.000001 else offset / d
	return Vector3(reach - d, n.x, n.y)
