extends GutTest

# THE faithful 1v1 sim: a real bot (SkaterAgentStateMachine + real movement, via
# the duel harness) rushes the net STEERING ITSELF, against the REAL
# GoalieController (option A) that CHALLENGES it (fed a real carrier Skater so it
# reads a shooter threat) — one temporal loop. Pins the user's MUST-HAVE: a clean
# 1v1 (no traffic, no closing defenders) has to produce a SHOT ATTEMPT from every
# angle of attack. A run that skates past without a shot is the bug.

const Duel := preload("res://tests/unit/ai/duel_harness.gd")
const DT: float = 1.0 / 120.0
const CARRIER: int = 1


# Run a 1v1 rush from `start` with initial `vel` toward the net; return stats.
# Fresh nodes per call so the goalie state doesn't bleed between angles.
func _run_rush(start: Vector3, vel: Vector3, secs: float = 3.0,
		trace: bool = false, profile: BotSkillProfile = null,
		backcheck_gap: float = 0.0) -> Dictionary:
	if profile == null:
		profile = BotSkillProfile.hard()
	var goal_z: float = -GameRules.GOAL_LINE_Z          # carrier (team 0) attacks -Z
	var net := Vector3(0.0, 0.0, goal_z)
	var goalie: Node = load("res://Scenes/Goalie.tscn").instantiate()
	var puck: Node = load("res://Scenes/Puck.tscn").instantiate()
	var carrier_actor: Node = load("res://Scenes/Skater.tscn").instantiate()
	var ctrl := GoalieController.new()
	add_child_autofree(goalie)
	add_child_autofree(puck)
	add_child_autofree(carrier_actor)
	add_child_autofree(ctrl)

	var duel := Duel.new()
	duel.add_skater(CARRIER, 0, start, profile, vel)
	# Optional real-AI backchecker (team 1) trailing the carrier by `backcheck_gap`
	# along its line — close enough to pressure the compete, starting behind at
	# matched speed so it can't strip unless the carrier dithers.
	if backcheck_gap > 0.0 and vel.length() > 0.001:
		duel.add_skater(2, 1, start - vel.normalized() * backcheck_gap,
				BotSkillProfile.hard(), vel)
	duel.start(CARRIER)

	# A real carrier Skater on the puck → the goalie reads a shooter threat and
	# comes out to challenge (without it, it plays the loose puck deep).
	carrier_actor.global_position = start
	puck.set_carrier(carrier_actor)
	puck.global_position = start
	ctrl.set_skater_getter(func() -> Array: return [])   # no crease-jam scan in a 1v1
	ctrl.setup(goalie, puck, goal_z, true)
	duel.goalie_provider = func(team_id: int, puck_pos: Vector3) -> Variant:
		if team_id != 1:
			return null
		carrier_actor.global_position = puck_pos
		puck.global_position = puck_pos
		ctrl._physics_process(DT)
		return goalie.global_position

	var shots: int = 0
	var crease_shots: int = 0     # shots fired from INSIDE the crease (illegitimate)
	var legit_shots: int = 0      # shots fired from outside the crease (real attempts)
	var min_dist: float = 999.0
	var first_shot_dist: float = -1.0
	if trace:
		gut.p("  t(s)  carrier(x,z) dist  shootEV carryEV  goalie(x,z) depth  shots")
	for t: int in int(secs / DT):
		var before: int = duel.releases.size()
		duel.step()
		var sk: Object = duel._skater(CARRIER)
		if duel.releases.size() > before:
			var n: int = duel.releases.size() - before
			shots += n
			var origin := Vector2(sk.pos.x, sk.pos.z)
			if CreaseRules.is_in_crease(origin):
				crease_shots += n
			else:
				legit_shots += n
			if first_shot_dist < 0.0:
				first_shot_dist = sk.pos.distance_to(net)
		min_dist = minf(min_dist, sk.pos.distance_to(net))
		if trace and t % 24 == 0:
			var g: Vector3 = goalie.global_position
			gut.p("  %.2f  (%5.1f,%5.1f) %4.1f  %6.3f %6.3f  (%5.2f,%6.2f) %.2f  %d" % [
					t * DT, sk.pos.x, sk.pos.z, sk.pos.distance_to(net),
					sk.agent.debug_shoot_score, sk.agent.debug_carry_score,
					g.x, g.z, absf(g.z - goal_z), shots])
	return {"shots": shots, "legit": legit_shots, "crease": crease_shots,
			"min_dist": min_dist, "first_dist": first_shot_dist}


