class_name GoalieCollisionShadow
extends RefCounted

# Phase-2 goalie-collision prototype instrument (docs/netcode-phase2-goalie-collision-
# spec.md). When Jolt fires a puck-vs-goalie contact, this runs the analytic
# swept-disc-vs-goalie-OBBs test (SweptDiscOBB) on the same swept segment and records
# whether it AGREES (detected the contact), which part it picked (vs the part Jolt
# reported), and whether the analytic normal is sane (points back at the puck). It
# answers the gating Phase-2 question — can the analytic model reproduce Jolt's goalie
# contacts? — deciding fully-deterministic vs hybrid. Dev + host only. Never drives the
# puck.
#
# Reactive (runs on Jolt's contact), so it measures agreement + part-match on Jolt's
# real contacts; it does NOT measure analytic false-positives (a proactive per-tick pass
# would — a later addition). `analytic_missed` (jolt_contacts - analytic_agreed) is the
# number to watch: contacts Jolt saw that the analytic test didn't reproduce.

var jolt_contacts: int = 0
var analytic_agreed: int = 0
var part_matches: int = 0
var normal_sane: int = 0          # analytic normal opposes the puck's travel (rebound-plausible)
var _scratch := SweptDiscOBB.Result.new()


func reset_session() -> void:
	jolt_contacts = 0
	analytic_agreed = 0
	part_matches = 0
	normal_sane = 0


# Called on a Jolt goalie contact. `goalie` = the Goalie hit; `jolt_part` = the specific
# StaticBody3D part Jolt reported (may be null); prev/curr = the puck's swept segment this
# tick; radius = puck collision radius.
func record_contact(goalie: Node, jolt_part: Node, prev: Vector3, curr: Vector3, radius: float) -> void:
	jolt_contacts += 1
	if goalie == null:
		return
	var best_toi: float = INF
	var best_part: Node = null
	var best_normal := Vector3.ZERO
	for cs: CollisionShape3D in _collision_shapes(goalie):
		var box := cs.shape as BoxShape3D
		if box == null:
			continue
		if SweptDiscOBB.contact(prev, curr, radius, cs.global_transform, box.size * 0.5, _scratch):
			if _scratch.toi < best_toi:
				best_toi = _scratch.toi
				best_part = _part_body(cs)
				best_normal = _scratch.normal
	if best_part == null:
		return  # analytic missed a contact Jolt saw — the failure this prototype hunts
	analytic_agreed += 1
	if jolt_part != null and best_part == jolt_part:
		part_matches += 1
	var travel := curr - prev
	if travel.length_squared() > 1e-9 and best_normal.dot(travel.normalized()) < 0.0:
		normal_sane += 1


static func _collision_shapes(root: Node) -> Array[CollisionShape3D]:
	var out: Array[CollisionShape3D] = []
	_gather_cs(root, out)
	return out


static func _gather_cs(node: Node, out: Array[CollisionShape3D]) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			out.append(child)
		_gather_cs(child, out)


# The StaticBody3D that owns a CollisionShape3D — Jolt reports contact against that body.
static func _part_body(cs: CollisionShape3D) -> Node:
	var p: Node = cs.get_parent()
	while p != null and not (p is StaticBody3D):
		p = p.get_parent()
	return p


func agreement_pct() -> float:
	return 100.0 * float(analytic_agreed) / float(jolt_contacts) if jolt_contacts > 0 else 0.0


func part_match_pct() -> float:
	return 100.0 * float(part_matches) / float(analytic_agreed) if analytic_agreed > 0 else 0.0


func summary() -> String:
	return "goalie-collision: jolt=%d caught=%d (%.0f%%) missed=%d part_match=%d (%.0f%%) normal_sane=%d" % [
		jolt_contacts, analytic_agreed, agreement_pct(), jolt_contacts - analytic_agreed,
		part_matches, part_match_pct(), normal_sane]
