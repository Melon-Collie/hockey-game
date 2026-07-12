extends GutTest

# Guards the rink-geometry mirrors: HockeyRink's export defaults and lip
# constant MUST stay in sync with the GameRules boundary constants, because
# everything analytic — the blade clamp, AI trajectory reflection, the client
# puck extrapolation board check, and the puck-OOB whistle — reasons against
# GameRules.INNER_*, while the puck physically collides with geometry built
# from HockeyRink's values. A silent drift would re-open the gap where the
# physics wall and the modelled wall disagree (puck sinking into the kickplate
# visual, OOB false reads). RinkArena.tscn instantiates the rink with NO
# geometry overrides, so the script defaults ARE the live values; if a scene
# override is ever added, these mirrors (and this test) need rethinking.
#
# wall_height needs no guard — it is single-sourced (its export default reads
# GameRules.BOARD_TOP_HEIGHT), same reasoning as ICE_FRICTION in
# test_physics_material_mirrors.gd.

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
