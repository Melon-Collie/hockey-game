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
	s.quick_shot_pressed = true
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
	assert_eq(r.quick_shot_pressed, s.quick_shot_pressed)
	assert_eq(r.hit_held,           s.hit_held)


func test_array_length_sentinel() -> void:
	# Field count sentinel — if someone adds a field without updating
	# to_array/from_array, this catches the mismatch.
	var s := InputState.new()
	assert_eq(s.to_array().size(), 21)


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
	s.quick_shot_pressed = true
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
	assert_eq(r.quick_shot_pressed, s.quick_shot_pressed)
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
	assert_eq(InputState.BYTES_SIZE, 23)


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
