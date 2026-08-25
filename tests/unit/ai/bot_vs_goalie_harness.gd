extends RefCounted

# ── THE MISSING INSTRUMENT: a real bot shooting at the real goalie ───────────
# Nothing else in the suite measures this. The two halves each exist and have
# never been joined:
#
#   duel_harness            real bot decisions + real movement, but every
#                           release fires FLAT at a fixed 15 m/s along the mouse
#                           aim — the corner and the elevation the bot actually
#                           chose are discarded, so no shot it fires can be
#                           scored against a goalie.
#   real_goalie_shot_harness  the real goalie and the real collision (the
#                           GoalieContactDetector / GoalieSaveRules pair the
#                           host runs), but driven by a SCRIPTED shooter — there
#                           is no bot in it.
#
# So the sweeps say the keeper is a wall while the logged games say 61.4%, and
# nothing can reconcile them: the bot decides against `AIActionScoring`'s model
# of the goalie, the goalie plays as `GoalieController`, and no instrument
# compares their OUTCOMES. The balance is set by the gap between the two models
# rather than by either, and the gap is invisible.
#
# This joins them. The bot picks the shot; the real keeper tries to stop it.
#
# ── WHAT IS REAL ────────────────────────────────────────────────────────────
#   * the bot's decision to shoot, and WHICH shot — `best_shot_aim` /
#     `best_shot_loft` / the scorer's own release speed, read off the live
#     carrier role at the moment it fires
#   * its steering and pace into the release (duel_harness movement)
#   * the goalie: real GoalieController on the real Goalie.tscn, ticked once per
#     frame against the bot's actual puck position, so his depth, tracking,
#     stance and read pipeline all run
#   * THE WIND-UP the goalie reads: while the bot holds its charge the shooter
#     publishes `predicted_shot_velocity` for the aim it has chosen, so the
#     pre-lean, the quiet-eye prearm and the stale-sample read all engage. The
#     existing rush sims never publish one, so their keeper is always cold.
#   * the save itself: swept-OBB against his posed collision boxes, resolved
#     through GoalieSaveRules, with the rebound marched afterwards
#
# ── APPROXIMATION SCOPE, and it matters ─────────────────────────────────────
#   * ONE shot per run. The bot rushes, fires, the puck resolves, done. Nothing
#     here models the next possession.
#   * The release is RECONSTRUCTED, not executed: the shot's launch velocity is
#     built from the bot's own aim/loft/speed through the same ShotMechanics
#     path the live release uses, rather than driven through SkaterController's
#     shot state machine. So there is no blade sweep and no release pose — the
#     goalie sees an honest wind-up and an honest launch, but not an animated
#     one.
#   * No teammates and no traffic unless the caller adds them, so screens are
#     absent by default and this reads CLEAN-SIGHT conversion.
#
# Read the CONVERSION RATE per zone as the measurement, and compare it against
# tools/goalie_shot_events_audit.sql — the bands are deliberately the same, so
# the harness and the logged games are directly comparable for the first time.

const Duel := preload("res://tests/unit/ai/duel_harness.gd")
const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const DT: float = 1.0 / 120.0
const CARRIER: int = 1
const GOAL_Z: float = -GameRules.GOAL_LINE_Z   # the bot (team 0) attacks -Z

# Outcomes mirror the shot harness so callers can pool the two.
enum { GOAL, SAVE, POST, WIDE, NO_SHOT }

# Owned by the caller's test (add_child_autofree), handed in via setup().
var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null


func setup(goalie: Node, puck: Node, ctrl: GoalieController, shooter: Skater) -> void:
	_goalie = goalie
	_puck = puck
	_ctrl = ctrl
	_shooter = shooter
	_h = Harness.new()
	_h.setup(goalie, puck, ctrl, shooter)


# Distance and bearing of a release, in the bands the SQL audit uses so the two
# instruments line up. Angle is 0 dead centre, 90 on the goal line.
static func zone_of(release: Vector3) -> Dictionary:
	var dz: float = absf(release.z - GOAL_Z)
	var dist: float = sqrt(release.x * release.x + dz * dz)
	var angle: float = rad_to_deg(atan2(absf(release.x), maxf(dz, 0.0001)))
	var dband: String = "f. 15+ m"
	if dist < 3.0: dband = "a. 0-3 m"
	elif dist < 5.0: dband = "b. 3-5 m"
	elif dist < 7.0: dband = "c. 5-7 m"
	elif dist < 10.0: dband = "d. 7-10 m"
	elif dist < 15.0: dband = "e. 10-15 m"
	var aband: String = "d. 60-90 deg"
	if angle < 20.0: aband = "a. 0-20 deg"
	elif angle < 40.0: aband = "b. 20-40 deg"
	elif angle < 60.0: aband = "c. 40-60 deg"
	return {"dist": dist, "angle": angle, "dist_band": dband, "angle_band": aband}


