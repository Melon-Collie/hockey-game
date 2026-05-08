class_name SkaterStateMachine
extends RefCounted

enum State {
	SKATING_WITHOUT_PUCK,
	SKATING_WITH_PUCK,
	WRISTER_AIM,
	SLAPPER_CHARGE_WITH_PUCK,
	SLAPPER_CHARGE_WITHOUT_PUCK,
	FOLLOW_THROUGH,
	SHOT_BLOCKING,
}

# Controller operations injected at setup. All methods that need @export params
# or actor/puck references stay on SkaterController and are wired as Callables
# so the state machine only owns transition logic.
class Callbacks:
	# Blade / IK
	var apply_blade_from_mouse: Callable          # (input: InputState, delta: float)
	var apply_slapper_blade_position: Callable    # ()
	var apply_wrister_follow_through: Callable    # ()
	var apply_slapper_follow_through: Callable    # ()
	# State entry
	var enter_shot_block: Callable                # ()
	var enter_slapper_charge: Callable            # (input: InputState)
	var transition_to_skating: Callable           # ()
	# Shot releases
	var release_wrister: Callable                 # (input: InputState)
	var release_slapper: Callable                 # (input: InputState, one_timer: bool)
	# puck distance check + ShotMechanics + signal.
	# Returns { fired: bool, direction: Vector3, follow_through_duration: float }
	var try_one_timer_release: Callable           # (input: InputState) -> Dictionary
	# Per-frame updates that need @export params from SkaterController
	var update_wrister_charge: Callable           # (input: InputState)
	var update_slapper_charge: Callable           # (delta: float)
	var apply_slapper_velocity_drag: Callable     # (delta: float)
	var apply_block_movement: Callable            # (input: InputState, delta: float)

# ── Owned state (moved from SkaterController) ─────────────────────────────────
var _state: State = State.SKATING_WITHOUT_PUCK
# No underscore: LocalController accesses these directly in reconcile().
var follow_through_timer: float = 0.0
var follow_through_is_slapper: bool = false
var shot_dir: Vector3 = Vector3.ZERO
var locked_slapper_dir: Vector2 = Vector2.ZERO

var _cb: Callbacks
var _aiming: SkaterAimingBehavior

# ── Setup ─────────────────────────────────────────────────────────────────────

func setup(callbacks: Callbacks, aiming: SkaterAimingBehavior) -> void:
	_cb = callbacks
	_aiming = aiming

# ── State accessors ───────────────────────────────────────────────────────────

func get_state() -> State:
	return _state


func set_state(s: State) -> void:
	_state = s

# ── Dispatch ─────────────────────────────────────────────────────────────────

func dispatch(skater: Skater, input: InputState, delta: float, has_puck: bool, is_movement_locked: bool) -> void:
	match _state:
		State.SKATING_WITHOUT_PUCK:
			_state_skating_without_puck(skater, input, delta, has_puck, is_movement_locked)
		State.SKATING_WITH_PUCK:
			_state_skating_with_puck(skater, input, delta, has_puck, is_movement_locked)
		State.WRISTER_AIM:
			_state_wrister_aim(skater, input, delta, has_puck, is_movement_locked)
		State.SLAPPER_CHARGE_WITH_PUCK:
			_state_slapper_charge_with_puck(skater, input, delta, has_puck, is_movement_locked)
		State.SLAPPER_CHARGE_WITHOUT_PUCK:
			_state_slapper_charge_without_puck(skater, input, delta, has_puck, is_movement_locked)
		State.FOLLOW_THROUGH:
			_state_follow_through(skater, input, delta, has_puck, is_movement_locked)
		State.SHOT_BLOCKING:
			_state_shot_blocking(skater, input, delta, has_puck, is_movement_locked)

# ── State handlers ────────────────────────────────────────────────────────────

func _state_skating_without_puck(_skater: Skater, input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	if input.block_held:
		_cb.enter_shot_block.call()
		return
	_cb.apply_blade_from_mouse.call(input, delta)
	if input.shoot_pressed:
		_state = State.WRISTER_AIM
		shot_dir = Vector3.ZERO
	if input.slap_pressed:
		_cb.enter_slapper_charge.call(input)


func _state_skating_with_puck(_skater: Skater, input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	_cb.apply_blade_from_mouse.call(input, delta)
	if input.shoot_pressed:
		_enter_wrister_aim(input)
	if input.slap_pressed:
		_cb.enter_slapper_charge.call(input)


func _state_wrister_aim(_skater: Skater, input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	if input.block_held:
		_cb.transition_to_skating.call()
		return
	_cb.apply_blade_from_mouse.call(input, delta)
	_cb.update_wrister_charge.call(input)
	if not input.shoot_held:
		_cb.release_wrister.call(input)


func _state_slapper_charge_with_puck(_skater: Skater, input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	if input.block_held:
		_cancel_slapper_internal()
		return

	# One-timer window: puck arrived mid-charge. Player must release before
	# the window expires or the shot is cancelled (they keep the puck).
	if _aiming.one_timer_window_timer > 0.0:
		_aiming.tick_one_timer_window(delta)
		if _aiming.one_timer_window_timer <= 0.0:
			# Window expired — cancel slapper, keep puck in carry state.
			_cancel_slapper_internal()
			return
		if not input.slap_held:
			_cb.release_slapper.call(input, true)
			return

	_cb.update_slapper_charge.call(delta)
	_cb.apply_slapper_blade_position.call()
	_cb.apply_slapper_velocity_drag.call(delta)

	if not input.slap_held:
		_cb.release_slapper.call(input, false)


func _state_slapper_charge_without_puck(_skater: Skater, input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	if input.block_held:
		_cancel_slapper_internal()
		return

	_cb.update_slapper_charge.call(delta)
	_cb.apply_slapper_blade_position.call()

	if not input.slap_held:
		# Release buffer: check if the puck is close enough to count as a
		# one-timer even if it hasn't entered the pickup zone yet. This lets
		# the player release on the beat without having to time it early.
		var result: Dictionary = _cb.try_one_timer_release.call(input)
		if result.get("fired", false):
			shot_dir = result.direction
			follow_through_is_slapper = true
			_state = State.FOLLOW_THROUGH
			follow_through_timer = result.get("follow_through_duration", 0.5)
		else:
			_cancel_slapper_internal()


func _state_follow_through(_skater: Skater, _input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	if follow_through_is_slapper:
		_cb.apply_slapper_follow_through.call()
	else:
		_cb.apply_wrister_follow_through.call()
	follow_through_timer -= delta
	if follow_through_timer <= 0.0:
		_cb.transition_to_skating.call()


func _state_shot_blocking(skater: Skater, input: InputState, delta: float, _has_puck: bool, is_movement_locked: bool) -> void:
	if not input.block_held or is_movement_locked:
		skater.set_block_stance(false)
		_cb.transition_to_skating.call()
		return
	_cb.apply_block_movement.call(input, delta)

# ── Internal helpers ──────────────────────────────────────────────────────────

func _enter_wrister_aim(input: InputState) -> void:
	_state = State.WRISTER_AIM
	shot_dir = Vector3.ZERO
	_aiming.reset_wrister(input.mouse_screen_pos)


func _cancel_slapper_internal() -> void:
	_aiming.slapper_charge_timer = 0.0
	_cb.transition_to_skating.call()
