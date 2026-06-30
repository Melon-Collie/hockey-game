class_name CareerStatsReporter extends RefCounted

func report(record: PlayerRecord, goals_for: int, goals_against: int, outcome: String,
		game_id: String, team_id: int, period_scores: Array, num_periods: int) -> void:
	var body: Dictionary = record.stats.to_dict()
	# steam_id is the career identity (cross-machine). Career stats only write in
	# online (Steam) sessions, so a valid SteamID64 is always available here.
	body["steam_id"] = SteamManager.steam_id
	body["player_name"] = record.display_name()
	body["game_version"] = BuildInfo.VERSION
	body["goals_for"] = goals_for
	body["goals_against"] = goals_against
	body["outcome"] = outcome
	body["game_id"] = game_id
	body["team_id"] = team_id
	body["period_scores"] = period_scores
	body["num_periods"] = num_periods
	_post(SupabaseConfig.URL + "/rest/v1/career_stats", body)


# Calls the recent_games_for RPC and returns up to `limit` recent games the
# given player participated in, newest first. Each game row carries nested
# players JSON, period_scores, and the home/away final score. Used by the
# Career screen's Recent Games tab. Empty array on error or no games.
func fetch_recent_games(steam_id: int, limit: int, callback: Callable) -> void:
	_call_rpc("recent_games_for", {
		"player_steam_id": steam_id,
		"game_limit": limit,
	}, callback)


func fetch_totals(callback: Callable) -> void:
	var url: String = "%s/rest/v1/career_totals?steam_id=eq.%d" % [
		SupabaseConfig.URL, SteamManager.steam_id
	]
	_fetch(url, callback)


func _post(url: String, body: Dictionary) -> void:
	_fire(url, HTTPClient.METHOD_POST, body)


func _fire(url: String, method: HTTPClient.Method, body: Dictionary) -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		if code < 200 or code >= 300:
			push_warning("CareerStatsReporter: HTTP %d on %s" % [code, url])
		req.queue_free()
	)
	var err: Error = req.request(url, _write_headers(), method, JSON.stringify(body))
	if err != OK:
		push_warning("CareerStatsReporter: request failed: %s" % error_string(err))
		req.queue_free()


# PostgREST RPC: POST with a JSON body, parse the JSON-array response. Used
# by fetch_recent_games. Calls back with the parsed Array (empty on error).
func _call_rpc(name: String, body: Dictionary, callback: Callable) -> void:
	var url: String = "%s/rest/v1/rpc/%s" % [SupabaseConfig.URL, name]
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, body_bytes: PackedByteArray) -> void:
		if code == 200:
			var parsed: Variant = JSON.parse_string(body_bytes.get_string_from_utf8())
			if parsed is Array:
				callback.call(parsed as Array)
			else:
				callback.call([])
		else:
			push_warning("CareerStatsReporter: RPC %s returned HTTP %d" % [name, code])
			callback.call([])
		req.queue_free()
	)
	var err: Error = req.request(url, _write_headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		push_warning("CareerStatsReporter: RPC %s failed: %s" % [name, error_string(err)])
		req.queue_free()
		callback.call([])


func _fetch(url: String, callback: Callable) -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, body_bytes: PackedByteArray) -> void:
		if code == 200:
			var parsed: Variant = JSON.parse_string(body_bytes.get_string_from_utf8())
			if parsed is Array and not (parsed as Array).is_empty():
				callback.call((parsed as Array)[0] as Dictionary)
			else:
				callback.call({})
		else:
			push_warning("CareerStatsReporter: GET returned HTTP %d" % code)
			callback.call({})
		req.queue_free()
	)
	var err: Error = req.request(url, _read_headers())
	if err != OK:
		push_warning("CareerStatsReporter: GET failed: %s" % error_string(err))
		req.queue_free()
		callback.call({})


func _write_headers() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + SupabaseConfig.ANON_KEY,
		"Authorization: Bearer " + SupabaseConfig.ANON_KEY,
		"Content-Type: application/json",
		"Prefer: return=minimal",
	])


func _read_headers() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + SupabaseConfig.ANON_KEY,
		"Authorization: Bearer " + SupabaseConfig.ANON_KEY,
	])
