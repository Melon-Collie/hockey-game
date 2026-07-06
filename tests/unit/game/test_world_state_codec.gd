extends GutTest

# WorldStateCodec — round-trip serialization tests.
# World-state encode/decode uses live controllers (CharacterBody3D etc.), so
# those aren't covered here. Stats are pure Array<->Dictionary conversions
# and fully testable.

var codec: WorldStateCodec
var registry: PlayerRegistry
var sm: GameStateMachine


func before_each() -> void:
	sm = GameStateMachine.new()
	registry = PlayerRegistry.new()
	codec = WorldStateCodec.new()
	# Puck / controller / goalie getters aren't needed for stats tests.
	codec.setup(registry, sm, Callable(), Callable(), Callable(), null)


func _add_player(peer_id: int, team_id: int, g: int = 0, a: int = 0, sog: int = 0, hits: int = 0, blk: int = 0) -> PlayerRecord:
	var team := Team.new()
	team.team_id = team_id
	var record := PlayerRecord.new(peer_id, 0, false, team)
	record.stats = PlayerStats.new()
	record.stats.goals         = g
	record.stats.assists       = a
	record.stats.shots_on_goal = sog
	record.stats.hits          = hits
	record.stats.shots_blocked = blk
	registry._players[peer_id] = record
	return record


# ── Stats round-trip ─────────────────────────────────────────────────────────

func test_stats_round_trip_preserves_per_player_counters() -> void:
	_add_player(10, 0, 2, 1, 5, 3, 2)
	_add_player(11, 1, 0, 0, 4, 1, 7)
	sm.team_shots[0] = 5
	sm.team_shots[1] = 4
	sm.period_scores[0][0] = 2
	sm.period_scores[1][0] = 0

	var encoded: Array = codec.encode_stats()

	# Fresh registry + state machine, then decode into them
	sm.team_shots[0] = 0
	sm.team_shots[1] = 0
	registry._players[10].stats = PlayerStats.new()
	registry._players[11].stats = PlayerStats.new()
	sm.period_scores[0][0] = 0
	sm.period_scores[1][0] = 0

	codec.decode_stats(encoded)

	assert_eq(registry._players[10].stats.goals, 2)
	assert_eq(registry._players[10].stats.assists, 1)
	assert_eq(registry._players[10].stats.shots_on_goal, 5)
	assert_eq(registry._players[10].stats.hits, 3)
	assert_eq(registry._players[10].stats.shots_blocked, 2)
	assert_eq(registry._players[11].stats.shots_on_goal, 4)
	assert_eq(registry._players[11].stats.shots_blocked, 7)
	assert_eq(sm.team_shots[0], 5)
	assert_eq(sm.team_shots[1], 4)
	assert_eq(sm.period_scores[0][0], 2)
	assert_eq(sm.period_scores[1][0], 0)


func test_decode_stats_preserves_locally_tracked_toi() -> void:
	# Regression: TOI is tracked locally per-peer and never crosses the wire.
	# Decoding must update the existing stats object in place, not replace it,
	# or a client's accumulated time-on-ice is wiped to zero on every packet.
	_add_player(10, 0, 1, 0, 2, 0, 0)
	var encoded: Array = codec.encode_stats()
	# Client has been accumulating TOI locally between packets.
	registry._players[10].stats.toi_seconds = 42.5
	codec.decode_stats(encoded)
	assert_eq(registry._players[10].stats.toi_seconds, 42.5,
			"decode_stats must not reset locally tracked toi_seconds")
	assert_eq(registry._players[10].stats.shots_on_goal, 2,
			"wire counters still apply through the in-place update")


func test_decode_stats_skips_unknown_peer_ids() -> void:
	_add_player(10, 0, 1, 0, 0, 0)
	var encoded: Array = codec.encode_stats()
	# Drop the known player; decode should no-op on missing peer_id but still
	# apply team_shots/period_scores afterwards.
	registry._players.erase(10)
	codec.decode_stats(encoded)
	# Team shots/period_scores are at the tail — they should land regardless.
	assert_eq(sm.team_shots[0], 0)
	assert_eq(sm.team_shots[1], 0)


