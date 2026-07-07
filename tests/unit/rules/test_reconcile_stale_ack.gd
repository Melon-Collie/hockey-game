extends GutTest

# ReconciliationRules.ack_is_new is the stale-ack gate for LocalController.reconcile.
#
# Context: the host broadcasts world state every physics tick but only advances
# its ack (last_processed_host_timestamp) when it pops a *due* client input.
# Inputs are stamped ~INPUT_LEAD ahead and arrive in 60Hz batches, so the ack
# stalls for whole ticks and consecutive broadcasts repeat the same value. The
# first reconcile at ack T matches its prediction snapshot and then trims that
# snapshot away, so re-processing a repeated ack finds no match, falls back to
# the live (prediction-lead-ahead) position, and fires a spurious correction —
# the false-reconcile churn seen on clean connections (reconcile_match_pct
# dropping well below 100% while RTT/loss are nominal).
#
# ack_is_new gates on a strictly-newer ack so only a genuinely fresh confirmed
# input drives a reconcile. Epsilon must absorb the 0.1ms wire-grid rounding of
# the ack so a re-sent value never reads as advanced.

const EPS: float = 1e-3  # PredictedState.TS_MATCH_EPSILON


func test_advanced_ack_is_new() -> void:
	# A clearly-later ack (one 120Hz tick, 8.33ms) is a fresh input to reconcile.
	assert_true(ReconciliationRules.ack_is_new(10.00833, 10.0, EPS),
			"an ack advanced by a full tick must count as new")


func test_repeated_ack_is_not_new() -> void:
	# The host re-broadcast the same ack — no new confirmed input.
	assert_false(ReconciliationRules.ack_is_new(10.0, 10.0, EPS),
			"an identical ack must NOT count as new (the stale-ack repeat case)")


func test_wire_quantized_repeat_is_not_new() -> void:
	# Same ack round-tripped through the 0.1ms wire grid differs by <=0.05ms.
	# Epsilon (1ms) must swallow it so a re-sent value never reads as advanced.
	var stored: float = 12.34567
	var requantized: float = round(stored * 10000.0) / 10000.0  # 0.1ms grid
	assert_false(ReconciliationRules.ack_is_new(requantized, stored, EPS),
			"wire-grid rounding of a repeated ack must not register as advancement")


func test_sub_epsilon_advance_is_not_new() -> void:
	# An advance smaller than epsilon is within wire-noise and must be ignored;
	# real ack steps are >= one input spacing (~8.33ms), far above epsilon.
	assert_false(ReconciliationRules.ack_is_new(10.0 + EPS * 0.5, 10.0, EPS),
			"an advance below epsilon must not count as new")


func test_first_ack_after_reset_is_new() -> void:
	# History is cleared on teleport / dead-puck lock and _last_reconcile_ack_ts
	# resets to 0. The first real ack of the session (a positive host time) must
	# be treated as new so reconcile resumes immediately.
	assert_true(ReconciliationRules.ack_is_new(842.5, 0.0, EPS),
			"first ack after a reset must count as new")


func test_repeat_then_advance_sequence() -> void:
	# Simulate the broadcast stream: T, T (repeat), T, T+tick. Only the first T
	# and the final advance should drive a reconcile; the repeats are skipped.
	var last: float = 0.0
	var acks: Array[float] = [10.0, 10.0, 10.0, 10.00833]
	var processed: Array[float] = []
	for ack: float in acks:
		if ReconciliationRules.ack_is_new(ack, last, EPS):
			processed.append(ack)
			last = ack
	assert_eq(processed.size(), 2,
			"only the first ack and the advanced ack drive a reconcile; repeats are skipped")
	assert_almost_eq(processed[0], 10.0, EPS)
	assert_almost_eq(processed[1], 10.00833, EPS)
