extends GutTest

# BotSprintRules.should_sprint is a pure gate — these tests cover each gate in
# isolation (lockout, carry/breakaway, stamina floor, gap band + hysteresis,
# turn alignment, facing alignment) plus the happy path. Args, in order:
#   was_sprinting, gap, velocity_xz, desired_move, stamina, locked,
#   carrying, breakaway, facing_xz (optional; ZERO skips the facing gate)

const FAR: float = 10.0          # gap well past GAP_ENGAGE_M
const NEAR: float = 1.0          # gap well inside GAP_SUSTAIN_M
const STRAIGHT := Vector2(0, 1)  # desired heading +Z
const FAST := Vector2(0, 5)      # velocity +Z, above the turn-gate speed


func test_happy_path_far_and_straight_sprints() -> void:
	assert_true(
			BotSprintRules.should_sprint(false, FAR, FAST, STRAIGHT, 1.0, false, false, false),
			"far gap, straight line, full stamina → sprint")


func test_lockout_blocks_sprint() -> void:
	assert_false(
			BotSprintRules.should_sprint(false, FAR, FAST, STRAIGHT, 1.0, true, false, false),
			"controller lockout suppresses sprint")


func test_carrying_without_breakaway_blocks() -> void:
	assert_false(
			BotSprintRules.should_sprint(false, FAR, FAST, STRAIGHT, 1.0, false, true, false),
			"carrier with traffic ahead does not sprint")


func test_carrying_with_breakaway_sprints() -> void:
	assert_true(
			BotSprintRules.should_sprint(false, FAR, FAST, STRAIGHT, 1.0, false, true, true),
			"open-ice carrier bursts")


func test_stamina_floor_blocks_engage() -> void:
	assert_false(
			BotSprintRules.should_sprint(false, FAR, FAST, STRAIGHT, 0.1, false, false, false),
			"below floor → don't start a sprint")


func test_stamina_floor_does_not_block_sustain() -> void:
	# Already sprinting: ride the burst down past the engage floor.
	assert_true(
			BotSprintRules.should_sprint(true, FAR, FAST, STRAIGHT, 0.1, false, false, false),
			"in-progress sprint rides down")


func test_gap_below_engage_blocks_start() -> void:
	# Between SUSTAIN and ENGAGE: not enough to start a fresh sprint.
	assert_false(
			BotSprintRules.should_sprint(false, 4.0, FAST, STRAIGHT, 1.0, false, false, false),
			"mid gap, not sprinting → wait for a bigger gap")


func test_gap_hysteresis_sustains_in_mid_band() -> void:
	# Same mid gap, but already sprinting → keep going (hysteresis).
	assert_true(
			BotSprintRules.should_sprint(true, 4.0, FAST, STRAIGHT, 1.0, false, false, false),
			"already sprinting holds through mid band")


func test_gap_below_sustain_stops_even_when_sprinting() -> void:
	assert_false(
			BotSprintRules.should_sprint(true, NEAR, FAST, STRAIGHT, 1.0, false, false, false),
			"arrived at target → drop sprint")


func test_sharp_turn_at_speed_blocks_sprint() -> void:
	# Moving +Z fast but wanting to go -X: ~90° turn, wide arc would overshoot.
	assert_false(
			BotSprintRules.should_sprint(false, FAR, FAST, Vector2(-1, 0), 1.0, false, false, false),
			"sharp turn at speed suppresses sprint")


func test_sharp_turn_from_rest_still_sprints() -> void:
	# Below the turn-gate speed the heading change is cheap — burst to build up.
	assert_true(
			BotSprintRules.should_sprint(false, FAR, Vector2(0, 1), Vector2(-1, 0), 1.0, false, false, false),
			"near-rest turn does not gate the sprint")


func test_reversal_blocks_sprint() -> void:
	assert_false(
			BotSprintRules.should_sprint(false, FAR, FAST, Vector2(0, -1), 1.0, false, false, false),
			"180° reversal never sprints")


func test_facing_off_heading_blocks_sprint() -> void:
	# Velocity already swung onto the new heading but the BODY still faces the
	# old one: sprint would halve the facing turn rate and pay the crossover
	# thrust penalty — burst only once pointed.
	assert_false(
			BotSprintRules.should_sprint(false, FAR, FAST, STRAIGHT, 1.0, false, false, false,
					Vector2(0, -1)),
			"body still rotating to the heading suppresses sprint")


func test_facing_aligned_sprints() -> void:
	assert_true(
			BotSprintRules.should_sprint(false, FAR, FAST, STRAIGHT, 1.0, false, false, false,
					Vector2(0.2, 0.98)),
			"body pointed within the alignment cone sprints")


func test_facing_zero_skips_the_gate() -> void:
	# Unwired callers (no facing in scope) keep the pre-gate behaviour.
	assert_true(
			BotSprintRules.should_sprint(false, FAR, FAST, STRAIGHT, 1.0, false, false, false,
					Vector2.ZERO),
			"ZERO facing skips the facing gate")


# ── race_speed: the read-side sprint model ───────────────────────────────────
# Race-class ETAs price the sprint gear the body actually runs (Speed's
# headline separation lever), stamina-gated. Cruise 9, league sprint ×1.14.

func test_race_speed_full_pool_short_race_hits_sprint_cap() -> void:
	# 10 m at a full pool: the burst (2.2 s ≈ 22+ m) covers the whole race.
	assert_almost_eq(BotSprintRules.race_speed(9.0, 1.14, 1.0, false, 10.0),
			9.0 * 1.14, 0.001, "a fully-fueled short race runs at the sprint ceiling")


func test_race_speed_gates_mirror_the_body() -> void:
	assert_almost_eq(BotSprintRules.race_speed(9.0, 1.14, 1.0, true, 10.0),
			9.0, 0.001, "exhaustion lockout races at cruise")
	assert_almost_eq(BotSprintRules.race_speed(9.0, 1.14, 0.1, false, 10.0),
			9.0, 0.001, "below the engage floor races at cruise")
	assert_almost_eq(BotSprintRules.race_speed(9.0, 1.14, 1.0, false, 4.0),
			9.0, 0.001, "inside the sprint engage gap races at cruise (arrival band)")


func test_race_speed_long_race_blends_burst_and_cruise() -> void:
	# 60 m on a half pool: the burst covers only part of the race, so the
	# effective cap sits strictly between cruise and the sprint ceiling —
	# the exact two-phase average, not a curve.
	var v: float = BotSprintRules.race_speed(9.0, 1.14, 0.5, false, 60.0)
	assert_gt(v, 9.0, "some burst is still worth real speed")
	assert_lt(v, 9.0 * 1.14, "but a drained pool can't sprint the whole race")
	# Exact check: t_burst = 0.5/drain, d_sprint = 10.26·t_burst,
	# v = 60 / (t_burst + (60 − d_sprint)/9).
	var t_burst: float = 0.5 / 0.45
	var d_sprint: float = 9.0 * 1.14 * t_burst
	var expected: float = 60.0 / (t_burst + (60.0 - d_sprint) / 9.0)
	assert_almost_eq(v, expected, 0.001, "two-phase distance-weighted average")
