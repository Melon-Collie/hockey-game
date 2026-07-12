class_name CameraDirector
extends Node

# Owns the three cameras that spectator mode and the offline replay viewer
# share (broadcast, chase, free). Handles mode cycling, chase-target cycling,
# and input dispatch. Only one camera is current at a time; the others sit
# parked as children of this node.
#
# Lifecycle: instance, add_child, setup(), then activate_initial() (defaults
# to broadcast). On teardown(), restores whichever camera was current before
# the director took over.

signal mode_changed(label: String)

enum Mode { BROADCAST, CHASE, FREE }

var _broadcast: SpectatorCamera = null
var _chase: ChaseCamera = null
var _free: FreeCamera = null

var _mode: int = Mode.BROADCAST
var _puck_getter: Callable = Callable()
var _skaters_getter: Callable = Callable()
var _chase_index: int = 0
# Cached cycle list so cycle_chase_target() sees the same ordering even if a
# mid-game roster change reorders the dictionary. Refreshed on each entry into
# CHASE mode and on cycle_chase_target.
var _cached_targets: Array[Skater] = []


func setup(puck_getter: Callable, skaters_getter: Callable) -> void:
	_puck_getter = puck_getter
	_skaters_getter = skaters_getter

	_broadcast = SpectatorCamera.new()
	add_child(_broadcast)
	_broadcast.setup(puck_getter)

	_chase = ChaseCamera.new()
	add_child(_chase)
	_chase.setup(func() -> Skater:
		if _cached_targets.is_empty():
			return null
		return _cached_targets[clampi(_chase_index, 0, _cached_targets.size() - 1)])

	_free = FreeCamera.new()
	add_child(_free)


func activate_initial() -> void:
	_mode = Mode.BROADCAST
	_broadcast.activate()
	mode_changed.emit(get_mode_label())


func teardown() -> void:
	# Whichever camera is current owns the restore-prev-camera contract;
	# explicitly deactivate it so the viewport returns to the original camera.
	match _mode:
		Mode.BROADCAST: _broadcast.deactivate()
		Mode.CHASE: _chase.deactivate()
		Mode.FREE: _free.deactivate()
	queue_free()


func get_mode() -> int:
	return _mode


func get_mode_label() -> String:
	match _mode:
		Mode.BROADCAST:
			return "BROADCAST"
		Mode.CHASE:
			var n: int = _cached_targets.size()
			if n == 0:
				return "CHASE"
			return "CHASE %d/%d" % [_chase_index + 1, n]
		Mode.FREE:
			return "FREE"
	return ""


func cycle_mode() -> void:
	# BROADCAST → CHASE → FREE → BROADCAST. CHASE is skipped if no skaters are
	# on the ice (early-game roster gap, all peers spectating, etc.).
	var next: int = _mode
	for _i in 3:
		next = (next + 1) % 3
		if next == Mode.CHASE and _refresh_targets().is_empty():
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


func cycle_chase_target(direction: int) -> void:
	if _mode != Mode.CHASE:
		return
	var targets: Array[Skater] = _refresh_targets()
	if targets.is_empty():
		return
	_chase_index = posmod(_chase_index + direction, targets.size())
	# Snap to the new target's pose so the next frame's smooth follow starts
	# from there instead of lerping across the rink from the previous skater.
	_chase.snap_to_target()
	mode_changed.emit(get_mode_label())


func _set_mode(new_mode: int) -> void:
	if new_mode == _mode:
		return
	var prev_xform: Transform3D = _current_transform()
	match _mode:
		Mode.BROADCAST: _broadcast.deactivate()
		Mode.CHASE: _chase.deactivate()
		Mode.FREE: _free.deactivate()
	_mode = new_mode
	match _mode:
		Mode.BROADCAST:
			_broadcast.activate()
		Mode.CHASE:
			_refresh_targets()
			_chase.activate()
		Mode.FREE:
			# Inherit the previous camera's pose so the swap doesn't snap.
			_free.activate(prev_xform)
	mode_changed.emit(get_mode_label())


func _current_transform() -> Transform3D:
	match _mode:
		Mode.BROADCAST: return _broadcast.global_transform
		Mode.CHASE: return _chase.current_transform()
		Mode.FREE: return _free.global_transform
	return Transform3D.IDENTITY


func _current_chase_skater() -> Skater:
	if _cached_targets.is_empty():
		return null
	return _cached_targets[clampi(_chase_index, 0, _cached_targets.size() - 1)]


# Re-queries the skaters getter and rebuilds the cycle list, dropping freed
# or null entries. Preserves the currently-targeted skater's index if it's
# still present so cycle direction stays consistent across roster changes.
func _refresh_targets() -> Array[Skater]:
	if not _skaters_getter.is_valid():
		_cached_targets = []
		return _cached_targets
	var raw: Variant = _skaters_getter.call()
	var prev: Skater = _current_chase_skater()
	var fresh: Array[Skater] = []
	if raw is Array:
		for entry: Variant in raw:
			if entry is Skater and is_instance_valid(entry):
				fresh.append(entry as Skater)
	_cached_targets = fresh
	if prev != null and is_instance_valid(prev):
		var idx: int = _cached_targets.find(prev)
		if idx >= 0:
			_chase_index = idx
		else:
			_chase_index = clampi(_chase_index, 0, max(0, _cached_targets.size() - 1))
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
