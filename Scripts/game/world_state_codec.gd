class_name WorldStateCodec
extends RefCounted

# Handles the flat PackedByteArray serialization format that `NetworkManager`
# ferries between host and clients. Pulled out of GameManager so the wire
# format lives in one place and the application layer speaks in typed
# network-state objects.
#
# Two wire formats are defined here:
#
# 1. World state  (120 Hz, unreliable_ordered) — single flat PackedByteArray:
#      u16 ws_sequence, u32 host_capture_time (0.1ms units), u8 num_skaters
#      [u32 peer_id, skater_bytes(40), u8 queue_depth] × num_skaters
#      puck_bytes(13)
#      u8 num_goalies, [goalie_bytes(43)] × num_goalies
#      u8 score0, u8 score1, u8 phase, u8 period, u16 time_remaining
#
#    Total for 6 players + 2 goalies: 383 bytes — stays in a single packet, well
#    under Steam's ~1200-byte unreliable cap. This matters: Steam (unlike ENet)
#    does NOT fragment unreliable messages, so an oversized snapshot would be
#    dropped at send rather than split across datagrams.
#
#    Quantization layout:
#      Skater  (40 B): pos s16/s8/s16@1cm, vel 3×s16@0.02m/s,
#                      blade 3×s16@1cm, top_hand 3×s16@1cm,
#                      facing u16 (0–TAU→0–65535), upper_body_rot s16 (−π–π→−32767–32767),
#                      facing_angular_velocity s16@PI*10 rad/s, upper_body_angular_velocity s16@PI*10 rad/s,
#                      last_processed_ts f32,
#                      flags u8 (shot_state[2:0]+elevation_level[4:3]+ghost[5]+blade_up[6]+sprint_locked[7]),
#                      shot_charge u8, stamina u8, stagger_timer u8@0.01s,
#                      intent u8 (move octant[2:0]+moving[3]+brake[4] v15, sprint[5] v16)
#      Puck    (13 B): pos s16/s16/s16@1cm, vel 3×s16@0.02m/s, carrier_idx u8 (0xFF=none)
#      Goalie  (43 B): root (12 B) + pose (31 B). Root:
#                      pos_x/z s16@1cm, rot_y s16@π/32767, state u8, fho u8,
#                      vel_x/z s16@0.02m/s.
#                      Pose: body_pitch/roll s8@π/127; left_pad offset (s8×3@1cm)
#                      + pitch/roll/yaw s8@π/127 (yaw = rebound-steering toe-out,
#                      v13); right_pad same; glove offset s16×3
#                      + yaw/pitch s8@π/127; blocker same; head_yaw s8@π/127.
#                      Stick rides the blocker socket (rigid IRL attachment),
#                      so no separate stick fields on the wire. The broadcast
#                      pose is authoritative: clients render the goalie purely
#                      from the interpolated host pose (no client-side goalie
#                      AI — see ARCHITECTURE.md Networking Invariants).
#
# 2. Stats  (reliable, event-driven):
#      [pid, G, A, SOG, HITS, BLK] × N players
#      team_shots[0], team_shots[1]
#      period_scores[0][0..P-1], period_scores[1][0..P-1]
#      num_periods (trailing sentinel)
#
# Emits signals for any state-change the decode detects; GameManager relays
# them to the rest of the game.

signal phase_changed(new_phase: int)
signal game_over_triggered()
signal period_synced(period: int)
signal clock_updated(time_remaining: float)
signal shots_on_goal_changed(sog_0: int, sog_1: int)
signal queue_depth_feedback(depth: int)

const WS_HEADER_SIZE: int = 7      # u16 ws_seq (2) + f32 host_capture_time (4) + u8 num_skaters (1)
const SKATER_STATE_BYTES: int = 40  # inner skater state block (was hardcoded 39 at two
                                    # decode sites and silently truncated on the v15 grow)
const SKATER_BLOCK_SIZE: int = SKATER_STATE_BYTES + 5  # + u32 peer_id + u8 queue_depth
const PUCK_BLOCK_SIZE: int = 13    # 12B pos+vel + 1B carrier_idx
const GOALIE_BLOCK_SIZE: int = 43  # 12 root + 31 pose (glove/blocker offsets are s16-wide)
const GAME_STATE_BLOCK_SIZE: int = 6  # 4×u8 + u16 time_remaining
const STATS_PLAYER_RECORD_SIZE: int = 12  # peer_id + PlayerStats.to_array() (11)

var _ws_sequence: int = 0
var _last_period: int = -1
var _last_clock_second: int = -1

