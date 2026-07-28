extends GutTest

# Calibration + contract tests for AIDangerField — the memoized goalie-hole
# surface behind AIActionScoring.score_shoot_threat_fielded (see the class
# doc in danger_field.gd for what is cached vs live vs dropped).
#
# The bound asserted here (ERR_BOUND) is the whole fidelity contract of the
# fielded read: |fielded − exact| over representative in-zone geometry, with
# the exact threat-family score_shoot as reference. If a change to the hole
# model or the grid spacing moves the real error, this is the test that
# says so — tighten or investigate, don't just bump the bound.

# Max |fielded − exact| tolerated over the probe lattice. Interpolation
# across the vertex spacing on a 0..1 surface with real ~0.9/m cliffs.
# Measured max at 0.75 m spacing: 0.053 — the bound sits snug above it; if
# it creeps, tighten the spacing or investigate, don't just raise this.
const ERR_BOUND: float = 0.07
# Value gap above which the fielded read must preserve pairwise ORDER on
# the lattice — the property the comparative consumers actually rely on.
const RANK_GAP: float = 0.10

var _net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
var _goalie := Vector3(0.2, 0.0, -(GameRules.GOAL_LINE_Z - 1.1))

# x = 4 / depth = 17 sit on a measured surface CLIFF (quality 0 → 0.72 over
# ~1 m of depth as a hole-opening threshold crosses) — the worst case for
# interpolation, kept in the lattice deliberately.
const _PROBE_XS: Array[float] = [-10.0, -6.0, -3.0, 0.0, 3.0, 4.0, 6.0, 10.0]
const _PROBE_DEPTHS: Array[float] = [8.0, 10.5, 13.0, 16.0, 17.0, 20.0, 24.0]


func before_each() -> void:
	AIDangerField.reset()


# The exact reference: score_shoot under the threat-family inputs, mirroring
# threat_surface_shoot's call (derived seal, league pace, no pose reads).
func _exact(pos: Vector3, goalie: Vector3, defenders: Array[Vector3]) -> float:
	var seal_x: float = AIActionScoring.derive_post_seal_x_sign(pos, _net)
	return AIActionScoring.score_shoot(
			pos, _net, goalie, GameRules.NET_HALF_WIDTH, defenders,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0, [], -1.0, false,
			seal_x, seal_x != 0.0)


func _fielded(pos: Vector3, goalie: Vector3, defenders: Array[Vector3]) -> float:
	return AIActionScoring.score_shoot_threat_fielded(
			pos, _net, goalie, GameRules.NET_HALF_WIDTH, defenders)


func _probes() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for x: float in _PROBE_XS:
		for d: float in _PROBE_DEPTHS:
			out.append(Vector3(x, 0.0, -d))
	return out


func test_vertex_sample_matches_exact_core() -> void:
	# A query exactly on a grid vertex pays no interpolation: fielded with no
	# defenders (lane = pressure = 1, screens = 0 in the exact twin too) must
	# equal the exact score to float32 storage precision.
	var vx: float = -GameRules.RINK_HALF_WIDTH + 9.0 * AIDangerField.VERTEX_SPACING_M
	var vu: float = GameRules.BLUE_LINE_Z + 6.0 * AIDangerField.VERTEX_SPACING_M
	var pos := Vector3(vx, 0.0, -vu)
	var none: Array[Vector3] = []
	assert_almost_eq(_fielded(pos, _goalie, none), _exact(pos, _goalie, none),
			0.0001, "vertex-aligned sample must match the exact core")


func test_lattice_error_bounded_no_defenders() -> void:
	var none: Array[Vector3] = []
	var max_err: float = 0.0
	var at := Vector3.ZERO
	for p: Vector3 in _probes():
		var err: float = absf(_fielded(p, _goalie, none) - _exact(p, _goalie, none))
		if err > max_err:
			max_err = err
			at = p
	gut.p("danger-field lattice max |fielded − exact| (no defenders): %.4f at %s"
			% [max_err, at])
	assert_lt(max_err, ERR_BOUND, "interpolation error inside the fidelity bound")


func test_lattice_error_bounded_with_off_line_defenders() -> void:
	# Defenders clear of every probe's sightline: the live lane/pressure terms
	# apply identically in both reads, so the error stays pure interpolation.
	var defenders: Array[Vector3] = [
		Vector3(-12.0, 0.0, -6.0),
		Vector3(12.0, 0.0, -8.0),
	]
	var max_err: float = 0.0
	for p: Vector3 in _probes():
		max_err = maxf(max_err,
				absf(_fielded(p, _goalie, defenders) - _exact(p, _goalie, defenders)))
	gut.p("danger-field lattice max err (off-line defenders): %.4f" % max_err)
	assert_lt(max_err, ERR_BOUND, "defender terms stay exact — same bound holds")


