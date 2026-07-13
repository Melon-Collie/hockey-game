class_name AIPingDirectives
extends RefCounted

# Live smart-ping directives for one team's bots — the host-side "obey the
# ping" bookkeeping. Owned by TeamBrain (same host-only, never-networked shape
# as its one-timer-ready dict); consumed two ways:
#
#   - Slot / threat overrides (apply_overrides): COVER_HIM pins the obeying
#     bot onto the pinged opponent (MARK + a forced threat assignment, the
#     same shape as AIThreatAssignment's house pin), PRESSURE_CARRIER forces
#     the obeyer onto the carrier, GET_OPEN sends it to the scoring-threat
#     slot, DEFEND drops it into man coverage. Applied by TeamBrain after
#     each slot-assignment tick, so the directive rides the existing role
#     architecture instead of bypassing it.
#   - Per-bot queries (move_target_for / chase_peer / shoot_ping_for /
#     pass_target_for): read every AI dispatch by SkaterAgentStateMachine /
#     AIRoleCarrier through RoleContext, so obedience is frame-tight while
#     the directive lives.
#
# One live directive per pinger — a fresh ping replaces that player's
# previous order. Time is an internal clock advanced by TeamBrain.tick's
# delta (never wall clock), so the class stays deterministic and
# GUT-testable: tests/unit/ai/test_ping_directives.gd.

class Directive:
	extends RefCounted
	var type: int = PingRules.Type.GO_THERE
	var pinger_peer: int = -1
	var target_peer: int = -1
	# The bot elected to obey (PingRules.choose_obeyer), -1 when the ping
	# applies situationally (PASS_TO_ME / IM_OPEN bias whichever bot carries).
	var obeyer_peer: int = -1
	var world_pos: Vector3 = Vector3.ZERO
	var expires_at: float = 0.0


# pinger_peer -> Directive (plain Dictionary; values read via typed for-loops)
var _by_pinger: Dictionary = {}
var _clock: float = 0.0


# Advance the internal clock and drop expired directives. Called once per
# host physics frame from TeamBrain.tick (before its rate-limit gate).
func advance(delta: float) -> void:
	_clock += delta
	if _by_pinger.is_empty():
		return
	for pinger: int in _by_pinger.keys():
		if _by_pinger[pinger].expires_at <= _clock:
			_by_pinger.erase(pinger)


func add(type: int, pinger_peer: int, target_peer: int, obeyer_peer: int,
		world_pos: Vector3, duration_s: float) -> void:
	var d := Directive.new()
	d.type = type
	d.pinger_peer = pinger_peer
	d.target_peer = target_peer
	d.obeyer_peer = obeyer_peer
	d.world_pos = world_pos
	d.expires_at = _clock + duration_s
	_by_pinger[pinger_peer] = d


func clear() -> void:
	_by_pinger.clear()


func is_empty() -> bool:
	return _by_pinger.is_empty()


# Force-slot the obeying bots after AIRoleSlots.assign. Mutates the brain's
# live dictionaries in place (both are Dictionary[int, int]). The current
# carrier is never overridden — it is playing the puck.
func apply_overrides(slot_assignments: Dictionary,
		threat_assignments: Dictionary, carrier_peer_id: int) -> void:
	if _by_pinger.is_empty():
		return
	for d: Directive in _by_pinger.values():
		var obeyer: int = d.obeyer_peer
		if obeyer == -1 or obeyer == carrier_peer_id:
			continue
		match d.type:
			PingRules.Type.COVER_HIM:
				slot_assignments[obeyer] = AIRoleSlots.Slot.MARK
				threat_assignments[obeyer] = d.target_peer
			PingRules.Type.DEFEND:
				slot_assignments[obeyer] = AIRoleSlots.Slot.MARK
			PingRules.Type.PRESSURE_CARRIER:
				slot_assignments[obeyer] = AIRoleSlots.Slot.PRESSURE
			PingRules.Type.GET_OPEN:
				slot_assignments[obeyer] = AIRoleSlots.Slot.FINISHER


# GO_THERE steering override for a bot, Vector3.INF when none. The off-puck
# state machine replaces its RoleDecision.target_position with this.
func move_target_for(peer_id: int) -> Vector3:
	if _by_pinger.is_empty():
		return Vector3.INF
	for d: Directive in _by_pinger.values():
		if d.type == PingRules.Type.GO_THERE and d.obeyer_peer == peer_id:
			return d.world_pos
	return Vector3.INF


# The bot ordered to retrieve a loose puck (GET_PUCK), -1 when none. Overrides
# the natural chase election AND the race-lost decline — an order is an order.
func chase_peer() -> int:
	if _by_pinger.is_empty():
		return -1
	for d: Directive in _by_pinger.values():
		if d.type == PingRules.Type.GET_PUCK and d.obeyer_peer != -1:
			return d.obeyer_peer
	return -1


# True while a SHOOT ping is live on this bot (it was carrying when pinged).
func shoot_ping_for(peer_id: int) -> bool:
	if _by_pinger.is_empty():
		return false
	for d: Directive in _by_pinger.values():
		if d.type == PingRules.Type.SHOOT and d.target_peer == peer_id:
			return true
	return false


# The teammate a live PASS_TO_ME / IM_OPEN ping asks the carrying bot to
# feed, -1 when none. `carrier_peer_id` is the bot asking — its own ping (it
# can't pass to itself) never matches. First live match wins; simultaneous
# pings from two humans within one cooldown window are a non-problem.
func pass_target_for(carrier_peer_id: int) -> int:
	if _by_pinger.is_empty():
		return -1
	for d: Directive in _by_pinger.values():
		if (d.type == PingRules.Type.PASS_TO_ME or d.type == PingRules.Type.IM_OPEN) \
				and d.pinger_peer != carrier_peer_id:
			return d.pinger_peer
	return -1
