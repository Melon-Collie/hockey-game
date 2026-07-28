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


func test_wire_round_trip() -> void:
	var e := ShotEvent.make(42, 1, Vector3(2.5, 0.0, -18.25), 0.23,
			ShotEvent.Outcome.BLOCKED, ShotEvent.ShotType.TIP, false, 3, 12.5)
	var r := ShotEvent.from_array(e.to_array())
	assert_eq(r.shooter_peer, 42)
	assert_eq(r.team_id, 1)
	assert_almost_eq(r.x, 2.5, 0.0001)
	assert_almost_eq(r.z, -18.25, 0.0001)
	assert_almost_eq(r.xg, 0.23, 0.0001)
	assert_eq(r.outcome, ShotEvent.Outcome.BLOCKED)
	assert_eq(r.shot_type, ShotEvent.ShotType.TIP)
	assert_false(r.on_net)
	assert_eq(r.period, 3)
	assert_almost_eq(r.clock_s, 12.5, 0.0001)


func test_from_array_rejects_malformed() -> void:
	assert_null(ShotEvent.from_array([]), "empty row is rejected")
	assert_null(ShotEvent.from_array([1, 2, 3]), "short row is rejected")


func test_list_round_trip() -> void:
	var events: Array[ShotEvent] = [
		ShotEvent.make(1, 0, Vector3(1.0, 0.0, 2.0), 0.1,
				ShotEvent.Outcome.GOAL, ShotEvent.ShotType.SHOT, true, 1, 100.0),
		ShotEvent.make(2, 1, Vector3(3.0, 0.0, 4.0), 0.2,
				ShotEvent.Outcome.MISSED, ShotEvent.ShotType.ONE_TIMER, false, 2, 50.0),
	]
	var decoded := ShotEvent.decode_list(ShotEvent.encode_list(events))
	assert_eq(decoded.size(), 2)
	assert_eq(decoded[0].outcome, ShotEvent.Outcome.GOAL)
	assert_eq(decoded[1].shooter_peer, 2)
	assert_eq(decoded[1].shot_type, ShotEvent.ShotType.ONE_TIMER)


func test_decode_list_skips_bad_rows() -> void:
	# A version-skewed / forged payload must not script-error the decode walk.
	var good := ShotEvent.make(1, 0, Vector3.ZERO, 0.1,
			ShotEvent.Outcome.SAVED, ShotEvent.ShotType.SHOT, true, 1, 0.0)
	var decoded := ShotEvent.decode_list([good.to_array(), [1, 2], "junk", good.to_array()])
	assert_eq(decoded.size(), 2, "malformed rows are skipped, valid ones survive")


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


# ── Stored-row round trip (Supabase / .mreplay footer -> analytics views) ────

func test_from_row_reads_the_stored_shape() -> void:
	var stored := ShotEvent.make(5, 1, Vector3(3.5, 0.0, 22.0), 0.31,
			ShotEvent.Outcome.GOAL, ShotEvent.ShotType.ONE_TIMER, true, 2, 210.0).to_dict()
	var e := ShotEvent.from_row(stored)
	assert_eq(e.team_id, 1)
	assert_almost_eq(e.x, 3.5, 0.0001)
	assert_almost_eq(e.z, 22.0, 0.0001)
	assert_almost_eq(e.xg, 0.31, 0.0001)
	assert_eq(e.outcome, ShotEvent.Outcome.GOAL, "text outcome maps back to the enum")
	assert_eq(e.shot_type, ShotEvent.ShotType.ONE_TIMER)
	assert_true(e.on_net)
	assert_eq(e.period, 2)


func test_from_row_defaults_unknown_fields() -> void:
	# A row written by an older build must still render rather than erroring.
	var e := ShotEvent.from_row({})
	assert_eq(e.outcome, ShotEvent.Outcome.MISSED)
	assert_eq(e.shot_type, ShotEvent.ShotType.SHOT)
	assert_eq(e.period, 1)


func test_decode_rows_skips_non_dictionaries() -> void:
	var good := ShotEvent.make(1, 0, Vector3.ZERO, 0.2,
			ShotEvent.Outcome.SAVED, ShotEvent.ShotType.SHOT, true, 1, 0.0).to_dict()
	assert_eq(ShotEvent.decode_rows([good, "junk", 7, good]).size(), 2)


# ── Release context ──────────────────────────────────────────────────────────
# The goalie-situation columns exist so an EMPIRICAL xG can be fitted from our
# own logged play — location alone is not comparable to a public model, which
# has the context baked into its location term. These pin the two things a
# consumer relies on: the context survives both round trips, and a row written
# before the columns existed still decodes to the neutral "set, unscreened
# keeper" defaults rather than erroring or reading as missing.

func _with_context() -> ShotEvent:
	var e := ShotEvent.make(7, 1, Vector3(2.5, 0.0, -20.0), 0.31,
			ShotEvent.Outcome.GOAL, ShotEvent.ShotType.SHOT, true, 2, 88.5)
	e.goalie_stance = 5
	e.goalie_unset = 0.62
	e.goalie_radius = 1.41
	e.goalie_x = -0.33
	e.screen_delay = 0.125
	e.shooter_speed = 5.75
	e.since_last_save_s = 0.84
	e.puck_lateral_speed = 3.20
	return e


func test_context_survives_the_wire_round_trip() -> void:
	var r := ShotEvent.from_array(_with_context().to_array())
	assert_not_null(r, "a full-width record decodes")
	assert_eq(r.goalie_stance, 5)
	assert_almost_eq(r.goalie_unset, 0.62, 0.0001)
	assert_almost_eq(r.goalie_radius, 1.41, 0.0001)
	assert_almost_eq(r.goalie_x, -0.33, 0.0001)
	assert_almost_eq(r.screen_delay, 0.125, 0.0001)
	assert_almost_eq(r.shooter_speed, 5.75, 0.0001)
	assert_almost_eq(r.since_last_save_s, 0.84, 0.0001)
	assert_almost_eq(r.puck_lateral_speed, 3.20, 0.0001)


func test_context_survives_the_stored_row_round_trip() -> void:
	var e := ShotEvent.from_row(_with_context().to_dict())
	assert_eq(e.goalie_stance, 5)
	assert_almost_eq(e.goalie_unset, 0.62, 0.01)
	assert_almost_eq(e.screen_delay, 0.125, 0.001)
	assert_almost_eq(e.shooter_speed, 5.75, 0.01)
	assert_almost_eq(e.since_last_save_s, 0.84, 0.01)
	assert_almost_eq(e.puck_lateral_speed, 3.20, 0.01)


func test_pre_context_row_decodes_to_neutral_defaults() -> void:
	# A row stored before the migration. It must read as a set, unscreened keeper
	# with no prior save, not as missing data a query has to special-case.
	var old_row := {
		"team_id": 0, "x": 1.0, "z": -20.0, "xg": 0.1, "outcome": "saved",
		"shot_type": "shot", "on_net": true, "period": 1, "clock_s": 30.0,
	}
	var e := ShotEvent.from_row(old_row)
	assert_eq(e.goalie_stance, -1, "no goalie resolved")
	assert_eq(e.goalie_unset, 0.0, "reads as set")
	assert_eq(e.screen_delay, 0.0, "reads as clear sight")
	assert_eq(e.since_last_save_s, -1.0, "no prior save this game")
