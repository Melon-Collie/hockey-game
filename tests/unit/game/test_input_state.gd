extends GutTest

# InputState — serialization round-trip.
# Catches regressions where host_timestamp is dropped from the wire format
# or field indices shift after a migration.


func test_round_trip_preserves_host_timestamp() -> void:
	var s := InputState.new()
	s.host_timestamp = 3.14159
	var r := InputState.from_array(s.to_array())
	assert_almost_eq(r.host_timestamp, 3.14159, 0.00001)


func test_round_trip_preserves_all_fields() -> void:
	var s := InputState.new()
	s.host_timestamp   = 1.5
	s.delta            = 1.0 / 240.0
	s.move_vector      = Vector2(0.5, -0.3)
	s.mouse_world_pos  = Vector3(1.0, 0.0, -2.5)
	s.mouse_screen_pos = Vector2(320.0, 240.0)
	s.shoot_pressed    = true
	s.shoot_held       = false
	s.slap_pressed     = false
	s.slap_held        = true
	s.brake            = false
	s.elevation_level  = 2
	s.block_held       = true
	s.stick_lift_held  = true
	s.sprint_held      = true
	s.stick_lift_pressed = true
	s.quick_pass_pressed = true
	s.hit_held           = true

	var r := InputState.from_array(s.to_array())

	assert_almost_eq(r.host_timestamp, s.host_timestamp, 0.00001)
	assert_almost_eq(r.delta, s.delta, 0.00001)
	assert_almost_eq(r.move_vector.x, s.move_vector.x, 0.00001)
	assert_almost_eq(r.move_vector.y, s.move_vector.y, 0.00001)
	assert_almost_eq(r.mouse_world_pos.x, s.mouse_world_pos.x, 0.00001)
	assert_almost_eq(r.mouse_world_pos.z, s.mouse_world_pos.z, 0.00001)
	assert_almost_eq(r.mouse_screen_pos.x, s.mouse_screen_pos.x, 0.00001)
	assert_almost_eq(r.mouse_screen_pos.y, s.mouse_screen_pos.y, 0.00001)
	assert_eq(r.shoot_pressed,   s.shoot_pressed)
	assert_eq(r.shoot_held,      s.shoot_held)
	assert_eq(r.slap_pressed,    s.slap_pressed)
	assert_eq(r.slap_held,       s.slap_held)
	assert_eq(r.brake,           s.brake)
	assert_eq(r.elevation_level, s.elevation_level)
	assert_eq(r.block_held,      s.block_held)
	assert_eq(r.stick_lift_held, s.stick_lift_held)
	assert_eq(r.sprint_held,     s.sprint_held)
	assert_eq(r.stick_lift_pressed, s.stick_lift_pressed)
	assert_eq(r.quick_pass_pressed, s.quick_pass_pressed)
	assert_eq(r.hit_held,           s.hit_held)


func test_array_length_sentinel() -> void:
	# Field count sentinel — if someone adds a field without updating
	# to_array/from_array, this catches the mismatch.
	var s := InputState.new()
	assert_eq(s.to_array().size(), 23)


func test_stick_lift_back_compat_defaults_false() -> void:
	# A short array from an older sender (no stick_lift_held at index 17) must
	# decode without error, defaulting the flag to false.
	var s := InputState.new()
	s.stick_lift_held = true
	var short_array: Array = s.to_array()
	short_array.resize(16)  # drop stick_lift_held + sprint_held
	var r := InputState.from_array(short_array)
	assert_false(r.stick_lift_held, "missing stick_lift_held index should default false")


func test_sprint_back_compat_defaults_false() -> void:
	# A short array missing sprint_held (index 18) must decode with sprint off.
	var s := InputState.new()
	s.sprint_held = true
	var short_array: Array = s.to_array()
	short_array.resize(17)  # drop sprint_held, keep stick_lift_held
	var r := InputState.from_array(short_array)
	assert_false(r.sprint_held, "missing sprint_held index should default false")


# ── Binary (bytes) round-trip ─────────────────────────────────────────────────

