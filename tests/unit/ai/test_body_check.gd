extends GutTest

# AIBodyCheck — pure commit-to-a-hit decision for on-puck defensive bots.
# Covers the three gates (range, reachable intercept, real-hit impulse), the
# attribute gating that falls out of the impulse prediction, the closing-speed
# dependence, and the self-stagger guard.
#
# In attributes v4 the check transfer is FLAT for every build (0.65 — Physical is
# gone); the commit differentiation now rides MASS: the checker's own weight and
# the carrier's weight move the reduced-mass delivery, so a heavy build hunts hits
# and a light build correctly declines checks it'd bounce off a bigger target.

const SELF_POS := Vector3.ZERO
const SELF_SPEED: float = 9.0     # league top speed (the closing-speed proxy)
const TRANSFER: float = 0.65      # Skater.body_check_transfer — flat for every v4 build
const NEUTRAL_W: float = 1.0
const HEAVY_W: float = 1.28       # top of the v4 mass range
const LIGHT_W: float = 0.79       # bottom of the v4 mass range


func _eval(carrier_pos: Vector3, carrier_vel: Vector3,
		self_weight: float = NEUTRAL_W, victim_weight: float = NEUTRAL_W,
		threshold: float = AIBodyCheck.COMMIT_IMPULSE_M_S,
		stagger: float = 0.0) -> AIBodyCheck.Result:
	return AIBodyCheck.evaluate(
			SELF_POS, SELF_SPEED, self_weight, TRANSFER, stagger,
			carrier_pos, carrier_vel, threshold, victim_weight)


# ── Real-hit gate ────────────────────────────────────────────────────────────

func test_commits_on_reachable_solid_hit() -> void:
	# Carrier 4 m away, head-on, stationary: the checker sprints in at ~9 m/s
	# closing → 9 × 0.65 × 0.5 ≈ 2.93 (well past the 1.6 commit bar), a solid
	# strip-and-stagger check, so it commits and steers at the body intercept.
	var r: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO)
	assert_true(r.commit, "commits to a reachable solid check")
	assert_almost_eq(r.target.x, 4.0, 0.3, "target is the body intercept")


# ── Mass differentiation (v4: weight, not Physical) ──────────────────────────

func test_heavier_checker_commits_where_a_lighter_one_bounces() -> void:
	# Same stationary carrier and geometry; only the CHECKER's mass differs. A
	# heavy build delivers a bigger reduced-mass kick (9 × 0.65 × 1.28/2.28 ≈ 3.28)
	# than a light one (9 × 0.65 × 0.79/1.79 ≈ 2.58). At a bar between them the
	# heavy build commits and the light build stays on its feet.
	var heavy: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, HEAVY_W, NEUTRAL_W, 3.0)
	var light: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, LIGHT_W, NEUTRAL_W, 3.0)
	assert_true(heavy.commit, "a heavy checker commits to the hit")
	assert_false(light.commit, "a light checker won't leave its feet for the same hit")


func test_heavier_victim_absorbs_the_check() -> void:
	# Same medium checker and geometry; only the CARRIER's mass differs. A heavier
	# carrier moves less for the same hit (9 × 0.65 × 1/2.28 ≈ 2.57) than a light
	# one (9 × 0.65 × 1/1.79 ≈ 3.27). At a bar between them the checker commits on
	# the light carrier but declines the heavy one it'd bounce off.
	var vs_light: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, NEUTRAL_W, LIGHT_W, 3.0)
	var vs_heavy: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, NEUTRAL_W, HEAVY_W, 3.0)
	assert_true(vs_light.commit, "commits on a lighter carrier")
	assert_false(vs_heavy.commit, "declines a heavy carrier that absorbs the hit")


# ── Closing-speed dependence ─────────────────────────────────────────────────

func test_closing_carrier_raises_the_hit() -> void:
	# A carrier skating INTO the check adds its speed to the closing line, so the
	# same geometry that lands a ~2.93 hit on a stationary carrier lands ~4.23 on
	# one closing at 4 m/s (13 × 0.65 × 0.5). At a bar above the stationary hit but
	# below the closing one, only the bigger collision is worth committing to.
	var still: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, NEUTRAL_W, NEUTRAL_W, 3.5)
	assert_false(still.commit, "holds vs a stationary carrier under a raised bar")
	var closing: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3(-4, 0, 0), NEUTRAL_W, NEUTRAL_W, 3.5)
	assert_true(closing.commit, "commits when the carrier closes on it")


# ── Range gate ───────────────────────────────────────────────────────────────

func test_no_commit_out_of_range() -> void:
	# Carrier 8 m away (> CHECK_RANGE_M) — don't hunt a hit from afar.
	var r: AIBodyCheck.Result = _eval(Vector3(8, 0, 0), Vector3.ZERO)
	assert_false(r.commit, "no commit beyond CHECK_RANGE_M")


# ── Reachability gate ────────────────────────────────────────────────────────

func test_no_commit_on_fleeing_carrier() -> void:
	# Carrier in range but fleeing faster than the checker can close — the
	# intercept saturates out of reach, so no commit.
	var r: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3(12, 0, 0))
	assert_false(r.commit, "no commit when the carrier outruns the closing line")


# ── Self-stagger guard ───────────────────────────────────────────────────────

func test_no_commit_while_staggered() -> void:
	# Even a perfect hit setup is declined while we're off-balance.
	var r: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, NEUTRAL_W, NEUTRAL_W,
			AIBodyCheck.COMMIT_IMPULSE_M_S, 0.3)
	assert_false(r.commit, "a staggered checker can't deliver a hit")


# ── Difficulty commit-threshold (check_aggression pace knob) ─────────────────

func test_raised_commit_threshold_suppresses_a_marginal_hit() -> void:
	# The same solid head-on hit that commits at the default bar (impulse ≈ 2.93)
	# is declined once an easier tier raises the required impulse above it — the
	# bot only commits to harder hits, or (at the extreme) none.
	var default_commit: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO)
	assert_true(default_commit.commit, "commits at the default threshold")
	var raised: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, NEUTRAL_W, NEUTRAL_W, 3.5)
	assert_false(raised.commit, "declines the same hit once the threshold is raised")
