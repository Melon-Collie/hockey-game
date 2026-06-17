class_name StateBufferManager
extends RefCounted

# Host-only rolling snapshot buffer for all actors.
# Pre-allocated ring buffers avoid per-tick GC pressure at the physics rate.
# Owned by GameManager; WorldStateCodec reads latest_*() for broadcasts.
# Phase 7 lag compensation queries get_state_at() for historical rewind.

const _PhysicsConstants: GDScript = preload("res://Scripts/game/constants.gd")
const BUFFER_SIZE: int = _PhysicsConstants.PHYSICS_TICK * 3  # 3 seconds of history

var _skater_buffers: Dictionary = {}   # peer_id -> Array[SkaterNetworkState]
var _skater_ptrs: Dictionary = {}      # peer_id -> int
var _skater_counts: Dictionary = {}    # peer_id -> int (entries written, capped at BUFFER_SIZE)
var _puck_buffer: Array = []           # Array[PuckNetworkState], BUFFER_SIZE slots
var _puck_ptr: int = 0
var _puck_count: int = 0
var _goalie_buffers: Dictionary = {}   # team_id -> Array[GoalieNetworkState]
var _goalie_ptrs: Dictionary = {}      # team_id -> int
var _goalie_counts: Dictionary = {}    # team_id -> int (entries written, capped at BUFFER_SIZE)
var _capture_count: int = 0


func setup(registry: PlayerRegistry, goalie_controllers: Array) -> void:
	for peer_id: int in registry.all():
		_alloc_skater(peer_id)
	_puck_buffer.resize(BUFFER_SIZE)
	for i: int in BUFFER_SIZE:
		_puck_buffer[i] = PuckNetworkState.new()
	_puck_count = 0
	for gc: GoalieController in goalie_controllers:
		_alloc_goalie(gc.team_id)


func add_player(peer_id: int) -> void:
	if not _skater_buffers.has(peer_id):
		_alloc_skater(peer_id)


func remove_player(peer_id: int) -> void:
	_skater_buffers.erase(peer_id)
	_skater_ptrs.erase(peer_id)
	_skater_counts.erase(peer_id)


func is_ready() -> bool:
	return _capture_count >= 2


func capture(registry: PlayerRegistry, puck_controller: PuckController, goalie_controllers: Array) -> void:
	# Session-relative time, matching `NetworkManager.local_time()` everywhere
	# else: world-state broadcast header, client claim timestamps, AI snapshot
	# queries. Keeping a single time base across capture + query means
	# `get_state_at(host_timestamp)` Just Works for both client-supplied
	# timestamps and host-internal queries — no offset translation required.
	var now: float = NetworkManager.local_time()

	# fill_* writes each controller's state directly into the pre-allocated
	# ring slot — the previous get_*() calls allocated a throwaway state per
	# actor per tick, defeating the rings' purpose (the header's whole point).
	for peer_id: int in registry.all():
		if not _skater_buffers.has(peer_id):
			_alloc_skater(peer_id)
		var ptr: int = _skater_ptrs[peer_id]
		var slot: SkaterNetworkState = _skater_buffers[peer_id][ptr]
		registry.get_record(peer_id).controller.fill_network_state(slot)
		slot.host_timestamp = now
		_skater_ptrs[peer_id] = (ptr + 1) % BUFFER_SIZE
		_skater_counts[peer_id] = mini(_skater_counts.get(peer_id, 0) + 1, BUFFER_SIZE)

	var puck_slot: PuckNetworkState = _puck_buffer[_puck_ptr]
	puck_controller.fill_state(puck_slot)
	puck_slot.host_timestamp = now
	_puck_ptr = (_puck_ptr + 1) % BUFFER_SIZE
	_puck_count = mini(_puck_count + 1, BUFFER_SIZE)

	for gc: GoalieController in goalie_controllers:
		if not _goalie_buffers.has(gc.team_id):
			_alloc_goalie(gc.team_id)
		var ptr: int = _goalie_ptrs[gc.team_id]
		var slot: GoalieNetworkState = _goalie_buffers[gc.team_id][ptr]
		gc.fill_state(slot)
		slot.host_timestamp = now
		_goalie_ptrs[gc.team_id] = (ptr + 1) % BUFFER_SIZE
		_goalie_counts[gc.team_id] = mini(_goalie_counts.get(gc.team_id, 0) + 1, BUFFER_SIZE)

	_capture_count += 1


