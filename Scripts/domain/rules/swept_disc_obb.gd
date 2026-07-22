class_name SweptDiscOBB

# Swept-disc (treated as a sphere of `radius`) vs oriented box (OBB) contact test — the
# atom of the Phase-2 goalie-collision prototype (docs/netcode-phase2-goalie-collision-
# spec.md). Every goalie collision part is a BoxShape3D, so puck-vs-goalie is
# swept-sphere-vs-N-OBBs. Method: transform the swept segment into the box's LOCAL space
# (box becomes an axis-aligned box centred at the origin), expand the box by the sphere
# radius (Minkowski sum), and run a ray-vs-AABB slab test for the time of impact and the
# entry face → outward normal. The world normal is the box basis applied to the local
# face normal.
#
# Edge/corner contacts approximate to the dominant entry-slab axis — fine for the
# DETECTION + rebound-direction agreement this prototype measures; the actual response
# is GoalieSaveRules, which re-steers. Pure value-type math, no allocation (fills a
# caller-owned Result).

class Result:
	var hit: bool = false
	var toi: float = 0.0                 # 0..1 along prev->curr at first contact
	var point: Vector3 = Vector3.ZERO    # world contact point (sphere centre at toi)
	var normal: Vector3 = Vector3.ZERO   # world outward surface normal
	# Penetration of the sphere CENTRE into the Minkowski-expanded box along `normal`
	# at toi. 0 for a clean surface contact; positive for a start-inside contact —
	# `point + normal * depth` is the centre pushed flush onto the expanded surface
	# (i.e. the sphere resting ON the box face). Callers ejecting the disc use this;
	# adding a further `radius` along the normal double-counts (the expanded box is
	# already radius bigger than the real one).
	var depth: float = 0.0


# box_transform: world transform of the box CENTRE (CollisionShape3D.global_transform).
# half_extents: BoxShape3D.size * 0.5. Returns Result.hit and fills `result`.
static func contact(prev: Vector3, curr: Vector3, radius: float,
		box_transform: Transform3D, half_extents: Vector3, result: Result) -> bool:
	result.hit = false
	var inv: Transform3D = box_transform.affine_inverse()
	var p0: Vector3 = inv * prev
	var p1: Vector3 = inv * curr
	var d: Vector3 = p1 - p0
	var e: Vector3 = half_extents + Vector3(radius, radius, radius)  # expanded box half-size
	var t_near: float = -INF
	var t_far: float = INF
	var hit_axis: int = -1
	var hit_sign: float = 0.0
	for axis in 3:
		var o: float = p0[axis]
		var dir: float = d[axis]
		if absf(dir) < 1e-9:
			# Segment parallel to this slab: no contact if it starts outside the slab.
			if o < -e[axis] or o > e[axis]:
				return false
		else:
			var inv_d: float = 1.0 / dir
			var t1: float = (-e[axis] - o) * inv_d  # low face
			var t2: float = (e[axis] - o) * inv_d   # high face
			var sign: float = -1.0                  # entering the low (-axis) face
			if t1 > t2:
				var tmp: float = t1
				t1 = t2
				t2 = tmp
				sign = 1.0                          # entering the high (+axis) face
			if t1 > t_near:
				t_near = t1
				hit_axis = axis
				hit_sign = sign
			t_far = minf(t_far, t2)
			if t_near > t_far:
				return false
	# Contact must land within this tick's segment. t_far < 0 (box behind the start) or
	# t_near > 1 (contact beyond curr) is a miss. t_near < 0 means the start point is
	# already inside the expanded box; hit_axis < 0 means every axis took the parallel
	# branch WITHOUT rejecting — a (near-)zero-length sweep fully inside the box, e.g.
	# the goalie dropping onto a RESTING puck, which the ray test alone cannot see.
	if hit_axis >= 0 and (t_far < 0.0 or t_near > 1.0):
		return false
	var toi: float = clampf(t_near, 0.0, 1.0) if hit_axis >= 0 else 0.0
	var depth: float = 0.0
	if hit_axis < 0 or t_near < 0.0:
		# Start-inside contact: depenetrate along the MINIMUM-penetration axis of the
		# start point. That axis's face is also the honest contact normal here — the
		# backward-extrapolated entry slab could name a face the puck never touched
		# (and under the analytic drive the normal now drives the save response, not
		# just a detection metric).
		toi = 0.0
		var best_axis: int = 0
		var best_pen: float = INF
		for axis in 3:
			var pen: float = e[axis] - absf(p0[axis])
			if pen < best_pen:
				best_pen = pen
				best_axis = axis
		hit_axis = best_axis
		hit_sign = 1.0 if p0[best_axis] >= 0.0 else -1.0
		depth = maxf(best_pen, 0.0)
	var local_n := Vector3.ZERO
	local_n[hit_axis] = hit_sign
	result.hit = true
	result.toi = toi
	result.point = prev + (curr - prev) * toi
	result.normal = (box_transform.basis * local_n).normalized()
	result.depth = depth
	return true
