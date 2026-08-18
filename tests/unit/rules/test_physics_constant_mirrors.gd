extends GutTest

# Pins the GameRules physics constants that are derived from, or shared with,
# something outside themselves. A silent drift here is what caused the historical
# 10× ice-friction bug (model 0.1 vs live 0.01).
#
# The board pair (PUCK_BOARD_BOUNCE / PUCK_BOARD_FRICTION) used to be guarded
# here against Physics/boards.tres. That resource is gone: the boards carry no
# collider, so nothing consumed the material and the constants are now the sole
# authority — there is no second value left to drift from. What remains below is
# the derivation and the one project setting the constants must agree with.


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


func test_puck_rest_height_is_the_collision_half_height() -> void:
	# PUCK_START_POS.y is stated as a literal but is not independent: it is the
	# height at which the disc's bottom face sits on the ice plane, which is by
	# definition the collision half-height. Its comment says "keep in sync with
	# Puck.gd ice_height and the Puck.tscn mesh/shape height" — the scene half of
	# that is not reachable from a headless test, but the half that lives in
	# GameRules is, and a stray edit to either constant alone is what would put
	# the puck through the ice or hovering above it at every faceoff.
	assert_almost_eq(GameRules.PUCK_START_POS.y, GameRules.PUCK_COLLISION_HALF_HEIGHT, 1e-6,
			"PUCK_START_POS.y must equal PUCK_COLLISION_HALF_HEIGHT so the disc rests " +
			"with its bottom face on y = 0")
