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
const JITTERS: int = 3

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
		puck: Vector3, puck_vel: Vector3) -> void:
	var duel: RefCounted = Duel.new()
	_add_rosters(duel, mirror)
	# Seed the warmup possession: the opponents play LIVE (their cycle /
	# their entry) while our five settle into the brain's own shape.
	var wc: RefCounted = null
	for s: RefCounted in duel.skaters:
		if s.peer_id == warm_carrier:
			wc = s
	wc.pos = Vector3(warm_carrier_pos.x * mirror, 0, warm_carrier_pos.z)
	wc.blade = wc.pos
	wc.prev_blade = wc.pos
	duel.start(warm_carrier)
	duel.run(WARMUP_S)
	# The trigger event: the puck comes loose (a strip / bobble / dump),
	# jittered so trials sample the neighborhood, not one frozen pose.
	duel.carrier_id = -1
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
	while t < LIMIT_S:
		duel.run(STEP_S)
		t += STEP_S
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
		if duel.puck_pos.z < GameRules.BLUE_LINE_Z:
			outcome = "clean-exit" \
					if cid != -1 and duel.team_map.get(cid, -1) == 0 \
					else "clear-exit"
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
			"release": first_release, "intercept": intercept_pos})


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
	gut.p("=== Breakout harness v2 (organic warmup staging; %.0fs limit, %d trials) ===" % [
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
			# Dump-in: their C carries the NZ, dumps it deep to our corner;
			# the forecheck enters with real runway — RETRIEVAL country.
			_run_trial("dump-in", mirror, j,
					10011, Vector3(0.0, 0, 2.0),
					Vector3(8.0, 0, 23.0), Vector3(2.0, 0, 8.0))
			# Rimmed dump dying behind our net (wheel country).
			_run_trial("dump-behind-net", mirror, j,
					10011, Vector3(0.0, 0, 2.0),
					Vector3(2.0, 0, 28.2), Vector3(-4.0, 0, 0))
	_report()
	assert_eq(_rows.size(), JITTERS * 6, "all trials ran")
