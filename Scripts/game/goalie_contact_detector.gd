class_name GoalieContactDetector
extends RefCounted

# Analytic puck-vs-goalie contact detection: a swept-disc-vs-oriented-boxes test. Given the
# puck's swept segment this tick and the live goalies, it returns the NEAREST contact (smallest time
# of impact) across every goalie part's BoxShape3D: which part was struck (for save-part
# classification), the contact point, and the outward surface normal. The response
# (deaden / steer / catch / live reflect) is GoalieSaveRules.resolve_contact — this only finds
# the contact. Fills a caller-owned Contact (no per-tick allocation).

class Contact:
	var hit: bool = false
	var part: Node = null          # the StaticBody3D part struck — classify via node name
	var point: Vector3 = Vector3.ZERO
	var normal: Vector3 = Vector3.ZERO   # outward, from the surface toward the puck
	var toi: float = INF
	var depth: float = 0.0         # start-inside depenetration along normal (see SweptDiscOBB)
	var goalie: Node = null
	# World velocity (m/s) of the struck part — the save resolves the rebound in
	# this frame (GoalieSaveRules.resolve_contact). Zero for a fixture root that
	# is not a real Goalie, which is the same as today's static-wall response.
	var part_velocity: Vector3 = Vector3.ZERO


# Nearest contact of the swept disc (prev → curr, radius) against every goalie's boxes.
# Returns true and fills `out` on a hit; clears `out` and returns false otherwise. `scratch`
# is a caller-owned SweptDiscOBB.Result reused across parts to stay allocation-free.
# Skips disabled shapes and parts whose collision layer is zeroed — the goalie's clear-sweep
# deliberately disables the stick collider for the swing's duration
# (Goalie.set_stick_collision_enabled), and the analytic test must honour that too, or the
# goalie's own sweep ricochets off his "disabled" blade.
# Native swept-OBB atom (null = extension absent, GDScript SweptDiscOBB). The
# obb_contact method needs no geometry configuration, so a bare instance
# suffices; misses cost one boundary crossing, hits add four getters.
static var _native_obb: RefCounted = null
static var _native_obb_checked: bool = false

# Non-box marker in a Goalie's cached half-extent array (a real half extent is
# never negative); the shared frozen empty keeps the fixture path allocation-free
# (an empty PackedVector3Array default-constructs without a heap buffer, so the
# halves local needs no shared counterpart).
const _NON_BOX_HALF := Vector3(-1.0, -1.0, -1.0)
const _EMPTY_BODIES: Array[Node] = []


static func nearest(goalies: Array, prev: Vector3, curr: Vector3, radius: float,
		scratch: SweptDiscOBB.Result, out: Contact) -> bool:
	if not _native_obb_checked:
		_native_obb_checked = true
		if ClassDB.class_exists(&"NativePuckStep"):
			_native_obb = ClassDB.instantiate(&"NativePuckStep")
	out.hit = false
	out.part = null
	out.goalie = null
	out.toi = INF
	out.depth = 0.0
	out.part_velocity = Vector3.ZERO
	for goalie: Node in goalies:
		if goalie == null:
			continue
		# Real goalies serve cached part lists (the subtree is static after _ready;
		# a fresh recursive gather per query would allocate hundreds of arrays/tick
		# in a crease scramble, and the owning-body walk + box-size read cost engine
		# calls per part per query). Non-Goalie roots (test fixtures) fall back to
		# a live gather + per-part resolution.
		var real: Goalie = goalie as Goalie
		var shapes: Array[CollisionShape3D]
		var bodies: Array[Node] = _EMPTY_BODIES
		var halves: PackedVector3Array
		var vels: PackedVector3Array
		if real != null:
			shapes = real.get_collision_parts()
			bodies = real.get_collision_part_bodies()
			halves = real.get_collision_part_half_extents()
			vels = real.get_collision_part_velocities()
		else:
			shapes = _collision_shapes(goalie)
		for i: int in shapes.size():
			var cs: CollisionShape3D = shapes[i]
			if cs.disabled:
				continue
			var half: Vector3
			var body: Node
			if real != null:
				half = halves[i]
				body = bodies[i]
			else:
				var box := cs.shape as BoxShape3D
				half = box.size * 0.5 if box != null else _NON_BOX_HALF
				body = _part_body(cs)
			if half.x < 0.0:
				continue
			# Layer 0 == collision off (the runtime toggle mechanism); a part flagged
			# non-colliding must not register an analytic contact either.
			if body is CollisionObject3D and (body as CollisionObject3D).collision_layer == 0:
				continue
			var contact_hit: bool
			if _native_obb != null:
				contact_hit = _native_obb.obb_contact(
						prev, curr, radius, cs.global_transform, half)
				if contact_hit:
					scratch.toi = _native_obb.get_obb_toi()
					scratch.point = _native_obb.get_obb_point()
					scratch.normal = _native_obb.get_obb_normal()
					scratch.depth = _native_obb.get_obb_depth()
			else:
				contact_hit = SweptDiscOBB.contact(
						prev, curr, radius, cs.global_transform, half, scratch)
			if contact_hit:
				if scratch.toi < out.toi:
					out.toi = scratch.toi
					out.point = scratch.point
					out.normal = scratch.normal
					out.depth = scratch.depth
					out.part = body
					out.goalie = goalie
					out.part_velocity = vels[i] if real != null else Vector3.ZERO
					out.hit = true
	return out.hit


