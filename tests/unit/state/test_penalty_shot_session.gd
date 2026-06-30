extends GutTest

# PenaltyShotSession — tallies makes across a fixed-length penalty-shot drill.

func test_starts_empty() -> void:
	var s := PenaltyShotSession.new(10)
	assert_eq(s.attempts_taken, 0)
	assert_eq(s.makes, 0)
	assert_eq(s.remaining(), 10)
	assert_false(s.is_complete())
	assert_eq(s.current_attempt_number(), 1)


func test_record_counts_makes_and_misses() -> void:
	var s := PenaltyShotSession.new(10)
	s.record(true)
	s.record(false)
	s.record(true)
	assert_eq(s.attempts_taken, 3)
	assert_eq(s.makes, 2)
	assert_eq(s.misses(), 1)
	assert_eq(s.remaining(), 7)
	assert_eq(s.current_attempt_number(), 4)


func test_completes_after_total_attempts() -> void:
	var s := PenaltyShotSession.new(3)
	s.record(true)
	s.record(false)
	assert_false(s.is_complete())
	s.record(true)
	assert_true(s.is_complete())
	assert_eq(s.remaining(), 0)
	assert_eq(s.summary(), "2 / 3")


func test_current_attempt_number_clamps_at_total() -> void:
	var s := PenaltyShotSession.new(2)
	s.record(true)
	s.record(true)
	# After the last shot it shouldn't read as "attempt 3 of 2".
	assert_eq(s.current_attempt_number(), 2)


func test_restart_clears_tally() -> void:
	var s := PenaltyShotSession.new(5)
	s.record(true)
	s.record(true)
	s.restart()
	assert_eq(s.attempts_taken, 0)
	assert_eq(s.makes, 0)
	assert_false(s.is_complete())


func test_total_is_floored_at_one() -> void:
	var s := PenaltyShotSession.new(0)
	assert_eq(s.total_attempts, 1)
