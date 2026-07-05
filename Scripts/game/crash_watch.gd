extends Node

# CrashWatch — captures hard crashes that GDScript cannot catch in-process.
#
# A native crash (e.g. a physics abort, or a force-kill) tears the process down
# before any script handler runs, so there is no in-process hook. Instead we
# detect the crash on the FOLLOWING launch:
#
#   #1 Dirty-shutdown sentinel — drop a sentinel file at boot, delete it on a
#      CLEAN exit (window close / quit). A hard crash never reaches the clean-exit
#      path, so the sentinel survives; the next launch sees it, reads the previous
#      session's log tail + breadcrumb, and POSTs a crash report through
#      BugReporter (same Supabase path as manual reports). File logging
#      (project.godot [debug] file_logging → user://logs) keeps the engine's own
#      crash backtrace, which we ship on the next run — the only way to recover a
#      native crash's trace.
#
#   #2 Breadcrumb — every few seconds overwrite user://last_state.json with the
#      current scene / phase / net context, so a crash report says WHAT was
#      happening, not just that it happened. We snapshot the PREVIOUS run's
#      breadcrumb at boot before our own timer overwrites it.
#
# Skipped entirely under --headless (CI / GUT): no sentinel, no breadcrumb, no
# network — so the test suite never leaves state or fires a report.

const SENTINEL_PATH: String = "user://session.lock"
const BREADCRUMB_PATH: String = "user://last_state.json"
const LOG_DIR: String = "user://logs"
const BREADCRUMB_INTERVAL_SEC: float = 3.0
const CRASH_REPORT_DELAY_SEC: float = 4.0  # let the tree/network settle before POSTing
const LOG_TAIL_BYTES: int = 6000           # cap of previous-log tail shipped with a report

var _phase: int = -1
var _breadcrumb_accum: float = 0.0
var _session_start_unix: int = 0
var _active: bool = false
# Held so the fire-and-forget crash POST (and its HTTPRequest child) outlive the call.
var _reporter: BugReporter = null


func _ready() -> void:
	# Dedicated headless / CI runs neither crash-report nor litter user:// state.
	if OS.has_feature("headless"):
		return
	_active = true
	_session_start_unix = int(Time.get_unix_time_from_system())
	# Snapshot the previous run's last breadcrumb BEFORE our timer overwrites it,
	# and read the stale sentinel BEFORE we replace it with this run's.
	var prev_breadcrumb: Dictionary = _read_json(BREADCRUMB_PATH)
	var crashed: bool = FileAccess.file_exists(SENTINEL_PATH)
	_write_sentinel()
	# Track live phase for the breadcrumb without poking GameManager internals.
	if GameManager.has_signal("phase_changed"):
		GameManager.phase_changed.connect(_on_phase_changed)
	_write_breadcrumb()
	# Respect the telemetry opt-out: a crash report ships steam_id, player name, a
	# breadcrumb, and a log tail (which may contain peer names / lobby ids), so it's
	# gated on the same PlayerPrefs.share_gameplay_stats flag as career + network
	# session rows. Opting out still detects the crash (sentinel logic above) — it
	# just doesn't phone home. Autoload order guarantees PlayerPrefs is ready here.
	if crashed and PlayerPrefs.share_gameplay_stats:
		get_tree().create_timer(CRASH_REPORT_DELAY_SEC).timeout.connect(
				_report_previous_crash.bind(prev_breadcrumb))


func _process(delta: float) -> void:
	if not _active:
		return
	_breadcrumb_accum += delta
	if _breadcrumb_accum >= BREADCRUMB_INTERVAL_SEC:
		_breadcrumb_accum = 0.0
		_write_breadcrumb()


func _notification(what: int) -> void:
	# Clean exit: window close (X / Alt+F4) or tree teardown on quit(). An autoload
	# only leaves the tree at app shutdown, so EXIT_TREE here is a real quit, not a
	# scene change. A hard crash fires none of these → the sentinel survives and
	# the next launch reports it.
	if _active and (what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE):
		_clear_sentinel()


func _on_phase_changed(new_phase: int) -> void:
	_phase = new_phase


# ── Sentinel ──────────────────────────────────────────────────────────────────
func _write_sentinel() -> void:
	var f: FileAccess = FileAccess.open(SENTINEL_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"version": BuildInfo.VERSION,
		"started_unix": _session_start_unix,
	}))
	f.close()


func _clear_sentinel() -> void:
	if not FileAccess.file_exists(SENTINEL_PATH):
		return
	var d: DirAccess = DirAccess.open("user://")
	if d != null:
		d.remove(SENTINEL_PATH.get_file())


# ── Breadcrumb ────────────────────────────────────────────────────────────────
func _write_breadcrumb() -> void:
	var f: FileAccess = FileAccess.open(BREADCRUMB_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_context()))
	f.close()


# Pragmatic live context. Every accessor is null-safe (verified) so this can run
# at any moment without itself erroring — CrashWatch must never be the crash.
func _context() -> Dictionary:
	var scene_name: String = "?"
	var cur: Node = get_tree().current_scene
	if cur != null:
		scene_name = cur.name
	return {
		"ts": Time.get_datetime_string_from_system(true),
		"uptime_sec": int(Time.get_unix_time_from_system()) - _session_start_unix,
		"scene": scene_name,
		"phase": _phase_name(),
		"version": BuildInfo.VERSION,
		"build_id": SteamManager.get_app_build_id(),
		"platform": OS.get_name(),
		"free_play": NetworkManager.is_free_play_mode,
		"offline": NetworkManager.is_offline_mode,
		"is_host": GameManager.is_host(),
		"players": GameManager.get_players().size(),
		"rtt_ms": int(NetworkManager.get_latest_rtt_ms()),
	}


func _phase_name() -> String:
	if _phase < 0:
		return "?"
	var keys: Array = GamePhase.Phase.keys()
	if _phase < keys.size():
		return String(keys[_phase])
	return str(_phase)


# ── Crash reporting ───────────────────────────────────────────────────────────
func _report_previous_crash(prev_breadcrumb: Dictionary) -> void:
	var log_tail: String = _read_log_tail(_find_previous_log())
	_reporter = BugReporter.new()
	_reporter.submit_crash(prev_breadcrumb, log_tail)


# The previous run's log = the most recently modified *.log that ISN'T this run's
# active file (which is being appended to now, so it has the newest mtime).
# Naming-agnostic: works regardless of Godot's rotation suffix scheme.
func _find_previous_log() -> String:
	var dir: DirAccess = DirAccess.open(LOG_DIR)
	if dir == null:
		return ""
	var entries: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".log"):
			var path: String = LOG_DIR + "/" + fname
			entries.append({"path": path, "mtime": FileAccess.get_modified_time(path)})
		fname = dir.get_next()
	dir.list_dir_end()
	if entries.size() < 2:
		return ""
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["mtime"] > b["mtime"])
	return entries[1]["path"]


func _read_log_tail(path: String) -> String:
	if path == "":
		return ""
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var length: int = f.get_length()
	if length > LOG_TAIL_BYTES:
		f.seek(length - LOG_TAIL_BYTES)
	var text: String = f.get_as_text()
	f.close()
	return text


# ── Helpers ───────────────────────────────────────────────────────────────────
func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}
