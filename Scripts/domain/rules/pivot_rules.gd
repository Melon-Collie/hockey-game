class_name PivotRules

# Pure pivot read for the gait: detection, phase, and the hip-yaw law of the
# facing↔travel swap (the open-hip / mohawk pivot). ψ is the travel direction
# expressed in the body frame (atan2(lat, fwd), radians; 0 = travel along
# facing) — the one coordinate in which the twin-stick scheme's two pivot
# producers (cursor swung across a held travel line, travel swung under a held
# cursor) are the same event: ψ transiting the lateral band. dψ/dt is the
# carve/pivot separator: ψ is travel heading minus facing heading, and a
# coordinated carve rotates both together (ψ barely moves) while a pivot whips
# the facing against travel. All functions are stateless; the caller owns the
# engage latch, the sense latch, and the smoothing, mirroring HockeyStopRules.

# Release hysteresis beyond the band edges, so the read never flickers when ψ
# hovers at a boundary. Completion exits through the far edge, an abort back
# through the entry edge — both release.
const RELEASE_MARGIN: float = 8.0 * PI / 180.0


static func should_engage(abs_psi: float, abs_psi_rate: float, ground_speed: float,
		band_lo: float, band_hi: float, rate_min: float, min_speed: float) -> bool:
	return ground_speed >= min_speed and abs_psi_rate >= rate_min \
			and abs_psi > band_lo and abs_psi < band_hi


static func should_release(abs_psi: float, ground_speed: float,
		band_lo: float, band_hi: float, min_speed: float) -> bool:
	return ground_speed < min_speed \
			or abs_psi <= band_lo - RELEASE_MARGIN \
			or abs_psi >= band_hi + RELEASE_MARGIN


# +1 = forward→backward (entered from the forward hemisphere), −1 = the return
# trip. Latched at engage so the transit keeps its identity as ψ crosses the
# band midpoint.
static func latch_sense(abs_psi: float, band_lo: float, band_hi: float) -> float:
	return 1.0 if abs_psi < 0.5 * (band_lo + band_hi) else -1.0


# Authority of the hold, ramping with how deep ψ sits in the band. The guard
# for a control scheme where the same cursor also stickhandles and aims: a
# quick flick that clips the band's shallow edge reads as a light hip lag —
# which is what a real quick re-aim produces — while a genuine transit that
# carries ψ deep earns the full hold.
static func hold_depth(abs_psi: float, band_lo: float, ramp: float) -> float:
	return clampf((abs_psi - band_lo) / maxf(ramp, 0.001), 0.0, 1.0)


# Progress through the transit in [0, 1], derived from ψ itself — not a timer —
# so a snap pivot and a slow open-hip glide read the same poses, and an aborted
# swing unwinds back through them.
static func phase(abs_psi: float, sense: float, band_lo: float, band_hi: float) -> float:
	var p: float = clampf((abs_psi - band_lo) / maxf(band_hi - band_lo, 0.001), 0.0, 1.0)
	return p if sense > 0.0 else 1.0 - p


# Lower-body yaw of the transit. The two anchor solutions of hip-to-travel
# alignment are hips ALONG travel (−ψ, forward skating) and hips ANTI travel
# (−ψ + π·sign(ψ), backward skating — square under the torso at ψ = π). Hold
# the entry anchor — the blades keep gliding the entry orientation while the
# torso swings over them — then smoothstep to the exit anchor over the
# transit's tail: the step-around.
static func pivot_yaw(psi: float, sense: float, p: float, step_begin: float) -> float:
	var along: float = -psi
	var anti: float = -psi + PI * signf(psi)
	var t: float = 0.0
	if p > step_begin:
		t = (p - step_begin) / maxf(1.0 - step_begin, 0.001)
		t = t * t * (3.0 - 2.0 * t)
	if sense > 0.0:
		return lerpf(along, anti, t)
	return lerpf(anti, along, t)
