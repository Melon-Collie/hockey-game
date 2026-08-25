extends "res://tests/unit/ai/real_goalie_shot_harness.gd"

# ── THE HUMAN MOVE, in the shape its player describes ────────────────────────
# "Skate at the goalie to commit him to a butterfly, then skate around and wrap
# it around him." Every other live-goalie instrument here measures a SHOT. This
# one measures a SEQUENCE, because what beats him is not the release — it is
# where he is standing when it comes.
#
# The live log says that distinction is real. Human shots at a keeper who is
# DOWN inside 5 m, cut by his challenge radius at the release:
#
#     <0.55 m    60.5% SV        0.90-1.30   18.6% SV
#     0.55-0.90  24.1% SV        1.30-1.60    3.8% SV
#
# and the SAME cut while he is still UP is flat — 58.6 / 50.0 / 50.0. Depth
# costs him nothing on his feet and nearly everything off them, so the defect is
# dropping WHILE aggressive. An instrument that cannot see WHEN he dropped
# cannot see that at all, which is why neither `drive_in` nor `deke_across` can
# measure this move: both run for a caller-fixed duration, so the goalie's own
# decision never terminates anything and is never sampled.
#
# So this adds exactly two things over its parent:
#
#   THE DRIVE ENDS WHEN HE DECIDES. `bait_commit` marches the carrier in and
#   stops the tick he leaves his feet, so the walkaround starts from the real
#   commit moment rather than a guessed one.
#
#   THE COMMIT IS SAMPLED. `commit_radius` / `commit_x` / `commit_stance` /
#   `commit_dist` are read through the same public getters `GameManager
#   ._note_shot_context` logs (`challenge_radius`, `lateral_x`, `stance`), so a
#   conversion table cut on `commit_radius` is directly comparable to the SQL
#   above rather than merely analogous to it.
#
# Both phases share one capture path, so a keeper who stays up through the drive
# and only commits once the puck starts crossing is recorded as such
# (`commit_phase`) instead of reading as "never committed".

# Where he was when he left his feet. INF / -1 until a commit happens.
var commit_radius: float = INF     # his challenge radius from goal centre (m)
var commit_x: float = INF          # his lateral position (m)
var commit_stance: int = -1        # GoalieStateMachine.State he entered
var commit_dist: float = INF       # carrier's distance from goal centre (m)
var commit_phase: String = "never" # "drive" | "wrap" | "never"
var committed: bool = false
# Seconds from the start of the walkaround to the commit, when it happened
# there. INF if he was already down when the wrap began, or never went down.
var wrap_commit_s: float = INF
# Seconds into the walkaround at which he committed a SECOND slide, when
# `stop_on_recommit` cut the wrap there. INF if he never re-decided.
var recommit_s: float = INF

var _elapsed_s: float = 0.0
# Per-tick [seconds, stance, goalie x, challenge radius] through the walkaround,
# when `trace_enabled`. The stance history is the instrument's real payload for
# a diagnosis: an outcome table says he was beaten, and only the trace says
# whether he was beaten while sliding, while coiling, or while re-deciding.
var trace: Array = []
var trace_enabled: bool = false
# Aim the carrier is publishing, if the trigger is held. Carried from the bait
# into the wrap: a human who baits with the trigger down does not let go of it
# to skate around, and re-solving the declared velocity from each new body
# position is what keeps the published threat pointing at the net instead of at
# where the net was when the drive started.
var _declared_aim: Vector3 = Vector3.INF
var _declared_speed: float = 0.0


# Clear the commit capture. Call once per trial, before `bait_commit`.
func begin_trial() -> void:
	commit_radius = INF
	commit_x = INF
	commit_stance = -1
	commit_dist = INF
	commit_phase = "never"
	committed = false
	wrap_commit_s = INF
	_elapsed_s = 0.0
	trace = []
	_declared_aim = Vector3.INF
	_declared_speed = 0.0


# Sample the commit if this tick is the one he went down on. `carrier` is the
# body position, not the puck's: the radius bands in the live log are read
# against where the SHOOTER was, and the blade is up to a stick length off it.
func _note_commit(phase: String, carrier: Vector3) -> void:
	if committed or _ctrl._sm.is_upright():
		return
	committed = true
	commit_phase = phase
	commit_radius = _ctrl.challenge_radius()
	commit_x = _ctrl.lateral_x()
	commit_stance = _ctrl.stance()
	commit_dist = Vector2(carrier.x, carrier.z - _goal_z).length()
	if phase == "wrap":
		wrap_commit_s = _elapsed_s


