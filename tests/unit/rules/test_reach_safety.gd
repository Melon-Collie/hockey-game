extends GutTest

# Reachable-set (pursuit-evasion) possession safety. Whether a defender threatens
# the puck is "can he get a stick to it given his momentum + reaction," not raw
# proximity. These pin the behaviours the old proximity model couldn't express:
# a hard charger is evadable (he overshoots), a contained/jockeying defender can't
# strip a careful carrier, a stick on the puck is a real threat, and handling
# (how far the carrier holds the puck off his body) threads tighter seams.

const HANDLE: float = 0.9   # base puck-protect reach (Hands scales this)


# Carrier's evadability [0,1]: safety at the best seam in his handling envelope.
func _evade(car: Vector3, car_v: Vector3, opps: Array[Vector3],
		vels: Array[Vector3], handle: float = HANDLE) -> float:
	var seam: Vector3 = AIActionScoring.best_evade_point(car, car_v, opps, vels, handle)
	var clear: float = AIActionScoring.reach_clearance(
			seam, AIActionScoring.EVADE_HORIZON_S, opps, vels)
	return AIActionScoring.clearance_to_safety(clear)


func test_no_defenders_is_fully_safe() -> void:
	assert_eq(_evade(Vector3.ZERO, Vector3(5, 0, 0), [], []), 1.0)


func _caps(max_accel: float, blade_span: float) -> AISkaterCaps:
	var c := AISkaterCaps.new()
	c.max_accel = max_accel
	c.blade_span = blade_span
	return c


func test_bigger_more_agile_defender_covers_more() -> void:
	# Same defender geometry, but its real build sets its reach: thrust (max_accel)
	# is how far it can lunge off its line, Size (blade_span) how far its stick
	# touches. A big, agile defender reaches further → LESS clearance for the same
	# puck point; a small, sluggish one reaches less → more room. Empty caps sits
	# between them at the league default.
	var opps: Array[Vector3] = [Vector3(2.0, 0, 0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var t: float = AIActionScoring.EVADE_HORIZON_S
	var league: float = AIActionScoring.reach_clearance(Vector3.ZERO, t, opps, vels)
	var vs_big: float = AIActionScoring.reach_clearance(
			Vector3.ZERO, t, opps, vels, [_caps(16.0, 2.0)])
	var vs_small: float = AIActionScoring.reach_clearance(
			Vector3.ZERO, t, opps, vels, [_caps(6.0, 1.2)])
	assert_lt(vs_big, league, "a bigger, more agile defender reaches further → less clearance")
	assert_gt(vs_small, league, "a smaller, slower defender reaches less → more room")


func test_angled_hard_charger_is_evadable() -> void:
	# Defender charging in from front-left at ~8 m/s. His momentum carries his
	# reach downrange past the carrier, so the space he vacates is open — beat him
	# by letting him overshoot.
	var opps: Array[Vector3] = [Vector3(2.5, 0, 2.5)]
	var vels: Array[Vector3] = [Vector3(-5.66, 0, -5.66)]
	assert_gt(_evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels), 0.8,
			"a committed angled charger is beaten, not a strip threat")


func test_straight_on_charger_is_evadable() -> void:
	var opps: Array[Vector3] = [Vector3(3, 0, 0)]
	var vels: Array[Vector3] = [Vector3(-8, 0, 0)]
	assert_gt(_evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels), 0.8,
			"a head-on charger at 8 m/s blows past — evadable")


