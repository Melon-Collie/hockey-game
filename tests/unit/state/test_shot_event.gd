extends GutTest

# ShotEvent — the shot-map / heatmap record. Pure data; guards the Supabase row
# shape (to_dict keys + enum→text mapping) the shot_events table depends on.


func test_make_populates_fields() -> void:
	var e := ShotEvent.make(42, 1, Vector3(2.0, 0.0, -18.0), 0.23,
			ShotEvent.Outcome.SAVED, ShotEvent.ShotType.ONE_TIMER, true, 2, 340.5)
	assert_eq(e.shooter_peer, 42)
	assert_eq(e.team_id, 1)
	assert_almost_eq(e.x, 2.0, 0.0001)
	assert_almost_eq(e.z, -18.0, 0.0001)
	assert_almost_eq(e.xg, 0.23, 0.0001)
	assert_eq(e.outcome, ShotEvent.Outcome.SAVED)
	assert_eq(e.shot_type, ShotEvent.ShotType.ONE_TIMER)
	assert_true(e.on_net)
	assert_eq(e.period, 2)
	assert_almost_eq(e.clock_s, 340.5, 0.0001)


func test_outcome_and_type_keys() -> void:
	assert_eq(ShotEvent.make(0, 0, Vector3.ZERO, 0.0,
			ShotEvent.Outcome.GOAL, ShotEvent.ShotType.SHOT, true, 1, 0.0).outcome_key(), "goal")
	assert_eq(ShotEvent.make(0, 0, Vector3.ZERO, 0.0,
			ShotEvent.Outcome.BLOCKED, ShotEvent.ShotType.TIP, false, 1, 0.0).type_key(), "tip")


func test_to_dict_row_shape() -> void:
	var d := ShotEvent.make(7, 0, Vector3(-1.25, 0.0, 20.4), 0.176,
			ShotEvent.Outcome.MISSED, ShotEvent.ShotType.SHOT, false, 3, 12.34).to_dict()
	assert_eq(d["team_id"], 0)
	assert_almost_eq(d["x"], -1.25, 0.0001)
	assert_almost_eq(d["z"], 20.4, 0.0001)
	assert_almost_eq(d["xg"], 0.176, 0.0001)
	assert_eq(d["outcome"], "missed")
	assert_eq(d["shot_type"], "shot")
	assert_eq(d["on_net"], false)
	assert_eq(d["period"], 3)
	# steam_id / game_id are stamped by the poster, not the event.
	assert_false(d.has("steam_id"))
	assert_false(d.has("game_id"))
