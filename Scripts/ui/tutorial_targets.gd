class_name TutorialTargets
extends Node3D

# Bullseye targets drawn in the goal plane for the Shooting tutorial's "Pick Your
# Spot" and "Beat the Goalie" drills. Procedural (no scene edits), following the
# slapshot-reticle pattern in skater_hud_coordinator: filled ArrayMesh discs with
# an unshaded, alpha-blended, double-sided material. Concentric bands (amber /
# white / amber) read as a solid target you AIM AT and HIT — not a ring you have
# to thread the puck through. TutorialManager owns placement and the (generous)
# hit test; this node just renders each bullseye and pops it when it's cleared.

# Band radii, largest first. Each entry is (radius, color); drawn back-to-front
# with a tiny depth nudge toward the shooter so the smaller bands sort on top.
const _BANDS: Array = [
	[0.34, Color(1.0, 0.82, 0.18, 0.90)],   # outer amber
	[0.23, Color(0.97, 0.97, 0.97, 0.92)],  # white ring
	[0.11, Color(1.0, 0.82, 0.18, 0.96)],   # amber centre
]
const _SEGMENTS:    int   = 32
const _BAND_Z_STEP: float = 0.012  # per-band nudge toward the shooter, for sorting

var _material_cache: Dictionary = {}      # color -> StandardMaterial3D
var _mesh_cache:     Dictionary = {}      # radius -> ArrayMesh
var _targets:        Array[Node3D] = []   # one container per bullseye


# Replaces any existing targets with a fresh bullseye set at the given net-plane
# (x, y) positions. They sit on the goal plane at `goal_line_z`, nudged
# `front_offset` toward the shooter so they float just in front of the net mesh.
func show_targets(positions: Array[Vector2], goal_line_z: float, front_offset: float) -> void:
	clear()
	for p: Vector2 in positions:
		var bull := Node3D.new()
		bull.position = Vector3(p.x, p.y, goal_line_z + front_offset)
		add_child(bull)
		for band_i: int in _BANDS.size():
			var radius: float = _BANDS[band_i][0]
			var color: Color = _BANDS[band_i][1]
			var inst := MeshInstance3D.new()
			inst.mesh = _disc_mesh(radius)
			inst.material_override = _disc_material(color)
			# Nudge each inner band a hair toward the shooter (goal_line_z is on the
			# -Z side, so +Z is toward the shooter) so it draws over the one behind.
			inst.position = Vector3(0.0, 0.0, band_i * _BAND_Z_STEP)
			bull.add_child(inst)
		_targets.append(bull)


# Pop one bullseye once its target is cleared (positive feedback — it vanishes
# off the net). Index matches the position passed to show_targets.
func hide_target(index: int) -> void:
	if index >= 0 and index < _targets.size() and is_instance_valid(_targets[index]):
		_targets[index].visible = false


func clear() -> void:
	for t: Node3D in _targets:
		if is_instance_valid(t):
			t.queue_free()
	_targets.clear()


# Cached unshaded, alpha-blended, double-sided material per color.
func _disc_material(color: Color) -> StandardMaterial3D:
	if _material_cache.has(color):
		return _material_cache[color]
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	_material_cache[color] = mat
	return mat


# Cached filled disc (triangle fan) in the XY plane, facing the shooter down +Z.
func _disc_mesh(radius: float) -> ArrayMesh:
	if _mesh_cache.has(radius):
		return _mesh_cache[radius]
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	verts.append(Vector3.ZERO)  # centre
	normals.append(Vector3.BACK)
	for i: int in _SEGMENTS + 1:
		var a: float = TAU * i / _SEGMENTS
		verts.append(Vector3(cos(a) * radius, sin(a) * radius, 0.0))
		normals.append(Vector3.BACK)
	for i: int in _SEGMENTS:
		indices.append_array([0, i + 1, i + 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_cache[radius] = mesh
	return mesh