func test_bytes_round_trip_preserves_all_fields() -> void:
	var s := InputState.new()
	s.host_timestamp   = 1.5
	s.delta            = 1.0 / 60.0
	s.move_vector      = Vector2(0.5, -0.3)
	s.mouse_world_pos  = Vector3(1.0, 0.0, -2.5)
	s.mouse_screen_pos = Vector2(320.0, 240.0)
	s.shoot_pressed    = true
	s.shoot_held       = false
	s.slap_pressed     = false
	s.slap_held        = true
	s.brake            = false
	s.elevation_level  = 1
	s.block_held       = true
	s.stick_lift_held  = true
	s.sprint_held      = true
	s.stick_lift_pressed = true
	s.quick_pass_pressed = true
	s.hit_held           = true

	var r := InputState.from_bytes(s.to_bytes())

	assert_almost_eq(r.host_timestamp,   s.host_timestamp,   0.0001)
	assert_almost_eq(r.delta,            s.delta,            0.00001)
	assert_almost_eq(r.move_vector.x,    s.move_vector.x,    0.001)
	assert_almost_eq(r.move_vector.y,    s.move_vector.y,    0.001)
	assert_almost_eq(r.mouse_world_pos.x, s.mouse_world_pos.x, 0.01)
	assert_almost_eq(r.mouse_world_pos.z, s.mouse_world_pos.z, 0.01)
	assert_almost_eq(r.mouse_screen_pos.x, s.mouse_screen_pos.x, 1.0)
	assert_almost_eq(r.mouse_screen_pos.y, s.mouse_screen_pos.y, 1.0)
	assert_eq(r.shoot_pressed,   s.shoot_pressed)
	assert_eq(r.shoot_held,      s.shoot_held)
	assert_eq(r.slap_pressed,    s.slap_pressed)
	assert_eq(r.slap_held,       s.slap_held)
	assert_eq(r.brake,           s.brake)
	assert_eq(r.elevation_level, s.elevation_level)
	assert_eq(r.block_held,      s.block_held)
	assert_eq(r.stick_lift_held, s.stick_lift_held)
	assert_eq(r.sprint_held,     s.sprint_held)
	assert_eq(r.stick_lift_pressed, s.stick_lift_pressed)
	assert_eq(r.quick_pass_pressed, s.quick_pass_pressed)
	assert_eq(r.hit_held,           s.hit_held)


func test_bytes_negative_mouse_screen_pos_round_trips() -> void:
	# Attack-up team-1 players negate mouse_screen_pos in the gatherer to align the
	# cursor-drag frame to world XZ. The old u16 wire encoding clamped those
	# negatives to 0, so the host saw a frozen (0,0) cursor and derived zero
	# wrister charge / null aim — firing every dragged shot as a tap. Signed s16
	# must round-trip the negation so the host re-derives the same charged shot.
	var s := InputState.new()
	s.mouse_screen_pos = Vector2(-960.0, -540.0)
	var r := InputState.from_bytes(s.to_bytes())
	assert_almost_eq(r.mouse_screen_pos.x, -960.0, 1.0)
	assert_almost_eq(r.mouse_screen_pos.y, -540.0, 1.0)


func test_bytes_size_sentinel() -> void:
	assert_eq(InputState.BYTES_SIZE, 24)


# ── Committed wrister power (gamepad) ────────────────────────────────────────
# A pad client commits power from its right-stick push instead of a measured
# cursor speed. Both fields must cross the wire or the host re-derives power from
# the pad's PARKED cursor (~0 speed) and fires a floater while the client
# predicted a full shot.

func test_bytes_round_trips_committed_wrister_power() -> void:
	var s := InputState.new()
	s.commit_wrister_power = true
	s.bot_wrister_power_t = InputState.quantize_power_t(0.63)
	var r := InputState.from_bytes(s.to_bytes())
	assert_true(r.commit_wrister_power, "commit flag survives the wire")
	assert_eq(r.bot_wrister_power_t, s.bot_wrister_power_t,
			"a source-quantized power decodes EXACTLY — no prediction divergence")


func test_quantize_power_t_is_wire_exact_across_the_range() -> void:
	# The whole point of quantizing at the source: whatever the sender predicts
	# with must survive to_bytes/from_bytes bit-exactly, not merely closely. The
	# client predicts on the raw InputState object and serializes separately, so
	# any drift here lands on the one tick that sets the shot's launch velocity.
	for raw: float in [0.0, 0.01, 0.137, 0.5, 0.6666667, 0.9, 0.999, 1.0]:
		var s := InputState.new()
		s.commit_wrister_power = true
		s.bot_wrister_power_t = InputState.quantize_power_t(raw)
		var r := InputState.from_bytes(s.to_bytes())
		assert_eq(r.bot_wrister_power_t, s.bot_wrister_power_t,
				"quantized %f round-trips exactly" % raw)


func test_quantize_power_t_clamps_out_of_range() -> void:
	assert_eq(InputState.quantize_power_t(-0.5), 0.0, "negative clamps to 0")
	assert_eq(InputState.quantize_power_t(4.0), 1.0, "above-1 clamps to 1")


func test_bytes_mouse_sender_leaves_power_uncommitted() -> void:
	# A mouse human never sets the flag; the host must fall through to its real
	# measured cursor speed rather than reading the power byte.
	var s := InputState.new()
	var r := InputState.from_bytes(s.to_bytes())
	assert_false(r.commit_wrister_power, "uncommitted by default")


