extends GutTest

# ReplayFileIndex — list + rolling-cap purge for user://replays/.

const TEST_DIR: String = "user://test_replay_index/"


func before_each() -> void:
	_clear_dir()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)


func after_each() -> void:
	_clear_dir()


func _clear_dir() -> void:
	if not DirAccess.dir_exists_absolute(TEST_DIR):
		return
	var d: DirAccess = DirAccess.open(TEST_DIR)
	if d == null:
		return
	d.list_dir_begin()
	var entry: String = d.get_next()
	while not entry.is_empty():
		if not d.current_is_dir():
			DirAccess.remove_absolute(TEST_DIR.path_join(entry))
		entry = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(TEST_DIR)


# Writes a 1-byte placeholder so FileAccess.get_modified_time has something to
# stat. FileAccess.get_modified_time is second-resolution on every supported
# platform, so consecutive _make_replay calls need ≥ 1 second between them
# for the order-sensitive tests to be deterministic. (10 ms wasn't enough —
# all three files ended up sharing a second, sort returned all-equal, and
# stable sort kept directory-listing order = alphabetical.)
func _make_replay(file_name: String) -> String:
	var path: String = TEST_DIR.path_join(file_name)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_8(0)
	f.close()
	OS.delay_msec(1100)
	return path


func test_list_empty_dir_returns_empty() -> void:
	var result: Array[String] = ReplayFileIndex.list(TEST_DIR)
	assert_eq(result.size(), 0)


func test_list_missing_dir_returns_empty() -> void:
	_clear_dir()  # remove the dir created in before_each
	var result: Array[String] = ReplayFileIndex.list(TEST_DIR)
	assert_eq(result.size(), 0)


func test_list_skips_non_mreplay_files() -> void:
	_make_replay("a.mreplay")
	var f: FileAccess = FileAccess.open(TEST_DIR.path_join("notes.txt"), FileAccess.WRITE)
	f.store_8(0)
	f.close()
	var result: Array[String] = ReplayFileIndex.list(TEST_DIR)
	assert_eq(result.size(), 1)
	assert_string_ends_with(result[0], "a.mreplay")


func test_list_orders_newest_first() -> void:
	_make_replay("oldest.mreplay")
	_make_replay("middle.mreplay")
	_make_replay("newest.mreplay")
	var result: Array[String] = ReplayFileIndex.list(TEST_DIR)
	assert_eq(result.size(), 3)
	assert_string_ends_with(result[0], "newest.mreplay")
	assert_string_ends_with(result[1], "middle.mreplay")
	assert_string_ends_with(result[2], "oldest.mreplay")


func test_purge_under_cap_is_noop() -> void:
	_make_replay("a.mreplay")
	_make_replay("b.mreplay")
	var deleted: int = ReplayFileIndex.purge_oldest(TEST_DIR, 5)
	assert_eq(deleted, 0)
	assert_eq(ReplayFileIndex.list(TEST_DIR).size(), 2)


func test_purge_at_cap_is_noop() -> void:
	_make_replay("a.mreplay")
	_make_replay("b.mreplay")
	_make_replay("c.mreplay")
	var deleted: int = ReplayFileIndex.purge_oldest(TEST_DIR, 3)
	assert_eq(deleted, 0)
	assert_eq(ReplayFileIndex.list(TEST_DIR).size(), 3)


func test_purge_drops_oldest_keeps_newest() -> void:
	_make_replay("oldest.mreplay")
	_make_replay("middle.mreplay")
	_make_replay("newest.mreplay")
	var deleted: int = ReplayFileIndex.purge_oldest(TEST_DIR, 1)
	assert_eq(deleted, 2)
	var remaining: Array[String] = ReplayFileIndex.list(TEST_DIR)
	assert_eq(remaining.size(), 1)
	assert_string_ends_with(remaining[0], "newest.mreplay")


func test_purge_zero_keep_is_noop_for_safety() -> void:
	_make_replay("a.mreplay")
	var deleted: int = ReplayFileIndex.purge_oldest(TEST_DIR, 0)
	assert_eq(deleted, 0)
	assert_eq(ReplayFileIndex.list(TEST_DIR).size(), 1)
