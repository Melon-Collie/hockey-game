extends GutTest

# Flyby shot probe: scripts a carrier-with-puck skating PAST the net while the
# real SkaterAgentStateMachine (with its real decision throttle) decides each
# tick, and records whether/when a shot actually fires. Built to separate the
# user's report — "inconsistent getting a shot off in close, especially going
# by" — into the LAG (the carry→shoot compete only re-runs every
# dispatch_period_ticks) vs the MODEL (the shoot-vs-carry EV balance).
#
# FINDINGS (the prints are the deliverable; see the trailing asserts):
#   - NOT the lag. Hard runs the fastest dispatch, spends the WHOLE pass in
#     point-blank range, and still fires ~0 shots — because carry EV (~0.5-0.96)
#     dominates shoot EV (~0.25). Instant dispatch wouldn't change that.
#   - It's the shoot-vs-carry balance, and it's CONFOUNDED by the static goalie:
#     a keeper that sits at 0.8 m and never challenges makes "walk it in" read as
#     a free tap-in, so carry wins. Pressure (a backchecker) drops carry toward
#     shoot but doesn't flip it here.
#   - So a valid study of this decision needs the REAL goalie in a temporal loop
#     (option A). The static-goalie harness structurally can't produce the true
#     balance — the challenging goalie is exactly what makes the shot the play.

const Agent := preload("res://Scripts/ai/skater_agent_state_machine.gd")
const DT: float = 1.0 / 120.0
const CARRIER: int = 1

var _goal := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)   # team 0 attacks -Z


func _snapshot(pos: Vector3, vel: Vector3, facing: Vector2,
		defender: Vector3 = Vector3.INF) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	var st := SkaterNetworkState.new()
	st.position = pos
	st.velocity = vel
	st.facing = facing
	st.blade_contact_world = pos
	st.stamina = 1.0
	snap.skater_states[CARRIER] = st
	# Optional backchecker (team 1) applying pressure so the carry isn't free.
	if defender.is_finite():
		var d := SkaterNetworkState.new()
		d.position = defender
		d.velocity = vel   # keeping pace on the backcheck
		d.blade_contact_world = defender
		d.stamina = 1.0
		snap.skater_states[2] = d
	snap.puck_state = PuckNetworkState.new()
	snap.puck_state.position = pos
	snap.puck_state.carrier_peer_id = CARRIER
	snap.real_puck_carrier_peer_id = CARRIER
	for tid: int in [0, 1]:
		var g := GoalieNetworkState.new()
		g.position_x = 0.0
		g.position_z = (1.0 if tid == 0 else -1.0) * (GameRules.GOAL_LINE_Z - 0.8)
		snap.goalie_states[tid] = g
	return snap


# Run one scripted flyby. `facing_net` faces the goal (best case); else facing
# tracks velocity (the natural "going by" pose). Returns fire stats.
func _run_flyby(start: Vector3, vel: Vector3, ticks: int,
		profile: BotSkillProfile, facing_net: bool, pressure_gap: float = 0.0) -> Dictionary:
	var team_map: Dictionary = {CARRIER: 0, 2: 1}
	var brain := TeamBrain.new(0, team_map)
	var agent := Agent.new()
	agent.setup(CARRIER, 0, brain, team_map, false)
	if profile != null:
		agent.apply_profile(profile)
	var input := InputState.new()
	var pos: Vector3 = start
	var shots: int = 0
	var first: int = -1
	var in_slot_window: int = 0    # ticks the carrier spends within ~slot range
	var prev_shoot: bool = false
	var prev_slap: bool = false
	var peak_shoot: float = 0.0
	var peak_carry: float = 0.0
	var peak_pass: float = 0.0
	var states: Dictionary = {}
	var carry_dest: Vector3 = Vector3.ZERO
	var carry_from: Vector3 = Vector3.ZERO
	for t: int in ticks:
		pos += vel * DT
		var facing: Vector2
		if facing_net:
			var to_net := Vector2(_goal.x - pos.x, _goal.z - pos.z)
			facing = to_net.normalized() if to_net.length() > 0.001 else Vector2(0, -1)
		else:
			facing = Vector2(vel.x, vel.z).normalized() if vel.length() > 0.001 else Vector2(0, -1)
		var defender := Vector3.INF
		if pressure_gap > 0.0 and vel.length() > 0.001:
			defender = pos - vel.normalized() * pressure_gap   # backchecker on the tape
		var snap := _snapshot(pos, vel, facing, defender)
		if t % 20 == 1:
			brain.tick(20 * DT, snap)
		input.shoot_pressed = false
		input.slap_pressed = false
		input.quick_shot_pressed = false
		agent.dispatch(input, snap)
		var released: bool = input.quick_shot_pressed \
				or (prev_shoot and not input.shoot_held) \
				or (prev_slap and not input.slap_held)
		if released:
			shots += 1
			if first < 0:
				first = t
		prev_shoot = input.shoot_held
		prev_slap = input.slap_held
		if pos.distance_to(_goal) < 9.0:
			in_slot_window += 1
			peak_shoot = maxf(peak_shoot, agent.debug_shoot_score)
			if agent.debug_carry_score > peak_carry:
				peak_carry = agent.debug_carry_score
				carry_dest = agent.debug_carry_pos
				carry_from = pos
			peak_pass = maxf(peak_pass, agent.debug_pass_score)
			var sname: int = agent._state
			states[sname] = int(states.get(sname, 0)) + 1
	return {"shots": shots, "first": first, "slot_ticks": in_slot_window,
			"peak_shoot": peak_shoot, "peak_carry": peak_carry, "peak_pass": peak_pass,
			"states": states, "carry_dest": carry_dest, "carry_from": carry_from}