var _registry: PlayerRegistry = null
var _state_machine: GameStateMachine = null
var _puck_getter: Callable = Callable()
var _puck_controller_getter: Callable = Callable()  # decode side only
var _goalie_controllers_getter: Callable = Callable()
var _state_buffer: StateBufferManager = null


func setup(
		registry: PlayerRegistry,
		state_machine: GameStateMachine,
		puck_getter: Callable,
		puck_controller_getter: Callable,
		goalie_controllers_getter: Callable,
		state_buffer: StateBufferManager) -> void:
	_registry = registry
	_state_machine = state_machine
	_puck_getter = puck_getter
	_puck_controller_getter = puck_controller_getter
	_goalie_controllers_getter = goalie_controllers_getter
	_state_buffer = state_buffer


# ── World state ──────────────────────────────────────────────────────────────

func encode_world_state() -> PackedByteArray:
	if _state_buffer == null or not _state_buffer.is_ready() or _state_machine == null:
		return PackedByteArray()
	var peers: Array = Array(_registry.all().keys())
	var goalie_controllers: Array = _goalie_controllers_getter.call()
	var b := PackedByteArray()
	# Header: u16 sequence + u32 host_capture_time (0.1ms units) + u8 skater count
	var hdr := PackedByteArray(); hdr.resize(WS_HEADER_SIZE)
	hdr.encode_u16(0, _ws_sequence)
	_ws_sequence = (_ws_sequence + 1) & 0xFFFF
	hdr.encode_u32(2, roundi(maxf(NetworkManager.local_time(), 0.0) * Constants.TIME_WIRE_SCALE))
	hdr.encode_u8(6, peers.size())
	b.append_array(hdr)
	# Skaters: u32 peer_id + 40B state + u8 queue_depth
	for peer_id: int in peers:
		var record: PlayerRecord = _registry.get_record(peer_id)
		var depth: int = 0
		if record != null and not record.is_local:
			depth = record.controller.get_queue_depth()
		var id_bytes := PackedByteArray(); id_bytes.resize(4)
		# encode_s32 (not u32) so negative AI bot peer_ids round-trip correctly.
		# For real ENet peer ids (always positive) the encoded bytes are
		# identical to u32, so this is wire-compatible with existing builds.
		id_bytes.encode_s32(0, peer_id)
		b.append_array(id_bytes)
		b.append_array(_encode_skater_quantized(_state_buffer.latest_skater_state(peer_id)))
		b.append(clampi(depth, 0, 255))
	# Puck: 12B pos+vel + 1B carrier index (0xFF = no carrier).
	# Carrier is encoded as the index of the carrier's peer_id in the peers array
	# above so the client can resolve it without a separate peer_id lookup.
	var puck_state := _state_buffer.latest_puck_state()
	b.append_array(_encode_puck_quantized(puck_state))
	var carrier_idx: int = 0xFF
	if puck_state.carrier_peer_id != -1:
		var idx: int = peers.find(puck_state.carrier_peer_id)
		if idx >= 0:
			carrier_idx = idx
	b.append(carrier_idx)
	# Goalies: u8 count + n × GOALIE_BLOCK_SIZE (43B)
	b.append(goalie_controllers.size())
	for gc: GoalieController in goalie_controllers:
		b.append_array(_encode_goalie_quantized(_state_buffer.latest_goalie_state(gc.team_id)))
	# Game state: 4×u8 + u16
	var gs := PackedByteArray(); gs.resize(GAME_STATE_BLOCK_SIZE)
	gs.encode_u8(0, clampi(_state_machine.scores[0], 0, 255))
	gs.encode_u8(1, clampi(_state_machine.scores[1], 0, 255))
	gs.encode_u8(2, _state_machine.current_phase)
	gs.encode_u8(3, clampi(_state_machine.current_period, 0, 255))
	gs.encode_u16(4, clampi(int(ceil(_state_machine.time_remaining)), 0, 65535))
	b.append_array(gs)
	return b


