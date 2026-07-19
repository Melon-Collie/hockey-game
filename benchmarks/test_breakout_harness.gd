extends GutTest

# ── Breakout scenario harness (report-only; NOT in the default suite) ────────
# The Phase D measurement instrument (docs/breakout-plan.md): 5v5 retrievals
# against the live forecheck on the real decision stack (the duel harness's
# 120 Hz movement + agents + brains), classified per trial:
#
#   clean-exit — the puck crosses our blue line with OUR carrier on it
#   clear-exit — the puck leaves the zone uncontrolled (a rim/chip out —
#                far better than a cough, not yet a controlled breakout)
#   cough-up   — an opponent becomes the carrier while the puck is still in
#                our zone (includes losing the initial retrieval race)
#   timeout    — still bottled after LIMIT_S
#
# STAGING HONESTY (v2): every trial begins as live play — the opponents
# CARRY through a short warmup (their cycle or their NZ entry), so both
# teams settle into ORGANIC shapes with real velocities before the trigger
# event (a forced turnover / dump) puts the puck loose. Hand-placed frozen
# poses biased v1: still skaters can't express the wheel's has-a-step
# trigger, and pre-contested races suppress RETRIEVAL by construction.
# Trials are jittered deterministically (PlayerRules.stagger01) for sample
# size without RNG.
#
# REAL DUMP FLIGHTS (v3): dump trials fire the puck from the warm carrier's
# live position at trigger instead of teleporting it deep. The teleport gave
# the forecheck a free head start equal to the dump's whole flight time —
# the chaser-path trace showed our retriever charging honestly at full
# stride and still losing every behind-net race, because the defense never
# got the retreat window a real dump concedes. With flight restored, the
# rim wraps the corner arc off the real board model and the retrieval race
# is the one the live game actually plays.
#
# Each trial also records a TRACE: whether RETRIEVAL engaged, the first
# touch, and the first team-0 release with its intent + compete scores
# (from the duel harness's enriched release records) and its fate — the
# causal story behind the outcome label, and the raw material for the
# pass-model calibration probe.
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks "-gselect=breakout"
#
# Report-only by design: the before/after instrument for the breakout
# phases; the only assertions are that the trials ran.

const Duel := preload("res://tests/unit/ai/duel_harness.gd")

const LIMIT_S: float = 12.0
const STEP_S: float = 0.1
const WARMUP_S: float = 1.2
const JITTERS: int = 5
# Per-jitter warmup stagger: without it the warmup (and so the trigger
# pose) is IDENTICAL across a scenario's jitters — only the scripted aim
# varied, so "n trials" was closer to n/3 independent samples. A ±ladder
# around the base warmup dislodges the whole pose.
const WARMUP_JITTER_S: float = 0.12
# Post-launch re-catch lockout for scripted dumps (see the launch-grace
# comment in _run_trial) — roughly the rim's flight to the corner.
const SCRIPTED_DUMP_GRACE_S: float = 1.0

var _rows: Array[Dictionary] = []
# Calibration probe v1: every team-0 release's scored pass EV paired with its
# realized fate (completed to us / died) — the measured completion curve the
# pass-lane recalibration will be derived from (the #27 method). Thin at 18
# trials; grows with the trial matrix.
var _probe: Array[Dictionary] = []


