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
			"C depth = middle of the paint (now the out-of-zone resting depth)")
	assert_gt(gc.depth_aggressive, crease_top,
			"A depth challenges past the crease top")
	assert_lt(gc.depth_aggressive, crease_top + 0.7,
			"A depth stays inside the modern (post-challenge-era) band")
	assert_between(gc.depth_defensive, 0.0, 0.25,
			"D depth = on the goal line / post")


func test_long_range_depth_never_sinks_to_the_goal_line() -> void:
	# A puck far away IN FRONT leaves a real goalie resting in the paint
	# watching the play — D depth is behind-net/post play only (USA Hockey).
	# Re-expressed against the LIVE model: depth is solved from the races now, and
	# the races say nothing about a puck that is not yet a threat — so the ceiling
	# is gated on the play having entered the zone, and outside it he rests in the
	# paint. Asserts the two ends: resting outside, challenging inside.
	var gc: GoalieController = _gc()
	var zone_depth: float = GameRules.GOAL_LINE_Z - GameRules.BLUE_LINE_Z
	assert_false(gc._threat_is_in_zone(35.0),
			"a puck 35 m out has not entered the zone")
	assert_true(gc._threat_is_in_zone(zone_depth - 1.0),
			"a puck inside the blue line has")
	assert_between(gc.depth_conservative, 0.4, 0.9,
			"and the resting depth is the middle of the paint, not the goal line")


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
	assert_almost_eq(gc._movement_read_delay(), gc.move_read_scramble_delay, 0.0001,
			"mid-lunge the goalie is out of the play — full scramble read")


func test_travelling_goalie_can_still_start_his_response_in_tight() -> void:
	# Keeper decision-time research splits on EXPERTISE (~250-260 ms expert vs
	# ~320 ms novice), not posture, so a goalie travelling on his feet has no
	# grounded reason to read a shot 100+ ms later than a set one — and pricing him
	# that way stops being "reads late" and becomes "does not react at all". At 5 m
	# and 25 m/s the puck arrives in 0.20 s, so a PRIMED goalie caught travelling
	# has to still get both limbs moving inside it.
	#
	# BOUNDED FROM BELOW TOO, and that is the live constraint: this residual is
	# measurably load-bearing for readability (tests/unit/ai/test_goalie_disguise_
	# read.gd — the goalie is in motion at release far more often than the "set
	# goalie" framing suggests). Below ~0.08 s height deception starts paying
	# NEGATIVELY, which the beatable-realism doctrine names as the tell for a wrong
	# change. Do not cut it further without giving deception a mechanism that does
	# not run through this number.
	var gc: GoalieController = _gc()
	var slot_flight: float = 5.0 / 25.0
	var primed_arm: float = maxf(
			gc.arm_reaction_delay - (gc.reaction_delay - gc.prearmed_reaction_delay), 0.0)
	assert_lt(gc.prearmed_reaction_delay + gc.move_read_speed_delay, slot_flight,
			"a primed goalie caught travelling must still START the drop in tight")
	assert_lte(primed_arm + gc.move_read_speed_delay, slot_flight,
			"...and must still get the arm moving rather than watching it go by")
	assert_lt(gc.move_read_speed_delay, gc.move_read_scramble_delay,
			"scrambling has no momentum for the drift to carry, so it keeps the "
			+ "larger latency — the response is not available yet, not merely late")


func test_unset_goalie_carries_momentum_through_the_freeze() -> void:
	# The real cost of being caught moving is mechanical: momentum you cannot
	# cancel and no loaded edge to cancel it with. Coaching doctrine is "be
	# stopped before the release" precisely because the body keeps going.
	var gc: GoalieController = _gc()
	var delta: float = 1.0 / 120.0
	gc._reaction_drift_vx = gc.t_push_speed
	var x: float = 0.0
	var elapsed: float = 0.0
	for _i in range(240):
		x = gc._reaction_drift_x(delta, x)
		if gc._reaction_drift_vx == 0.0:
			break
		elapsed += delta
	assert_between(x, 0.25, 0.8,
			"a full T-push carries the body a real fraction of a metre past the commit")
	assert_between(elapsed, 0.2, 0.7,
			"and takes a few tenths to kill — the window a shooter can exploit")


