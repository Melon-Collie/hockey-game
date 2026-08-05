class_name NativePuckStepFactory

# Builds a NativePuckStep (C++ GDExtension, native/src/) configured from the
# live GDScript symbols — GameRules geometry/material constants, the
# PuckGeometryCollision restitutions, and the PuckAuthorityRules sub-step law.
# One factory so the host drive (Puck) and the client prediction
# (PuckController) are configured identically — the determinism migration
# requires the two to run the same step by construction.
#
# Returns null when the extension isn't loaded; callers fall back to the
# GDScript step.


static func make_configured() -> RefCounted:
	if not ClassDB.class_exists(&"NativePuckStep"):
		return null
	var native: RefCounted = ClassDB.instantiate(&"NativePuckStep")
	native.set_rink_geometry(
			GameRules.INNER_HALF_WIDTH, GameRules.INNER_HALF_LENGTH,
			GameRules.INNER_CORNER_RADIUS,
			GameRules.CORNER_CENTER_X, GameRules.CORNER_CENTER_Z)
	native.set_puck_params(
			GameRules.PUCK_BOARD_BOUNCE, GameRules.PUCK_BOARD_FRICTION,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.GRAVITY_M_S2,
			AITrajectory.PUCK_REST_HEIGHT_M)
	native.set_net_geometry(
			GameRules.GOAL_LINE_Z, GameRules.NET_HALF_WIDTH,
			GameRules.NET_POST_RADIUS, GameRules.NET_DEPTH,
			GameRules.NET_BACK_HALF_WIDTH, GameRules.NET_HEIGHT,
			GameRules.NET_CROWN_HALF_WIDTH, GameRules.NET_MOUTH_CORNER_RADIUS,
			GameRules.NET_TOP_DEPTH,
			GameRules.PUCK_COLLISION_HALF_HEIGHT,
			PuckGeometryCollision.POST_RESTITUTION,
			PuckGeometryCollision.NET_RESTITUTION)
	native.set_substep_params(
			PuckAuthorityRules.FRAME_SUBSTEP_RANGE_Z,
			PuckAuthorityRules.FRAME_SUBSTEP_M,
			PuckAuthorityRules.MAX_FRAME_SUBSTEPS)
	return native
