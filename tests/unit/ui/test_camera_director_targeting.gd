extends GutTest

# CameraDirector's chase / POV cycle list picks who you watch. The replay viewer
# points it at the peer that recorded the file (set_preferred_target) so the
# tracking modes open on "you" instead of whoever happens to be first in the
# roster — while live spectator mode, which sets no preference, keeps the old
# first-in-the-list behavior.
#
# Real skater instances in the tree: activating a tracking camera snaps to the
# target's global transform, which only exists inside the tree.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")

var _director: CameraDirector = null
var _skaters: Array[Skater] = []


func before_each() -> void:
	_skaters = []
	for _i: int in 4:
		_skaters.append(_spawn_skater())
	_director = CameraDirector.new()
	add_child_autofree(_director)
	_director.setup(
		func() -> Vector3: return Vector3.ZERO,
		func() -> Array[Skater]: return _live_skaters())


func _spawn_skater() -> Skater:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	return skater


# Mirrors ReplayViewer's getter: freed actors drop out of the list.
func _live_skaters() -> Array[Skater]:
	var out: Array[Skater] = []
	for s: Skater in _skaters:
		if is_instance_valid(s):
			out.append(s)
	return out


func test_no_preference_tracks_the_first_skater() -> void:
	# Live spectator mode's contract — unchanged by the replay wiring.
	_director.cycle_mode()  # BROADCAST → CHASE, which builds the cycle list
	assert_eq(_director.current_target(), _skaters[0])
	assert_eq(_director.get_mode_label(), "CHASE 1/4")


func test_preferred_target_is_what_the_tracking_modes_open_on() -> void:
	_director.set_preferred_target(_skaters[2])
	assert_eq(_director.current_target(), _skaters[2],
			"the recording peer should be tracked before any mode switch")
	_director.cycle_mode()
	assert_eq(_director.get_mode_label(), "CHASE 3/4")
	# POV shares the tracked skater with chase, so switching between them holds.
	_director.cycle_mode()
	assert_eq(_director.get_mode_label(), "POV 3/4")
	assert_eq(_director.current_target(), _skaters[2])


# The preference is a starting point, not a lock — once the user cycles, the
# director must stay where they put it.
func test_user_cycling_beats_the_preference() -> void:
	_director.set_preferred_target(_skaters[2])
	_director.cycle_mode()
	_director.cycle_chase_target(1)
	assert_eq(_director.current_target(), _skaters[3])
	# A roster refresh (any mode entry / target cycle) must not snap back.
	_director.cycle_mode()
	assert_eq(_director.current_target(), _skaters[3])


# A backward seek in the viewer frees every skater and respawns the roster; the
# viewer re-points the director at the new actor as it spawns.
func test_respawned_preferred_target_is_re_adopted() -> void:
	_director.set_preferred_target(_skaters[2])
	_director.cycle_mode()
	for s: Skater in _skaters:
		s.free()
	assert_null(_director.current_target(), "a freed target must read as nothing tracked")
	_skaters = []
	for _i: int in 4:
		_skaters.append(_spawn_skater())
	_director.set_preferred_target(_skaters[2])
	assert_eq(_director.current_target(), _skaters[2])


# A preference naming somebody who isn't on the ice (they left before the seek
# target) must not wedge the cycle list — fall back to the first skater.
func test_preferred_target_absent_from_the_roster_falls_back() -> void:
	var stranger: Skater = _spawn_skater()
	_skaters.erase(stranger)
	_director.set_preferred_target(stranger)
	_director.cycle_mode()
	assert_eq(_director.current_target(), _skaters[0])
	assert_eq(_director.get_mode_label(), "CHASE 1/4")
