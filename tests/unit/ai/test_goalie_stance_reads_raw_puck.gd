extends GutTest

# ── THE STANCE GATES READ THE RAW PUCK; POSITIONING READS THE FILTERED ONE ───
# `_update_tracking` exists to reject stickhandling jitter: the puck's offset from
# the carrier is low-passed, and `_tracked_threat_position` is what `_update_depth`
# and the arc target consume. See "Filter the puck, not the man".
#
# Four stance gates bypass it and read `puck.global_position` directly —
# `_is_ready_situation`, `_is_puck_in_defensive_zone`, `_is_threat_pressing`, and
# `_should_play_rim`. So a dangle the POSITION deliberately smooths can still move
# the STANCE, and each of those gates is a threshold with a real play sitting on
# it: the READY zone edge, the RVH/VH angle, and the recovery proximity stay.
#
# Measured with a 0.35 m, 2 Hz stickhandle — a carry, not a deke — against the
# same carrier standing perfectly still as the control:
#
#   what the filter removes    carrier 2 m: 73% of the swing survives
#                              carrier 5 m: 41%      carrier 9 m: 23%
#
#   stance changes in 3 s      still        dangling
#     recovery-stay edge         0             17
#     post-stance angle gate     0          11-12
#
# The control is zero everywhere, so the flips are the dangle and nothing else.
# In tight the filter deliberately keeps most of the puck (that is the design —
# he tracks the puck at the doorstep and the chest at range), so the gap is
# widest exactly where it costs least; at range the gates are acting on four
# fifths of a signal the position half has thrown away.
#
# The `rvh_swap_deadband_m` and `post_stance_swap_deadband_m` knobs exist to damp
# this, which is the tell that it is real — they damp the SIDE swap, not the
# entry.

const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const DT: float = 1.0 / 120.0
const SkaterScene := preload("res://Scenes/Skater.tscn")
const DANGLE_M: float = 0.35      # a stickhandle, not a deke
const DANGLE_HZ: float = 2.0

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = SkaterScene.instantiate() as Skater
	_ctrl = GoalieController.new()
	for n: Node in [_goalie, _puck, _shooter, _ctrl]:
		add_child_autofree(n)
	_shooter.set_physics_process(false)
	_shooter.set_process(false)
	_ctrl.set_skater_getter(func() -> Array: return [_shooter])
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)


# Park a carrier at (lane, dist) and stickhandle for `secs`, counting stance
# changes. `amplitude` 0 is the control: the same standing carrier, no dangle.
func _dangle(lane: float, dist: float, amplitude: float, secs: float) -> Dictionary:
	_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	_shooter.predicted_shot_velocity = Vector3.ZERO
	_shooter.global_position = Vector3(lane, 0.0, GOAL_Z + dist)
	_shooter.velocity = Vector3.ZERO
	_puck.global_position = _shooter.global_position
	_puck.set_carrier(_shooter)
	_ctrl.reset_to_crease()
	for _i: int in 240:                      # settle with the puck still
		_puck.global_position = _shooter.global_position
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
	var flips: int = 0
	var prev: int = _ctrl.stance()
	var raw_lo: float = INF
	var raw_hi: float = -INF
	var trk_lo: float = INF
	var trk_hi: float = -INF
	var t: float = 0.0
	for _i: int in int(secs / DT):
		var off: float = amplitude * sin(TAU * DANGLE_HZ * t)
		_puck.global_position = _shooter.global_position + Vector3(off, 0.0, 0.0)
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
		t += DT
		raw_lo = minf(raw_lo, _puck.global_position.x)
		raw_hi = maxf(raw_hi, _puck.global_position.x)
		trk_lo = minf(trk_lo, _ctrl._tracked_threat_position.x)
		trk_hi = maxf(trk_hi, _ctrl._tracked_threat_position.x)
		var s: int = _ctrl.stance()
		if s != prev:
			flips += 1
		prev = s
	return {"flips": flips, "raw_span": raw_hi - raw_lo,
			"tracked_span": trk_hi - trk_lo, "final": _ctrl.stance()}


