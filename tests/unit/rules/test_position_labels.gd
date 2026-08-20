extends GutTest

# PositionLabels is the single home for the badge and column-header keys the
# box score, the matchup card and the lobby slot grid all draw. All three used
# to carry their own copy of the tables with a comment pointing at the others,
# which is the shape of a rule nothing checks. These are those checks.

const _CATALOGUE: String = "res://locale/translations.csv"
const _COLUMNS: int = 3


func test_away_mirrors_the_wings() -> void:
	# Away attacks the other way, so its slot 1 sits in the column home's slot 2
	# does. Labelling both "L" would put two left wings in one column.
	for is_5v5: bool in [false, true]:
		assert_eq(PositionLabels.badge_key(1, 1, is_5v5),
			PositionLabels.badge_key(0, 2, is_5v5),
			"away slot 1 wears home slot 2's badge (5v5: %s)" % is_5v5)
		assert_eq(PositionLabels.badge_key(1, 2, is_5v5),
			PositionLabels.badge_key(0, 1, is_5v5),
			"away slot 2 wears home slot 1's badge (5v5: %s)" % is_5v5)
		assert_eq(PositionLabels.badge_key(1, 3, is_5v5),
			PositionLabels.badge_key(0, 4, is_5v5),
			"the defense pair mirrors too (5v5: %s)" % is_5v5)


func test_centre_never_mirrors() -> void:
	for is_5v5: bool in [false, true]:
		assert_eq(PositionLabels.badge_key(0, 0, is_5v5),
			PositionLabels.badge_key(1, 0, is_5v5),
			"the centre is the centre on both benches (5v5: %s)" % is_5v5)


func test_only_the_wingers_change_between_modes() -> void:
	# 3v3 is position-free rovers, so slots 1/2 keep the plain letters; 5v5 has
	# a real forward/defense split and spells the wingers out beside LD/RD.
	for team_id: int in 2:
		for slot: int in [0, 3, 4]:
			assert_eq(PositionLabels.badge_key(team_id, slot, false),
				PositionLabels.badge_key(team_id, slot, true),
				"slot %d reads the same in both modes (team %d)" % [slot, team_id])
		for slot: int in [1, 2]:
			assert_ne(PositionLabels.badge_key(team_id, slot, false),
				PositionLabels.badge_key(team_id, slot, true),
				"slot %d spells the wing out in 5v5 (team %d)" % [slot, team_id])


func test_column_headers_mirror_and_hold_the_centre() -> void:
	assert_eq(PositionLabels.column_header_key(1, 0),
		PositionLabels.column_header_key(0, 2), "away's left column is its right wing")
	assert_eq(PositionLabels.column_header_key(1, 2),
		PositionLabels.column_header_key(0, 0), "away's right column is its left wing")
	assert_eq(PositionLabels.column_header_key(1, 1),
		PositionLabels.column_header_key(0, 1), "the centre column never mirrors")


func test_out_of_range_indices_fall_back_rather_than_crash() -> void:
	# A HUD rebuild must not die on a slot the roster does not have.
	assert_eq(PositionLabels.badge_key(0, -1, false), PositionLabels.badge_key(0, 0, false),
		"a negative slot falls back to the centre badge")
	assert_eq(PositionLabels.badge_key(1, 99, true), PositionLabels.badge_key(0, 0, false),
		"a slot past the roster falls back to the centre badge")
	assert_eq(PositionLabels.column_header_key(0, 7), PositionLabels.column_header_key(0, 1),
		"a column past the row falls back to the centre header")


func test_every_key_has_a_catalogue_row() -> void:
	var known: Dictionary[String, bool] = {}
	var rows: PackedStringArray = FileAccess.get_file_as_string(_CATALOGUE).split("\n")
	for i: int in range(1, rows.size()):
		var row: String = rows[i].strip_edges()
		if not row.is_empty():
			known[row.get_slice(",", 0)] = true

	var missing: Array[String] = []
	for team_id: int in 2:
		for is_5v5: bool in [false, true]:
			for slot: int in PlayerRules.MAX_PER_TEAM:
				var badge: String = String(PositionLabels.badge_key(team_id, slot, is_5v5))
				if not known.has(badge):
					missing.append(badge)
		for col: int in _COLUMNS:
			var header: String = String(PositionLabels.column_header_key(team_id, col))
			if not known.has(header):
				missing.append(header)
	assert_true(missing.is_empty(),
		"keys with no locale/translations.csv row (they would render raw): "
		+ ", ".join(missing))
