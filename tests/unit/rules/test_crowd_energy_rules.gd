extends GutTest

# CrowdEnergyRules — the live crowd-energy read behind the ambient bed.
#
# The load-bearing test here is the first one: the scale's two endpoints are
# XGBaseline's own log-odds at a point shot and a shot from the top of the
# crease, written out as constants so the per-frame read costs no logs. If the
# xG model is ever recalibrated, that pin fails rather than the building
# silently rescaling.

const _EPS: float = 1.0e-3


# Distance `d` straight out from the goal a team is attacking.
func _straight_on(d: float, team_id: int) -> Vector2:
	var goal_z: float = XGBaseline.attacking_goal_z(team_id)
	return Vector2(0.0, goal_z + d if team_id == 0 else goal_z - d)


func test_scale_endpoints_match_the_xg_model() -> void:
	for team_id: int in [0, 1]:
		var quiet: Vector2 = _straight_on(CrowdEnergyRules.QUIET_DISTANCE_M, team_id)
		var roar: Vector2 = _straight_on(CrowdEnergyRules.ROAR_DISTANCE_M, team_id)
		assert_almost_eq(XGBaseline.logit_for_shot(
						quiet.x, quiet.y, team_id, ShotEvent.ShotType.SHOT),
				CrowdEnergyRules.QUIET_LOGIT, _EPS,
				"QUIET_LOGIT no longer matches XGBaseline at %.0f m" % [
						CrowdEnergyRules.QUIET_DISTANCE_M])
		assert_almost_eq(XGBaseline.logit_for_shot(
						roar.x, roar.y, team_id, ShotEvent.ShotType.SHOT),
				CrowdEnergyRules.ROAR_LOGIT, _EPS,
				"ROAR_LOGIT no longer matches XGBaseline at %.0f m" % [
						CrowdEnergyRules.ROAR_DISTANCE_M])


func test_the_threatened_end_is_the_nearer_one() -> void:
	# Team 0 attacks -Z, so the -Z half is the half team 0 threatens.
	assert_eq(CrowdEnergyRules.threatening_team(-20.0), 0)
	assert_eq(CrowdEnergyRules.threatening_team(20.0), 1)


func test_chance_rises_as_the_puck_closes_on_the_net() -> void:
	var last: float = -1.0
	for d: float in [22.0, 20.0, 15.0, 10.0, 6.0, 3.0, 1.0]:
		var at: Vector2 = _straight_on(d, 1)
		var c: float = CrowdEnergyRules.chance(at.x, at.y, 1)
		assert_gte(c, last, "chance fell moving from further out to %.0f m" % d)
		last = c
	assert_almost_eq(last, 1.0, _EPS, "the top of the crease is not full roar")


func test_the_scale_bottoms_out_at_the_point_and_tops_out_in_tight() -> void:
	var point: Vector2 = _straight_on(CrowdEnergyRules.QUIET_DISTANCE_M, 1)
	assert_almost_eq(CrowdEnergyRules.chance(point.x, point.y, 1), 0.0, _EPS)
	var crease: Vector2 = _straight_on(CrowdEnergyRules.ROAR_DISTANCE_M, 1)
	assert_almost_eq(CrowdEnergyRules.chance(crease.x, crease.y, 1), 1.0, _EPS)


func test_a_sharp_angle_is_quieter_than_the_same_distance_straight_on() -> void:
	var goal_z: float = XGBaseline.attacking_goal_z(1)
	var straight: float = CrowdEnergyRules.chance(0.0, goal_z - 8.0, 1)
	# Same 8 m, swung out to 60 degrees off the centre line.
	var wide: float = CrowdEnergyRules.chance(
			8.0 * sin(deg_to_rad(60.0)), goal_z - 8.0 * cos(deg_to_rad(60.0)), 1)
	assert_lt(wide, straight)


