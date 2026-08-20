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


# ── Rinkside furniture and the doors that serve it ───────────────────────────
#
# Three things are built off the bench span — the furniture in the bowl, the
# gate the boards leave for it, and the intro's start points — and they agree
# because all three read GameRules.BENCH_*, so there is no mirror left to guard
# there (same as wall_height above). What still needs holding is everything
# DERIVED from that span, because each derivation fails silently:
#
#   · A gate half a metre off its furniture is still a gate. The boards keep
#     their ad band clear of it, the glass still opens, and it just leads
#     nowhere — which is what the bench door did, sitting 0.45 m of its own
#     width past the end of the bench.
#   · A start point off the end of the bench is still a legal spawn. The intro
#     runs at the same speed to the same dots; two of the five just step onto
#     the ice beside a bench that isn't theirs.

func test_every_gate_opens_onto_the_furniture_it_serves() -> void:
	# A door is for something. The penalty door has always been derived from its
	# box; the bench door was a literal, and drifted off the end of the bench.
	# Flush against that end is the intended result, not a coincidence, so both
	# halves are checked: the opening lies wholly on the furniture, and the edge
	# that is supposed to touch does touch. The bench's door is at the INNER end
	# (nearest centre ice) so a team steps on beside its own bench; the box's is
	# at the OUTER end so a released player leaves behind the play.
	var rink: HockeyRink = autofree(HockeyRink.new())
	var half_w: float = float(_RINK.get_property_default_value("rink_width")) / 2.0
	var half_gate: float = HockeyRink.GATE_WIDTH * 0.5
	var spans: Dictionary = {
		# side sign → [furniture centre, half-length, +1 if the door is flush
		# with the OUTER end, -1 if with the inner]
		1.0: [ArenaRinksideLayout.BENCH_CENTER_Z,
				ArenaRinksideLayout.BENCH_HALF_LEN, -1.0],
		-1.0: [ArenaRinksideLayout.PENALTY_BOX_CENTER_Z,
				ArenaRinksideLayout.PENALTY_BOX_HALF_LEN, 1.0],
	}
	var checked: int = 0
	for gate: Vector2 in rink._gate_targets():
		if not is_equal_approx(absf(gate.x), half_w):
			continue  # an end-board resurfacer door serves no rinkside furniture
		var span: Array = spans[signf(gate.x)]
		var centre: float = absf(float(span[0]))
		var half_len: float = float(span[1])
		var flush_end: float = centre + float(span[2]) * half_len
		var near: float = absf(gate.y) - half_gate
		var far: float = absf(gate.y) + half_gate
		assert_gt(near, centre - half_len - 1e-6,
				"gate at %v opens past the near end of its furniture" % gate)
		assert_lt(far, centre + half_len + 1e-6,
				"gate at %v opens past the far end of its furniture" % gate)
		assert_almost_eq(near if float(span[2]) < 0.0 else far, flush_end, 1e-6,
				("gate at %v is not flush with the end of its furniture — a door " +
						"floating mid-bench is a door nobody would walk to") % gate)
		checked += 1
	assert_eq(checked, 4, "expected two bench doors and two penalty doors")


func test_the_whole_roster_starts_on_the_bench() -> void:
	# Every slot, not just the 3v3 line: the two the 5v5 roster adds are exactly
	# the ones that used to overrun. Driven through
	# PlayerRules.bench_start_position rather than the raw offsets, so the
	# side-mirroring is covered too, and sized against the body rather than the
	# origin so nobody hangs half off the end.
	var skater: Skater = autofree(Skater.new())
	var reach: float = ArenaRinksideLayout.BENCH_HALF_LEN - skater.collision_radius()
	assert_gt(reach, 0.0, "premise: a body fits on the bench at all")
	for team_id: int in [0, 1]:
		for slot: int in GameRules.BENCH_START_SLOT_DZ.size():
			var start: Vector3 = PlayerRules.bench_start_position(team_id, slot)
			var side: float = -1.0 if team_id == 1 else 1.0
			var along_bench: float = start.z - side * ArenaRinksideLayout.BENCH_CENTER_Z
			assert_lt(absf(along_bench), reach,
					("team %d slot %d starts %.2f m from its bench centre, past the " +
							"%.2f m a body can stand within") % [team_id, slot,
							along_bench, reach])


func test_bench_starts_are_on_the_ice_not_in_the_kickplate() -> void:
	# BENCH_START_X is pulled in from the inner boards so a skater standing there
	# is on the sheet. The body has width, so the clearance has to cover its
	# radius, not just its origin — read off the shipped skater rather than
	# restated here. (A bare Skater, not the scene: its @onready node refs only
	# resolve on _ready. It is read live rather than through
	# get_property_default_value, which the rink mirrors above can use because
	# those are @export and this is a plain `var` — see CLAUDE.md on why the
	# skater's tunables carry no inspector rows.)
	var skater: Skater = autofree(Skater.new())
	var body_radius: float = skater.collision_radius()
	assert_gt(body_radius, 0.0, "expected a skater body radius to check against")
	assert_lt(GameRules.BENCH_START_X + body_radius, GameRules.INNER_HALF_WIDTH,
			"a skater standing at BENCH_START_X must clear the kickplate lip")


func test_the_bench_slots_do_not_overlap_each_other() -> void:
	# Fitting on the bench is not enough on its own — five bodies inside a 6 m
	# block have to not intersect, which is the constraint that decides how tight
	# the stagger can get.
	var skater: Skater = autofree(Skater.new())
	var offsets: Array[float] = GameRules.BENCH_START_SLOT_DZ.duplicate()
	offsets.sort()
	for i: int in range(1, offsets.size()):
		assert_gt(offsets[i] - offsets[i - 1], skater.collision_radius() * 2.0,
				"bench slots at %.2f and %.2f overlap" % [offsets[i - 1], offsets[i]])


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
