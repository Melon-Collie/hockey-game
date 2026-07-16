extends GutTest

# HitRules — NHL-style classification of a body-check contact into a hit.
# CREDIT = victim just lost/released the puck (finished check, stat lands now);
# CREDIT_PENDING = victim carries, stat waits for a possession loss;
# REJECT = soft contact, attacker carrying, or victim nowhere near possession.

const IMPULSE_OK: float = HitRules.MIN_HIT_IMPULSE + 1.0

# ── Impulse gate ─────────────────────────────────────────────────────────────

func test_below_impulse_threshold_rejected() -> void:
	assert_eq(HitRules.classify_contact(HitRules.MIN_HIT_IMPULSE - 0.01, false, true, INF),
			HitRules.Verdict.REJECT)

func test_at_impulse_threshold_passes() -> void:
	assert_eq(HitRules.classify_contact(HitRules.MIN_HIT_IMPULSE, false, true, INF),
			HitRules.Verdict.CREDIT_PENDING)

# ── Attacker gate ────────────────────────────────────────────────────────────

func test_attacker_carrying_puck_rejected() -> void:
	assert_eq(HitRules.classify_contact(IMPULSE_OK, true, false, 0.0),
			HitRules.Verdict.REJECT)

# ── Commit gate ──────────────────────────────────────────────────────────────

func test_uncommitted_attacker_rejected() -> void:
	# The Hit button wasn't held — incidental contact, not a body check, even on a
	# carrier with plenty of impulse. This is the "bump after a stick check" case.
	assert_eq(HitRules.classify_contact(IMPULSE_OK, false, true, INF, false),
			HitRules.Verdict.REJECT)

func test_uncommitted_within_grace_still_rejected() -> void:
	# The grace path (just-released victim) would normally CREDIT, but without a
	# commit it's still just a bump drifting in right after the poke.
	assert_eq(HitRules.classify_contact(
			IMPULSE_OK, false, false, HitRules.JUST_RELEASED_GRACE_S - 0.01, false),
			HitRules.Verdict.REJECT)

func test_committed_default_preserves_existing_behavior() -> void:
	# attacker_committed defaults true, so the un-passed calls above (and the
	# existing host/claim call sites during migration) classify unchanged.
	assert_eq(HitRules.classify_contact(IMPULSE_OK, false, true, INF, true),
			HitRules.Verdict.CREDIT_PENDING)

# ── Possession gates ─────────────────────────────────────────────────────────

func test_contact_on_carrier_is_pending() -> void:
	assert_eq(HitRules.classify_contact(IMPULSE_OK, false, true, INF),
			HitRules.Verdict.CREDIT_PENDING)

func test_contact_within_grace_after_release_credits() -> void:
	assert_eq(HitRules.classify_contact(
			IMPULSE_OK, false, false, HitRules.JUST_RELEASED_GRACE_S - 0.01),
			HitRules.Verdict.CREDIT)

func test_contact_after_grace_expires_rejected() -> void:
	assert_eq(HitRules.classify_contact(
			IMPULSE_OK, false, false, HitRules.JUST_RELEASED_GRACE_S + 0.01),
			HitRules.Verdict.REJECT)

func test_victim_never_possessed_rejected() -> void:
	# Open-ice bump on a player who never had the puck — no hit, however hard.
	assert_eq(HitRules.classify_contact(IMPULSE_OK + 10.0, false, false, INF),
			HitRules.Verdict.REJECT)

func test_grace_wins_over_stale_carrier_flag() -> void:
	# A lag-comp claim can present a snapshot where the victim still carried,
	# after the host already saw the puck come loose — the live possession loss
	# must credit immediately instead of pending on a loss already in the past.
	assert_eq(HitRules.classify_contact(IMPULSE_OK, false, true, 0.0),
			HitRules.Verdict.CREDIT)
