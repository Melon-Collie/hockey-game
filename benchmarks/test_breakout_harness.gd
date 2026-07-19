extends GutTest

# ── Breakout scenario harness (report-only; NOT in the default suite) ────────
# The Phase D measurement instrument (docs/breakout-plan.md): staged 5v5
# retrievals against the live forecheck, run on the real decision stack (the
# duel harness's 120 Hz movement + agents + brains), classified per trial:
#
#   clean-exit — the puck crosses our blue line with OUR carrier on it
#   clear-exit — the puck leaves the zone uncontrolled (a rim/chip out —
#                far better than a cough, not yet a controlled breakout)
#   cough-up   — an opponent becomes the carrier while the puck is still in
#                our zone (includes losing the initial retrieval race)
#   timeout    — still bottled after LIMIT_S
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks "-gselect=breakout"
#
# Report-only by design: this is the before/after instrument for the breakout
# phases, not a behavior gate — the only assertions are that the trials ran.
# Compare tables across commits the way the host-cost benchmark is used.

const Duel := preload("res://tests/unit/ai/duel_harness.gd")

const LIMIT_S: float = 12.0
const STEP_S: float = 0.1

var _rows: Array[Dictionary] = []


# Team 0 (defends +Z) staged in D-zone coverage-ish spots; team 1 as a
# committed 2-1-2 forecheck (F1 deep at fc_depth, F2 behind him, F3 high,
# points on the line). `mirror` flips the x-axis for side variety.
func _add_rosters(duel: RefCounted, mirror: float, fc_depth: float) -> void:
	duel.add_skater(10001, 0, Vector3(1.5 * mirror, 0, 21.0))    # C
	duel.add_skater(10002, 0, Vector3(-8.0 * mirror, 0, 17.0))   # LW
	duel.add_skater(10003, 0, Vector3(8.5 * mirror, 0, 18.5))    # RW
	duel.add_skater(10004, 0, Vector3(-3.0 * mirror, 0, 24.5))   # LD
	duel.add_skater(10005, 0, Vector3(6.5 * mirror, 0, 23.5))    # RD
	duel.add_skater(10011, 1, Vector3(7.0 * mirror, 0, fc_depth))        # F1
	duel.add_skater(10012, 1, Vector3(-2.0 * mirror, 0, fc_depth - 5.0)) # F2
	duel.add_skater(10013, 1, Vector3(2.0 * mirror, 0, 10.0))            # F3
	duel.add_skater(10014, 1, Vector3(-5.0 * mirror, 0, 6.0))            # point
	duel.add_skater(10015, 1, Vector3(6.0 * mirror, 0, 6.0))             # point
	duel.team_size = 5
	duel.positions = {
		10001: 0, 10002: 1, 10003: 2, 10004: 3, 10005: 4,
		10011: 0, 10012: 1, 10013: 2, 10014: 3, 10015: 4,
	}


func _run_trial(scenario: String, mirror: float, fc_depth: float,
		puck: Vector3, puck_vel: Vector3) -> void:
	var duel: RefCounted = Duel.new()
	_add_rosters(duel, mirror, fc_depth)
	duel.start(-1, Vector3(puck.x * mirror, 0.0, puck.z))
	duel.puck_vel = Vector3(puck_vel.x * mirror, 0.0, puck_vel.z)

	var t: float = 0.0
	var outcome: String = "timeout"
	while t < LIMIT_S:
		duel.run(STEP_S)
		t += STEP_S
		var cid: int = duel.carrier_id
		if duel.puck_pos.z < GameRules.BLUE_LINE_Z:
			outcome = "clean-exit" \
					if cid != -1 and duel.team_map.get(cid, -1) == 0 \
					else "clear-exit"
			break
		if cid != -1 and duel.team_map.get(cid, -1) == 1:
			outcome = "cough-up"
			break
	_rows.append({"scenario": scenario, "mirror": mirror,
			"outcome": outcome, "t": t})


func _report() -> void:
	gut.p("")
	gut.p("=== Breakout harness (5v5 vs committed forecheck; %.0fs limit) ===" % LIMIT_S)
	var counts: Dictionary = {}
	var exit_times: Array[float] = []
	for row: Dictionary in _rows:
		counts[row.outcome] = int(counts.get(row.outcome, 0)) + 1
		if String(row.outcome).ends_with("exit"):
			exit_times.append(row.t)
		gut.p("  %-22s mirror %+d  →  %-10s %5.1fs" % [
				row.scenario, int(row.mirror), row.outcome, row.t])
	var n: int = _rows.size()
	gut.p("  totals: clean %d/%d, clear %d/%d, cough %d/%d, timeout %d/%d" % [
			int(counts.get("clean-exit", 0)), n,
			int(counts.get("clear-exit", 0)), n,
			int(counts.get("cough-up", 0)), n,
			int(counts.get("timeout", 0)), n])
	if not exit_times.is_empty():
		var sum: float = 0.0
		for et: float in exit_times:
			sum += et
		gut.p("  mean time-to-exit: %.1fs over %d exits" % [
				sum / exit_times.size(), exit_times.size()])


func test_breakout_scenarios() -> void:
	for mirror: float in [1.0, -1.0]:
		# Corner retrieval, forecheck arriving.
		_run_trial("corner-retrieval", mirror, 15.0,
				Vector3(9.5, 0, 25.0), Vector3.ZERO)
		# Corner retrieval with F1 nearly on the puck — the hard race.
		_run_trial("corner-hot-f1", mirror, 20.0,
				Vector3(9.5, 0, 25.0), Vector3.ZERO)
		# Dumped-in rim travelling down our weak wall.
		_run_trial("rim-in-weak-wall", mirror, 15.0,
				Vector3(-11.8, 0, 14.0), Vector3(0, 0, 9.0))
		# Dead puck behind our net (wheel country).
		_run_trial("behind-net", mirror, 16.0,
				Vector3(2.0, 0, 28.2), Vector3(-3.0, 0, 0))
		# Dump-in WITH RUNWAY — the forecheck still crossing the line while
		# the puck runs deep: the clearly-won retrieval race, i.e. the case
		# the RETRIEVAL posture (Phase A) exists for.
		_run_trial("dump-in-runway", mirror, 9.0,
				Vector3(8.0, 0, 22.0), Vector3(2.0, 0, 8.0))
	_report()
	assert_eq(_rows.size(), 10, "all trials ran")
