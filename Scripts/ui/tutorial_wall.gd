class_name TutorialWall
extends Node3D

# Low board laid across a drill lane so a flat shot or pass can't get through —
# the obstacle that gives LOW loft (the saucer) a reason to exist. Procedural
# (no scene edits), following the TutorialTargets pattern.
#
# THE WALL DOES NOT CURRENTLY STOP ANYTHING. Its StaticBody3D is inert: the puck
# is analytically integrated and has no physics body, and the only obstacles the
# analytic sim knows about are the rink boundary, the goal frame, and the goalie.
# A flat shot passes straight through, so the drills below read as passable when
# they are meant to demand a saucer. Fixing it means teaching the analytic puck
# step about drill obstacles — tracked as a GitHub issue.
#
# Used by the Shooting module's saucer wave and the Passing module's saucer
# drill. show_wall() replaces any existing wall; clear() removes it.

const _WALL_COLOR := Color(1.0, 0.82, 0.18, 0.85)  # amber, matching the targets

var _wall: StaticBody3D = null


# Places a box obstacle centred at `center` with dimensions `size`
# (x = width across the lane, y = height off the ice, z = thickness).
# The center's y is derived from the size so callers pass an on-ice position.
func show_wall(center: Vector3, size: Vector3) -> void:
	clear()
	_wall = StaticBody3D.new()
	_wall.collision_layer = Constants.LAYER_WALLS
	_wall.collision_mask = 0
	_wall.position = Vector3(center.x, size.y * 0.5, center.z)
	add_child(_wall)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	_wall.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = _WALL_COLOR
	mesh.material_override = mat
	_wall.add_child(mesh)


func clear() -> void:
	if _wall != null and is_instance_valid(_wall):
		_wall.queue_free()
	_wall = null