func test_decode_stats_emits_shots_on_goal_signal() -> void:
	_add_player(10, 0)
	sm.team_shots[0] = 3
	sm.team_shots[1] = 1
	var encoded: Array = codec.encode_stats()
	watch_signals(codec)
	codec.decode_stats(encoded)
	assert_signal_emitted_with_parameters(codec, "shots_on_goal_changed", [3, 1])


# ── Wire-format tail sentinel ─────────────────────────────────────────────────

func test_encode_stats_ends_with_num_periods_sentinel() -> void:
	_add_player(10, 0)
	var encoded: Array = codec.encode_stats()
	assert_eq(encoded[-1], sm.period_scores[0].size(),
			"trailing sentinel encodes the period count")


# ── Goalie pose round-trip ───────────────────────────────────────────────────

func _make_goalie_state() -> GoalieNetworkState:
	var s := GoalieNetworkState.new()
	# Legacy fields
	s.position_x = 1.23
	s.position_z = -25.47
	s.rotation_y = 0.42
	s.state_enum = 3
	s.five_hole_openness = 0.65
	s.velocity_x = -2.1
	s.velocity_z = 1.7
	# Pose fields
	s.body_pitch = -0.17
	s.body_roll = 0.09
	s.left_pad_offset = Vector3(-0.42, 0.14, -0.05)
	s.left_pad_pitch = -1.57
	s.left_pad_roll = 0.21
	s.left_pad_yaw = 0.31   # toe-out (v13)
	s.right_pad_offset = Vector3(0.40, 0.16, -0.04)
	s.right_pad_pitch = -1.50
	s.right_pad_roll = -0.18
	s.right_pad_yaw = -0.28  # toe-out (v13)
	s.glove_offset = Vector3(-0.55, 0.49, -0.10)
	s.glove_yaw = 0.78
	s.glove_pitch = -0.30
	s.blocker_offset = Vector3(0.38, 0.47, -0.08)
	s.blocker_yaw = -0.45
	s.blocker_pitch = 0.20
	s.head_yaw = 0.12
	return s


func test_goalie_round_trip_preserves_fields_within_quantization() -> void:
	var orig := _make_goalie_state()
	var encoded: PackedByteArray = WorldStateCodec._encode_goalie_quantized(orig)
	assert_eq(encoded.size(), WorldStateCodec.GOALIE_BLOCK_SIZE,
			"encoded block matches declared size")
	var decoded: GoalieNetworkState = WorldStateCodec._decode_goalie_quantized(encoded)
	# Legacy fields: position s16@1cm, rot_y s16@π/32767, fho u8, vel s16@0.02m/s
	assert_almost_eq(decoded.position_x, orig.position_x, 0.011)
	assert_almost_eq(decoded.position_z, orig.position_z, 0.011)
	assert_almost_eq(decoded.rotation_y, orig.rotation_y, 0.001)
	assert_eq(decoded.state_enum, orig.state_enum)
	assert_almost_eq(decoded.five_hole_openness, orig.five_hole_openness, 0.005)
	assert_almost_eq(decoded.velocity_x, orig.velocity_x, 0.025)
	assert_almost_eq(decoded.velocity_z, orig.velocity_z, 0.025)
	# Pose fields: angles s8@π/127 (~0.025 rad), offsets s8@1cm (~0.011m)
	assert_almost_eq(decoded.body_pitch, orig.body_pitch, 0.03)
	assert_almost_eq(decoded.body_roll, orig.body_roll, 0.03)
	assert_almost_eq(decoded.left_pad_offset.x, orig.left_pad_offset.x, 0.011)
	assert_almost_eq(decoded.left_pad_offset.y, orig.left_pad_offset.y, 0.011)
	assert_almost_eq(decoded.left_pad_offset.z, orig.left_pad_offset.z, 0.011)
	assert_almost_eq(decoded.left_pad_pitch, orig.left_pad_pitch, 0.03)
	assert_almost_eq(decoded.left_pad_roll, orig.left_pad_roll, 0.03)
	assert_almost_eq(decoded.left_pad_yaw, orig.left_pad_yaw, 0.03)
	assert_almost_eq(decoded.right_pad_offset.x, orig.right_pad_offset.x, 0.011)
	assert_almost_eq(decoded.right_pad_pitch, orig.right_pad_pitch, 0.03)
	assert_almost_eq(decoded.right_pad_yaw, orig.right_pad_yaw, 0.03)
	assert_almost_eq(decoded.glove_offset.x, orig.glove_offset.x, 0.011)
	assert_almost_eq(decoded.glove_yaw, orig.glove_yaw, 0.03)
	assert_almost_eq(decoded.glove_pitch, orig.glove_pitch, 0.03)
	assert_almost_eq(decoded.blocker_offset.y, orig.blocker_offset.y, 0.011)
	assert_almost_eq(decoded.blocker_yaw, orig.blocker_yaw, 0.03)
	assert_almost_eq(decoded.head_yaw, orig.head_yaw, 0.03)


