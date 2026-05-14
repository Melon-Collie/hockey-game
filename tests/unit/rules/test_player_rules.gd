extends GutTest

# PlayerRules — team balancing and faceoff position lookup.

# ── assign_team ──────────────────────────────────────────────────────────────

func test_tied_counts_pick_either_team() -> void:
	# Tiebreak is randomised; verify only that a valid team id comes back.
	var t: int = PlayerRules.assign_team(0, 0)
	assert_true(t == 0 or t == 1, "tiebreak must return 0 or 1, got %d" % t)

func test_smaller_team_gets_next_player() -> void:
	assert_eq(PlayerRules.assign_team(1, 0), 1)
	assert_eq(PlayerRules.assign_team(0, 1), 0)

func test_lopsided_filled_to_smaller() -> void:
	assert_eq(PlayerRules.assign_team(3, 1), 1)

# ── faceoff_position ─────────────────────────────────────────────────────────

func test_team_0_faceoff_positions_are_on_positive_z_side() -> void:
	assert_gt(PlayerRules.faceoff_position(0, 0).z, 0.0)
	assert_gt(PlayerRules.faceoff_position(0, 1).z, 0.0)
	assert_gt(PlayerRules.faceoff_position(0, 2).z, 0.0)

func test_team_1_faceoff_positions_are_on_negative_z_side() -> void:
	assert_lt(PlayerRules.faceoff_position(1, 0).z, 0.0)
	assert_lt(PlayerRules.faceoff_position(1, 1).z, 0.0)
	assert_lt(PlayerRules.faceoff_position(1, 2).z, 0.0)

# ── faceoff_facing ───────────────────────────────────────────────────────────
# Team 0 spawns on the +Z side and attacks -Z; team 1 mirrors. The teleport
# helper relies on this so swapped/spawning players don't keep last frame's
# heading and end up backwards on faceoff.

func test_team_0_faces_negative_z() -> void:
	var f: Vector2 = PlayerRules.faceoff_facing(0)
	assert_eq(f.x, 0.0)
	assert_lt(f.y, 0.0, "team 0 should face -Z (attacking goal)")

func test_team_1_faces_positive_z() -> void:
	var f: Vector2 = PlayerRules.faceoff_facing(1)
	assert_eq(f.x, 0.0)
	assert_gt(f.y, 0.0, "team 1 should face +Z (attacking goal)")

func test_unknown_team_returns_zero_facing() -> void:
	# Vector2.ZERO sentinel lets the teleport helper pass through without
	# overriding facing — used by tutorial / test paths that don't want
	# the helper to flip the skater.
	assert_eq(PlayerRules.faceoff_facing(-1), Vector2.ZERO)
