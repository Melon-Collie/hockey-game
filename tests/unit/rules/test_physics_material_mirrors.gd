extends GutTest

# Guards the model↔simulation mirrors: GameRules constants that MUST equal a live
# physics-material value the host simulates. A silent drift here is exactly what
# caused the historical 10× ice-friction bug (model 0.1 vs live 0.01), so these
# assertions fail CI the moment the pair diverges.
#
# Note the asymmetry:
#   - ICE_FRICTION is now SINGLE-SOURCED (HockeyRink builds the ice material from
#     the constant), so it structurally cannot drift and needs no runtime guard —
#     the derivation test below just documents the relationship.
#   - PUCK_BOARD_BOUNCE mirrors a STATIC resource (boards.tres) a const can't
#     reach, so it's the one pair a test has to enforce.


func test_board_bounce_matches_boards_material() -> void:
	var mat: PhysicsMaterial = load("res://Physics/boards.tres")
	assert_not_null(mat, "Physics/boards.tres must exist and load as a PhysicsMaterial")
	# Resource stores bounce as a 32-bit float, the const is a 64-bit double, so
	# compare with a tolerance well below any meaningful tuning step.
	assert_almost_eq(mat.bounce, GameRules.PUCK_BOARD_BOUNCE, 1e-4,
			"boards.tres bounce must equal GameRules.PUCK_BOARD_BOUNCE — the AI/client " +
			"prediction models board rebounds from this constant. Update both together.")


func test_puck_ice_decel_derives_from_ice_friction_and_gravity() -> void:
	# PUCK_ICE_DECEL_M_S2 is the Coulomb decel a = μ·g the prediction paths apply.
	# Locks the derivation so a stray literal can't replace the computed value.
	assert_almost_eq(GameRules.PUCK_ICE_DECEL_M_S2,
			GameRules.ICE_FRICTION * GameRules.GRAVITY_M_S2, 1e-6,
			"PUCK_ICE_DECEL_M_S2 must stay = ICE_FRICTION × GRAVITY_M_S2")


func test_gravity_matches_godot_default() -> void:
	# The model's gravity must equal what Jolt actually applies (Godot's
	# un-overridden physics/3d/default_gravity = 9.8), not textbook 9.81, or the
	# modelled ice decel drifts from the host's real contact-solver decel.
	var default_gravity: float = ProjectSettings.get_setting(
			"physics/3d/default_gravity", 9.8)
	assert_eq(GameRules.GRAVITY_M_S2, default_gravity,
			"GameRules.GRAVITY_M_S2 must match physics/3d/default_gravity")
