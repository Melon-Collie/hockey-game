class_name InputState

const BYTES_SIZE: int = 24
# Layout: u32 timestamp@0.1ms(0) f32 delta(4) s16 move.x(8) s16 move.y(10)
#         s16 mwp.x(12) s8 mwp.y(14) s16 mwp.z(15) s16 msp.x(17) s16 msp.y(19)
#         u16 flags(21)  flags: shoot_pressed[0] shoot_held[1] slap_pressed[2]
#         slap_held[3] sprint_held[4] brake[5] elevation_level[6..7]
#         block_held[8] stick_lift_held[9] stick_lift_pressed[10] quick_pass_pressed[11]
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
# Edge: quick-pass button pressed THIS tick. Fires an instant quick pass (the
# fixed-power blade→cursor snap) without entering wrister aim — LMB is now always
# a charged wrister, so the quick pass lives on its own button to remove the
# tap-vs-hold ambiguity.
var quick_pass_pressed: bool = false
# Held THIS tick: the body-check / hit button (C). A committed "line someone up"
# stance rather than an instantaneous impact — held so the future body-check
# logic can read intent over a window. Networked (reconcile replays it), so it
# lives here rather than as a loose local key read. Not yet consumed by any
# behavior — the button is wired ahead of the hit-system redesign.
var hit_held: bool = false
# Committed wrister power fraction (0..1): the controller converts it to the
# equivalent cursor speed (ShotMechanics.wrister_speed_for_power_t) so a committed
# shooter drives the SAME pure-mouse power model deterministically. Set by bots at
# their shot/pass windup, and by the gamepad path from the right-stick push
# magnitude. Mouse humans leave it at the default (unused — they read real cursor speed).
#
# SERIALIZED as a u8 (see to_bytes) for the gamepad path — bots are host-simulated
# and never cross the wire, but a pad CLIENT's power has to reach the host or the
# host re-derives it from a parked (≈0 speed) cursor and fires a floater while the
# client predicted a full shot. Senders quantize to the wire grid BEFORE predicting
# (LocalInputGatherer / quantize_power_t) so prediction and host agree bit-exactly.
var bot_wrister_power_t: float = 1.0
# Runtime, NOT serialized. True when the wrister POWER is COMMITTED rather than
# measured from cursor motion: power comes from bot_wrister_power_t (with the travel
# gate bypassed) instead of the real cursor speed. Set by the gamepad gatherer while
# RT is held — the pad has no meaningful cursor speed, so the right-stick push
# magnitude is the whole power signal (aim still flows through the positional
# origin→cursor model, since the gamepad parks the cursor in the stick direction).
# Serialized as flag bit [13] (see to_bytes) so a pad CLIENT's committed power
# reaches the host instead of the host falling back to the parked cursor's speed.
var commit_wrister_power: bool = false

# Snap a power fraction to the u8 wire grid. Senders MUST run their value through
# this before predicting with it: the client predicts on the raw InputState object
# (LocalController._process_input) and serializes separately, so an unquantized
# value would have the client predict full precision while the host decodes 1/255
# steps — a divergence on the one tick that sets the whole shot's launch velocity.
# Power is committed once per shot (not per tick, like position), so quantizing at
# the source is cheap here and buys an exact match rather than a tolerance.
# Bots skip this deliberately — host-simulated, never serialized, so they keep
# full precision.
static func quantize_power_t(v: float) -> float:
	return float(roundi(clampf(v, 0.0, 1.0) * 255.0)) / 255.0
# BOT-ONLY, runtime, NOT serialized. The bot's committed shot DIRECTION (world XZ,
# normalized) for a charged wrister/pass, and its committed forehand/backhand.
# Bots have no real cursor, and the human wrister now aims POSITIONALLY (origin→
# cursor) with forehand/backhand read from the cursor's bearing sweep — a bot's
# cosmetic near-body wind-up cursor would make both garbage. So a bot commits its
# aim and hand directly (like it already commits power via bot_wrister_power_t);
# the controller uses them when bot_wrister_aim_dir is non-ZERO (see
# SkaterController._wrister_aim_dir / _wrister_is_backhand). The fake cursor stays
# purely cosmetic (the wind-up coil pose). Humans leave aim_dir ZERO → positional.
var bot_wrister_aim_dir: Vector3 = Vector3.ZERO
var bot_wrister_backhand: bool = false
# BOT-ONLY. World XZ offset (from the skater) where the bot wants its puck to
# FREEZE for the shot — the scored lateral release offset (`_shot_release_offset_locked`).
# The freeze otherwise pins the puck at the centered carry pose; on a breakaway
# that rides into the goalie's poke radius and the shot whiffs. Holding the puck
# at this scored, off-the-poke-line spot (see SkaterController._apply_wrister_aim_blade)
# restores the offset release the scorer priced. ZERO = centered (human / no offset).
var bot_wrister_origin_offset: Vector3 = Vector3.ZERO

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
		quick_pass_pressed,
		hit_held,
		commit_wrister_power,
		bot_wrister_power_t,
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
		(0x400 if stick_lift_pressed else 0) | (0x800 if quick_pass_pressed else 0) |
		(0x1000 if hit_held else 0) | (0x2000 if commit_wrister_power else 0))
	b.encode_u16(21, flags)
	# Committed wrister power as a u8 (0..1 in 1/255 steps). Only meaningful while
	# the commit flag above is set; a mouse sender leaves the default and the host
	# ignores the byte. u8 caps the decode at 1.0 by construction, so a forged
	# payload can't buy a shot above the ceiling.
	b.encode_u8(23, roundi(clampf(bot_wrister_power_t, 0.0, 1.0) * 255.0))
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
	s.quick_pass_pressed = (flags & 0x800) != 0
	s.hit_held           = (flags & 0x1000) != 0
	s.commit_wrister_power = (flags & 0x2000) != 0
	s.bot_wrister_power_t = float(b.decode_u8(offset + 23)) / 255.0
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
		state.quick_pass_pressed = data[19]
	if data.size() > 20:
		state.hit_held = data[20]
	if data.size() > 22:
		state.commit_wrister_power = data[21]
		state.bot_wrister_power_t = clampf(data[22], 0.0, 1.0)
	return state
