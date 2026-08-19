class_name ReplayLiveSimHold
extends RefCounted

# Parks the live world while a replay driver scrubs the actors through it, and
# puts it back exactly as it was.
#
# Both halves matter, and the second is the one that was worth extracting: the
# goalies are restored to their OWN saved processing state rather than blanket
# re-enabled, because a goalie already disabled for some other reason must not
# come back on when a replay ends. That is four lines of bookkeeping which
# looked incidental in both copies.

var _puck: Puck = null
var _goalie_controllers: Array[GoalieController] = []
var _saved_goalie_processing: Array[bool] = []


# The hold flag parks the analytic loose-puck sim; the goalies stop ticking so
# their AI cannot fight the poses being applied.
func grab(puck: Puck, goalie_controllers: Array[GoalieController]) -> void:
	_puck = puck
	_goalie_controllers = goalie_controllers
	if _puck != null:
		_puck.set_replay_hold(true)
	_saved_goalie_processing.clear()
	for gc: GoalieController in _goalie_controllers:
		_saved_goalie_processing.append(gc.is_physics_processing())
		gc.set_physics_process(false)


# Dropping the puck hold is all the drive needs to resume — the game transitions
# to FACEOFF_PREP after a replay stops, which calls puck.reset().
func release() -> void:
	if _puck != null:
		_puck.set_replay_hold(false)
	for i: int in _goalie_controllers.size():
		var was: bool = _saved_goalie_processing[i] if i < _saved_goalie_processing.size() else true
		_goalie_controllers[i].set_physics_process(was)
	_saved_goalie_processing.clear()
	_puck = null
	_goalie_controllers = []
