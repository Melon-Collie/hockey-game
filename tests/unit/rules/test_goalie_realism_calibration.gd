extends GutTest

# Research-grounded calibration for the goalie model (docs/AUDIT_2026-07_
# GOALIE_REALISM.md). Each test pins a trigger or magnitude to a documented
# coaching doctrine or measured number from the audit's research — USA Hockey /
# Hockey Canada curricula, Clear Sight Analytics tracking, Panchuk & Vickers
# quiet-eye work, and the Brock University butterfly biomechanics study. The
# point is drift protection: if a tune moves the model outside what the
# research supports, the failing test names the doctrine being violated.
#
# Tests read the authored @export defaults off a fresh GoalieController (the
# HARD skill profile is these values verbatim, so this pins the realism
# ceiling; lower tiers deviate deliberately).


func _gc() -> GoalieController:
	var gc: GoalieController = autofree(GoalieController.new())
	return gc


# ── Positioning: the Buckley Positioning System (USA Hockey "ABCs of Depth") ──

func test_bps_depth_anchors_match_real_crease_geometry() -> void:
	# BPS (Mike Buckley / USA Hockey): B = heels on the crease top, C = middle
	# of the blue paint, A = above the crease top (taught "2 ft or more"; the
	# modern deep-vs-aggressive band starts just past the top), D = goal line.
	# The crease top is CreaseRules.STRAIGHT_DEPTH (1.37 m, regulation 4.5 ft).
	var gc: GoalieController = _gc()
	var crease_top: float = CreaseRules.STRAIGHT_DEPTH
	assert_between(gc.depth_base, crease_top - 0.2, crease_top + 0.1,
			"B depth = heels at the crease top")
	assert_between(gc.depth_conservative, 0.4, 0.9,
			"C depth = middle of the paint")
	assert_gt(gc.depth_aggressive, crease_top,
			"A depth challenges past the crease top")
	assert_lt(gc.depth_aggressive, crease_top + 0.7,
			"A depth stays inside the modern (post-challenge-era) band")
	assert_between(gc.depth_defensive, 0.0, 0.25,
			"D depth = on the goal line / post")


func test_long_range_depth_never_sinks_to_the_goal_line() -> void:
	# A puck far away IN FRONT leaves a real goalie resting in the paint
	# watching the play — D depth is behind-net/post play only (USA Hockey).
	var gc: GoalieController = _gc()
	var cfg := GoalieBehaviorRules.DepthConfig.new()
	cfg.zone_post_z = gc.zone_post_z
	cfg.zone_aggressive_z = gc.zone_aggressive_z
	cfg.zone_base_z = gc.zone_base_z
	cfg.zone_conservative_z = gc.zone_conservative_z
	cfg.depth_aggressive = gc.depth_aggressive
	cfg.depth_base = gc.depth_base
	cfg.depth_conservative = gc.depth_conservative
	cfg.depth_defensive = gc.depth_defensive
	var far: float = GoalieBehaviorRules.target_depth_for_puck_distance(35.0, cfg)
	assert_almost_eq(far, gc.depth_conservative, 0.001,
			"far-away puck in front → rest at conservative depth, not the goal line")


# ── Rush retreat: speed-matched backflow (USA Hockey / Edge Ice Academy) ──────

func test_rush_backflow_anchors_match_taught_timing() -> void:
	# Taught breakaway retreat: back at the crease edge as the shooter reaches
	# the hash marks, near the goal line as they reach the crease.
	var gc: GoalieController = _gc()
	var cfg := GoalieBehaviorRules.RushRetreatConfig.new()
	cfg.engage_distance = gc.rush_engage_distance
	cfg.mid_distance = gc.rush_mid_distance
	cfg.arrive_distance = gc.rush_arrive_distance
	cfg.depth_engage = gc.depth_aggressive
	cfg.depth_mid = gc.depth_base
	cfg.depth_arrive = gc.depth_defensive
	assert_almost_eq(
			GoalieBehaviorRules.rush_retreat_depth(gc.rush_mid_distance, cfg),
			gc.depth_base, 0.001,
			"attacker at the hash marks → goalie back at crease-top depth")
	assert_almost_eq(
			GoalieBehaviorRules.rush_retreat_depth(gc.rush_arrive_distance, cfg),
			gc.depth_defensive, 0.001,
			"attacker at the crease → goalie at goal-line depth")
	# Speed-matching: the retreat rate scales linearly with closing speed, so
	# the gap is a modeled read, not lerp lag.
	var slow: float = GoalieBehaviorRules.rush_retreat_rate(3.0, 2.0, cfg)
	var fast: float = GoalieBehaviorRules.rush_retreat_rate(3.0, 8.0, cfg)
	assert_almost_eq(fast, slow * 4.0, 0.0001, "retreat rate matches the rush's pace")


