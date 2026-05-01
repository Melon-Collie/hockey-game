class_name BugReporter extends RefCounted

func submit(description: String, telemetry: NetworkTelemetry) -> void:
	var body: Dictionary = {
		"uuid": PlayerPrefs.player_uuid,
		"player_name": PlayerPrefs.player_name,
		"game_version": BuildInfo.VERSION,
		"platform": OS.get_name(),
		"description": description,
		"telemetry": _telemetry_snapshot(telemetry),
	}
	_post(SupabaseConfig.URL + "/rest/v1/bug_reports", body)


func _telemetry_snapshot(telemetry: NetworkTelemetry) -> Dictionary:
	if telemetry == null:
		return {}
	return {
		"world_state_hz": telemetry.world_state_hz,
		"input_hz": telemetry.input_hz,
		"reconcile_per_sec": telemetry.reconcile_per_sec,
		"reconcile_magnitude_avg": telemetry.reconcile_magnitude_avg,
		"packet_loss_pct": telemetry.packet_loss_pct,
		"jitter_p95_ms": telemetry.jitter_p95_ms,
	}


func _post(url: String, body: Dictionary) -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request_completed.connect(func(_result: int, code: int, _response_headers: PackedStringArray, _body: PackedByteArray) -> void:
		if code < 200 or code >= 300:
			push_warning("BugReporter: HTTP %d" % code)
		req.queue_free()
	)
	var err: Error = req.request(url, _headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		push_warning("BugReporter: request failed: %s" % error_string(err))
		req.queue_free()


func _headers() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + SupabaseConfig.ANON_KEY,
		"Authorization: Bearer " + SupabaseConfig.ANON_KEY,
		"Content-Type: application/json",
		"Prefer: return=minimal",
	])
