extends GutTest

# AIPingDirectives — the host-side "obey the ping" store: expiry on the
# internal clock, per-pinger replacement, slot/threat overrides, and the
# per-bot queries the state machine / carrier read through RoleContext.

const PINGER: int = 1
const BOT_A: int = 10000
const BOT_B: int = 10001
const OPP: int = 3

var _d: AIPingDirectives


func before_each() -> void:
	_d = AIPingDirectives.new()


func test_starts_empty() -> void:
	assert_true(_d.is_empty())
	assert_eq(_d.move_target_for(BOT_A), Vector3.INF)
	assert_eq(_d.chase_peer(), -1)
	assert_false(_d.shoot_ping_for(BOT_A))
	assert_eq(_d.pass_target_for(BOT_A), -1)


func test_go_there_move_target_is_scoped_to_the_obeyer() -> void:
	var spot := Vector3(4.0, 0.0, -6.0)
	_d.add(PingRules.Type.GO_THERE, PINGER, -1, BOT_A, spot, 5.0)
	assert_eq(_d.move_target_for(BOT_A), spot)
	assert_eq(_d.move_target_for(BOT_B), Vector3.INF)


func test_directive_expires_on_the_internal_clock() -> void:
	_d.add(PingRules.Type.GO_THERE, PINGER, -1, BOT_A, Vector3.ONE, 2.0)
	_d.advance(1.9)
	assert_eq(_d.move_target_for(BOT_A), Vector3.ONE)
	_d.advance(0.2)
	assert_true(_d.is_empty())
	assert_eq(_d.move_target_for(BOT_A), Vector3.INF)


func test_new_ping_from_same_pinger_replaces_the_old_order() -> void:
	_d.add(PingRules.Type.GO_THERE, PINGER, -1, BOT_A, Vector3.ONE, 5.0)
	_d.add(PingRules.Type.SHOOT, PINGER, BOT_B, BOT_B, Vector3.ZERO, 3.0)
	assert_eq(_d.move_target_for(BOT_A), Vector3.INF, "GO_THERE was replaced")
	assert_true(_d.shoot_ping_for(BOT_B))


func test_shoot_ping_matches_the_pinged_carrier_only() -> void:
	_d.add(PingRules.Type.SHOOT, PINGER, BOT_A, BOT_A, Vector3.ZERO, 3.0)
	assert_true(_d.shoot_ping_for(BOT_A))
	assert_false(_d.shoot_ping_for(BOT_B))


func test_pass_ping_feeds_any_carrier_except_the_pinger() -> void:
	_d.add(PingRules.Type.PASS_TO_ME, PINGER, PINGER, -1, Vector3.ZERO, 4.0)
	assert_eq(_d.pass_target_for(BOT_A), PINGER)
	assert_eq(_d.pass_target_for(PINGER), -1,
			"the pinger's own carry never passes to itself")


func test_chase_peer_reports_the_get_puck_obeyer() -> void:
	_d.add(PingRules.Type.GET_PUCK, PINGER, -1, BOT_B, Vector3.ZERO, 4.0)
	assert_eq(_d.chase_peer(), BOT_B)


# ── Slot / threat overrides ──────────────────────────────────────────────────

func test_cover_him_pins_mark_slot_and_threat() -> void:
	_d.add(PingRules.Type.COVER_HIM, PINGER, OPP, BOT_A, Vector3.ZERO, 6.0)
	var slots: Dictionary[int, int] = {BOT_A: AIRoleSlots.Slot.FINISHER}
	var threats: Dictionary[int, int] = {}
	_d.apply_overrides(slots, threats, -1)
	assert_eq(slots[BOT_A], AIRoleSlots.Slot.MARK)
	assert_eq(threats[BOT_A], OPP)


func test_pressure_and_get_open_and_defend_force_their_slots() -> void:
	_d.add(PingRules.Type.PRESSURE_CARRIER, PINGER, OPP, BOT_A, Vector3.ZERO, 5.0)
	_d.add(PingRules.Type.GET_OPEN, PINGER + 1, BOT_B, BOT_B, Vector3.ZERO, 4.0)
	var slots: Dictionary[int, int] = {}
	var threats: Dictionary[int, int] = {}
	_d.apply_overrides(slots, threats, -1)
	assert_eq(slots[BOT_A], AIRoleSlots.Slot.PRESSURE)
	assert_eq(slots[BOT_B], AIRoleSlots.Slot.FINISHER)

	_d.clear()
	_d.add(PingRules.Type.DEFEND, PINGER, BOT_A, BOT_A, Vector3.ZERO, 5.0)
	slots.clear()
	_d.apply_overrides(slots, threats, -1)
	assert_eq(slots[BOT_A], AIRoleSlots.Slot.MARK)


func test_overrides_never_touch_the_current_carrier() -> void:
	_d.add(PingRules.Type.GET_OPEN, PINGER, BOT_A, BOT_A, Vector3.ZERO, 4.0)
	var slots: Dictionary[int, int] = {BOT_A: AIRoleSlots.Slot.CARRIER}
	var threats: Dictionary[int, int] = {}
	_d.apply_overrides(slots, threats, BOT_A)
	assert_eq(slots[BOT_A], AIRoleSlots.Slot.CARRIER,
			"the bot playing the puck keeps its role")


func test_go_there_applies_no_slot_override() -> void:
	_d.add(PingRules.Type.GO_THERE, PINGER, -1, BOT_A, Vector3.ONE, 5.0)
	var slots: Dictionary[int, int] = {BOT_A: AIRoleSlots.Slot.SUPPORT}
	var threats: Dictionary[int, int] = {}
	_d.apply_overrides(slots, threats, -1)
	assert_eq(slots[BOT_A], AIRoleSlots.Slot.SUPPORT,
			"GO_THERE only commandeers steering, not the role")
