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
	s.right_pad_offset = Vector3(0.40, 0.16, -0.04)
	s.right_pad_pitch = -1.50
	s.right_pad_roll = -0.18
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
	assert_almost_eq(decoded.right_pad_offset.x, orig.right_pad_offset.x, 0.011)
	assert_almost_eq(decoded.right_pad_pitch, orig.right_pad_pitch, 0.03)
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


# ── Skater flags byte: shot_state | ghost | elevated | blade_up | sprint_lock ─
# All share the single flags byte (shot_state low nibble, the rest are bits
# 0x10/0x20/0x40/0x80). This exercises every combination so a new bit can't
# silently clobber a neighbour.

func test_skater_flags_round_trip_all_combinations() -> void:
	for shot_state: int in [0, 5, 15]:
		for ghost: bool in [false, true]:
			for elevated: bool in [false, true]:
				for blade_up: bool in [false, true]:
					for sprint_locked: bool in [false, true]:
						var s := SkaterNetworkState.new()
						s.shot_state    = shot_state
						s.is_ghost      = ghost
						s.is_elevated   = elevated
						s.blade_up      = blade_up
						s.sprint_locked = sprint_locked
						var enc: PackedByteArray = WorldStateCodec._encode_skater_quantized(s)
						var dec: SkaterNetworkState = WorldStateCodec._decode_skater_quantized(enc)
						var ctx := "shot=%d ghost=%s elev=%s up=%s lock=%s" % [shot_state, ghost, elevated, blade_up, sprint_locked]
						assert_eq(dec.shot_state, shot_state, ctx)
						assert_eq(dec.is_ghost, ghost, ctx)
						assert_eq(dec.is_elevated, elevated, ctx)
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
