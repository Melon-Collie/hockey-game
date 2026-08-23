extends GutTest

# ── Control-tick micro-benchmark (report-only; NOT in the default suite) ─────
# Times SkaterController._process_input and its parts on one real skater, so the
# per-tick control budget can be ranked instead of guessed at. Sister tool to
# test_ai_micro_benchmark.gd: that one says where a bot's DECISION budget goes;
# this one says where the CONTROL budget goes — the tick every skater runs,
# bot or human, on the host.
#
# Why this exists: _process_input is the single largest main-thread cost in a
# 5v5 frame, and it runs 120 Hz x roster on the host, so on a dedicated server
# it is essentially the entire bill. It is also already well optimised at the
# obvious level (IK configs cached, ROM projection closed-form, collaborators
# memoised), which means the remaining wins are the non-obvious kind and
# guessing at them wastes time. Everything here is a µs-per-call number on one
# frozen, realistic pose.
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks
#
# Compare RELATIVELY (part vs part, before vs after a change), never as an
# absolute frame cost: a debug build inflates GDScript, and the parts overlap
# (the state machine's total contains the blade IK it calls).

const REPS: int = 3000

# Minimal stand-in for the game-state Node the controller takes. The controller
# only ever asks these two questions of it.
class StubGameState extends Node:
	var locked: bool = false

	func is_host() -> bool:
		return true

	func is_movement_locked() -> bool:
		return locked


var _results: Array[Dictionary] = []
var _skater: Skater = null
var _controller: SkaterController = null
var _input: InputState = null


func before_all() -> void:
	var puck: Puck = load("res://Scenes/Puck.tscn").instantiate() as Puck
	add_child_autofree(puck)

	_skater = load("res://Scenes/Skater.tscn").instantiate() as Skater
	add_child_autofree(_skater)
	_skater.global_position = Vector3(2.0, 0.0, 8.0)

	var state := StubGameState.new()
	add_child_autofree(state)

	_controller = SkaterController.new()
	add_child_autofree(_controller)
	_controller.setup(_skater, puck, state)

	# A mid-rink skater carrying speed with the cursor out in front — the pose
	# the tick spends almost all of its time in (SKATING_WITHOUT_PUCK with a
	# live aim). Benchmarking a rest pose would understate the IK, which is the
	# part with the most work to skip.
	_skater.velocity = Vector3(3.5, 0.0, -4.0)
	_input = InputState.new()
	_input.delta = 1.0 / 120.0
	_input.move_vector = Vector2(0.4, -0.9)
	_input.mouse_world_pos = Vector3(3.4, 0.0, 5.2)
	_input.sprint_held = true


func after_all() -> void:
	if _results.is_empty():
		return
	var widest: int = 0
	for r: Dictionary in _results:
		widest = maxi(widest, (r["label"] as String).length())
	gut.p("")
	gut.p("── Control tick cost (µs/call, %d reps) ──" % REPS)
	for r: Dictionary in _results:
		gut.p("  %s  %8.2f" % [(r["label"] as String).rpad(widest), r["us"]])
	gut.p("")


func _bench(label: String, fn: Callable) -> void:
	fn.call()  # warm: first-call inits, smoothing seeds, scratch growth
	var t0: int = Time.get_ticks_usec()
	for _i: int in REPS:
		fn.call()
	_results.append({
		"label": label,
		"us": float(Time.get_ticks_usec() - t0) / float(REPS),
	})