func test_who_has_the_puck_scales_the_same_look() -> void:
	var slot: Vector2 = _straight_on(6.0, 1)
	var attacking: float = CrowdEnergyRules.chance(slot.x, slot.y, 1)
	var loose: float = CrowdEnergyRules.chance(slot.x, slot.y, -1)
	var defending: float = CrowdEnergyRules.chance(slot.x, slot.y, 0)
	assert_gt(attacking, loose, "an owned chance beats a scramble")
	assert_gt(loose, defending, "a scramble in the slot beats a breakout")
	assert_gt(defending, 0.0, "a puck in one's own slot is never dead quiet")


func test_behind_the_goal_line_is_its_own_quieter_regime() -> void:
	var goal_z: float = XGBaseline.attacking_goal_z(1)
	var mouth: float = CrowdEnergyRules.chance(0.0, goal_z - 0.5, 1)
	var behind: float = CrowdEnergyRules.chance(0.0, goal_z + 1.0, 1)
	assert_almost_eq(mouth, 1.0, _EPS, "the goal mouth is not full roar")
	assert_almost_eq(behind, CrowdEnergyRules.BEHIND_NET_CHANCE, _EPS,
			"a puck behind the net reads off the front-of-net model")


func test_pressure_needs_the_attacking_team_holding_it_in_the_zone() -> void:
	var deep: float = GameRules.BLUE_LINE_Z + 5.0
	assert_true(CrowdEnergyRules.is_sustaining_pressure(deep, 1),
			"team 1 carrying deep in its attacking zone is pressure")
	assert_false(CrowdEnergyRules.is_sustaining_pressure(deep, 0),
			"the team defending that end holding it is a breakout, not pressure")
	assert_false(CrowdEnergyRules.is_sustaining_pressure(deep, -1),
			"a loose puck is not sustained possession")
	assert_false(CrowdEnergyRules.is_sustaining_pressure(GameRules.BLUE_LINE_Z - 1.0, 1),
			"the neutral zone is not the attacking zone")


func test_pressure_builds_slower_than_it_is_worth_and_fades_after() -> void:
	var p: float = 0.0
	for i: int in 60:  # one second at 60 fps
		p = CrowdEnergyRules.advance_pressure(p, true, 1.0 / 60.0)
	assert_lt(p, 0.25, "a single second of zone time should not be a full cycle")
	var held: float = p
	for i: int in 600:  # ten seconds
		p = CrowdEnergyRules.advance_pressure(p, true, 1.0 / 60.0)
	assert_gt(p, 0.75, "ten seconds of sustained pressure should be most of it")
	for i: int in 600:
		p = CrowdEnergyRules.advance_pressure(p, false, 1.0 / 60.0)
	assert_lt(p, held, "pressure must fade once the zone is cleared")


func test_energy_rises_faster_than_it_falls() -> void:
	var dt: float = 1.0 / 60.0
	var up: float = CrowdEnergyRules.advance_energy(0.0, 1.0, dt)
	var down: float = 1.0 - CrowdEnergyRules.advance_energy(1.0, 0.0, dt)
	assert_gt(up, down, "the crowd must jump to a chance and settle off one")


func test_the_envelope_is_frame_rate_independent() -> void:
	var coarse: float = CrowdEnergyRules.advance_energy(0.0, 1.0, 0.1)
	var fine: float = 0.0
	for i: int in 10:
		fine = CrowdEnergyRules.advance_energy(fine, 1.0, 0.01)
	assert_almost_eq(fine, coarse, 1.0e-2,
			"one 100 ms step and ten 10 ms steps must land in the same place")


func test_the_two_sources_do_not_stack() -> void:
	var full_cycle: float = CrowdEnergyRules.target_energy(0.0, 1.0)
	assert_almost_eq(full_cycle, CrowdEnergyRules.PRESSURE_CEILING, _EPS,
			"zone time alone is capped below a real look")
	assert_almost_eq(CrowdEnergyRules.target_energy(1.0, 1.0), 1.0, _EPS,
			"a slot chance during a cycle is one moment, not two summed")
	assert_almost_eq(CrowdEnergyRules.target_energy(0.2, 1.0), full_cycle, _EPS,
			"the louder source wins")
