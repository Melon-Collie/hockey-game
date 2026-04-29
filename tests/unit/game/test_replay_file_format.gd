extends GutTest

# Round-trip tests for ReplayFileWriter / ReplayFileReader. Verifies header,
# frame payloads, and footer all survive a write → read pass byte-exact, and
# that a manually-truncated trailing record is gracefully skipped.

const TEST_PATH: String = "user://test_replay_format.mreplay"


func before_each() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(TEST_PATH)


func after_each() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(TEST_PATH)


func test_round_trip_header_frames_footer() -> void:
	var writer := ReplayFileWriter.new()
	var header := {
		"game_id": "abc-123",
		"build_version": "0.1.42",
		"num_periods": 3,
	}
	assert_true(writer.open(TEST_PATH, header))

	var ws_payload := PackedByteArray([10, 20, 30, 40, 50])
	writer.enqueue_frame(0.000, ws_payload)
	writer.enqueue_frame(0.025, ws_payload)

	var ev_payload := "phase=PLAYING".to_utf8_buffer()
	writer.enqueue_event(0.050, ev_payload)

	writer.close_async({"frame_count": 3})

	var result: Dictionary = ReplayFileReader.read(TEST_PATH)
	assert_true(result.ok, "read failed: %s" % result.error)
	assert_eq(result.header.game_id, "abc-123")
	assert_eq(result.header.build_version, "0.1.42")
	assert_eq(int(result.header.num_periods), 3)  # JSON unifies int/float
	assert_eq(result.frames.size(), 3)
	assert_eq(result.frames[0].kind, ReplayFileWriter.KIND_WORLD_STATE)
	assert_almost_eq(float(result.frames[0].host_ts), 0.000, 0.0001)
	assert_eq(result.frames[0].payload, ws_payload)
	assert_almost_eq(float(result.frames[1].host_ts), 0.025, 0.0001)
	assert_eq(result.frames[1].payload, ws_payload)
	assert_eq(result.frames[2].kind, ReplayFileWriter.KIND_EVENT)
	assert_eq(result.frames[2].payload, ev_payload)
	assert_eq(int(result.footer.frame_count), 3)
	assert_false(result.truncated)


func test_empty_payload_round_trips() -> void:
	var writer := ReplayFileWriter.new()
	assert_true(writer.open(TEST_PATH, {}))
	writer.enqueue_frame(0.0, PackedByteArray())
	writer.close_async({})

	var result: Dictionary = ReplayFileReader.read(TEST_PATH)
	assert_true(result.ok)
	assert_eq(result.frames.size(), 1)
	assert_eq(result.frames[0].payload.size(), 0)


func test_partial_trailing_record_is_skipped() -> void:
	# Write a normal file with 2 frames + footer, then corrupt the file by
	# overwriting the END_OF_RECORDS sentinel with a length prefix that claims
	# more bytes than remain. Reader should yield 2 frames and report
	# truncated = true.
	var writer := ReplayFileWriter.new()
	assert_true(writer.open(TEST_PATH, {"game_id": "trunc-test"}))
	writer.enqueue_frame(0.0, PackedByteArray([1, 2, 3]))
	writer.enqueue_frame(0.025, PackedByteArray([4, 5, 6]))
	writer.close_async({})

	# The first 4-byte u32 after the last frame is END_OF_RECORDS (0). Compute
	# its position by reading once, finding the offset.
	var pristine: Dictionary = ReplayFileReader.read(TEST_PATH)
	assert_false(pristine.truncated)
	assert_eq(pristine.frames.size(), 2)

	# Strip the file at the END_OF_RECORDS position and append a malformed
	# length prefix claiming 9999 more bytes.
	var read_file: FileAccess = FileAccess.open(TEST_PATH, FileAccess.READ)
	# Layout: MAGIC(8) + VERSION(1) + HEADER_SIZE(4) + HEADER_BYTES
	var head_len: int = ReplayFileWriter.MAGIC.size() + 1 + 4
	read_file.seek(ReplayFileWriter.MAGIC.size() + 1)  # skip magic + version
	var header_size: int = read_file.get_32()
	var pre_records_offset: int = head_len + header_size
	# Walk both records to find the offset of END_OF_RECORDS.
	read_file.seek(pre_records_offset)
	for _i: int in 2:
		var frame_len: int = read_file.get_32()
		read_file.seek(read_file.get_position() + frame_len)
	var eof_marker_pos: int = read_file.get_position()
	read_file.close()

	var corrupted: PackedByteArray = FileAccess.get_file_as_bytes(TEST_PATH).slice(0, eof_marker_pos)
	corrupted.resize(eof_marker_pos + 4)
	corrupted.encode_u32(eof_marker_pos, 9999)
	var write_file: FileAccess = FileAccess.open(TEST_PATH, FileAccess.WRITE)
	write_file.store_buffer(corrupted)
	write_file.close()

	var result: Dictionary = ReplayFileReader.read(TEST_PATH)
	assert_true(result.ok)
	assert_eq(result.frames.size(), 2)
	assert_true(result.truncated)


func test_magic_mismatch_returns_error() -> void:
	var f: FileAccess = FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_buffer("NOT_MREPLAY".to_utf8_buffer())
	f.close()
	var result: Dictionary = ReplayFileReader.read(TEST_PATH)
	assert_false(result.ok)
	assert_string_contains(result.error, "magic")


func test_large_payload_round_trips() -> void:
	# Realistic-size broadcast (~250 bytes) over many frames.
	var writer := ReplayFileWriter.new()
	assert_true(writer.open(TEST_PATH, {}))
	var payload := PackedByteArray()
	payload.resize(250)
	for i: int in 250:
		payload[i] = i % 256
	for i: int in 100:
		writer.enqueue_frame(float(i) * 0.025, payload)
	writer.close_async({})

	var result: Dictionary = ReplayFileReader.read(TEST_PATH)
	assert_true(result.ok)
	assert_eq(result.frames.size(), 100)
	assert_eq(result.frames[0].payload, payload)
	assert_eq(result.frames[99].payload, payload)
	assert_almost_eq(float(result.frames[99].host_ts), 99.0 * 0.025, 0.0001)
