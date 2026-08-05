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


# Argument count of set_net_geometry once the mouth-corner bends landed.
const NET_GEOMETRY_ARITY: int = 12


# Argument count of a ClassDB-bound method, or -1 when the class does not expose it.
static func _bound_arity(native: RefCounted, method: StringName) -> int:
	for m: Dictionary in native.get_method_list():
		if m.name == method:
			return (m.args as Array).size()
	return -1


static func make_configured() -> RefCounted:
	if not ClassDB.class_exists(&"NativePuckStep"):
		return null
	var native: RefCounted = ClassDB.instantiate(&"NativePuckStep")
	# Stale-binary guard. set_net_geometry's ARITY grew with the mouth-corner
	# bends, and a binary predating them still exports the class and the method —
	# so the configure call below would fail at runtime rather than degrade. Unlike
	# NativeTopHandIK's property write (which quietly no-ops), that breaks the puck
	# outright, so measure the arity directly and fall back to the GDScript step
	# when it is the old shape. NativeKernels' class census cannot see this: the
	# class is present, it is the shape that moved.
	#
	# Arity, not has_method: only ClassDB-bound methods are visible to GDScript, so
	# probing an internal C++ helper reports false on every binary ever built and
	# disables the kernel outright. Runs once per puck spawn, so the method-list
	# walk is not on any hot path.
	if _bound_arity(native, &"set_net_geometry") != NET_GEOMETRY_ARITY:
		push_warning("NativePuckStep predates the mouth-corner bends — "
				+ "using the GDScript puck step. Rebuild native/ (bash native/build.sh); "
				+ "if you just did, restart the editor so the reload takes.")
		return null
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
