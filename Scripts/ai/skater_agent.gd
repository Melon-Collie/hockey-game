class_name SkaterAgent
extends RefCounted

# Per-bot decision loop. Owned by AIController. Owns the InputState scratch
# buffer and forwards to a SkaterAgentStateMachine that holds the actual
# transition logic + per-state behavior. Mirrors the SkaterController /
# SkaterStateMachine pairing — controller does glue, state machine owns
# the decision graph.

var _scratch_input: InputState = InputState.new()
var _sm: SkaterAgentStateMachine = SkaterAgentStateMachine.new()

# Mouse-world lerp factor — closes this fraction of the gap toward the
# SM's desired mouse_world_pos each tick. 1.0 = snap (no smoothing).
# Lower values add tracking lag: the blade lags slightly behind its target,
# dekes don't immediately get matched, and aim transitions read as a smooth
# swing rather than a snap. A second-stage softener on top of the state
# machine's blade-slew cap (BotSkillProfile.mouse_max_speed_m_s) — that cap
# does the heavy lifting; this is the exponential polish.
#
# DEFAULT is the perfect-bot baseline (1.0 = snap); the real per-tier value is
# set from BotSkillProfile in apply_profile(). Difficulty tuning has landed.
const MOUSE_LERP_FACTOR_DEFAULT: float = 1.0
var _mouse_lerp_factor: float = MOUSE_LERP_FACTOR_DEFAULT
var _prev_mouse_world_pos: Vector3 = Vector3.ZERO
var _has_prev_mouse: bool = false


func setup(peer_id: int, team_id: int, brain: TeamBrain, team_id_by_peer: Dictionary,
		is_left_handed: bool) -> void:
	_sm.setup(peer_id, team_id, brain, team_id_by_peer, is_left_handed)


# Apply a difficulty skill profile. Called by AIController.setup_agent right
# after setup(), before the first tick. Forwards the execution knobs to the
# state machine; the perception-delay knob is consumed globally by GameManager,
# not here. Null leaves the perfect-bot defaults in place (back-compat).
func apply_profile(profile: BotSkillProfile) -> void:
	if profile == null:
		return
	_mouse_lerp_factor = profile.mouse_lerp_factor
	_sm.apply_profile(profile)


func set_max_wrister_charge_distance(d: float) -> void:
	_sm.set_max_wrister_charge_distance(d)


# Forward this bot's attribute-scaled self-capabilities (speed, accel, reach,
# shot / pass speed) to the state machine. Called by AIController.apply_attributes
# on spawn and on free-play picker changes. Null is a no-op (baseline defaults).
func apply_capabilities(caps: AISelfCapabilities) -> void:
	_sm.apply_capabilities(caps)


# Returns the InputState for this physics tick. Caller must not retain a
# reference past the next tick — same scratch buffer is reused.
func tick(snapshot: WorldSnapshot, delta: float, host_timestamp: float) -> InputState:
	_zero_input(_scratch_input, delta, host_timestamp)
	_sm.dispatch(_scratch_input, snapshot)
	# Lerp the SM's desired mouse_world_pos so the blade always lags a
	# bit behind. Skipped on the first ever tick (no prev to lerp from)
	# and after any tick where the SM left mouse at ZERO (state didn't
	# explicitly aim — don't drag a stale lag value into a subsequent
	# real aim). Also skipped while aiming a committed shot: the SM cursor
	# is already slew-smoothed there, and the second-stage lerp on top
	# makes the blade ring through the wind-up (see wants_direct_aim).
	if _has_prev_mouse and _scratch_input.mouse_world_pos != Vector3.ZERO \
			and not _sm.wants_direct_aim():
		_scratch_input.mouse_world_pos = _prev_mouse_world_pos.lerp(
				_scratch_input.mouse_world_pos, _mouse_lerp_factor)
	_prev_mouse_world_pos = _scratch_input.mouse_world_pos
	_has_prev_mouse = _scratch_input.mouse_world_pos != Vector3.ZERO
	return _scratch_input


func get_state() -> SkaterAgentStateMachine.State:
	return _sm.get_state()


# ── Debug accessors ───────────────────────────────────────────────────────────
# Read by AIController to populate the floating per-bot debug label.

func debug_state_name() -> String:
	return SkaterAgentStateMachine.State.keys()[_sm.get_state()]


func debug_role() -> String:
	return _sm.debug_role()


func debug_last_decision() -> String:
	return _sm.debug_last_decision


func debug_shoot_score() -> float:
	# Show whichever of wrister/quick-shot the carrier is currently
	# leaning on. Matches the tie-break in AIRoleCarrier._pick_action
	# (wrister wins ties, quick must beat wrister by the hysteresis
	# fraction).
	if _sm.debug_quick_shot_score > _sm.debug_shoot_score \
			* (1.0 + AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC):
		return _sm.debug_quick_shot_score
	return _sm.debug_shoot_score


func debug_shoot_label() -> String:
	if _sm.debug_quick_shot_score > _sm.debug_shoot_score \
			* (1.0 + AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC):
		return "QUICK"
	return "SHOOT"


func debug_pass_score() -> float:
	return _sm.debug_pass_score


func debug_pass_slot() -> String:
	return _sm.debug_pass_slot()


func debug_carry_score() -> float:
	return _sm.debug_carry_score


func debug_carry_dir(snapshot: WorldSnapshot) -> String:
	if snapshot == null or not snapshot.skater_states.has(_sm._peer_id):
		return "—"
	return _sm.debug_carry_dir(snapshot.skater_states[_sm._peer_id].position)


func debug_winner() -> String:
	return _sm.debug_winner()


func debug_intent() -> String:
	return _sm.debug_intent()


func _zero_input(input: InputState, delta: float, host_timestamp: float) -> void:
	input.delta = delta
	input.host_timestamp = host_timestamp
	input.move_vector = Vector2.ZERO
	input.mouse_world_pos = Vector3.ZERO
	input.mouse_screen_pos = Vector2.ZERO
	input.shoot_pressed = false
	input.shoot_held = false
	input.slap_pressed = false
	input.slap_held = false
	input.brake = false
	# Sprint defaults off every tick. The scratch buffer is reused, so a state
	# that set sprint_held last tick would otherwise leak it into a state that
	# doesn't touch it (e.g. a press state). The SM re-decides it each full
	# dispatch via _resolve_sprint and restores the cache on throttled ticks.
	input.sprint_held = false
	# Loft defaults flat every tick — the level is absolute per input frame
	# (no sticky controller state), so press states just set the level they
	# want on the ticks they want it.
	input.elevation_level = 0
	input.block_held = false
	input.stick_lift_held = false
	# Fire-once edge: PASS_PRESSED / QUICK_SHOT_PRESSED set it on their release
	# tick and nothing else clears it, so a latched true would fire an instant
	# quick shot on every subsequent carry tick.
	input.quick_shot_pressed = false
