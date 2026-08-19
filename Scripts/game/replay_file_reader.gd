class_name ReplayFileReader
extends RefCounted

# Reads a .mreplay file produced by ReplayFileWriter into a flat dict for the
# viewer / GUT tests. Format constants live on ReplayFileWriter; this class
# only knows how to parse them.

# Hard caps on untrusted lengths from the file. A malformed or malicious file
# can claim header_size = 0xFFFFFFFF and trigger a multi-gigabyte allocation
# inside file.get_buffer(); these limits are well above any legitimate value
# (a 6-player header is &lt; 4 KB; broadcast frames are &lt; 1 KB; a 30-min game
# at 120 Hz is ~90 MB on disk).
const _MAX_FILE_BYTES: int = 200 * 1024 * 1024  # 200 MB
const _MAX_HEADER_BYTES: int = 64 * 1024        # 64 KB
const _MAX_FRAME_BYTES: int = 64 * 1024         # 64 KB

# read_meta memo, keyed on "path|modified_time" — a .mreplay is immutable once
# its footer is written, and the filename IS the game_id, so a completed file
# can never change under the key. Static (survives scene changes, like
# HockeyRink._build_cache) because the career screen is rebuilt with the HUD.
# Bounded by the replay purge (20 files on disk) plus stale mtime keys; the cap
# is a backstop, and clearing wholesale is fine — the cost of a miss is one walk.
static var _meta_cache: Dictionary = {}
const _META_CACHE_MAX: int = 64
#
# Returns:
#   {
#     ok: bool,
#     header: Dictionary,            # JSON object from the file's header
#     frames: Array[Dictionary],     # each {host_ts: float, kind: int, payload: PackedByteArray}
#     footer: Dictionary,            # empty if truncated or footer JSON missing
#     truncated: bool,               # true when END_OF_RECORDS sentinel was missing
#     error: String,                 # populated when ok = false
#   }
static func read(path: String) -> Dictionary:
	var failure := func(msg: String) -> Dictionary:
		return {
			"ok": false,
			"header": {},
			"frames": [],
			"footer": {},
			"truncated": false,
			"error": msg,
		}

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return failure.call("failed to open: %s (err %d)" % [path, FileAccess.get_open_error()])

	if file.get_length() > _MAX_FILE_BYTES:
		file.close()
		return failure.call("file too large: %d bytes (cap %d)" % [file.get_length(), _MAX_FILE_BYTES])

	var magic: PackedByteArray = file.get_buffer(ReplayFileWriter.MAGIC.size())
	if magic != ReplayFileWriter.MAGIC:
		file.close()
		return failure.call("magic mismatch (not a .mreplay file?)")

	var version: int = file.get_8()
	if version != ReplayFileWriter.FORMAT_VERSION:
		file.close()
		return failure.call("unsupported format version %d (expected %d)" % [version, ReplayFileWriter.FORMAT_VERSION])

	var header_size: int = file.get_32()
	if header_size <= 0 or header_size > _MAX_HEADER_BYTES:
		file.close()
		return failure.call("header size out of range: %d" % header_size)
	var header_bytes: PackedByteArray = file.get_buffer(header_size)
	if header_bytes.size() != header_size:
		file.close()
		return failure.call("header truncated")
	var header_parsed: Variant = JSON.parse_string(header_bytes.get_string_from_utf8())
	if not header_parsed is Dictionary:
		file.close()
		return failure.call("header JSON parse failed")

	var frames: Array[Dictionary] = []
	var truncated: bool = true
	var file_len: int = file.get_length()
	# Issue at most one push_warning per file even if many frames are out
	# of order, so a corrupted file doesn't flood the log.
	var warned_non_monotone: bool = false
	var prev_host_ts: float = -INF
	while file.get_position() + 4 <= file_len:
		var frame_len: int = file.get_32()
		if frame_len == ReplayFileWriter.END_OF_RECORDS:
			truncated = false
			break
		if frame_len < ReplayFileWriter.FRAME_INNER_HEADER_SIZE:
			break  # corrupt or unexpected; treat as EOF
		if frame_len > _MAX_FRAME_BYTES:
			break  # malformed length claim; refuse to allocate
		if file.get_position() + frame_len > file_len:
			break  # partial trailing record (writer crashed)
		var host_ts: float = float(file.get_32()) / Constants.TIME_WIRE_SCALE
		var kind: int = file.get_8()
		var payload_size: int = frame_len - ReplayFileWriter.FRAME_INNER_HEADER_SIZE
		var payload: PackedByteArray
		if payload_size > 0:
			payload = file.get_buffer(payload_size)
		else:
			payload = PackedByteArray()
		# Defensive monotone check: FileReplayDriver._find_frame_idx assumes
		# timestamps increase. A maliciously-crafted or corrupted file with
		# out-of-order frames would silently break seek behavior. Warn once
		# so the issue surfaces in the log.
		if host_ts < prev_host_ts and not warned_non_monotone:
			push_warning("ReplayFileReader: non-monotone host_ts in %s (frame %d: %f < prev %f)" % [path, frames.size(), host_ts, prev_host_ts])
			warned_non_monotone = true
		prev_host_ts = host_ts
		frames.append({
			"host_ts": host_ts,
			"kind": kind,
			"payload": payload,
		})

	var footer: Dictionary = {}
	if not truncated and file.get_position() + 4 <= file_len:
		var footer_size: int = file.get_32()
		if footer_size > 0 and file.get_position() + footer_size <= file_len:
			var footer_bytes: PackedByteArray = file.get_buffer(footer_size)
			var footer_parsed: Variant = JSON.parse_string(footer_bytes.get_string_from_utf8())
			if footer_parsed is Dictionary:
				footer = footer_parsed

	file.close()
	return {
		"ok": true,
		"header": header_parsed as Dictionary,
		"frames": frames,
		"footer": footer,
		"truncated": truncated,
		"error": "",
	}