# ── Latest state reads (used by WorldStateCodec for world state broadcast) ────

func latest_skater_state(peer_id: int) -> SkaterNetworkState:
	if not _skater_buffers.has(peer_id):
		return SkaterNetworkState.new()
	var ptr: int = (_skater_ptrs[peer_id] - 1 + BUFFER_SIZE) % BUFFER_SIZE
	return _skater_buffers[peer_id][ptr]


func latest_puck_state() -> PuckNetworkState:
	var ptr: int = (_puck_ptr - 1 + BUFFER_SIZE) % BUFFER_SIZE
	return _puck_buffer[ptr]


func latest_goalie_state(team_id: int) -> GoalieNetworkState:
	if not _goalie_buffers.has(team_id):
		return GoalieNetworkState.new()
	var ptr: int = (_goalie_ptrs[team_id] - 1 + BUFFER_SIZE) % BUFFER_SIZE
	return _goalie_buffers[team_id][ptr]


# ── Historical query (used by Phase 7 lag compensation) ──────────────────────

func get_state_at(host_timestamp: float) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	snap.host_timestamp = host_timestamp
	snap.puck_state = _interpolate_puck(host_timestamp)
	for peer_id: int in _skater_buffers:
		snap.skater_states[peer_id] = _interpolate_skater(peer_id, host_timestamp)
	for team_id: int in _goalie_buffers:
		snap.goalie_states[team_id] = _interpolate_goalie(team_id, host_timestamp)
	return snap


# ── Private helpers ───────────────────────────────────────────────────────────

func _alloc_goalie(team_id: int) -> void:
	var buf: Array = []
	buf.resize(BUFFER_SIZE)
	for i: int in BUFFER_SIZE:
		buf[i] = GoalieNetworkState.new()
	_goalie_buffers[team_id] = buf
	_goalie_ptrs[team_id] = 0
	_goalie_counts[team_id] = 0


func _alloc_skater(peer_id: int) -> void:
	var buf: Array = []
	buf.resize(BUFFER_SIZE)
	for i: int in BUFFER_SIZE:
		buf[i] = SkaterNetworkState.new()
	_skater_buffers[peer_id] = buf
	_skater_ptrs[peer_id] = 0
	_skater_counts[peer_id] = 0


func _interpolate_skater(peer_id: int, ts: float) -> SkaterNetworkState:
	var buf: Array = _skater_buffers[peer_id]
	var ptr: int = _skater_ptrs[peer_id]
	var bracket: Array = _find_bracket(buf, ptr, _skater_counts.get(peer_id, 0), ts)
	var t: float = bracket[0]
	var from_s: SkaterNetworkState = bracket[1]
	var to_s: SkaterNetworkState = bracket[2]
	if t < 0.0:
		return to_s if to_s != null else SkaterNetworkState.new()
	var result := SkaterNetworkState.new()
	result.position = from_s.position.lerp(to_s.position, t)
	result.velocity = from_s.velocity.lerp(to_s.velocity, t)
	result.blade_position = from_s.blade_position.lerp(to_s.blade_position, t)
	result.blade_contact_world = from_s.blade_contact_world.lerp(to_s.blade_contact_world, t)
	# top_hand_world (host-only) pairs with blade_contact_world as the shaft
	# segment for stick-lift claim resolution — interpolate it too, or the
	# resolver reads a (0,0,0) hand on rewound snapshots.
	result.top_hand_world = from_s.top_hand_world.lerp(to_s.top_hand_world, t)
	result.top_hand_position = from_s.top_hand_position.lerp(to_s.top_hand_position, t)
	var bracket_dt: float = to_s.host_timestamp - from_s.host_timestamp
	result.upper_body_rotation_y = BufferedStateInterpolator.hermite_angle(
			from_s.upper_body_rotation_y, from_s.upper_body_angular_velocity,
			to_s.upper_body_rotation_y, to_s.upper_body_angular_velocity, t, bracket_dt)
	var lag_fa: float = BufferedStateInterpolator.hermite_angle(
			atan2(from_s.facing.x, from_s.facing.y), from_s.facing_angular_velocity,
			atan2(to_s.facing.x, to_s.facing.y), to_s.facing_angular_velocity, t, bracket_dt)
	result.facing = Vector2(sin(lag_fa), cos(lag_fa))
	result.is_ghost = to_s.is_ghost
	result.host_timestamp = ts
	return result