# Both rosters in seed spots for the warmup genesis; the warmup itself
# settles them into organic shapes. Team 0 defends +Z.
func _add_rosters(duel: RefCounted, mirror: float) -> void:
	duel.add_skater(10001, 0, Vector3(1.5 * mirror, 0, 18.0))    # C
	duel.add_skater(10002, 0, Vector3(-7.0 * mirror, 0, 15.0))   # LW
	duel.add_skater(10003, 0, Vector3(7.0 * mirror, 0, 15.0))    # RW
	duel.add_skater(10004, 0, Vector3(-3.5 * mirror, 0, 22.0))   # LD
	duel.add_skater(10005, 0, Vector3(3.5 * mirror, 0, 22.0))    # RD
	duel.add_skater(10011, 1, Vector3(0.0, 0, 6.0))              # C
	duel.add_skater(10012, 1, Vector3(-8.0 * mirror, 0, 12.0))   # LW
	duel.add_skater(10013, 1, Vector3(9.0 * mirror, 0, 14.0))    # RW
	duel.add_skater(10014, 1, Vector3(-4.0 * mirror, 0, 3.0))    # LD
	duel.add_skater(10015, 1, Vector3(4.0 * mirror, 0, 3.0))     # RD
	duel.team_size = 5
	duel.positions = {
		10001: 0, 10002: 1, 10003: 2, 10004: 3, 10005: 4,
		10011: 0, 10012: 1, 10013: 2, 10014: 3, 10015: 4,
	}


# ±spread jitter from the deterministic spatial hash (seeded per trial).
func _jit(trial: int, salt: int, spread: float) -> float:
	return (PlayerRules.stagger01(trial, salt) * 2.0 - 1.0) * spread


