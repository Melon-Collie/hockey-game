extends GutTest

# AIBodyCheck — pure commit-to-a-hit decision for on-puck defensive bots.
# Covers the three gates (range, reachable intercept, real-hit impulse), the
# attribute gating that falls out of the impulse prediction, the closing-speed
# dependence, and the self-stagger guard.

const SELF_POS := Vector3.ZERO
const SELF_SPEED: float = 9.0          # league top speed
const BASE_TRANSFER: float = 0.45      # Skater default body_check_transfer
const HIGH_TRANSFER: float = 0.61      # ~ +36% Physical
const LOW_TRANSFER: float = 0.29       # ~ -36% Physical
const WEIGHT: float = 1.0


func _eval(carrier_pos: Vector3, carrier_vel: Vector3, transfer: float,
		stagger: float = 0.0) -> AIBodyCheck.Result:
	return AIBodyCheck.evaluate(
			SELF_POS, SELF_SPEED, WEIGHT, transfer, stagger, carrier_pos, carrier_vel)


# ── Real-hit gate + attribute expression ────────────────────────────────────

func test_high_physical_commits_on_stationary_carrier() -> void:
	# Carrier 4 m away, head-on, stationary. A high-Physical checker predicts a
	# separating hit (9 × 1 × 0.61 ≈ 5.5 ≥ 5) and commits.
	var r: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, HIGH_TRANSFER)
	assert_true(r.commit, "high-Physical checker commits to a reachable hit")
	assert_almost_eq(r.target.x, 4.0, 0.3, "target is the body intercept")


func test_low_physical_does_not_commit_same_geometry() -> void:
	# Identical geometry; a low-Physical checker predicts a bounce-off
	# (9 × 1 × 0.29 ≈ 2.6 < 5) and stays in position instead of whiffing.
	var r: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, LOW_TRANSFER)
	assert_false(r.commit, "low-Physical checker won't commit to a soft hit")


func test_heavy_victim_bounces_off_a_committing_checker() -> void:
	# HIGH_TRANSFER commits on a league-weight carrier (9 × 1 × 0.61 ≈ 5.5 ≥ 5).
	# Against a HEAVY carrier (Size — weight 1.4) the same hit moves it less
	# (9 × 1/1.4 × 0.61 ≈ 3.9 < 5), so the checker won't leave its feet for it.
	var vs_league: AIBodyCheck.Result = AIBodyCheck.evaluate(
			SELF_POS, SELF_SPEED, WEIGHT, HIGH_TRANSFER, 0.0,
			Vector3(4, 0, 0), Vector3.ZERO)
	var vs_heavy: AIBodyCheck.Result = AIBodyCheck.evaluate(
			SELF_POS, SELF_SPEED, WEIGHT, HIGH_TRANSFER, 0.0,
			Vector3(4, 0, 0), Vector3.ZERO, AIBodyCheck.COMMIT_IMPULSE_M_S, 1.4)
	assert_true(vs_league.commit, "commits on a league-weight carrier")
	assert_false(vs_heavy.commit, "bounces off a heavy carrier — no commit")


func test_medium_holds_on_stationary_but_commits_when_carrier_closes() -> void:
	# A medium checker doesn't hunt a stationary carrier head-on
	# (9 × 0.45 ≈ 4.05 < 5)...
	var still: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, BASE_TRANSFER)
	assert_false(still.commit, "medium checker holds vs a stationary carrier")
	# ...but a carrier skating INTO the check raises the closing speed
	# (≈13 × 0.45 ≈ 5.85 ≥ 5), so the bigger collision is worth committing to.
	var closing: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3(-4, 0, 0), BASE_TRANSFER)
	assert_true(closing.commit, "medium checker commits when the carrier closes on it")


# ── Range gate ───────────────────────────────────────────────────────────────

func test_no_commit_out_of_range() -> void:
	# Carrier 8 m away (> CHECK_RANGE_M) — don't hunt a hit from afar even with
	# a big hitter.
	var r: AIBodyCheck.Result = _eval(Vector3(8, 0, 0), Vector3.ZERO, HIGH_TRANSFER)
	assert_false(r.commit, "no commit beyond CHECK_RANGE_M")


# ── Reachability gate ────────────────────────────────────────────────────────

func test_no_commit_on_fleeing_carrier() -> void:
	# Carrier in range but fleeing faster than the checker can close — the
	# intercept saturates out of reach, so no commit.
	var r: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3(12, 0, 0), HIGH_TRANSFER)
	assert_false(r.commit, "no commit when the carrier outruns the closing line")


# ── Self-stagger guard ───────────────────────────────────────────────────────

func test_no_commit_while_staggered() -> void:
	# Even a perfect hit setup is declined while we're off-balance.
	var r: AIBodyCheck.Result = _eval(Vector3(4, 0, 0), Vector3.ZERO, HIGH_TRANSFER, 0.3)
	assert_false(r.commit, "a staggered checker can't deliver a hit")


# ── Difficulty commit-threshold (check_aggression pace knob) ─────────────────

func test_raised_commit_threshold_suppresses_a_marginal_hit() -> void:
	# The same high-Physical head-on hit that commits at the default threshold
	# (impulse ≈ 5.5) is declined once an easier tier raises the required impulse
	# above it — the bot only commits to harder hits, or (at the extreme) none.
	var default_commit: AIBodyCheck.Result = AIBodyCheck.evaluate(
			SELF_POS, SELF_SPEED, WEIGHT, HIGH_TRANSFER, 0.0,
			Vector3(4, 0, 0), Vector3.ZERO)
	assert_true(default_commit.commit, "commits at the default threshold")
	var raised: AIBodyCheck.Result = AIBodyCheck.evaluate(
			SELF_POS, SELF_SPEED, WEIGHT, HIGH_TRANSFER, 0.0,
			Vector3(4, 0, 0), Vector3.ZERO, 7.0)
	assert_false(raised.commit, "declines the same hit once the threshold is raised")
