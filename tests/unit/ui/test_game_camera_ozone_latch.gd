extends GutTest

# GameCamera._update_in_ozone — the attacking-zone goal-fit latch.
#
# The fit is a step change (crossing in adds the goal line to the Z extent,
# swinging the zoom by most of its range and dragging the camera's Z with it
# through the tilt offset), so the interesting property is not "does it engage"
# but "can a velocity change alone toggle it". It cannot: engage reads the
# predicted Z, release reads the true Z, and the two differ by exactly the
# prediction lead.
#
# The camera is built unparented so _ready() — make_current(), GameManager signal
# wiring — never runs. The latch reads only its own state and GameRules.

var _cam: GameCamera = null

# Prediction lead at the league-default top speed: the largest swing a direction
# change can put into predicted_z while the player stands still.
var _lead: float = 0.0


func before_each() -> void:
	_cam = GameCamera.new()
	autofree(_cam)
	_lead = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S * _cam.ozone_predict_time


# Predicted Z for a player at `z` skating at `vz`, matching the call site.
func _predicted(z: float, vz: float) -> float:
	return z + vz * _cam.ozone_predict_time


func test_disengaged_behind_the_line_stays_off() -> void:
	var z: float = GameRules.BLUE_LINE_Z - 5.0
	assert_false(_cam._update_in_ozone(z, _predicted(z, 0.0), 1),
			"a stationary player in the neutral zone must not fit the goal")


func test_engages_on_the_predicted_crossing_before_the_real_one() -> void:
	# Still short of the line, but skating at it fast enough to arrive within the
	# prediction window — engaging here is the point of predicting.
	var z: float = GameRules.BLUE_LINE_Z - 1.0
	var predicted: float = _predicted(z, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S)
	assert_gt(predicted, GameRules.BLUE_LINE_Z, "test setup: prediction must clear the line")
	assert_true(_cam._update_in_ozone(z, predicted, 1),
			"a fast carry-in should engage before the body crosses")


# The regression this latch exists for: a single threshold on the predicted Z
# releases here, because reversing swings predicted_z back across the line
# without the player having moved at all.
func test_reversing_at_speed_does_not_release_while_truly_inside() -> void:
	var z: float = GameRules.BLUE_LINE_Z + 0.5
	assert_true(_cam._update_in_ozone(z, _predicted(z, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S), 1),
			"test setup: should be engaged going in")
	var reversed_predicted: float = _predicted(z, -GameRules.DEFAULT_SKATER_MAX_SPEED_M_S)
	assert_lt(reversed_predicted, GameRules.BLUE_LINE_Z,
			"test setup: the reversal must swing the prediction back over the line")
	assert_true(_cam._update_in_ozone(z, reversed_predicted, 1),
			"a direction change alone must not drop the goal fit")


func test_releases_once_the_player_actually_retreats() -> void:
	var inside: float = GameRules.BLUE_LINE_Z + 0.5
	_cam._update_in_ozone(inside, _predicted(inside, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S), 1)
	var outside: float = GameRules.BLUE_LINE_Z - 0.1
	assert_false(_cam._update_in_ozone(outside, _predicted(outside, 0.0), 1),
			"crossing back out for real must release the fit")


func test_full_speed_reversal_cannot_toggle_the_latch_either_way() -> void:
	# Sweep the band the prediction lead can reach on both sides of the line and
	# assert the latch depends only on true position once engaged — i.e. the
	# hysteresis exactly cancels the prediction term.
	var steps: int = 12
	for i: int in steps:
		var z: float = GameRules.BLUE_LINE_Z - _lead + (2.0 * _lead) * (float(i) / float(steps - 1))
		_cam._in_ozone = true
		var forward: bool = _cam._update_in_ozone(z, _predicted(z, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S), 1)
		_cam._in_ozone = true
		var backward: bool = _cam._update_in_ozone(z, _predicted(z, -GameRules.DEFAULT_SKATER_MAX_SPEED_M_S), 1)
		assert_eq(forward, backward,
				"at z=%.2f the engaged latch must not depend on skating direction" % z)


func test_no_carrier_clears_the_latch() -> void:
	var z: float = GameRules.BLUE_LINE_Z + 5.0
	_cam._update_in_ozone(z, _predicted(z, 0.0), 1)
	assert_false(_cam._update_in_ozone(z, _predicted(z, 0.0), 0),
			"a loose puck (no attacking direction) has no zone to fit")
	assert_false(_cam._in_ozone, "the latch itself must be cleared, not just the return")


func test_possession_flip_releases_for_a_player_left_upstream() -> void:
	# Deep in the zone the team was attacking, then the other team takes it: the
	# same Z is now behind the local player's defensive blue line, not past an
	# attacking one, so the fit must drop.
	var z: float = GameRules.BLUE_LINE_Z + 5.0
	assert_true(_cam._update_in_ozone(z, _predicted(z, 0.0), 1), "test setup: engaged attacking +Z")
	assert_false(_cam._update_in_ozone(z, _predicted(z, 0.0), -1),
			"a possession change must re-evaluate against the new attacking direction")


func test_mirrors_for_the_negative_attacking_direction() -> void:
	var z: float = -(GameRules.BLUE_LINE_Z + 0.5)
	assert_true(_cam._update_in_ozone(z, _predicted(z, -GameRules.DEFAULT_SKATER_MAX_SPEED_M_S), -1),
			"attacking -Z should engage symmetrically")
	assert_true(_cam._update_in_ozone(z, _predicted(z, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S), -1),
			"and hold through a reversal the same way")