func decode_world_state(data: PackedByteArray) -> void:
	var goalie_controllers: Array = _goalie_controllers_getter.call()
	if data.size() < WS_HEADER_SIZE:
		push_warning("WorldStateCodec: packet too small (%d bytes)" % data.size())
		return
	var o: int = 0
	o += 2  # ws_sequence already consumed by NetworkManager for loss tracking
	var host_ts: float = float(data.decode_u32(o)) / Constants.TIME_WIRE_SCALE; o += 4
	var num_skaters: int = data.decode_u8(o); o += 1
	var min_size: int = WS_HEADER_SIZE + num_skaters * SKATER_BLOCK_SIZE + PUCK_BLOCK_SIZE + 1 + GAME_STATE_BLOCK_SIZE
	if data.size() < min_size:
		push_warning("WorldStateCodec: truncated (got %d, need %d)" % [data.size(), min_size])
		return
	# During the goal-replay cinematic, GoalReplayDriver owns actor positions
	# locally. Broadcast packets keep arriving (frozen state from the host),
	# but applying them would fight the driver's apply_replay_state writes.
	# Skip actor application; still walk the byte cursor so the trailing
	# game-state block lands at the right offset.
	var skip_actors: bool = NetworkManager.is_replay_mode()
	# Skaters — collect peer_ids in packet order so we can resolve the puck carrier index below.
	var decoded_peers: Array[int] = []
	for _i: int in num_skaters:
		# decode_s32 to match the encoder; negative ids are AI bots.
		var peer_id: int = data.decode_s32(o); o += 4
		decoded_peers.append(peer_id)
		var skater_bytes: PackedByteArray = data.slice(o, o + SKATER_STATE_BYTES); o += SKATER_STATE_BYTES
		var depth: int = data.decode_u8(o); o += 1
		if skip_actors:
			continue
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record == null:
			continue
		var skater_state := _decode_skater_quantized(skater_bytes)
		if record.is_local and not NetworkManager.is_replay_mode():
			(record.controller as LocalController).reconcile(skater_state)
			queue_depth_feedback.emit(depth)
		else:
			record.controller.apply_network_state(skater_state, host_ts)
	# Puck: 12B pos+vel + 1B carrier index. 0xFF is the "no carrier"
	# sentinel — checked explicitly so a future bump of MAX_CONNECTIONS
	# past 255 doesn't silently alias the sentinel onto a real index.
	var puck_state := _decode_puck_quantized(data.slice(o, o + 12)); o += 12
	var carrier_idx: int = data.decode_u8(o); o += 1
	puck_state.carrier_peer_id = -1 if carrier_idx == 0xFF or carrier_idx >= decoded_peers.size() else decoded_peers[carrier_idx]
	if not skip_actors:
		var puck_controller: PuckController = _puck_controller_getter.call() as PuckController
		if puck_controller != null:
			puck_controller.apply_state(puck_state, host_ts)
	# Goalies
	var num_goalies: int = data.decode_u8(o); o += 1
	for gi: int in mini(num_goalies, goalie_controllers.size()):
		if o + GOALIE_BLOCK_SIZE > data.size():
			push_warning("WorldStateCodec: truncated goalie block %d" % gi)
			return
		if not skip_actors:
			goalie_controllers[gi].apply_state(_decode_goalie_quantized(data.slice(o, o + GOALIE_BLOCK_SIZE)), host_ts)
		o += GOALIE_BLOCK_SIZE
	o += maxi(0, num_goalies - goalie_controllers.size()) * GOALIE_BLOCK_SIZE
	# Game state
	if data.size() < o + GAME_STATE_BLOCK_SIZE:
		return
	var score0: int = data.decode_u8(o)
	var score1: int = data.decode_u8(o + 1)
	var new_phase: GamePhase.Phase = data.decode_u8(o + 2) as GamePhase.Phase
	var period: int = data.decode_u8(o + 3)
	var t_remaining: float = float(data.decode_u16(o + 4))
	_apply_game_state(score0, score1, new_phase, period, t_remaining)


func _apply_game_state(score0: int, score1: int, new_phase: GamePhase.Phase,
		period: int, t_remaining: float) -> void:
	var phase_changed_this_tick: bool = _state_machine.apply_remote_state(
			score0, score1, new_phase, period, t_remaining)
	if phase_changed_this_tick:
		var puck: Puck = _puck_getter.call() as Puck
		if puck != null:
			puck.pickup_locked = PhaseRules.is_puck_pickup_locked_phase(new_phase)
		if new_phase == GamePhase.Phase.GAME_OVER:
			game_over_triggered.emit()
		phase_changed.emit(new_phase)
	if period != _last_period:
		_last_period = period
		period_synced.emit(period)
	# Emit only when the displayed second changes (mirrors the host's 1 Hz
	# gate in GameManager). Per-packet emission made clients rebuild the HUD
	# clock label + dirty its theme cache at 120 Hz for an unchanged display.
	var whole_second: int = int(ceilf(t_remaining))
	if whole_second != _last_clock_second:
		_last_clock_second = whole_second
		clock_updated.emit(t_remaining)


# ── Replay decode (host-side, no side effects) ───────────────────────────────

