extends GutTest

# RemoteController's bounded input catch-up. Production and consumption are both
# one per tick, so a backlog left by a host stall can never drain on its own —
# every later input stays that many ticks stale for the rest of the session. The
# drain is the only other release and it clears debt by DISCARDING inputs the
# client already predicted with. Catch-up clears the same debt losslessly by
# consuming a second input on ticks where the next one is already past due.
#
# These tests drive _front_overdue (the catch-up predicate) and the queue
# directly, the same way test_remote_controller_drain.gd does — no clock, no
# scene. The convergence test models the tick loop the predicate governs.

const TICK: float = 1.0 / 120.0


func _controller() -> RemoteController:
	var rc := RemoteController.new()
	autofree(rc)
	return rc


func _seed(rc: RemoteController, timestamps: Array) -> void:
	for ts: float in timestamps:
		var s := InputState.new()
		s.host_timestamp = ts
		rc._input_queue.append(s)


# A queue holding only the stamp-lead cushion carries no debt: every entry is
# scheduled ahead of now, so nothing is owed and catch-up must stay off.
func test_lead_cushion_is_not_debt() -> void:
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(9):  # 9 ticks of cushion — the lead working, not a backlog
		stamps.append(now + TICK * float(i))
	_seed(rc, stamps)
	assert_eq(rc._front_overdue(now), 0.0, "future stamps are cushion, never debt")


func test_healthy_cadence_does_not_trigger_catch_up() -> void:
	# The steady state the drain sizing measured: a deep queue whose front pops
	# ~1.5 ticks overdue. Ordinary cadence must never double-pop.
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(10):
		stamps.append(now - TICK * 1.5 + TICK * float(i))
	_seed(rc, stamps)
	assert_lt(rc._front_overdue(now), RemoteController._CATCH_UP_OVERDUE_S,
			"healthy quantization-scale overdue rides on a single pop")


func test_stall_backlog_triggers_catch_up() -> void:
	# Ten ticks of debt — an ~83 ms host stall's worth of inputs all coming due
	# at once. This is the case that used to persist for the whole session.
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(10):
		stamps.append(now - TICK * float(10 - i))
	_seed(rc, stamps)
	assert_gt(rc._front_overdue(now), RemoteController._CATCH_UP_OVERDUE_S,
			"a stall backlog reads as debt")


func test_catch_up_arms_well_before_the_lossy_drain() -> void:
	# The whole point of the lossless path: it must clear a stall backlog long
	# before the drain's trigger arms and starts discarding real inputs.
	assert_lt(RemoteController._CATCH_UP_OVERDUE_S, RemoteController._DRAIN_TRIGGER_S,
			"catch-up engages first, so the drain stays a backstop")


# Run the tick loop the predicate governs: each tick the client produces one
# input and the host consumes one, plus a second when `catch_up` is on and the
# next input is also past due. Returns the debt still owed at the last decision
# instant, seeded with a 10-tick (~83 ms) stall backlog.
func _settled_debt(catch_up: bool, ticks: int = 40) -> float:
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(10):
		stamps.append(now - TICK * float(10 - i))
	_seed(rc, stamps)
	var produced_at: float = now
	var debt: float = 0.0
	for _tick: int in range(ticks):
		if not rc._input_queue.is_empty() and rc._input_queue.front().host_timestamp <= now:
			rc._input_queue.pop_front()
			if catch_up and rc._front_overdue(now) > RemoteController._CATCH_UP_OVERDUE_S:
				rc._input_queue.pop_front()
		debt = rc._front_overdue(now)
		produced_at += TICK
		_seed(rc, [produced_at])
		now += TICK
	return debt


func test_backlog_converges_instead_of_persisting() -> void:
	# The regression this exists for. Catch-up must settle the debt at the
	# threshold it targets rather than carrying the stall's backlog forever.
	assert_lte(_settled_debt(true), RemoteController._CATCH_UP_OVERDUE_S,
			"a stall backlog converges to the catch-up threshold")


func test_single_pop_consumption_holds_the_backlog_forever() -> void:
	# The counterfactual that makes the fix meaningful. With one pop per tick,
	# production and consumption cancel exactly, so the debt a stall left is
	# INVARIANT: running five times as long works off none of it. That is the
	# shape the host telemetry showed — a queue that ratcheted up on every stall
	# and never came back down.
	var short_run: float = _settled_debt(false, 40)
	var long_run: float = _settled_debt(false, 200)
	assert_almost_eq(long_run, short_run, 1e-6,
			"single-pop debt is invariant — five times the ticks works off nothing")
	assert_gt(short_run, RemoteController._CATCH_UP_OVERDUE_S,
			"and it sits above the catch-up threshold the entire time")
	assert_gt(short_run, _settled_debt(true, 40),
			"catch-up strictly reduces the debt single-pop consumption would hold")


func test_catch_up_never_consumes_a_future_input() -> void:
	# The anti-exploit invariant. The stamp gate is what stops a client buying
	# speed by flooding inputs: debt is measured against `now`, so a queue full
	# of future stamps reports none however deep it is.
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(60):  # a flood, all stamped ahead
		stamps.append(now + TICK * float(i + 1))
	_seed(rc, stamps)
	assert_eq(rc._front_overdue(now), 0.0,
			"flooding future-stamped inputs buys no catch-up")


func test_empty_queue_reports_no_debt() -> void:
	var rc := _controller()
	assert_eq(rc._front_overdue(10.0), 0.0, "starvation is not debt")