# The headline plus its parts. The parts do not sum to the whole — the state
# machine's dispatch calls the blade IK, so that cost appears in both — but the
# ranking is what picks the target.
func test_control_tick_costs() -> void:
	var delta: float = 1.0 / 120.0

	_bench("_process_input (WHOLE TICK)", func() -> void:
		_controller._process_input(_input, delta))

	_bench("  blade IK (apply_blade_from_mouse)", func() -> void:
		_controller._ik.apply_blade_from_mouse(_input, delta))

	_bench("  state machine dispatch", func() -> void:
		_controller._sm.dispatch(_skater, _input, delta, false, false))

	_bench("  movement (_apply_movement)", func() -> void:
		_controller._apply_movement(_input, delta))

	_bench("  upper body pose", func() -> void:
		_controller._pose.apply_upper_body(delta))

	_bench("  facing", func() -> void:
		_controller._pose.apply_facing(_input, delta))

	# The Callable question, isolated. The state machine reaches the IK through
	# a Callables bundle (SkaterStateMachine.Callbacks), so every tick pays
	# variant-dispatch on top of the work. These two lines run identical code by
	# different routes; the gap between them IS the indirection's price, and it
	# is paid 120 Hz x roster on the host. If the gap is noise, the boundary is
	# free and should stay exactly as it is.
	var cb: Callable = _controller._ik.apply_blade_from_mouse
	_bench("[A] blade IK via direct call", func() -> void:
		_controller._ik.apply_blade_from_mouse(_input, delta))
	_bench("[B] blade IK via Callable.call", func() -> void:
		cb.call(_input, delta))

	# Transform round-trips: _process_input converts blade and hand to world,
	# rotates the torso, then converts both back, and the IK does more of the
	# same. Each conversion depends on the upper body's global transform. This
	# prices one pair so the total can be estimated against the whole tick.
	_bench("[C] one to_global + to_local pair", func() -> void:
		var w: Vector3 = _skater.upper_body_to_global(_skater.get_blade_position())
		_skater.upper_body_to_local(w))

	# The rest of the tick. The five parts above leave a large unattributed
	# remainder, and a remainder is not a target — these break it open. Anything
	# here that rivals the blade IK is a finding, because none of it is the
	# headline work anyone would think to look at.
	_bench("[D] velocity lean", func() -> void:
		_controller._pose.apply_velocity_lean(delta))

	# The carry path's net collision. It is gated on has_puck, and the frozen
	# pose above is a skater WITHOUT the puck, so the flag is lifted for the
	# duration or the row would time an early return and report the work as
	# free. Safe to force here and only here: the skater is parked mid-rink, so
	# the post / crossbar branches — the ones with the release side effect —
	# cannot reach their geometry.
	_controller.has_puck = true
	_bench("[E] collide pinned puck with net (carrying)", func() -> void:
		_controller._collide_pinned_puck_with_net())
	_controller.has_puck = false

	_bench("[F] angular velocities", func() -> void:
		_controller._pose.update_angular_velocities(delta))

	_bench("[G] tick_celebration", func() -> void:
		_controller.tick_celebration(delta))

	_bench("[H] _wants_deflect", func() -> void:
		_controller._wants_deflect(_input))

	# The intent-stamping preamble: a dozen property writes onto the Skater plus
	# two predicate calls. Individually trivial, but it is the one block that
	# runs unconditionally for every skater every tick regardless of state.
	_bench("[I] intent stamping preamble", func() -> void:
		_skater.move_intent = _input.move_vector
		_skater.brake_intent = _input.brake
		_skater.elevation_level = _input.elevation_level
		_skater.deflect_intent = false
		_skater.blade_up = _skater.is_forced_lift_active()
		_skater.current_shot_state = 0)

	# The suspect the remainder pointed at. Skater.set_blade_position reads as a
	# setter at every call site but is not one: it does two to_global conversions
	# and a look_at to re-aim the blade marker along the shaft. look_at resolves
	# the global chain, writes back through set_global_transform, then restores
	# scale — the same cost profile removed from the cosmetic rig, except this one
	# sits in the 120 Hz path and fires several times per tick (the IK's wall
	# clamp, the torso-rotation restore, every shot pose).
	var blade_local: Vector3 = _skater.get_blade_position()
	_bench("[J] set_blade_position (has look_at)", func() -> void:
		_skater.set_blade_position(blade_local))
	_bench("[K] set_top_hand_position (plain setter, for scale)", func() -> void:
		_skater.set_top_hand_position(_skater.get_top_hand_position()))

	# Control for state drift. _process_input MUTATES the skater — velocity ramps,
	# the smoothed blade converges on a fixed cursor — so a long rep loop can walk
	# into cheaper branches than the first call took, and every part below the
	# headline was measured in whatever state the headline's loop left behind.
	# Re-running the whole tick LAST says whether the parts and the whole were
	# even priced in the same world. A large drop here means the headline number
	# is a convergence transient and the sum-vs-whole gap is an artefact, not a
	# missing cost worth hunting.
	_bench("_process_input (WHOLE TICK, re-measured last)", func() -> void:
		_controller._process_input(_input, delta))

	assert_true(_results.size() > 0, "benchmark produced results")

