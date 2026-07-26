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


# States in which the skater is handling the puck — carrying, aiming a wrister, or
# a slapper wind-up that still holds it (the one-timer SLAPPER_CHARGE_WITHOUT_PUCK
# does NOT). Pure/static so it reads the same on host, client, reconcile replay,
# and the lag-comp claim path (which only has the replicated shot_state, not a live
# carrier reference). Gates the "committed check" split: a carrier can hold the Hit
# button to BRACE but can't DELIVER an offensive check while carrying.
static func state_has_puck(state: int) -> bool:
	return state == State.SKATING_WITH_PUCK \
			or state == State.WRISTER_AIM \
			or state == State.SLAPPER_CHARGE_WITH_PUCK

# Controller operations injected at setup. All methods that need @export params
# or actor/puck references stay on SkaterController and are wired as Callables
# so the state machine only owns transition logic.
class Callbacks:
	# Blade / IK
	var apply_blade_from_mouse: Callable          # (input: InputState, delta: float)
	var apply_wrister_aim_blade: Callable         # (input: InputState, delta: float) — holds the blade at the shot origin while the torso coils
	var wrister_chirality_seed: Callable          # (input: InputState) -> Vector3 — player-relative bearing the swing tracker seeds from; MUST match the source _update_wrister_charge feeds (cursor when frozen, blade when live)
	var wrister_blade_backhand: Callable          # () -> bool — is the blade on the backhand side RIGHT NOW; pinned at charge start as the absolute-aim (gamepad) hand read
	var apply_slapper_blade_position: Callable    # ()
	var apply_block_blade_position: Callable      # ()
	var apply_wrister_follow_through: Callable    # ()
	var apply_slapper_follow_through: Callable    # ()
	# State entry
	var enter_shot_block: Callable                # ()
	var enter_slapper_charge: Callable            # (input: InputState)
	var transition_to_skating: Callable           # ()
	# Shot releases
	var release_wrister: Callable                 # (input: InputState)
	var fire_quick_pass: Callable                 # (input: InputState) — instant quick pass
	var release_slapper: Callable                 # (input: InputState)
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
# Total the timer started from (normalizes follow-through progress — durations
# differ per shot type) and the amplitude scale of this follow-through (set at
# release: wrister by charge, quick pass fixed low, slapper full). Saved and
# restored through reconcile in LocalController alongside the timer.
var follow_through_duration_total: float = 0.25
var follow_through_power: float = 1.0
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


func _state_skating_with_puck(skater: Skater, input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	_cb.apply_blade_from_mouse.call(input, delta)
	# Quick pass: dedicated button, fires instantly (no aim state). Checked
	# before the wrister so the blade target computed above is this tick's, and
	# returns so a same-tick shoot/slap press can't stack on top.
	if input.quick_pass_pressed:
		_cb.fire_quick_pass.call(input)
		return
	if input.shoot_pressed:
		_enter_wrister_aim(skater, input)
	if input.slap_pressed:
		_cb.enter_slapper_charge.call(input)


func _state_wrister_aim(_skater: Skater, input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	# The OTHER shot button cancels: tap the slapper (RMB) to bail a wrister
	# charge back to carry without firing. Block no longer cancels shots — it is
	# purely the shot-block stance now. The slap_pressed edge is consumed here, so
	# returning to carry this tick can't stack into a slapper charge next tick.
	if input.slap_pressed:
		_cb.transition_to_skating.call()
		return
	# Holds the blade frozen at the shot origin (the puck sits still where the shot
	# fires from) while the torso coils toward the cursor.
	_cb.apply_wrister_aim_blade.call(input, delta)
	_cb.update_wrister_charge.call(input)
	if not input.shoot_held:
		_cb.release_wrister.call(input)


func _state_slapper_charge_with_puck(_skater: Skater, input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	# The OTHER shot button cancels: tap the wrister (LMB) to bail the slapper
	# wind-up back to carry. (Was block_held; block is now the shot-block stance.)
	if input.shoot_pressed:
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
			_cb.release_slapper.call(input)
			return

	_cb.update_slapper_charge.call(delta)
	_cb.apply_slapper_blade_position.call()
	_cb.apply_slapper_velocity_drag.call(delta)

	if not input.slap_held:
		_cb.release_slapper.call(input)


func _state_slapper_charge_without_puck(_skater: Skater, input: InputState, delta: float, _has_puck: bool, _is_movement_locked: bool) -> void:
	# The OTHER shot button cancels: tap the wrister (LMB) to bail a one-timer
	# wind-up back to carry. (Was block_held; block is now the shot-block stance.)
	if input.shoot_pressed:
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
		else:
			# Whiffed one-timer: the swing is already committed — play the
			# full follow-through through empty air (shot_dir stays zero;
			# the pose falls back to locked_slapper_dir) instead of the old
			# instant cancel, which snapped the wind-up away with no swing.
			shot_dir = Vector3.ZERO
		follow_through_is_slapper = true
		_state = State.FOLLOW_THROUGH
		follow_through_timer = result.get("follow_through_duration", 0.5)
		follow_through_duration_total = follow_through_timer


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
	_cb.apply_block_blade_position.call()

# ── Internal helpers ──────────────────────────────────────────────────────────

func _enter_wrister_aim(skater: Skater, input: InputState) -> void:
	_state = State.WRISTER_AIM
	shot_dir = Vector3.ZERO
	# Seed both the cursor (screen-space) and the blade (skater-translation-
	# subtracted world) baselines the charge tracker reads each tick — first
	# tick after press produces a delta of zero against these, so a spurious
	# wide-angle direction-variance reset can't fire on the first frame.
	var intent_pos := Vector3(input.mouse_screen_pos.x, 0.0, input.mouse_screen_pos.y)
	# Chirality (FH/BH) baseline: seed from the SAME source the charge tick will
	# feed (cursor bearing when frozen, blade bearing when live), so the first
	# swing_step is source-to-source and doesn't bank a spurious rotation from a
	# blade→cursor bearing jump — that jump was flipping frozen backhands (cursor
	# starting opposite the carry blade) to forehands.
	var blade_pos_rel_skater: Vector3
	if _cb.wrister_chirality_seed.is_valid():
		blade_pos_rel_skater = _cb.wrister_chirality_seed.call(input)
	else:
		var blade_world: Vector3 = skater.upper_body_to_global(skater.get_blade_position())
		blade_pos_rel_skater = blade_world - skater.global_position
	blade_pos_rel_skater.y = 0.0
	# Pin the aim ORIGIN at stroke start (the puck's on-blade contact point, where
	# the shot will fire from) for the positional-aim wrister — see
	# SkaterAimingBehavior.wrister_origin_world. Anchoring here, before the blade
	# sweeps, is what keeps origin→cursor stable through the stroke.
	# The HAND pins with it, read off the side the blade is on as it freezes: the
	# absolute-aim (gamepad) forehand/backhand source, which needs no sweep. See
	# SkaterAimingBehavior.wrister_origin_backhand.
	var origin_backhand: bool = false
	if _cb.wrister_blade_backhand.is_valid():
		origin_backhand = bool(_cb.wrister_blade_backhand.call())
	_aiming.reset_wrister(intent_pos, blade_pos_rel_skater,
			skater.get_blade_contact_global(), origin_backhand)


func _cancel_slapper_internal() -> void:
	_aiming.slapper_charge_timer = 0.0
	_cb.transition_to_skating.call()
