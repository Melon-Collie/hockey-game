class_name TutorialTargets
extends Node3D

# Glowing ring targets drawn in the goal plane for the Shooting tutorial's
# "Pick Your Spot" and "Beat the Goalie" drills. Procedural (no scene edits),
# following the slapshot-reticle pattern in skater_hud_coordinator: an ArrayMesh
# ring + an unshaded, alpha-blended, double-sided material so it reads clearly
# over the net and the goalie. TutorialManager owns placement and hit logic;
# this node just renders the set and hides a ring when it's cleared.

const _RING_INNER: float = 0.20
const _RING_OUTER: float = 0.30
const _SEGMENTS:   int   = 28
const _COLOR := Color(1.0, 0.82, 0.18, 0.92)   # bright amber

var _material: StandardMaterial3D = null
var _mesh:     ArrayMesh          = null
var _rings:    Array[MeshInstance3D] = []


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = _COLOR
	_mesh = _build_ring_mesh()


# Replaces any existing targets with a fresh set at the given net-plane (x, y)
# positions. They sit on the goal plane at `goal_line_z`, nudged `front_offset`
# toward the shooter so they float just in front of the net mesh.
func show_targets(positions: Array[Vector2], goal_line_z: float, front_offset: float) -> void:
	clear()
	for p: Vector2 in positions:
		var inst := MeshInstance3D.new()
		inst.mesh = _mesh
		inst.material_override = _material
		inst.position = Vector3(p.x, p.y, goal_line_z + front_offset)
		add_child(inst)
		_rings.append(inst)


# Hide one ring once its target is cleared (positive feedback — the target pops
# off the net). Index matches the position passed to show_targets.
func hide_target(index: int) -> void:
	if index >= 0 and index < _rings.size() and is_instance_valid(_rings[index]):
		_rings[index].visible = false


func clear() -> void:
	for r: MeshInstance3D in _rings:
		if is_instance_valid(r):
			r.queue_free()
	_rings.clear()


# Ring lying in the XY plane (facing the shooter down +Z), built as a triangle
# strip between an inner and outer radius — same construction as the HUD's
# charge ring, rotated into the vertical goal plane.
func _build_ring_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for i: int in _SEGMENTS:
		var a0: float = TAU * i / _SEGMENTS
		var a1: float = TAU * (i + 1) / _SEGMENTS
		var base: int = verts.size()
		verts.append(Vector3(cos(a0) * _RING_INNER, sin(a0) * _RING_INNER, 0.0))
		verts.append(Vector3(cos(a0) * _RING_OUTER, sin(a0) * _RING_OUTER, 0.0))
		verts.append(Vector3(cos(a1) * _RING_INNER, sin(a1) * _RING_INNER, 0.0))
		verts.append(Vector3(cos(a1) * _RING_OUTER, sin(a1) * _RING_OUTER, 0.0))
		for _n: int in 4:
			normals.append(Vector3.BACK)
		indices.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