func test_goalie_zero_state_round_trips() -> void:
	# Rest state — confirms quantization handles zero inputs without truncation
	# artifacts on the s8 channels.
	var orig := GoalieNetworkState.new()
	var encoded: PackedByteArray = WorldStateCodec._encode_goalie_quantized(orig)
	var decoded: GoalieNetworkState = WorldStateCodec._decode_goalie_quantized(encoded)
	assert_eq(decoded.position_x, 0.0)
	assert_eq(decoded.body_pitch, 0.0)
	assert_eq(decoded.left_pad_offset, Vector3.ZERO)
	assert_eq(decoded.glove_yaw, 0.0)
	assert_eq(decoded.head_yaw, 0.0)


# ── Puck wire block: pos + vel (carrier handled separately) ───────────────────

func test_puck_round_trip_preserves_elevated_y() -> void:
	# Y on the wire is s16 (not s8): an elevated/saucer shot above the old s8
	# ±1.27 m range must survive the round-trip instead of clipping flat.
	var orig := PuckNetworkState.new()
	orig.position = Vector3(12.3, 2.5, -8.7)
	orig.velocity = Vector3(18.0, 4.0, -22.5)
	var encoded: PackedByteArray = WorldStateCodec._encode_puck_quantized(orig)
	assert_eq(encoded.size(), 12, "puck pos+vel block is 12 bytes")
	var decoded: PuckNetworkState = WorldStateCodec._decode_puck_quantized(encoded)
	# Position s16@1cm, velocity s16@0.02m/s.
	assert_almost_eq(decoded.position.x, orig.position.x, 0.011)
	assert_almost_eq(decoded.position.y, orig.position.y, 0.011)  # would clip to 1.27 under s8
	assert_almost_eq(decoded.position.z, orig.position.z, 0.011)
	assert_almost_eq(decoded.velocity.x, orig.velocity.x, 0.021)
	assert_almost_eq(decoded.velocity.y, orig.velocity.y, 0.021)
	assert_almost_eq(decoded.velocity.z, orig.velocity.z, 0.021)


# ── Skater flags byte: shot_state | elevation_level | ghost | blade_up | lock ─
# All share the single flags byte (bits 0-2 shot_state, bits 3-4 the 2-bit
# elevation_level, then 0x20/0x40/0x80). This exercises every combination so a
# new bit can't silently clobber a neighbour.