func test_drift_stopping_is_harder_than_pushing() -> void:
	# Stopping is the harder half of the edge: pushing loads an edge, arresting
	# momentum happens on an unloaded leg that has not re-planted yet.
	var gc: GoalieController = _gc()
	assert_lt(gc.unset_drift_decel_ratio, 1.0,
			"killing momentum must be slower than generating it")
	assert_gt(gc.unset_drift_decel_ratio, 0.0)


func test_prime_and_read_penalty_share_one_definition_of_set() -> void:
	# The quiet-eye credit is premised on being coiled and settled. A goalie the
	# read penalty is calling unset must not simultaneously collect it, so both
	# go through _unset_fraction and the prime gate sits inside its range.
	var gc: GoalieController = _gc()
	gc._build_rule_configs()
	assert_almost_eq(gc._unset_fraction(), 0.0, 0.0001, "stopped goalie is set")
	gc._velocity_x = gc.t_push_speed
	assert_gt(gc._unset_fraction(), gc.set_unset_max,
			"a goalie mid-T-push does not collect the primed read")
	gc._velocity_x = 0.0
	gc._lunge_active_timer = 0.1
	assert_gt(gc._unset_fraction(), gc.set_unset_max,
			"nor does one with a committed jab extended")
	assert_between(gc.set_unset_max, 0.0, 0.5,
			"the set band is a settling shuffle, not a push")


func test_movement_penalty_is_additive_only() -> void:
	# CSA set-vs-unset: penalties only ever ADD read latency; a set goalie is
	# never buffed past the base read.
	var cfg := GoalieBehaviorRules.MovementReadConfig.new()
	cfg.reference_speed = 2.5
	cfg.speed_delay = 0.12
	cfg.scramble_delay = 0.12
	cfg.scramble_unset = 1.0
	assert_almost_eq(GoalieBehaviorRules.movement_read_penalty(0.0, false, cfg),
			0.0, 0.0001)
	assert_almost_eq(GoalieBehaviorRules.movement_read_penalty(99.0, false, cfg),
			cfg.speed_delay, 0.0001, "penalty caps at speed_delay")


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


func test_seal_only_for_contested_pucks_never_for_the_1v1_dangler() -> void:
	# Doctrine: seal the ice on a net-front BATTLE; stay up against controlled
	# possession — a carrier driving the net (force the release) AND the
	# uncontested 1v1 dangler in tight (breakaway/penalty-shot teaching: stay
	# patient, make the shooter commit first; the goalie who drops early has
	# already lost the read battle).
	#
	# Was a threshold pair on the deleted GoalieBehaviorRules.is_crease_jam
	# (puck within 2 m, contestant within 1.5 m, carrier under 3 m/s). The
	# doctrine is unchanged; it now falls out of GoalieSaveSelection's clock,
	# so this pins the SAME three cases through the model that owns them.
	var gc: GoalieController = _gc()
	var s := GoalieSaveSelection.Situation.new()
	s.reaction_delay = gc.reaction_delay
	s.drop_time = gc.butterfly_drop_speed

	# Doorstep battle: a contested puck 0.9 m away, a stick already on it. The
	# next touch IS the release, and 0.9 m of flight is no time at all.
	s.time_to_contest = 0.0
	s.time_to_arrival = 0.9 / GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	assert_true(GoalieSaveSelection.should_block(s),
			"a contested puck at the doorstep → seal")

	# The uncontested 1v1 dangler at the same range. Nothing else can touch it,
	# and he has declared nothing, so the caller hands us an unbounded arrival —
	# there is no clock running and no reason to pre-commit.
	s.time_to_contest = INF
	s.time_to_arrival = INF
	assert_false(GoalieSaveSelection.should_block(s),
			"uncontested carrier in tight is the 1v1 dangler → stay up, be patient")

	# Same carrier driving the net hard. Speed does not make him readable OR
	# unreadable — it is still controlled possession, so still no clock.
	assert_false(GoalieSaveSelection.should_block(s),
			"a fast carrier is ATTACKING → stay up, force the release")


