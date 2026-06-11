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


# Reads only the magic + header JSON, skipping the frame stream entirely.
# Used by the main-menu replay browser to populate the list without walking
# 24K frames per file. Returns {ok, header, error} only.
static func read_header_only(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "header": {}, "error": "open failed"}
	if file.get_length() > _MAX_FILE_BYTES:
		file.close()
		return {"ok": false, "header": {}, "error": "file too large"}
	var magic: PackedByteArray = file.get_buffer(ReplayFileWriter.MAGIC.size())
	if magic != ReplayFileWriter.MAGIC:
		file.close()
		return {"ok": false, "header": {}, "error": "magic mismatch"}
	var version: int = file.get_8()
	if version != ReplayFileWriter.FORMAT_VERSION:
		file.close()
		return {"ok": false, "header": {}, "error": "unsupported format version %d" % version}
	var header_size: int = file.get_32()
	if header_size <= 0 or header_size > _MAX_HEADER_BYTES:
		file.close()
		return {"ok": false, "header": {}, "error": "header size out of range"}
	var header_bytes: PackedByteArray = file.get_buffer(header_size)
	file.close()
	if header_bytes.size() != header_size:
		return {"ok": false, "header": {}, "error": "header truncated"}
	var parsed: Variant = JSON.parse_string(header_bytes.get_string_from_utf8())
	if not parsed is Dictionary:
		return {"ok": false, "header": {}, "error": "header parse failed"}
	return {"ok": true, "header": parsed as Dictionary, "error": ""}