func _run_trial(scenario: String, mirror: float, jitter: int,
		warm_carrier: int, warm_carrier_pos: Vector3,
		puck: Vector3, puck_vel: Vector3, dump_speed: float = 0.0,
		chip_hang_s: float = 0.0, opts: Dictionary = {}) -> void:
	var duel: RefCounted = Duel.new()
	_add_rosters(duel, mirror)
	# Seed the warmup possession: the opponents play LIVE (their cycle /
	# their entry) while our five settle into the brain's own shape.
	# opts.warm_vel seeds carrier momentum and opts.warmup_s shortens the
	# settle — a wall carrier given a long warmup can (correctly!) decide
	# the entry is bad and regroup to his own end, and then the scripted
	# dump fires from a spot that no longer matches the scenario.
	var wc: RefCounted = null
	for s: RefCounted in duel.skaters:
		if s.peer_id == warm_carrier:
			wc = s
	wc.pos = Vector3(warm_carrier_pos.x * mirror, 0, warm_carrier_pos.z)
	wc.blade = wc.pos
	wc.prev_blade = wc.pos
	var warm_vel: Vector3 = opts.get("warm_vel", Vector3.ZERO)
	wc.vel = Vector3(warm_vel.x * mirror, 0, warm_vel.z)
	duel.start(warm_carrier)
	# Warm up tick-by-tick, cutting to the trigger the moment the carrier
	# moves the puck himself — his release IS the dump moment (we script
	# its target, not its timing). Running the full fixed warmup past a
	# release fired the scripted dump from a mid-flight pass metres behind
	# him, straight past his own (ungraced) stick. The per-jitter warmup
	# stagger dislodges the whole trigger pose between jitters.
	var warm_base: float = float(opts.get("warmup_s", WARMUP_S))
	var warm_s: float = maxf(0.2,
			warm_base + _jit(jitter, 37, WARMUP_JITTER_S))
	var warm_ticks: int = int(warm_s / Duel.DT)
	for _i: int in warm_ticks:
		duel.step()
		if duel.carrier_id != warm_carrier:
			break
	# The trigger event puts the puck loose, jittered (aim + the staggered
	# warmup above) so trials sample the neighborhood, not one frozen pose.
	# Two forms:
	#   dump_speed > 0 — a REAL dump: fired from the puck's live position
	#     toward the (jittered) aim point, so the flight time is the
	#     defense's honest retreat window and the rim wraps the corner arc
	#     off the board model. chip_hang_s > 0 lofts it instead: airborne
	#     (untouchable) for the hang, ground speed solved to land ON the aim
	#     point — the over-the-traffic dump a flat 2D fire can't stage.
	#   dump_speed == 0 — a local squirt (strip / bobble): the puck
	#     teleports to the jittered spot with the given velocity.
	duel.carrier_id = -1
	if dump_speed > 0.0 or chip_hang_s > 0.0:
		var aim := Vector3(
				(puck.x + _jit(jitter, 11, 1.5)) * mirror, 0,
				puck.z + _jit(jitter, 23, 1.5))
		var dir: Vector3 = aim - duel.puck_pos
		dir.y = 0.0
		if chip_hang_s > 0.0:
			duel.puck_vel = dir / chip_hang_s
			duel.airborne_ticks = int(chip_hang_s / Duel.DT)
		else:
			duel.puck_vel = dir.normalized() * dump_speed
		# Launch grace for every opponent near the release point — the
		# dumper and his point-blank support. Without it a trigger landing
		# mid-warmup-pass fired the "dump" straight into the intended
		# receiver's blade one tick later, and a wall dumper sprinting in
		# his own rim's wake re-caught it the tick the production-length
		# grace expired (his brain never CHOSE the dump, so the loose puck
		# reads as a gift a stride away). The scripted launch gets a grace
		# covering the flight to the corner: dump-and-chase pressures the
		# RETRIEVER, it doesn't re-possess mid-flight.
		for s: RefCounted in duel.skaters:
			if s.team_id == 1 and Vector2(s.pos.x - duel.puck_pos.x,
					s.pos.z - duel.puck_pos.z).length() < 4.0:
				duel._release_grace[s.peer_id] = duel.ticks \
						+ int(SCRIPTED_DUMP_GRACE_S / Duel.DT)
	else:
		duel.puck_pos = Vector3(
				(puck.x + _jit(jitter, 11, 1.5)) * mirror, 0,
				puck.z + _jit(jitter, 23, 1.5))
		duel.puck_vel = Vector3(puck_vel.x * mirror, 0, puck_vel.z)
	var releases_before: int = duel.releases.size()

	var t: float = 0.0
	var outcome: String = "timeout"
	var retrieval_seen: bool = false
	var first_touch_peer: int = -1
	var first_touch_t: float = -1.0
	var intercept_pos := Vector3.INF
	var seen_releases: int = releases_before
	var pending_probe: Dictionary = {}
	var entered_zone: bool = dump_speed <= 0.0 and chip_hang_s <= 0.0
	# Chaser-path trace (behind-net diagnosis): sample OUR elected chaser's
	# body + agent state against the puck until first touch. First line is
	# the trigger itself — where the dump actually launched from and the
	# warm carrier's position there (a warmup release moves the launch).
	var chaser_trace: Array[String] = []
	if scenario == "dump-behind-net":
		chaser_trace.append("trig puck(%.1f,%.1f) v(%.1f,%.1f) wc(%.1f,%.1f)" % [
				duel.puck_pos.x, duel.puck_pos.z, duel.puck_vel.x, duel.puck_vel.z,
				wc.pos.x, wc.pos.z])
	while t < LIMIT_S:
		duel.run(STEP_S)
		t += STEP_S
		if scenario == "dump-behind-net" and first_touch_peer == -1 \
				and (t < 1.05 or int(roundf(t * 10.0)) % 5 == 0):
			var elected: int = int(duel._prev_chase_by_team.get(0, -1))
			var bit: String = "e:none"
			if elected != -1:
				var es: RefCounted = duel._skater(elected)
				var st_name: String = "?"
				if es.agent != null:
					st_name = SkaterAgentStateMachine.State.keys()[es.agent._state]
				bit = "%d %s (%.1f,%.1f) v%.1f" % [elected, st_name,
						es.pos.x, es.pos.z, Vector2(es.vel.x, es.vel.z).length()]
			# Per-teammate path intercept times — who COULD kill this puck.
			var kill_bits: Array[String] = []
			if AILoosePuckChase.is_fast_puck(duel.puck_vel):
				var ktraj: Array[Vector3] = AILoosePuckChase.race_trajectory(
						duel.puck_pos, duel.puck_vel)
				var sdt: float = AILoosePuckChase.RACE_LOOKAHEAD_S \
						/ float(AILoosePuckChase.RACE_STEPS)
				for s2: RefCounted in duel.skaters:
					if s2.team_id != 0:
						continue
					kill_bits.append("%d:%.1f" % [s2.peer_id % 100,
							AILoosePuckChase.path_intercept_time(
									ktraj, sdt, s2.pos, s2.vel, 9.0)])
			chaser_trace.append("%4.1fs %s | puck(%.1f,%.1f) | %s" % [
					t, bit, duel.puck_pos.x, duel.puck_pos.z, " ".join(kill_bits)])
		# Probe: pair each team-0 release with its fate — the next pickup
		# (ours = completed, theirs = died) or an uncontrolled zone exit.
		while seen_releases < duel.releases.size():
			var rec: Dictionary = duel.releases[seen_releases]
			seen_releases += 1
			if int(rec.get("team", -1)) == 0 and rec.has("pass_score") 					and String(rec.get("decision", "")).begins_with("PASS"):
				if not pending_probe.is_empty():
					_probe.append({"ev": pending_probe.ev, "completed": false})
				pending_probe = {"ev": float(rec.get("pass_score", 0.0))}
		if not pending_probe.is_empty() and duel.carrier_id != -1:
			_probe.append({"ev": pending_probe.ev,
					"completed": duel.team_map.get(duel.carrier_id, -1) == 0})
			pending_probe = {}
		if (duel.brains[0] as TeamBrain).state == AIPossessionState.State.RETRIEVAL:
			retrieval_seen = true
		var cid: int = duel.carrier_id
		if first_touch_peer == -1 and cid != -1:
			first_touch_peer = cid
			first_touch_t = t
		# A dump launches near the blue line — an "exit" only counts after
		# the puck has actually been established inside our zone.
		if not entered_zone:
			entered_zone = duel.puck_pos.z > GameRules.BLUE_LINE_Z + 2.0
		if entered_zone and duel.puck_pos.z < GameRules.BLUE_LINE_Z:
			# Clean = our carrier skates it out, OR our controlled PASS is
			# in flight across the line (a breakout feed is a controlled
			# exit; only rims/chips/deflections count as "clear").
			var controlled: bool = cid != -1 and duel.team_map.get(cid, -1) == 0
			if not controlled and cid == -1 and not duel.releases.is_empty():
				var last_rel: Dictionary = duel.releases[-1]
				controlled = int(last_rel.get("team", -1)) == 0 \
						and String(last_rel.get("decision", "")).begins_with("PASS") \
						and duel.ticks - int(last_rel.get("tick", 0)) < 180
			outcome = "clean-exit" if controlled else "clear-exit"
			break
		if cid != -1 and duel.team_map.get(cid, -1) == 1:
			outcome = "cough-up"
			if duel.team_map.get(first_touch_peer, -1) == 0:
				intercept_pos = duel.puck_pos
			break

	# First team-0 release after the trigger — the retriever's first move.
	var first_release: Dictionary = {}
	for i: int in range(releases_before, duel.releases.size()):
		var rec: Dictionary = duel.releases[i]
		if int(rec.get("team", -1)) == 0:
			first_release = rec
			break
	_rows.append({"scenario": scenario, "mirror": mirror, "jitter": jitter,
			"outcome": outcome, "t": t, "retrieval": retrieval_seen,
			"touch_peer": first_touch_peer, "touch_t": first_touch_t,
			"release": first_release, "intercept": intercept_pos,
			"chaser_trace": chaser_trace})


