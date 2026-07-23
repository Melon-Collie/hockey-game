class_name DrillGates
extends Node3D

# Procedural gate markers for the Dangle Gauntlet drill — one lightweight
# "gate" (two posts + a top bar) per DangleDrillRules.Gate. Procedural (no scene
# edits), following the TutorialTargets / TutorialWall pattern: unshaded,
# double-sided, alpha-blended meshes with materials cached by colour.
#
# These are PURELY VISUAL — no collider, no physics layer. You skate (and carry
# the puck) straight through the gap; the manager owns the actual checkpoint
# test (DangleDrillRules.crossed_gate). Colour is the whole feedback: the gate
# you're on glows amber, cleared gates turn green, upcoming gates sit dim.
# dangle_gauntlet_manager.gd owns placement (show_course) and recolouring
# (set_state) as the run progresses.

enum State { PENDING, ACTIVE, CLEARED }

const _POST_HEIGHT: float = 1.5
const _POST_RADIUS: float = 0.06
const _BAR_THICKNESS: float = 0.09
const _ICE_Y: float = 0.0

const _PENDING_COLOR: Color = Color(0.45, 0.55, 0.72, 0.55)  # dim cool blue
const _ACTIVE_COLOR: Color  = Color(1.0, 0.82, 0.18, 0.95)   # amber (matches targets)
const _CLEARED_COLOR: Color = Color(0.3, 1.0, 0.45, 0.9)     # drill green

var _material_cache: Dictionary = {}       # color -> StandardMaterial3D
var _post_mesh_cache: Dictionary = {}      # "h" -> CylinderMesh (shared)
var _gate_nodes: Array[Node3D] = []        # one container per gate, index-aligned


# Replaces any existing gates with markers for the built course. Each gate is
# oriented to its through-axis so the posts sit on the lateral line the puck
# threads. Every gate starts PENDING; the manager lights the first one ACTIVE.
func show_course(gates: Array) -> void:
	clear()
	for g: DangleDrillRules.Gate in gates:
		var node := Node3D.new()
		node.position = Vector3(g.center.x, _ICE_Y, g.center.y)
		# Rotate about Y so the local Z axis points along the through-axis; the
		# local X axis is then the lateral post line (perpendicular to the axis).
		node.rotation = Vector3(0.0, atan2(g.axis.x, g.axis.y), 0.0)
		add_child(node)

		# Two vertical posts at ±half_width along the local X (lateral) axis.
		for side: float in [-1.0, 1.0]:
			var post := MeshInstance3D.new()
			post.mesh = _post_mesh()
			post.position = Vector3(side * g.half_width, _POST_HEIGHT * 0.5, 0.0)
			node.add_child(post)

		# A top bar bridging the posts, so the gap reads as a gate to thread.
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = Vector3(g.half_width * 2.0, _BAR_THICKNESS, _BAR_THICKNESS)
		bar.mesh = bar_mesh
		bar.position = Vector3(0.0, _POST_HEIGHT, 0.0)
		node.add_child(bar)

		_gate_nodes.append(node)
		_apply_color(node, _PENDING_COLOR)


# Recolours one gate to reflect run progress. Index matches the course order.
func set_state(index: int, state: State) -> void:
	if index < 0 or index >= _gate_nodes.size():
		return
	var node: Node3D = _gate_nodes[index]
	if not is_instance_valid(node):
		return
	match state:
		State.ACTIVE:
			_apply_color(node, _ACTIVE_COLOR)
		State.CLEARED:
			_apply_color(node, _CLEARED_COLOR)
		_:
			_apply_color(node, _PENDING_COLOR)


func clear() -> void:
	for n: Node3D in _gate_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_gate_nodes.clear()


# ── Internals ─────────────────────────────────────────────────────────────────

func _apply_color(gate_node: Node3D, color: Color) -> void:
	var mat: StandardMaterial3D = _material(color)
	for child: Node in gate_node.get_children():
		var mi := child as MeshInstance3D
		if mi != null:
			mi.material_override = mat


func _post_mesh() -> CylinderMesh:
	if _post_mesh_cache.has("post"):
		return _post_mesh_cache["post"]
	var mesh := CylinderMesh.new()
	mesh.top_radius = _POST_RADIUS
	mesh.bottom_radius = _POST_RADIUS
	mesh.height = _POST_HEIGHT
	mesh.radial_segments = 10
	mesh.rings = 1
	_post_mesh_cache["post"] = mesh
	return mesh


func _material(color: Color) -> StandardMaterial3D:
	if _material_cache.has(color):
		return _material_cache[color]
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	_material_cache[color] = mat
	return mat
