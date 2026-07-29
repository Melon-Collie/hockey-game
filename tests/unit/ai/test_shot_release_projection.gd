extends GutTest

# Does the shot leave from where its aim was computed?
#
# The bot commits its shot DIRECTION at press entry:
#
#   _shoot_release_anchor = self_pos + velocity * BOT_WRISTER_LOOKAHEAD_S
#   release_pos           = _shoot_release_anchor + _shot_release_offset_locked
#   _shoot_aim_dir_locked = (aim_point - release_pos).normalized()
#
# — a straight-line, constant-velocity projection of where the body will be one
# charge later. The puck then actually leaves from the live blade, which
# _apply_wrister_aim_blade holds body-relative (skater.global_position + offset),
# so the release origin follows the body wherever it really goes.
#
# Direction is locked; origin is live. Any gap between the projected body and the
# real one would therefore SHIFT THE WHOLE SHOT LINE laterally, arriving at the
# net displaced by that gap — and because the aim sits in a goalie-hole window
# whose clean-entry inset already pushes it near a post, a couple of tenths of a
# metre sideways is the difference between a corner and a miss.
#
# Nothing tested it, and nothing could: the shot-outcome instruments
# (shot_sim_harness, real_goalie_shot_harness) both fire from a GIVEN release
# point, so a projection error is invisible to them by construction. This drives
# the real state machine and the real movement physics through a full press
# instead, and measures the gap.
#
# The answer is that the projection is HONEST — under 5 cm in every case,
# including through traffic and on a hard lateral cut, which are the two shapes
# a straight-line constant-velocity projection should struggle with most. The
# bot steers to its own locked anchor and arrives. These stay as a regression
# pin: they rule out release displacement as a source of wide misses, so a
# future investigation does not have to re-derive it.

const Harness := preload("res://tests/unit/ai/duel_harness.gd")

const SHOOTER := 1
const D1 := 11
const D2 := 12


class Probe:
	var fired: bool = false
	var blade: Vector3 = Vector3.ZERO
	var released_dir: Vector3 = Vector3.ZERO
	var assumed_release: Vector3 = Vector3.ZERO
	var aim_dir: Vector3 = Vector3.ZERO
	var aim_point: Vector3 = Vector3.INF
	var actual_body: Vector3 = Vector3.ZERO
	var projected_body: Vector3 = Vector3.ZERO
	var offset: Vector3 = Vector3.ZERO


# Runs a scenario until a shot is released; returns the probe (fired = false if
# the bot never shot within `seconds`).
func _measure(shooter_pos: Vector3, shooter_vel: Vector3,
		defenders: Array, seconds: float = 3.0) -> Probe:
	var h = Harness.new()
	h.add_skater(SHOOTER, 0, shooter_pos, null, shooter_vel)
	var did: int = D1
	for d: Vector3 in defenders:
		h.add_skater(did, 1, d)
		did += 1
	h.start(SHOOTER)
	var probe := Probe.new()
	var armed: bool = false
	var steps: int = int(seconds / Harness.DT)
	for _i: int in steps:
		var s = h._skater(SHOOTER)
		var agent = s.agent
		var held_before: bool = s.input.shoot_held
		h.step()
		if agent == null:
			continue
		# Re-capture on EVERY press. A bot can abort a charge (the mid-charge
		# bail when an opponent closes) and press again, so latching the first
		# press would measure one press's projection against a later press's
		# release. _shoot_charge_tick is 1 on the tick after the anchor is
		# locked, so that is the capture edge.
		if agent._shoot_charge_tick == 1:
			armed = true
			probe.offset = agent._shot_release_offset_locked
			probe.projected_body = agent._shoot_release_anchor
			probe.assumed_release = agent._shoot_release_anchor \
					+ agent._shot_release_offset_locked
			probe.aim_dir = agent._shoot_aim_dir_locked
			probe.aim_point = agent._shot_aim_locked
		# Release edge: the charge was held and has now dropped.
		if armed and held_before and not s.input.shoot_held:
			probe.actual_body = s.pos
			probe.blade = s.blade
			probe.released_dir = agent._shoot_aim_dir_locked
			probe.fired = true
			return probe
	return probe


# Lateral (perpendicular-to-aim) component of the projection gap — the part that
# actually displaces the shot at the net. The along-aim part only changes the
# range slightly.
func _lateral_gap(p: Probe) -> float:
	var gap: Vector3 = p.actual_body - p.projected_body
	gap.y = 0.0
	var perp := Vector3(p.aim_dir.z, 0.0, -p.aim_dir.x)
	return gap.dot(perp)


func _report(label: String, p: Probe) -> void:
	if not p.fired:
		gut.p("  %s: no shot released" % label)
		return
	var gap: Vector3 = p.actual_body - p.projected_body
	gap.y = 0.0
	gut.p("  %s: gap %.3f m (lateral %+.3f m), aim %s"
			% [label, gap.length(), _lateral_gap(p),
			"none" if not p.aim_point.is_finite() else "%.2f" % p.aim_point.x])


# ── Clean case: nobody near, straight drive ──────────────────────────────────

func test_projection_is_honest_with_nobody_around() -> void:
	# The design case: the bot steers to its own locked anchor with nothing
	# pulling it off. Measures ~1.5 cm lateral.
	var p: Probe = _measure(Vector3(0.0, 0.0, -12.0), Vector3(0.0, 0.0, -7.0), [])
	_report("clean drive", p)
	if not p.fired:
		pending("bot did not shoot in the clean fixture — scenario needs a rethink")
		return
	assert_lt(absf(_lateral_gap(p)), 0.15,
			"an unpressured shot leaves within 15 cm of its projected release")


