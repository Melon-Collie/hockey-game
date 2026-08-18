extends GutTest

# Guards the rink-geometry mirrors: HockeyRink's export defaults and lip constant
# MUST stay in sync with the GameRules boundary constants. Everything analytic —
# the blade clamp, AI trajectory reflection, the client puck extrapolation board
# check, the puck-OOB whistle, and the skater's own rink clamp — reasons against
# GameRules.INNER_*, while HockeyRink's values are what the player actually SEES.
#
# That makes this the only coupling left between the two, and the reason it still
# matters: the boards carry no collider any more, so a drift no longer shows up as
# a physics bug that someone trips over. It shows up as a puck caroming off empty
# air a centimetre from the kickplate, or sinking into it — with nothing else in
# the codebase to catch it. RinkArena.tscn instantiates the rink with NO geometry
# overrides, so the script defaults ARE the live values; if a scene override is
# ever added, these mirrors (and this test) need rethinking.
#
# wall_height needs no guard — it is single-sourced (its export default reads
# GameRules.BOARD_TOP_HEIGHT).

const _RINK: GDScript = preload("res://Scripts/actors/hockey_rink.gd")


func test_rink_dimension_defaults_mirror_game_rules() -> void:
	assert_almost_eq(float(_RINK.get_property_default_value("rink_width")),
			GameRules.RINK_HALF_WIDTH * 2.0, 1e-6,
			"HockeyRink.rink_width default must equal 2 × GameRules.RINK_HALF_WIDTH")
	assert_almost_eq(float(_RINK.get_property_default_value("rink_length")),
			GameRules.RINK_HALF_LENGTH * 2.0, 1e-6,
			"HockeyRink.rink_length default must equal 2 × GameRules.RINK_HALF_LENGTH")
	assert_almost_eq(float(_RINK.get_property_default_value("corner_radius")),
			GameRules.CORNER_RADIUS, 1e-6,
			"HockeyRink.corner_radius default must equal GameRules.CORNER_RADIUS")
	assert_almost_eq(float(_RINK.get_property_default_value("wall_thickness")),
			GameRules.WALL_THICKNESS, 1e-6,
			"HockeyRink.wall_thickness default must equal GameRules.WALL_THICKNESS")


func test_kickplate_protrusion_matches_inward_lip() -> void:
	assert_almost_eq(HockeyRink.KICKPLATE_PROTRUSION, GameRules.KICKPLATE_INWARD_LIP, 1e-6,
			"HockeyRink.KICKPLATE_PROTRUSION must equal GameRules.KICKPLATE_INWARD_LIP — " +
			"the blade clamp and puck-OOB boundary assume the visible lip sits exactly " +
			"this far inside the boards' inner face. Update both together.")


func test_perimeter_collision_inner_face_is_the_inner_boundary() -> void:
	# _rebuild builds the perimeter collision with inner_offset = kick_half_thick
	# (= wall_thickness/2 + KICKPLATE_PROTRUSION) from the centerline, so the
	# collision's inner face is the kickplate lip — the same surface
	# GameRules.INNER_* describes. Locks the derivation on all three extents.
	var half_w: float = float(_RINK.get_property_default_value("rink_width")) / 2.0
	var half_l: float = float(_RINK.get_property_default_value("rink_length")) / 2.0
	var corner_r: float = float(_RINK.get_property_default_value("corner_radius"))
	var kick_half_thick: float = float(_RINK.get_property_default_value("wall_thickness")) / 2.0 \
			+ HockeyRink.KICKPLATE_PROTRUSION
	assert_almost_eq(half_w - kick_half_thick, GameRules.INNER_HALF_WIDTH, 1e-6,
			"collision inner face (width) must sit at GameRules.INNER_HALF_WIDTH")
	assert_almost_eq(half_l - kick_half_thick, GameRules.INNER_HALF_LENGTH, 1e-6,
			"collision inner face (length) must sit at GameRules.INNER_HALF_LENGTH")
	assert_almost_eq(corner_r - kick_half_thick, GameRules.INNER_CORNER_RADIUS, 1e-6,
			"collision corner arc must sit at GameRules.INNER_CORNER_RADIUS")


# Every faceoff marking has a twin at −z, which is what makes the painted sheet
# symmetric about centre ice. The albedo image therefore looks the same whichever
# way its Z axis runs, so nothing in the paint itself can catch a frame that is
# upside down in Z — the first marking placed at one end only inherits the error
# silently. This holds the symmetry the rest of the ice pipeline (IceScratchMap,
# the in-ice ad slots) is checked against.
func test_faceoff_markings_are_mirrored_about_centre_ice() -> void:
	for dots: Array[Vector2] in [GameRules.END_ZONE_FACEOFF_DOTS,
			GameRules.NEUTRAL_ZONE_FACEOFF_DOTS]:
		for dot: Vector2 in dots:
			assert_true(dots.has(Vector2(dot.x, -dot.y)),
					"the dot at %s has a twin at the other end of the sheet" % dot)
