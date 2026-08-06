class_name NetBladeCollision

# The stick's collision with the net. Two materials, because a real goal is two
# materials and they behave nothing alike:
#
#   PIPES (posts) — hard, thin, exactly where they are drawn. The blade stops on
#     iron, and a carried puck driven into iron is stripped off the pipe's own
#     reflection (SkaterIKCoordinator). Ringing a post should cost you the puck.
#   TWINE (sides, back) — compliant. The blade sinks in to `mesh_give` against
#     the mesh and stops there. It is NOT teleported to a face, and touching
#     twine does NOT strip the puck: a stick buried in the side mesh simply
#     cannot do anything, which is what physically happens and what reads
#     correctly. The old flat-box clamp confiscated the puck instead.
#
# There is no legality concept here — no "did you enter through the mouth", no
# mouth column, no `allow_front`. This is a surface. A puck ends up in the net
# only by going through the mouth, because the mouth is the only opening; see
# `docs/net-play-plan.md` §3.
#
# The blade is a SEGMENT (heel → toe), not a point. It has to be: a post is 3 cm
# across and a blade ~30 cm long, so a stick sweeping across the post with both
# ends clear is the case that decides wraparound goals, and it is invisible to
# any point sample. (The boards have always tested heel and toe —
# `Skater.clamp_blade_to_walls`. The net, where the difference actually decides
# goals, did not.)
#
# Pure and allocation-free: fills a caller-owned Result.

class Result:
	# World-space translation to apply to the blade. The caller owns the blade
	# anchor (a heel, in practice) and moves it by this; the arm is then rebuilt
	# to reach it via TopHandIK.hand_for_clamped_blade.
	var offset: Vector3 = Vector3.ZERO
	# Outward normal of the pipe struck, or ZERO when only twine was touched.
	# Non-zero is the strip signal AND the direction the puck leaves along.
	var pipe_normal: Vector3 = Vector3.ZERO

	func hit() -> bool:
		return offset != Vector3.ZERO or pipe_normal != Vector3.ZERO


# Resolve the blade segment against the near end's net. `prev` is the blade's
# previous world contact point, used only to classify which side of the two-sided
# twine the stick is on — a sweep question, never a history one.
#
# `half_thickness` is the blade's own reach perpendicular to the segment;
# `mesh_give` is how deep the twine lets it sink before stopping.
#
# Returns true when anything was hit.
static func resolve(
		prev: Vector3,
		heel: Vector3,
		toe: Vector3,
		half_thickness: float,
		mesh_give: float,
		result: Result) -> bool:
	result.offset = Vector3.ZERO
	result.pipe_normal = Vector3.ZERO
	# A stick above the crossbar is over the net, not in it — the roof twine is
	# the puck's problem, and constraining a raised stick there would fight the
	# deflect/stick-lift poses for no gameplay gain.
	if heel.y > GameRules.NET_HEIGHT and toe.y > GameRules.NET_HEIGHT:
		return false
	var end_z: float = NetGeometry.near_end_z(heel.z)
	# Cheap early-out: the whole blade is well clear of this end's cage.
	var reach: float = GameRules.NET_DEPTH + half_thickness + 1.0
	if absf(heel.z - end_z) > reach and absf(toe.z - end_z) > reach:
		return false
	# Same in x, which the depth test above cannot stand in for: the cage is
	# NET_BACK_HALF_WIDTH across at its widest, so a stick out by the boards is
	# touching nothing however close to the goal line it is. The bound is the
	# cage's own footprint plus this caller's clearance — a stick within the give
	# is sunk in compliant mesh, one beyond it never crossed anything — and it is
	# what stops a blade in the corner from being claimed by a face whose plane
	# happens to run past it. Tested on the blade's x-INTERVAL rather than end by
	# end, so a segment lying across the cage still resolves.
	var lateral: float = GameRules.NET_BACK_HALF_WIDTH + half_thickness + mesh_give
	if minf(heel.x, toe.x) > lateral or maxf(heel.x, toe.x) < -lateral:
		return false

	# ── Pipes first: iron wins, and a post hit is the terminal answer ─────────
	# Resolved before twine so a blade wedged at the post reports the pipe (which
	# strips) rather than a side-mesh graze (which does not).
	var a := Vector2(heel.x, heel.z)
	var b := Vector2(toe.x, toe.z)
	var near_x: float = GameRules.NET_HALF_WIDTH if heel.x >= 0.0 else -GameRules.NET_HALF_WIDTH
	var post: Vector3 = NetGeometry.post_overlap_xz(a, b, near_x, end_z, half_thickness)
	if post.x <= 0.0:
		post = NetGeometry.post_overlap_xz(a, b, -near_x, end_z, half_thickness)
	if post.x > 0.0:
		result.pipe_normal = Vector3(post.y, 0.0, post.z)
		result.offset = result.pipe_normal * post.x
		return true
	# The mouth-corner bends, so the blade sees the same three-piece frame the puck
	# does. Sampled at the blade's closest approach to the bend's centre rather
	# than swept along it: unlike the post — which a stick sweeps ACROSS at ice
	# level, the case that decides wraparounds — the bend is only reachable by a
	# raised stick already near the crown, where a point sample is honest.
	if _resolve_bend(heel, toe, end_z, half_thickness, result):
		return true

	# ── Twine: compliant, and two-sided like the mesh it models ──────────────
	# The surface the blade stops at is the twine pushed back by `mesh_give`, so
	# the stick visibly sinks into the mesh instead of skidding along an invisible
	# hard wall standing off it.
	var interior: bool = NetGeometry.interior_or_mouth(prev)
	var offset := Vector3.ZERO
	for point: Vector3 in [heel, toe]:
		if point.y > GameRules.NET_HEIGHT:
			continue
		var moved: Vector3 = _twine_offset(prev, point + offset, interior, mesh_give, end_z)
		# Adopt the larger correction, exactly as the board clamp does across heel
		# and toe — one translation has to satisfy both ends.
		if moved.length_squared() > offset.length_squared():
			offset = moved
	if offset == Vector3.ZERO:
		return false
	result.offset = offset
	return true