# ── PHASE 1: BAIT THE COMMIT ─────────────────────────────────────────────────
# Straight down `lane_x` from `start_dist` metres of perpendicular depth,
# closing at `speed_m_s`, until he leaves his feet or the carrier reaches
# `floor_dist`.
#
# `declared_aim` other than Vector3.INF drives him with the trigger HELD — the
# carrier publishes `predicted_shot_velocity` the whole way in, which is the
# only thing on a straight drive the keeper can read as a shot threat. Left at
# INF the carry is cold. The distinction turns out to decide the whole scenario:
# measured, a cold drive never takes him off his feet at any speed or any depth,
# so the commit it baits is the one the WALKAROUND earns rather than one the
# drive did.
#
# `swing_x` non-zero pulls the puck ONCE across the body — from `+swing_x` to
# `-swing_x` over `swing_secs`, starting when the carrier reaches
# `swing_from_dist`, and held on the far side afterwards. That is the
# forehand-to-backhand the move sometimes carries, and it is deliberately a
# single beat rather than an oscillation: a repeating dangle commits him on
# whichever excursion happens to be wide when he is close enough, so the commit
# distance phase-locks to the period and stops being a controllable input.
#
# `swing_from_dist` is the instrument's control on WHERE he commits and the
# reason the pull is here at all. He goes down within a few ticks of the puck
# clearing his standing sealing reach, and his challenge radius at that moment
# tracks how far out the carrier still is — so pulling earlier is what produces
# a commit further out, which is the axis the whole scenario is cut on.
#
# Returns true if he committed during the drive. The caller continues into
# `wrap_around` either way: a keeper who holds his feet through the bait and
# only drops once the puck starts crossing is a different failure from one who
# never drops, and only running both phases can tell them apart.
func bait_commit(lane_x: float, start_dist: float, floor_dist: float,
		speed_m_s: float, swing_x: float = 0.0, swing_secs: float = 0.25,
		swing_from_dist: float = INF,
		declared_aim: Vector3 = Vector3.INF, shot_speed_m_s: float = 22.0) -> bool:
	var dir: float = signf(-_goal_z)
	var z: float = _goal_z + dir * start_dist
	var end_z: float = _goal_z + dir * floor_dist
	var vel := Vector3(0.0, 0.0, -dir * absf(speed_m_s))
	var winding: bool = declared_aim != Vector3.INF
	_declared_aim = declared_aim
	_declared_speed = shot_speed_m_s
	_shooter.current_shot_state = SkaterStateMachine.State.WRISTER_AIM if winding \
			else SkaterStateMachine.State.SKATING_WITH_PUCK
	_shooter.predicted_shot_velocity = Vector3.ZERO
	_puck.set_carrier(_shooter)
	var pos := Vector3(lane_x, 0.0, z)
	var swing_s: float = 0.0
	for _i: int in MAX_STEPS:
		_shooter.global_position = pos
		_shooter.velocity = vel
		if winding:
			_shooter.predicted_shot_velocity = shot_velocity_at(
					pos, declared_aim, 0, shot_speed_m_s, 0.0)
		if absf(pos.z - _goal_z) <= swing_from_dist:
			swing_s += DT
		var pull: float = clampf(swing_s / maxf(swing_secs, 0.0001), 0.0, 1.0)
		_puck.global_position = Vector3(
				pos.x + swing_x * (1.0 - 2.0 * pull), 0.0, pos.z)
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
		_elapsed_s += DT
		_note_commit("drive", pos)
		if committed:
			break
		if (pos.z - end_z) * dir <= 0.0:
			break
		pos.z += vel.z * DT
	_shooter.global_position = pos
	return committed


# ── PHASE 2: WALK AROUND HIM ─────────────────────────────────────────────────
# The body goes around too — this is not `sweep_across`'s puck-only pull. The
# carrier cuts laterally to `to_x` over `seconds` while still closing at
# `forward_speed`, with the blade carrying the puck `puck_lead_x` ahead of the
# body across the direction of travel.
#
# Forward pace is the caller's and should be well below the drive's: a wrap is
# bought out of the same legs as the lateral cut, and a carrier still closing at
# rush speed while crossing the crease face is skating through the goal line
# rather than around the keeper.
#
# Returns the PUCK's position — the release point, which is not the body's.
#
# `stop_on_recommit` ends the walkaround the tick he enters COILING again — a
# SECOND commit, decided while the puck was already going round him. That is the
# moment the live log says is his worst: COILING is 21.5% of this player's shots
# at 11.3% save percentage, and a coil is 0.12 s of a body that has decided to
# move and has not started. Firing there is the difference between measuring a
# keeper who is out of position and one who is mid-decision, and no fixed
# duration finds it, because when he re-decides depends on the whole move.
func wrap_around(to_x: float, seconds: float, forward_speed: float,
		puck_lead_x: float = 0.35, stop_on_recommit: bool = false) -> Vector3:
	_elapsed_s = 0.0
	var ticks: int = maxi(int(seconds / DT), 1)
	var dir: float = signf(-_goal_z)
	var body: Vector3 = _shooter.global_position
	var from_x: float = body.x
	var side: float = signf(to_x - from_x)
	var lateral_rate: float = (to_x - from_x) / maxf(seconds, 0.0001)
	var vel := Vector3(lateral_rate, 0.0, -dir * absf(forward_speed))
	var puck: Vector3 = _puck.global_position
	# THE PUCK DOES NOT TELEPORT ONTO THE NEW BLADE SIDE. The bait leaves it
	# wherever the pull ended — often a metre and a half from where `puck_lead_x`
	# would put it — so writing the target lead on the first wrap tick moves it
	# there in one frame. The goalie differentiates the puck's position for his
	# velocity estimate and his lateral read, so that single frame hands him a
	# lateral speed no stick can produce and re-arms the beaten-wide verdict off
	# an artefact. The lead eases from whatever it actually is.
	var lead_from: float = puck.x - body.x
	# Whether he was ALREADY coiling as the walkaround opened. Without it the
	# bait's own commit — which is a coil the tick before this starts — reads as
	# the re-decision `stop_on_recommit` is looking for, and the wrap ends before
	# the carrier has moved at all.
	var was_coiling: int = \
			1 if _ctrl.stance() == GoalieStateMachine.State.COILING else 0
	recommit_s = INF
	for i: int in ticks:
		var t: float = float(i + 1) / float(ticks)
		body.x = lerpf(from_x, to_x, t)
		body.z += vel.z * DT
		_shooter.global_position = body
		_shooter.velocity = vel
		if _declared_aim != Vector3.INF:
			_shooter.predicted_shot_velocity = shot_velocity_at(
					body, _declared_aim, 0, _declared_speed, 0.0)
		puck = Vector3(
				body.x + lerpf(lead_from, side * puck_lead_x, t), 0.0, body.z)
		_puck.global_position = puck
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
		_elapsed_s += DT
		_note_commit("wrap", body)
		if trace_enabled:
			trace.append([_elapsed_s, _ctrl.stance(), _ctrl.lateral_x(),
					_ctrl.challenge_radius()])
		var st: int = _ctrl.stance()
		if stop_on_recommit and st == GoalieStateMachine.State.COILING \
				and was_coiling != 1:
			recommit_s = _elapsed_s
			return puck
		was_coiling = 1 if st == GoalieStateMachine.State.COILING else 0
	return puck


