extends GutTest

# Committing to a shot block takes the blade out of puck play: it corrals
# nothing loose and it strips nothing off a carrier. The withdrawal is enforced
# per-path rather than in one place — the blade Area3D's layer flip has been
# inert since puck contact went analytic — so this drives the host's real
# present-time detection (PuckController._check_interactions) with a blade
# parked on the puck, which is the case a gate on the wrong path would miss.
#
# The lag-comp claim paths (PokeClaimResolver / StickLiftClaimResolver) carry
# the same gate against the REWOUND stance; those need a state-buffer triple to
# exercise and are verified live, like the rest of the claim geometry.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const PUCK_SCENE: PackedScene = preload("res://Scenes/Puck.tscn")
const State = SkaterStateMachine.State

var _pc: PuckController = null
var _puck: Puck = null
var _carrier: Skater = null
var _checker: Skater = null


func before_each() -> void:
	_puck = PUCK_SCENE.instantiate() as Puck
	add_child_autofree(_puck)
	_puck.set_physics_process(false)
	_puck.set_process(false)

	_carrier = _spawn_skater(Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0))
	_checker = _spawn_skater(Vector3(0.6, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0))

	_pc = PuckController.new()
	add_child_autofree(_pc)
	_pc.set_physics_process(false)
	_pc.set_process(false)
	_pc.setup(_puck, true)
	# Opposing teams, or can_poke_check refuses before any stance gate does.
	_pc.set_team_id_by_skater({_carrier: 0, _checker: 1})
	_pc.set_skater_getter(func() -> Array: return [_carrier, _checker])
	_pc.set_peer_id_resolver(func(s: Skater) -> int: return 1 if s == _checker else 2)
	_puck.set_carrier(_carrier)


func _spawn_skater(pos: Vector3) -> Skater:
	var s: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(s)
	s.global_position = pos
	s.set_physics_process(false)
	s.set_process(false)
	return s


# Sits the puck exactly on the checker's blade and runs the tick the host runs.
# Zero separation, so the poke's swept test cannot miss for geometric reasons —
# whether the strip lands is then purely the stance gate. (These skaters are
# never ticked by a controller, so their blades hang unposed at body height
# rather than on the ice; the poke test is a plain distance, so that only
# matters for where the puck has to be put.)
func _poke_with_blade_on_the_puck() -> void:
	_puck.global_position = _checker.get_blade_contact_global()
	_pc._prev_puck_pos = _puck.global_position
	_pc._check_interactions()


func test_a_skating_checker_pokes_the_carrier() -> void:
	# The control: without the block stance the same geometry strips the puck,
	# so the assertions below are about the stance and not about a poke that
	# never had a chance to land.
	_checker.current_shot_state = State.SKATING_WITHOUT_PUCK
	_poke_with_blade_on_the_puck()
	assert_null(_puck.carrier, "a blade on the puck should strip the carrier")


func test_a_blocking_checker_does_not_poke() -> void:
	_checker.current_shot_state = State.SHOT_BLOCKING
	_checker.set_block_stance(true)
	_poke_with_blade_on_the_puck()
	assert_eq(_puck.carrier, _carrier, "a committed block should take no puck off a carrier")


func test_a_lifted_blade_strips_the_carrier() -> void:
	# The control for the lift branch, same purpose as the poke control above.
	_checker.current_shot_state = State.SKATING_WITHOUT_PUCK
	_checker.blade_up = true
	_hook_blade_under_the_carrier_shaft()
	_pc._check_interactions()
	assert_null(_puck.carrier, "a blade hooked under the shaft should lift it and strip")


func test_a_blocking_checker_does_not_stick_lift() -> void:
	# blade_up is still written from input during a block (holding deflect at an
	# air loft), so the lift branch is reachable on stance alone — the gate has
	# to come first.
	_checker.current_shot_state = State.SHOT_BLOCKING
	_checker.set_block_stance(true)
	_checker.blade_up = true
	_hook_blade_under_the_carrier_shaft()
	_pc._check_interactions()
	assert_eq(_puck.carrier, _carrier, "a committed block should lift no stick either")


# Moves the checker's body until its blade sits just under the midpoint of the
# carrier's hand→blade shaft — the geometry check_blade_under_stick wants.
func _hook_blade_under_the_carrier_shaft() -> void:
	var hand: Vector3 = _carrier.upper_body_to_global(_carrier.get_top_hand_position())
	var target: Vector3 = hand.lerp(_carrier.get_blade_contact_global(), 0.5) - Vector3(0.0, 0.1, 0.0)
	var offset: Vector3 = _checker.get_blade_contact_global() - _checker.global_position
	_checker.global_position = target - offset
	_puck.global_position = _carrier.get_blade_contact_global()
	_pc._prev_puck_pos = _puck.global_position
