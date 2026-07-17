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

# ── End-zone draw D alignment (5v5) ──────────────────────────────────────────
# At an end-zone dot the D pair's jobs are positional, not dot-relative (the
# FACEOFF_END_* doc in GameRules): defending — strong-side D retrieves behind
# the C, weak-side D fronts the net (the cover the dot-stacked table left
# naked); attacking — points at the blue line. C/wingers keep the table, and
# 3v3 (no D slots) is untouched by construction.

const _END_DOT_T0 := Vector2(
		GameRules.END_ZONE_FACEOFF_DOT_X, GameRules.ICING_FACEOFF_DOT_Z)

func test_defending_strong_d_retrieves_behind_the_center() -> void:
	# Team 0 defends +Z; on the +x dot the RD (slot 4, identity +x) is strong.
	var p: Vector3 = PlayerRules.faceoff_position(0, 4, _END_DOT_T0)
	assert_almost_eq(p.x, _END_DOT_T0.x + GameRules.FACEOFF_END_RETRIEVER_SHADE_M, 0.001,
			"retriever shades boards-side off the dot line")
	assert_almost_eq(p.z, _END_DOT_T0.y + GameRules.FACEOFF_END_RETRIEVER_BEHIND_M, 0.001,
			"retriever stands goal-side behind the C")

func test_defending_weak_d_fronts_the_net() -> void:
	# The LD (slot 3, identity -x) is weak on the +x dot: near post, dot side.
	var p: Vector3 = PlayerRules.faceoff_position(0, 3, _END_DOT_T0)
	assert_almost_eq(p.x, GameRules.FACEOFF_END_NETFRONT_X_M, 0.001,
			"net-front D stands at the near post (net is at x = 0)")
	assert_almost_eq(p.z, GameRules.GOAL_LINE_Z - GameRules.FACEOFF_END_NETFRONT_OFF_LINE_M, 0.001,
			"net-front D stands just in front of the goal line")

func test_attacking_points_hold_the_blue_line() -> void:
	# Team 1 attacks +Z: at team 0's D-zone dot its D pair plays the points.
	var strong: Vector3 = PlayerRules.faceoff_position(1, 4, _END_DOT_T0)
	var weak: Vector3 = PlayerRules.faceoff_position(1, 3, _END_DOT_T0)
	var line_z: float = GameRules.BLUE_LINE_Z + GameRules.FACEOFF_END_POINT_INSIDE_M
	assert_almost_eq(strong.z, line_z, 0.001, "strong point just inside the blue line")
	assert_almost_eq(weak.z, line_z, 0.001, "weak point on the same line")
	assert_almost_eq(strong.x, _END_DOT_T0.x, 0.001, "strong point directly above the dot")
	assert_almost_eq(weak.x, -GameRules.FACEOFF_END_WEAK_POINT_X_M, 0.001,
			"weak point covers the middle of the line")

func test_end_zone_alignment_mirrors_for_team_1() -> void:
	# Team 1 defending at its own -x/-z dot: the LD (identity -x) is strong.
	var dot := Vector2(-GameRules.END_ZONE_FACEOFF_DOT_X,
			-GameRules.ICING_FACEOFF_DOT_Z)
	var retriever: Vector3 = PlayerRules.faceoff_position(1, 3, dot)
	var netfront: Vector3 = PlayerRules.faceoff_position(1, 4, dot)
	assert_almost_eq(retriever.x, dot.x - GameRules.FACEOFF_END_RETRIEVER_SHADE_M, 0.001)
	assert_almost_eq(retriever.z, dot.y - GameRules.FACEOFF_END_RETRIEVER_BEHIND_M, 0.001)
	assert_almost_eq(netfront.x, -GameRules.FACEOFF_END_NETFRONT_X_M, 0.001)
	assert_almost_eq(netfront.z,
			-(GameRules.GOAL_LINE_Z - GameRules.FACEOFF_END_NETFRONT_OFF_LINE_M),
			0.001)

func test_center_and_neutral_dots_keep_the_legacy_d_offsets() -> void:
	# The positional override is end-zone only: |dot z| inside the blue line
	# keeps the one dot-relative table for the D pair.
	var center: Vector3 = PlayerRules.faceoff_position(0, 3)
	assert_almost_eq(center, Vector3(-2.4, GameRules.FACEOFF_SPAWN_HEIGHT, 7.0),
			Vector3.ONE * 0.001)
	var nz_dot: Vector2 = GameRules.NEUTRAL_ZONE_FACEOFF_DOTS[2]
	var nz: Vector3 = PlayerRules.faceoff_position(0, 3, nz_dot)
	assert_almost_eq(nz, Vector3(nz_dot.x - 2.4, GameRules.FACEOFF_SPAWN_HEIGHT,
			nz_dot.y + 7.0), Vector3.ONE * 0.001)