func _intent_label(rec: Dictionary) -> String:
	if rec.is_empty():
		return "none"
	# The SM's committed decision string ("PASS→Slot" / "DUMP↝rim" / "SHOOT")
	# — the intent enum can already be cleared by fire time.
	var decision: String = String(rec.get("decision", ""))
	if decision != "":
		return "%s(p%.2f c%.2f d%.2f)" % [decision,
				float(rec.get("pass_score", 0.0)),
				float(rec.get("carry_score", 0.0)),
				float(rec.get("dump_score", 0.0))]
	return "rel(%d)" % int(rec.get("intent", -1))


func _report() -> void:
	gut.p("")
	gut.p("=== Breakout harness v3 (organic warmup + real dump flights; %.0fs limit, %d trials) ===" % [
			LIMIT_S, _rows.size()])
	var counts: Dictionary = {}
	var exit_times: Array[float] = []
	var retrieval_fires: int = 0
	for row: Dictionary in _rows:
		counts[row.outcome] = int(counts.get(row.outcome, 0)) + 1
		if String(row.outcome).ends_with("exit"):
			exit_times.append(row.t)
		if row.retrieval:
			retrieval_fires += 1
		var rel_bit: String = _intent_label(row.release)
		gut.p("  %-16s m%+d j%d → %-10s %5.1fs  retr:%s touch:%d@%.1fs 1st:%s" % [
				row.scenario, int(row.mirror), int(row.jitter), row.outcome,
				row.t, "Y" if row.retrieval else "n",
				int(row.touch_peer), float(row.touch_t), rel_bit])
		if int(row.jitter) == 0 and not (row.chaser_trace as Array).is_empty():
			for line: String in row.chaser_trace:
				gut.p("      " + line)
	# The completion curve: scored pass EV bucket vs realized completion.
	if not _probe.is_empty():
		var buckets: Array = [[0.0, 0.05], [0.05, 0.1], [0.1, 0.2], [0.2, 9.9]]
		var bits: Array[String] = []
		for b: Array in buckets:
			var done: int = 0
			var total: int = 0
			for pr: Dictionary in _probe:
				if pr.ev >= b[0] and pr.ev < b[1]:
					total += 1
					if pr.completed:
						done += 1
			if total > 0:
				bits.append("ev[%.2f-%.2f) %d/%d" % [b[0], b[1], done, total])
		gut.p("  pass probe (completed/fired by scored EV): " + ", ".join(bits))
	var n: int = _rows.size()
	gut.p("  totals: clean %d/%d, clear %d/%d, cough %d/%d, timeout %d/%d | retrieval fired %d/%d" % [
			int(counts.get("clean-exit", 0)), n,
			int(counts.get("clear-exit", 0)), n,
			int(counts.get("cough-up", 0)), n,
			int(counts.get("timeout", 0)), n,
			retrieval_fires, n])
	if not exit_times.is_empty():
		var sum: float = 0.0
		for et: float in exit_times:
			sum += et
		gut.p("  mean time-to-exit: %.1fs over %d exits" % [
				sum / exit_times.size(), exit_times.size()])


