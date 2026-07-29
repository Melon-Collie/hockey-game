extends GutTest

# DUMP release aim — does the puck leave the stick on the line the dump was
# scored for?
#
# `_best_dump` picks a world spot and the state machine fires at it through the
# ONE-TICK quick release (`_state_pass_pressed`'s `not _pass_should_charge`
# branch). Every EV term in the dump — chase_recovery, turnover_cost,
# position_potential — is evaluated at that spot, so a release that leaves on a
# different line makes the whole decision meaningless: the bot prices a rim up
# the strong-side wall and fires somewhere else entirely.
#
# Two properties of the cursor handed to the controller on the firing tick are
# load-bearing, because `ShotMechanics.release_wrister(is_quick_pass = true)`
# takes its direction as blade→cursor and the blade is itself the ROM-projection
# of that same cursor (SkaterIKCoordinator.apply_blade_from_mouse resolves
# `last_target_blade_world` from `input.mouse_world_pos` on the same tick):
#
#   DIRECTION — the cursor must sit on the line from the bot to the dump spot.
#   CONDITIONING — it must sit far enough out that blade→cursor is a well-defined
#     direction at all. A cursor inside the stick's reach projects to ~itself, so
#     the difference degenerates toward the blade's lateral carry offset and
#     carries no information about where the bot meant to put the puck.
#
# The state machine's own `_aim_ring_toward` doc asserts distance doesn't matter
# ("the shot direction at fire time depends on (mouse - shoulder) or
# (mouse - blade), which is a unit direction") — true for the CHARGED wrister,
# false for the quick-pass path, which is the only path a dump takes.
#
# These are pinned across a sweep of carry-cursor offsets because the cursor's
# starting point is not incidental: a dump commits when `retention_hopeless`,
# i.e. under pressure, which is exactly when the carrier's protect swing has
# pushed the carry cursor furthest off the forward line.

const Agent := preload("res://Scripts/ai/skater_agent_state_machine.gd")

const SELF_ID := 1
const TEAMMATE_ID := 2
const OPP_ID := 11
var _team_map := {1: 0, 2: 0, 11: 1, 12: 1}

# Tolerance on the release line. The tier's own execution error is a SEPARATE,
# deliberate quantity (`_pass_aim_error_rad`, zeroed below) — anything left over
# is geometry the bot never chose, so this is tight on purpose.
const AIM_TOLERANCE_DEG: float = 5.0

# Minimum cursor stand-off for a well-conditioned blade→cursor direction: the
# blade reach the bot's own carry ring is sized against, plus a margin. Inside
# this the ROM projection puts the blade essentially on the cursor.
const MIN_CURSOR_STANDOFF_M: float = 2.5

var sm: SkaterAgentStateMachine


func before_each() -> void:
	sm = Agent.new()
	sm.setup(SELF_ID, 0, TeamBrain.new(0, _team_map), _team_map, false)
	# Zero the tier's committed execution error so the measurement is pure
	# geometry. Any angle left is the bug, not the difficulty budget.
	sm._pass_aim_error_rad = 0.0
	sm._committed_aim_error_rad = 0.0


# ── Fixture ──────────────────────────────────────────────────────────────────
# Team 0 defends +z, so a carrier deep in its own end is at +z and its clear
# runs toward centre ice. This mirrors the live DZ geometry `dump_clear_target`
# is written against (strong-side wall, z = 0).

const SELF_POS := Vector3(2.0, 0.0, 22.0)
const DUMP_SPOT := Vector3(12.5, 0.0, 0.0)


func _snapshot(self_pos: Vector3) -> WorldSnapshot:
	var s := WorldSnapshot.new()
	s.puck_state = PuckNetworkState.new()
	s.puck_state.position = self_pos
	s.puck_state.carrier_peer_id = SELF_ID
	s.real_puck_carrier_peer_id = SELF_ID
	_add_skater(s, SELF_ID, self_pos)
	_add_skater(s, TEAMMATE_ID, Vector3(-6.0, 0.0, 14.0))
	_add_skater(s, OPP_ID, Vector3(3.5, 0.0, 20.0))
	return s


func _add_skater(s: WorldSnapshot, peer_id: int, pos: Vector3) -> void:
	var st := SkaterNetworkState.new()
	st.position = pos
	st.velocity = Vector3.ZERO
	s.skater_states[peer_id] = st