# Run one rush and resolve the first SHOT the bot takes.
#
# Returns a record: `outcome` is the enum (NO_SHOT when it never fired), plus
# the release geometry, the shot the bot chose, the goalie's state at the
# release, and where the rebound ended up. `track_rebound` marches the real save
# response afterwards — the logged games say the 0-3 m band is largely second
# chances, so a conversion instrument that stops at first contact cannot see the
# thing that actually scores there.
func run_rush(start: Vector3, vel: Vector3, profile: BotSkillProfile,
		secs: float = 3.5, track_rebound: bool = true) -> Dictionary:
	var duel := Duel.new()
	duel.add_skater(CARRIER, 0, start, profile, vel)
	duel.start(CARRIER)
	# NO _ctrl.setup() here — setup() already wired it, and calling it again per
	# rush re-connects every signal it subscribes to.
	_shooter.global_position = start
	_shooter.velocity = vel
	_puck.set_carrier(_shooter)
	_puck.global_position = start
	_puck.pickup_locked = false
	_puck.motion_pinned = false
	# Drive the REAL goalie off the bot's live puck position, once per frame.
	# The shooter node rides the puck so the keeper reads a carrier threat and
	# comes out to challenge rather than playing it as a loose puck deep.
	duel.goalie_provider = func(team_id: int, puck_pos: Vector3) -> Variant:
		if team_id != 1:
			return null
		_shooter.global_position = puck_pos
		_shooter.velocity = duel._skater(CARRIER).vel \
				if duel._skater(CARRIER) != null else Vector3.ZERO
		_puck.global_position = puck_pos
		_publish_windup(duel)
		_ctrl._physics_process(DT)
		return _goalie.global_position

	var rec := {"outcome": NO_SHOT, "release": Vector3.INF, "aim": Vector3.INF,
			"loft": -1, "speed": 0.0, "intent": -1,
			"stance": -1, "unset": 0.0, "radius": 0.0,
			"rebound_goal": false, "rebound_held": false, "part": -1,
			"decision": ""}
	# LATCH THE DECISION, because `duel.step()` consumes the release inside the
	# same call: by the time a new entry appears in `releases` the bot has
	# already stopped carrying, its carrier role has moved on, and
	# `intended_action` reads CARRY again. What fired the shot is the decision
	# standing on the last tick it still had the puck.
	var l_intent: int = -1
	var l_aim: Vector3 = Vector3.INF
	var l_loft: int = -1
	var l_speed: float = 0.0
	var l_pos: Vector3 = start
	var l_stance: int = -1
	var l_unset: float = 0.0
	var l_radius: float = 0.0
	for _t: int in int(secs / DT):
		var before: int = duel.releases.size()
		duel.step()
		if duel.releases.size() <= before:
			var s0: Object = duel._skater(CARRIER)
			var c0: Object = s0.agent._carrier if s0 != null and s0.agent != null else null
			if duel.carrier_id == CARRIER and c0 != null:
				l_intent = c0.intended_action
				l_aim = c0.shot_aim_point
				l_loft = c0.shot_loft_level
				l_speed = c0._shot_sample_speed
				l_pos = s0.pos
				l_stance = _ctrl.stance()
				l_unset = _ctrl.unset_fraction()
				l_radius = _ctrl.challenge_radius()
			continue
		# GATE ON THE DECISION, NOT ON `intended_action`. The carrier role's
		# `intended_action` still reads CARRY on the tick it fires a shot — the
		# thing that says "I am shooting" is the dispatched decision, which the
		# duel already publishes on the release record. `shot_aim_point` and
		# `shot_loft_level` ARE populated correctly alongside it.
		var decision: String = str(duel.releases[-1].get("decision", ""))
		rec["decision"] = decision
		rec["intent"] = l_intent
		if decision != "SHOOT" or l_aim == Vector3.INF:
			return rec                               # a pass or a dump, not a shot
		rec["release"] = l_pos
		rec["aim"] = l_aim
		rec["loft"] = l_loft
		rec["speed"] = l_speed
		# The keeper's state belongs to the same instant as the release position,
		# so these are the latched ones too — reading them after the step samples
		# a goalie who has already ticked past the shot.
		rec["stance"] = l_stance
		rec["unset"] = l_unset
		rec["radius"] = l_radius
		# Fire it through the real release path so the keeper's read resolves
		# off the true shot, then march it against his posed collision.
		var o: int
		if track_rebound:
			o = _h.fire_tracking_rebound(l_pos, l_aim, l_loft, l_speed, 0.0)
			rec["rebound_goal"] = _h.rebound_goal
			rec["rebound_held"] = _h.rebound_held or _h.rebound_caught
		else:
			o = _h.fire_release_at(l_pos, l_aim, l_loft, l_speed, 0.0)
		rec["outcome"] = o
		rec["part"] = _h.last_part
		return rec
	return rec


# Publish the wind-up the goalie is supposed to be able to READ. While the bot
# holds its charge with a shot already chosen, the shooter advertises the shot
# that would fire right now — which is what feeds the pre-lean, the quiet-eye
# prearm and the stale-sample read. Without it the keeper meets every bot shot
# cold, which is the state the existing rush sims leave him in.
func _publish_windup(duel: RefCounted) -> void:
	var sk: Object = duel._skater(CARRIER)
	if sk == null or sk.agent == null:
		return
	var car: Object = sk.agent._carrier
	var holding: bool = sk.input.shoot_held or sk.input.slap_held
	if not holding or car == null or sk.agent.debug_last_decision != "SHOOT" \
			or car.shot_aim_point == Vector3.INF:
		_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
		_shooter.predicted_shot_velocity = Vector3.ZERO
		return
	_shooter.current_shot_state = SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK \
			if sk.input.slap_held else SkaterStateMachine.State.WRISTER_AIM
	_shooter.predicted_shot_velocity = _h.shot_velocity_at(
			sk.pos, car.shot_aim_point, car.shot_loft_level,
			car._shot_sample_speed, 0.0)