# ── Movement: measured / estimated kinematics ─────────────────────────────────

func test_butterfly_drop_time_in_measured_band_and_mirrored_to_bots() -> void:
	# Brock Univ. motion capture (Sports 10(6):96): pro butterfly drop velocity
	# 2.07 ± 0.09 m/s → ice seal ~0.2 s from commitment (band 0.15–0.40 s).
	var gc: GoalieController = _gc()
	assert_between(gc.butterfly_drop_speed, 0.15, 0.40,
			"drop time grounded on the measured 2.07 m/s drop velocity")
	assert_almost_eq(gc.butterfly_drop_speed, AIActionScoring.GOALIE_BUTTERFLY_DROP_S,
			0.0001, "bot shot model must mirror the live drop time")


func test_post_to_post_push_time_in_estimated_band() -> void:
	# No published NHL measurement exists; the research estimate is ~0.5–0.8 s
	# on feet for the 1.83 m post-to-post span, from rest. Closed-form from the
	# same accel-ramp model the live push and race math use.
	var gc: GoalieController = _gc()
	var span: float = 2.0 * GameRules.NET_HALF_WIDTH
	var t_ramp: float = gc.t_push_speed / gc.lateral_accel
	var d_ramp: float = 0.5 * gc.lateral_accel * t_ramp * t_ramp
	var t_total: float = t_ramp + (span - d_ramp) / gc.t_push_speed
	assert_between(t_total, 0.45, 0.90,
			"post-to-post from rest lands in the real ~0.5–0.8 s band")


func test_down_movement_tiers_are_ordered() -> void:
	# Real down movement is tiered (knee shuffle < slide) and down transit is
	# slower than skating (slide < T-push) — GoalieCoaches / Goalie Training Pro.
	var gc: GoalieController = _gc()
	assert_lt(gc.knee_shuffle_speed, gc.shuffle_speed,
			"knee shuffle is the slowest, smallest tier")
	assert_lt(gc.shuffle_speed, gc.slide_initial_speed,
			"a committed slide push beats shuffling")
	assert_lt(gc.slide_initial_speed, gc.t_push_speed,
			"down transit is slower than the on-feet T-push")


# ── Perception: reaction structure (quiet-eye / CSA / RT literature) ──────────

func test_read_latencies_ordered_prearm_legs_arms() -> void:
	# Blocking (legs) is pre-programmed and faster than the target-computed arm
	# reach; a primed (quiet-eye) read is faster than a cold one. Panchuk &
	# Vickers: response prepared during fixation, executed ballistically.
	var gc: GoalieController = _gc()
	assert_lt(gc.prearmed_reaction_delay, gc.reaction_delay,
			"a primed read beats a cold read")
	assert_true(gc.reaction_delay <= gc.arm_reaction_delay,
			"arms (where-in-the-net computation) never beat the reflexive legs")
	# CSA: ~0.5 s of clear, set sight is the performance threshold — the prime
	# requirement sits in that band.
	assert_between(gc.prearm_read_time, 0.25, 0.6,
			"priming requires a genuine sustained read (CSA clear-sight band)")


func test_point_blank_shots_sit_in_the_blocking_zone() -> void:
	# Coaching doctrine ("blocking vs reacting"): inside ~15 ft there is no
	# reactive save — an 85 mph shot from 4.6 m flies ~0.12 s, under the read +
	# drop time, so pre-committed blocking (jam seal, windup drop, screen drop)
	# is the only real answer. The model must NOT be able to reactively seal it.
	var gc: GoalieController = _gc()
	var flight: float = 4.6 / 38.0
	assert_lt(flight, gc.reaction_delay + gc.butterfly_drop_speed,
			"a point-blank shot beats read + drop — blocking territory")


func test_fully_screened_release_flips_to_blocking_drop() -> void:
	# Heinz / blocking doctrine: a release the goalie never sees gets a
	# committed blocking butterfly on the read — not a late reactive save. The
	# blocking timer runs the BASE leg read (no screen wait: he drops because
	# he can't see).
	var gc: GoalieController = _gc()
	gc._maybe_arm_screen_block_drop(gc.screen_max_extra_delay, 0.0, 0.0)
	assert_almost_eq(gc._screen_block_drop_timer, gc.reaction_delay, 0.001,
			"full occlusion arms the blocking drop at the base read")
	var gc2: GoalieController = _gc()
	gc2._maybe_arm_screen_block_drop(gc2.screen_max_extra_delay * 0.5, 0.0, 0.0)
	assert_lt(gc2._screen_block_drop_timer, 0.0,
			"a partial screen keeps the normal reactive read")


