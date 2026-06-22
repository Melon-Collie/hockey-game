class_name NetworkSessionReporter extends RefCounted

# Fire-and-forget POST of one network-quality row per online game to Supabase's
# network_sessions table, called at game-over (mirrors CareerStatsReporter).
# This is the playtesting payoff: F3 shows a tester's live connection, but only
# they can see it — this ships the session's worst/typical numbers back so the
# whole tester pool can be aggregated to find what actually causes bad netcode.
#
# Gating (the caller, GameManager._on_game_over, applies the same privacy/mode
# gates it uses for career stats) plus our own MIN_DURATION_SEC floor so a
# rage-quit warmup doesn't post a meaningless 2-second row.

const MIN_DURATION_SEC: int = 30


# `role` is "host" / "client"; `net_sim_active` flags dev sessions running
# artificial lag (NetworkSimManager) so they can be excluded from analysis.
func report(summary: NetworkSessionSummary, role: String, net_sim_active: bool) -> void:
	if summary == null or summary.seconds < MIN_DURATION_SEC:
		return
	# Identity / filter fields are top-level columns; the evolving metric set
	# (every "<key>_max/_avg/_min" plus felt-lag markers) rides in one jsonb
	# column so adding a metric never requires an ALTER TABLE. Mirrors how
	# bug_reports stores its telemetry blob.
	var body: Dictionary = {
		"uuid": PlayerPrefs.player_uuid,
		"steam_id": SteamManager.steam_id,
		"player_name": PlayerPrefs.player_name,
		"game_version": BuildInfo.VERSION,
		"platform": OS.get_name(),
		"role": role,
		"net_sim_active": net_sim_active,
		"duration_sec": summary.seconds,
		"felt_lag_count": summary.felt_lag_count,
		"metrics": summary.to_dict(),
	}
	_post(SupabaseConfig.URL + "/rest/v1/network_sessions", body)


func _post(url: String, body: Dictionary) -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		if code < 200 or code >= 300:
			push_warning("NetworkSessionReporter: HTTP %d" % code)
		req.queue_free()
	)
	var err: Error = req.request(url, _headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		push_warning("NetworkSessionReporter: request failed: %s" % error_string(err))
		req.queue_free()


func _headers() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + SupabaseConfig.ANON_KEY,
		"Authorization: Bearer " + SupabaseConfig.ANON_KEY,
		"Content-Type: application/json",
		"Prefer: return=minimal",
	])