# ── PHASE 2, AIMED AT A FIXED SPOT ──────────────────────────────────────────
# Same walkaround, but the caller names WHERE the carrier ends up rather than
# how fast he travels: a straight skate from wherever the commit left him to
# (`target_x`, `target_dist` metres out), at `speed_m_s`.
#
# This is the controlled form, and the whole point of it is that the RELEASE
# POINT stops being an output. Baiting the commit from further out also starts
# the walkaround from further out, so a `wrap_around` at fixed rates ends
# somewhere different for every commit radius — and then a conversion table cut
# on the radius is really a table cut on shot geometry, which is the confound
# the live log cannot rule out either. Holding the release fixed makes the
# radius the only thing that varies.
#
# What it deliberately does NOT hold fixed is the DURATION: at a constant
# skating speed a commit further out is a longer skate, so the keeper gets more
# time to recover from it. That is not a flaw in the control, it is the other
# half of the effect — committing further out is committing EARLIER — and the
# claim under test is the net of the two.
func wrap_to(target_x: float, target_dist: float, speed_m_s: float,
		puck_lead_x: float = 0.35) -> Vector3:
	var dir: float = signf(-_goal_z)
	var body: Vector3 = _shooter.global_position
	# A commit that came LATE can leave him already inside the release depth, and
	# `wrap_around` only ever closes — so the walkaround there is purely lateral
	# rather than a skate back out that no player makes.
	var here: float = absf(body.z - _goal_z)
	var target_z: float = _goal_z + dir * minf(target_dist, here)
	var span: float = Vector2(target_x - body.x, target_z - body.z).length()
	var seconds: float = span / maxf(absf(speed_m_s), 0.01)
	var forward: float = absf(target_z - body.z) / maxf(seconds, 0.0001)
	return wrap_around(target_x, seconds, forward, puck_lead_x)


# The keeper's situation right now, through the same getters `GameManager
# ._note_shot_context` logs at every real release. Call it on the release tick
# so a harness table and a `shot_events` row mean the same thing.
func release_ctx() -> Dictionary:
	return {
		"stance": _ctrl.stance(),
		"unset": _ctrl.unset_fraction(),
		"radius": _ctrl.challenge_radius(),
		"x": _ctrl.lateral_x(),
		"down": not _ctrl._sm.is_upright(),
	}


# The open net as the shooter can see it from `from_pos`: the net-plane x, one
# puck radius inside the post, on the side of the keeper with more room. This is
# the aim a wraparound actually takes — you shoot at the space he is not in —
# and deriving it from his live lateral position rather than fixing it per trial
# keeps the instrument from crediting a shooter who guessed.
func open_side_aim(from_pos: Vector3, height: float = 0.10) -> Vector3:
	var post: float = GameRules.NET_HALF_WIDTH - RADIUS
	var gx: float = _ctrl.lateral_x()
	var side: float = 1.0 if (post - gx) >= (gx + post) else -1.0
	# Off-angle enough that the near post is unreachable makes the FAR side the
	# only net left, whatever the keeper's x says.
	if absf(from_pos.x) > post and signf(from_pos.x) == side:
		side = -side
	return Vector3(side * post, height, _goal_z)
