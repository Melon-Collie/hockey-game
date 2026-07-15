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
	resolver.receive_claim(1, 0.0, 30.0)
	assert_eq(resolver._pending_peer_id, -1)


# ── _rewound_blade_kinematics ─────────────────────────────────────────────────
# The contest path resolves the squirt from each claimant's REWOUND blade, not a
# present-time sample. These pin the rewind: the position comes from the
# claimant's self-view-time snapshot, the velocity is the per-tick finite
# difference (matching the live blade_world_velocity = Δpos / tick formula).

const _KIN_PEER: int = 5


func _blade_slot(ts: float, blade: Vector3) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.host_timestamp = ts
	s.blade_contact_world = blade
	return s


# Seeds three consecutive one-tick-apart slots around the claimant's self-view
# time so get_state_at lands exactly on the middle slot (view-time) and its
# predecessor (view-time − one tick), making the finite difference exact.
func _resolver_with_blade_track(claim_ts: float, prev_blade: Vector3, view_blade: Vector3) -> PickupClaimResolver:
	var sbm := StateBufferManager.new()
	sbm._alloc_skater(_KIN_PEER)
	var view_t: float = LagCompRewind.self_view_time(claim_ts)
	var tick: float = 1.0 / float(Constants.PHYSICS_TICK)
	var buf: Array = sbm._skater_buffers[_KIN_PEER]
	buf[0] = _blade_slot(view_t - tick, prev_blade)
	buf[1] = _blade_slot(view_t, view_blade)
	buf[2] = _blade_slot(view_t + tick, view_blade)  # newest, so view_t interpolates
	sbm._skater_ptrs[_KIN_PEER] = 3
	sbm._skater_counts[_KIN_PEER] = 3
	var r := PickupClaimResolver.new()
	r.setup(PlayerRegistry.new(), sbm, Callable(), Callable())
	return r


func test_rewound_blade_kinematics_returns_view_time_pos_and_finite_diff_vel() -> void:
	# prev blade at origin, view-time blade at +1 cm on X, one tick apart →
	# pos = view-time blade, vel = 0.01 m × PHYSICS_TICK along X.
	var r: PickupClaimResolver = _resolver_with_blade_track(
		10.0, Vector3.ZERO, Vector3(0.01, 0.0, 0.0))
	var kin: Array = r._rewound_blade_kinematics(_KIN_PEER, 10.0)
	assert_eq(kin.size(), 2, "returns [pos, vel]")
	assert_almost_eq((kin[0] as Vector3).x, 0.01, 1e-5)
	assert_almost_eq((kin[1] as Vector3).x, 0.01 * float(Constants.PHYSICS_TICK), 1e-3)


func test_rewound_blade_kinematics_empty_when_snapshot_missing() -> void:
	# Empty buffer → no skater state at the rewind time → [] so the caller falls
	# back to the live blade instead of reading a phantom (0,0,0).
	var sbm := StateBufferManager.new()
	var r := PickupClaimResolver.new()
	r.setup(PlayerRegistry.new(), sbm, Callable(), Callable())
	assert_true(r._rewound_blade_kinematics(_KIN_PEER, 10.0).is_empty())