func test_pads_first_commit_keys_on_the_puck_not_the_body() -> void:
	# The tuck is played by the puck. A body driving across the crease with
	# the puck trailing on the far side (the forehand-drag drive) has not
	# committed anything — the wrap/cut-back is free, and a goalie who sells
	# out to the body is exactly what the move fishes for. Pads-first only
	# once the puck itself is past the standing sealing reach (the point of
	# no return: bringing it back costs the full trip around the body).
	var cfg := GoalieBehaviorRules.BeatenWideConfig.new()
	cfg.goalie_lateral_speed = 3.8
	cfg.goalie_lateral_accel = 14.0
	cfg.reach_half_width = 0.42
	cfg.min_lateral_speed = 2.5
	cfg.max_threat_distance = 4.0
	var goalie := Vector3(0.0, 0.0, 24.85)
	var body := Vector3(0.2, 0.0, 25.5)
	assert_false(GoalieBehaviorRules.is_beaten_wide(
			body, Vector3(-0.8, 0.0, 25.6), 4.0, goalie,
			26.6, 0.0, -1, 0.915, cfg),
			"puck trailing the drive → stay up, shuffle across")
	assert_true(GoalieBehaviorRules.is_beaten_wide(
			body, Vector3(0.9, 0.0, 25.6), 4.0, goalie,
			26.6, 0.0, -1, 0.915, cfg),
			"puck past the sealing reach → the tuck is live, sell out")


func test_lateral_commits_require_a_confirmed_read() -> void:
	# "Don't bite on the first move": a goalie confirms a trajectory over a
	# quiet-eye fixation (~100-300 ms) before selling out pads-first. One
	# tick of lateral body velocity is a deke's opening move, not a drive —
	# and the drive bar itself must be above dangle/shuffle pace (brisk
	# walking is ~1.5 m/s; a genuine drive to the post is well past it).
	var gc: GoalieController = _gc()
	assert_between(gc.lateral_commit_confirm_s, 0.10, 0.30)
	assert_gte(gc.beaten_wide_min_lateral_speed, 2.0,
			"beaten-wide needs a genuine drive, not a lateral shuffle")


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


# ── Cover / freeze doctrine (USA Hockey cover-vs-clear hierarchy) ─────────────

func test_cover_parameters_match_doctrine_and_flow() -> void:
	# The smother race window sits in a human collapse band; the ARCADE hold is
	# long enough to kill a scramble but short enough to keep the no-stoppage
	# flow promise; the cooldown makes cover a scramble-killer, not a wall.
	var gc: GoalieController = _gc()
	assert_between(gc.cover_reach_time, 0.2, 0.5,
			"glove-to-ice smother takes a human beat — it's a race, not a snap")
	assert_between(gc.cover_hold_s, 0.4, 1.2,
			"ARCADE hold kills the scramble without reading as a stoppage")
	assert_gt(gc.cover_cooldown_s, 4.0,
			"covers are spaced — smothering every rebound would be a wall")

func test_sweep_requires_an_open_lane() -> void:
	# The clear is only the correct read when a corner exit lane is OPEN — an
	# opponent's stick on the lane turns the sweep into a turnover, which is
	# exactly when real goalies cover instead (USA Hockey: gather/cover vs
	# "clear it into the corner" is a time-and-pressure decision).
	var gc: GoalieController = _gc()
	gc._build_rule_configs()
	var lane_cfg: GoalieBehaviorRules.SweepLaneConfig = gc._sweep_lane_cfg
	var on_lane := PackedVector3Array([Vector3(1.5, 0, 25.0)])
	assert_true(GoalieBehaviorRules.sweep_lane_blocked(
			Vector3(0, 0, 25), Vector3(7, 0, 0), on_lane, lane_cfg))
	assert_false(GoalieBehaviorRules.sweep_lane_blocked(
			Vector3(0, 0, 25), Vector3(7, 0, 0), PackedVector3Array(), lane_cfg))

func test_covering_is_a_committed_down_state() -> void:
	# On the wire the smother reads as a sealed (down-family) pose; in the
	# state machine it is neither upright (no drop-eligibility) nor butterfly
	# family (no slide machinery composes with a smother).
	var sm := GoalieStateMachine.new()
	sm.current = GoalieStateMachine.State.COVERING
	assert_false(sm.is_upright())
	assert_false(sm.is_down())
	assert_false(sm.is_post_integrated())
	var ns := GoalieNetworkState.new()
	ns.state_enum = GoalieStateMachine.State.COVERING as int
	assert_true(ns.is_down(), "replicated smother pose is down-family")