static func read_meta(path: String) -> Dictionary:
	var key: String = _meta_cache_key(path)
	if not key.is_empty():
		var cached: Variant = _meta_cache.get(key)
		if cached is Dictionary:
			return cached as Dictionary
	var meta: Dictionary = _read_meta_uncached(path)
	# Only a COMPLETE file is immutable, so only that is safe to memoize: a
	# recording still in progress (truncated, no footer yet) grows under us — and
	# the career screen is reachable from the in-game side menu, mid-match. A
	# failed read isn't cached either, so a transient error retries.
	if not key.is_empty() and bool(meta.get("ok", false)) \
			and not bool(meta.get("truncated", true)):
		if _meta_cache.size() >= _META_CACHE_MAX:
			_meta_cache.clear()  # bounded; the next open just re-walks
		_meta_cache[key] = meta
	return meta


# Identity of the bytes behind `path`: mtime AND length, since mtime alone is
# second-granular. In the wild a replay's filename is its game_id (a UUID), so
# path alone already identifies a completed file — the other two terms are what
# keep a REUSED path (the GUT fixture writes several files to one) honest.
# Empty string when the file can't be opened: don't look up, don't store.
static func _meta_cache_key(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var key: String = "%s|%d|%d" % [path, FileAccess.get_modified_time(path), file.get_length()]
	file.close()
	return key


# Callers only ever READ the returned dictionary; it is handed out by reference
# rather than duplicated, so a mutation would poison the cache.
static func _read_meta_uncached(path: String) -> Dictionary:
	var failure := func(msg: String) -> Dictionary:
		return {"ok": false, "header": {}, "footer": {}, "truncated": false, "error": msg}

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return failure.call("failed to open: %s (err %d)" % [path, FileAccess.get_open_error()])
	if file.get_length() > _MAX_FILE_BYTES:
		file.close()
		return failure.call("file too large: %d bytes (cap %d)" % [file.get_length(), _MAX_FILE_BYTES])
	var magic: PackedByteArray = file.get_buffer(ReplayFileWriter.MAGIC.size())
	if magic != ReplayFileWriter.MAGIC:
		file.close()
		return failure.call("magic mismatch (not a .mreplay file?)")
	var version: int = file.get_8()
	if version != ReplayFileWriter.FORMAT_VERSION:
		file.close()
		return failure.call("unsupported format version %d (expected %d)" % [version, ReplayFileWriter.FORMAT_VERSION])
	var header_size: int = file.get_32()
	if header_size <= 0 or header_size > _MAX_HEADER_BYTES:
		file.close()
		return failure.call("header size out of range: %d" % header_size)
	var header_bytes: PackedByteArray = file.get_buffer(header_size)
	if header_bytes.size() != header_size:
		file.close()
		return failure.call("header truncated")
	var header_parsed: Variant = JSON.parse_string(header_bytes.get_string_from_utf8())
	if not header_parsed is Dictionary:
		file.close()
		return failure.call("header JSON parse failed")

	# Walk frame records by seeking past each payload — never reads frame bytes.
	var truncated: bool = true
	var file_len: int = file.get_length()
	while file.get_position() + 4 <= file_len:
		var frame_len: int = file.get_32()
		if frame_len == ReplayFileWriter.END_OF_RECORDS:
			truncated = false
			break
		if frame_len < ReplayFileWriter.FRAME_INNER_HEADER_SIZE:
			break  # corrupt or unexpected; treat as EOF
		if frame_len > _MAX_FRAME_BYTES:
			break  # malformed length claim
		if file.get_position() + frame_len > file_len:
			break  # partial trailing record (writer crashed)
		file.seek(file.get_position() + frame_len)

	var footer: Dictionary = {}
	if not truncated and file.get_position() + 4 <= file_len:
		var footer_size: int = file.get_32()
		if footer_size > 0 and footer_size <= _MAX_HEADER_BYTES \
				and file.get_position() + footer_size <= file_len:
			var footer_bytes: PackedByteArray = file.get_buffer(footer_size)
			var footer_parsed: Variant = JSON.parse_string(footer_bytes.get_string_from_utf8())
			if footer_parsed is Dictionary:
				footer = footer_parsed

	file.close()
	return {
		"ok": true,
		"header": header_parsed as Dictionary,
		"footer": footer,
		"truncated": truncated,
		"error": "",
	}
