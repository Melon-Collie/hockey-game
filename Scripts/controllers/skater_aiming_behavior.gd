class_name SkaterAimingBehavior
extends RefCounted

# ── Wrister charge state ──────────────────────────────────────────────────────
# Net signed angular sweep of the SHOT LINE about the pinned origin (radians),
# over the current stroke. Its SIGN is the forehand/backhand chirality
# (ShotMechanics.is_backhand_from_swing). Accumulated by ChargeTracking, reset
# with the rest of the stroke on a variance break, and saved/restored across
# reconcile like cursor_speed_ema.
var swing_rotation: float = 0.0
# Cursor (intent) position in SCREEN-space, packed into a Vector3 as
# (screen.x, 0, screen.y). The charge tracker reads its DIRECTION from
# the delta of this position frame-over-frame. Screen space is the
# camera-immune frame — pixel motion captures pure mouse drag intent
# regardless of camera lag, body rotation, or skater locomotion.
# Public (no underscore): LocalController saves and restores it across
# reconcile() replay alongside the rest of the charge state.
var prev_intent_pos: Vector3 = Vector3.ZERO
# Previous SHOT-LINE bearing: cursor minus the pinned wrister origin, the exact
# vector the release fires along (SkaterController._wrister_aim_dir). Its signed
# rotation between ticks is the swing chirality the forehand/backhand read
# classifies (ChargeTracking.swing_step), and its path length is the stroke travel.
# Measured about the ORIGIN rather than the body: the origin is where the puck sits
# and where the shot leaves from, so this rotates only when the player actually
# sweeps their aim — a body-relative bearing would also rotate with the ~1 m blade
# parallax, which is swing nobody made.
var prev_swing_bearing: Vector3 = Vector3.ZERO
var prev_blade_dir: Vector3 = Vector3.ZERO
# EMA of the raw SCREEN-space cursor speed (px/s) — THE wrister power signal.
# Unfiltered hand motion (unlike the old ROM-clamped, speed-capped blade
# speed): flick fast = hard, sweep slow = soft. Saved/restored across reconcile
# like the rest of the charge state.
var cursor_speed_ema: float = 0.0
# XZ path length (meters) of the shot-line bearing accumulated over the current
# stroke by ChargeTracking — the "did you actually sweep" signal that gates the
# wrister power CEILING (ShotMechanics.wrister_travel_cap_t, currently DORMANT —
# see SkaterController._wrister_stroke_travel).
# Resets with the stroke on a variance break; saved/restored across reconcile
# like cursor_speed_ema.
var stroke_travel: float = 0.0
# World position of the blade/puck at the MOMENT the wrister charge began (mouse
# down), captured in reset_wrister. This is a human shot's aim ORIGIN: the
# release fires along origin→cursor, so the
# aim is anchored where the stroke STARTED, not on the live blade (which has
# swung to an extreme by release — a leading, arcing point that made the aim
# whip at tight angles / a close cursor). Pinned at stroke start so it doesn't
# move as the stick sweeps. Saved/restored across reconcile like the rest of the
# charge state (set once on the entry edge; restored so replay can't re-perturb).
var wrister_origin_world: Vector3 = Vector3.ZERO
# Reused output for ChargeTracking.accumulate_into — a per-controller scratch so
# the per-tick charge update never allocates. Pure output (fully overwritten each
# call), so it needs no reconcile save/restore.
var _charge_result: ChargeTracking.Result = ChargeTracking.Result.new()

# ── Slapper charge state ──────────────────────────────────────────────────────
var slapper_charge_timer: float = 0.0
var one_timer_window_timer: float = 0.0

# ── Wrister ───────────────────────────────────────────────────────────────────

func reset_wrister(initial_intent_pos: Vector3, initial_swing_bearing: Vector3,
		initial_origin_world: Vector3 = Vector3.ZERO) -> void:
	swing_rotation = 0.0
	cursor_speed_ema = 0.0
	stroke_travel = 0.0
	prev_blade_dir = Vector3.ZERO
	prev_intent_pos = initial_intent_pos
	prev_swing_bearing = initial_swing_bearing
	wrister_origin_world = initial_origin_world


func tick_wrister_charge(
		intent_pos: Vector3,
		swing_bearing: Vector3,
		max_charge_direction_variance: float,
		delta: float,
		cursor_speed_smoothing: float,
		max_travel_step: float = INF) -> void:
	# Raw screen-space cursor speed (px/s), EMA-smoothed — THE wrister power
	# signal. Computed against the OLD prev_intent_pos before ChargeTracking's
	# result overwrites it below.
	if delta > 0.0:
		var screen_delta := intent_pos - prev_intent_pos
		screen_delta.y = 0.0
		var inst_speed: float = screen_delta.length() / delta
		var a: float = clampf(cursor_speed_smoothing * delta, 0.0, 1.0)
		cursor_speed_ema = lerpf(cursor_speed_ema, inst_speed, a)
	# ChargeTracking tracks the swing chirality (forehand/backhand), the
	# stroke's blade travel (the power-ceiling gate), and the variance-break
	# reset — power itself is the cursor speed above, not distance.
	# Fill a reused Result scratch instead of allocating a Dictionary every tick
	# (this runs at 120 Hz while charging, and re-runs per replayed input during
	# reconcile).
	ChargeTracking.accumulate_into(
			_charge_result,
			prev_intent_pos, intent_pos,
			prev_swing_bearing, swing_bearing,
			prev_blade_dir, max_charge_direction_variance, swing_rotation,
			stroke_travel, max_travel_step)
	swing_rotation = _charge_result.rotation
	stroke_travel = _charge_result.travel
	prev_blade_dir = _charge_result.direction
	prev_intent_pos = intent_pos
	prev_swing_bearing = swing_bearing



# ── Slapper ───────────────────────────────────────────────────────────────────

func reset_slapper() -> void:
	slapper_charge_timer = 0.0
	one_timer_window_timer = 0.0


func tick_slapper(delta: float) -> void:
	slapper_charge_timer += delta


func tick_one_timer_window(delta: float) -> void:
	if one_timer_window_timer > 0.0:
		one_timer_window_timer -= delta
