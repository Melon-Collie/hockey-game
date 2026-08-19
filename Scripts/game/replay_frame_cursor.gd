class_name ReplayFrameCursor
extends RefCounted

# "Which two recorded frames bracket this instant, decoded once." Every replay
# driver needs exactly that and each had written it out: find the frame at or
# before the clock, pair it with the next, re-decode only when the pair changes,
# and hand both to ReplayPlaybackEngine with the fraction between them.
#
# The cursor deliberately does NOT hold the frames. Drivers use their timestamp
# array for their own purposes — the file driver steps frame-by-frame and jumps
# recording gaps with it — and a cursor that owned the array would have to
# re-export it accessor by accessor, which is how a small collaborator turns
# into a wide one. It owns the decode cache and the scan hint, nothing else.
#
# What each driver keeps is the POLICY: the clip player takes alpha() straight,
# while the file viewer overrides it to hold the FROM frame across a recording
# gap or a faceoff reset rather than sweeping every actor across the rink in one
# bracket.

var _codec: WorldStateCodec = null
var _from_snap: Dictionary = {}
var _to_snap: Dictionary = {}
var _from_idx: int = -1
var _to_idx: int = -1
# Timestamps only advance within a clip, so the scan resumes where it left off
# instead of walking the whole array every frame. Reset on a backward seek.
var _hint: int = 0
var _bracket_changed: bool = false
var _bracket_dt: float = 0.0
var _alpha: float = 0.0


func bind(codec: WorldStateCodec) -> void:
	_codec = codec


# Forget the cached bracket. Call on any discontinuity — a new clip, a backward
# seek, teardown — or the next seek reads a stale decode as current.
func reset() -> void:
	_from_snap = {}
	_to_snap = {}
	_from_idx = -1
	_to_idx = -1
	_hint = 0
	_bracket_changed = false
	_bracket_dt = 0.0
	_alpha = 0.0


# Index of the last frame at or before `t`, or -1 when the clock sits before the
# first frame.
func find_index(timestamps: Array[float], t: float) -> int:
	if _hint > 0 and (_hint >= timestamps.size() or timestamps[_hint] > t):
		_hint = 0
	var best: int = -1
	for i: int in range(_hint, timestamps.size()):
		if timestamps[i] > t:
			break
		best = i
	if best >= 0:
		_hint = best
	return best


# Positions the cursor at `t`. False means there is nothing to draw — the clock
# is before the first frame, or the frame did not decode — and the caller must
# return rather than reuse the previous pose.
func seek(frames: Array[PackedByteArray], timestamps: Array[float], t: float) -> bool:
	_bracket_changed = false
	var idx: int = find_index(timestamps, t)
	if idx < 0:
		return false
	var idx_next: int = mini(idx + 1, frames.size() - 1)
	if idx != _from_idx or idx_next != _to_idx:
		_from_snap = _codec.decode_for_replay(frames[idx])
		_to_snap = _codec.decode_for_replay(frames[idx_next])
		_from_idx = idx
		_to_idx = idx_next
		_bracket_changed = true
	if _from_snap.is_empty():
		return false
	_bracket_dt = timestamps[idx_next] - timestamps[idx]
	_alpha = clampf((t - timestamps[idx]) / _bracket_dt, 0.0, 1.0) if _bracket_dt > 0.0 else 0.0
	return true


# True when the last seek landed on a different pair — the moment a driver
# watching for a phase keyframe has to look, since the decode only happens here.
func bracket_changed() -> bool:
	return _bracket_changed


func from_snap() -> Dictionary:
	return _from_snap


func to_snap() -> Dictionary:
	return _to_snap


func bracket_dt() -> float:
	return _bracket_dt


func alpha() -> float:
	return _alpha