# ── Gather-once fast path (native) ────────────────────────────────────────────
# The per-sub-step cost of nearest() is dominated by engine property reads
# (global_transform / size / disabled / collision_layer per part), re-paid up
# to 16x per near-net tick. The native path splits detection: gather_boxes
# reads every eligible part ONCE per tick into a packed 15-float-per-box array
# (basis columns, origin, half extents) plus parallel part/goalie ref arrays,
# then nearest_packed runs the whole slab-test loop natively per sub-step with
# zero engine reads. Callers gate on the native step being available and fall
# back to nearest() otherwise; skip rules here MUST mirror nearest()'s.
static func gather_boxes(goalies: Array, packed: PackedFloat32Array,
		parts: Array, part_goalies: Array,
		part_velocities: PackedVector3Array) -> int:
	parts.clear()
	part_goalies.clear()
	var idx: int = 0
	for goalie: Node in goalies:
		if goalie == null:
			continue
		var real: Goalie = goalie as Goalie
		var shapes: Array[CollisionShape3D]
		var bodies: Array[Node] = _EMPTY_BODIES
		var halves: PackedVector3Array
		var vels: PackedVector3Array
		if real != null:
			shapes = real.get_collision_parts()
			bodies = real.get_collision_part_bodies()
			halves = real.get_collision_part_half_extents()
			vels = real.get_collision_part_velocities()
		else:
			shapes = _collision_shapes(goalie)
		for i: int in shapes.size():
			var cs: CollisionShape3D = shapes[i]
			if cs.disabled:
				continue
			var half: Vector3
			var body: Node
			if real != null:
				half = halves[i]
				body = bodies[i]
			else:
				var box := cs.shape as BoxShape3D
				half = box.size * 0.5 if box != null else _NON_BOX_HALF
				body = _part_body(cs)
			if half.x < 0.0:
				continue
			if body is CollisionObject3D and (body as CollisionObject3D).collision_layer == 0:
				continue
			var base: int = idx * 15
			if packed.size() < base + 15:
				packed.resize(base + 15)
			var xf: Transform3D = cs.global_transform
			packed[base] = xf.basis.x.x
			packed[base + 1] = xf.basis.x.y
			packed[base + 2] = xf.basis.x.z
			packed[base + 3] = xf.basis.y.x
			packed[base + 4] = xf.basis.y.y
			packed[base + 5] = xf.basis.y.z
			packed[base + 6] = xf.basis.z.x
			packed[base + 7] = xf.basis.z.y
			packed[base + 8] = xf.basis.z.z
			packed[base + 9] = xf.origin.x
			packed[base + 10] = xf.origin.y
			packed[base + 11] = xf.origin.z
			packed[base + 12] = half.x
			packed[base + 13] = half.y
			packed[base + 14] = half.z
			# Velocity rides a parallel array rather than the packed slab: the
			# kernel tests geometry to find WHICH box was struck, and the
			# velocity is only wanted for the response to the one it names. A
			# wider stride would cost every box to serve at most one.
			if part_velocities.size() <= idx:
				part_velocities.resize(idx + 1)
			part_velocities[idx] = vels[i] if real != null else Vector3.ZERO
			parts.append(body)
			part_goalies.append(goalie)
			idx += 1
	return idx


# The packed-gather counterpart of nearest(): one native crossing per sub-step.
# Valid only when the native extension is loaded (callers gate on it).
static func nearest_packed(packed: PackedFloat32Array, count: int,
		parts: Array, part_goalies: Array, part_velocities: PackedVector3Array,
		prev: Vector3, curr: Vector3, radius: float, out: Contact) -> bool:
	out.hit = false
	out.part = null
	out.goalie = null
	out.toi = INF
	out.depth = 0.0
	out.part_velocity = Vector3.ZERO
	if count == 0 or _native_obb == null:
		return false
	var best: int = _native_obb.obb_nearest(prev, curr, radius, packed, count)
	if best < 0:
		return false
	out.toi = _native_obb.get_obb_toi()
	out.point = _native_obb.get_obb_point()
	out.normal = _native_obb.get_obb_normal()
	out.depth = _native_obb.get_obb_depth()
	out.part = parts[best]
	out.goalie = part_goalies[best]
	out.part_velocity = part_velocities[best]
	out.hit = true
	return true


# Lazily resolves the native handle outside nearest() so gather-path callers
# can gate on it before their per-tick gather.
static func native_available() -> bool:
	if not _native_obb_checked:
		_native_obb_checked = true
		if ClassDB.class_exists(&"NativePuckStep"):
			_native_obb = ClassDB.instantiate(&"NativePuckStep")
	return _native_obb != null


static func _collision_shapes(root: Node) -> Array[CollisionShape3D]:
	var found: Array[CollisionShape3D] = []
	_gather_cs(root, found)
	return found


static func _gather_cs(node: Node, found: Array[CollisionShape3D]) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			found.append(child)
		_gather_cs(child, found)


# The StaticBody3D that owns a CollisionShape3D — the part whose node name classifies the
# save surface (Glove / Body / Head / Blocker / Stick / pad). Fixture fallback only:
# real Goalies serve this pre-resolved from get_collision_part_bodies().
static func _part_body(cs: CollisionShape3D) -> Node:
	var p: Node = cs.get_parent()
	while p != null and not (p is StaticBody3D):
		p = p.get_parent()
	return p