# ── HOW MUCH THE FILTER ACTUALLY REMOVES ─────────────────────────────────────
# The size of what the gates are throwing away. If the tracked span were close to
# the raw span the whole finding would be moot.
func test_the_filter_removes_most_of_the_dangle() -> void:
	for dist: float in [2.0, 5.0, 9.0]:
		var r: Dictionary = _dangle(0.0, dist, DANGLE_M, 3.0)
		var kept: float = 100.0 * (r["tracked_span"] as float) \
				/ maxf(r["raw_span"] as float, 0.0001)
		gut.p("carrier %.0f m | raw puck swings %.3f m, tracked threat swings %.3f m (%.0f%% kept)"
				% [dist, r["raw_span"], r["tracked_span"], kept])
		assert_lt(r["tracked_span"] as float, r["raw_span"] as float,
				"the filter is doing something at %.0f m" % dist)


# ── THE RECOVERY PROXIMITY STAY, sitting on a raw threshold ──────────────────
# `_is_threat_pressing` holds him down whenever the RAW puck is inside
# `recovery_proximity_threshold`. Park a carrier so the threat distance straddles
# it and the gate answers a different question every few frames — while the
# position he is holding is deliberately smoothed.
func test_the_recovery_stay_straddles_its_threshold_on_a_dangle() -> void:
	var edge: float = _ctrl.recovery_proximity_threshold
	var flips: int = 0
	gut.p("recovery_proximity_threshold %.2f m" % edge)
	for lane: float in [0.0, 1.5]:
		var dist: float = sqrt(maxf(edge * edge - lane * lane, 0.04))
		var still: Dictionary = _dangle(lane, dist, 0.0, 3.0)
		var moving: Dictionary = _dangle(lane, dist, DANGLE_M, 3.0)
		gut.p("  lane %.1f, %.2f m out (threat exactly on the edge) | still: %d stance changes | dangling: %d"
				% [lane, dist, still["flips"], moving["flips"]])
		assert_eq(still["flips"], 0,
				"control: a carrier standing still does not move his stance")
		flips += moving["flips"] as int
	assert_gt(flips, 0,
			"CHARACTERISATION: a stickhandle alone moves the stance at the raw threshold")


# ── THE POST-STANCE GATE ─────────────────────────────────────────────────────
# `is_puck_in_defensive_zone` is an ANGLE test on the raw puck, so its threshold
# moves fastest exactly where a walkout lives — close to the goal line, where a
# few centimetres of stickhandle is several degrees.
func test_the_post_stance_angle_gate_is_degrees_per_centimetre() -> void:
	var flips: int = 0
	gut.p("zone_post_z %.2f m, rvh_early_angle %.0f deg" % [
			_ctrl.zone_post_z, _ctrl.rvh_early_angle])
	for z: float in [0.30, 0.50, 0.80]:
		var edge_x: float = z * tan(deg_to_rad(_ctrl.rvh_early_angle))
		var swing: float = rad_to_deg(
				atan2(edge_x + DANGLE_M, z) - atan2(edge_x - DANGLE_M, z))
		gut.p("  %.2f m off the line | the %.0f deg gate sits at x %.2f | a %.2f m dangle swings it %.1f deg"
				% [z, _ctrl.rvh_early_angle, edge_x, DANGLE_M, swing])
		# The control matters here: a goalie parked at a sharp angle has other
		# reasons to change stance, and without the still-puck arm the flips
		# cannot be attributed to the dangle at all.
		var still: Dictionary = _dangle(edge_x, z, 0.0, 3.0)
		var moving: Dictionary = _dangle(edge_x, z, DANGLE_M, 3.0)
		gut.p("     -> still: %d stance changes | dangling: %d"
				% [still["flips"], moving["flips"]])
		assert_eq(still["flips"], 0,
				"control: a carrier standing still does not move his stance")
		flips += moving["flips"] as int
	assert_gt(flips, 0,
			"CHARACTERISATION: the angle gate is degrees per centimetre, on the unfiltered puck")
