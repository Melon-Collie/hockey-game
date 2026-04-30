class_name PerceptionBuffer
extends RefCounted

# Pre-allocated ring buffer of WorldSnapshots. Owned by GameManager (host).
# Host calls write(...) once per physics tick after physics has stepped and
# before controllers process. Agents call read(delay_ticks) to fetch a
# snapshot delayed by their per-skill reaction window.
#
# Sizing: 64 slots @ 240 Hz = 267 ms of history. Generous for any reaction
# delay we'll plausibly pick — the buffer is cheap (one WorldSnapshot per
# slot), so leaving headroom is fine. The actual delay used by AI is set
# elsewhere as a single global value (we're not shipping per-skill scaling).
#
# Snapshots store ground truth: no noise, no jitter, no skill-derived
# transforms. If we add perception noise later it lives on the consumer,
# not in the buffer, so debug visualizers and tests see truth.

const RING_SIZE: int = 64

var _ring: Array[WorldSnapshot] = []
var _write_index: int = 0
var _latest_tick: int = -1


func _init() -> void:
	_ring.resize(RING_SIZE)
	for i: int in RING_SIZE:
		_ring[i] = WorldSnapshot.new()


# Returns the WorldSnapshot slot the host should populate this tick. The
# caller fills it in-place, then calls commit(tick). Two-step pattern keeps
# the codec-style "fill then commit" idiom and avoids a temporary copy.
func acquire() -> WorldSnapshot:
	var dst: WorldSnapshot = _ring[_write_index]
	dst.clear()
	return dst


func commit(tick: int, time: float) -> void:
	var dst: WorldSnapshot = _ring[_write_index]
	dst.tick = tick
	dst.time = time
	_latest_tick = tick
	_write_index = (_write_index + 1) % RING_SIZE


# Returns the snapshot from `delay_ticks` before the latest write.
# delay_ticks=0 returns the most recent snapshot. If the buffer hasn't been
# written to yet, returns the (empty) slot at index 0 — callers must check
# `tick != 0` or the time field before consuming.
func read(delay_ticks: int) -> WorldSnapshot:
	if _latest_tick < 0:
		return _ring[0]
	var clamped: int = clampi(delay_ticks, 0, RING_SIZE - 1)
	# _write_index points to the next write slot; the latest committed slot
	# is one back. Modular arithmetic with the +RING_SIZE guard keeps the
	# index non-negative for any clamped delay.
	var idx: int = ((_write_index - 1 - clamped) % RING_SIZE + RING_SIZE) % RING_SIZE
	return _ring[idx]


func get_latest_tick() -> int:
	return _latest_tick
