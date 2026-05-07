extends GutTest

# PickupClaimResolver — pending-claim state machine for the contest window.
# `receive_claim`'s geometry path needs a real Puck/PuckController/StateBuffer
# triple, which isn't reasonable to stand up here. We cover the parts that own
# state directly: tick(), clear(), and the early-return branches.

var resolver: PickupClaimResolver
var registry: PlayerRegistry


func before_each() -> void:
	registry = PlayerRegistry.new()
	resolver = PickupClaimResolver.new()
	resolver.setup(registry, null, Callable(), Callable())


# ── tick() ────────────────────────────────────────────────────────────────────

func test_tick_with_no_pending_claim_is_noop() -> void:
	resolver.tick(0.1)
	assert_eq(resolver._pending_peer_id, -1)
	assert_eq(resolver._pending_timer, 0.0)


func test_tick_below_contest_window_preserves_pending_claim() -> void:
	resolver._pending_peer_id = 42
	resolver._pending_timer = 0.0
	resolver.tick(PickupClaimResolver.CONTEST_WINDOW_S - 0.01)
	assert_eq(resolver._pending_peer_id, 42)


func test_tick_past_contest_window_clears_when_peer_unknown() -> void:
	# Peer 42 is not in the registry — simulates a disconnect / demote during
	# the contest window. tick() should clear without crashing.
	resolver._pending_peer_id = 42
	resolver._pending_timer = 0.0
	resolver.tick(PickupClaimResolver.CONTEST_WINDOW_S + 0.01)
	assert_eq(resolver._pending_peer_id, -1)
	assert_eq(resolver._pending_timer, 0.0)


# ── clear() ───────────────────────────────────────────────────────────────────

func test_clear_resets_pending_claim() -> void:
	resolver._pending_peer_id = 42
	resolver._pending_timer = 0.025
	resolver.clear()
	assert_eq(resolver._pending_peer_id, -1)
	assert_eq(resolver._pending_timer, 0.0)


# ── receive_claim() early-return branches ─────────────────────────────────────

func test_receive_claim_with_null_puck_getter_is_noop() -> void:
	# Empty Callables → puck/pc resolve to null → early return without crash.
	resolver.receive_claim(1, 0.0, 50.0, 30.0)
	assert_eq(resolver._pending_peer_id, -1)