func test_lunge_is_a_committed_gamble() -> void:
	# Korn-family heuristic: a committed poke concedes ~2 goals per save when
	# missed — modeled as a fully-unset read while the jab is extended.
	var gc: GoalieController = _gc()
	gc._build_rule_configs()
	assert_almost_eq(gc._movement_read_delay(), 0.0, 0.0001,
			"a set goalie reads at the base delay")
	gc._lunge_active_timer = 0.1
	assert_almost_eq(gc._movement_read_delay(), gc.move_read_max_delay, 0.0001,
			"mid-lunge the goalie is out of the play — fully unset read")


func test_movement_penalty_is_additive_only() -> void:
	# CSA set-vs-unset: penalties only ever ADD read latency; a set goalie is
	# never buffed past the base read.
	var cfg := GoalieBehaviorRules.MovementReadConfig.new()
	cfg.reference_speed = 2.5
	cfg.max_delay = 0.12
	cfg.scramble_unset = 1.0
	assert_almost_eq(GoalieBehaviorRules.movement_read_penalty(0.0, false, cfg),
			0.0, 0.0001)
	assert_almost_eq(GoalieBehaviorRules.movement_read_penalty(99.0, false, cfg),
			cfg.max_delay, 0.0001, "penalty caps at max_delay")


func test_glove_speed_cap_in_human_hand_speed_band() -> void:
	# Boxing measures peak hand speed ~7–10 m/s; a flat (no-ramp) cap must sit
	# at the stroke average, below peak — the 3–6 m/s band.
	var gc: GoalieController = _gc()
	assert_between(gc.glove_react_max_speed, 3.0, 6.0)
	assert_between(gc.blocker_react_max_speed, 3.0, 6.0)


# ── Save selection: cross-crease and stay-down doctrine ───────────────────────

func test_royal_road_one_timer_beats_the_standing_push() -> void:
	# CSA royal road: the pass (~0.1–0.2 s) beats the push (~0.4–0.7 s); a
	# clean hard cross-crease one-timer must be unsaveable on the feet — the
	# model's answer is the pads-first slide, not a faster goalie.
	var gc: GoalieController = _gc()
	assert_true(GoalieBehaviorRules.cross_crease_race_lost(
			0.9, -2.1, 16.0, -0.8, gc.pad_local_offset,
			gc.backdoor_release_time, gc.t_push_speed, gc.lateral_accel),
			"a hard royal-road feed wins the race → drop and slide")
	assert_false(GoalieBehaviorRules.cross_crease_race_lost(
			0.9, -2.1, 6.0, -0.8, gc.pad_local_offset,
			gc.backdoor_release_time, gc.t_push_speed, gc.lateral_accel),
			"a slow telegraphed feed loses the race → stay on the feet")


func test_stay_down_window_is_about_two_stick_lengths() -> void:
	# Hockey Canada / coaching consensus: rebound in tight (inside ~2 stick
	# lengths) → stay down; farther → recover to feet immediately.
	var gc: GoalieController = _gc()
	assert_between(gc.recovery_proximity_threshold, 1.8, 3.2)


func test_jam_seal_only_for_slow_carriers() -> void:
	# Doctrine: seal the ice on a net-front battle, stay UP against a carrier
	# driving the net (force the release).
	var cfg := GoalieBehaviorRules.CreaseJamConfig.new()
	cfg.puck_distance = 2.0
	cfg.opponent_distance = 1.5
	cfg.carrier_max_speed = 3.0
	var puck := Vector3(0.0, 0.0, 25.5)
	var goalie := Vector3(0.0, 0.0, 26.4)
	assert_true(GoalieBehaviorRules.is_crease_jam(
			puck, goalie, 26.65, -1, true, 1.0, INF, cfg),
			"slow carrier jammed at the doorstep → seal")
	assert_false(GoalieBehaviorRules.is_crease_jam(
			puck, goalie, 26.65, -1, true, 6.0, INF, cfg),
			"fast carrier is ATTACKING → stay up, force the release")


# ── Post play: RVH discipline and the VH split ────────────────────────────────