# Runs the firing tick of a committed DUMP with the carry cursor parked
# `offset_deg` off the dump line at the carry aim ring, and returns the
# InputState the controller would receive.
#
# `offset_deg` stands in for where the carry left the cursor: 0 = presented
# straight down the dump line (the best case the bot ever gets), larger angles =
# the protect swing holding the puck off to the hip, which is the state a
# pressured carrier — the only kind that dumps — is actually in.
func _fire_dump(offset_deg: float) -> InputState:
	var snapshot: WorldSnapshot = _snapshot(SELF_POS)
	var input := InputState.new()

	# Park the cursor on the carry aim ring, rotated off the dump line.
	var to_spot: Vector3 = (DUMP_SPOT - SELF_POS).normalized()
	var ring_dir: Vector3 = to_spot.rotated(Vector3.UP, deg_to_rad(offset_deg))
	sm._mouse_pos = SELF_POS + ring_dir * Agent.CARRY_BLADE_AIM_FORWARD_M
	sm._mouse_pos.y = 0.0
	sm._mouse_pos_initialized = true
	# _step_mouse_internal shapes against these (cached each dispatch live).
	sm._current_self_pos = SELF_POS
	sm._current_self_state = snapshot.skater_states[SELF_ID]

	# A committed DUMP, exactly as _state_carry hands it over: the target is
	# frozen, the receiver cleared, and the charge suppressed.
	sm._dump_target = DUMP_SPOT
	sm._dump_is_soft = false
	sm._dump_is_rim = false
	sm._pass_should_charge = false
	sm._pass_should_saucer = false
	sm._pass_target_peer_id = -1
	sm._state = Agent.State.PASS_PRESSED

	sm._state_pass_pressed(input, snapshot, SELF_POS, true)
	return input


func _release_angle_error_deg(input: InputState) -> float:
	var intended := Vector2(DUMP_SPOT.x - SELF_POS.x, DUMP_SPOT.z - SELF_POS.z)
	var actual := Vector2(
			input.mouse_world_pos.x - SELF_POS.x,
			input.mouse_world_pos.z - SELF_POS.z)
	return rad_to_deg(absf(intended.angle_to(actual)))


# ── The release actually fires on this tick ──────────────────────────────────
# Guards the rest of the file: if the dump ever stops being a one-tick release,
# these measurements are of nothing and the assertions below must be revisited
# rather than re-pinned.

func test_dump_fires_a_one_tick_quick_release() -> void:
	var input: InputState = _fire_dump(0.0)
	assert_true(input.quick_pass_pressed,
			"a dump releases on the same tick PASS_PRESSED is entered")


# ── DIRECTION ────────────────────────────────────────────────────────────────

func test_dump_leaves_on_the_line_it_was_scored_for() -> void:
	# The cleanest case available: the carry cursor already sits on the dump
	# line, so nothing but the release itself can bend it.
	var input: InputState = _fire_dump(0.0)
	assert_lt(_release_angle_error_deg(input), AIM_TOLERANCE_DEG,
			"a dump aimed straight ahead leaves on its scored line")


func test_dump_line_survives_the_protect_swing() -> void:
	# The real case. A dump commits under pressure, which is when the carry
	# cursor is furthest off the forward line — so the release must not inherit
	# where the carry happened to be holding the puck.
	for offset_deg: float in [30.0, 60.0, 90.0, 120.0]:
		var input: InputState = _fire_dump(offset_deg)
		var err: float = _release_angle_error_deg(input)
		assert_lt(err, AIM_TOLERANCE_DEG,
				"carry cursor %d deg off the dump line: release missed by %.1f deg"
					% [int(offset_deg), err])


func test_dump_line_is_independent_of_which_way_the_puck_was_held() -> void:
	# Direction-of-swing invariance. Mirrored protect offsets must not pull the
	# release to opposite sides of the scored line — that spread is what turns
	# one dump target into a scatter of outcomes across a game.
	var left: float = _release_angle_error_deg(_fire_dump(75.0))
	var right: float = _release_angle_error_deg(_fire_dump(-75.0))
	assert_almost_eq(left, right, 1.0,
			"a dump's accuracy does not depend on which hip the puck was on")


# ── CONDITIONING ─────────────────────────────────────────────────────────────

func test_dump_cursor_stands_off_far_enough_to_define_a_direction() -> void:
	# blade→cursor is the quick pass's direction (ShotMechanics.release_wrister,
	# is_quick_pass branch) and the blade is the ROM-projection of this same
	# cursor. A cursor inside the stick's reach collapses that difference onto
	# the blade's lateral carry offset, so the release direction stops depending
	# on the dump target at all — no matter how correct the cursor's ANGLE is.
	for offset_deg: float in [0.0, 60.0, 120.0]:
		var input: InputState = _fire_dump(offset_deg)
		var standoff: float = Vector2(
				input.mouse_world_pos.x - SELF_POS.x,
				input.mouse_world_pos.z - SELF_POS.z).length()
		assert_gt(standoff, MIN_CURSOR_STANDOFF_M,
				"carry cursor %d deg off: cursor only %.2f m out, blade->cursor is degenerate"
					% [int(offset_deg), standoff])