func test_skater_flags_round_trip_all_combinations() -> void:
	for shot_state: int in [0, 3, 6]:
		for elevation_level: int in [0, 1, 2]:
			for ghost: bool in [false, true]:
				for blade_up: bool in [false, true]:
					for sprint_locked: bool in [false, true]:
						var s := SkaterNetworkState.new()
						s.shot_state      = shot_state
						s.elevation_level = elevation_level
						s.is_ghost        = ghost
						s.blade_up        = blade_up
						s.sprint_locked   = sprint_locked
						var enc: PackedByteArray = WorldStateCodec._encode_skater_quantized(s)
						var dec: SkaterNetworkState = WorldStateCodec._decode_skater_quantized(enc)
						var ctx := "shot=%d elev=%d ghost=%s up=%s lock=%s" % [shot_state, elevation_level, ghost, blade_up, sprint_locked]
						assert_eq(dec.shot_state, shot_state, ctx)
						assert_eq(dec.elevation_level, elevation_level, ctx)
						assert_eq(dec.is_ghost, ghost, ctx)
						assert_eq(dec.blade_up, blade_up, ctx)
						assert_eq(dec.sprint_locked, sprint_locked, ctx)


func test_skater_stamina_quantizes_within_tolerance() -> void:
	# Stamina rides as a u8 (0..1 → 0..255), so worst-case quantization error is
	# ~1/255. Round-trip a spread of values through the real wire path.
	for v: float in [0.0, 0.25, 0.5, 0.73, 1.0]:
		var s := SkaterNetworkState.new()
		s.stamina = v
		var dec: SkaterNetworkState = WorldStateCodec._decode_skater_quantized(
				WorldStateCodec._encode_skater_quantized(s))
		assert_almost_eq(dec.stamina, v, 1.0 / 255.0, "stamina %f round-trips within u8 tolerance" % v)


# ── decode_for_replay: side-effect-free world-state decode ────────────────────
# The replay viewer / goal-replay driver decode packets through decode_for_replay
# instead of decode_world_state precisely because it must NOT mutate the live
# state machine. These build a world-state buffer by hand (the live encoder pulls
# from CharacterBody3D controllers, untestable headless) using the same documented
# layout and the static quantizers the round-trip tests above already validate.

func _append_s32(buf: PackedByteArray, v: int) -> void:
	var t := PackedByteArray()
	t.resize(4)
	t.encode_s32(0, v)
	buf.append_array(t)


# skaters: Array of { id: int, state: SkaterNetworkState } in wire order.
# carrier_idx is the raw on-wire byte (0xFF = no carrier).
func _build_ws(
		host_ts: float,
		skaters: Array,
		puck: PuckNetworkState,
		carrier_idx: int,
		goalies: Array,
		game_state: Dictionary) -> PackedByteArray:
	var buf := PackedByteArray()
	var header := PackedByteArray()
	header.resize(WorldStateCodec.WS_HEADER_SIZE)
	header.encode_u16(0, 1)  # ws_sequence
	header.encode_u32(2, roundi(host_ts * Constants.TIME_WIRE_SCALE))
	header.encode_u8(6, skaters.size())
	buf.append_array(header)
	for entry: Dictionary in skaters:
		_append_s32(buf, entry.id)
		buf.append_array(WorldStateCodec._encode_skater_quantized(entry.state))  # 39 B
		buf.append(0)  # queue_depth (ignored by replay decode)
	buf.append_array(WorldStateCodec._encode_puck_quantized(puck))  # 12 B
	buf.append(carrier_idx & 0xFF)
	buf.append(goalies.size())
	for g: GoalieNetworkState in goalies:
		buf.append_array(WorldStateCodec._encode_goalie_quantized(g))  # 43 B
	var gs := PackedByteArray()
	gs.resize(WorldStateCodec.GAME_STATE_BLOCK_SIZE)
	gs.encode_u8(0, game_state.score0)
	gs.encode_u8(1, game_state.score1)
	gs.encode_u8(2, game_state.phase)
	gs.encode_u8(3, game_state.period)
	gs.encode_u16(4, game_state.time_remaining)
	buf.append_array(gs)
	return buf