func test_flyby_shot_by_tier_and_facing() -> void:
	# A lateral flyby across the slot ~4.5 m out: from +4 to -4 at 7 m/s. The
	# carrier is in shot range for a stretch; does it get one off?
	var z: float = _goal.z + 4.5
	var start := Vector3(4.0, 0.0, z)
	var vel := Vector3(-7.0, 0.0, 0.0)
	var ticks: int = int(1.4 / DT)   # ~1.4 s to cross
	gut.p("── lateral flyby across the slot (+4→-4 @ 7 m/s, ~4.5 m out) ──")
	for pressure: float in [0.0, 1.6]:
		gut.p("  [backchecker gap = %.1f m]" % pressure if pressure > 0.0 else "  [unpressured]")
		for facing_net: bool in [true, false]:
			var tag: String = "face-NET " if facing_net else "face-VEL "
			for name: String in ["HARD", "NORMAL", "EASY"]:
				var p: BotSkillProfile = (BotSkillProfile.hard() if name == "HARD"
						else BotSkillProfile.normal() if name == "NORMAL"
						else BotSkillProfile.easy())
				var r: Dictionary = _run_flyby(start, vel, ticks, p, facing_net, pressure)
				var cd: Vector3 = r["carry_dest"]
				var cf: Vector3 = r["carry_from"]
				gut.p("    %s%-7s shots %d  shoot=%.3f carry=%.3f  carry→(%.1f,%.1f) %.1fm-from-net (from %.1fm)" % [
						tag, name, r["shots"], r["peak_shoot"], r["peak_carry"],
						cd.x, cd.z, cd.distance_to(_goal), cf.distance_to(_goal)])
	# What the probe establishes (see the file header):
	var free: Dictionary = _run_flyby(start, vel, ticks, BotSkillProfile.hard(), true, 0.0)
	var pressed: Dictionary = _run_flyby(start, vel, ticks, BotSkillProfile.hard(), true, 1.6)
	assert_gt(free["slot_ticks"], 0, "the carrier passes through point-blank shot range")
	# (1) NOT the lag: Hard's fast dispatch spends the whole pass in range and still
	# doesn't shoot, because carry EV dominates shoot EV.
	assert_gt(free["peak_carry"], free["peak_shoot"],
			"unpressured, carry EV dominates the point-blank shot — the bot walks it in")
	# (2) Pressure is what shifts it: a backchecker collapses the carry's value.
	assert_lt(pressed["peak_carry"], free["peak_carry"],
			"a backchecker drops the carry EV toward the shot")
	# (3) The static goalie is the confound: it never challenges, so 'walk it in'
	# reads as a free tap-in. A valid shoot-vs-carry study needs the REAL goalie in
	# the loop (option A) — this probe can't produce the true balance on its own.
