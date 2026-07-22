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
	# Client blade args (v28 client-authoritative aim) are all zero here.
	resolver.receive_claim(1, 0.0, 30.0, 25.0, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	assert_eq(resolver._pending_peer_id, -1)


# ── pending client blade (contest path) ───────────────────────────────────────
# Since v28 the claim carries the client's own (reach-clamped) blade; a claimant
# that arms the contest window stashes it so a later contender resolves BOTH
# squirts from client-authoritative aim. These pin the pending-state bookkeeping.

func test_arm_pending_stores_peer_and_client_blade() -> void:
	var curr := Vector3(1.0, 0.0, 2.0)
	var prev := Vector3(0.9, 0.0, 2.0)
	resolver._arm_pending(7, 3.0, curr, prev)
	assert_eq(resolver._pending_peer_id, 7)
	assert_eq(resolver._pending_host_timestamp, 3.0)
	assert_eq(resolver._pending_blade_curr, curr)
	assert_eq(resolver._pending_blade_prev, prev)


func test_clear_resets_pending_client_blade() -> void:
	resolver._arm_pending(7, 3.0, Vector3(1.0, 0.0, 2.0), Vector3(0.9, 0.0, 2.0))
	resolver.clear()
	assert_eq(resolver._pending_blade_curr, Vector3.ZERO)
	assert_eq(resolver._pending_blade_prev, Vector3.ZERO)


# ── _peer_max_reach ───────────────────────────────────────────────────────────
# The anti-cheat reach ceiling comes from the peer's memoized caps; a missing
# entry returns 0.0 so LagCompRewind.clamp_client_blade no-ops (never clamps a
# legit claim to the body when the ceiling is unknown).

func test_peer_max_reach_reads_caps_entry() -> void:
	var caps := AISkaterCaps.new()
	caps.max_blade_reach = 2.5
	registry.caps_by_peer[9] = caps
	assert_almost_eq(resolver._peer_max_reach(9), 2.5, 1e-6)


func test_peer_max_reach_zero_when_no_caps() -> void:
	assert_eq(resolver._peer_max_reach(999), 0.0)