# Decodes a recorded packet into typed actor states without touching the game
# state machine, controllers, or signals. GoalReplayDriver uses this on the
# host because decode_world_state is designed for clients receiving authoritative
# state — calling it here would slam the live state machine (phase, score) back
# to whatever the recorded packet contained.
#
# Returns:
#   {
#     host_ts:         float,
#     skaters:         Dictionary[int, SkaterNetworkState],   # peer_id → state
#     puck:            PuckNetworkState (or null on malformed input),
#     carrier_peer_id: int,                                   # -1 if no carrier
#     goalies:         Array[GoalieNetworkState]              # team index order
#   }
# Or {} if the packet is too small to decode.
func decode_for_replay(data: PackedByteArray) -> Dictionary:
	if data.size() < WS_HEADER_SIZE:
		return {}
	var o: int = 0
	o += 2  # ws_sequence
	var host_ts: float = float(data.decode_u32(o)) / Constants.TIME_WIRE_SCALE; o += 4
	var num_skaters: int = data.decode_u8(o); o += 1
	var min_size: int = WS_HEADER_SIZE + num_skaters * SKATER_BLOCK_SIZE + PUCK_BLOCK_SIZE + 1 + GAME_STATE_BLOCK_SIZE
	if data.size() < min_size:
		return {}

	var skaters: Dictionary = {}
	var decoded_peers: Array[int] = []
	for _i: int in num_skaters:
		var peer_id: int = data.decode_s32(o); o += 4
		decoded_peers.append(peer_id)
		var skater_bytes: PackedByteArray = data.slice(o, o + SKATER_STATE_BYTES); o += SKATER_STATE_BYTES
		o += 1  # queue_depth (not needed for replay)
		skaters[peer_id] = _decode_skater_quantized(skater_bytes)

	var puck_state := _decode_puck_quantized(data.slice(o, o + 12)); o += 12
	var carrier_idx: int = data.decode_u8(o); o += 1
	# 0xFF is the encoder's "no carrier" sentinel — see decode_world_state.
	var carrier_peer_id: int = -1 if carrier_idx == 0xFF or carrier_idx >= decoded_peers.size() else decoded_peers[carrier_idx]

	var num_goalies: int = data.decode_u8(o); o += 1
	# Validate up-front so a maliciously-crafted file with num_goalies = 255
	# and a short payload doesn't partially decode goalies and then read the
	# game-state block from a stale offset past EOF. Refuse the whole packet
	# if the claimed goalie count overruns the buffer.
	if o + num_goalies * GOALIE_BLOCK_SIZE + GAME_STATE_BLOCK_SIZE > data.size():
		return {}
	var goalies: Array[GoalieNetworkState] = []
	for _gi: int in num_goalies:
		goalies.append(_decode_goalie_quantized(data.slice(o, o + GOALIE_BLOCK_SIZE)))
		o += GOALIE_BLOCK_SIZE

	# Game state block follows the goalies. The viewer needs score / phase /
	# period / clock to render the HUD; live decode_world_state side-effects
	# game state into the live state machine, so that path can't be reused.
	var game_state: Dictionary = {
		"score0": data.decode_u8(o),
		"score1": data.decode_u8(o + 1),
		"phase": data.decode_u8(o + 2),
		"period": data.decode_u8(o + 3),
		"time_remaining": float(data.decode_u16(o + 4)),
	}

	return {
		host_ts = host_ts,
		skaters = skaters,
		puck = puck_state,
		carrier_peer_id = carrier_peer_id,
		goalies = goalies,
		game_state = game_state,
	}


# ── Stats ────────────────────────────────────────────────────────────────────

func encode_stats() -> Array:
	var data: Array = []
	var players := _registry.all()
	for pid: int in players:
		data.append(pid)
		data.append_array(players[pid].stats.to_array())
	data.append(_state_machine.team_shots[0])
	data.append(_state_machine.team_shots[1])
	for team_id: int in 2:
		data.append_array(_state_machine.period_scores[team_id])
	data.append(_state_machine.period_scores[0].size())  # sentinel
	return data


