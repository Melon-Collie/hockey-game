extends GutTest

# ReplayFrameCursor — "which two recorded frames bracket this instant, decoded
# once." All three replay drivers had written this out; the interesting parts
# are the forward-scan hint (which has to survive a backward seek and a shorter
# clip) and the two ways a seek can come back with nothing to draw.
#
# decode_for_replay reads only the packet bytes — no registry, no scene — so the
# codec stands up bare here and the frames below are hand-built packets.

const _SEQ_BYTES: int = 2
const _TIME_BYTES: int = 4

var cursor: ReplayFrameCursor


func before_each() -> void:
	cursor = ReplayFrameCursor.new()
	cursor.bind(WorldStateCodec.new())


# The smallest packet decode_for_replay accepts: header with zero skaters, then
# the puck block, the goalie count, and the game-state block.
func _frame() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(WorldStateCodec.WS_HEADER_SIZE + WorldStateCodec.PUCK_BLOCK_SIZE
			+ 1 + WorldStateCodec.GAME_STATE_BLOCK_SIZE)
	b.encode_u16(0, 1)
	b.encode_u32(_SEQ_BYTES, 0)
	b.encode_u8(_SEQ_BYTES + _TIME_BYTES, 0)  # zero skaters
	return b


func _clip(count: int) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	for _i: int in count:
		out.append(_frame())
	return out


func test_find_index_returns_the_frame_at_or_before_the_clock() -> void:
	var ts: Array[float] = [10.0, 11.0, 12.0]
	assert_eq(cursor.find_index(ts, 9.9), -1, "before the first frame there is nothing to show")
	assert_eq(cursor.find_index(ts, 10.0), 0, "exactly on a frame lands on it")
	assert_eq(cursor.find_index(ts, 11.5), 1, "mid-bracket lands on the FROM frame")
	assert_eq(cursor.find_index(ts, 99.0), 2, "past the end holds the last frame")


# The hint is what makes a forward-advancing clock O(1). It has to notice a
# backward seek, or a scrub to the start would answer with a frame from the end.
func test_the_scan_hint_survives_a_backward_seek() -> void:
	var ts: Array[float] = [10.0, 11.0, 12.0, 13.0]
	assert_eq(cursor.find_index(ts, 13.0), 3)
	assert_eq(cursor.find_index(ts, 10.5), 0, "scrubbing back must not answer from the hint")
	assert_eq(cursor.find_index(ts, 12.5), 2, "and forward again still works")


# Loading a shorter recording after a longer one leaves the hint past the end of
# the new array. Indexing it is a crash, not a wrong answer.
func test_a_shorter_clip_does_not_index_past_the_stale_hint() -> void:
	var long_ts: Array[float] = [1.0, 2.0, 3.0, 4.0, 5.0]
	assert_eq(cursor.find_index(long_ts, 5.0), 4)
	var short_ts: Array[float] = [1.0, 2.0]
	assert_eq(cursor.find_index(short_ts, 2.0), 1,
			"a hint left at index 4 must not be read against a 2-frame clip")


func test_seek_reports_nothing_to_draw_before_the_first_frame() -> void:
	assert_false(cursor.seek(_clip(3), [10.0, 11.0, 12.0], 9.0),
			"the caller must return rather than reuse the previous pose")


func test_seek_reports_nothing_to_draw_when_the_frame_does_not_decode() -> void:
	var truncated: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	assert_false(cursor.seek(truncated, [10.0, 11.0], 10.5),
			"a short packet decodes to nothing — that is not a frame to hold")


func test_alpha_spans_the_bracket() -> void:
	var frames: Array[PackedByteArray] = _clip(2)
	var ts: Array[float] = [10.0, 11.0]
	assert_true(cursor.seek(frames, ts, 10.0))
	assert_almost_eq(cursor.alpha(), 0.0, 1e-6)
	assert_almost_eq(cursor.bracket_dt(), 1.0, 1e-6)
	assert_true(cursor.seek(frames, ts, 10.25))
	assert_almost_eq(cursor.alpha(), 0.25, 1e-6)


# Past the last frame the bracket collapses onto itself, so there is no span to
# interpolate across and the final pose has to hold rather than divide by zero.
func test_the_last_frame_brackets_against_itself() -> void:
	var frames: Array[PackedByteArray] = _clip(2)
	assert_true(cursor.seek(frames, [10.0, 11.0], 50.0))
	assert_almost_eq(cursor.bracket_dt(), 0.0, 1e-6)
	assert_almost_eq(cursor.alpha(), 0.0, 1e-6)


# The decode happens only on a bracket change, so a driver watching for a phase
# keyframe has exactly this one moment to look.
func test_bracket_changed_fires_once_per_bracket() -> void:
	var frames: Array[PackedByteArray] = _clip(3)
	var ts: Array[float] = [10.0, 11.0, 12.0]
	assert_true(cursor.seek(frames, ts, 10.1))
	assert_true(cursor.bracket_changed(), "first landing in a bracket is a change")
	assert_true(cursor.seek(frames, ts, 10.9))
	assert_false(cursor.bracket_changed(), "still the same pair — no re-decode happened")
	assert_true(cursor.seek(frames, ts, 11.1))
	assert_true(cursor.bracket_changed(), "crossed into the next pair")


func test_reset_forgets_the_cached_bracket() -> void:
	var frames: Array[PackedByteArray] = _clip(2)
	var ts: Array[float] = [10.0, 11.0]
	assert_true(cursor.seek(frames, ts, 10.5))
	assert_false(cursor.from_snap().is_empty())
	cursor.reset()
	assert_true(cursor.from_snap().is_empty(),
			"a new clip must not read the previous one's decode as current")
	assert_almost_eq(cursor.alpha(), 0.0, 1e-6)


# Three drivers had each written the bracket-and-decode block out, and the file
# viewer's copy carried a scan hint the other two lacked — so the same lookup
# had two different performance characters and one of them a stale-index crash.
# The decode belongs to the cursor now; a fourth driver has to go through it.
func test_no_driver_re_implements_the_bracket_decode() -> void:
	var dir: DirAccess = DirAccess.open("res://Scripts/game")
	assert_not_null(dir, "could not open res://Scripts/game")
	if dir == null:
		return
	var checked: int = 0
	for file: String in dir.get_files():
		if not file.ends_with("_replay_driver.gd"):
			continue
		checked += 1
		var src: String = FileAccess.get_file_as_string("res://Scripts/game/%s" % file)
		assert_false(src.contains("decode_for_replay("),
				"%s decodes frames itself instead of going through ReplayFrameCursor — " % file +
				"the bracket cache is what keeps a 60 fps _process from re-decoding the " +
				"same two frames every tick, and each hand-rolled copy got it slightly " +
				"differently")
	assert_gt(checked, 2, "expected to have found the replay drivers")
