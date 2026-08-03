extends GutTest

# Pins the GameRules constants that used to mirror a live PhysicsMaterial. A
# silent drift here is what caused the historical 10× ice-friction bug (model 0.1
# vs live 0.01).
#
# READ THIS BEFORE TRUSTING IT: the simulation half of the mirror is gone. Nothing
# collides through the physics server any more, so boards.tres is no longer read
# by anything at runtime — the analytic carom applies PUCK_BOARD_BOUNCE and
# PUCK_BOARD_FRICTION directly, and they are now the only authority. What is left
# below pins a resource against a constant that no longer derives from it, which
# is worth exactly as much as keeping the .tres file is: the pair can still be
# read as the documented rim-feel numbers, but a drift no longer breaks the game.
# Retiring the resources and this file together is the honest end state, once
# RinkArena.tscn stops referencing them.


const _BOARDS_MAT: PhysicsMaterial = preload("res://Physics/boards.tres")


func test_board_bounce_matches_boards_material() -> void:
	assert_not_null(_BOARDS_MAT, "Physics/boards.tres must exist and load as a PhysicsMaterial")
	# Resource stores bounce as a 32-bit float, the const is a 64-bit double, so
	# compare with a tolerance well below any meaningful tuning step.
	assert_almost_eq(_BOARDS_MAT.bounce, GameRules.PUCK_BOARD_BOUNCE, 1e-4,
			"boards.tres bounce must equal GameRules.PUCK_BOARD_BOUNCE — the AI/client " +
			"prediction models board rebounds from this constant. Update both together.")


func test_board_friction_matches_boards_material() -> void:
	assert_almost_eq(_BOARDS_MAT.friction, GameRules.PUCK_BOARD_FRICTION, 1e-4,
			"boards.tres friction must equal GameRules.PUCK_BOARD_FRICTION — the analytic puck " +
			"sim bleeds tangential rim speed from this constant. Update both together.")


func test_puck_ice_decel_derives_from_ice_friction_and_gravity() -> void:
	# PUCK_ICE_DECEL_M_S2 is the Coulomb decel a = μ·g every path applies — host
	# drive, client prediction, and the AI model alike. Locks the derivation so a
	# stray literal can't replace the computed value. This one never had a
	# simulation half to drift from; ICE_FRICTION has always been the source.
	assert_almost_eq(GameRules.PUCK_ICE_DECEL_M_S2,
			GameRules.ICE_FRICTION * GameRules.GRAVITY_M_S2, 1e-6,
			"PUCK_ICE_DECEL_M_S2 must stay = ICE_FRICTION × GRAVITY_M_S2")


func test_gravity_matches_godot_default() -> void:
	# GRAVITY_M_S2 is pinned to Godot's un-overridden physics/3d/default_gravity
	# (9.8, not textbook 9.81). Overriding the project setting without moving the
	# constant would leave two different gravities in the build.
	var default_gravity: float = ProjectSettings.get_setting(
			"physics/3d/default_gravity", 9.8)
	assert_eq(GameRules.GRAVITY_M_S2, default_gravity,
			"GameRules.GRAVITY_M_S2 must match physics/3d/default_gravity")