# ── The case shots are actually taken in ─────────────────────────────────────

func test_traffic_displaces_the_release_the_aim_assumed() -> void:
	# The locked anchor is captured once and cannot see the steering that happens
	# during the charge, and _apply_steering carries opponent repulsion — so a
	# shot taken with bodies right there is where displacement should show up.
	# It does not: ~0.6 cm lateral. The charge is short enough (~125 ms) that
	# repulsion cannot move the body meaningfully within it.
	var p: Probe = _measure(Vector3(0.0, 0.0, -12.0), Vector3(0.0, 0.0, -7.0),
			[Vector3(1.6, 0.0, -14.0), Vector3(-1.8, 0.0, -15.0)])
	_report("through traffic", p)
	if not p.fired:
		pending("bot did not shoot in the traffic fixture")
		return
	# Bounded at what a corner window can absorb: the aim already sits a
	# puck+post radius (plus the tier's own spread) inside the pipe, so much more
	# than this and the shot is off the net rather than off the corner.
	assert_lt(absf(_lateral_gap(p)), 0.15,
			"a shot in traffic still leaves within 15 cm of its projected release")


func test_a_lateral_cut_keeps_its_release_line() -> void:
	# The model explicitly rewards the hard lateral cut in tight (it wins the
	# arc race against the goalie's push), so that is a shot the bot deliberately
	# seeks — and it is the worst case for a straight-line projection, because
	# the anchor is placed down the CURRENT velocity while the body is turning.
	# Measures ~4 cm lateral: the anchor being straight ahead makes the bot
	# finish the charge straight, so it lands on the spot it aimed from.
	var p: Probe = _measure(Vector3(-5.0, 0.0, -14.0), Vector3(6.5, 0.0, -2.0),
			[Vector3(-2.0, 0.0, -16.0)])
	_report("lateral cut", p)
	if not p.fired:
		pending("bot did not shoot in the cut fixture")
		return
	assert_lt(absf(_lateral_gap(p)), 0.15,
			"a cutting shooter still leaves within 15 cm of its projected release")


# ── Where the shot line actually crosses the goal ────────────────────────────
# The body projection above is honest, but the puck leaves from the BLADE, and
# the aim was computed against an assumed release. Live-game instrumentation
# measured that gap at 1.2-1.8 m whenever no release offset was committed (the
# blade freezes at the current carry pose), and showed a 0.16 m gap turning into
# a 0.64 m miss on a sharp-angle look, where the shot runs nearly parallel to the
# goal line and the crossing point is hypersensitive to release DEPTH.
#
# The release now re-derives its direction from the live blade to the locked aim
# point, so the line has to arrive where it was aimed regardless of either.

# Where the released line crosses the goal plane, fired from the real blade —
# the same solve the DEBUG_SHOT_RELEASE log prints.
func _crossing_x(p: Probe, goal_z: float) -> float:
	if absf(p.released_dir.z) < 0.001:
		return INF
	return p.blade.x + p.released_dir.x * ((goal_z - p.blade.z) / p.released_dir.z)


# Tolerance note: the harness models the blade as the cursor clamped to the
# reach ring and rate-limited, not the real ROM solve, so a couple of centimetres
# of blade disagreement is instrument error rather than model error — and the
# same lever that makes a sharp-angle shot sensitive to release depth amplifies
# it there too. The bound is set to admit that and nothing near the failure it
# replaces: the live log had these at 0.25-0.71 m, and 0.64 m on the sharp-angle
# shot this is derived from.
func _assert_lands_on_its_aim(label: String, p: Probe, aim: Vector3,
		tol: float = 0.05) -> void:
	var cross: float = _crossing_x(p, aim.z)
	gut.p("  %s: aim_x %+.3f, crossing %+.3f (miss %+.3f)"
			% [label, aim.x, cross, cross - aim.x])
	assert_lt(absf(cross - aim.x), tol,
			"%s: the released line crosses where it was aimed" % label)


func test_the_released_line_arrives_where_it_was_aimed() -> void:
	# Straight-on. The easy case, and the control for the two below.
	var p: Probe = _measure(Vector3(0.0, 0.0, -12.0), Vector3(0.0, 0.0, -7.0), [])
	if not p.fired or not p.aim_point.is_finite():
		pending("no shot with a locked aim in the head-on fixture")
		return
	_assert_lands_on_its_aim("head-on", p, p.aim_point)


func test_a_sharp_angle_shot_arrives_where_it_was_aimed() -> void:
	# The failure mode from the live log: out to the side with little depth left,
	# so the shot runs nearly parallel to the goal line. Here a small release
	# error used to swing the crossing point by half a metre or more.
	var p: Probe = _measure(Vector3(-6.5, 0.0, -22.0), Vector3(1.0, 0.0, -3.0),
			[Vector3(-3.0, 0.0, -24.0)])
	if not p.fired or not p.aim_point.is_finite():
		pending("no shot with a locked aim in the sharp-angle fixture")
		return
	_assert_lands_on_its_aim("sharp angle", p, p.aim_point, 0.08)


func test_a_doorstep_shot_arrives_where_it_was_aimed() -> void:
	# Short range beside the net — the other shape that went wide in the log
	# (several of the misses were inside 3 m).
	var p: Probe = _measure(Vector3(1.4, 0.0, -24.6), Vector3(0.5, 0.0, -2.0),
			[Vector3(-1.0, 0.0, -25.2)])
	if not p.fired or not p.aim_point.is_finite():
		pending("no shot with a locked aim in the doorstep fixture")
		return
	_assert_lands_on_its_aim("doorstep", p, p.aim_point)
