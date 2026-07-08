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

func test_faceoff_position_defaults_to_center_ice() -> void:
	var p: Vector3 = PlayerRules.faceoff_position(0, 0)
	# Center ice + team-0 center offset (0, 1.5) + spawn height.
	assert_eq(p, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 1.5))

func test_faceoff_position_translates_with_dot() -> void:
	var dot := Vector2(6.5, 22.1)
	var p: Vector3 = PlayerRules.faceoff_position(0, 0, dot)
	# Same team-0 center offset, but anchored at the end-zone dot.
	assert_eq(p, Vector3(6.5, GameRules.FACEOFF_SPAWN_HEIGHT, 22.1 + 1.5))

func test_faceoff_offsets_preserve_team_split_around_dot() -> void:
	var dot := Vector2(-6.5, -22.1)
	# Team 0 always sits on the +Z side of whatever dot is active, team 1 on -Z.
	# This holds even at end-zone dots regardless of the dot's own Z sign.
	for slot: int in range(PlayerRules.MAX_PER_TEAM):
		var p0: Vector3 = PlayerRules.faceoff_position(0, slot, dot)
		var p1: Vector3 = PlayerRules.faceoff_position(1, slot, dot)
		assert_gt(p0.z, dot.y, "team 0 slot %d should be on +Z side of dot" % slot)
		assert_lt(p1.z, dot.y, "team 1 slot %d should be on -Z side of dot" % slot)

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

# ── bench_start_position ─────────────────────────────────────────────────────
# Intro skate-in start points. Both benches on the +X boards; team 0 (+Z half)
# uses the +Z bench, team 1 the -Z bench, staggered per slot toward center.

func test_bench_start_is_on_positive_x_boards() -> void:
	for team_id: int in [0, 1]:
		for slot: int in [0, 1, 2]:
			assert_eq(PlayerRules.bench_start_position(team_id, slot).x,
					GameRules.BENCH_DOOR_X)

func test_bench_start_height_matches_faceoff_spawn_height() -> void:
	assert_eq(PlayerRules.bench_start_position(0, 0).y, GameRules.FACEOFF_SPAWN_HEIGHT)

func test_team_0_bench_is_on_positive_z() -> void:
	for slot: int in [0, 1, 2]:
		assert_gt(PlayerRules.bench_start_position(0, slot).z, 0.0)

func test_team_1_bench_is_on_negative_z() -> void:
	for slot: int in [0, 1, 2]:
		assert_lt(PlayerRules.bench_start_position(1, slot).z, 0.0)

func test_bench_slots_do_not_stack() -> void:
	# The three team-0 skaters leave from distinct points along the bench.
	var z0: float = PlayerRules.bench_start_position(0, 0).z
	var z1: float = PlayerRules.bench_start_position(0, 1).z
	var z2: float = PlayerRules.bench_start_position(0, 2).z
	assert_ne(z0, z1)
	assert_ne(z0, z2)
	assert_ne(z1, z2)

# ── faceoff_staging_position ─────────────────────────────────────────────────
# Post-goal skate-in start: the slot pushed radially OUT from the dot, so the
# skate-in runs back along the ray toward the dot (players converge on it).

const CENTER := Vector2.ZERO

func test_staging_preserves_y() -> void:
	var target := Vector3(4.0, 1.0, 2.8)
	assert_eq(PlayerRules.faceoff_staging_position(target, CENTER, 0).y, target.y)

func test_staging_is_setback_metres_out_along_the_radial() -> void:
	# A winger slot: staging sits exactly the setback further from the dot, on the
	# dot→slot ray, so the skate-in vector points straight at the dot.
	var target := Vector3(4.0, 1.0, 2.8)
	var s: Vector3 = PlayerRules.faceoff_staging_position(target, CENTER, 0)
	var d_target: float = Vector2(target.x, target.z).length()
	var d_staging: float = Vector2(s.x, s.z).length()
	assert_almost_eq(d_staging - d_target, GameRules.FACEOFF_STAGING_SETBACK, 0.001)
	# Colinear with the dot: staging, slot, dot all on one ray.
	var cross: float = target.x * s.z - target.z * s.x
	assert_almost_eq(cross, 0.0, 0.001, "staging is on the dot→slot ray")

func test_staging_pushes_a_winger_wider_in_x() -> void:
	# The radial push widens X for an off-axis slot (was straight-back before).
	var target := Vector3(4.0, 1.0, 2.8)
	assert_gt(PlayerRules.faceoff_staging_position(target, CENTER, 0).x, target.x)

func test_center_on_dot_falls_back_to_straight_back() -> void:
	# A player sitting exactly on the dot has no radial — push toward its own end.
	var target := Vector3(0.0, 1.0, 0.0)
	var s0: Vector3 = PlayerRules.faceoff_staging_position(target, CENTER, 0)
	assert_almost_eq(s0.z, GameRules.FACEOFF_STAGING_SETBACK, 0.001)
	var s1: Vector3 = PlayerRules.faceoff_staging_position(target, CENTER, 1)
	assert_almost_eq(s1.z, -GameRules.FACEOFF_STAGING_SETBACK, 0.001)

# ── skate_in_duration ────────────────────────────────────────────────────────
# Distance-scaled glide time for period / stoppage skate-ins, clamped to a range.

func test_skate_in_duration_scales_with_distance() -> void:
	# A mid-range distance at the target pace, inside the clamp band.
	var d: float = PlayerRules.skate_in_duration(
			GameRules.FACEOFF_SKATE_IN_SPEED * 2.0, 0.5, 5.0)
	assert_almost_eq(d, 2.0, 0.001)

func test_skate_in_duration_floors_close_distance() -> void:
	assert_eq(PlayerRules.skate_in_duration(0.0, 1.25, 3.0), 1.25)

func test_skate_in_duration_caps_far_distance() -> void:
	# 100 m would need ~11 s; the cap keeps everyone set before the drop.
	assert_eq(PlayerRules.skate_in_duration(100.0, 1.25, 3.0), 3.0)
