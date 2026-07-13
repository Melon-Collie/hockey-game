extends GutTest

# PlayerStats wire round-trip. to_array()/update_from_array() carry the
# host-authoritative counters (not toi_seconds, which is local-only). Guards the
# append-only wire order that STATS_PLAYER_RECORD_SIZE + PROTOCOL_VERSION track.

func _full() -> PlayerStats:
	var s := PlayerStats.new()
	s.goals = 1
	s.assists = 2
	s.shots_on_goal = 3
	s.hits = 4
	s.shots_blocked = 5
	s.hits_taken = 6
	s.takeaways = 7
	s.giveaways = 8
	s.faceoff_wins = 9
	s.faceoff_losses = 10
	s.game_winning_goals = 1
	s.toi_seconds = 123.4
	return s


func test_to_array_has_eleven_fields_in_order() -> void:
	var a := _full().to_array()
	assert_eq(a, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 1])


func test_round_trip_preserves_broadcast_counters() -> void:
	var restored := PlayerStats.from_array(_full().to_array())
	assert_eq(restored.goals, 1)
	assert_eq(restored.hits, 4)
	assert_eq(restored.hits_taken, 6)
	assert_eq(restored.takeaways, 7)
	assert_eq(restored.giveaways, 8)
	assert_eq(restored.faceoff_wins, 9)
	assert_eq(restored.faceoff_losses, 10)
	assert_eq(restored.game_winning_goals, 1)


func test_update_from_array_preserves_local_toi() -> void:
	# toi_seconds never crosses the wire; a decode must not zero a client's count.
	var s := PlayerStats.new()
	s.toi_seconds = 42.0
	s.update_from_array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0])
	assert_eq(s.faceoff_wins, 9)
	assert_eq(s.faceoff_losses, 10)
	assert_almost_eq(s.toi_seconds, 42.0, 0.001)


func test_to_dict_includes_new_stats() -> void:
	var d := _full().to_dict()
	assert_eq(d["hits_taken"], 6)
	assert_eq(d["takeaways"], 7)
	assert_eq(d["giveaways"], 8)
	assert_eq(d["faceoff_wins"], 9)
	assert_eq(d["faceoff_losses"], 10)
	assert_eq(d["toi_seconds"], 123)  # rounded
