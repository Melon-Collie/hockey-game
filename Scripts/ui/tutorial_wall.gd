class_name TutorialWall
extends Node3D

# Low board laid across a drill lane so a flat shot or pass can't get through —
# the obstacle that gives LOW loft (the saucer) a reason to exist. Procedural
# (no scene edits), following the TutorialTargets pattern.
#
# The board is a MESH plus an analytic obstacle registered on the puck, not a
# collision body: the puck is integrated analytically and never reaches the
# engine solver, so a StaticBody3D across the lane would stop nothing (and would
# put a body back into the physics pipeline that nothing can query — see
# tests/unit/game/test_actors_stay_out_of_physics.gd). PuckObstacleCollision owns
# the rebound; this node owns only where the box is and when it exists.
#
# Skaters pass through it, deliberately: a knee-high board is skate-over-able and
# the drills only need the puck stopped.
#
# Used by the Shooting module's saucer wave and the Passing module's saucer
# drill. show_wall() replaces any existing wall; clear() removes it.

const _WALL_COLOR := Color(1.0, 0.82, 0.18, 0.85)  # amber, matching the targets

var _wall: MeshInstance3D = null
var _obstacle: PuckObstacleCollision.Obstacle = null
var _puck: Puck = null


# Places a box obstacle centred at `center` with dimensions `size`
# (x = width across the lane, y = height off the ice, z = thickness), and
# registers it on `puck` so the analytic step rebounds off it. The center's y is
# derived from the size so callers pass an on-ice position.
func show_wall(center: Vector3, size: Vector3, puck: Puck) -> void:
	clear()
	_puck = puck
	var origin := Vector3(center.x, size.y * 0.5, center.z)

	_wall = MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	_wall.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = _WALL_COLOR
	_wall.material_override = mat
	_wall.position = origin
	add_child(_wall)

	# A wall without a puck to register on is a wall that stops nothing — the
	# failure this node was rebuilt to end. Say so rather than drawing an
	# obstacle-free board a drill then reads as passable.
	if _puck == null or not is_instance_valid(_puck):
		push_error("TutorialWall: no puck to register the obstacle on — the board will not stop the puck")
		return
	_obstacle = PuckObstacleCollision.Obstacle.new()
	# The mesh is placed in local space but the obstacle is read in world space by
	# the puck step, so the box carries this node's transform too. The drills
	# parent the wall at the origin; going through global_transform means a wall
	# staged under a moved parent still stops the puck where it is drawn.
	_obstacle.transform = global_transform * Transform3D(Basis(), origin)
	_obstacle.half_extents = size * 0.5
	_puck.add_obstacle(_obstacle)


func clear() -> void:
	if _wall != null and is_instance_valid(_wall):
		_wall.queue_free()
	_wall = null
	if _obstacle != null and _puck != null and is_instance_valid(_puck):
		_puck.remove_obstacle(_obstacle)
	_obstacle = null
	_puck = null


# The obstacle must not outlive the node — a drill that frees its wall without
# calling clear() would otherwise leave a box the puck still bounces off.
func _exit_tree() -> void:
	clear()
