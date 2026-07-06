class_name BugReporter extends RefCounted

# Posts a bug-report row to Supabase via fire-and-forget HTTPRequest. The
# caller (BugReportDialog) listens to submit_completed for the result so the
# UI can show real success / failure / rate-limit feedback rather than a
# fixed "thank you" timer.
#
# Rate-limit and length-cap state lives at class scope so multiple dialog
# instances (or rapid open/close cycles) share one window. Both are
# defense-in-depth against a buggy build or a hostile client spamming the
# table — the publishable Supabase key only authorizes INSERT on bug_reports
# (no SELECT/UPDATE/DELETE), so spam can't be cleaned up server-side. A
# server-side CHECK constraint (sql/bug_reports.sql) caps row size as a backstop;
# RLS still has to be correctly configured on the table (verify in dashboard).

const RATE_LIMIT_SEC: float = 60.0
const MAX_DESCRIPTION_CHARS: int = 2000
const MAX_CRASH_LOG_CHARS: int = 8000  # cap on the previous-session log tail shipped with a crash report

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
		# Identity is the Steam id (0 in offline / free-play, i.e. anonymous).
		"steam_id": SteamManager.steam_id,
		"player_name": PlayerPrefs.player_name,
		"game_version": BuildInfo.VERSION,
		"platform": OS.get_name(),
		"description": trimmed,
		"telemetry": _telemetry_snapshot(telemetry),
	}
	_post(SupabaseConfig.URL + "/rest/v1/bug_reports", body)


# Auto-submitted by CrashWatch on the launch AFTER an unclean shutdown. Unlike
# submit(): no human description, and it deliberately BYPASSES the manual-report
# rate limit — it's a once-per-launch automated report we don't want suppressed
# by a recent manual submit. The previous run's breadcrumb + log tail ride in the
# telemetry blob (no bug_reports schema change — same trick as build_id).
func submit_crash(breadcrumb: Dictionary, log_tail: String) -> void:
	var summary: String = "scene=%s phase=%s v=%s" % [
		breadcrumb.get("scene", "?"),
		breadcrumb.get("phase", "?"),
		breadcrumb.get("version", BuildInfo.VERSION)]
	var body: Dictionary = {
		"steam_id": SteamManager.steam_id,
		"player_name": PlayerPrefs.player_name,
		"game_version": String(breadcrumb.get("version", BuildInfo.VERSION)),
		"platform": OS.get_name(),
		"description": "[CRASH] " + summary,
		"telemetry": {
			"crash": true,
			"build_id": SteamManager.get_app_build_id(),
			"breadcrumb": breadcrumb,
			"log_tail": log_tail.left(MAX_CRASH_LOG_CHARS),
		},
	}
	_post(SupabaseConfig.URL + "/rest/v1/bug_reports", body)


func _telemetry_snapshot(telemetry: NetworkTelemetry) -> Dictionary:
	# build_id lives inside this telemetry JSON blob (not a top-level column) so
	# it needs no bug_reports schema change. It pins the exact Steam build a
	# report came from (0 for dev), and is always present even without net stats.
	var snapshot: Dictionary = {"build_id": SteamManager.get_app_build_id()}
	if telemetry == null:
		return snapshot
	snapshot["world_state_hz"] = telemetry.world_state_hz
	snapshot["input_hz"] = telemetry.input_hz
	snapshot["reconcile_per_sec"] = telemetry.reconcile_per_sec
	snapshot["reconcile_magnitude_avg"] = telemetry.reconcile_magnitude_avg
	snapshot["packet_loss_pct"] = telemetry.packet_loss_pct
	snapshot["jitter_p95_ms"] = telemetry.jitter_p95_ms
	return snapshot


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
