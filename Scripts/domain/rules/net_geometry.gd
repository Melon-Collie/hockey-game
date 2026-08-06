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

# The back mesh is a finite rectangle spanning the cavity's width, not the
# infinite plane its distance function describes. Anything reading that plane has
# to establish the body is within the panel first — a plane equation on its own
# answers "which side of it am I on" for the whole rink, and both ends of the ice
# are behind it. Skipping this let the back face claim contacts that were never
# its own: it pinned a stick out by the corner boards to a surface metres away,
# and it answered for a puck rounding the cage's back corner, whose contact
# belonged to the SIDE mesh — so the side mesh never got asked and the puck kept
# creeping in.
#
# `slack` is the caller's own reach — a puck radius, a blade half-thickness plus
# the mesh give — so a body grazing the panel's edge still counts as on it.
static func within_back_panel(x: float, slack: float) -> bool:
	return absf(x) <= cavity_half_width() + slack

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

# Height the straight post reaches before the mouth-corner bend takes over. Above
# this the frame is the bend, not the pipe — modelling the post as a full-height
# cylinder to the crossbar both over-blocked (a straight pipe standing where the
# real frame has already curved inward) and left a seam near the crown, which is
# what let top-corner shots through the visible frame (issue #598).
static func post_top_y() -> float:
	return GameRules.NET_HEIGHT - GameRules.NET_MOUTH_CORNER_RADIUS

# Nearest point on the centre-line of the mouth-corner bend at this end, on the
# side `p` is on. The bend is a quarter circle in the plane z = `end_z`, centred
# above the crossbar end at (±NET_CROWN_HALF_WIDTH, post_top_y) and sweeping from
# the post top (offset +x) round to the crossbar end (offset +y), matching how
# HockeyGoal builds it.
#
# Consumers do their own sphere-vs-point test against the result with their own
# clearance, so the pipe's tube radius lives with the response, not here.
static func closest_point_on_bend(p: Vector3, end_z: float) -> Vector3:
	var side: float = 1.0 if p.x >= 0.0 else -1.0
	var cx: float = side * GameRules.NET_CROWN_HALF_WIDTH
	var cy: float = post_top_y()
	var r: float = GameRules.NET_MOUTH_CORNER_RADIUS
	# Local quarter-plane coords: u toward the post, v toward the crossbar. Both
	# clamped non-negative BEFORE normalising, which projects onto the quarter arc
	# and handles the two endpoints without a separate case.
	var u: float = maxf((p.x - cx) * side, 0.0)
	var v: float = maxf(p.y - cy, 0.0)
	if u <= 0.0 and v <= 0.0:
		# Inside the corner, equidistant-ish: bias to the post end, the surface a
		# body arriving from below meets first.
		u = 1.0
	var inv: float = r / sqrt(u * u + v * v)
	return Vector3(cx + side * u * inv, cy + v * inv, end_z)

# Distance from `origin_xz` along unit `dir_xz` to the first SOLID face of the
# near net at height `y`, or INF when the ray never meets one. Feeds the blade's
# reach limit, so a stick simply cannot be aimed through the mesh — the same
# treatment the boards get, applied to the other obstacle on the ice.
#
# The mouth is not a face. A ray entering through the opening (crossing the
# goal-line plane between the post inner faces, travelling inward) returns INF:
# reaching into the net from the front is the whole point of net-front play, and
# the limit must not be what stops a wraparound. Every other approach — from a
# side, from behind, across the back mesh — meets twine and stops there.
#
# Slab method against the cavity, using the back depth at `y` (blades work near
# the ice, where that is nearly the full NET_DEPTH). An origin already inside the
# cavity returns INF: the reach limit is for keeping the stick out, and a body
# already in there is the collision's problem, not the limit's.
static func ray_to_solid_face(origin_xz: Vector2, dir_xz: Vector2, y: float) -> float:
	if dir_xz.length_squared() < 0.000001:
		return INF
	# Canonical frame: `u` runs from the goal line into the cage at the near end,
	# so both ends share one set of comparisons.
	var s: float = signf(near_end_z(origin_xz.y))
	var u: float = origin_xz.y * s
	var du: float = dir_xz.y * s
	var hw: float = cavity_half_width()
	var u_lo: float = GameRules.GOAL_LINE_Z
	var u_hi: float = GameRules.GOAL_LINE_Z + back_depth_at_height(y)

	var tx_lo: float = -INF
	var tx_hi: float = INF
	if absf(dir_xz.x) < 0.000001:
		if absf(origin_xz.x) > hw:
			return INF  # parallel to the side planes and outside them
	else:
		var a: float = (-hw - origin_xz.x) / dir_xz.x
		var b: float = (hw - origin_xz.x) / dir_xz.x
		tx_lo = minf(a, b)
		tx_hi = maxf(a, b)

	var tu_lo: float = -INF
	var tu_hi: float = INF
	if absf(du) < 0.000001:
		if u < u_lo or u > u_hi:
			return INF
	else:
		var a2: float = (u_lo - u) / du
		var b2: float = (u_hi - u) / du
		tu_lo = minf(a2, b2)
		tu_hi = maxf(a2, b2)

	var t_enter: float = maxf(tx_lo, tu_lo)
	var t_exit: float = minf(tx_hi, tu_hi)
	if t_enter > t_exit or t_exit < 0.0 or t_enter < 0.0:
		return INF
	# Entry through the OPEN mouth: the limiting slab is the depth one, entered at
	# its near plane while travelling inward, within the clear span between the
	# posts. Nothing solid there, so the panels do not bound the reach — but the
	# PIPES still can, and at the mouth they are exactly what a wraparound is
	# threading, so they are tested either way below.
	if tu_lo >= tx_lo and du > 0.0:
		var entry_x: float = origin_xz.x + dir_xz.x * t_enter
		if absf(entry_x) < hw - GameRules.NET_POST_RADIUS:
			return INF
	return t_enter


# Distance along the ray to the nearer post pipe, or INF. Separate from the panel
# slab above because a ray can miss the cavity entirely and still meet iron — a
# stick crossing the goal-line plane AT a post passes outside the side plane, so
# the slab declines it while the pipe is squarely in the way.
static func ray_to_post(origin_xz: Vector2, dir_xz: Vector2, clearance: float) -> float:
	var end_z: float = near_end_z(origin_xz.y)
	var r: float = GameRules.NET_POST_RADIUS + clearance
	var best: float = INF
	for side: float in [-1.0, 1.0]:
		var m: Vector2 = origin_xz - Vector2(side * GameRules.NET_HALF_WIDTH, end_z)
		var b: float = m.dot(dir_xz)
		var c: float = m.length_squared() - r * r
		if c < 0.0:
			return 0.0  # already touching this pipe
		var disc: float = b * b - c
		if disc < 0.0:
			continue
		var t: float = -b - sqrt(disc)
		if t >= 0.0:
			best = minf(best, t)
	return best


# The nearer of the two: whichever part of the net the aim line meets first.
static func ray_to_net(origin_xz: Vector2, dir_xz: Vector2, y: float, clearance: float) -> float:
	return minf(
			ray_to_solid_face(origin_xz, dir_xz, y),
			ray_to_post(origin_xz, dir_xz, clearance))

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
