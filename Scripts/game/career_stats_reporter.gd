class_name CareerStatsReporter extends RefCounted

func report(record: PlayerRecord, goals_for: int, goals_against: int, outcome: String,
		game_id: String, team_id: int, period_scores: Array, num_periods: int,
		team_sog_for: int, team_sog_against: int) -> void:
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
	# Team shots-on-goal for/against this game — the PDO denominators (on-ice
	# SH% = goals_for / team_sog_for, SV% = 1 − goals_against / team_sog_against).
	# Team quantities like goals_for, so they carry on every player's row.
	body["team_sog_for"] = team_sog_for
	body["team_sog_against"] = team_sog_against
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
	req.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, resp: PackedByteArray) -> void:
		if code < 200 or code >= 300:
			push_warning("CareerStatsReporter: HTTP %d on %s%s" % [code, url, _body_detail(resp)])
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
			push_warning("CareerStatsReporter: RPC %s returned HTTP %d%s" % [name, code, _body_detail(body_bytes)])
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
			push_warning("CareerStatsReporter: GET returned HTTP %d%s" % [code, _body_detail(body_bytes)])
			callback.call({})
		req.queue_free()
	)
	var err: Error = req.request(url, _read_headers())
	if err != OK:
		push_warning("CareerStatsReporter: GET failed: %s" % error_string(err))
		req.queue_free()
		callback.call({})


# Truncated, log-safe rendering of an error response body. PostgREST names the
# offending column / constraint there (e.g. PGRST204 "column ... not found"),
# so a bare HTTP code alone can't distinguish schema drift from a size-cap
# rejection. Returns " — <detail>" (leading separator) or "" when empty.
func _body_detail(bytes: PackedByteArray) -> String:
	var detail: String = bytes.get_string_from_utf8().strip_edges()
	if detail.is_empty():
		return ""
	if detail.length() > 500:
		detail = detail.substr(0, 500) + "…"
	return " — " + detail


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
