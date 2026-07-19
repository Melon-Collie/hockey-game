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
	var goalie: Node = null


# Nearest contact of the swept disc (prev → curr, radius) against every goalie's boxes.
# Returns true and fills `out` on a hit; clears `out` and returns false otherwise. `scratch`
# is a caller-owned SweptDiscOBB.Result reused across parts to stay allocation-free.
static func nearest(goalies: Array, prev: Vector3, curr: Vector3, radius: float,
		scratch: SweptDiscOBB.Result, out: Contact) -> bool:
	out.hit = false
	out.part = null
	out.goalie = null
	out.toi = INF
	for goalie: Node in goalies:
		if goalie == null:
			continue
		for cs: CollisionShape3D in _collision_shapes(goalie):
			var box := cs.shape as BoxShape3D
			if box == null:
				continue
			if SweptDiscOBB.contact(prev, curr, radius, cs.global_transform, box.size * 0.5, scratch):
				if scratch.toi < out.toi:
					out.toi = scratch.toi
					out.point = scratch.point
					out.normal = scratch.normal
					out.part = _part_body(cs)
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
