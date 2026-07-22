extends GutTest

# ── AI host-cost benchmark (report-only; NOT in the default suite) ───────────
# Measures the real production decision stack — live SkaterAgentStateMachines
# + TeamBrains stepped by the duel harness at 120 Hz — across representative
# game situations, for a 3v3 and a 5v5 roster, and prints a µs/game-second
# report. This is the perf regression gate for AI work: run it before and
# after a change and compare the table.
#
# Run explicitly (the benchmarks/ dir is outside .gutconfig's tests/ scan):
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks
#
# Methodology notes:
#   - Perfect-bot profiles (null) — the ~60 Hz dispatch cadence, i.e. the
#     WORST-case host cost tier. Difficulty tiers only lower it.
#   - Each scenario warms up 1 s (unmeasured) then measures WINDOW_S of game
#     time. The sim evolves live (passes, chases, possession flips), so
#     numbers are a churned average, not a frozen pose — expect a few % of
#     run-to-run noise; compare deltas bigger than that.
#   - "host AI µs per game-second" = brain ticks + all agent dispatches. On
#     the real host that budget competes with physics + everything else
#     inside 1_000_000 µs/s (8333 µs per 120 Hz tick).
#   - The only assertion is a generous sanity ceiling so a catastrophic
#     regression fails loudly even if nobody reads the table.

const Duel := preload("res://tests/unit/ai/duel_harness.gd")

const WARMUP_S: float = 1.0
const WINDOW_S: float = 10.0
# Catastrophic-regression ceiling: 5v5 AI over half the host's whole budget.
const SANITY_CEILING_US_PER_S: float = 500_000.0

# Collected rows for the final report: scenario -> size -> Dictionary.
var _rows: Array[Dictionary] = []


# ── Roster builders ──────────────────────────────────────────────────────────

# 3v3: rovers around the puck, mirroring a settled formation.
func _add_3v3(duel: RefCounted) -> void:
	# Team 0 (defends +Z): peers 1-3. Team 1 (defends -Z): peers 11-13.
	duel.add_skater(10001, 0, Vector3(0.0, 0.0, 6.0))
	duel.add_skater(10002, 0, Vector3(-6.0, 0.0, 10.0))
	duel.add_skater(10003, 0, Vector3(6.0, 0.0, 10.0))
	duel.add_skater(10011, 1, Vector3(0.0, 0.0, -6.0))
	duel.add_skater(10012, 1, Vector3(-6.0, 0.0, -10.0))
	duel.add_skater(10013, 1, Vector3(6.0, 0.0, -10.0))


# 5v5: full lineups with lobby positions (C/LW/RW/LD/RD per team).
func _add_5v5(duel: RefCounted) -> void:
	duel.add_skater(10001, 0, Vector3(0.0, 0.0, 4.0))     # C
	duel.add_skater(10002, 0, Vector3(-8.0, 0.0, 6.0))    # LW
	duel.add_skater(10003, 0, Vector3(8.0, 0.0, 6.0))     # RW
	duel.add_skater(10004, 0, Vector3(-4.0, 0.0, 14.0))   # LD
	duel.add_skater(10005, 0, Vector3(4.0, 0.0, 14.0))    # RD
	duel.add_skater(10011, 1, Vector3(0.0, 0.0, -4.0))
	duel.add_skater(10012, 1, Vector3(-8.0, 0.0, -6.0))
	duel.add_skater(10013, 1, Vector3(8.0, 0.0, -6.0))
	duel.add_skater(10014, 1, Vector3(-4.0, 0.0, -14.0))
	duel.add_skater(10015, 1, Vector3(4.0, 0.0, -14.0))
	duel.team_size = 5
	duel.positions = {10001: 0, 10002: 1, 10003: 2, 10004: 3, 10005: 4,
			10011: 0, 10012: 1, 10013: 2, 10014: 3, 10015: 4}


# Shift every skater toward a staged situation before start().
func _stage(duel: RefCounted, offset_t0: Vector3, offset_t1: Vector3) -> void:
	for s: RefCounted in duel.skaters:
		var off: Vector3 = offset_t0 if s.team_id == 0 else offset_t1
		s.pos += off
		s.blade = s.pos
		s.prev_blade = s.pos


# ── The measured run ─────────────────────────────────────────────────────────

