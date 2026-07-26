class_name PuckGeometryCollision

# Analytic puck-vs-goal-frame collision for the determinism migration
# (docs/netcode-determinism-migration.md). Replaces Jolt's PhysicsMaterial restitution
# bounce off the goal FRAME (posts, crossbar, top net panel) with deterministic analytic
# reflections so those bounces are client-reproducible. The goalie response stays in
# GoalieSaveRules; the back/side net panels are resolved separately.
#
# Geometry (from HockeyGoal, NHL-regulation): posts are vertical cylinders at
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

# Restitution off a goal pipe — mirrors Physics/goal_pipe.tres `bounce`. Kept as named
# constants here because the analytic path no longer reads the Jolt material; a puck-side
# mirror guard (like GameRules.PUCK_BOARD_BOUNCE ↔ boards.tres) should pin the pairs.
const POST_RESTITUTION: float = 0.55  # goal pipe (posts + crossbar)
const NET_RESTITUTION: float = 0.05   # net panels — mirrors Physics/goal_net.tres `bounce`


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
	# The pipes end at the crossbar — above it there is no post to hit (an airborne
	# puck over the bar is crossbar / top-net territory, not a phantom pipe ping).
	if pos.y > GameRules.NET_HEIGHT + puck_radius:
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


# Half-width of the net cavity's SIDE twine — the visible side panels are straight vertical
# planes at the post line (NET_HALF_WIDTH), so the lateral bound is constant with depth. (An
# earlier model widened this to NET_BACK_HALF_WIDTH toward the back, letting a corner-driven
# puck settle ~10 cm OUTSIDE the visible side mesh — a puck resting beside the twine. The
# real cage doesn't flare; the only lateral narrowing is the back panel's top edge, a corner
# gusset too small to model.)
static func _cavity_half_width() -> float:
	return GameRules.NET_HALF_WIDTH


# Goal-line-relative depth of the SLANTED back mesh at height `y`: the full
# NET_DEPTH (BASE_DEPTH) at the ice, tapering to NET_TOP_DEPTH under the
# crossbar. This mirrors HockeyGoal's back panel, whose top edge sits at
# NET_TOP_DEPTH and bottom at NET_DEPTH — the real NHL goal is shallow at the
# top shelf. A flat back wall at the full NET_DEPTH let a top-corner snipe sail
# ~0.35 m THROUGH the visible top twine before stopping, the "puck through the
# net after a goal" bug; a scored puck must die on the twine where the net
# actually is, not deep behind it.
static func _back_depth_at_height(y: float) -> float:
	var t: float = clampf(y / GameRules.NET_HEIGHT, 0.0, 1.0)
	return lerpf(GameRules.NET_DEPTH, GameRules.NET_TOP_DEPTH, t)


# ── The back mesh as ONE plane, resolved from BOTH sides ──────────────────────
# Because the taper above is linear, the back twine is a single plane leaning
# ~21° off vertical: in the (depth, y) half-plane of either end it runs from
# NET_DEPTH at the ice to NET_TOP_DEPTH under the crossbar.
#
# Interior and exterior MUST come from that one plane. They used not to: the
# interior clamp was the slant (above) while the exterior face was a vertical
# wall at the full NET_DEPTH, and the wedge between them — depth NET_TOP_DEPTH..
# NET_DEPTH, below the crossbar — is real ice OUTSIDE the cage that
# `_interior_or_mouth` nonetheless called cavity. Nothing guards that wedge from
# ABOVE (the top panel's rear edge IS the slant's top edge), so a puck DESCENDING
# into it — one trickling off the back of the net roof, a deflection dropping
# steeply behind the cage — was classified interior on the next sub-step and
# clamped forward THROUGH the twine, ending up sitting inside the net (no goal:
# GoalDetectionRules sees no fresh goal-line crossing, so the puck just sat there
# and play rolled on). The same mismatch stopped a puck driven at the back of the
# net at height dead in mid-air, up to ~0.45 m behind the visible mesh.
#
# Slope is negative — the twine gets shallower as it rises.
const _BACK_SLOPE: float = (GameRules.NET_TOP_DEPTH - GameRules.NET_DEPTH) / GameRules.NET_HEIGHT


# Signed PERPENDICULAR distance from `p` to this end's back-mesh plane, in metres,
# positive on the EXTERIOR (behind the twine) side. Sign alone classifies which
# face a puck is on — robust where the old depth-shell comparison sat on a knife
# edge with the ejection point it had to agree with.
static func _back_plane_distance(p: Vector3) -> float:
	var depth: float = absf(p.z) - GameRules.GOAL_LINE_Z
	return (depth - GameRules.NET_DEPTH - _BACK_SLOPE * p.y) / _back_plane_norm()


