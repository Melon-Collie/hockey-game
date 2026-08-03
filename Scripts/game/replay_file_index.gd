class_name ReplayFileIndex
extends RefCounted

# On-disk catalog of .mreplay files in user://replays/. Two responsibilities:
#   - list(): enumerate replays (used by the main-menu browser)
#   - purge_oldest(): bound the on-disk footprint by deleting the oldest
#     files beyond keep_count. Run at writer-open time so the new file is
#     never the one that gets deleted.

const REPLAY_DIR: String = "user://replays/"
const REPLAY_EXT: String = ".mreplay"


# Returns paths sorted newest-first by modification time. Includes only
# regular .mreplay files; subdirectories and stray files are ignored.
static func list(dir: String = REPLAY_DIR) -> Array[String]:
	var result: Array[String] = []
	if not DirAccess.dir_exists_absolute(dir):
		return result
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return result
	# Decorate-sort-undecorate: stat each file once on the way in and sort on the
	# cached time. Statting inside the comparator instead costs a filesystem call
	# per comparison — O(n log n) syscalls to order n files, on the main thread of
	# whatever menu frame asked for the list.
	var mtime_by_path: Dictionary[String, int] = {}
	d.list_dir_begin()
	var name: String = d.get_next()
	while not name.is_empty():
		if not d.current_is_dir() and name.ends_with(REPLAY_EXT):
			var path: String = dir.path_join(name)
			result.append(path)
			mtime_by_path[path] = FileAccess.get_modified_time(path)
		name = d.get_next()
	d.list_dir_end()
	result.sort_custom(func(a: String, b: String) -> bool:
		return mtime_by_path[a] > mtime_by_path[b])
	return result


# Deletes oldest .mreplay files in `dir` until at most `keep_count` remain.
# Returns the number of files deleted. Safe to call when the directory
# doesn't exist or is empty.
static func purge_oldest(dir: String = REPLAY_DIR, keep_count: int = 20) -> int:
	if keep_count <= 0:
		return 0
	var files: Array[String] = list(dir)
	if files.size() <= keep_count:
		return 0
	var to_delete: Array[String] = files.slice(keep_count)  # tail = oldest after newest-first sort
	var deleted: int = 0
	for path: String in to_delete:
		var err: int = DirAccess.remove_absolute(path)
		if err == OK:
			deleted += 1
		else:
			push_warning("ReplayFileIndex: failed to delete %s (err %d)" % [path, err])
	return deleted