func _interpolate_puck(ts: float) -> PuckNetworkState:
	var bracket: Array = _find_bracket_puck(ts)
	var t: float = bracket[0]
	var from_p: PuckNetworkState = bracket[1]
	var to_p: PuckNetworkState = bracket[2]
	if t < 0.0:
		return to_p if to_p != null else PuckNetworkState.new()
	var result := PuckNetworkState.new()
	result.position = from_p.position.lerp(to_p.position, t)
	result.velocity = from_p.velocity.lerp(to_p.velocity, t)
	result.carrier_peer_id = to_p.carrier_peer_id
	result.host_timestamp = ts
	return result


func _interpolate_goalie(team_id: int, ts: float) -> GoalieNetworkState:
	var bracket: Array = _find_bracket_goalie(team_id, ts)
	var t: float = bracket[0]
	var from_g: GoalieNetworkState = bracket[1]
	var to_g: GoalieNetworkState = bracket[2]
	if t < 0.0:
		return to_g if to_g != null else GoalieNetworkState.new()
	var result := GoalieNetworkState.new()
	result.position_x = lerpf(from_g.position_x, to_g.position_x, t)
	result.position_z = lerpf(from_g.position_z, to_g.position_z, t)
	result.rotation_y = lerp_angle(from_g.rotation_y, to_g.rotation_y, t)
	result.state_enum = to_g.state_enum
	result.five_hole_openness = lerpf(from_g.five_hole_openness, to_g.five_hole_openness, t)
	result.velocity_x = lerpf(from_g.velocity_x, to_g.velocity_x, t)
	result.velocity_z = lerpf(from_g.velocity_z, to_g.velocity_z, t)
	result.host_timestamp = ts
	return result


# Returns [t, from, to]. t < 0 means no valid bracket; from may be null.
# Binary search: O(log BUFFER_SIZE) ≈ 10 comparisons vs. up to 720 linear.
# Timestamps are monotonically increasing so binary search is exact.
func _find_bracket(buf: Array, write_ptr: int, count: int, ts: float) -> Array:
	if count == 0:
		return [-1.0, null, null]
	var newest_ptr: int = (write_ptr - 1 + BUFFER_SIZE) % BUFFER_SIZE
	var newest = buf[newest_ptr]
	if ts >= newest.host_timestamp:
		return [-1.0, null, newest]
	# Binary search for the last logical index whose timestamp <= ts.
	# Logical index 0 = oldest, count-1 = newest.
	var oldest_ptr: int = (write_ptr - count + BUFFER_SIZE) % BUFFER_SIZE
	var lo: int = 0
	var hi: int = count - 1
	var found: int = -1
	while lo <= hi:
		var mid: int = (lo + hi) >> 1
		var phys: int = (oldest_ptr + mid) % BUFFER_SIZE
		if buf[phys].host_timestamp <= ts:
			found = mid
			lo = mid + 1
		else:
			hi = mid - 1
	if found < 0:
		if OS.is_debug_build():
			push_warning("StateBufferManager: ts %.4f predates oldest buffered %.4f (skater)" % [ts, buf[oldest_ptr].host_timestamp])
		return [-1.0, null, newest]
	if found >= count - 1:
		return [-1.0, null, newest]
	var from_s = buf[(oldest_ptr + found) % BUFFER_SIZE]
	var to_s = buf[(oldest_ptr + found + 1) % BUFFER_SIZE]
	var dt: float = to_s.host_timestamp - from_s.host_timestamp
	if dt <= 0.0:
		return [0.0, from_s, to_s]
	return [clampf((ts - from_s.host_timestamp) / dt, 0.0, 1.0), from_s, to_s]