func test_stick_on_the_puck_is_a_real_threat() -> void:
	# Defender's stick right on the puck, no momentum — the carrier can't just
	# skate out of it in one cut.
	var opps: Array[Vector3] = [Vector3(0.8, 0, 0.3)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	assert_lt(_evade(Vector3.ZERO, Vector3(3, 0, 0), opps, vels), 0.35,
			"a stick on the puck is genuine pressure")


func test_stationary_wall_ahead_is_tight() -> void:
	var opps: Array[Vector3] = [Vector3(1.5, 0, 0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	assert_lt(_evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels), 0.35,
			"skating into a stationary defender 1.5 m ahead is tight")


func test_jockey_cannot_strip_a_careful_carrier() -> void:
	# A gap-control defender pacing the carrier can CONTAIN (cap progress) but not
	# strip — the carrier is safe from a poke (he can retreat/hold). Containment is
	# the offense model's problem (no lane past him), not a safety one.
	var opps: Array[Vector3] = [Vector3(2.2, 0, 0.2)]
	var vels: Array[Vector3] = [Vector3(5, 0, 0)]
	assert_gt(_evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels), 0.8,
			"gap-control contains but doesn't strip — safe from the poke")


func test_handling_threads_a_tighter_seam() -> void:
	# In a tight spot (stationary wall), a better handler holds the puck further
	# off his body and finds room a plodder can't. Skill expression, grounded in
	# the handling envelope — not a magic deke chance.
	var opps: Array[Vector3] = [Vector3(1.5, 0, 0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var low: float = _evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels, 0.6)
	var high: float = _evade(Vector3.ZERO, Vector3(5, 0, 0), opps, vels, 1.4)
	assert_gt(high, low, "better hands thread a tighter seam")


func test_seam_points_into_open_space() -> void:
	# The seam is a usable carry target: with a defender to the left, it resolves
	# to the right of the carrier's line.
	var opps: Array[Vector3] = [Vector3(1.0, 0, 2.0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var seam: Vector3 = AIActionScoring.best_evade_point(
			Vector3.ZERO, Vector3(4, 0, 0), opps, vels, HANDLE)
	assert_lt(seam.z, 0.5, "seam leans away from the defender on the +Z side")


# ─── carry_strip_point: WHERE a carry gets stripped ──────────────────────────

func test_strip_point_is_the_tight_midroute_not_the_safe_destination() -> void:
	# Carry from (0,0) to a clear destination (0,10), but a defender sits right on
	# the mid-route point (0,5). The strip, if it happens, is mid-route — the cost
	# must localize there, not at the open destination.
	var from := Vector3(0, 0, 0)
	var to := Vector3(0, 0, 10)
	var opps: Array[Vector3] = [Vector3(0, 0, 5)]     # parked on the midpoint
	var vels: Array[Vector3] = [Vector3.ZERO]
	var strip: Vector3 = AIActionScoring.carry_strip_point(from, to, 1.4, opps, vels)
	assert_almost_eq(strip.z, 5.0, 0.01, "strip localizes to the tight mid-route point")


func test_strip_point_is_destination_when_that_is_the_tight_end() -> void:
	# Clear mid-route, but a defender waiting AT the destination. The strip is there.
	var from := Vector3(0, 0, 0)
	var to := Vector3(0, 0, 10)
	var opps: Array[Vector3] = [Vector3(0, 0, 10)]    # waiting at the destination
	var vels: Array[Vector3] = [Vector3.ZERO]
	var strip: Vector3 = AIActionScoring.carry_strip_point(from, to, 1.4, opps, vels)
	assert_almost_eq(strip.z, 10.0, 0.01, "strip localizes to the covered destination")


func test_strip_point_of_a_stand_is_the_spot_itself() -> void:
	var spot := Vector3(3, 0, 7)
	var opps: Array[Vector3] = [Vector3(4, 0, 7)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var strip: Vector3 = AIActionScoring.carry_strip_point(spot, spot, 0.4, opps, vels)
	assert_eq(strip, spot, "a stand's strip is where it stands")


# ─── boards bound the seam search (the wall-pincer read) ─────────────────────

func test_evade_seam_never_leaves_the_playing_surface() -> void:
	# Carrier tight on the side wall, defender sealing from mid-ice: the naive
	# "away from the threat" seam sits THROUGH the boards. The handling envelope
	# is intersected with the rink, so the seam resolves along the wall instead.
	var carrier := Vector3(GameRules.INNER_HALF_WIDTH - 0.4, 0, 0)
	var opps: Array[Vector3] = [carrier + Vector3(-2.0, 0, 0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var seam: Vector3 = AIActionScoring.best_evade_point(
			carrier, Vector3.ZERO, opps, vels, HANDLE)
	assert_lte(seam.x, GameRules.INNER_HALF_WIDTH, "seam stays on the playing surface")
	assert_gt(absf(seam.z), 0.5, "with the wall at the back, the escape runs along the boards")


func test_wall_alone_is_harmless_without_a_defender() -> void:
	# Nobody to pin against: a carrier parked on the boards with no defender in
	# the picture is fully safe (the n == 0 early return).
	assert_eq(_evade(Vector3(GameRules.INNER_HALF_WIDTH - 0.3, 0, 0),
			Vector3.ZERO, [], []), 1.0)


func test_wall_pinned_carrier_reads_far_less_safe_than_open_ice() -> void:
	# Same 1.5 m defender gap, two placements: pinned against the side wall (the
	# outside half of the handling envelope is illegal — the classic wall pincer)
	# vs mid-ice (a full envelope to evade into). The pre-boards model scored
	# both alike by "evading" INTO the wall; the pinned read must now collapse.
	var pinned_pos := Vector3(GameRules.INNER_HALF_WIDTH - 0.4, 0, 0)
	var opps_wall: Array[Vector3] = [pinned_pos + Vector3(-1.5, 0, 0)]
	var opps_open: Array[Vector3] = [Vector3(-1.5, 0, 0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var pinned: float = _evade(pinned_pos, Vector3.ZERO, opps_wall, vels)
	var open: float = _evade(Vector3.ZERO, Vector3.ZERO, opps_open, vels)
	assert_lt(pinned, 0.35, "pinned on the wall with a defender sealing is genuinely unsafe")
	assert_gt(open, pinned + 0.3, "the identical defender gap in open ice leaves real room")


# ─── best_evade_point_toward: beat the man TOWARD the objective ──────────────

func test_directed_seam_advances_past_an_overplaying_defender() -> void:
	# Carrier driving +Z at the objective, defender overplaying the left side of
	# the lane. The pure max-clearance seam retreats to wherever is emptiest
	# (behind/lateral); the DIRECTED seam takes the safe sample on the OPEN side
	# on the way forward — beating the man, not avoiding him.
	var objective := Vector3(0, 0, 10)
	var opps: Array[Vector3] = [Vector3(-1.2, 0, 3.0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var directed: Vector3 = AIActionScoring.best_evade_point_toward(
			Vector3.ZERO, Vector3(0, 0, 4), objective, opps, vels, HANDLE)
	var undirected: Vector3 = AIActionScoring.best_evade_point(
			Vector3.ZERO, Vector3(0, 0, 4), opps, vels, HANDLE)
	assert_gt(directed.x, 0.5, "cuts to the open (right) side of the overplayed lane")
	assert_gt(directed.z, 1.6, "advances past the projected center, toward the objective")
	assert_gt(directed.z, undirected.z + 0.5,
			"the directed seam advances where the max-clearance seam gives ground")


func test_directed_seam_is_genuinely_safe() -> void:
	# The progress winner must clear every defender's reach by the blade-of-air
	# floor — progress never buys back into a strip.
	var objective := Vector3(0, 0, 10)
	var opps: Array[Vector3] = [Vector3(-1.2, 0, 3.0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var directed: Vector3 = AIActionScoring.best_evade_point_toward(
			Vector3.ZERO, Vector3(0, 0, 4), objective, opps, vels, HANDLE)
	var clear: float = AIActionScoring.reach_clearance(
			directed, AIActionScoring.EVADE_HORIZON_S, opps, vels)
	assert_gte(clear, AIActionScoring.EVADE_SAFE_CLEAR_MIN_M,
			"the directed seam keeps at least a blade of air off every reach")


func test_directed_seam_falls_back_to_max_clearance_when_surrounded() -> void:
	# Swarmed — no envelope sample clears the safe floor. Nothing to attack:
	# the directed seam degrades to exactly the survival (max-clearance) read.
	var objective := Vector3(0, 0, 10)
	var opps: Array[Vector3] = [
			Vector3(1.2, 0, 0), Vector3(-0.85, 0, 0.85), Vector3(-0.85, 0, -0.85)]
	var vels: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	var directed: Vector3 = AIActionScoring.best_evade_point_toward(
			Vector3.ZERO, Vector3.ZERO, objective, opps, vels, HANDLE)
	var undirected: Vector3 = AIActionScoring.best_evade_point(
			Vector3.ZERO, Vector3.ZERO, opps, vels, HANDLE)
	assert_eq(directed, undirected, "no safe sample → survive first, pure max clearance")


func test_directed_seam_leans_toward_objective_in_open_ice() -> void:
	# Nobody around: every sample is safe, so the directed seam is simply the
	# most-progress point of the envelope — it leans toward the objective.
	var objective := Vector3(0, 0, 10)
	var directed: Vector3 = AIActionScoring.best_evade_point_toward(
			Vector3.ZERO, Vector3.ZERO, objective, [], [], HANDLE)
	assert_gt(directed.z, 0.5, "open ice: the seam leans toward the objective")


# ─── brake check: stop dead, let the committed checker fly by ─────────────────

func test_brake_stop_point_is_the_physical_stopping_distance() -> void:
	# v²/(2·decel) along the velocity: 6 m/s into a 10 m/s² brake = 1.8 m.
	var stop: Vector3 = AIActionScoring.brake_stop_point(
			Vector3.ZERO, Vector3(6, 0, 0))
	assert_almost_eq(stop.x, 1.8, 0.01, "stop point is v²/(2·decel) downstream")
	assert_almost_eq(stop.z, 0.0, 0.01)


func test_brake_check_beats_a_charger_crossing_the_forward_lane() -> void:
	# A committed checker sweeping across the carrier's forward lane, timed for
	# where the carrier is GOING: cutting forward carries the puck into his
	# sweep, braking parks it short of the crossing and his momentum takes his
	# reach past. The cut seam here is the forward-directed one the carrier
	# would otherwise take.
	var carrier_vel := Vector3(5, 0, 0)
	var forward_seam := Vector3(3.2, 0, 0.4)
	var opps: Array[Vector3] = [Vector3(4.0, 0, 2.2)]
	var vels: Array[Vector3] = [Vector3(0, 0, -8)]
	assert_true(AIActionScoring.prefers_brake_check(
			Vector3.ZERO, carrier_vel, forward_seam, opps, vels),
			"stopping short of the crossing beats cutting into it")


func test_brake_check_rejected_against_a_jockeying_pacer() -> void:
	# A gap-control defender pacing alongside: braking doesn't shake him (his
	# projected reach never leaves the carrier), while the cut away stays the
	# clearer play — no brake check against containment.
	var carrier_vel := Vector3(5, 0, 0)
	var away_seam := Vector3(1.2, 0, -1.2)
	var opps: Array[Vector3] = [Vector3(1.4, 0, 1.0)]
	var vels: Array[Vector3] = [Vector3(5, 0, 0)]
	assert_false(AIActionScoring.prefers_brake_check(
			Vector3.ZERO, carrier_vel, away_seam, opps, vels),
			"a pacer stays on the braked puck — the cut is the answer, not the stop")


func test_brake_check_rejected_when_the_braked_hold_is_not_safe() -> void:
	# Stick already at the puck: the braked hold is covered outright, so the
	# brake check can never fire regardless of how bad the cut looks.
	var carrier_vel := Vector3(5, 0, 0)
	var seam := Vector3(1.0, 0, 1.5)
	var opps: Array[Vector3] = [Vector3(1.0, 0, 0.3)]
	var vels: Array[Vector3] = [Vector3(4.5, 0, 0)]
	assert_false(AIActionScoring.prefers_brake_check(
			Vector3.ZERO, carrier_vel, seam, opps, vels),
			"an unsafe braked hold never prefers the brake")


# ─── best_handle_protect_point: shield the puck with the body ─────────────────

func test_protect_point_pulls_the_puck_away_from_a_frontal_stick() -> void:
	# Stick threat dead ahead of a stationary carrier: the safest holdable spot
	# is on the FAR side of the body — pull the puck back, body becomes the
	# shield. Offset is body-relative.
	var opps: Array[Vector3] = [Vector3(0, 0, -1.2)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var offset: Vector3 = AIActionScoring.best_handle_protect_point(
			Vector3.ZERO, Vector3.ZERO, opps, vels, HANDLE)
	assert_gt(offset.z, 0.5, "puck pulls to the protected side, away from the threat")


func test_protect_point_stays_inside_the_handling_envelope() -> void:
	var opps: Array[Vector3] = [Vector3(0.9, 0, 0.7)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var offset: Vector3 = AIActionScoring.best_handle_protect_point(
			Vector3.ZERO, Vector3.ZERO, opps, vels, HANDLE)
	assert_lte(offset.length(), HANDLE + 0.001,
			"the blade can only hold the puck within its handling reach")


func test_protect_point_never_shields_into_the_wall() -> void:
	# Carrier tight on the side wall, defender attacking from mid-ice: the naive
	# "away from the threat" side is INTO the wall. The board cap makes the seam
	# resolve along the wall instead — never outside the rink.
	var carrier := Vector3(GameRules.INNER_HALF_WIDTH - 0.4, 0, 0)
	var opps: Array[Vector3] = [carrier + Vector3(-1.2, 0, 0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var offset: Vector3 = AIActionScoring.best_handle_protect_point(
			carrier, Vector3.ZERO, opps, vels, HANDLE)
	assert_lte(carrier.x + offset.x, GameRules.INNER_HALF_WIDTH,
			"the protected spot stays on the playing surface")
	assert_gt(absf(offset.z), 0.3, "with the wall behind, the escape runs ALONG the boards")


# ─── fake-then-cut deke: manufacturing the opening ────────────────────────────
# GO iff the cut side is covered NOW but clear of everyone AFTER the fake
# loads the defender with wrong-way momentum (his real accel, reaction-gated).

func _deke_frame(puck: Vector3, d_pos: Vector3, d_vel: Vector3) -> Array:
	# The caller-supplied axis frame, built exactly as the carrier builds it.
	var d_proj: Vector3 = d_pos + d_vel * (AIActionScoring.DEKE_FAKE_S + AIActionScoring.DEKE_CUT_S)
	var axis: Vector3 = (d_proj - puck).normalized()
	return [axis, Vector3(axis.z, 0.0, -axis.x)]


func test_deke_manufactures_an_opening_on_a_patient_container() -> void:
	# Standstill duel: a league-agility defender parked 2.3 m ahead. No cut
	# side is safe right now (his window reach covers both), but his bite on
	# the fake carries his reach the wrong way — GO.
	var opps: Array[Vector3] = [Vector3(0, 0, -2.3)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var frame: Array = _deke_frame(Vector3.ZERO, opps[0], vels[0])
	var side: int = AIActionScoring.deke_cut_side(
			Vector3.ZERO, Vector3.ZERO, 0.9, frame[0], frame[1], 0, opps, vels)
	assert_ne(side, 0, "the fake buys a safe cut that doesn't exist today")


func test_deke_declines_an_already_beatable_defender() -> void:
	# Defender well off the puck: the cut side is safe right now — nothing to
	# manufacture, the plain seam owns it.
	var opps: Array[Vector3] = [Vector3(0, 0, -4.5)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var frame: Array = _deke_frame(Vector3.ZERO, opps[0], vels[0])
	assert_eq(AIActionScoring.deke_cut_side(
			Vector3.ZERO, Vector3.ZERO, 0.9, frame[0], frame[1], 0, opps, vels), 0,
			"an opening that already exists needs no fake")


func test_deke_cannot_fake_a_pylon() -> void:
	# Same 2.3 m duel, but the defender's build barely accelerates: he can't
	# BITE, so the fake manufactures nothing — while the identical geometry
	# against a league-agility man is GO (the previous test). You deke the
	# good defender; the slow one you simply beat.
	var opps: Array[Vector3] = [Vector3(0, 0, -2.3)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var pylon := AISkaterCaps.new()
	pylon.max_accel = 2.0
	var frame: Array = _deke_frame(Vector3.ZERO, opps[0], vels[0])
	assert_eq(AIActionScoring.deke_cut_side(
			Vector3.ZERO, Vector3.ZERO, 0.9, frame[0], frame[1], 0,
			opps, vels, [pylon]), 0,
			"no bite, no manufactured opening")


func test_deke_cuts_away_from_the_second_defender() -> void:
	# A helper shades one cut lane: the manufactured cut must go the OTHER
	# way (perp = (-1,0,0), so side -1 cuts world +X, away from the -X guard).
	# The guard sits far enough that HIS side alone dies — a truly tight
	# double-team correctly manufactures nothing at all.
	var opps: Array[Vector3] = [Vector3(0, 0, -2.3), Vector3(-2.6, 0, -1.2)]
	var vels: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var frame: Array = _deke_frame(Vector3.ZERO, opps[0], vels[0])
	assert_eq(AIActionScoring.deke_cut_side(
			Vector3.ZERO, Vector3.ZERO, 0.9, frame[0], frame[1], 0, opps, vels), -1,
			"the cut resolves to the unguarded side")