func test_breakout_scenarios() -> void:
	for mirror: float in [1.0, -1.0]:
		for j: int in JITTERS:
			# Cycle turnover: their RW cycling our strong wall loses it into
			# the corner (a poke/bobble squirt).
			_run_trial("cycle-turnover", mirror, j,
					10013, Vector3(10.5, 0, 17.0),
					Vector3(9.5, 0, 25.0), Vector3(1.0, 0, 2.0))
			# Dump-in: their C carries the NZ and CHIPS it over the traffic
			# into our corner — the lofted dump a flat 2D fire can't stage
			# (a flat center-lane dump gets picked off, which is exactly
			# why real dumps are chipped). Flight + hang is the defense's
			# honest retreat window.
			_run_trial("dump-in", mirror, j,
					10011, Vector3(0.0, 0, 2.0),
					Vector3(10.5, 0, 25.0), Vector3.ZERO, 0.0, 0.95)
			# Wall entry + hard rim: their C drives up the boards and rims
			# it from the true wall lane — the rim hugs the boards past the
			# pinching winger's reach, wraps the corner arc, dies
			# behind/beside our net (wheel country).
			_run_trial("dump-behind-net", mirror, j,
					10011, Vector3(11.0, 0, 6.0),
					Vector3(12.7, 0, 18.0), Vector3.ZERO, 17.0,
					0.0, {"warmup_s": 0.6, "warm_vel": Vector3(0, 0, 7.0)})
	_report()
	assert_eq(_rows.size(), JITTERS * 6, "all trials ran")
