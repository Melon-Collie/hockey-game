extends GutTest

# HitClaimResolver — throttle bookkeeping and rematch reset.
# `notify_local_hit` and `receive_claim` happy paths need a real Skater node
# (for victim → peer_id resolution) and a populated StateBufferManager
# (for rewind), neither of which is reasonable to stand up here. We cover the
# state the resolver owns directly: the throttle dict and reset_throttle().

var resolver: HitClaimResolver
var registry: PlayerRegistry
var hit_tracker: HitTracker


func before_each() -> void:
	registry = PlayerRegistry.new()
	hit_tracker = HitTracker.new()
	hit_tracker.setup(registry)
	resolver = HitClaimResolver.new()
	resolver.setup(registry, null, hit_tracker)


# ── Throttle state ────────────────────────────────────────────────────────────

func test_throttle_dict_starts_empty() -> void:
	assert_eq(resolver._last_claim_sent.size(), 0)


func test_reset_throttle_clears_dict() -> void:
	resolver._last_claim_sent["1:2"] = 100.0
	resolver._last_claim_sent["1:3"] = 100.0
	resolver.reset_throttle()
	assert_eq(resolver._last_claim_sent.size(), 0)


# ── receive_claim() early-return branches ─────────────────────────────────────

func test_receive_claim_with_null_state_buffer_is_noop() -> void:
	# state_buffer is null → early return without crash. The credit path also
	# wouldn't fire, but the lighter assertion is that nothing throws.
	resolver.receive_claim(1, 2, 0.0, 50.0)
	assert_eq(hit_tracker._last_hit_time.size(), 0)