func test_screened_shooter_is_understated_only() -> void:
	# A body on the shooter→goalie sightline delays the goalie's read and
	# RAISES the exact quality; the field deliberately drops that term. The
	# contract is one-sided: the fielded read may understate a screened
	# shooter (by the screen's worth), never overstate past the interp bound.
	var pos := Vector3(2.0, 0.0, -13.0)
	var screener_mid: Vector3 = (pos + _goalie) * 0.5
	var defenders: Array[Vector3] = [screener_mid]
	var exact: float = _exact(pos, _goalie, defenders)
	var fielded: float = _fielded(pos, _goalie, defenders)
	# Sanity, on the QUALITY term in isolation. It cannot be read off `_exact`,
	# because the one defender body does two opposing things at once: it screens
	# (raising quality) and it stands in the shot lane (lowering lane_clear).
	# Comparing _exact-with-body against _exact-with-nothing therefore measures
	# the net of those two, not the screen. That comparison only ever passed
	# because the surface was SATURATED — quality read 1.000 screened or not, so
	# it reduced to the lane term equalling itself. With a currency that has
	# range, the lane block can dominate, and the assert started failing while
	# the property it names stayed true.
	var seal_x: float = AIActionScoring.derive_post_seal_x_sign(pos, _net)
	var none: Array[Vector3] = []
	var screen_d: float = AIActionScoring.screen_along_m(
			pos, _goalie, defenders, none)
	assert_gt(screen_d, 0.0, "sanity: this body really does screen the sightline")
	var q_screened: float = AIActionScoring.open_net_danger(
			pos, _net, _goalie, GameRules.NET_HALF_WIDTH,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0, -1.0, false,
			seal_x, seal_x != 0.0, 0.0, screen_d)
	var q_clean: float = AIActionScoring.open_net_danger(
			pos, _net, _goalie, GameRules.NET_HALF_WIDTH,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0, -1.0, false,
			seal_x, seal_x != 0.0, 0.0, 0.0)
	assert_true(q_screened >= q_clean - 0.0001,
			"a screen never lowers the goalie-hole quality (%.4f vs %.4f)"
			% [q_screened, q_clean])
	assert_lt(fielded, exact + ERR_BOUND,
			"fielded never overstates a screened shooter beyond the interp bound")


func test_goalie_move_invalidates_and_tracks() -> void:
	var pos := Vector3(4.0, 0.0, -17.0)
	var none: Array[Vector3] = []
	var moved := Vector3(-1.2, 0.0, -(GameRules.GOAL_LINE_Z - 1.4))
	var before: float = _fielded(pos, _goalie, none)
	var after: float = _fielded(pos, moved, none)
	assert_almost_eq(after, _exact(pos, moved, none), ERR_BOUND,
			"post-move sample tracks the moved goalie, not the stale memo")
	assert_ne(before, after,
			"a 1.4 m goalie displacement must change this look's quality")


func test_within_eps_move_serves_the_memo() -> void:
	var pos := Vector3(4.0, 0.0, -17.0)
	var none: Array[Vector3] = []
	var nudged: Vector3 = _goalie + Vector3(0.1, 0.0, 0.0)
	var before: float = _fielded(pos, _goalie, none)
	# Not bit-identical any more, and deliberately so: the lattice stores
	# MARGINS and the margin→danger map runs at query time against the LIVE
	# keeper (see AIDangerField.quality). A sub-epsilon nudge therefore re-serves
	# the cached vertices — the expensive geometry — while the cheap mapping
	# term tracks the real goalie exactly instead of being frozen at whatever
	# position happened to warm the cache. That residual is a fidelity gain, so
	# the assert is "the geometry was not recomputed", not "nothing moved".
	assert_almost_eq(_fielded(pos, nudged, none), before, 0.005,
			"a sub-epsilon goalie nudge re-serves the memoized vertices")


func test_reset_clears_the_memo() -> void:
	var pos := Vector3(4.0, 0.0, -17.0)
	var none: Array[Vector3] = []
	var moved: Vector3 = _goalie + Vector3(0.15, 0.0, 0.0)
	var before: float = _fielded(pos, _goalie, none)
	AIDangerField.reset()
	# Post-reset, the nudged goalie (inside epsilon of the OLD memo) must be
	# recomputed fresh rather than served stale.
	assert_almost_eq(_fielded(pos, moved, none), _exact(pos, moved, none),
			ERR_BOUND, "reset drops the memo — fresh compute against the new goalie")
	assert_almost_eq(before, _exact(pos, _goalie, none), ERR_BOUND,
			"pre-reset value was itself calibrated (guards a vacuous test)")


func test_pairwise_ranking_preserved() -> void:
	# The property the comparative consumers rely on: whenever two spots
	# differ by a real margin in the exact model, the fielded read agrees on
	# which is more dangerous.
	var none: Array[Vector3] = []
	var probes: Array[Vector3] = _probes()
	var exact_v: Array[float] = []
	var fielded_v: Array[float] = []
	for p: Vector3 in probes:
		exact_v.append(_exact(p, _goalie, none))
		fielded_v.append(_fielded(p, _goalie, none))
	var violations: int = 0
	for a: int in probes.size():
		for b: int in probes.size():
			if exact_v[a] - exact_v[b] > RANK_GAP \
					and fielded_v[a] <= fielded_v[b]:
				violations += 1
	assert_eq(violations, 0,
			"no pairwise order flips across gaps larger than RANK_GAP")
