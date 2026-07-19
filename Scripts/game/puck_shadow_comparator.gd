class_name PuckShadowComparator
extends RefCounted

# Phase-0 determinism go/no-go instrument (docs/netcode-phase0-shadow-puck-spec.md).
# Runs a SHADOW puck — the analytic AITrajectory.step_puck_3d model (grounded slide +
# the airborne gravity channel), the same family the AI already trusts to match Jolt —
# alongside the authoritative Jolt puck, and accumulates how far the two diverge. It
# NEVER drives the real puck: pure measurement. Host-only, dev-only (the caller gates on
# a dev flag + is_host). Divergence is the full 3D distance, so loft shots / saucer
# passes / glove rebounds contribute their vertical error too, not just the XZ slide.
#
# Two comparison modes (run a session in each; they answer different questions):
#  - PER_TICK_STEP: every tick, step the shadow ONE tick from the real puck's CURRENT
#    state and compare that one-step prediction to the real puck's NEXT state.
#    Isolates per-interaction modeling error — tells you WHICH thing diverges
#    (friction rate? bounce angle?) without accumulation masking it.
#  - FREE_RUN: seed the shadow once on loose entry, then free-run it and compare every
#    tick. Measures accumulated drift over a whole flight — the headline number that
#    decides whether a predicted puck would reconcile gently.
#
# Rim-around / containment track: the real (Jolt) puck can squeeze past the boundary
# in the rounded corners and leave the rink (the "falls out of the arena" bug the
# board_rescue_velocity hack patches). The shadow is analytically clamped by
# clamp_to_rink_inner and CANNOT. `real_escape_ticks` counts how often Jolt left the
# rink while the shadow stayed contained — the direct measure of the bug the analytic
# sim fixes. It is judged on its own merits, not against Jolt (Jolt's rim-around IS
# the bug).
#
# Feed one authoritative tick of the loose puck via observe(); call reset() whenever
# the puck stops being a free loose puck (carried / frozen / whistled) so each flight
# re-seeds cleanly. reset_session() zeroes the accumulated stats for a fresh run.

enum Mode { PER_TICK_STEP, FREE_RUN }

# Ticks after a board contact during which divergence is bucketed as "post-bounce"
# (where a wrong reflection angle shows up) rather than "free-flight".
const _POST_BOUNCE_WINDOW: int = 6
# How far outside the analytic boundary the real puck must sit to count as an escape
# (past float noise on the boundary itself).
const _ESCAPE_EPS: float = 0.02
const _ESCAPE_EPS_SQ: float = _ESCAPE_EPS * _ESCAPE_EPS
# The puck within this of the rink boundary counts as a board contact — catches the
# glancing rim-arounds the coarse puck_hit_boards signal (hard perpendicular hits only)
# misses. Detected analytically from the boundary, so it can't be undercounted.
const _BOARD_PROXIMITY_M: float = 0.3
# FREE_RUN self-limit: two puck sims decorrelate CHAOTICALLY over many bounces, so an
# unbounded free-run of a puck that stays loose for tens of seconds measures noise, not
# model error (a 40 m "divergence" is just two unrelated trajectories). Re-seed once the
# shadow drifts past this and count it, so FREE_RUN reports "tracks to within X before
# decorrelating" instead of nonsense. PER_TICK_STEP (the default) doesn't have this
# problem — it re-seeds every tick.
const _FREE_RUN_RESEED_M: float = 3.0

# PER_TICK_STEP is the default: it re-seeds from the real puck every tick, so it never
# decorrelates and its error is a bounded, meaningful per-interaction signal (~zero in
# free flight, spiking at bounces/clamps — the rim-around fidelity). FREE_RUN measures
# accumulated drift over a SHORT flight and needs reset() at flight boundaries.
var mode: int = Mode.PER_TICK_STEP

# ── Shadow state ──────────────────────────────────────────────────────────────
var _shadow_pos: Vector3 = Vector3.ZERO
var _shadow_vel: Vector3 = Vector3.ZERO
var _seeded: bool = false
# PER_TICK_STEP: the one-step prediction made LAST tick, compared to real THIS tick.
var _pending_pred_pos: Vector3 = Vector3.ZERO
var _has_pending_pred: bool = false
# Bounce-angle: the shadow's reflected velocity stashed at a board-contact tick, to
# compare against the real puck's actual post-bounce velocity one tick later.
var _pending_bounce_vel: Vector3 = Vector3.ZERO
var _has_pending_bounce: bool = false
var _post_bounce_ticks: int = 0

# ── Accumulated stats (session) ───────────────────────────────────────────────
var samples: int = 0
var div_sum: float = 0.0
var div_max: float = 0.0
var free_flight_div_max: float = 0.0
var post_bounce_div_max: float = 0.0
var bounce_events: int = 0
var bounce_angle_err_sum_deg: float = 0.0
var real_escape_ticks: int = 0
var free_run_reseeds: int = 0
# Airborne sub-bucket: how many samples were taken while the real puck was off the ice,
# and the worst divergence among them — the direct read on whether the gravity channel
# (loft shots / saucer passes / glove rebounds) reconciles as well as the grounded slide.
var airborne_samples: int = 0
var airborne_div_max: float = 0.0
var _real_airborne: bool = false


# Drop the per-flight shadow so the next observe() re-seeds. Call on loose↔carried /
# dead-puck transitions. Session stats persist (use reset_session to zero them).
func reset() -> void:
	_seeded = false
	_has_pending_pred = false
	_has_pending_bounce = false
	_post_bounce_ticks = 0


