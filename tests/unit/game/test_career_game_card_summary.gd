extends GutTest

# Guards the join between the career screen's game cards and the .mreplay meta
# they read. Every field here failed SILENTLY once: the header's player list is
# keyed `roster` while the FOOTER's box score is keyed `players`, and reading
# `players` off the header returns an empty Array rather than erroring — so the
# participant names, the local win/loss badge, and the YOU line all just quietly
# stopped rendering with no log line to find.
#
# The screen is a Control built entirely in _build_ui (driven from _ready), so
# `new()` gives a bare instance whose pure meta->summary helpers can be called
# without a scene tree.

const _HEADER_ROSTER_KEY: String = "roster"
const _FOOTER_PLAYERS_KEY: String = "players"

var _screen: CareerStatsScreen = null


func before_each() -> void:
	_screen = CareerStatsScreen.new()


func after_each() -> void:
	_screen.free()
	_screen = null


# Mirrors GameManager._build_replay_header / _build_replay_footer. Kept literal
# rather than generated so a key rename over there fails HERE, loudly.
func _meta(home: int, away: int) -> Dictionary:
	return {
		"ok": true,
		"header": {
			_HEADER_ROSTER_KEY: [
				{"peer_id": 1, "player_name": "Melon", "team_id": 0, "is_local": true},
				{"peer_id": 2, "player_name": "Rook", "team_id": 0, "is_local": false},
				{"peer_id": 3, "player_name": "Gunner", "team_id": 1, "is_local": false},
			],
			"home_color_slot": 0,
			"away_color_slot": 1,
		},
		"footer": {
			"final_score_home": home,
			"final_score_away": away,
			_FOOTER_PLAYERS_KEY: [
				{"peer_id": 1, "team_id": 0, "goals": 2, "assists": 1, "shots_on_goal": 5},
				{"peer_id": 3, "team_id": 1, "goals": 0, "assists": 0, "shots_on_goal": 4},
			],
		},
	}


func test_roster_reads_the_headers_roster_key() -> void:
	var roster: Dictionary = _screen._roster_from_meta(_meta(2, 1))
	assert_eq((roster[0] as Array).size(), 2, "home side should list both its skaters")
	assert_eq((roster[1] as Array).size(), 1, "away side should list its skater")
	assert_has(roster[0] as Array, "Melon (you)", "the local player is marked")
	assert_has(roster[0] as Array, "Rook")
	assert_has(roster[1] as Array, "Gunner")


func test_roster_is_empty_when_the_header_has_no_roster() -> void:
	# A header written by a build that predates the roster field, or an unreadable
	# file: the card drops the names rather than erroring mid-render.
	var roster: Dictionary = _screen._roster_from_meta({"header": {}})
	assert_true((roster[0] as Array).is_empty())
	assert_true((roster[1] as Array).is_empty())


func test_outcome_uses_the_local_players_side() -> void:
	assert_eq(_screen._outcome_from_meta(_meta(2, 1)), "win")
	assert_eq(_screen._outcome_from_meta(_meta(1, 2)), "loss")
	assert_eq(_screen._outcome_from_meta(_meta(2, 2)), "draw")


func test_outcome_is_blank_without_a_local_player() -> void:
	# A spectator recording has no is_local entry, so there is no "your" side to
	# call a win or a loss.
	var meta: Dictionary = _meta(3, 0)
	for entry: Variant in (meta["header"][_HEADER_ROSTER_KEY] as Array):
		(entry as Dictionary)["is_local"] = false
	assert_eq(_screen._outcome_from_meta(meta), "")


func test_you_line_joins_header_identity_to_footer_box_score() -> void:
	# peer_id is the join key: is_local lives in the header, the stats in the footer.
	assert_eq(_screen._you_line_from_meta(_meta(2, 1)), "YOU · 2G 1A · 5 SOG")


func test_you_line_is_blank_when_the_footer_has_no_row_for_you() -> void:
	var meta: Dictionary = _meta(2, 1)
	meta["footer"][_FOOTER_PLAYERS_KEY] = [
		{"peer_id": 3, "team_id": 1, "goals": 0, "assists": 0, "shots_on_goal": 4},
	]
	assert_eq(_screen._you_line_from_meta(meta), "")


# Card colours are a SCORE surface, so they follow the scorebug's rule — each
# team wears its own primary — rather than the jersey colours, whose away kit is
# near-white and vanishes on the dark card.
func test_card_colours_are_each_teams_own_primary() -> void:
	var colors: Array[Color] = _screen._colors_from_meta(_meta(2, 1))
	var pair: Dictionary = TeamColorRegistry.get_score_stripe_pair(0, 1)
	assert_eq(colors.size(), 2)
	assert_eq(colors[0], pair.home as Color)
	assert_eq(colors[1], pair.away as Color)


func test_card_colours_fall_back_when_no_replay_file_recorded_them() -> void:
	# career_stats has no colour columns, so a backend row with no local file has
	# to render neutral rather than borrow the CURRENT session's palette.
	var colors: Array[Color] = _screen._colors_from_meta({})
	assert_eq(colors.size(), 2)
	assert_ne(colors[0], colors[1], "the two sides must still be distinguishable")
