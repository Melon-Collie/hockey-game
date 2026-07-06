extends GutTest

# StatFeedRules — pure diff of consecutive PlayerStats snapshots onto HUD
# ticker events. Pins which counters toast, the goal-suppresses-SOG rule, and
# the reset (any decrease → no events) behavior the rebaseline path relies on.


func _stats(
		goals: int = 0, assists: int = 0, sog: int = 0, hits: int = 0,
		blocked: int = 0, takeaways: int = 0, giveaways: int = 0,
		faceoff_wins: int = 0) -> PlayerStats:
	var s := PlayerStats.new()
	s.goals = goals
	s.assists = assists
	s.shots_on_goal = sog
	s.hits = hits
	s.shots_blocked = blocked
	s.takeaways = takeaways
	s.giveaways = giveaways
	s.faceoff_wins = faceoff_wins
	return s


func test_no_change_yields_no_events() -> void:
	var events := StatFeedRules.feed_events(_stats(), _stats())
	assert_eq(events.size(), 0)


func test_each_ticker_stat_fires_its_event() -> void:
	assert_eq(StatFeedRules.feed_events(_stats(), _stats(0, 0, 1)),
			[StatFeedRules.EVENT_SHOT_ON_GOAL] as Array[StringName])
	assert_eq(StatFeedRules.feed_events(_stats(), _stats(0, 0, 0, 0, 1)),
			[StatFeedRules.EVENT_BLOCKED_SHOT] as Array[StringName])
	assert_eq(StatFeedRules.feed_events(_stats(), _stats(0, 0, 0, 1)),
			[StatFeedRules.EVENT_HIT] as Array[StringName])
	assert_eq(StatFeedRules.feed_events(_stats(), _stats(0, 0, 0, 0, 0, 1)),
			[StatFeedRules.EVENT_TAKEAWAY] as Array[StringName])
	assert_eq(StatFeedRules.feed_events(_stats(), _stats(0, 0, 0, 0, 0, 0, 0, 1)),
			[StatFeedRules.EVENT_FACEOFF_WIN] as Array[StringName])


func test_goal_and_assist_do_not_toast() -> void:
	# The goal banner + chyron own the goal moment.
	var events := StatFeedRules.feed_events(_stats(), _stats(1, 1))
	assert_eq(events.size(), 0)


func test_goal_suppresses_shot_on_goal_from_same_diff() -> void:
	# A confirmed goal increments SOG alongside goals; the SOG toast would
	# double-announce the goal.
	var events := StatFeedRules.feed_events(_stats(), _stats(1, 0, 1))
	assert_eq(events.size(), 0)


func test_sog_without_goal_still_toasts_alongside_other_events() -> void:
	var events := StatFeedRules.feed_events(_stats(), _stats(0, 0, 1, 1))
	assert_has(events, StatFeedRules.EVENT_SHOT_ON_GOAL)
	assert_has(events, StatFeedRules.EVENT_HIT)


func test_giveaway_and_hit_taken_do_not_toast() -> void:
	var now := _stats(0, 0, 0, 0, 0, 0, 1)
	now.hits_taken = 1
	assert_eq(StatFeedRules.feed_events(_stats(), now).size(), 0)


func test_any_decrease_means_reset_and_no_events() -> void:
	# Rematch zeroes the counters; a diff straddling the reset must not toast
	# even if another counter looks "increased" vs the stale baseline.
	var prev := _stats(2, 1, 5, 3, 1)
	var now := _stats(0, 0, 1)
	assert_eq(StatFeedRules.feed_events(prev, now).size(), 0)
