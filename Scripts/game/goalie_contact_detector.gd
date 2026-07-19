class_name GoalieContactDetector
extends RefCounted

# Production analytic puck-vs-goalie contact detection for the determinism migration — the
# same swept-disc-vs-oriented-boxes test the Phase-2 harness (GoalieCollisionShadow) validated
# against Jolt (~97% agreement on real contacts), promoted to drive the puck. Given the puck's
# swept segment this tick and the live goalies, it returns the NEAREST contact (smallest time
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


# Nearest contact of the swept disc (prev → curr, radius) against every goalie's boxes.
# Returns true and fills `out` on a hit; clears `out` and returns false otherwise. `scratch`
# is a caller-owned SweptDiscOBB.Result reused across parts to stay allocation-free.
# Skips disabled shapes and parts whose collision layer is zeroed — the goalie's clear-sweep
# deliberately disables the stick collider for the swing's duration
# (Goalie.set_stick_collision_enabled), and the analytic test must honour that the same way
# Jolt did, or the goalie's own sweep ricochets off his "disabled" blade.
static func nearest(goalies: Array, prev: Vector3, curr: Vector3, radius: float,
		scratch: SweptDiscOBB.Result, out: Contact) -> bool:
	out.hit = false
	out.part = null
	out.goalie = null
	out.toi = INF
	out.depth = 0.0
	for goalie: Node in goalies:
		if goalie == null:
			continue
		# Real goalies serve a cached part list (the subtree is static after _ready;
		# a fresh recursive gather per query allocated hundreds of arrays/tick in a
		# crease scramble). Non-Goalie roots (test fixtures) fall back to a gather.
		var shapes: Array[CollisionShape3D]
		if goalie is Goalie:
			shapes = (goalie as Goalie).get_collision_parts()
		else:
			shapes = _collision_shapes(goalie)
		for cs: CollisionShape3D in shapes:
			if cs.disabled:
				continue
			var box := cs.shape as BoxShape3D
			if box == null:
				continue
			var body: Node = _part_body(cs)
			# Layer 0 == collision off (the runtime toggle mechanism); a part Jolt
			# would not collide must not contact analytically either.
			if body is CollisionObject3D and (body as CollisionObject3D).collision_layer == 0:
				continue
			if SweptDiscOBB.contact(prev, curr, radius, cs.global_transform, box.size * 0.5, scratch):
				if scratch.toi < out.toi:
					out.toi = scratch.toi
					out.point = scratch.point
					out.normal = scratch.normal
					out.depth = scratch.depth
					out.part = body
					out.goalie = goalie
					out.hit = true
	return out.hit


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
# save surface (Glove / Body / Head / Blocker / Stick / pad).
static func _part_body(cs: CollisionShape3D) -> Node:
	var p: Node = cs.get_parent()
	while p != null and not (p is StaticBody3D):
		p = p.get_parent()
	return p