func test_straight_1v1_produces_a_shot() -> void:
	# Sanity + trace: a centred rush against the challenging goalie must shoot.
	var goal_z: float = -GameRules.GOAL_LINE_Z
	gut.p("── 1v1 straight rush (traced) ──")
	var r: Dictionary = _run_rush(
			Vector3(0.0, 0.0, goal_z + 10.0), Vector3(0.0, 0.0, -5.0), 3.0, true)
	assert_gt(r["shots"], 0, "a clean centred 1v1 must produce a shot attempt")


func test_every_angle_of_attack_produces_a_shot() -> void:
	# THE spec: a clean 1v1 from EVERY angle of attack must produce a shot
	# attempt. Skating past without a shot is unacceptable (traffic / closing
	# defenders would be a different scenario — there are none here). Any angle
	# with shots=0 is the bug this pins.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var radius: float = 11.0
	var speed: float = 5.0
	var missed: Array = []
	for tier: String in ["HARD", "NORMAL", "EASY"]:
		var prof: BotSkillProfile = (BotSkillProfile.hard() if tier == "HARD"
				else BotSkillProfile.normal() if tier == "NORMAL"
				else BotSkillProfile.easy())
		gut.p("── 1v1 shot-attempt sweep by approach angle — %s ──" % tier)
		for deg: float in [-85.0, -75.0, -60.0, -45.0, -25.0, 0.0, 25.0, 45.0, 60.0, 75.0, 85.0]:
			var a: float = deg_to_rad(deg)
			var start: Vector3 = net + Vector3(sin(a), 0.0, cos(a)) * radius
			var vel: Vector3 = (net - start).normalized() * speed
			var r: Dictionary = _run_rush(start, vel, 3.5, false, prof)
			gut.p("  %-6s angle %+5.0f°  →  legit=%d crease=%d  first-shot@%.1fm  min-dist=%.1f" % [
					tier, deg, r["legit"], r["crease"], r["first_dist"], r["min_dist"]])
			# Must-have: a shot ATTEMPT (crease shots are allowed — only a really-
			# close on-the-goalie shot would be a problem, surfaced by first-shot@).
			if r["shots"] <= 0:
				missed.append("%s@%+.0f" % [tier, deg])
	assert_eq(missed.size(), 0,
			"every clean 1v1 angle (all tiers) must produce a shot attempt; missed: %s" % str(missed))


# Cells of the pressured sweep below where an ANGLED pressurer takes the look
# away entirely. Pinned exactly, not budgeted — see the note at the assertion.
#
# EASY@-25 LEFT THIS LIST when the goalie stopped low-passing the carrier's body
# (Scripts/controllers/CLAUDE.md → "Filter the puck, not the man"). The bot now
# releases there from 4.0 m instead of skating past, which is the direction this
# test exists to protect — it was written for bots being paralysed under
# pressure, not for them shooting too much.
#
# Read it as a MARGINAL cell rather than a settled one. It moved on a change to
# where the keeper stands, so it sits near the compete's decision boundary and
# will move again on the next one. The load-bearing halves are the HARD
# assertion below (untouched, all seven angles) and the mirrored +25/-25 pair
# still being taken away at the two lower tiers.
const PRESSURED_ANGLED_NO_SHOT_CELLS: Array = ["EASY@+25", "NORMAL@-25"]


