extends GutTest

# TeamColorRegistry.get_ui_colors — the canonical 3-color UI palette rule.
# Loads the bundled res://data/team_colors.json on first access.
#
#   Home (team_id 0): primary body, secondary stripe, light lettering.
#   Away (team_id 1): light body, primary stripe, primary lettering.

const _PAPAYA: int = 0  # primary #F46B2A, secondary #2A9472, light #FBF3EC


func test_home_uses_primary_body_secondary_stripe() -> void:
	var ui: Dictionary = TeamColorRegistry.get_ui_colors(_PAPAYA, 0)
	var preset: Dictionary = TeamColorRegistry.get_preset(_PAPAYA)
	assert_eq(ui.base, preset.primary, "home body is primary")
	assert_eq(ui.stripe, preset.secondary, "home stripe is secondary")
	assert_eq(ui.text, preset.light, "home lettering is light")


func test_away_uses_light_body_primary_stripe() -> void:
	var ui: Dictionary = TeamColorRegistry.get_ui_colors(_PAPAYA, 1)
	var preset: Dictionary = TeamColorRegistry.get_preset(_PAPAYA)
	assert_eq(ui.base, preset.light, "away body is light")
	assert_eq(ui.stripe, preset.primary, "away stripe is primary")
	assert_eq(ui.text, preset.primary, "away lettering is primary")


func test_get_colors_exposes_ui_keys_matching_get_ui_colors() -> void:
	for team_id: int in [0, 1]:
		var colors: Dictionary = TeamColorRegistry.get_colors(_PAPAYA, team_id)
		var ui: Dictionary = TeamColorRegistry.get_ui_colors(_PAPAYA, team_id)
		assert_eq(colors.ui_base, ui.base)
		assert_eq(colors.ui_stripe, ui.stripe)
		assert_eq(colors.ui_text, ui.text)


func test_light_mirrors_away_jersey_base() -> void:
	# light is authored to match the away kit's jersey base so the UI away
	# card matches the 3D away sweater. Verify across all teams.
	for slot: int in TeamColorRegistry.get_all_slots():
		var preset: Dictionary = TeamColorRegistry.get_preset(slot)
		assert_true(preset.has("light"), "slot %d carries a light color" % slot)
		assert_eq(preset.light, preset.away.jersey.base,
			"slot %d light matches away jersey base" % slot)


func test_unknown_slot_still_returns_valid_ui_colors() -> void:
	# Out-of-range slot falls back to default preset rather than crashing.
	var ui: Dictionary = TeamColorRegistry.get_ui_colors(9999, 0)
	assert_true(ui.has("base") and ui.has("stripe") and ui.has("text"))


# ── Score-surface stripe pair (scorebug + period summary) ────────────────────
# Each team always wears its own primary, independent of its opponent's colors.

func test_score_stripe_pair_home_is_primary() -> void:
	var pair: Dictionary = TeamColorRegistry.get_score_stripe_pair(_PAPAYA, 1)
	assert_eq(pair.home, TeamColorRegistry.get_preset(_PAPAYA).primary,
			"home stripe is its primary")

func test_score_stripe_pair_away_is_primary() -> void:
	var pair: Dictionary = TeamColorRegistry.get_score_stripe_pair(_PAPAYA, 1)
	assert_eq(pair.away, TeamColorRegistry.get_preset(1).primary,
			"away stripe is its primary")


# A glove design's second color has to differ from the glove body, and MOST
# presets dress their gloves in the secondary — so reaching for the secondary
# again would paint those teams a monochrome glove. get_colors derives
# glove_accent as whichever team color the body is not; every shipped preset
# has to come out with two distinguishable glove colors or the catalogue's
# contrast designs collapse on that team.
func test_every_preset_has_a_contrasting_glove_accent() -> void:
	for slot: int in TeamColorRegistry.get_all_slots():
		for team_id: int in 2:
			var colors: Dictionary = TeamColorRegistry.get_colors(slot, team_id)
			var body: Color = colors.gloves
			var accent: Color = colors.glove_accent
			assert_false(body.is_equal_approx(accent),
					"%s side %d: glove body and accent must differ"
					% [TeamColorRegistry.get_preset_name(slot), team_id])
			# And it is one of the team's OWN two colors, not an invention.
			assert_true(accent.is_equal_approx(colors.primary)
					or accent.is_equal_approx(colors.secondary),
					"%s side %d: the glove accent is a team color"
					% [TeamColorRegistry.get_preset_name(slot), team_id])