func decode_stats(data: Array) -> void:
	# Defensive decode: this only arrives from the host (authority RPC), but a
	# version-skewed host sends a shape whose unguarded index walk script-errors
	# on every stats sync — turning "mixed versions" into error spam. Bail with
	# a warning instead; the protocol handshake is the real gate.
	if data.is_empty() or typeof(data[-1]) != TYPE_INT:
		push_warning("WorldStateCodec: malformed stats payload (empty or non-int footer)")
		return
	var num_periods: int = data[-1]
	var footer_size: int = 2 + 2 * num_periods + 1  # shots×2 + scores×2P + sentinel
	if num_periods < 0 or num_periods > 64 or data.size() < footer_size:
		push_warning("WorldStateCodec: malformed stats payload (periods=%d, size=%d)" % [num_periods, data.size()])
		return
	var players_end: int = data.size() - footer_size
	if players_end % STATS_PLAYER_RECORD_SIZE != 0 \
			or typeof(data[players_end]) != TYPE_INT or typeof(data[players_end + 1]) != TYPE_INT:
		push_warning("WorldStateCodec: malformed stats payload (player block %d not a multiple of %d)"
				% [players_end, STATS_PLAYER_RECORD_SIZE])
		return
	var i: int = 0
	while i < players_end:
		var pid: int = data[i]
		var record: PlayerRecord = _registry.get_record(pid)
		if record != null:
			# Update in place rather than reassigning: record.stats carries
			# toi_seconds, which is tracked locally and absent from the wire.
			# A fresh from_array() object would reset it to zero every packet.
			if record.stats == null:
				record.stats = PlayerStats.new()
			record.stats.update_from_array(
					data.slice(i + 1, i + STATS_PLAYER_RECORD_SIZE))
		i += STATS_PLAYER_RECORD_SIZE
	_state_machine.team_shots[0] = data[i]
	_state_machine.team_shots[1] = data[i + 1]
	i += 2
	while _state_machine.period_scores[0].size() < num_periods:
		_state_machine.period_scores[0].append(0)
		_state_machine.period_scores[1].append(0)
	for team_id: int in 2:
		for p: int in num_periods:
			_state_machine.period_scores[team_id][p] = data[i]
			i += 1
	shots_on_goal_changed.emit(
			_state_machine.team_shots[0], _state_machine.team_shots[1])


# ── Quantization helpers ──────────────────────────────────────────────────────

# Skater: SKATER_STATE_BYTES (40) bytes
# Offsets: pos(0..4) vel(5..10) blade(11..16) top_hand(17..22)
#          facing(23..24) ubrot(25..26) fav(27..28) ubav(29..30) lp_ts(31..34)
#          flags(35) charge(36) stamina(37) stagger(38)
static func _encode_skater_quantized(s: SkaterNetworkState) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(40)
	var o: int = 0
	b.encode_s16(o, clampi(roundi(s.position.x * 100.0), -32768, 32767)); o += 2
	b.encode_s8(o, clampi(roundi(s.position.y * 100.0), -128, 127)); o += 1
	b.encode_s16(o, clampi(roundi(s.position.z * 100.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.velocity.x * 50.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.velocity.y * 50.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.velocity.z * 50.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.blade_position.x * 100.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.blade_position.y * 100.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.blade_position.z * 100.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.top_hand_position.x * 100.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.top_hand_position.y * 100.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.top_hand_position.z * 100.0), -32768, 32767)); o += 2
	var angle: float = atan2(s.facing.x, s.facing.y)
	if angle < 0.0:
		angle += TAU
	b.encode_u16(o, roundi(angle / TAU * 65535.0) & 0xFFFF); o += 2
	b.encode_s16(o, clampi(roundi(s.upper_body_rotation_y / PI * 32767.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.facing_angular_velocity / (PI * 10.0) * 32767.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.upper_body_angular_velocity / (PI * 10.0) * 32767.0), -32768, 32767)); o += 2
	b.encode_u32(o, roundi(maxf(s.last_processed_host_timestamp, 0.0) * Constants.TIME_WIRE_SCALE)); o += 4
	# Flags byte: bits 0-2 shot_state (7 SkaterStateMachine.State values),
	# bits 3-4 elevation_level (0..2), bit 5 ghost, bit 6 blade_up,
	# bit 7 sprint_locked. Repacked at PROTOCOL_VERSION 11 (shot_state gave a
	# bit to the 2-bit loft level).
	var flags: int = (s.shot_state & 0x07) \
			| ((clampi(s.elevation_level, 0, 3) & 0x3) << 3) \
			| (0x20 if s.is_ghost else 0) \
			| (0x40 if s.blade_up else 0) \
			| (0x80 if s.sprint_locked else 0)
	b.encode_u8(o, flags); o += 1
	b.encode_u8(o, clampi(roundi(s.shot_charge * 255.0), 0, 255)); o += 1
	b.encode_u8(o, clampi(roundi(s.stamina * 255.0), 0, 255)); o += 1
	# Body-check stagger seconds remaining, u8 @ 0.01 s (0..2.55 s covers
	# stagger_max_seconds 1.0 with headroom). Without this the client victim's
	# predicted stagger was wiped to 0 on the next reconcile — full-thrust replay
	# vs the host's penalised sim → a reconcile storm for the whole stagger window.
	b.encode_u8(o, clampi(roundi(s.stagger_timer * 100.0), 0, 255)); o += 1
	# Movement-intent byte (v15): bits [0..2] move-direction octant, bit [3]
	# moving, bit [4] brake held, bit [5] sprint active (v16). WASD is 8-way,
	# so the octant quantization is lossless; the gait reads intent (glide /
	# crossover anticipation / brake-gated hockey stop / sprint stride) on
	# client-rendered remotes from this.
	var intent: int = 0
	if s.move_intent.length_squared() > 0.0025:
		var oct: int = wrapi(roundi(atan2(s.move_intent.x, s.move_intent.y) / (PI / 4.0)), 0, 8)
		intent = oct | 0x08
	if s.brake_intent:
		intent |= 0x10
	if s.sprint_active:
		intent |= 0x20
	b.encode_u8(o, intent)
	return b