func test_pressured_1v1_with_backchecker_still_shoots() -> void:
	# The realistic case: a backchecker trailing ~2 m (pressure, but can't strip a
	# carrier at speed). The pressure should make the bot release QUICKLY — it must
	# still get a shot attempt from every angle, not dither and skate past. This is
	# the scenario most like the in-game report; a miss here is the bug.
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var radius: float = 11.0
	var speed: float = 5.5
	var gap: float = 2.0
	var missed: Array = []
	for tier: String in ["HARD", "NORMAL", "EASY"]:
		var prof: BotSkillProfile = (BotSkillProfile.hard() if tier == "HARD"
				else BotSkillProfile.normal() if tier == "NORMAL"
				else BotSkillProfile.easy())
		gut.p("── pressured 1v1 (backchecker @%.1fm) — %s ──" % [gap, tier])
		for deg: float in [-75.0, -45.0, -25.0, 0.0, 25.0, 45.0, 75.0]:
			var a: float = deg_to_rad(deg)
			var start: Vector3 = net + Vector3(sin(a), 0.0, cos(a)) * radius
			var vel: Vector3 = (net - start).normalized() * speed
			var r: Dictionary = _run_rush(start, vel, 3.5, false, prof, gap)
			gut.p("  %-6s angle %+5.0f°  →  shots=%d (legit=%d crease=%d)  first@%.1fm min-dist=%.1f" % [
					tier, deg, r["shots"], r["legit"], r["crease"], r["first_dist"], r["min_dist"]])
			if r["shots"] <= 0:
				missed.append("%s@%+.0f" % [tier, deg])
	# The bug this originally fixed: under backchecker pressure the bot failed to
	# get a shot off at sharp/off-centre angles and skated past. The momentum-aware
	# time_to_arrive makes it release from range instead.
	#
	# It no longer asserts a shot from EVERY cell, because the defender changed.
	# The pressurer used to hold the gap ladder's DISTANCE with no bearing doctrine
	# at all — it stood wherever the argmax said deflated the carrier's options
	# most, which is a defender offering the inside and outside lanes equally.
	# It now angles him off the middle (AIRoleHelpers.carrier_stand), and a
	# defender who has genuinely taken the inside lane is entitled to take the
	# look with it. Measured: the pressurer concedes 1.2 m less of his own ice in
	# the worst case (closest approach to our net 8.2 m -> 9.4 m, deep starts
	# 5% -> 0%) and the cost is the three cells below.
	#
	# So the spec splits in two, and BOTH halves have to hold:
	#
	#   HARD is untouched — the look is still there, and the tier with the
	#   precision to take it does, from every angle. That is what says the play
	#   exists and the bot is not paralysed.
	#
	#   The lower tiers' misses are PINNED EXACTLY rather than given a budget, so
	#   this fails in both directions: angling that starts eating more looks fails
	#   here, and angling that stops working fails here too. Re-pin only with the
	#   measurement that justifies the new list.
	#
	# The absolute "never skate past" guard is unaffected and lives in
	# test_every_angle_of_attack_produces_a_shot, which has no defender in it —
	# with nobody to take the lane away, all 21 cells must still shoot, and do.
	var hard_missed: Array = []
	for cell: String in missed:
		if cell.begins_with("HARD"):
			hard_missed.append(cell)
	assert_eq(hard_missed, [] as Array,
			"HARD must beat an angled pressurer from every angle; missed: %s"
			% str(hard_missed))
	missed.sort()
	assert_eq(missed, PRESSURED_ANGLED_NO_SHOT_CELLS,
			"the looks an angled pressurer takes away have moved; got %s, pinned %s"
			% [str(missed), str(PRESSURED_ANGLED_NO_SHOT_CELLS)])


func test_going_by_the_net_still_produces_a_shot() -> void:
	# The user's concrete case: the carrier moving LATERALLY across the top of the
	# slot ("skating sideways toward the side") rather than driving at the net. A
	# clean 1v1 like this must STILL produce a shot — cut in and fire, don't skate
	# past. These are the runs most likely to expose the bug.
	var goal_z: float = -GameRules.GOAL_LINE_Z
	gut.p("── 1v1 'going by' sweep (lateral entry) ──")
	var cases: Array = [
		["cross-slot L→R  4.5m", Vector3(-6.0, 0.0, goal_z + 4.5), Vector3(6.0, 0.0, 0.0)],
		["cross-slot R→L  4.5m", Vector3(6.0, 0.0, goal_z + 4.5), Vector3(-6.0, 0.0, 0.0)],
		["cross-high     7.0m",  Vector3(-6.0, 0.0, goal_z + 7.0), Vector3(6.0, 0.0, 0.0)],
		["wall drive→by  L",     Vector3(-8.0, 0.0, goal_z + 9.0), Vector3(3.0, 0.0, -5.0)],
		["wall drive→by  R",     Vector3(8.0, 0.0, goal_z + 9.0),  Vector3(-3.0, 0.0, -5.0)],
	]
	var missed: Array = []
	for c: Array in cases:
		var r: Dictionary = _run_rush(c[1], c[2], 3.5, false)
		gut.p("  %-22s legit=%d crease=%d  first-shot@%.1fm  min-dist=%.1f" % [
				c[0], r["legit"], r["crease"], r["first_dist"], r["min_dist"]])
		if r["shots"] <= 0:
			missed.append(c[0])
	assert_eq(missed.size(), 0,
			"a lateral 'going by' 1v1 must still produce a shot attempt; missed: %s" % str(missed))
