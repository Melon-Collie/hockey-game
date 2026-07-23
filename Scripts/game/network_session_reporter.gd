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

# Local mirror of every posted row, so a tester (or the dev) can grab their own
# session data — Discord paste, bug report, LLM diagnosis — without a Supabase
# round-trip, and so a failed POST still leaves the data on disk. Rolling
# window; oldest dumps are purged.
const DUMP_DIR: String = "user://net_sessions"
const DUMP_KEEP: int = 10


# `role` is "host" / "client"; `net_sim_active` flags dev sessions running
# artificial lag (NetworkSimManager) so they can be excluded from analysis.
# `game_id` is the cross-peer match UUID (GameManager mints it and ships it to
# every peer — the same id career_stats rows carry), so the host row and its
# clients' rows join into one per-match picture (`match_health` view).
# `end_reason` is how the session ended: "completed" (game over), "quit"
# (local player left mid-game), or a client-side abnormal end ("host_lost",
# "host_ended", "kicked") — the sessions a game-over-only reporter would miss.
func report(summary: NetworkSessionSummary, role: String, net_sim_active: bool,
		game_id: String, end_reason: String) -> void:
	if summary == null or summary.seconds < MIN_DURATION_SEC:
		return
	# Identity / filter fields are top-level columns; the evolving metric set
	# (every "<key>_max/_avg/_min/_total" plus felt-lag markers) rides in one
	# jsonb column so adding a metric never requires an ALTER TABLE. Mirrors
	# how bug_reports stores its telemetry blob.
	# JSON-null for an absent game_id (a String/null ternary isn't type-compatible).
	var game_id_value: Variant = null
	if not game_id.is_empty():
		game_id_value = game_id
	var body: Dictionary = {
		"steam_id": SteamManager.steam_id,
		"player_name": PlayerPrefs.player_name,
		"game_version": BuildInfo.VERSION,
		"platform": OS.get_name(),
		"role": role,
		"net_sim_active": net_sim_active,
		"duration_sec": summary.seconds,
		"felt_lag_count": summary.felt_lag_count,
		"game_id": game_id_value,
		"end_reason": end_reason,
		# Bounded: the table rejects rows whose compressed metrics jsonb
		# reaches 64 KiB (network_sessions_sane_sizes) — the first playtest's
		# client rows all 400'd on it. The bounded serializer sheds marker
		# detail (never aggregates or counts) until the payload fits.
		"metrics": summary.to_dict_bounded(),
	}
	_write_local_dump(body, role)
	_post(SupabaseConfig.URL + "/rest/v1/network_sessions", body)


# Best-effort local copy of the payload (fails silently, like the POST).
# Filename sorts chronologically so the purge can drop the oldest.
func _write_local_dump(body: Dictionary, role: String) -> void:
	if DirAccess.make_dir_recursive_absolute(DUMP_DIR) != OK:
		return
	_purge_old_dumps()
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = "%s/%s_%s.json" % [DUMP_DIR, stamp, role]
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(body, "\t"))
		f.close()


func _purge_old_dumps() -> void:
	var dir: DirAccess = DirAccess.open(DUMP_DIR)
	if dir == null:
		return
	var files: Array[String] = []
	for fname: String in dir.get_files():
		if fname.ends_with(".json"):
			files.append(fname)
	files.sort()
	# keep - 1 because we're about to add a new file.
	while files.size() > DUMP_KEEP - 1:
		dir.remove(files.pop_front())


func _post(url: String, body: Dictionary) -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request_completed.connect(func(_result: int, code: int, _hdrs: PackedStringArray, resp: PackedByteArray) -> void:
		if code < 200 or code >= 300:
			# Include the response body: PostgREST names the offending column /
			# constraint there (e.g. PGRST204 "column ... not found"), and a bare
			# code alone can't distinguish a schema-drift 400 from a size-cap one.
			var detail: String = resp.get_string_from_utf8().strip_edges()
			if detail.length() > 500:
				detail = detail.substr(0, 500) + "…"
			if detail.is_empty():
				push_warning("NetworkSessionReporter: HTTP %d" % code)
			else:
				push_warning("NetworkSessionReporter: HTTP %d — %s" % [code, detail])
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