static func _decode_skater_quantized(b: PackedByteArray) -> SkaterNetworkState:
	if b.size() < 40:
		push_warning("WorldStateCodec: truncated skater block (%d bytes)" % b.size())
		return SkaterNetworkState.new()
	var s := SkaterNetworkState.new()
	var o: int = 0
	s.position.x = b.decode_s16(o) / 100.0; o += 2
	s.position.y = b.decode_s8(o) / 100.0; o += 1
	s.position.z = b.decode_s16(o) / 100.0; o += 2
	s.velocity.x = b.decode_s16(o) / 50.0; o += 2
	s.velocity.y = b.decode_s16(o) / 50.0; o += 2
	s.velocity.z = b.decode_s16(o) / 50.0; o += 2
	s.blade_position.x = b.decode_s16(o) / 100.0; o += 2
	s.blade_position.y = b.decode_s16(o) / 100.0; o += 2
	s.blade_position.z = b.decode_s16(o) / 100.0; o += 2
	s.top_hand_position.x = b.decode_s16(o) / 100.0; o += 2
	s.top_hand_position.y = b.decode_s16(o) / 100.0; o += 2
	s.top_hand_position.z = b.decode_s16(o) / 100.0; o += 2
	var angle: float = b.decode_u16(o) / 65535.0 * TAU; o += 2
	s.facing = Vector2(sin(angle), cos(angle))
	s.upper_body_rotation_y = b.decode_s16(o) / 32767.0 * PI; o += 2
	s.facing_angular_velocity = b.decode_s16(o) / 32767.0 * (PI * 10.0); o += 2
	s.upper_body_angular_velocity = b.decode_s16(o) / 32767.0 * (PI * 10.0); o += 2
	s.last_processed_host_timestamp = float(b.decode_u32(o)) / Constants.TIME_WIRE_SCALE; o += 4
	var flags: int = b.decode_u8(o); o += 1
	s.shot_state = flags & 0x07
	s.elevation_level = (flags >> 3) & 0x3
	s.is_ghost = (flags & 0x20) != 0
	s.blade_up = (flags & 0x40) != 0
	s.sprint_locked = (flags & 0x80) != 0
	s.shot_charge = b.decode_u8(o) / 255.0; o += 1
	s.stamina = b.decode_u8(o) / 255.0; o += 1
	s.stagger_timer = b.decode_u8(o) / 100.0; o += 1
	var intent: int = b.decode_u8(o)
	if intent & 0x08:
		var a: float = float(intent & 0x07) * (PI / 4.0)
		s.move_intent = Vector2(sin(a), cos(a))
	else:
		s.move_intent = Vector2.ZERO
	s.brake_intent = (intent & 0x10) != 0
	s.sprint_active = (intent & 0x20) != 0
	return s


# Puck: 12 bytes (pos + vel only; carrier index handled separately in encode/decode_world_state)
# Offsets: pos(0..5) vel(6..11)
static func _encode_puck_quantized(s: PuckNetworkState) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(12)
	var o: int = 0
	b.encode_s16(o, clampi(roundi(s.position.x * 100.0), -32768, 32767)); o += 2
	# s16 (not s8) on Y: elevated/saucer shots exceed the s8 ±1.27 m range and
	# would clip flat on the wire. s16 @1cm covers the puck's ~3 m max_height.
	b.encode_s16(o, clampi(roundi(s.position.y * 100.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.position.z * 100.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.velocity.x * 50.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.velocity.y * 50.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.velocity.z * 50.0), -32768, 32767)); o += 2
	return b