func _make_skater(x: float) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.position = Vector3(x, 0.5, -x)
	s.velocity = Vector3(1.0, 0.0, -2.0)
	s.stamina = 0.5
	return s


func test_decode_for_replay_round_trips_full_packet() -> void:
	var puck := PuckNetworkState.new()
	puck.position = Vector3(3.0, 0.2, -4.0)
	puck.velocity = Vector3(5.0, 0.0, 1.0)
	var goalie := _make_goalie_state()
	var buf := _build_ws(12.5,
			[{id = 10, state = _make_skater(2.0)}, {id = 11, state = _make_skater(-6.0)}],
			puck, 1, [goalie],
			{score0 = 2, score1 = 1, phase = 3, period = 2, time_remaining = 600})

	var out: Dictionary = codec.decode_for_replay(buf)

	assert_false(out.is_empty(), "valid packet decodes")
	assert_almost_eq(out.host_ts, 12.5, 0.001, "host_ts survives 0.1ms quantization")
	# Skaters keyed by peer_id, decoded poses within s16@1cm tolerance.
	assert_eq((out.skaters as Dictionary).size(), 2)
	assert_true(out.skaters.has(10) and out.skaters.has(11))
	assert_almost_eq(out.skaters[10].position.x, 2.0, 0.011)
	assert_almost_eq(out.skaters[11].position.x, -6.0, 0.011)
	# carrier_idx 1 → second decoded peer (11).
	assert_eq(out.carrier_peer_id, 11)
	# Puck + goalies.
	assert_almost_eq(out.puck.position.x, 3.0, 0.011)
	assert_eq((out.goalies as Array).size(), 1)
	assert_almost_eq(out.goalies[0].position_x, goalie.position_x, 0.011)
	# Game-state block (HUD fields) — note time_remaining rides as a raw u16.
	assert_eq(out.game_state.score0, 2)
	assert_eq(out.game_state.score1, 1)
	assert_eq(out.game_state.phase, 3)
	assert_eq(out.game_state.period, 2)
	assert_eq(out.game_state.time_remaining, 600.0)


func test_decode_for_replay_no_carrier_sentinel() -> void:
	var buf := _build_ws(1.0,
			[{id = 10, state = _make_skater(1.0)}],
			PuckNetworkState.new(), 0xFF, [],
			{score0 = 0, score1 = 0, phase = 0, period = 1, time_remaining = 0})
	var out: Dictionary = codec.decode_for_replay(buf)
	assert_eq(out.carrier_peer_id, -1, "0xFF sentinel decodes to no carrier")


func test_decode_for_replay_out_of_range_carrier_idx_is_no_carrier() -> void:
	# A carrier_idx beyond the decoded peer count must not index out of bounds.
	var buf := _build_ws(1.0,
			[{id = 10, state = _make_skater(1.0)}, {id = 11, state = _make_skater(2.0)}],
			PuckNetworkState.new(), 5, [],
			{score0 = 0, score1 = 0, phase = 0, period = 1, time_remaining = 0})
	var out: Dictionary = codec.decode_for_replay(buf)
	assert_eq(out.carrier_peer_id, -1)


func test_decode_for_replay_zero_skaters_zero_goalies() -> void:
	var buf := _build_ws(2.0, [], PuckNetworkState.new(), 0xFF, [],
			{score0 = 0, score1 = 0, phase = 1, period = 1, time_remaining = 1200})
	var out: Dictionary = codec.decode_for_replay(buf)
	assert_false(out.is_empty(), "empty-roster packet still decodes puck + game state")
	assert_eq((out.skaters as Dictionary).size(), 0)
	assert_eq((out.goalies as Array).size(), 0)
	assert_eq(out.game_state.time_remaining, 1200.0)