func _find_bracket_puck(ts: float) -> Array:
	if _puck_count == 0:
		return [-1.0, null, null]
	var newest_ptr: int = (_puck_ptr - 1 + BUFFER_SIZE) % BUFFER_SIZE
	var newest = _puck_buffer[newest_ptr]
	if ts >= newest.host_timestamp:
		return [-1.0, null, newest]
	var oldest_ptr: int = (_puck_ptr - _puck_count + BUFFER_SIZE) % BUFFER_SIZE
	var lo: int = 0
	var hi: int = _puck_count - 1
	var found: int = -1
	while lo <= hi:
		var mid: int = (lo + hi) >> 1
		var phys: int = (oldest_ptr + mid) % BUFFER_SIZE
		if _puck_buffer[phys].host_timestamp <= ts:
			found = mid
			lo = mid + 1
		else:
			hi = mid - 1
	if found < 0:
		if OS.is_debug_build():
			push_warning("StateBufferManager: ts %.4f predates oldest buffered %.4f (puck)" % [ts, _puck_buffer[oldest_ptr].host_timestamp])
		return [-1.0, null, newest]
	if found >= _puck_count - 1:
		return [-1.0, null, newest]
	var from_p = _puck_buffer[(oldest_ptr + found) % BUFFER_SIZE]
	var to_p = _puck_buffer[(oldest_ptr + found + 1) % BUFFER_SIZE]
	var dt: float = to_p.host_timestamp - from_p.host_timestamp
	if dt <= 0.0:
		return [0.0, from_p, to_p]
	return [clampf((ts - from_p.host_timestamp) / dt, 0.0, 1.0), from_p, to_p]


func _find_bracket_goalie(team_id: int, ts: float) -> Array:
	var count: int = _goalie_counts.get(team_id, 0)
	if count == 0:
		return [-1.0, null, null]
	var buf: Array = _goalie_buffers[team_id]
	var write_ptr: int = _goalie_ptrs[team_id]
	var newest_ptr: int = (write_ptr - 1 + BUFFER_SIZE) % BUFFER_SIZE
	var newest = buf[newest_ptr]
	if ts >= newest.host_timestamp:
		return [-1.0, null, newest]
	var oldest_ptr: int = (write_ptr - count + BUFFER_SIZE) % BUFFER_SIZE
	var lo: int = 0
	var hi: int = count - 1
	var found: int = -1
	while lo <= hi:
		var mid: int = (lo + hi) >> 1
		var phys: int = (oldest_ptr + mid) % BUFFER_SIZE
		if buf[phys].host_timestamp <= ts:
			found = mid
			lo = mid + 1
		else:
			hi = mid - 1
	if found < 0:
		if OS.is_debug_build():
			push_warning("StateBufferManager: ts %.4f predates oldest buffered %.4f (goalie team %d)" % [ts, buf[oldest_ptr].host_timestamp, team_id])
		return [-1.0, null, newest]
	if found >= count - 1:
		return [-1.0, null, newest]
	var from_g = buf[(oldest_ptr + found) % BUFFER_SIZE]
	var to_g = buf[(oldest_ptr + found + 1) % BUFFER_SIZE]
	var dt: float = to_g.host_timestamp - from_g.host_timestamp
	if dt <= 0.0:
		return [0.0, from_g, to_g]
	return [clampf((ts - from_g.host_timestamp) / dt, 0.0, 1.0), from_g, to_g]
