extends GutTest

# Exercises CrashWatch's file plumbing (sentinel lifecycle, breadcrumb JSON
# roundtrip, previous-log selection + tail). The autoload itself is inert under
# --headless; here we instantiate it directly and drive the helpers, cleaning up
# the temp user:// files afterward.

var _cw: Node = null

func before_each() -> void:
	_cw = load("res://Scripts/game/crash_watch.gd").new()

func after_each() -> void:
	# Clear any files the test (or the helper) wrote.
	var ud: DirAccess = DirAccess.open("user://")
	if ud != null:
		ud.remove("session.lock")
		ud.remove("last_state.json")
	var ld: DirAccess = DirAccess.open("user://logs")
	if ld != null:
		ld.list_dir_begin()
		var nm: String = ld.get_next()
		while nm != "":
			if not ld.current_is_dir():
				ld.remove(nm)
			nm = ld.get_next()
		ld.list_dir_end()
	if _cw != null:
		_cw.free()
		_cw = null

func test_sentinel_write_then_clear() -> void:
	_cw._write_sentinel()
	assert_true(FileAccess.file_exists("user://session.lock"), "sentinel created")
	_cw._clear_sentinel()
	assert_false(FileAccess.file_exists("user://session.lock"), "sentinel removed on clean exit")

func test_read_json_roundtrip_and_missing() -> void:
	var f: FileAccess = FileAccess.open("user://last_state.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"scene": "Hockey", "n": 3}))
	f.close()
	var got: Dictionary = _cw._read_json("user://last_state.json")
	assert_eq(String(got.get("scene", "")), "Hockey", "breadcrumb scene read back")
	assert_eq(int(got.get("n", 0)), 3, "breadcrumb int read back")
	assert_true(_cw._read_json("user://nope_missing.json").is_empty(), "missing file → empty dict")

func test_find_previous_log_needs_two_files() -> void:
	DirAccess.make_dir_recursive_absolute("user://logs")
	# Zero/one file → no distinguishable previous run.
	assert_eq(_cw._find_previous_log(), "", "no logs → empty")
	var one: FileAccess = FileAccess.open("user://logs/only.log", FileAccess.WRITE)
	one.store_string("solo\n"); one.close()
	assert_eq(_cw._find_previous_log(), "", "single log (this run) → empty")
	# Two files → the previous run's log is identified.
	var two: FileAccess = FileAccess.open("user://logs/prev.log", FileAccess.WRITE)
	two.store_string("line1\nERROR boom\n"); two.close()
	var prev: String = _cw._find_previous_log()
	assert_true(prev.ends_with(".log"), "two logs → a .log path is returned (%s)" % prev)

func test_read_log_tail() -> void:
	DirAccess.make_dir_recursive_absolute("user://logs")
	var lf: FileAccess = FileAccess.open("user://logs/x.log", FileAccess.WRITE)
	lf.store_string("a\nb\nERROR crashed here\n"); lf.close()
	var tail: String = _cw._read_log_tail("user://logs/x.log")
	assert_true(tail.contains("ERROR crashed here"), "tail includes the recent error line")
	assert_eq(_cw._read_log_tail(""), "", "empty path → empty tail")