func _run_case(scenario: String, size: int, carrier_peer: int,
		offset_t0: Vector3, offset_t1: Vector3,
		loose_puck: Vector3 = Vector3.ZERO) -> void:
	var duel: RefCounted = Duel.new()
	if size == 5:
		_add_5v5(duel)
	else:
		_add_3v3(duel)
	_stage(duel, offset_t0, offset_t1)
	duel.start(carrier_peer, loose_puck)

	duel.run(WARMUP_S)
	duel.collect_perf = true
	duel.perf_brain_us = 0
	duel.perf_dispatch_us.clear()
	duel.perf_dispatch_calls.clear()
	duel.perf_tick_us.clear()
	for s: RefCounted in duel.skaters:
		if s.agent != null:
			(s.agent as SkaterAgentStateMachine).full_dispatch_count = 0
	var wall_t0: int = Time.get_ticks_usec()
	duel.run(WINDOW_S)
	var wall_us: int = Time.get_ticks_usec() - wall_t0

	# Frame pacing: the host's FPS is set by the WORST tick. Report the
	# spike (max) and p95 per-tick AI cost against the 8333 µs tick budget.
	var ticks_sorted: Array[int] = duel.perf_tick_us.duplicate()
	ticks_sorted.sort()
	var tick_max: int = ticks_sorted[-1] if not ticks_sorted.is_empty() else 0
	var tick_p95: int = ticks_sorted[int(ticks_sorted.size() * 0.95)] \
			if not ticks_sorted.is_empty() else 0

	var dispatch_us: int = 0
	for pid: int in duel.perf_dispatch_us:
		dispatch_us += int(duel.perf_dispatch_us[pid])
	var ai_us: int = dispatch_us + duel.perf_brain_us
	# FULL-dispatch volume (throttle-skipped ticks excluded): the far-play
	# dispatch LOD thins how OFTEN the full state handler runs, which the
	# scenario totals can't show (the play evolves differently run-to-run) —
	# full dispatches/s shows the thinning directly.
	var dispatch_calls: int = 0
	for s: RefCounted in duel.skaters:
		if s.agent != null:
			dispatch_calls += (s.agent as SkaterAgentStateMachine).full_dispatch_count

	# Per-slot attribution: bucket each bot's window cost by the slot it
	# holds at the end of the window (bots hold slots for long stretches in
	# a staged scenario, so this is a fair coarse attribution).
	var by_slot: Dictionary = {}
	for pid: int in duel.perf_dispatch_us:
		var tid: int = duel.team_map[pid]
		var slot: int = (duel.brains[tid] as TeamBrain).get_slot(pid)
		var label: String = AIRoleSlots.Slot.keys()[slot]
		by_slot[label] = int(by_slot.get(label, 0)) + int(duel.perf_dispatch_us[pid])

	_rows.append({
		"scenario": scenario,
		"size": size,
		"ai_us_per_s": float(ai_us) / WINDOW_S,
		"brain_us_per_s": float(duel.perf_brain_us) / WINDOW_S,
		"dispatch_us_per_s": float(dispatch_us) / WINDOW_S,
		"dispatch_calls_per_s": float(dispatch_calls) / WINDOW_S,
		"wall_us_per_s": float(wall_us) / WINDOW_S,
		"tick_max_us": tick_max,
		"tick_p95_us": tick_p95,
		"by_slot": by_slot,
	})


func _report() -> void:
	gut.p("")
	gut.p("=== AI host-cost benchmark (µs per game-second; 120 Hz tick budget = 1,000,000) ===")
	for row: Dictionary in _rows:
		gut.p("%-14s %dv%d  AI %8.0f  (brain %6.0f + dispatch %8.0f over %4.0f full/s)   tick p95 %5d max %5d" % [
				row.scenario, row.size, row.size, row.ai_us_per_s,
				row.brain_us_per_s, row.dispatch_us_per_s,
				row.dispatch_calls_per_s,
				row.tick_p95_us, row.tick_max_us])
		var slot_bits: Array[String] = []
		var by_slot: Dictionary = row.by_slot
		for label: String in by_slot:
			slot_bits.append("%s %.0f" % [label, float(by_slot[label]) / WINDOW_S])
		gut.p("               slots: " + ", ".join(slot_bits))
	# Headline: the 3v3 → 5v5 multiplier per scenario.
	for i: int in range(0, _rows.size() - 1, 2):
		var a: Dictionary = _rows[i]
		var b: Dictionary = _rows[i + 1]
		if a.scenario == b.scenario:
			gut.p("%-14s 5v5/3v3 multiplier: %.2fx" % [
					a.scenario, b.ai_us_per_s / maxf(a.ai_us_per_s, 1.0)])


# One test = the whole matrix, so the report prints as a single block.
func test_ai_host_cost_matrix() -> void:
	# O-zone cycle: team 0's carrier deep in team 1's end.
	_run_case("ozone-cycle", 3, 10002, Vector3(0, 0, -24), Vector3(0, 0, -14))
	_run_case("ozone-cycle", 5, 10002, Vector3(0, 0, -24), Vector3(0, 0, -14))
	# NZ rush: team 0 carries through center ice at the defense.
	_run_case("nz-rush", 3, 10001, Vector3(0, 0, -6), Vector3(0, 0, -4))
	_run_case("nz-rush", 5, 10001, Vector3(0, 0, -6), Vector3(0, 0, -4))
	# Loose puck at center: both teams race + shape.
	_run_case("loose-neutral", 3, -1, Vector3.ZERO, Vector3.ZERO)
	_run_case("loose-neutral", 5, -1, Vector3.ZERO, Vector3.ZERO)
	_report()
	for row: Dictionary in _rows:
		assert_lt(row.ai_us_per_s, SANITY_CEILING_US_PER_S,
				"%s %dv%d blew the catastrophic ceiling" % [row.scenario, row.size, row.size])
