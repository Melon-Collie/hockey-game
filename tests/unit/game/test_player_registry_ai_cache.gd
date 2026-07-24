extends GutTest

# Covers the bot-controller cache added for the centralized AI dispatch loop
# (docs/ai-threading-plan.md, Phase 2). The host iterates
# PlayerRegistry.ai_controllers() once per tick instead of scanning _players for
# AIControllers, so the cache must hold exactly the AIController instances and
# rebuild in lockstep as records come and go.
#
# Drives _rebuild_skaters_cache() directly against a hand-populated _players so
# the test stays free of the heavy spawn/remove wiring (teams, TeamColorRegistry,
# signals, state machine, and Skater actor construction). The rebuild's
# controller filter is the only logic the cache change touched; records carry a
# controller but no Skater actor (Skater.new() needs the spawner's args and the
# rebuild only reads `controller is AIController` for this cache).

var _reg: PlayerRegistry
var _nodes: Array[Node] = []


func before_each() -> void:
	_reg = PlayerRegistry.new()
	_nodes = []


func after_each() -> void:
	for n: Node in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	_reg = null


func _record_with_controller(pid: int, ai: bool) -> PlayerRecord:
	# team is null: _rebuild_skaters_cache only reads skater/controller, never team.
	var rec := PlayerRecord.new(pid, 0, not ai, null)
	var ctrl: SkaterController
	if ai:
		ctrl = AIController.new()
	else:
		ctrl = LocalController.new()
	_nodes.append(ctrl)
	rec.controller = ctrl
	return rec


func test_cache_holds_only_ai_controllers() -> void:
	_reg._players[1] = _record_with_controller(1, true)
	_reg._players[2] = _record_with_controller(2, false)
	_reg._players[3] = _record_with_controller(3, true)
	_reg._rebuild_skaters_cache()

	assert_eq(_reg.ai_controllers().size(), 2, "both bots cached, the human is not")
	for ctrl: AIController in _reg.ai_controllers():
		assert_true(ctrl is AIController, "cache entries are AIControllers")


func test_cache_tracks_removal() -> void:
	_reg._players[1] = _record_with_controller(1, true)
	_reg._players[2] = _record_with_controller(2, false)
	_reg._rebuild_skaters_cache()
	assert_eq(_reg.ai_controllers().size(), 1, "one bot present")

	_reg._players.erase(1)
	_reg._rebuild_skaters_cache()
	assert_eq(_reg.ai_controllers().size(), 0, "cache empties when the only bot leaves")


func test_cache_clears_with_state() -> void:
	_reg._players[1] = _record_with_controller(1, true)
	_reg._rebuild_skaters_cache()
	assert_eq(_reg.ai_controllers().size(), 1)

	# clear_state wipes both caches (autoload teardown / match reset path).
	_reg.clear_state()
	assert_eq(_reg.ai_controllers().size(), 0, "cache cleared with registry state")
