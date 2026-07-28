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
