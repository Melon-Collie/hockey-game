class_name CameraDirector
extends Node

# Owns the four cameras that spectator mode and the offline replay viewer
# share (broadcast, chase, POV, free). Handles mode cycling, target cycling
# for the skater-tracking modes, and input dispatch. Only one camera is
# current at a time; the others sit parked as children of this node.
#
# Lifecycle: instance, add_child, setup(), then activate_initial() (defaults
# to broadcast). On teardown(), restores whichever camera was current before
# the director took over.


enum Mode { BROADCAST, CHASE, POV, FREE }

const _MODE_COUNT: int = 4

var _broadcast: SpectatorCamera = null
var _chase: ChaseCamera = null
var _pov: PovCamera = null
var _free: FreeCamera = null

var _mode: int = Mode.BROADCAST
var _puck_getter: Callable = Callable()
var _skaters_getter: Callable = Callable()
var _chase_index: int = 0
# Cached cycle list so cycle_chase_target() sees the same ordering even if a
# mid-game roster change reorders the dictionary. Refreshed on each entry into
# a skater-tracking mode and on cycle_chase_target. Shared by CHASE and POV so
# switching between them keeps the same tracked skater.
var _cached_targets: Array[Skater] = []
# Who the tracking modes open on (set_preferred_target). Consulted only when
# there is no tracked skater to preserve — first entry into CHASE / POV, or
# after the tracked one leaves the ice — so the user's own cycling always wins.
# Null (the default, and what live spectator mode leaves it at) keeps the
# original behavior: whoever the roster getter yields first.
var _preferred_target: Skater = null


func setup(puck_getter: Callable, skaters_getter: Callable) -> void:
	_puck_getter = puck_getter
	_skaters_getter = skaters_getter

	_broadcast = SpectatorCamera.new()
	add_child(_broadcast)
	_broadcast.setup(puck_getter)

	# The cameras read the tracked skater through the same accessor the director
	# does, so a target freed under them (replay seek) reads null rather than a
	# dangling reference.
	var target_getter: Callable = current_target

	_chase = ChaseCamera.new()
	add_child(_chase)
	_chase.setup(target_getter)

	_pov = PovCamera.new()
	add_child(_pov)
	_pov.setup(target_getter, puck_getter)

	_free = FreeCamera.new()
	add_child(_free)


# Names the skater CHASE / POV should open on — the replay viewer points this
# at the peer that recorded the file, so "watch my own POV" is one key press
# rather than a hunt through the cycle list. Safe to call before or after the
# cameras exist, and safe to re-point at a respawned actor.
func set_preferred_target(skater: Skater) -> void:
	_preferred_target = skater
	# Adopt it now if nothing is being tracked yet, so a call that lands after
	# the first _refresh_targets (a mid-game arrival, a post-seek respawn) still
	# takes effect.
	if current_target() == null:
		_refresh_targets()


func activate_initial() -> void:
	_mode = Mode.BROADCAST
	_broadcast.activate()


func teardown() -> void:
	# Whichever camera is current owns the restore-prev-camera contract;
	# explicitly deactivate it so the viewport returns to the original camera.
	match _mode:
		Mode.BROADCAST: _broadcast.deactivate()
		Mode.CHASE: _chase.deactivate()
		Mode.POV: _pov.deactivate()
		Mode.FREE: _free.deactivate()
	queue_free()


func get_mode_label() -> String:
	match _mode:
		Mode.BROADCAST:
			return "BROADCAST"
		Mode.CHASE:
			return _target_label("CHASE")
		Mode.POV:
			return _target_label("POV")
		Mode.FREE:
			return "FREE"
	return ""


func _target_label(prefix: String) -> String:
	var n: int = _cached_targets.size()
	if n == 0:
		return prefix
	return "%s %d/%d" % [prefix, _chase_index + 1, n]


