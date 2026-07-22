extends GutTest

# BuildArchetypeRules — the matchup screen's scouting-label decision table:
# height band × frame band → one of nine body archetype keys, plus the
# optional signature-gear tell. Fixtures build real PlayerAttributes so the
# bands are exercised through the same coercion the game uses.

const A := preload("res://Scripts/domain/state/player_attributes.gd")


# A build at a height with its frame pinned to the band's exact lean (0),
# neutral (0.5), or heavy (1) pounds — the frame_t values the thirds split.
func _build(inches: int, frame: float) -> PlayerAttributes:
	var lbs: int = A.weight_neutral(inches)
	if frame <= 0.0:
		lbs = A.weight_min(inches)
	elif frame >= 1.0:
		lbs = A.weight_max(inches)
	return A.from_levels(inches, lbs)


# ── Body grid ─────────────────────────────────────────────────────────────────

func test_body_grid_all_nine_cells() -> void:
	assert_eq(BuildArchetypeRules.body_key(_build(68, 0.0)), "ARCH_WATERBUG")
	assert_eq(BuildArchetypeRules.body_key(_build(68, 0.5)), "ARCH_SPARK_PLUG")
	assert_eq(BuildArchetypeRules.body_key(_build(68, 1.0)), "ARCH_FIRE_HYDRANT")
	assert_eq(BuildArchetypeRules.body_key(_build(73, 0.0)), "ARCH_GREYHOUND")
	assert_eq(BuildArchetypeRules.body_key(_build(73, 0.5)), "ARCH_TWO_WAY")
	assert_eq(BuildArchetypeRules.body_key(_build(73, 1.0)), "ARCH_BRUISER")
	assert_eq(BuildArchetypeRules.body_key(_build(79, 0.0)), "ARCH_RANGY")
	assert_eq(BuildArchetypeRules.body_key(_build(79, 0.5)), "ARCH_TOWER")
	assert_eq(BuildArchetypeRules.body_key(_build(79, 1.0)), "ARCH_TANK")


func test_neutral_reference_build_is_two_way() -> void:
	assert_eq(BuildArchetypeRules.body_key(A.all_average()), "ARCH_TWO_WAY")


func test_height_band_edges() -> void:
	# 5'10" is the last short inch; 5'11" reads mid. 6'4" is the first tall.
	assert_eq(BuildArchetypeRules.body_key(_build(70, 0.5)), "ARCH_SPARK_PLUG")
	assert_eq(BuildArchetypeRules.body_key(_build(71, 0.5)), "ARCH_TWO_WAY")
	assert_eq(BuildArchetypeRules.body_key(_build(75, 0.5)), "ARCH_TWO_WAY")
	assert_eq(BuildArchetypeRules.body_key(_build(76, 0.5)), "ARCH_TOWER")


func test_frame_band_edges() -> void:
	# The frame thirds split on frame_t: band-edge pounds are exactly 0 and 1,
	# so one pound inside the band still reads lean/heavy at every height
	# (the 6'1" band is ~38 lbs wide; a pound is ~0.03 of it).
	var lean_edge := A.from_levels(73, A.weight_min(73) + 1)
	assert_eq(BuildArchetypeRules.body_key(lean_edge), "ARCH_GREYHOUND")
	var heavy_edge := A.from_levels(73, A.weight_max(73) - 1)
	assert_eq(BuildArchetypeRules.body_key(heavy_edge), "ARCH_BRUISER")


# ── Gear tells ────────────────────────────────────────────────────────────────

func test_balanced_gear_has_no_tell() -> void:
	assert_eq(BuildArchetypeRules.gear_tell_key(A.all_average()), "")


func test_single_leaned_slot_stays_quiet() -> void:
	var open_only := A.from_levels(73, 0, A.GEAR_BALANCED, A.CURVE_OPEN)
	assert_eq(BuildArchetypeRules.gear_tell_key(open_only), "")
	var stiff_only := A.from_levels(73, 0,
			A.GEAR_BALANCED, A.GEAR_BALANCED, A.FLEX_HIGH)
	assert_eq(BuildArchetypeRules.gear_tell_key(stiff_only), "")


func test_quick_release_loadout() -> void:
	var b := A.from_levels(73, 0, A.GEAR_BALANCED, A.CURVE_OPEN, A.FLEX_LOW)
	assert_eq(BuildArchetypeRules.gear_tell_key(b), "ARCH_TELL_QUICK_RELEASE")


func test_howitzer_loadout() -> void:
	var b := A.from_levels(73, 0,
			A.GEAR_BALANCED, A.GEAR_BALANCED, A.FLEX_HIGH, A.LENGTH_LONG)
	assert_eq(BuildArchetypeRules.gear_tell_key(b), "ARCH_TELL_HOWITZER")


func test_shifty_loadout() -> void:
	var b := A.from_levels(73, 0,
			A.PROFILE_AGILITY, A.GEAR_BALANCED, A.GEAR_BALANCED, A.LENGTH_SHORT)
	assert_eq(BuildArchetypeRules.gear_tell_key(b), "ARCH_TELL_SHIFTY")


func test_stacked_signatures_lead_with_the_shot_identity() -> void:
	# Quick-release pair + shifty pair on one build: first match wins, and the
	# shot identity outranks the skating one.
	var b := A.from_levels(73, 0,
			A.PROFILE_AGILITY, A.CURVE_OPEN, A.FLEX_LOW, A.LENGTH_SHORT)
	assert_eq(BuildArchetypeRules.gear_tell_key(b), "ARCH_TELL_QUICK_RELEASE")
