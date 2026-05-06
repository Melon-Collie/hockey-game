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
	s.shot_state                  = 2
	s.shot_charge                 = 0.75

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
	assert_eq(r.is_ghost,    s.is_ghost)
	assert_eq(r.shot_state,  s.shot_state)
	assert_almost_eq(r.shot_charge, s.shot_charge, 0.00001)


func test_array_length_is_thirteen() -> void:
	# Field-count sentinel — if a field is added without updating to_array /
	# from_array, this catches the mismatch before it becomes a silent bug.
	# 13: position, velocity, blade_position, top_hand_position,
	# upper_body_rotation_y, facing, last_processed_host_timestamp,
	# is_ghost, shot_state, shot_charge, facing_angular_velocity,
	# upper_body_angular_velocity, is_elevated.
	var s := SkaterNetworkState.new()
	assert_eq(s.to_array().size(), 13)


func test_host_only_fields_not_serialized() -> void:
	# host_timestamp and blade_contact_world must NOT appear in the wire array.
	var s := SkaterNetworkState.new()
	s.host_timestamp = 99.9
	s.blade_contact_world = Vector3(5.0, 0.0, 5.0)
	var r := SkaterNetworkState.from_array(s.to_array())
	assert_almost_eq(r.host_timestamp, 0.0, 0.00001,
			"host_timestamp must not be serialized")
	assert_almost_eq(r.blade_contact_world.x, 0.0, 0.00001,
			"blade_contact_world must not be serialized")