func test_rvh_reserved_for_dead_angles() -> void:
	# Modern critique is RVH OVERUSE — post integration belongs at true dead
	# angles / behind the net, not "anytime the puck is below the circles"
	# (NHL.com "RVH under microscope"; Corchis).
	var gc: GoalieController = _gc()
	assert_gt(gc.rvh_early_angle, 60.0,
			"post integration only at true dead angles")
	var cfg := GoalieBehaviorRules.DefensiveZoneConfig.new()
	cfg.zone_post_z = gc.zone_post_z
	cfg.rvh_early_angle = gc.rvh_early_angle
	assert_true(GoalieBehaviorRules.is_puck_in_defensive_zone(
			Vector3(2.0, 0.0, 27.5), 26.65, 0.0, -1, cfg),
			"behind the goal line → post play")
	assert_false(GoalieBehaviorRules.is_puck_in_defensive_zone(
			Vector3(1.5, 0.0, 25.15), 26.65, 0.0, -1, cfg),
			"a 45-degree in-front look is a SHOT, not a post-hug situation")


func test_post_stance_families_cover_both_sides_of_the_goal_line() -> void:
	# Jake Allen / Woll doctrine: RVH at/below the goal line, VH for the
	# in-front sharp-angle shot threat (keeps short-side-high coverage).
	var sm := GoalieStateMachine.new()
	sm.current = GoalieStateMachine.State.RVH_LEFT
	assert_true(sm.is_post_integrated())
	assert_false(sm.is_vh())
	sm.current = GoalieStateMachine.State.VH_LEFT
	assert_true(sm.is_post_integrated())
	assert_true(sm.is_vh())
	assert_false(sm.is_down(),
			"VH is a post stance, not butterfly-family (no slide machinery)")
	assert_false(sm.is_upright(),
			"VH is committed to the post — not a drop-eligible upright stance")


func test_vh_pose_keeps_the_body_taller_than_rvh() -> void:
	# VH exists to close RVH's short-side-high hole: the torso must sit
	# meaningfully taller on the post than in RVH.
	var rvh_body: Vector3 = GoalieBodyConfigBuilder.resting_body_position_for_state(
			GoalieStateMachine.State.RVH_LEFT)
	var vh_body: Vector3 = GoalieBodyConfigBuilder.resting_body_position_for_state(
			GoalieStateMachine.State.VH_LEFT)
	assert_gt(vh_body.y, rvh_body.y + 0.15,
			"VH torso is the taller short-side seal")


# ── Rebounds: modern active-rebound doctrine ──────────────────────────────────

func test_rebound_surfaces_follow_real_doctrine() -> void:
	# Chest/body absorbs dead (the one "no rebound" save); controlled pad saves
	# STEER cornerward at pace (pads are built to fire pucks wide); hard shots
	# beat the pad and stay live (Ice Warehouse / InGoal equipment + technique).
	var cfg := GoalieSaveRules.DeadenConfig.new()
	var chest: Vector3 = GoalieSaveRules.deadened_velocity(
			Vector3(6.0, 2.0, -20.0), GoalieSaveRules.SavePart.CHEST, 1.0, 1, cfg)
	assert_true(chest.length() <= cfg.drop_speed + 0.001,
			"chest save is the dead-absorb")
	var pad: Vector3 = GoalieSaveRules.deadened_velocity(
			Vector3(0.0, 0.0, -20.0), GoalieSaveRules.SavePart.PAD, 1.0, 1, cfg)
	assert_gt(pad.length(), 3.0, "controlled pad save exits with real pace")
	assert_gt(absf(pad.x), absf(pad.z), "steered cornerward, not up the slot")
	assert_gt(pad.z, 0.0, "forward component leaves the crease")
	assert_false(GoalieSaveRules.is_controlled_save(
			34.0, GoalieSaveRules.SavePart.PAD, cfg),
			"a genuinely hard shot still beats the pad — live rebound")


func test_five_hole_is_a_real_but_small_target() -> void:
	# The set standing five-hole is a genuine hole (NHL: ~14% of goals) but a
	# tight one — wider than the puck, far narrower than the net — and the
	# down-family seal closes it.
	var puck_diameter: float = GameRules.PUCK_COLLISION_RADIUS * 2.0
	var gc: GoalieController = _gc()
	var standing_gap: float = GoalieBehaviorRules.five_hole_gap_m(false, gc.five_hole_base)
	assert_gt(standing_gap, puck_diameter, "the standing five-hole is shootable")
	assert_lt(standing_gap, 0.35, "…but only just — a timing target, not a lane")
	assert_lt(GoalieBehaviorRules.five_hole_gap_m(true, 0.0), 0.02,
			"a set butterfly seals it")