func test_wingers_keep_the_table_at_end_zone_dots() -> void:
	# The hash-mark line-up is the real alignment at every dot — only the D
	# pair repositions on end-zone draws.
	var p: Vector3 = PlayerRules.faceoff_position(0, 1, _END_DOT_T0)
	assert_almost_eq(p, Vector3(_END_DOT_T0.x - 4.7, GameRules.FACEOFF_SPAWN_HEIGHT,
			_END_DOT_T0.y + 0.9), Vector3.ONE * 0.001)

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

# ── stagger01 ────────────────────────────────────────────────────────────────
# Deterministic per-player skate-in stagger seed.

func test_stagger01_is_in_unit_range() -> void:
	for a: int in range(1, 8):
		for b: int in range(0, 6):
			var v: float = PlayerRules.stagger01(a, b)
			assert_between(v, 0.0, 1.0)

func test_stagger01_is_deterministic() -> void:
	assert_eq(PlayerRules.stagger01(3, 2), PlayerRules.stagger01(3, 2))

func test_stagger01_varies_by_player() -> void:
	# The three faceoff peers at the same goal count shouldn't all match.
	var a: float = PlayerRules.stagger01(1, 0)
	var b: float = PlayerRules.stagger01(2, 0)
	var c: float = PlayerRules.stagger01(3, 0)
	assert_false(a == b and b == c, "per-player stagger must not collapse to one value")

func test_stagger01_varies_by_goal_count() -> void:
	# Same player, different faceoff (goal count) → generally a different stagger.
	assert_ne(PlayerRules.stagger01(1, 0), PlayerRules.stagger01(1, 1))

# ── 5v5 slots: positions, D faceoff placement, clamps ────────────────────────

func test_position_names_cover_the_full_lineup() -> void:
	assert_eq(PlayerRules.position_name(0), "C")
	assert_eq(PlayerRules.position_name(1), "LW")
	assert_eq(PlayerRules.position_name(2), "RW")
	assert_eq(PlayerRules.position_name(3), "LD")
	assert_eq(PlayerRules.position_name(4), "RD")
	assert_eq(PlayerRules.position_name(5), "", "out-of-range slot has no position")

func test_defense_slots_are_3_and_4() -> void:
	for slot: int in [0, 1, 2]:
		assert_false(PlayerRules.is_defense_slot(slot), "slot %d is a forward" % slot)
	for slot: int in [3, 4]:
		assert_true(PlayerRules.is_defense_slot(slot), "slot %d is a defenseman" % slot)

func test_defensemen_stand_behind_the_wingers() -> void:
	# Center-ice draw: the D pair (slots 3/4) sets up deeper toward its own
	# end than the wingers (slots 1/2), mirrored per team.
	for team_id: int in [0, 1]:
		var own_dir: float = 1.0 if team_id == 0 else -1.0
		var winger_depth: float = own_dir * PlayerRules.faceoff_position(team_id, 1).z
		for d_slot: int in [3, 4]:
			var d_depth: float = own_dir * PlayerRules.faceoff_position(team_id, d_slot).z
			assert_gt(d_depth, winger_depth,
					"team %d slot %d must be behind the wingers" % [team_id, d_slot])

func test_defensive_zone_draw_keeps_defensemen_in_front_of_goal_line() -> void:
	# Team 0 defends +Z; at its own end-zone dot the D slots' raw offsets
	# (+7 m) would land behind the goal line — the depth cap pulls them
	# net-side instead.
	var dot: Vector2 = GameRules.END_ZONE_FACEOFF_DOTS[0]  # team 0 DZ, left
	for d_slot: int in [3, 4]:
		var p: Vector3 = PlayerRules.faceoff_position(0, d_slot, dot)
		assert_lt(absf(p.z), GameRules.GOAL_LINE_Z,
				"slot %d must spawn in front of the goal line" % d_slot)

func test_staging_position_stays_on_the_ice_for_deep_slots() -> void:
	# Post-goal staging pushes radially outward from the dot; for a D already
	# clamped near the goal line that raw push lands outside the boards.
	var dot: Vector2 = GameRules.END_ZONE_FACEOFF_DOTS[1]  # team 0 DZ, right
	for d_slot: int in [3, 4]:
		var target: Vector3 = PlayerRules.faceoff_position(0, d_slot, dot)
		var staged: Vector3 = PlayerRules.faceoff_staging_position(target, dot, 0)
		assert_lt(absf(staged.z), GameRules.INNER_HALF_LENGTH,
				"slot %d staging must stay inside the end boards" % d_slot)
		assert_lt(absf(staged.x), GameRules.INNER_HALF_WIDTH,
				"slot %d staging must stay inside the side boards" % d_slot)
