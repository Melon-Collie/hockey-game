class_name AIDangerField

# Memoized goalie-hole danger surface — the cached core of the defensive
# threat reads.
#
# WHAT IS CACHED. The expensive part of score_shoot is open_net_danger: the
# per-band hole geometry against the goalie (tangent-cone cover, reaction-
# gated reach race, post-seal erasure — ~20 of score_shoot's ~29 µs). For
# the THREAT-SURFACE consumer family (threat_surface_shoot /
# threat_local_shoot, the turnover costs built on them, the zone soft-lock's
# finish-danger read) every input to that core except the GOALIE'S POSITION
# is a constant or a pure function of the shooter position: league wrister
# pace, unsettled 0, no pose reads (hands/pads ABSENT → declared-stance
# fallback), spread 0, post seal derived from the shooter spot. So for this
# family the core is a surface over shooter position re-keyed only by goalie
# motion — this class memoizes it on a per-net vertex grid and serves
# bilinear samples.
#
# WHAT STAYS LIVE PER QUERY. Defender-dependent terms — the shot lane and
# the release contest — are cheap and applied by the caller
# (AIActionScoring.score_shoot_threat_fielded) against the live defender
# list, so the hypothetical-self mechanic (a candidate body blocking the
# lane) stays exact. The one defender effect the field DROPS is sightline
# screening (a body delaying the goalie's read RAISES the true quality), so
# the fielded read understates a screened shooter's threat by that term —
# bounded, with the interpolation error, by tests/unit/ai/test_danger_field.gd.
#
# EXACTNESS. A sample equals the exact core computed with a goalie at most
# GOALIE_EPS_M from the live one (each vertex stores the goalie position it
# was computed against and revalidates against the position the query
# passes — no TTL, no tick coupling, so the memo is pure w.r.t. its
# inputs). Vertices behind the goal line store 0 (no direct shot exists
# from back there; the callers' behind-line guard zeroes those queries
# before sampling — the stored 0 only feeds interpolation just in front of
# the line). Queries outside the grid region (possible when a displaced
# goalie voids the callers' out-of-zone skip) fall through to the exact
# core compute, unmemoized.
#
# Host-only AI bookkeeping (static state, like AIActionScoring's difficulty
# sync statics); never touched by reconcile replay. Assumes the standard
# net (every live caller passes GameRules.NET_HALF_WIDTH). Call reset() at
# match start / in test setup.

# WHAT IS STORED PER VERTEX: the signed goalie-hole MARGIN (radians), not the
# 0..1 danger. The margin is smooth geometry — post bearings against a cover
# edge — while danger is that margin pushed through a sigmoid, and the
# sigmoid's knee is the steepest feature anywhere on the surface. Bilinear
# interpolation is exact for a linear function and worst at a knee, so
# interpolating the margin and mapping AFTERWARDS puts the lattice where it is
# accurate and the nonlinearity where it costs nothing (the map is a per-query
# scalar either way). Storing the mapped value instead measured 0.284 max
# error on the probe lattice against a 0.07 bound; the same lattice storing
# margins is well inside it.
#
# 0.75 m: the surface has real cliffs (hole-opening thresholds as range
# closes), and because vertices are computed lazily per query, finer spacing
# costs only sharing — each query still warms at most its 4 surrounding
# vertices.
const VERTEX_SPACING_M: float = 0.75
# A vertex recomputes when the live goalie is farther than this from the
# goalie it was computed against — the staleness bound is a physical body
# displacement, not a time.
const GOALIE_EPS_M: float = 0.25

const _U_MIN: float = GameRules.BLUE_LINE_Z
const _U_MAX: float = GameRules.RINK_HALF_LENGTH
const _X_MIN: float = -GameRules.RINK_HALF_WIDTH
const _NX: int = int(GameRules.RINK_HALF_WIDTH * 2.0 / VERTEX_SPACING_M) + 2
const _NU: int = int((_U_MAX - _U_MIN) / VERTEX_SPACING_M) + 2

# Per-net storage (index 0 = net at +GOAL_LINE_Z, 1 = net at −GOAL_LINE_Z),
# parallel flat arrays indexed iu * _NX + ix.
static var _quality: Array[PackedFloat32Array] = []
static var _goalie_at: Array[PackedVector3Array] = []
static var _valid: Array[PackedByteArray] = []