func reset_session() -> void:
	reset()
	samples = 0
	div_sum = 0.0
	div_max = 0.0
	free_flight_div_max = 0.0
	post_bounce_div_max = 0.0
	bounce_events = 0
	bounce_angle_err_sum_deg = 0.0
	real_escape_ticks = 0
	free_run_reseeds = 0
	airborne_samples = 0
	airborne_div_max = 0.0


# Feed one authoritative tick of the real (Jolt) loose puck. `board_contact` = the
# real puck hit a board this tick (from Puck._on_body_entered classification).
# Returns the shadow position for optional ghost rendering.
func observe(real_pos: Vector3, real_vel: Vector3, board_contact: bool, dt: float) -> Vector3:
	# Bucket this sample as airborne if the real puck is off the ice or moving vertically
	# (the same test step_puck_3d uses to branch ballistic vs grounded).
	_real_airborne = AITrajectory.is_puck_airborne(real_pos, real_vel)
	var real_xz := Vector2(real_pos.x, real_pos.z)
	# Containment: did Jolt leave the rink this tick? The shadow can't, by construction.
	# NOTE: on the live host this usually reads 0 even during a bad rim-around, because
	# the C1 board_rescue_velocity hack in Puck._integrate_forces reseats the puck BEFORE
	# _physics_process feeds it here — so the true rim-around escape frequency is the C1
	# rescue count, instrumented separately, not this field.
	if GameRules.clamp_to_rink_inner(real_xz).distance_squared_to(real_xz) > _ESCAPE_EPS_SQ:
		real_escape_ticks += 1

	# Board contact = the coarse signal OR the puck sitting within _BOARD_PROXIMITY_M of
	# the boundary (analytic — catches glancing rim-arounds the signal misses).
	var near_board: bool = GameRules.clamp_to_rink_inner(real_xz, _BOARD_PROXIMITY_M) \
			.distance_squared_to(real_xz) > 1e-6
	var contact: bool = board_contact or near_board

	# Resolve a pending bounce-angle comparison against this tick's real velocity
	# (the real puck's post-bounce direction, one tick after the contact).
	if _has_pending_bounce:
		_has_pending_bounce = false
		var sh := Vector2(_pending_bounce_vel.x, _pending_bounce_vel.z)
		var rl := Vector2(real_vel.x, real_vel.z)
		if sh.length_squared() > 1e-6 and rl.length_squared() > 1e-6:
			bounce_events += 1
			bounce_angle_err_sum_deg += rad_to_deg(absf(sh.angle_to(rl)))

	if contact:
		_post_bounce_ticks = _POST_BOUNCE_WINDOW

	match mode:
		Mode.PER_TICK_STEP:
			if _has_pending_pred:
				_record_divergence(_pending_pred_pos.distance_to(real_pos))
			var s: Transform3D = AITrajectory.step_puck_3d(real_pos, real_vel, dt)
			_pending_pred_pos = s.origin
			_has_pending_pred = true
			_shadow_pos = s.origin
			_shadow_vel = s.basis.x
			if contact:
				_pending_bounce_vel = s.basis.x
				_has_pending_bounce = true
		Mode.FREE_RUN:
			if not _seeded:
				_shadow_pos = real_pos
				_shadow_vel = real_vel
				_seeded = true
			else:
				var s: Transform3D = AITrajectory.step_puck_3d(_shadow_pos, _shadow_vel, dt)
				_shadow_pos = s.origin
				_shadow_vel = s.basis.x
				var d: float = _shadow_pos.distance_to(real_pos)
				_record_divergence(d)
				if contact:
					_pending_bounce_vel = _shadow_vel
					_has_pending_bounce = true
				# Chaotic decorrelation guard: once the two pucks are this far apart the
				# free-run is measuring noise — re-seed and count it (see _FREE_RUN_RESEED_M).
				if d > _FREE_RUN_RESEED_M:
					_shadow_pos = real_pos
					_shadow_vel = real_vel
					free_run_reseeds += 1

	if _post_bounce_ticks > 0:
		_post_bounce_ticks -= 1
	return _shadow_pos


func _record_divergence(d: float) -> void:
	samples += 1
	div_sum += d
	div_max = maxf(div_max, d)
	if _real_airborne:
		airborne_samples += 1
		airborne_div_max = maxf(airborne_div_max, d)
	if _post_bounce_ticks > 0:
		post_bounce_div_max = maxf(post_bounce_div_max, d)
	else:
		free_flight_div_max = maxf(free_flight_div_max, d)


func avg_divergence() -> float:
	return div_sum / float(samples) if samples > 0 else 0.0


func avg_bounce_angle_err_deg() -> float:
	return bounce_angle_err_sum_deg / float(bounce_events) if bounce_events > 0 else 0.0


# One-line session digest for the F-overlay / log header.
func summary() -> String:
	return ("shadow-puck[%s]: n=%d avg=%.3fm max=%.3fm free_max=%.3fm bounce_max=%.3fm " +
			"air_n=%d air_max=%.3fm bounce_ang=%.1f° (%d) jolt_escapes=%d reseeds=%d") % [
		"per-tick" if mode == Mode.PER_TICK_STEP else "free-run",
		samples, avg_divergence(), div_max, free_flight_div_max, post_bounce_div_max,
		airborne_samples, airborne_div_max,
		avg_bounce_angle_err_deg(), bounce_events, real_escape_ticks, free_run_reseeds]
