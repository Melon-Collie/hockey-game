extends GutTest

# GameCamera's carrier gate — the condition behind carrier vision (the zoom probe
# ahead of the puck carrier) and carrier lookahead (the anchor lean).
#
# It used to read `puck.get_carrier()`, which is HOST-ONLY: the server's physics
# callbacks write `puck.carrier` and clients never do (Scripts/networking/
# CLAUDE.md). So every non-host player skated with the puck and got neither the
# vision zoom nor the lookahead — the framing silently degraded to off-puck for
# everyone but the host. The gate now consumes an injected resolver, which
# GameManager wires to a carrier source that resolves on both sides.
#
# The camera is built unparented so _ready() never runs (see
# test_game_camera_ozone_latch.gd).

var _cam: GameCamera = null
var _me: Skater = null
var _them: Skater = null

var _carrier: Skater = null


func before_each() -> void:
	_cam = GameCamera.new()
	autofree(_cam)
	_me = Skater.new()
	autofree(_me)
	_them = Skater.new()
	autofree(_them)
	_cam.skater = _me
	_carrier = null


func _resolve_carrier() -> Skater:
	return _carrier


func _wire() -> void:
	_cam.set_goal_context(null, null, Callable(), _resolve_carrier)


func test_gate_is_off_before_the_resolver_is_wired() -> void:
	# set_goal_context runs at spawn; until then there is no carrier source and
	# the gate must read false rather than erroring on an empty Callable.
	assert_false(_cam._local_player_carries(), "an unwired camera reports no carry")


func test_the_framed_player_carrying_opens_the_gate() -> void:
	_wire()
	_carrier = _me
	assert_true(_cam._local_player_carries(),
			"carrier framing engages when the resolver names the framed player")


func test_another_skater_carrying_leaves_the_gate_shut() -> void:
	_wire()
	_carrier = _them
	assert_false(_cam._local_player_carries(),
			"carrier framing is for the local carry only, not any carry")


func test_a_loose_puck_leaves_the_gate_shut() -> void:
	_wire()
	_carrier = null
	assert_false(_cam._local_player_carries(), "no carrier, no carrier framing")


func test_the_gate_does_not_read_the_host_only_puck_carrier() -> void:
	# The regression itself: a client's puck reports no carrier even while the
	# local player is carrying. With a puck attached and `puck.carrier` null — the
	# permanent client state — the resolver must still open the gate.
	var puck := Puck.new()
	autofree(puck)
	_cam.puck = puck
	_wire()
	_carrier = _me
	assert_null(puck.get_carrier(), "test setup: a client's puck never has a carrier")
	assert_true(_cam._local_player_carries(),
			"the gate follows the resolver, not the host-only puck.carrier")
