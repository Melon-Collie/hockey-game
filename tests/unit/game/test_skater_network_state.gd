extends GutTest

# SkaterNetworkState — serialization round-trip.
# Mirrors test_input_state.gd: catches index shifts when fields are added or
# reordered in to_array / from_array.


func test_round_trip_preserves_all_wire_fields() -> void:
	var s := SkaterNetworkState.new()
	s.position                    = Vector3(1.0, 0.0, -3.5)
	s.velocity                    = Vector3(2.5, 0.0, 0.0)
	s.blade_position              = Vector3(0.3, 0.05, -0.8)
	s.top_hand_position           = Vector3(0.2, 0.4, -0.6)
	s.upper_body_rotation_y       = 0.785
	s.facing                      = Vector2(0.0, -1.0)
	s.facing_angular_velocity     = 1.2
	s.upper_body_angular_velocity = -0.8
	s.last_processed_host_timestamp = 12.345
	s.is_ghost                    = true
	s.elevation_level             = 2
	s.blade_up                    = true
	s.shot_state                  = 2
	s.shot_charge                 = 0.75
	s.stamina                     = 0.4
	s.sprint_locked               = true
	s.stagger_timer               = 0.65
	s.move_intent                 = Vector2(0.0, -1.0)
	s.brake_intent                = true
	s.sprint_active               = true

	var r := SkaterNetworkState.from_array(s.to_array())

	assert_almost_eq(r.position.x,                   s.position.x,                   0.00001)
	assert_almost_eq(r.position.z,                   s.position.z,                   0.00001)
	assert_almost_eq(r.velocity.x,                   s.velocity.x,                   0.00001)
	assert_almost_eq(r.blade_position.z,             s.blade_position.z,             0.00001)
	assert_almost_eq(r.top_hand_position.y,          s.top_hand_position.y,          0.00001)
	assert_almost_eq(r.upper_body_rotation_y,        s.upper_body_rotation_y,        0.00001)
	assert_almost_eq(r.facing.y,                     s.facing.y,                     0.00001)
	assert_almost_eq(r.facing_angular_velocity,      s.facing_angular_velocity,      0.00001)
	assert_almost_eq(r.upper_body_angular_velocity,  s.upper_body_angular_velocity,  0.00001)
	assert_almost_eq(r.last_processed_host_timestamp, s.last_processed_host_timestamp, 0.00001)
	assert_eq(r.is_ghost,        s.is_ghost)
	assert_eq(r.elevation_level, s.elevation_level)
	assert_eq(r.blade_up,        s.blade_up)
	assert_eq(r.shot_state,  s.shot_state)
	assert_almost_eq(r.shot_charge, s.shot_charge, 0.00001)
	assert_almost_eq(r.stamina, s.stamina, 0.00001)
	assert_eq(r.sprint_locked, s.sprint_locked)
	assert_almost_eq(r.stagger_timer, s.stagger_timer, 0.00001)
	assert_eq(r.move_intent, s.move_intent)
	assert_eq(r.brake_intent, s.brake_intent)
	assert_eq(r.sprint_active, s.sprint_active)


func test_array_length_sentinel() -> void:
	# Field-count sentinel — if a field is added without updating to_array /
	# from_array, this catches the mismatch before it becomes a silent bug.
	# 23: position, velocity, blade_position, top_hand_position,
	# upper_body_rotation_y, facing, last_processed_host_timestamp,
	# is_ghost, shot_state, shot_charge, facing_angular_velocity,
	# upper_body_angular_velocity, elevation_level, blade_up, stamina, sprint_locked,
	# stagger_timer, move_intent, brake_intent, sprint_active, knockdown_timer,
	# hit_committed, wrister_address_side.
	var s := SkaterNetworkState.new()
	assert_eq(s.to_array().size(), 23)


func test_blade_up_back_compat_defaults_false() -> void:
	# A short array from an older sender (no blade_up at index 13) must decode
	# without error, defaulting blade_up to false.
	var s := SkaterNetworkState.new()
	s.blade_up = true
	var short_array: Array = s.to_array()
	short_array.resize(13)  # drop blade_up, stamina, sprint_locked
	var r := SkaterNetworkState.from_array(short_array)
	assert_false(r.blade_up, "missing blade_up index should default false")


func test_stamina_back_compat_defaults() -> void:
	# A short array missing stamina/sprint_locked (indices 14/15) must decode
	# with the safe defaults — full stamina, not locked.
	var s := SkaterNetworkState.new()
	s.stamina = 0.2
	s.sprint_locked = true
	var short_array: Array = s.to_array()
	short_array.resize(14)  # keep blade_up, drop stamina + sprint_locked
	var r := SkaterNetworkState.from_array(short_array)
	assert_almost_eq(r.stamina, 1.0, 0.00001, "missing stamina defaults to full")
	assert_false(r.sprint_locked, "missing sprint_locked defaults false")


func test_stagger_back_compat_defaults() -> void:
	# A short array from an older sender (no stagger_timer at index 16) must decode
	# with stagger_timer defaulting to 0 (not staggered).
	var s := SkaterNetworkState.new()
	s.stagger_timer = 0.8
	var short_array: Array = s.to_array()
	short_array.resize(16)  # keep stamina + sprint_locked, drop stagger_timer
	var r := SkaterNetworkState.from_array(short_array)
	assert_almost_eq(r.stagger_timer, 0.0, 0.00001, "missing stagger_timer defaults to 0")


func test_sprint_active_back_compat_defaults_false() -> void:
	# A short array from an older sender (no sprint_active at index 19) must
	# decode with sprint_active defaulting to false (no sprint gait).
	var s := SkaterNetworkState.new()
	s.sprint_active = true
	var short_array: Array = s.to_array()
	short_array.resize(19)  # keep move/brake intent, drop sprint_active
	var r := SkaterNetworkState.from_array(short_array)
	assert_false(r.sprint_active, "missing sprint_active defaults false")


func test_host_only_fields_not_serialized() -> void:
	# host_timestamp, blade_contact_world and top_hand_world must NOT appear in
	# the wire array.
	var s := SkaterNetworkState.new()
	s.host_timestamp = 99.9
	s.blade_contact_world = Vector3(5.0, 0.0, 5.0)
	s.top_hand_world = Vector3(2.0, 1.0, 2.0)
	var r := SkaterNetworkState.from_array(s.to_array())
	assert_almost_eq(r.host_timestamp, 0.0, 0.00001,
			"host_timestamp must not be serialized")
	assert_almost_eq(r.blade_contact_world.x, 0.0, 0.00001,
			"blade_contact_world must not be serialized")
	assert_almost_eq(r.top_hand_world.x, 0.0, 0.00001,
			"top_hand_world must not be serialized")
