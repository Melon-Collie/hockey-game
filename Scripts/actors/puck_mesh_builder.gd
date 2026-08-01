class_name PuckMeshBuilder
extends SkaterMeshBuilder

# Beveled low-poly puck replacing the smooth CylinderMesh
# (Assets/puck_mesh.tres, r 0.065 × h 0.035): same envelope, 12 flat-shaded
# sides, with a real puck's edge chamfer so the disc catches highlights on
# its rims instead of reading as a featureless dark ellipse from the game
# camera. Cosmetic only — puck physics is analytic
# (GameRules.PUCK_COLLISION_RADIUS); nothing reads this mesh.

const _PUCK_PROFILE: Array[Vector2] = [
	Vector2(0.0175, 0.058),   # top face rim
	Vector2(0.0114, 0.065),   # chamfer → full radius
	Vector2(-0.0114, 0.065),
	Vector2(-0.0175, 0.058),  # bottom chamfer
]


static func apply_puck(puck: Node3D) -> void:
	_swap(puck, "MeshInstance3D", "puck", _build_puck)


static func _build_puck() -> ArrayMesh:
	return _build_lathe(_PUCK_PROFILE, 12, 1.0, 1.0)
