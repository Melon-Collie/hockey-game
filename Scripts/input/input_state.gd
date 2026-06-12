class_name InputState

const BYTES_SIZE: int = 23
# Layout: f32 timestamp(0) f32 delta(4) s16 move.x(8) s16 move.y(10)
#         s16 mwp.x(12) s8 mwp.y(14) s16 mwp.z(15) u16 msp.x(17) u16 msp.y(19)
#         u16 flags(21)  flags: shoot_pressed[0] shoot_held[1] slap_pressed[2]
#         slap_held[3] (reserved)[4] brake[5] elevation_up[6] elevation_down[7]
#         block_held[8]

var host_timestamp: float = 0.0
var delta: float = 1.0 / 60.0
var move_vector: Vector2 = Vector2.ZERO
var mouse_world_pos: Vector3 = Vector3.ZERO
var mouse_screen_pos: Vector2 = Vector2.ZERO
var shoot_pressed: bool = false
var shoot_held: bool = false
var slap_pressed: bool = false
var slap_held: bool = false
var brake: bool = false
var elevation_up: bool = false
var elevation_down: bool = false
var block_held: bool = false

func to_array() -> Array:
	return [
		host_timestamp,
		delta,
		move_vector.x,
		move_vector.y,
		mouse_world_pos.x,
		mouse_world_pos.y,
		mouse_world_pos.z,
		shoot_pressed,
		shoot_held,
		slap_pressed,
		slap_held,
		brake,
		elevation_up,
		elevation_down,
		block_held,
		mouse_screen_pos.x,
		mouse_screen_pos.y,
	]

func to_bytes() -> PackedByteArray:
	var b := PackedByteArray(); b.resize(BYTES_SIZE)
	# host_timestamp rides as u32 in 0.1ms units (Constants.TIME_WIRE_SCALE):
	# constant precision over ~119h vs f32's uptime-degrading ULP, which would
	# start quantizing adjacent 240 Hz stamps equal (dedupe-dropped as
	# duplicates) after ~4.6h of host uptime.
	b.encode_u32(0, roundi(maxf(host_timestamp, 0.0) * Constants.TIME_WIRE_SCALE))
	b.encode_float(4, delta)
	b.encode_s16(8,  clampi(roundi(move_vector.x * 1000.0), -32768, 32767))
	b.encode_s16(10, clampi(roundi(move_vector.y * 1000.0), -32768, 32767))
	b.encode_s16(12, clampi(roundi(mouse_world_pos.x * 100.0), -32768, 32767))
	b.encode_s8( 14, clampi(roundi(mouse_world_pos.y * 100.0), -128, 127))
	b.encode_s16(15, clampi(roundi(mouse_world_pos.z * 100.0), -32768, 32767))
	b.encode_u16(17, clampi(roundi(mouse_screen_pos.x), 0, 65535))
	b.encode_u16(19, clampi(roundi(mouse_screen_pos.y), 0, 65535))
	var flags: int = (
		(0x001 if shoot_pressed  else 0) | (0x002 if shoot_held     else 0) |
		(0x004 if slap_pressed   else 0) | (0x008 if slap_held      else 0) |
										   (0x020 if brake          else 0) |
		(0x040 if elevation_up   else 0) | (0x080 if elevation_down else 0) |
		(0x100 if block_held     else 0))
	b.encode_u16(21, flags)
	return b


static func from_bytes(b: PackedByteArray, offset: int = 0) -> InputState:
	var s := InputState.new()
	s.host_timestamp     = float(b.decode_u32(offset)) / Constants.TIME_WIRE_SCALE
	s.delta              = b.decode_float(offset + 4)
	s.move_vector.x      = b.decode_s16(offset + 8)  / 1000.0
	s.move_vector.y      = b.decode_s16(offset + 10) / 1000.0
	# The s16 wire range admits magnitudes up to ~32.7 and the movement rules
	# consume the vector unnormalized as thrust direction — clamp to the unit
	# disc at the trust boundary so a forged long vector can't buy instant
	# 0-to-max acceleration / one-tick 180° flips in a momentum-skating game.
	s.move_vector        = s.move_vector.limit_length(1.0)
	s.mouse_world_pos.x  = b.decode_s16(offset + 12) / 100.0
	s.mouse_world_pos.y  = b.decode_s8( offset + 14) / 100.0
	s.mouse_world_pos.z  = b.decode_s16(offset + 15) / 100.0
	s.mouse_screen_pos.x = float(b.decode_u16(offset + 17))
	s.mouse_screen_pos.y = float(b.decode_u16(offset + 19))
	var flags: int       = b.decode_u16(offset + 21)
	s.shoot_pressed      = (flags & 0x001) != 0
	s.shoot_held         = (flags & 0x002) != 0
	s.slap_pressed       = (flags & 0x004) != 0
	s.slap_held          = (flags & 0x008) != 0
	s.brake              = (flags & 0x020) != 0
	s.elevation_up       = (flags & 0x040) != 0
	s.elevation_down     = (flags & 0x080) != 0
	s.block_held         = (flags & 0x100) != 0
	return s


static func from_array(data: Array) -> InputState:
	var state := InputState.new()
	state.host_timestamp = data[0]
	state.delta = data[1]
	state.move_vector = Vector2(data[2], data[3])
	state.mouse_world_pos = Vector3(data[4], data[5], data[6])
	state.shoot_pressed = data[7]
	state.shoot_held = data[8]
	state.slap_pressed = data[9]
	state.slap_held = data[10]
	state.brake = data[11]
	state.elevation_up = data[12]
	state.elevation_down = data[13]
	state.block_held = data[14]
	state.mouse_screen_pos = Vector2(data[15], data[16])
	return state