# Blade vs a mouth-corner bend. Samples the blade at its closest approach to the
# bend's centre, then does the same sphere-vs-centre-line test the puck does.
# Fills `result` and returns true on contact.
static func _resolve_bend(
		heel: Vector3, toe: Vector3, end_z: float, half_thickness: float,
		result: Result) -> bool:
	var lo: float = NetGeometry.post_top_y() - half_thickness
	var hi: float = GameRules.NET_HEIGHT + half_thickness
	if (heel.y < lo and toe.y < lo) or (heel.y > hi and toe.y > hi):
		return false
	# The bend the blade is nearest, then the point on the blade nearest IT.
	var side: float = 1.0 if (heel.x + toe.x) >= 0.0 else -1.0
	var centre := Vector3(
			side * GameRules.NET_CROWN_HALF_WIDTH, NetGeometry.post_top_y(), end_z)
	var span: Vector3 = toe - heel
	var len_sq: float = span.length_squared()
	var sample: Vector3 = heel
	if len_sq > 0.000001:
		sample = heel + span * clampf((centre - heel).dot(span) / len_sq, 0.0, 1.0)
	var axis: Vector3 = NetGeometry.closest_point_on_bend(sample, end_z)
	var offset: Vector3 = sample - axis
	var d: float = offset.length()
	var reach: float = GameRules.NET_POST_RADIUS + half_thickness
	if d >= reach or d < 0.000001:
		return false
	result.pipe_normal = offset / d
	result.offset = result.pipe_normal * (reach - d)
	return true


# Correction that puts a single blade point back outside the compliant twine.
# Interior and exterior faces come from ONE plane per surface (the slanted back,
# the straight sides), so a stick pressing from either side is stopped at the
# mesh rather than pulled through it.
static func _twine_offset(
		prev: Vector3,
		point: Vector3,
		interior: bool,
		mesh_give: float,
		end_z: float) -> Vector3:
	var end_sign: float = signf(end_z)
	# Twine depth is measured on the blade's own line. half_thickness is a pipe
	# concern — iron is 3 cm across and the millimetres matter there; against a
	# compliant panel that gives 12 cm they are noise, and folding them in would
	# only make `mesh_give` mean something other than what it says.
	var give: float = mesh_give
	if interior:
		var az: float = absf(point.z)
		if az <= GameRules.GOAL_LINE_Z:
			return Vector3.ZERO  # in the open mouth — nothing to collide with
		var out := Vector3.ZERO
		var back_limit: float = GameRules.GOAL_LINE_Z \
				+ NetGeometry.back_depth_at_height(point.y) + give
		if az > back_limit:
			out.z = end_sign * back_limit - point.z
		var side_limit: float = NetGeometry.cavity_half_width() + give
		if absf(point.x) > side_limit:
			out.x = signf(point.x) * side_limit - point.x
		return out
	# EXTERIOR. Which face applies is read from the side the segment START was on,
	# mirroring PuckGeometryCollision.resolve_net_panels — without that, a stick
	# reaching in from BESIDE the cage (in front of the back plane, but laterally
	# outside) is mistaken for one pressing the back mesh and gets shoved along the
	# slant instead of stopping in the side twine.
	if NetGeometry.back_plane_distance(prev) >= 0.0 \
			and NetGeometry.within_back_panel(point.x, give):
		# Behind the back twine, pressing on it. Ejected along the mesh's own
		# leaning normal, so the stick stops on the VISIBLE twine at its own height
		# rather than being pulled through into the cavity.
		var back_dist: float = NetGeometry.back_plane_distance(point)
		if back_dist < -give:
			return NetGeometry.back_plane_normal(end_sign) * (-give - back_dist)
		return Vector3.ZERO
	var surface: float = NetGeometry.cavity_half_width()
	var side_stop: float = surface - give
	if absf(prev.x) >= surface and absf(point.x) < side_stop \
			and absf(point.z) > GameRules.GOAL_LINE_Z:
		return Vector3(signf(prev.x) * side_stop - point.x, 0.0, 0.0)
	return Vector3.ZERO
