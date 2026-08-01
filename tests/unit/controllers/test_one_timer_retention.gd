extends GutTest

# One-timer retention — the committed catch-and-load hold between the slap
# release and the puck leaving. Drives SkaterStateMachine directly with stub
# callbacks (it is a RefCounted whose every controller reach-out is a Callable,
# and the retention handler never touches the Skater argument).
#
# What is pinned here: a one-timer does NOT fire on the button edge, it fires
# once the hold expires; a PLAIN carried slapshot still fires on the edge; the
# hold is uncancellable; and a whiff at the end still commits to the follow
# through. The hold DURATION is a feel tunable on SkaterController and is
# deliberately not asserted — only the ordering it creates.

const RETENTION_S: float = 0.11
const TICK: float = 1.0 / 120.0

var _sm: SkaterStateMachine
var _aiming: SkaterAimingBehavior
var _retention_entries: int = 0
var _slapper_releases: int = 0
var _retained_releases: int = 0
var _retained_fires: bool = true


func before_each() -> void:
	_retention_entries = 0
	_slapper_releases = 0
	_retained_releases = 0
	_retained_fires = true
	_aiming = SkaterAimingBehavior.new()
	_sm = SkaterStateMachine.new()
	_sm.setup(_make_callbacks(), _aiming)


func _make_callbacks() -> SkaterStateMachine.Callbacks:
	var cb := SkaterStateMachine.Callbacks.new()
	var noop: Callable = func() -> void: pass
	var noop_1: Callable = func(_a: Variant) -> void: pass
	var noop_2: Callable = func(_a: Variant, _b: Variant) -> void: pass
	cb.apply_blade_from_mouse = noop_2
	cb.apply_wrister_aim_blade = noop_2
	cb.wrister_chirality_seed = func(_i: Variant, _o: Variant) -> Vector3: return Vector3.FORWARD
	cb.apply_slapper_blade_position = noop
	cb.apply_block_blade_position = noop
	cb.apply_wrister_follow_through = noop
	cb.apply_slapper_follow_through = noop
	cb.enter_shot_block = noop
	cb.enter_slapper_charge = noop_1
	cb.transition_to_skating = noop
	cb.release_wrister = noop_1
	cb.fire_quick_pass = noop_1
	cb.update_wrister_charge = noop_1
	cb.update_slapper_charge = func(delta: float) -> void: _aiming.tick_slapper(delta)
	cb.apply_slapper_velocity_drag = noop_1
	cb.apply_block_movement = noop_2
	cb.release_slapper = func(_i: Variant) -> void:
		_slapper_releases += 1
		_sm.set_state(SkaterStateMachine.State.FOLLOW_THROUGH)
		_sm.follow_through_timer = 0.5
	cb.enter_one_timer_retention = func() -> void:
		_retention_entries += 1
		_aiming.one_timer_retention_timer = RETENTION_S
	cb.release_retained_one_timer = func(_i: Variant) -> Dictionary:
		_retained_releases += 1
		return {
			fired = _retained_fires,
			direction = Vector3.FORWARD,
			follow_through_duration = 0.5,
		}
	return cb


func _tick(input: InputState, has_puck: bool) -> void:
	_sm.dispatch(null, input, TICK, has_puck, false)


func _held_slap() -> InputState:
	var i := InputState.new()
	i.slap_held = true
	return i


func _released_slap() -> InputState:
	return InputState.new()


# ── The puckless one-timer (feed still inbound at the swing) ──────────────────

func test_puckless_release_holds_before_it_fires() -> void:
	_sm.set_state(SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK)
	_tick(_released_slap(), false)
	assert_eq(_sm.get_state(), SkaterStateMachine.State.ONE_TIMER_RETENTION,
			"letting go commits the swing into the hold, not straight to the finish")
	assert_eq(_retention_entries, 1, "the hold is armed once")
	assert_eq(_retained_releases, 0, "nothing has left the stick yet")


func test_hold_expires_into_the_shot_and_the_follow_through() -> void:
	_sm.set_state(SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK)
	_tick(_released_slap(), false)
	for _i: int in 64:
		if _sm.get_state() != SkaterStateMachine.State.ONE_TIMER_RETENTION:
			break
		_tick(_released_slap(), false)
	assert_eq(_retained_releases, 1, "the shot fires exactly once, at the end of the hold")
	assert_eq(_sm.get_state(), SkaterStateMachine.State.FOLLOW_THROUGH,
			"and hands off to the finish")
	assert_true(_sm.follow_through_is_slapper, "a one-timer finishes as a slap swing")
	assert_eq(_sm.shot_dir, Vector3.FORWARD, "the fired direction drives the finish pose")


func test_the_hold_cannot_be_cancelled() -> void:
	_sm.set_state(SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK)
	_tick(_released_slap(), false)
	# The wind-up states bail to carry on the OTHER shot button; the hold must not.
	var cancel := InputState.new()
	cancel.shoot_pressed = true
	cancel.shoot_held = true
	_tick(cancel, false)
	assert_eq(_sm.get_state(), SkaterStateMachine.State.ONE_TIMER_RETENTION,
			"the swing is already committed — no button takes it back")


func test_a_whiff_at_the_end_still_commits_to_the_swing() -> void:
	_retained_fires = false
	_sm.set_state(SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK)
	_tick(_released_slap(), false)
	for _i: int in 64:
		if _sm.get_state() != SkaterStateMachine.State.ONE_TIMER_RETENTION:
			break
		_tick(_released_slap(), false)
	assert_eq(_sm.get_state(), SkaterStateMachine.State.FOLLOW_THROUGH,
			"a missed one-timer swings through empty air rather than snapping away")
	assert_eq(_sm.shot_dir, Vector3.ZERO, "with no shot line, the pose falls back to the locked aim")


# ── The carried one-timer (feed arrived mid-wind-up) ──────────────────────────

func test_carried_one_timer_holds_too() -> void:
	_sm.set_state(SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK)
	_aiming.one_timer_window_timer = 0.45
	_tick(_released_slap(), true)
	assert_eq(_sm.get_state(), SkaterStateMachine.State.ONE_TIMER_RETENTION,
			"an armed one-timer window routes through the hold")
	assert_eq(_slapper_releases, 0, "the shot does not leave on the button edge")


func test_a_plain_carried_slapshot_still_fires_on_the_edge() -> void:
	# No window armed = this was never a one-timer, just a slapshot from carry.
	# It must keep firing the instant the button comes up.
	_sm.set_state(SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK)
	_tick(_released_slap(), true)
	assert_eq(_slapper_releases, 1, "a plain slapshot releases immediately")
	assert_eq(_retention_entries, 0, "and never enters the one-timer hold")
	assert_eq(_sm.get_state(), SkaterStateMachine.State.FOLLOW_THROUGH)


func test_expired_window_still_cancels_back_to_carry() -> void:
	_sm.set_state(SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK)
	_aiming.one_timer_window_timer = TICK * 0.5
	_tick(_held_slap(), true)
	assert_eq(_sm.get_state(), SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK,
			"the cancel path routes through transition_to_skating, not the hold")
	assert_eq(_retention_entries, 0, "a lapsed window never arms the hold")
