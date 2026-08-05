class_name PuckGeometryCollision

# Analytic puck-vs-goal-frame collision (docs/netcode-determinism-migration.md): deterministic,
# client-reproducible reflections off the goal FRAME (posts, crossbar, top net panel). The
# goalie response stays in GoalieSaveRules; the back/side net panels are resolved separately.
#
# WHERE the surfaces are lives in `NetGeometry`, shared with the blade collider so the stick
# and the puck cannot drift onto different nets again (docs/net-play-plan.md §1). This file
# owns only the puck's RESPONSE to them. Posts are vertical cylinders at
# x = ±GameRules.NET_HALF_WIDTH, z = ±GameRules.GOAL_LINE_Z, radius GameRules.NET_POST_RADIUS,
# spanning y ∈ [0, NET_HEIGHT]; the crossbar is a horizontal pipe joining the post tops at
# y = NET_HEIGHT; the top net panel is the mesh roof behind it. The crossbar and top panel
# sit above the LAUNCHED loft ceiling (a clean loft shot tops ~1.14 m, under the 1.19 m
# crossbar underside) — but deflections and goalie rebounds can carry the puck higher
# (Puck.max_height is 3.0), so these are reachable in live play, not dead code. A post hit is 2D in XZ (circle vs circle); the
# crossbar is 2D in Y-Z; the top panel is a horizontal-plane bounce.
#
# Pure / static — headless-testable, allocation-free on the per-tick path (fills a caller-
# owned Result rather than returning a fresh object).

# Restitution the analytic reflections apply. These are the authoritative values — the puck
# never reaches the engine solver, so the goal bodies' PhysicsMaterial overrides are not read.
const POST_RESTITUTION: float = 0.55  # goal pipe (posts + crossbar) — a live ping off the iron
const NET_RESTITUTION: float = 0.05   # net panels — twine absorbs, the puck drops


class Result:
	var hit: bool = false
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO


# General 3D reflection: rebound the INTO-surface velocity component with `restitution`,
# keep the tangential. `normal` points away from the surface (toward the puck); only an
# approaching puck (v·n < 0) is reflected — a separating one is returned unchanged, so
# re-testing a puck already ejected off a surface never re-reflects it. Used for the
# crossbar (a YZ-plane bounce) and top net panel (a Y bounce), where the horizontal-only
# deflect_velocity can't carry the vertical rebound.
static func reflect_3d(vel: Vector3, normal: Vector3, restitution: float) -> Vector3:
	var n: Vector3 = normal.normalized()
	var vn: float = vel.dot(n)
	if vn >= 0.0:
		return vel
	return vel - (1.0 + restitution) * vn * n


