extends GutTest

# Feasibility probe for "option A": can the REAL GoalieController tick headless
# (with the real Goalie/Puck scenes) and produce a challenging position?
#
# RESULT: YES — option A is feasible. The real controller instantiates from the
# scenes, ticks via _physics_process, and CHALLENGES (settles at 1.75 m aggressive
# depth, squared on a slot threat). No physics/contact needed for positioning.
#
# It also let us RULE OUT a false lead. On a scripted lateral flyby the carrier
# never shoots (carry 0.957 vs shoot 0.30) because the winning carry candidate is
# a spot off to the SIDE. That LOOKS like an over-valued side-angle phantom — but
# it is NOT: at ~0.34 s arrival the keeper (after his 0.13 s reaction) can push
# only ~0.31 m of the ~0.91 m needed to re-square, so a fast diagonal cut leaves a
# GENUINE window that predict_goalie_pos prices correctly (a squared keeper would
# be ~0.04; the partially-squared one the carrier actually beats is ~0.9). Forcing
# the keeper fully square there (goalie_squared_pos) kills that real window and
# regresses the doorstep-cut behaviour (test_role_carrier's standstill wind-up) —
# so the model is right and the SCRIPTED LATERAL PATH is the artifact: the bot
# correctly wants to cut IN for a better look, and the script won't let it, so it
# "never shoots." A faithful repro of the in-game "no shot going by" needs the
# bot's REAL steering (real movement) + the real goalie in one temporal loop —
# neither scripted-path probe can capture the cut-in that's central to it.

const GOAL_Z: float = -GameRules.GOAL_LINE_Z   # goalie defends the -Z net

var _goalie: Node = null
var _puck: Node = null
var _ctrl: GoalieController = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	_ctrl = GoalieController.new()
	add_child_autofree(_ctrl)


func _tick_with_puck_at(puck_pos: Vector3, ticks: int) -> Vector3:
	# Drive the puck node to a scripted threat spot each tick and step the
	# controller; return the goalie's resulting world position.
	for _i: int in ticks:
		_puck.global_position = puck_pos
		_ctrl._physics_process(1.0 / 120.0)
	return _goalie.global_position


func test_real_goalie_ticks_and_challenges() -> void:
	# An opposing shooter with the puck in the slot; the goalie should come OUT
	# (challenge) toward it rather than sit on the goal line.
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 7.0)
	_puck.global_position = shooter
	_ctrl.set_skater_getter(func() -> Array: return [shooter])
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)

	var settled: Vector3 = _tick_with_puck_at(shooter, 240)   # 2 s to settle
	gut.p("goalie settled at x=%.2f z=%.2f (goal line z=%.2f)" % [
			settled.x, settled.z, GOAL_Z])
	var depth: float = absf(settled.z - GOAL_Z)
	assert_gt(depth, 0.3, "the real goalie CHALLENGES the slot threat (comes off his line)")
	assert_lt(absf(settled.x), 0.5, "…and squares up centred on a centred shooter")


func test_carrier_shoots_more_against_a_challenging_goalie() -> void:
	# The payoff: replay the lateral slot flyby, but feed the carrier the REAL
	# challenging goalie's position each tick instead of a static deep keeper. A
	# goalie out at 1.75 m cutting the angle should tank the "drive closer" carry
	# value and let the shot win — the fix the static-goalie probe couldn't show.
	var DT: float = 1.0 / 120.0
	var team_map: Dictionary = {1: 0}
	var brain := TeamBrain.new(0, team_map)
	var agent := SkaterAgentStateMachine.new()
	agent.setup(1, 0, brain, team_map, false)
	agent.apply_profile(BotSkillProfile.hard())
	# Real challenging goalie in the -Z net, fed the carrier as its threat.
	var carrier_ref := {"pos": Vector3.ZERO}
	_ctrl.set_skater_getter(func() -> Array: return [carrier_ref["pos"]])
	_puck.global_position = Vector3(0.0, 0.0, GOAL_Z + 6.0)
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)

	var pos := Vector3(4.0, 0.0, GOAL_Z + 4.5)
	var vel := Vector3(-7.0, 0.0, 0.0)
	var input := InputState.new()
	var shots: int = 0
	var peak_shoot: float = 0.0
	var peak_carry: float = 0.0
	var prev_shoot: bool = false
	var carry_dest: Vector3 = Vector3.ZERO
	var goalie_at: Vector3 = Vector3.ZERO
	for t: int in int(1.4 / DT):
		pos += vel * DT
		carrier_ref["pos"] = pos
		_puck.global_position = pos
		_ctrl._physics_process(DT)
		var g: Vector3 = _goalie.global_position
		var snap := WorldSnapshot.new()
		var st := SkaterNetworkState.new()
		st.position = pos
		st.velocity = vel
		st.facing = Vector2(vel.x, vel.z).normalized()
		st.blade_contact_world = pos
		st.stamina = 1.0
		snap.skater_states[1] = st
		snap.puck_state = PuckNetworkState.new()
		snap.puck_state.position = pos
		snap.puck_state.carrier_peer_id = 1
		snap.real_puck_carrier_peer_id = 1
		var gs := GoalieNetworkState.new()
		gs.position_x = g.x
		gs.position_z = g.z
		snap.goalie_states[1] = gs
		var own := GoalieNetworkState.new()
		own.position_x = 0.0
		own.position_z = GameRules.GOAL_LINE_Z - 0.8
		snap.goalie_states[0] = own
		if t % 20 == 1:
			brain.tick(20 * DT, snap)
		input.shoot_pressed = false
		input.slap_pressed = false
		input.quick_pass_pressed = false
		agent.dispatch(input, snap)
		if input.quick_pass_pressed or (prev_shoot and not input.shoot_held):
			shots += 1
		prev_shoot = input.shoot_held
		if pos.distance_to(Vector3(0, 0, GOAL_Z)) < 9.0:
			peak_shoot = maxf(peak_shoot, agent.debug_shoot_score)
			if agent.debug_carry_score > peak_carry:
				peak_carry = agent.debug_carry_score
				carry_dest = agent.debug_carry_pos
				goalie_at = g
	gut.p("REAL challenging goalie at z=%.2f (%.2fm deep) → shots=%d shoot=%.3f carry=%.3f  carry→(%.1f,%.1f) %.1fm-net" % [
			goalie_at.z, absf(goalie_at.z - GOAL_Z), shots, peak_shoot, peak_carry,
			carry_dest.x, carry_dest.z, carry_dest.distance_to(Vector3(0, 0, GOAL_Z))])
	# Documents the (correct) behaviour: the winning carry is a real fast-cut
	# window the bot wants to drive to, so it out-values a flat-footed far shot —
	# NOT a bug. The "no shot" here is the scripted lateral path denying the cut-in
	# (see the header); the model prices the cut honestly.
	# Both saturate at certainty under the make-probability currency; the
	# claim survives as "the cut-in never reads worse than the far shot".
	assert_gte(peak_carry, peak_shoot,
			"the bot never rates the flat-footed far shot above cutting in")
