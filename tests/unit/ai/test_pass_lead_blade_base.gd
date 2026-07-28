extends GutTest

# Where a pass lead is measured FROM.
#
# AIPassLead.lead aims at `receiver.blade_contact_world` — the live stick tip —
# and then extrapolates it forward by the receiver's BODY velocity. That is two
# different things stacked: the stick's current offset from the body, plus the
# travel the body will do during the flight.
#
# The stick's offset is not a prediction. An off-puck bot's cursor is its ready
# stance (SkaterAgentStateMachine._compute_desired_aim_dir): far from its anchor
# it points the stick along its travel direction, so the blade sits most of a
# stick-length AHEAD of the body — and that offset gets added to the lead. At
# arrival the receiver is not holding that pose at all: _pass_receive_aim_and_steer
# stands its body aside from the puck's path and parks the blade ON the line, so
# the forward-pointing stick the lead was measured from no longer exists.
#
# These pin that the lead no longer depends on the stance at all: the aim point
# is the body's travel, and where the receiver happens to be holding its stick
# when the pass is decided moves it by nothing.

const RECEIVER_SPEED: float = 6.0
const LAUNCH_SPEED: float = 14.0
const MAX_LEAD_S: float = 1.5
# League-baseline stick reach — how far the blade sits from the body.
var _reach: float = GameRules.DEFAULT_STICK_LENGTH_M + GameRules.DEFAULT_BLADE_LENGTH_M


# A receiver skating along +z at RECEIVER_SPEED, with its stick pointed
# `blade_dir` (a unit XZ direction) at full reach from the body.
func _receiver(blade_dir: Vector3) -> SkaterNetworkState:
	var r := SkaterNetworkState.new()
	r.position = Vector3(0.0, 0.0, 0.0)
	r.velocity = Vector3(0.0, 0.0, RECEIVER_SPEED)
	r.blade_contact_world = r.position + blade_dir * _reach
	return r


func _lead_point(blade_dir: Vector3) -> Vector3:
	return AIPassLead.lead_point(
			Vector3(0.0, 0.0, -14.0), _receiver(blade_dir),
			Vector3.ZERO, LAUNCH_SPEED, MAX_LEAD_S)


func test_the_stance_does_not_move_the_aim_point() -> void:
	# Identical body state — same position, same velocity, same (zero)
	# acceleration. The ONLY difference is which way the receiver happens to be
	# holding its stick. If the lead were a prediction of the body's travel,
	# these would barely differ.
	var forward: Vector3 = _lead_point(Vector3(0.0, 0.0, 1.0))
	var lateral: Vector3 = _lead_point(Vector3(1.0, 0.0, 0.0))
	var trailing: Vector3 = _lead_point(Vector3(0.0, 0.0, -1.0))
	gut.p("  aim z by stance: forward %.2f | lateral %.2f | trailing %.2f"
			% [forward.z, lateral.z, trailing.z])
	gut.p("  forward-vs-trailing spread: %.2f m (stick reach %.2f m)"
			% [forward.z - trailing.z, _reach])
	# Before the body-based lead these spread by 3.43 m — two stick reaches — for
	# a receiver doing exactly the same thing in all three cases.
	assert_almost_eq(forward.z, trailing.z, 0.001,
			"stick pose does not move the aim point")
	assert_almost_eq(forward.z, lateral.z, 0.001,
			"nor does a laterally-held stick")


func test_the_aim_is_exactly_the_body_travel() -> void:
	# The body's own travel over the solved flight IS the lead. Anything beyond
	# it was stance, and used to measure a flat one stick reach.
	var res: Array = AIPassLead.lead(
			Vector3(0.0, 0.0, -14.0), _receiver(Vector3(0.0, 0.0, 1.0)),
			Vector3.ZERO, LAUNCH_SPEED, MAX_LEAD_S)
	var point: Vector3 = res[0]
	var flight_t: float = res[1]
	var body_at_arrival: float = RECEIVER_SPEED * flight_t
	var overshoot: float = point.z - body_at_arrival
	gut.p("  flight %.3fs: body reaches z=%.2f, aim is z=%.2f (overshoot %.2f m)"
			% [flight_t, body_at_arrival, point.z, overshoot])
	assert_almost_eq(overshoot, 0.0, 0.01,
			"the aim lands on the body's travel, not a stick reach past it")


func test_no_residual_bias_at_any_receiver_speed() -> void:
	# The case that mattered: an off-puck receiver moving toward its role anchor
	# points its stick along travel (the ready stance), so the stance offset and
	# the travel lead always ADDED — a consistent over-lead rather than scatter,
	# and speed-independent, since the offset is a stick length either way.
	for speed: float in [2.0, 5.0, 8.0]:
		var r := SkaterNetworkState.new()
		r.position = Vector3.ZERO
		r.velocity = Vector3(0.0, 0.0, speed)
		r.blade_contact_world = Vector3(0.0, 0.0, _reach)  # stick along travel
		var res: Array = AIPassLead.lead(
				Vector3(0.0, 0.0, -14.0), r, Vector3.ZERO, LAUNCH_SPEED, MAX_LEAD_S)
		var overshoot: float = res[0].z - speed * res[1]
		gut.p("  v=%.0f m/s: aim vs body travel %+.3f m" % [speed, overshoot])
		assert_almost_eq(overshoot, 0.0, 0.01,
				"no stance residual at any speed (v=%.0f)" % speed)
