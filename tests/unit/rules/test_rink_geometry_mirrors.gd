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


# ── Bench doors ──────────────────────────────────────────────────────────────
#
# The pre-game intro sends every skater out from its team's bench, and
# GameRules.BENCH_DOOR_* is where the domain thinks that bench is. The bench you
# can actually SEE is ArenaRinksideLayout's, built into the bowl — so this is the
# same shape as the rink mirrors above: an analytic constant against the thing
# the player looks at, with nothing else in the codebase to catch a drift.
#
# It fails softly, which is why it needs a guard. Move one number and the intro
# still runs, at the same speed, to the same faceoff dots; the skaters just walk
# out of the boards a couple of metres from the bench they are supposed to be
# leaving. Nothing errors and no other test notices.

func test_bench_door_center_mirrors_the_arena_bench() -> void:
	assert_almost_eq(GameRules.BENCH_DOOR_CENTER_Z,
			ArenaRinksideLayout.BENCH_CENTER_Z, 1e-6,
			"GameRules.BENCH_DOOR_CENTER_Z must equal ArenaRinksideLayout" +
			".BENCH_CENTER_Z — the intro's start points and the bench furniture " +
			"describe the same bench. Update both together.")


func test_the_fielded_roster_starts_on_the_bench_block() -> void:
	# The centre-of-the-bench constant agreeing is only half of it: the per-slot
	# stagger has to keep the skaters ON the block it centres. Checked through
	# PlayerRules.bench_start_position rather than the raw offsets, so the
	# side-mirroring is covered too.
	#
	# DEFAULT_TEAM_SIZE slots only — deliberately, and it is not a silent cap:
	# the 5v5 pair (BENCH_DOOR_SLOT_DZ ±4.8) lands 1.8 m off either end of a
	# 3.0 m half-bench, so at 5v5 the outer two skaters do NOT start at their
	# bench and one of them starts across centre ice. That is a real gap, not a
	# rounding one, and widening the constant is a feel decision rather than
	# something to assert into existence here.
	var half_len: float = ArenaRinksideLayout.BENCH_HALF_LEN
	for team_id: int in [0, 1]:
		for slot: int in GameRules.DEFAULT_TEAM_SIZE:
			var start: Vector3 = PlayerRules.bench_start_position(team_id, slot)
			var side: float = -1.0 if team_id == 1 else 1.0
			var along_bench: float = start.z - side * ArenaRinksideLayout.BENCH_CENTER_Z
			assert_lt(absf(along_bench), half_len,
					("team %d slot %d starts %.2f m from its bench centre, past the " +
							"%.2f m the block spans") % [team_id, slot, along_bench, half_len])


func test_bench_doors_open_onto_ice_not_into_the_kickplate() -> void:
	# The other half of the same comment block: BENCH_DOOR_X is pulled in from
	# the inner boards so a skater standing there is on the sheet. The body has
	# width, so the clearance has to cover its radius, not just its origin —
	# read off the shipped skater rather than restated here. (A bare Skater, not
	# the scene: its @onready node refs only resolve on _ready, and the tuning
	# vars this reads are plain class-level defaults — see CLAUDE.md on why they
	# are `var` and not `@export`, which is also why the rink mirrors above can
	# use get_property_default_value and this cannot.)
	var skater: Skater = autofree(Skater.new())
	var body_radius: float = skater.collision_radius()
	assert_gt(body_radius, 0.0, "expected a skater body radius to check against")
	assert_lt(GameRules.BENCH_DOOR_X + body_radius, GameRules.INNER_HALF_WIDTH,
			"a skater standing at BENCH_DOOR_X must clear the kickplate lip")


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
