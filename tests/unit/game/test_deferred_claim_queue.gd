extends GutTest

# DeferredClaimQueue — parks a client claim until the state buffer covers the
# instant the claim names, so a claim can't jump ahead of the input that defines
# that instant. The bug it exists for is silent (StateBufferManager answers a
# future query with its newest sample and no signal), so the release rule is
# pinned here rather than left to integration testing.

var q: DeferredClaimQueue
var fired: Array[String]


func before_each() -> void:
	q = DeferredClaimQueue.new()
	fired = []


func _record(tag: String) -> void:
	fired.append(tag)


# ── Immediate paths ──────────────────────────────────────────────────────────

func test_runs_immediately_when_buffer_already_covers_the_instant() -> void:
	# one_way exceeded the lead: the host has already simulated the instant, so
	# there is nothing to wait for and behaviour is unchanged from before.
	q.submit(10.0, 10.05, _record, ["a"])
	assert_eq(fired, ["a"] as Array[String])
	assert_eq(q.size(), 0)


func test_runs_immediately_before_the_first_capture() -> void:
	# newest_ts < 0 means no timeline to wait for; the resolver's own readiness
	# gate owns the outcome rather than the claim being parked forever.
	q.submit(10.0, -1.0, _record, ["a"])
	assert_eq(fired, ["a"] as Array[String])


func test_runs_immediately_on_non_finite_due() -> void:
	q.submit(NAN, 10.0, _record, ["a"])
	assert_eq(fired, ["a"] as Array[String])
	assert_eq(q.size(), 0)


func test_invalid_callable_is_dropped() -> void:
	q.submit(10.5, 10.0, Callable(), ["a"])
	assert_eq(q.size(), 0)


# ── Parking and release ──────────────────────────────────────────────────────

func test_parks_until_the_buffer_reaches_the_instant() -> void:
	q.submit(10.05, 10.0, _record, ["a"])
	assert_eq(fired, [] as Array[String], "must not resolve against an unreached world")
	assert_eq(q.size(), 1)
	q.drain(10.04)
	assert_eq(fired, [] as Array[String], "still one tick short")
	q.drain(10.05)
	assert_eq(fired, ["a"] as Array[String])
	assert_eq(q.size(), 0)


func test_releases_in_instant_order_not_arrival_order() -> void:
	# A later-arriving claim with an EARLIER instant resolves first — the whole
	# point of ordering on the stamp rather than on the packet.
	q.submit(10.09, 10.0, _record, ["late_instant"])
	q.submit(10.02, 10.0, _record, ["early_instant"])
	q.drain(10.10)
	assert_eq(fired, ["early_instant", "late_instant"] as Array[String])


func test_drain_releases_only_what_is_covered() -> void:
	q.submit(10.02, 10.0, _record, ["a"])
	q.submit(10.08, 10.0, _record, ["b"])
	q.drain(10.05)
	assert_eq(fired, ["a"] as Array[String])
	assert_eq(q.size(), 1)
	q.drain(10.09)
	assert_eq(fired, ["a", "b"] as Array[String])


func test_drain_before_first_capture_is_a_noop() -> void:
	q.submit(10.05, 10.0, _record, ["a"])
	q.drain(-1.0)
	assert_eq(fired, [] as Array[String])
	assert_eq(q.size(), 1)


# ── Bounds and teardown ──────────────────────────────────────────────────────

func test_hold_is_capped_so_a_clock_glitch_cannot_park_forever() -> void:
	# A wildly future instant still releases once the buffer passes the cap,
	# rather than sitting until clear().
	q.submit(1000.0, 10.0, _record, ["a"])
	assert_eq(q.size(), 1)
	q.drain(10.0 + DeferredClaimQueue.MAX_HOLD_S)
	assert_eq(fired, ["a"] as Array[String])


func test_clear_drops_parked_claims_without_running_them() -> void:
	# A claim parked across a faceoff describes a world that no longer exists.
	q.submit(10.05, 10.0, _record, ["a"])
	q.clear()
	q.drain(10.10)
	assert_eq(fired, [] as Array[String])
	assert_eq(q.size(), 0)