# The memoized goalie-hole quality for a shot from `shooter` at the net at
# `our_net`, against a goalie standing at `our_goalie_pos` — the
# open_net_danger core under the threat-family inputs (see the class doc).
# Bilinear over the four surrounding vertices' MARGINS (see VERTEX_SPACING_M),
# then mapped to danger; each vertex lazily (re)computed when its stored
# goalie drifts past GOALIE_EPS_M.
static func quality(shooter: Vector3, our_net: Vector3,
		our_goalie_pos: Vector3, net_half_width: float) -> float:
	var sign_z: float = signf(our_net.z)
	var u: float = shooter.z * sign_z   # depth axis: + toward the net's end wall
	var fx: float = (shooter.x - _X_MIN) / VERTEX_SPACING_M
	var fu: float = (u - _U_MIN) / VERTEX_SPACING_M
	if fx < 0.0 or fu < 0.0 or fx > float(_NX - 1) or fu > float(_NU - 1):
		# Outside the memoized region — exact compute, unmemoized (rare: only
		# reachable when a displaced goalie voids the callers' zone skip).
		return _core_quality(shooter, our_net, our_goalie_pos, net_half_width)
	_ensure_grids()
	var net_idx: int = 0 if sign_z > 0.0 else 1
	var ix: int = mini(int(fx), _NX - 2)
	var iu: int = mini(int(fu), _NU - 2)
	var tx: float = fx - float(ix)
	var tu: float = fu - float(iu)
	var q00: float = _vertex(net_idx, ix, iu, our_net, our_goalie_pos, net_half_width)
	var q10: float = _vertex(net_idx, ix + 1, iu, our_net, our_goalie_pos, net_half_width)
	var q01: float = _vertex(net_idx, ix, iu + 1, our_net, our_goalie_pos, net_half_width)
	var q11: float = _vertex(net_idx, ix + 1, iu + 1, our_net, our_goalie_pos, net_half_width)
	var margin: float = lerpf(lerpf(q00, q10, tx), lerpf(q01, q11, tx), tu)
	# Map at the QUERY's own position, not the vertices': the edge spread is a
	# function of the shooter-keeper range, so this term stays exact instead of
	# being interpolated along with everything else.
	return AIActionScoring.danger_from_margin(shooter, our_goalie_pos, margin)


# Invalidate every memoized vertex (both nets). Match start / tests.
static func reset() -> void:
	for v: PackedByteArray in _valid:
		v.fill(0)


static func _vertex(net_idx: int, ix: int, iu: int, our_net: Vector3,
		goalie: Vector3, net_half_width: float) -> float:
	var idx: int = iu * _NX + ix
	if _valid[net_idx][idx] != 0 \
			and _goalie_at[net_idx][idx].distance_squared_to(goalie) \
					<= GOALIE_EPS_M * GOALIE_EPS_M:
		return _quality[net_idx][idx]
	var u: float = _U_MIN + float(iu) * VERTEX_SPACING_M
	# Behind the goal line there is no shot in at all — structurally closed,
	# which maps to ~0 and interpolates sanely toward the vertices in front.
	var q: float = AIActionScoring.HOLE_STRUCTURALLY_CLOSED_RAD
	if u < GameRules.GOAL_LINE_Z:
		var sign_z: float = 1.0 if net_idx == 0 else -1.0
		var pos := Vector3(
				_X_MIN + float(ix) * VERTEX_SPACING_M, 0.0, u * sign_z)
		q = _core_margin(pos, our_net, goalie, net_half_width)
	_quality[net_idx][idx] = q
	_goalie_at[net_idx][idx] = goalie
	_valid[net_idx][idx] = 1
	# Return the STORED value (float32-rounded), not the fresh double — memo
	# hits must be bit-identical to the sample that populated them.
	return _quality[net_idx][idx]


# The exact core under the threat-family inputs — one source of truth for
# vertex computes, out-of-region queries, and the calibration test's
# reference values. Returns the DANGER (what callers want).
static func _core_quality(pos: Vector3, our_net: Vector3, goalie: Vector3,
		net_half_width: float) -> float:
	var seal_x: float = AIActionScoring.derive_post_seal_x_sign(pos, our_net)
	return AIActionScoring.open_net_danger(
			pos, our_net, goalie, net_half_width,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0, -1.0, false,
			seal_x, seal_x != 0.0)


# The same core stopped one step earlier, at the signed margin — what the
# lattice stores. Kept adjacent to _core_quality so the two cannot drift:
# _core_quality(p) must equal danger_from_margin(p, _core_margin(p)).
static func _core_margin(pos: Vector3, our_net: Vector3, goalie: Vector3,
		net_half_width: float) -> float:
	var seal_x: float = AIActionScoring.derive_post_seal_x_sign(pos, our_net)
	return AIActionScoring.best_signed_margin(
			pos, our_net, goalie, net_half_width,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0, -1.0, false,
			seal_x, seal_x != 0.0)


static func _ensure_grids() -> void:
	if _quality.size() == 2:
		return
	_quality.clear()
	_goalie_at.clear()
	_valid.clear()
	for _i: int in 2:
		var q := PackedFloat32Array()
		q.resize(_NX * _NU)
		var g := PackedVector3Array()
		g.resize(_NX * _NU)
		var v := PackedByteArray()
		v.resize(_NX * _NU)
		_quality.append(q)
		_goalie_at.append(g)
		_valid.append(v)