# Resolve a puck against the two goal posts at whichever end it's near. On contact, eject the
# disc flush against the post and reflect the into-post velocity with POST_RESTITUTION
# (tangential kept — pipes are near-frictionless). Returns true and fills `result` on a hit;
# returns false and leaves the puck untouched otherwise. Testing only the near end keeps this
# to two circle checks on the per-tick path.
static func resolve_posts(pos: Vector3, vel: Vector3, puck_radius: float, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	var end_z: float = GameRules.GOAL_LINE_Z if pos.z >= 0.0 else -GameRules.GOAL_LINE_Z
	# Cheap early-out: the puck is nowhere near this end's goal line.
	if absf(pos.z - end_z) > 1.0 + puck_radius + GameRules.NET_POST_RADIUS:
		return false
	# The straight pipe ends where the mouth-corner bend begins; above that the
	# frame curves inward and resolve_crossbar_bends owns it. Modelling the post
	# all the way to the crossbar stood a straight pipe where the real frame has
	# already swept in — over-blocking below the crown and, because the circle at
	# NET_HALF_WIDTH cannot reach the crossbar's end at NET_CROWN_HALF_WIDTH, still
	# leaving a seam a top-corner shot flew through (issue #598).
	if pos.y > NetGeometry.post_top_y() + puck_radius:
		return false
	# Nearer post first (per-tick path: two explicit checks, no per-call array).
	var first_x: float = GameRules.NET_HALF_WIDTH if pos.x >= 0.0 else -GameRules.NET_HALF_WIDTH
	if _resolve_one_post(pos, vel, puck_radius, first_x, end_z, result):
		return true
	return _resolve_one_post(pos, vel, puck_radius, -first_x, end_z, result)


static func _resolve_one_post(pos: Vector3, vel: Vector3, puck_radius: float,
		post_x: float, end_z: float, result: Result) -> bool:
	var combined_r: float = puck_radius + GameRules.NET_POST_RADIUS
	var post_xz := Vector2(post_x, end_z)
	var offset := Vector2(pos.x, pos.z) - post_xz
	var d: float = offset.length()
	if d >= combined_r or d < 1e-6:
		return false
	# Contact: surface normal points from the post out toward the puck.
	var n := offset / d
	var n3 := Vector3(n.x, 0.0, n.y)
	# Eject flush against the post, then reflect the horizontal velocity with restitution
	# (deflect_velocity is horizontal-only, so carry the vertical channel through unchanged).
	var ejected: Vector2 = post_xz + n * combined_r
	var reflected_h: Vector3 = PuckCollisionRules.deflect_velocity(vel, n3, POST_RESTITUTION)
	result.position = Vector3(ejected.x, pos.y, ejected.y)
	result.velocity = Vector3(reflected_h.x, vel.y, reflected_h.z)
	result.hit = true
	return true


# Resolve a puck against the CROSSBAR — a horizontal pipe (axis along X) at y = NET_HEIGHT,
# z = ±GOAL_LINE_Z, spanning |x| <= NET_CROWN_HALF_WIDTH. The test is 2D in the Y-Z plane:
# circle (puck) vs circle (pipe). Reflects the Y-Z velocity at POST_RESTITUTION, keeping the
# along-bar X channel. Launched loft tops out under the bar (~1.14 m vs the 1.19 m
# underside), but deflections / goalie rebounds can arrive higher, so this does fire in
# live play. Puck treated as a sphere of
# puck_radius here (the flat disc is oblate in Y-Z, so this is slightly generous vertically —
# harmless for a top-corner edge case).
static func resolve_crossbar(pos: Vector3, vel: Vector3, puck_radius: float, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	if absf(pos.x) > GameRules.NET_CROWN_HALF_WIDTH:
		return false
	var end_z: float = GameRules.GOAL_LINE_Z if pos.z >= 0.0 else -GameRules.GOAL_LINE_Z
	var combined_r: float = puck_radius + GameRules.NET_POST_RADIUS
	var dyz := Vector2(pos.y - GameRules.NET_HEIGHT, pos.z - end_z)
	var d: float = dyz.length()
	if d >= combined_r or d < 1e-6:
		return false
	var n := dyz / d  # (y, z)
	var ejected: Vector2 = Vector2(GameRules.NET_HEIGHT, end_z) + n * combined_r
	result.position = Vector3(pos.x, ejected.x, ejected.y)
	result.velocity = reflect_3d(vel, Vector3(0.0, n.x, n.y), POST_RESTITUTION)
	result.hit = true
	return true


# Resolve a puck against the two MOUTH-CORNER BENDS — the quarter-torus elbows
# joining each post top to its end of the crossbar. Together with resolve_posts
# (below the bend) and resolve_crossbar (inside the crown) these tile the frame
# continuously, so a puck leaving one surface is picked up by the next.
#
# The test is sphere-vs-torus reduced to a point test: find the nearest point on
# the bend's centre-line (NetGeometry.closest_point_on_bend) and treat the pipe as
# that point's tube radius. Reflects at POST_RESTITUTION like the rest of the
# iron, through the true 3D normal — a corner ping deflects up and sideways, which
# a horizontal-only deflect could not express.
static func resolve_crossbar_bends(
		pos: Vector3, vel: Vector3, puck_radius: float, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	# Only the corner band, laterally and vertically — cheap rejects first.
	var ax: float = absf(pos.x)
	if ax < GameRules.NET_CROWN_HALF_WIDTH - puck_radius \
			or ax > GameRules.NET_HALF_WIDTH + puck_radius:
		return false
	if pos.y < NetGeometry.post_top_y() - puck_radius \
			or pos.y > GameRules.NET_HEIGHT + puck_radius:
		return false
	var end_z: float = NetGeometry.near_end_z(pos.z)
	if absf(pos.z - end_z) > puck_radius + GameRules.NET_POST_RADIUS:
		return false
	var axis: Vector3 = NetGeometry.closest_point_on_bend(pos, end_z)
	var offset: Vector3 = pos - axis
	var d: float = offset.length()
	var combined_r: float = puck_radius + GameRules.NET_POST_RADIUS
	if d >= combined_r or d < 1e-6:
		return false
	var n: Vector3 = offset / d
	result.position = axis + n * combined_r
	result.velocity = reflect_3d(vel, n, POST_RESTITUTION)
	result.hit = true
	return true


# Resolve a puck against the TOP NET PANEL — a horizontal mesh plane at y = NET_HEIGHT over
# the net roof (|x| <= NET_CROWN_HALF_WIDTH, |z| in [GOAL_LINE_Z, GOAL_LINE_Z + NET_TOP_DEPTH]).
# The twine is two-sided; the vertical channel rebounds at NET_RESTITUTION (absorbs), keeping
# horizontal motion. Reachable in live play by a hard deflection / goalie rebound kicked up
# under the roof from inside the cage.
#
# SWEPT, not a thin-band snapshot: the face is chosen from the side the segment START (`prev`)
# was on, and a puck approaching from below is caught the instant its disc top reaches the
# twine, however far it overshot the plane centre this sub-step. The old point-sampled test
# read the contact side from the CURRENT position and only fired inside a ±half_height band,
# so a fast riser that cleared the ~3.5 cm band in one sub-step — or landed a hair ABOVE the
# plane while still moving up — was mistaken for a puck resting on top (normal up, upward
# velocity "separating") and sailed straight through to the ceiling. This is that fix.
static func resolve_top_net(prev: Vector3, pos: Vector3, vel: Vector3, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	if absf(pos.x) > GameRules.NET_CROWN_HALF_WIDTH:
		return false
	var az: float = absf(pos.z)
	if az < GameRules.GOAL_LINE_Z or az > GameRules.GOAL_LINE_Z + GameRules.NET_TOP_DEPTH:
		return false
	var hh: float = GameRules.PUCK_COLLISION_HALF_HEIGHT
	if prev.y <= GameRules.NET_HEIGHT:
		# Approaching from below (inside the cage): caught once the disc top reaches the
		# twine, and ejected flush just under it with the rebound driven DOWN.
		if pos.y < GameRules.NET_HEIGHT - hh:
			return false
		result.position = Vector3(pos.x, GameRules.NET_HEIGHT - hh, pos.z)
		result.velocity = reflect_3d(vel, Vector3(0.0, -1.0, 0.0), NET_RESTITUTION)
		result.hit = true
		return true
	# Resting on / dropping onto the roof from above.
	if pos.y > GameRules.NET_HEIGHT + hh:
		return false
	result.position = Vector3(pos.x, GameRules.NET_HEIGHT + hh, pos.z)
	result.velocity = reflect_3d(vel, Vector3(0.0, 1.0, 0.0), NET_RESTITUTION)
	result.hit = true
	return true


# Resolve a puck against the back and side net-mesh panels — TWO-SIDED, like the twine it
# models. Which face applies is classified from the segment START (`prev`, see
# NetGeometry.interior_or_mouth): a puck that entered through the open mouth (a scored puck,
# a bounce-out) plays the INTERIOR faces — clamped inside the cavity, with the mouth itself
# open so it can bounce back out. A puck OUTSIDE the netting (a
# wraparound rounding the cage, a rim pressing the back mesh) plays the EXTERIOR faces and
# is reflected away — it must never be pulled through the twine into the cavity (the
# pre-fix one-sided clamp teleported exactly those pucks inside). Rebounds absorb hard
# (NET_RESTITUTION); the existing NET_STUCK / settle logic drops a dead puck to the ice.
# Both a back and a side contact can apply in one interior tick (a shot into the corner).
static func resolve_net_panels(prev: Vector3, pos: Vector3, vel: Vector3,
		puck_radius: float, result: Result) -> bool:
	result.hit = false
	result.position = pos
	result.velocity = vel
	var az: float = absf(pos.z)
	# Nowhere near the netting: past the goal line out to the back mesh (+ radius),
	# under the roof (the top panel owns y ≥ NET_HEIGHT).
	if az <= GameRules.GOAL_LINE_Z or az > GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH + puck_radius:
		return false
	if absf(pos.x) > GameRules.NET_BACK_HALF_WIDTH + puck_radius or pos.y > GameRules.NET_HEIGHT:
		return false
	var p: Vector3 = pos
	var v: Vector3 = vel
	var hit: bool = false
	var end_sign: float = signf(pos.z)
	if NetGeometry.interior_or_mouth(prev):
		# INTERIOR faces (a puck that came in through the mouth). The back mesh is
		# a slanted plane, shallow at the top shelf — clamp to its depth AT THIS
		# HEIGHT (_back_depth_at_height) so a top-corner goal dies on the twine
		# instead of sailing through it into the deep cavity. The rebound stays a
		# horizontal −z absorb rather than the plane's true normal (which the
		# exterior face below does use): at NET_RESTITUTION the puck barely bounces
		# and then drops, so the ~21° lean isn't worth reflecting through, and a
		# scored puck kicks straight back out toward the mouth.
		var back_limit: float = GameRules.GOAL_LINE_Z + NetGeometry.back_depth_at_height(p.y) - puck_radius
		if absf(p.z) > back_limit:
			p.z = end_sign * back_limit
			v = reflect_3d(v, Vector3(0.0, 0.0, -end_sign), NET_RESTITUTION)
			hit = true
		var side_limit: float = NetGeometry.cavity_half_width() - puck_radius
		if absf(p.x) > side_limit:
			var x_sign: float = signf(p.x)
			p.x = x_sign * side_limit
			v = reflect_3d(v, Vector3(-x_sign, 0.0, 0.0), NET_RESTITUTION)
			hit = true
	else:
		# EXTERIOR faces (a puck outside the netting). Resolve the face whose plane
		# the segment is crossing from ITS side; a diagonal corner case resolves one
		# face now and the other on the next ≤4 cm sub-step.
		var back_dist: float = NetGeometry.back_plane_distance(p)
		if NetGeometry.back_plane_distance(prev) >= 0.0 and back_dist < puck_radius \
				and NetGeometry.within_back_panel(p.x, puck_radius):
			# Behind the back twine and pressing on it — a rim into the back of the
			# cage, or a puck dropping into the wedge above the slant. Eject flush
			# along the mesh's own normal (back AND up), so the puck dies on the
			# VISIBLE mesh at its own height and then tracks down the outside instead
			# of being pulled through into the cavity. Two guards keep this face from
			# answering for contacts that are not its own: `prev`'s side of the plane
			# (a puck in FRONT of it plays the side face below), and the panel's own
			# width — a puck rounding the cage's back corner is behind the plane but
			# laterally past the mesh, and claiming it here left the side face, which
			# is the one that should have stopped it, unreached in that sub-step.
			#
			# GEOMETRY uses the slant's normal; the RESPONSE stays a horizontal absorb,
			# like the interior face. Rebounding along the true normal instead sends the
			# tangential component UP the 21° slope — a hard rim into the back climbed
			# the twine and popped over the crossbar (from where it could drop into the
			# cavity through the open top), which is worse than the bug being fixed.
			p += NetGeometry.back_plane_normal(end_sign) * (puck_radius - back_dist)
			v = reflect_3d(v, Vector3(0.0, 0.0, end_sign), NET_RESTITUTION)
			hit = true
		else:
			var side_surface: float = NetGeometry.cavity_half_width()
			if absf(prev.x) >= side_surface and absf(p.x) < side_surface + puck_radius:
				# Beside the cage, pressing inward: reflect off the exterior side face.
				var x_sign: float = 1.0 if prev.x >= 0.0 else -1.0
				p.x = x_sign * (side_surface + puck_radius)
				v = reflect_3d(v, Vector3(x_sign, 0.0, 0.0), NET_RESTITUTION)
				hit = true
	if hit:
		result.hit = true
		result.position = p
		result.velocity = v
	return hit
