class_name CareerStatsReporter extends RefCounted

func report(record: PlayerRecord, goals_for: int, goals_against: int, outcome: String,
		game_id: String, team_id: int, period_scores: Array, num_periods: int) -> void:
	var body: Dictionary = record.stats.to_dict()
	body["uuid"] = PlayerPrefs.player_uuid
	# steam_id is the career identity (cross-machine); uuid stays for legacy rows
	# and bug reports. Career stats only write in online (Steam) sessions, so a
	# valid SteamID64 is always available here.
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
# given player UUID participated in, newest first. Each game row carries
# nested players JSON, period_scores, and the home/away final score. Used by
# the Career screen's Recent Games tab. Empty array on error or no games.
func fetch_recent_games(steam_id: int, limit: int, callback: Callable) -> void:
	_call_rpc("recent_games_for", {
		"player_steam_id": steam_id,
		"game_limit": limit,
	}, callback)


# One-time backfill: stamp this machine's legacy uuid-keyed rows (steam_id IS
# NULL) with the now-known SteamID64 so old and new games unify under one
# identity. Only the local machine knows its own uuid↔steam_id mapping, so it
# only ever patches its own rows. Latches on success — a failed PATCH leaves
# steam_id_linked false so the next session retries rather than orphaning
# history forever.
func migrate_to_steam_id(uuid: String, steam_id: int) -> void:
	if PlayerPrefs.steam_id_linked or steam_id == 0:
		return
	var url: String = "%s/rest/v1/career_stats?uuid=eq.%s&steam_id=is.null" % [SupabaseConfig.URL, uuid]
	_patch(url, {"steam_id": steam_id}, func(ok: bool) -> void:
		if ok:
			PlayerPrefs.steam_id_linked = true
			PlayerPrefs.save()
	)


func fetch_totals(callback: Callable) -> void:
	var url: String = "%s/rest/v1/career_totals?steam_id=eq.%d" % [
		SupabaseConfig.URL, SteamManager.steam_id
	]
	_fetch(url, callback)


func _post(url: String, body: Dictionary) -> void:
	_fire(url, HTTPClient.METHOD_POST, body)


func _patch(url: String, body: Dictionary, on_done: Callable = Callable()) -> void:
	_fire(url, HTTPClient.METHOD_PATCH, body, on_done)


# on_done, when valid, is called with a single bool: true on a 2xx response,
# false on a non-2xx or a failed-to-dispatch request.
func _fire(url: String, method: HTTPClient.Method, body: Dictionary, on_done: Callable = Callable()) -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		var ok: bool = code >= 200 and code < 300
		if not ok:
			push_warning("CareerStatsReporter: HTTP %d on %s" % [code, url])
		if on_done.is_valid():
			on_done.call(ok)
		req.queue_free()
	)
	var err: Error = req.request(url, _write_headers(), method, JSON.stringify(body))
	if err != OK:
		push_warning("CareerStatsReporter: request failed: %s" % error_string(err))
		if on_done.is_valid():
			on_done.call(false)
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
