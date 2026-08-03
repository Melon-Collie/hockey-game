extends GutTest

# StatsSyncGate coalesces the 120 Hz contact-path stat-sync requests into at
# most one flush per broadcast interval. Pins: flush only when dirty AND the
# broadcast cadence is due, the flush consumes the flag (flush-once), repeated
# marks coalesce, and an immediate phase-transition sync's clear() supersedes a
# pending contact-path flush.

var gate: StatsSyncGate


func before_each() -> void:
	gate = StatsSyncGate.new()


func test_clean_gate_never_flushes() -> void:
	assert_false(gate.should_flush(true))
	assert_false(gate.should_flush(false))


func test_dirty_but_not_due_holds_the_flag() -> void:
	gate.mark_dirty()
	assert_false(gate.should_flush(false), "no flush off the broadcast cadence")
	assert_true(gate.is_dirty(), "flag survives a not-due tick")
	assert_true(gate.should_flush(true), "and flushes on the next due tick")


func test_flush_consumes_the_flag() -> void:
	gate.mark_dirty()
	assert_true(gate.should_flush(true))
	assert_false(gate.should_flush(true), "flush-once: the second due tick has nothing pending")


func test_multiple_marks_coalesce_into_one_flush() -> void:
	gate.mark_dirty()
	gate.mark_dirty()
	gate.mark_dirty()
	assert_true(gate.should_flush(true), "one flush covers every mark since the last")
	assert_false(gate.should_flush(true))


func test_clear_supersedes_a_pending_flush() -> void:
	# An immediate sync (goal / period end / roster change) already shipped the
	# fresh stats — its clear() must cancel the pending contact-path flush so
	# the next broadcast tick doesn't re-encode redundantly.
	gate.mark_dirty()
	gate.clear()
	assert_false(gate.should_flush(true))