func test_clear_strike_has_a_windup_beat() -> void:
	# The clear is windup → strike → follow-through: the puck departs at the
	# STRIKE (blade-through-puck moment), not at the decision — so the stick
	# is visibly what clears it. The backswing sits in a human beat: long
	# enough to read, short enough that a scramble can't fully turn over
	# underneath it.
	var gc: GoalieController = _gc()
	assert_between(gc.sweep_windup_s, 0.08, 0.25,
			"backswing beat — the stick, not telekinesis, clears the puck")


# ── Behind-net puck play: conservative doctrine ───────────────────────────────

func test_puck_play_is_ultra_conservative() -> void:
	# "Stop it, leave it, get back" with a fat surplus: the go margin is a
	# real safety buffer, the abort margin is strictly smaller (bail-early
	# hysteresis), the assumed forechecker is at/above a skater's true sprint
	# ceiling, and a net-front lurker vetoes the trip from well out. An AI
	# goalie mistake behind the net is the most frustrating failure available,
	# so every knob here errs toward staying home.
	var gc: GoalieController = _gc()
	assert_gt(gc.puck_play_go_margin, 0.6, "fat GO surplus")
	assert_lt(gc.puck_play_abort_margin, gc.puck_play_go_margin,
			"abort threshold strictly tighter than go — hysteresis bails early")
	assert_true(gc.puck_play_opponent_speed >= GameRules.DEFAULT_SKATER_MAX_SPEED_M_S,
			"pressure clock assumes a full-sprint forechecker")
	assert_gt(gc.puck_play_net_front_exclusion, 2.0,
			"a net-front lurker vetoes leaving the net outright")
	assert_lt(gc.puck_play_skate_speed, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S,
			"goalies skate slower than skaters — the race must reflect it")

func test_only_the_top_tier_plays_the_puck() -> void:
	# Timid puck play is a real weaker-goalie trait — and it means the feature
	# carries zero risk on the tiers most players face. HARD's margin equals
	# the authored default (the profile contract).
	assert_true(is_inf(GoalieSkillProfile.easy().puck_play_go_margin_s))
	assert_true(is_inf(GoalieSkillProfile.normal().puck_play_go_margin_s))
	var gc: GoalieController = _gc()
	assert_almost_eq(GoalieSkillProfile.hard().puck_play_go_margin_s,
			gc.puck_play_go_margin, 0.0001)


# ── Catch-and-hold doctrine ───────────────────────────────────────────────────

func test_catch_resolution_mirrors_the_real_freeze_incentive() -> void:
	# Real rule structure: a goalie freezes a caught puck under pressure (a
	# whistle in NHL terms), but freezing with nobody on you is delay of game —
	# unpressured catches get set down and played. The quick drop must be a
	# genuinely shorter beat than the pressured hold, and the pressure radius a
	# real "someone is bearing down" range.
	var gc: GoalieController = _gc()
	assert_lt(gc.catch_quick_drop_s, gc.cover_hold_s,
			"unpressured look-and-drop is quicker than the pressured hold")
	assert_between(gc.catch_hold_pressure_radius, 1.5, 4.0,
			"pressure = an opponent genuinely bearing down on the crease")

func test_catching_state_families() -> void:
	# The upright and down catch variants exist so clients' state-keyed
	# body/head heights render the right silhouette; neither is upright (no
	# drop-eligibility mid-squeeze) and only the down variant reads as a
	# down-family pose on the wire.
	var sm := GoalieStateMachine.new()
	sm.current = GoalieStateMachine.State.CATCHING
	assert_true(sm.is_catching())
	assert_false(sm.is_upright())
	assert_false(sm.is_down())
	var up := GoalieNetworkState.new()
	up.state_enum = GoalieStateMachine.State.CATCHING as int
	assert_false(up.is_down(), "upright catch keeps the standing silhouette")
	var down := GoalieNetworkState.new()
	down.state_enum = GoalieStateMachine.State.CATCHING_DOWN as int
	assert_true(down.is_down(), "butterfly catch keeps the sealed silhouette")