func test_bytes_forged_power_cannot_exceed_ceiling() -> void:
	# Trust boundary: the u8 encoding caps the decode at 1.0 by construction, so a
	# forged payload can't buy a shot above the power ceiling.
	var s := InputState.new()
	s.commit_wrister_power = true
	s.bot_wrister_power_t = 99.0
	var r := InputState.from_bytes(s.to_bytes())
	assert_eq(r.bot_wrister_power_t, 1.0, "forged power clamps to the ceiling")


func test_array_back_compat_defaults_power_uncommitted() -> void:
	# A short array from an older sender must decode with power uncommitted, so
	# the host uses its measured-cursor path instead of a garbage fraction.
	var s := InputState.new()
	s.commit_wrister_power = true
	s.bot_wrister_power_t = 0.5
	var short_array: Array = s.to_array()
	short_array.resize(21)
	var r := InputState.from_array(short_array)
	assert_false(r.commit_wrister_power, "missing commit flag defaults false")


func test_from_bytes_supports_offset() -> void:
	var s := InputState.new()
	s.host_timestamp = 2.0
	s.shoot_pressed = true
	# Embed the bytes at offset 5 inside a larger buffer
	var buf := PackedByteArray(); buf.resize(5 + InputState.BYTES_SIZE)
	var inner := s.to_bytes()
	for i: int in InputState.BYTES_SIZE:
		buf[5 + i] = inner[i]
	var r := InputState.from_bytes(buf, 5)
	assert_almost_eq(r.host_timestamp, 2.0, 0.0001)
	assert_eq(r.shoot_pressed, true)

# ── Wire timestamp precision (u32 @ 0.1ms units) ─────────────────────────────

func test_bytes_round_trip_timestamp_precision_at_long_session() -> void:
	# 5 hours of host uptime. The old f32 encoding had ~2ms ULP here — adjacent
	# 240 Hz stamps (4.17ms apart) were near collision; u32 @ 0.1ms units keeps
	# constant 0.05ms worst-case error regardless of session length.
	var s := InputState.new()
	s.host_timestamp = 18000.123456
	var r := InputState.from_bytes(s.to_bytes())
	assert_almost_eq(r.host_timestamp, s.host_timestamp, 0.0001)


func test_bytes_round_trip_adjacent_240hz_stamps_stay_distinct() -> void:
	var a := InputState.new()
	var b := InputState.new()
	a.host_timestamp = 18000.0
	b.host_timestamp = 18000.0 + 1.0 / 240.0
	var ra := InputState.from_bytes(a.to_bytes())
	var rb := InputState.from_bytes(b.to_bytes())
	assert_true(rb.host_timestamp > ra.host_timestamp,
			"adjacent tick stamps must not quantize equal (dedupe would drop one)")


func test_bytes_negative_timestamp_clamped_to_zero() -> void:
	var s := InputState.new()
	s.host_timestamp = -1.0
	var r := InputState.from_bytes(s.to_bytes())
	assert_almost_eq(r.host_timestamp, 0.0, 0.0001)


# ── move_vector trust boundary ────────────────────────────────────────────────

func test_bytes_forged_long_move_vector_clamped_to_unit() -> void:
	# The s16 wire range admits length ~32; the decode clamps to the unit disc.
	var s := InputState.new()
	s.move_vector = Vector2(30.0, 0.0)
	var r := InputState.from_bytes(s.to_bytes())
	assert_almost_eq(r.move_vector.length(), 1.0, 0.001)
	assert_true(r.move_vector.x > 0.0, "direction preserved")


func test_bytes_legit_move_vector_unchanged() -> void:
	var s := InputState.new()
	s.move_vector = Vector2(0.6, -0.8)  # length 1.0
	var r := InputState.from_bytes(s.to_bytes())
	assert_almost_eq(r.move_vector.x, 0.6, 0.01)
	assert_almost_eq(r.move_vector.y, -0.8, 0.01)


# ── elevation_level trust boundary ───────────────────────────────────────────

func test_bytes_elevation_level_round_trips_each_level() -> void:
	for level: int in [0, 1, 2]:
		var s := InputState.new()
		s.elevation_level = level
		var r := InputState.from_bytes(s.to_bytes())
		assert_eq(r.elevation_level, level, "level %d round-trips" % level)


func test_bytes_forged_elevation_level_clamped() -> void:
	# The 2-bit wire field admits 3; both encode and decode clamp to MAX (2).
	var s := InputState.new()
	s.elevation_level = 7
	var r := InputState.from_bytes(s.to_bytes())
	assert_eq(r.elevation_level, InputState.MAX_ELEVATION_LEVEL)