static func _decode_puck_quantized(b: PackedByteArray) -> PuckNetworkState:
	if b.size() < 12:
		push_warning("WorldStateCodec: truncated puck block (%d bytes)" % b.size())
		return PuckNetworkState.new()
	var s := PuckNetworkState.new()
	var o: int = 0
	s.position.x = b.decode_s16(o) / 100.0; o += 2
	s.position.y = b.decode_s16(o) / 100.0; o += 2
	s.position.z = b.decode_s16(o) / 100.0; o += 2
	s.velocity.x = b.decode_s16(o) / 50.0; o += 2
	s.velocity.y = b.decode_s16(o) / 50.0; o += 2
	s.velocity.z = b.decode_s16(o) / 50.0
	return s


# Goalie: 43 bytes — 12 root + 31 pose. See top-of-file layout comment.
# Root offsets:   pos_x(0..1) pos_z(2..3) rot_y(4..5) state(6) fho(7) vel_x(8..9) vel_z(10..11)
# Pose offsets:   body_pitch(12) body_roll(13)
#                 left_pad_offset(14..16) left_pad_pitch(17) left_pad_roll(18) left_pad_yaw(19)
#                 right_pad_offset(20..22) right_pad_pitch(23) right_pad_roll(24) right_pad_yaw(25)
#                 glove_offset s16(26..31) glove_yaw(32) glove_pitch(33)
#                 blocker_offset s16(34..39) blocker_yaw(40) blocker_pitch(41)
#                 head_yaw(42)
# Pad offsets: s8 @1cm (±1.27m, ample near the ice). Glove/blocker offsets: s16
# @1cm (±327m) — their Y reach (react_hand_y_max 1.55m) exceeds the s8 range.
# Angle quantization:  s8 @π/127 (~1.43° precision, full ±π range).
const _POSE_OFFSET_SCALE: float = 100.0
const _POSE_ANGLE_SCALE: float = 127.0 / PI

static func _encode_goalie_quantized(s: GoalieNetworkState) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(GOALIE_BLOCK_SIZE)
	var o: int = 0
	b.encode_s16(o, clampi(roundi(s.position_x * 100.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.position_z * 100.0), -32768, 32767)); o += 2
	# Wrap into (-PI, PI] BEFORE quantizing: the -Z goalie's facing lerps around
	# base angle PI up to ~4.36 rad, which a raw clamp pinned flat at PI — so that
	# goalie rendered facing dead-straight on every turn one way. wrapf fixes it.
	b.encode_s16(o, clampi(roundi(wrapf(s.rotation_y, -PI, PI) / PI * 32767.0), -32768, 32767)); o += 2
	b.encode_u8(o, s.state_enum); o += 1
	b.encode_u8(o, clampi(roundi(s.five_hole_openness * 255.0), 0, 255)); o += 1
	b.encode_s16(o, clampi(roundi(s.velocity_x * 50.0), -32768, 32767)); o += 2
	b.encode_s16(o, clampi(roundi(s.velocity_z * 50.0), -32768, 32767)); o += 2
	# Pose block
	b.encode_s8(o, _quant_angle(s.body_pitch)); o += 1
	b.encode_s8(o, _quant_angle(s.body_roll)); o += 1
	o = _encode_offset(b, o, s.left_pad_offset)
	b.encode_s8(o, _quant_angle(s.left_pad_pitch)); o += 1
	b.encode_s8(o, _quant_angle(s.left_pad_roll)); o += 1
	b.encode_s8(o, _quant_angle(s.left_pad_yaw)); o += 1
	o = _encode_offset(b, o, s.right_pad_offset)
	b.encode_s8(o, _quant_angle(s.right_pad_pitch)); o += 1
	b.encode_s8(o, _quant_angle(s.right_pad_roll)); o += 1
	b.encode_s8(o, _quant_angle(s.right_pad_yaw)); o += 1
	# Glove/blocker offsets use the WIDE (s16) encoding: their Y reach goes to
	# react_hand_y_max (1.55 m), above the s8 ±1.27 m range, so above-crossbar
	# reaches clipped ~28 cm low on clients. Pads stay s8 (they never leave the ice).
	o = _encode_offset_wide(b, o, s.glove_offset)
	b.encode_s8(o, _quant_angle(s.glove_yaw)); o += 1
	b.encode_s8(o, _quant_angle(s.glove_pitch)); o += 1
	o = _encode_offset_wide(b, o, s.blocker_offset)
	b.encode_s8(o, _quant_angle(s.blocker_yaw)); o += 1
	b.encode_s8(o, _quant_angle(s.blocker_pitch)); o += 1
	b.encode_s8(o, _quant_angle(s.head_yaw))
	return b


