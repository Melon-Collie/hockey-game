class_name SkaterAgent
extends RefCounted

# Per-bot decision loop. Owned by AIController. Owns the InputState scratch
# buffer and forwards to a SkaterAgentStateMachine that holds the actual
# transition logic + per-state behavior. Mirrors the SkaterController /
# SkaterStateMachine pairing — controller does glue, state machine owns
# the decision graph.

var _scratch_input: InputState = InputState.new()
var _sm: SkaterAgentStateMachine = SkaterAgentStateMachine.new()


func setup(peer_id: int, team_id: int, brain: TeamBrain, team_id_by_peer: Dictionary,
		is_left_handed: bool, caps_by_peer: Dictionary = {}) -> void:
	_sm.setup(peer_id, team_id, brain, team_id_by_peer, is_left_handed, caps_by_peer)


# Apply a difficulty skill profile. Called by AIController.setup_agent right
# after setup(), before the first tick. Forwards the execution knobs to the
# state machine; the perception-delay knob is consumed globally by GameManager,
# not here. Null leaves the perfect-bot defaults in place (back-compat).
func apply_profile(profile: BotSkillProfile) -> void:
	if profile == null:
		return
	_sm.apply_profile(profile)


# Forward this bot's attribute-scaled self-capabilities (speed, accel, reach,
# shot / pass speed) to the state machine. Called by AIController.apply_attributes
# on spawn and on free-play picker changes. Null is a no-op (baseline defaults).
func apply_capabilities(caps: AISkaterCaps) -> void:
	_sm.apply_capabilities(caps)


# Returns the InputState for this physics tick. Caller must not retain a
# reference past the next tick — same scratch buffer is reused.
# The SM's cursor goes out untouched: its slew (the bot's real Hands blade
# speed) is the one motion limit, exactly the limit a human's blade plays
# under. An old second-stage exponential lerp here was removed — it added
# only milliseconds of lag but its straight-line world blending chord-cut
# the SM's carefully shaped cursor paths (arc / reach-cone clamp) across the
# body on big flips, which could trip the pose IK gate's facing freeze.
func tick(snapshot: WorldSnapshot, delta: float, host_timestamp: float) -> InputState:
	_zero_input(_scratch_input, delta, host_timestamp)
	_sm.dispatch(_scratch_input, snapshot)
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
	# The wrister is the only shot type now.
	return _sm.debug_shoot_score


func debug_shoot_label() -> String:
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
	# Hit commit defaults off every tick (reused scratch): only the body-check
	# commit branch sets it, so a leaked true would keep a bot bracing / draining
	# stamina after the check is over.
	input.hit_held = false
	# Fire-once edge: PASS_PRESSED's one-tick release path (the dump) sets it on its
	# release tick and nothing else clears it, so a latched true would fire an
	# instant quick shot on every subsequent carry tick.
	input.quick_shot_pressed = false