func test_decode_for_replay_rejects_short_header() -> void:
	var buf := PackedByteArray()
	buf.resize(WorldStateCodec.WS_HEADER_SIZE - 1)
	assert_true(codec.decode_for_replay(buf).is_empty(), "sub-header buffer rejected")


func test_decode_for_replay_rejects_truncated_body() -> void:
	# Header claims 2 skaters but no body follows — the min-size guard must bail
	# before reading past the buffer.
	var buf := PackedByteArray()
	buf.resize(WorldStateCodec.WS_HEADER_SIZE)
	buf.encode_u8(6, 2)  # num_skaters
	assert_true(codec.decode_for_replay(buf).is_empty(), "truncated body rejected")


func test_decode_for_replay_rejects_overrun_goalie_count() -> void:
	# A crafted packet with a huge num_goalies but no goalie payload must be
	# refused wholesale, not partially decoded off a stale offset (the guard
	# protects the replay viewer from malformed .mreplay files).
	var buf := _build_ws(1.0, [], PuckNetworkState.new(), 0xFF, [],
			{score0 = 0, score1 = 0, phase = 0, period = 1, time_remaining = 0})
	# num_goalies sits just before the 6-byte game-state tail.
	buf.encode_u8(buf.size() - WorldStateCodec.GAME_STATE_BLOCK_SIZE - 1, 255)
	assert_true(codec.decode_for_replay(buf).is_empty(), "overrun goalie count rejected")


# ── v10 wire additions ────────────────────────────────────────────────────────

func test_skater_stagger_round_trips() -> void:
	# stagger_timer was never on the wire, so a client victim's predicted stagger
	# was wiped to 0 on the next reconcile. u8 @0.01s must now round-trip it.
	for v: float in [0.0, 0.3, 1.0, 2.5]:
		var s := SkaterNetworkState.new()
		s.stagger_timer = v
		var dec: SkaterNetworkState = WorldStateCodec._decode_skater_quantized(
				WorldStateCodec._encode_skater_quantized(s))
		assert_almost_eq(dec.stagger_timer, v, 0.01, "stagger %f round-trips within u8 @0.01s" % v)

func test_goalie_glove_above_crossbar_not_clipped() -> void:
	# Regression: glove/blocker Y reach (react_hand_y_max 1.55) exceeded the old s8
	# ±1.27 m range and clipped ~28 cm low. The s16-wide encoding preserves it.
	var s := GoalieNetworkState.new()
	s.glove_offset = Vector3(-0.6, 1.55, -0.1)
	s.blocker_offset = Vector3(0.6, 1.50, -0.1)
	var dec: GoalieNetworkState = WorldStateCodec._decode_goalie_quantized(
			WorldStateCodec._encode_goalie_quantized(s))
	assert_almost_eq(dec.glove_offset.y, 1.55, 0.011, "glove Y above crossbar preserved")
	assert_almost_eq(dec.blocker_offset.y, 1.50, 0.011, "blocker Y above crossbar preserved")

func test_goalie_rotation_y_wraps_past_pi() -> void:
	# The -Z goalie's facing lerps around base PI past +PI; the old raw clamp pinned
	# it flat at PI. wrapf must fold it to the equivalent (-PI,PI] before quantizing,
	# so the decoded facing points the SAME way (cos/sin match), not straight out.
	var s := GoalieNetworkState.new()
	s.rotation_y = PI + 1.0   # ~4.14 rad; wraps to ~-2.14
	var dec: GoalieNetworkState = WorldStateCodec._decode_goalie_quantized(
			WorldStateCodec._encode_goalie_quantized(s))
	assert_almost_eq(cos(dec.rotation_y), cos(PI + 1.0), 0.002, "wrapped facing same direction (cos)")
	assert_almost_eq(sin(dec.rotation_y), sin(PI + 1.0), 0.002, "wrapped facing same direction (sin)")
