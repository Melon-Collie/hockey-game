class_name StatsSyncGate
extends RefCounted

# Coalesces high-frequency stat-sync requests into at most one flush per
# broadcast interval. The 120 Hz contact paths (goalie touches, deflections,
# blocked shots, possession establishment, credited hits) used to call
# GameManager._sync_stats_to_clients directly — a full-roster
# WorldStateCodec.encode_stats + reliable RPC per contact, paid inside the
# physics tick. Those paths now mark_dirty(); GameManager's end-of-tick hook
# asks should_flush() on the broadcast cadence and runs the one real sync.
# Game-phase transitions (goals, period ends, game over, roster changes) still
# sync immediately — an immediate sync calls clear() so the pending
# contact-path flush it supersedes doesn't fire a redundant second encode.

var _dirty: bool = false


func mark_dirty() -> void:
	_dirty = true


func is_dirty() -> bool:
	return _dirty


func clear() -> void:
	_dirty = false


# True (consuming the dirty flag) when a flush should run now: something is
# pending and the caller says this tick is a broadcast tick. Not due or not
# dirty leaves the flag as-is.
func should_flush(broadcast_due: bool) -> bool:
	if _dirty and broadcast_due:
		_dirty = false
		return true
	return false
