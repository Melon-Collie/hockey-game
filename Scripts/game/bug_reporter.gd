class_name BugReporter extends RefCounted

# Posts a bug-report row to Supabase via fire-and-forget HTTPRequest. The
# caller (BugReportDialog) listens to submit_completed for the result so the
# UI can show real success / failure / rate-limit feedback rather than a
# fixed "thank you" timer.
#
# Rate-limit and length-cap state lives at class scope so multiple dialog
# instances (or rapid open/close cycles) share one window. Both are
# defense-in-depth against a buggy build or a hostile client spamming the
# table — the publishable Supabase key only authorizes INSERT/SELECT/UPDATE,
# not DELETE, so spam can't be cleaned up server-side. RLS still has to be
# correctly configured on the bug_reports table (verify in dashboard).

const RATE_LIMIT_SEC: float = 60.0
const MAX_DESCRIPTION_CHARS: int = 2000

# Negative seed so the very first submission of a session goes through —
# Time.get_ticks_msec() is non-negative, so any positive value would
# accidentally rate-limit a fresh process for ~RATE_LIMIT_SEC.
static var _last_submit_msec: int = -1_000_000

enum Result { SUCCESS, RATE_LIMITED, FAILED }

signal submit_completed(result: Result, http_code: int)


func submit(description: String, telemetry: NetworkTelemetry) -> void:
	var now_msec: int = Time.get_ticks_msec()
	if now_msec - _last_submit_msec < int(RATE_LIMIT_SEC * 1000.0):
		submit_completed.emit(Result.RATE_LIMITED, 0)
		return
	_last_submit_msec = now_msec

	var trimmed: String = description.left(MAX_DESCRIPTION_CHARS)
	var body: Dictionary = {
		"uuid": PlayerPrefs.player_uuid,
		"player_name": PlayerPrefs.player_name,
		"game_version": BuildInfo.VERSION,
		"platform": OS.get_name(),
		"description": trimmed,
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
		var ok: bool = code >= 200 and code < 300
		if not ok:
			push_warning("BugReporter: HTTP %d" % code)
		submit_completed.emit(Result.SUCCESS if ok else Result.FAILED, code)
		req.queue_free()
	)
	var err: Error = req.request(url, _headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		push_warning("BugReporter: request failed: %s" % error_string(err))
		submit_completed.emit(Result.FAILED, 0)
		req.queue_free()


func _headers() -> PackedStringArray:
	return PackedStringArray([
		"apikey: " + SupabaseConfig.ANON_KEY,
		"Authorization: Bearer " + SupabaseConfig.ANON_KEY,
		"Content-Type: application/json",
		"Prefer: return=minimal",
	])