# Length of the (depth, y) plane normal (1, -_BACK_SLOPE) — the divisor that turns
# the plane equation into a true distance. Constant; a couple of multiplies and a
# sqrt, only reached inside the near-net band.
static func _back_plane_norm() -> float:
	return sqrt(1.0 + _BACK_SLOPE * _BACK_SLOPE)


# Unit outward normal of the back mesh at the end whose depth grows along
# `end_sign` * +z. It leans back AND UP, since the twine leans back as it drops.
static func _back_plane_normal(end_sign: float) -> Vector3:
	var inv: float = 1.0 / _back_plane_norm()
	return Vector3(0.0, -_BACK_SLOPE * inv, end_sign * inv)


# True when a puck at `p` is on the INTERIOR side of the netting — inside the cavity, or in
# front of the goal line within the open mouth (about to enter the way a scored puck does).
# The sub-stepped drive keeps the previous sample within ~4 cm of any crossing, so this
# local classification of the segment START decides which face of the twine the puck is on.
#
# The back test is the SLANT's own plane (_back_plane_distance), not a depth box: the wedge
# above the slant is behind the twine and must classify EXTERIOR however shallow it is.
static func _interior_or_mouth(p: Vector3) -> bool:
	if p.y > GameRules.NET_HEIGHT:
		return false
	var az: float = absf(p.z)
	if az <= GameRules.GOAL_LINE_Z:
		# In front of the goal-line plane: the only interior entry is the open mouth.
		return absf(p.x) <= GameRules.NET_HALF_WIDTH
	if _back_plane_distance(p) >= 0.0:
		return false
	return absf(p.x) < _cavity_half_width()


# Resolve a puck against the back and side net-mesh panels — TWO-SIDED, like the twine it
# models. Which face applies is classified from the segment START (`prev`, see
# _interior_or_mouth): a puck that entered through the open mouth (a scored puck, a
# bounce-out) plays the INTERIOR faces — clamped inside the cavity: the back mesh tapers from
# NET_DEPTH at the ice to NET_TOP_DEPTH under the crossbar (the slanted back), the side twine
# is straight at NET_HALF_WIDTH (_cavity_half_width), and the mouth itself is open so it can
# bounce back out. A puck OUTSIDE the netting (a
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
	if _interior_or_mouth(prev):
		# INTERIOR faces (a puck that came in through the mouth). The back mesh is
		# a slanted plane, shallow at the top shelf — clamp to its depth AT THIS
		# HEIGHT (_back_depth_at_height) so a top-corner goal dies on the twine
		# instead of sailing through it into the deep cavity. The rebound stays a
		# horizontal −z absorb rather than the plane's true normal (which the
		# exterior face below does use): at NET_RESTITUTION the puck barely bounces
		# and then drops, so the ~21° lean isn't worth reflecting through, and a
		# scored puck kicks straight back out toward the mouth.
		var back_limit: float = GameRules.GOAL_LINE_Z + _back_depth_at_height(p.y) - puck_radius
		if absf(p.z) > back_limit:
			p.z = end_sign * back_limit
			v = reflect_3d(v, Vector3(0.0, 0.0, -end_sign), NET_RESTITUTION)
			hit = true
		var side_limit: float = _cavity_half_width() - puck_radius
		if absf(p.x) > side_limit:
			var x_sign: float = signf(p.x)
			p.x = x_sign * side_limit
			v = reflect_3d(v, Vector3(-x_sign, 0.0, 0.0), NET_RESTITUTION)
			hit = true
	else:
		# EXTERIOR faces (a puck outside the netting). Resolve the face whose plane
		# the segment is crossing from ITS side; a diagonal corner case resolves one
		# face now and the other on the next ≤4 cm sub-step.
		var back_dist: float = _back_plane_distance(p)
		if _back_plane_distance(prev) >= 0.0 and back_dist < puck_radius:
			# Behind the back twine and pressing on it — a rim into the back of the
			# cage, or a puck dropping into the wedge above the slant. Eject flush
			# along the mesh's own normal (back AND up), so the puck dies on the
			# VISIBLE mesh at its own height and then tracks down the outside instead
			# of being pulled through into the cavity. Starting from `prev`'s side
			# (rather than the position alone) keeps a puck BESIDE the cage — in front
			# of this plane but laterally outside — on the side face below.
			#
			# GEOMETRY uses the slant's normal; the RESPONSE stays a horizontal absorb,
			# like the interior face. Rebounding along the true normal instead sends the
			# tangential component UP the 21° slope — a hard rim into the back climbed
			# the twine and popped over the crossbar (from where it could drop into the
			# cavity through the open top), which is worse than the bug being fixed.
			p += _back_plane_normal(end_sign) * (puck_radius - back_dist)
			v = reflect_3d(v, Vector3(0.0, 0.0, end_sign), NET_RESTITUTION)
			hit = true
		else:
			var side_surface: float = _cavity_half_width()
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
