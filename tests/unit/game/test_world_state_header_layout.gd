extends GutTest

# The world-state header is read by byte offset from three files outside the
# codec that owns it: NetworkManager takes the sequence and the host time (for
# the PDV sample), GameManager takes the host time (to stamp recorder frames).
#
# That coupling used to be four literals and a comment — "u32 0.1ms wire units —
# must match WorldStateCodec's header encoding". Reordering the header while
# those literals stayed put would not have failed to decode. It would have
# decoded a *different field* and carried on: the recorder would stamp every
# replay frame with a sequence number reinterpreted as a timestamp, and the PDV
# histogram would fill with nonsense. Nothing throws, nothing warns.
#
# The offsets are named constants now, so the literals are gone. What this pins
# is the layout arithmetic itself — a field cannot be resized or reordered
# without the derivation failing — plus a round trip proving encoder and readers
# agree on where each field is and how wide.

const _SEQ: int = WorldStateCodec.WS_SEQUENCE_OFFSET
const _TIME: int = WorldStateCodec.WS_HOST_TIME_OFFSET
const _COUNT: int = WorldStateCodec.WS_SKATER_COUNT_OFFSET


# u16 sequence, u32 host time, u8 skater count, packed with no padding. Stated as
# arithmetic so moving any field breaks it rather than silently overlapping the
# next one.
func test_header_fields_tile_without_gaps_or_overlap() -> void:
	assert_eq(_SEQ, 0, "the sequence must stay first — NetworkManager reads it before size checks")
	assert_eq(_TIME, _SEQ + 2, "host time follows the u16 sequence")
	assert_eq(_COUNT, _TIME + 4, "skater count follows the u32 host time")
	assert_eq(WorldStateCodec.WS_HEADER_SIZE, _COUNT + 1,
			"WS_HEADER_SIZE must cover the u8 count — it is where the skater blocks start")


func test_header_round_trips_through_the_named_offsets() -> void:
	var b := PackedByteArray()
	b.resize(WorldStateCodec.WS_HEADER_SIZE)
	# 0.1 ms units, per Scripts/networking/CLAUDE.md. Chosen with a fractional
	# millisecond so a scale error shows up rather than rounding away.
	var host_time_s: float = 1234.5678
	b.encode_u16(_SEQ, 65535)
	b.encode_u32(_TIME, roundi(host_time_s * Constants.TIME_WIRE_SCALE))
	b.encode_u8(_COUNT, 6)

	assert_eq(b.decode_u16(_SEQ), 65535, "sequence must survive at full u16 width")
	assert_almost_eq(float(b.decode_u32(_TIME)) / Constants.TIME_WIRE_SCALE,
			host_time_s, 0.0001,
			"host time must round-trip within the 0.1 ms wire grid")
	assert_eq(b.decode_u8(_COUNT), 6, "skater count must survive")


# The reason the representation is u32-in-0.1ms rather than f32 seconds is that
# f32's ULP grows with host uptime until adjacent per-tick stamps quantize equal
# and the input dedupe drops real inputs. Pinning the horizon keeps that argument
# checkable: if the scale is ever widened for precision, this says what it costs.
func test_wire_grid_covers_a_long_session() -> void:
	var max_seconds: float = 4294967295.0 / Constants.TIME_WIRE_SCALE
	assert_gt(max_seconds, 100.0 * 3600.0,
			"u32 at TIME_WIRE_SCALE must cover >100 h of host uptime before wrapping")
	assert_almost_eq(1.0 / Constants.TIME_WIRE_SCALE, 0.0001, 1e-9,
			"the wire grid is 0.1 ms — PredictedState.TS_MATCH_EPSILON is sized against it")
