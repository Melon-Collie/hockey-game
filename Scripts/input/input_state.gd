class_name InputState

const BYTES_SIZE: int = 23
# Layout: f32 timestamp(0) f32 delta(4) s16 move.x(8) s16 move.y(10)
#         s16 mwp.x(12) s8 mwp.y(14) s16 mwp.z(15) s16 msp.x(17) s16 msp.y(19)
#         u16 flags(21)  flags: shoot_pressed[0] shoot_held[1] slap_pressed[2]
#         slap_held[3] sprint_held[4] brake[5] elevation_level[6..7]
#         block_held[8] stick_lift_held[9] stick_lift_pressed[10] quick_shot_pressed[11]
#         hit_held[12]

# Highest legal loft level (ShotMechanics.ELEVATION_HIGH). Decode clamps the
# 2-bit wire field to this so a forged 3 can't reach the shot math.
const MAX_ELEVATION_LEVEL: int = ShotMechanics.ELEVATION_HIGH

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
# Loft mode, ABSOLUTE each tick (not an edge): 0 flat / 1 low / 2 high. The
# gatherer owns the scroll-adjusted mode and stamps the current value into
# every input frame, so replaying an input during reconcile is idempotent —
# there is no sticky controller state to snap or double-apply.
var elevation_level: int = 0
var block_held: bool = false
var stick_lift_held: bool = false
# Edge: stick-lift pressed THIS tick. Latched in the gatherer like shoot_pressed
# so it survives the physics-tick / input-frame cadence mismatch and replays
# deterministically. Drives the nudge self-tap (Q while carrying).
var stick_lift_pressed: bool = false
var sprint_held: bool = false
# Edge: quick-shot / pass button pressed THIS tick. Fires an instant quick shot
# (the fixed-power player→blade snap that doubles as a pass) without entering
# wrister aim — LMB is now always a charged wrister, so the quick shot lives on
# its own button to remove the tap-vs-hold ambiguity.
var quick_shot_pressed: bool = false
# Held THIS tick: the body-check / hit button (C). A committed "line someone up"
# stance rather than an instantaneous impact — held so the future body-check
# logic can read intent over a window. Networked (reconcile replays it), so it
# lives here rather than as a loose local key read. Not yet consumed by any
# behavior — the button is wired ahead of the hit-system redesign.
var hit_held: bool = false
# BOT-ONLY, runtime, NOT serialized (bots are host-simulated, never sent over
# the wire). Target wrister power fraction (0..1) a bot commits to at its shot/
# pass windup; the controller converts it to the equivalent cursor speed
# (ShotMechanics.wrister_speed_for_power_t) so bots drive the SAME pure-mouse
# power model deterministically. Humans leave it at the default (unused — they
# read real cursor speed).
var bot_wrister_power_t: float = 1.0

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
		elevation_level,
		block_held,
		mouse_screen_pos.x,
		mouse_screen_pos.y,
		stick_lift_held,
		sprint_held,
		stick_lift_pressed,
		quick_shot_pressed,
		hit_held,
	]

func to_bytes() -> PackedByteArray:
	var b := PackedByteArray(); b.resize(BYTES_SIZE)
	# host_timestamp rides as u32 in 0.1ms units (Constants.TIME_WIRE_SCALE):
	# constant precision over ~119h vs f32's uptime-degrading ULP, which would
	# start quantizing adjacent per-tick stamps equal (dedupe-dropped as
	# duplicates) after ~4.6h of host uptime.
	b.encode_u32(0, roundi(maxf(host_timestamp, 0.0) * Constants.TIME_WIRE_SCALE))
	b.encode_float(4, delta)
	b.encode_s16(8,  clampi(roundi(move_vector.x * 1000.0), -32768, 32767))
	b.encode_s16(10, clampi(roundi(move_vector.y * 1000.0), -32768, 32767))
	b.encode_s16(12, clampi(roundi(mouse_world_pos.x * 100.0), -32768, 32767))
	b.encode_s8( 14, clampi(roundi(mouse_world_pos.y * 100.0), -128, 127))
	b.encode_s16(15, clampi(roundi(mouse_world_pos.z * 100.0), -32768, 32767))
	# SIGNED s16: attack_up team-1 players negate mouse_screen_pos in the gatherer
	# to pre-align the cursor-drag frame to world XZ (see LocalInputGatherer.gather).
	# A u16 clamp floored those negatives to 0, so the host saw a frozen (0,0)
	# cursor — zero wrister charge + null charge direction — and fired every drag
	# as a tap. Screen coords (even negated, even at 8K) fit in ±32767.
	b.encode_s16(17, clampi(roundi(mouse_screen_pos.x), -32768, 32767))
	b.encode_s16(19, clampi(roundi(mouse_screen_pos.y), -32768, 32767))
	var flags: int = (
		(0x001 if shoot_pressed  else 0) | (0x002 if shoot_held     else 0) |
		(0x004 if slap_pressed   else 0) | (0x008 if slap_held      else 0) |
		(0x010 if sprint_held    else 0) | (0x020 if brake          else 0) |
		((clampi(elevation_level, 0, MAX_ELEVATION_LEVEL) & 0x3) << 6) |
		(0x100 if block_held     else 0) | (0x200 if stick_lift_held else 0) |
		(0x400 if stick_lift_pressed else 0) | (0x800 if quick_shot_pressed else 0) |
		(0x1000 if hit_held else 0))
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
	s.mouse_screen_pos.x = float(b.decode_s16(offset + 17))
	s.mouse_screen_pos.y = float(b.decode_s16(offset + 19))
	var flags: int       = b.decode_u16(offset + 21)
	s.shoot_pressed      = (flags & 0x001) != 0
	s.shoot_held         = (flags & 0x002) != 0
	s.slap_pressed       = (flags & 0x004) != 0
	s.slap_held          = (flags & 0x008) != 0
	s.sprint_held        = (flags & 0x010) != 0
	s.brake              = (flags & 0x020) != 0
	s.elevation_level    = mini((flags >> 6) & 0x3, MAX_ELEVATION_LEVEL)
	s.block_held         = (flags & 0x100) != 0
	s.stick_lift_held    = (flags & 0x200) != 0
	s.stick_lift_pressed = (flags & 0x400) != 0
	s.quick_shot_pressed = (flags & 0x800) != 0
	s.hit_held           = (flags & 0x1000) != 0
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
	state.elevation_level = mini(int(data[12]), MAX_ELEVATION_LEVEL)
	state.block_held = data[13]
	state.mouse_screen_pos = Vector2(data[14], data[15])
	if data.size() > 16:
		state.stick_lift_held = data[16]
	if data.size() > 17:
		state.sprint_held = data[17]
	if data.size() > 18:
		state.stick_lift_pressed = data[18]
	if data.size() > 19:
		state.quick_shot_pressed = data[19]
	if data.size() > 20:
		state.hit_held = data[20]
	return state