func cycle_mode() -> void:
	# BROADCAST → CHASE → POV → FREE → BROADCAST. The skater-tracking modes are
	# skipped if no skaters are on the ice (early-game roster gap, all peers
	# spectating, etc.).
	var next: int = _mode
	for _i in _MODE_COUNT:
		next = (next + 1) % _MODE_COUNT
		if (next == Mode.CHASE or next == Mode.POV) and _refresh_targets().is_empty():
			continue
		break
	_set_mode(next)


# Playback discontinuity (seek, recording-gap skip, faceoff reset): the world
# just teleported, so the tracking cameras cut to the new action instead of
# panning across the jump. Free cam is user-driven — leave it alone.
func on_playback_discontinuity() -> void:
	match _mode:
		Mode.BROADCAST:
			_broadcast.snap_to_position()
		Mode.CHASE:
			_chase.snap_to_target()
		Mode.POV:
			_pov.snap_to_target()


func cycle_chase_target(direction: int) -> void:
	if _mode != Mode.CHASE and _mode != Mode.POV:
		return
	var targets: Array[Skater] = _refresh_targets()
	if targets.is_empty():
		return
	_chase_index = posmod(_chase_index + direction, targets.size())
	# Snap to the new target's pose so the next frame's smooth follow starts
	# from there instead of lerping across the rink from the previous skater.
	if _mode == Mode.CHASE:
		_chase.snap_to_target()
	else:
		_pov.snap_to_target()


func _set_mode(new_mode: int) -> void:
	if new_mode == _mode:
		return
	var prev_xform: Transform3D = _current_transform()
	match _mode:
		Mode.BROADCAST: _broadcast.deactivate()
		Mode.CHASE: _chase.deactivate()
		Mode.POV: _pov.deactivate()
		Mode.FREE: _free.deactivate()
	_mode = new_mode
	match _mode:
		Mode.BROADCAST:
			_broadcast.activate()
		Mode.CHASE:
			_refresh_targets()
			_chase.activate()
		Mode.POV:
			_refresh_targets()
			_pov.activate()
		Mode.FREE:
			# Inherit the previous camera's pose so the swap doesn't snap.
			_free.activate(prev_xform)


func _current_transform() -> Transform3D:
	match _mode:
		Mode.BROADCAST: return _broadcast.global_transform
		Mode.CHASE: return _chase.current_transform()
		Mode.POV: return _pov.current_transform()
		Mode.FREE: return _free.global_transform
	return Transform3D.IDENTITY


# Null when nothing is tracked OR the tracked actor has been freed (a replay
# seek tears the whole roster down and respawns it), so callers can test for a
# live target with one comparison.
func current_target() -> Skater:
	if _cached_targets.is_empty():
		return null
	var tracked: Skater = _cached_targets[clampi(_chase_index, 0, _cached_targets.size() - 1)]
	return tracked if is_instance_valid(tracked) else null


# Re-queries the skaters getter and rebuilds the cycle list, dropping freed
# or null entries. Preserves the currently-targeted skater's index if it's
# still present so cycle direction stays consistent across roster changes;
# falls back to the preferred target when there is nothing to preserve.
func _refresh_targets() -> Array[Skater]:
	if not _skaters_getter.is_valid():
		_cached_targets = []
		return _cached_targets
	var raw: Variant = _skaters_getter.call()
	var prev: Skater = current_target()
	var fresh: Array[Skater] = []
	if raw is Array:
		for entry: Variant in raw:
			if entry is Skater and is_instance_valid(entry):
				fresh.append(entry as Skater)
	_cached_targets = fresh
	var idx: int = _cached_targets.find(prev) if prev != null else -1
	if idx < 0 and is_instance_valid(_preferred_target):
		idx = _cached_targets.find(_preferred_target)
	if idx >= 0:
		_chase_index = idx
	else:
		_chase_index = clampi(_chase_index, 0, max(0, _cached_targets.size() - 1))
	return _cached_targets


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("camera_cycle_mode"):
		cycle_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("camera_next_target"):
		cycle_chase_target(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("camera_prev_target"):
		cycle_chase_target(-1)
		get_viewport().set_input_as_handled()