static func _decode_goalie_quantized(b: PackedByteArray) -> GoalieNetworkState:
	if b.size() < GOALIE_BLOCK_SIZE:
		push_warning("WorldStateCodec: truncated goalie block (%d bytes)" % b.size())
		return GoalieNetworkState.new()
	var s := GoalieNetworkState.new()
	var o: int = 0
	s.position_x = b.decode_s16(o) / 100.0; o += 2
	s.position_z = b.decode_s16(o) / 100.0; o += 2
	s.rotation_y = b.decode_s16(o) / 32767.0 * PI; o += 2
	s.state_enum = b.decode_u8(o); o += 1
	s.five_hole_openness = b.decode_u8(o) / 255.0; o += 1
	s.velocity_x = b.decode_s16(o) / 50.0; o += 2
	s.velocity_z = b.decode_s16(o) / 50.0; o += 2
	# Pose block
	s.body_pitch = _dequant_angle(b.decode_s8(o)); o += 1
	s.body_roll = _dequant_angle(b.decode_s8(o)); o += 1
	s.left_pad_offset = _decode_offset(b, o); o += 3
	s.left_pad_pitch = _dequant_angle(b.decode_s8(o)); o += 1
	s.left_pad_roll = _dequant_angle(b.decode_s8(o)); o += 1
	s.left_pad_yaw = _dequant_angle(b.decode_s8(o)); o += 1
	s.right_pad_offset = _decode_offset(b, o); o += 3
	s.right_pad_pitch = _dequant_angle(b.decode_s8(o)); o += 1
	s.right_pad_roll = _dequant_angle(b.decode_s8(o)); o += 1
	s.right_pad_yaw = _dequant_angle(b.decode_s8(o)); o += 1
	s.glove_offset = _decode_offset_wide(b, o); o += 6
	s.glove_yaw = _dequant_angle(b.decode_s8(o)); o += 1
	s.glove_pitch = _dequant_angle(b.decode_s8(o)); o += 1
	s.blocker_offset = _decode_offset_wide(b, o); o += 6
	s.blocker_yaw = _dequant_angle(b.decode_s8(o)); o += 1
	s.blocker_pitch = _dequant_angle(b.decode_s8(o)); o += 1
	s.head_yaw = _dequant_angle(b.decode_s8(o))
	return s


static func _quant_angle(a: float) -> int:
	return clampi(roundi(a * _POSE_ANGLE_SCALE), -128, 127)

static func _dequant_angle(q: int) -> float:
	return q / _POSE_ANGLE_SCALE

static func _encode_offset(b: PackedByteArray, o: int, v: Vector3) -> int:
	b.encode_s8(o, clampi(roundi(v.x * _POSE_OFFSET_SCALE), -128, 127))
	b.encode_s8(o + 1, clampi(roundi(v.y * _POSE_OFFSET_SCALE), -128, 127))
	b.encode_s8(o + 2, clampi(roundi(v.z * _POSE_OFFSET_SCALE), -128, 127))
	return o + 3

static func _decode_offset(b: PackedByteArray, o: int) -> Vector3:
	return Vector3(
		b.decode_s8(o) / _POSE_OFFSET_SCALE,
		b.decode_s8(o + 1) / _POSE_OFFSET_SCALE,
		b.decode_s8(o + 2) / _POSE_OFFSET_SCALE,
	)

# Wide offset: s16 @1cm (±327 m) for glove/blocker whose Y reach (up to 1.55 m)
# exceeds the s8 ±1.27 m range. 6 bytes instead of 3.
static func _encode_offset_wide(b: PackedByteArray, o: int, v: Vector3) -> int:
	b.encode_s16(o, clampi(roundi(v.x * _POSE_OFFSET_SCALE), -32768, 32767))
	b.encode_s16(o + 2, clampi(roundi(v.y * _POSE_OFFSET_SCALE), -32768, 32767))
	b.encode_s16(o + 4, clampi(roundi(v.z * _POSE_OFFSET_SCALE), -32768, 32767))
	return o + 6

static func _decode_offset_wide(b: PackedByteArray, o: int) -> Vector3:
	return Vector3(
		b.decode_s16(o) / _POSE_OFFSET_SCALE,
		b.decode_s16(o + 2) / _POSE_OFFSET_SCALE,
		b.decode_s16(o + 4) / _POSE_OFFSET_SCALE,
	)
