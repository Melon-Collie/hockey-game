class_name PerfProbe
extends Object

# Debug freeze switches for the per-actor COSMETIC work, plus the per-mode
# accumulator that makes comparing them meaningful.
#
# Why this exists: the F3 "Frame cost" section can prove the main thread owns the
# frame, but it cannot say WHICH main-thread work — and the editor profiler only
# attributes GDScript. On a 5v5 frame the script functions total ~3 ms while the
# idle step costs ~10 ms, so most of the cost has no function to blame: it is
# engine-side transform propagation and RenderingServer pushes, triggered BY
# cheap script, once per moved Node3D. A skater carries ~38 mesh nodes. No
# profiler confirms that the COUNT of transform writes is what dominates —
# turning the writes off and reading the frame does.
#
# Each switch suppresses only write-only cosmetic updates — poses nothing reads
# back. Gameplay is unaffected: it reads the `blade` / Marker3D anchors and the
# physics body, never the cosmetic mesh transforms these produce.
#
# WHAT YOU SEE while frozen is wrong on purpose: rigs hold their last pose, HUD
# rings stop tracking, trails streak. That is the cost being removed. Never read
# gameplay behaviour or a shippable frame rate off a frozen run.
#
# ── Why the accumulator, and why auto-cycle ──────────────────────────────────
# The first run of this probe was inconclusive in a way worth recording, because
# the same trap catches every hand-run A/B here. Modes were sampled one at a
# time by eye, each from an instantaneous reading. The result had ALL-frozen
# measuring SLOWER than RIG-frozen — impossible when the freezes stack — and
# draw calls swinging 1300→1860 with MORE frozen. Neither is a freeze effect;
# both are the camera pointing somewhere else. A 5v5 frame varies by more than
# the ~1-2 ms being hunted, so any protocol that samples one mode at one moment
# measures the moment, not the mode.
#
# Two fixes, together:
#   • Accumulate. Every frame adds to its current mode's running mean, so a
#     comparison rests on thousands of frames instead of one.
#   • Interleave. Auto-cycle rotates the mode on a short timer, so each mode
#     samples the SAME distribution of camera angles, scrums and open ice.
#     Without this, holding one mode for a minute just measures that minute.
# Reading one mode for a long time is exactly the mistake that produced the bad
# run; rotating fast and averaging is what makes the modes comparable.

enum Mode {
	NONE,
	RIG,        # the whole cosmetic rig: pose SOLVE + pose WRITE, render rate
	RIG_WRITE,  # the WRITE half only — bone poses and the stick/arm rebuild
	HUD,        # per-skater world HUD — now almost entirely ice-shader uniforms
	VFX,        # SkaterVFX per-frame emitter bookkeeping
	SCRATCH,    # IceScratchMap: per-frame skater sweep AND its SubViewport repaint
	ALL,
}

const MODE_COUNT: int = 7
const MODE_NAMES: Array[String] = [
	"off", "RIG frozen", "RIG writes frozen", "HUD frozen", "VFX frozen",
	"SCRATCH frozen", "ALL frozen",
]

# Read directly on hot paths, so they are plain bools rather than a mode compare
# or an accessor call — checked once per skater per frame (RIG/VFX) or per tick
# (HUD).
static var freeze_rig: bool = false
# Splits RIG in half. freeze_rig suppresses BOTH the pose solve (the gait, head
# tracking and off-hand IK behind Skater.render_pose_update) and the pose write
# (update_stick_mesh / update_arm_mesh / update_bottom_arm_mesh, which write bone
# poses and dirty both skeletons). Those are very different things to fix, and
# the sweep could not tell them apart — RIG measured 2.08 ms without saying
# whether that was arithmetic or transform plumbing.
#
# This one suppresses ONLY the write half, so:
#     write cost = off − RIG_WRITE
#     solve cost = RIG_WRITE − RIG
# Which one dominates decides whether the next move is cheaper math, or fewer /
# rarer writes.
static var freeze_rig_write: bool = false
static var freeze_hud: bool = false
static var freeze_vfx: bool = false
# Unlike the other three, this one has a player-facing equivalent (Options →
# Video → Ice Scratches), so its measurement answers a shipping question and not
# just an internal one: what that switch is actually worth. The probe path is
# separate from the pref's set_enabled() on purpose — set_enabled wipes the
# accumulated scratches, and a sweep toggling every 2 s would pay for repeated
# clears that a player flipping the option once never would, pricing teardown
# churn instead of the steady-state cost.
static var freeze_scratches: bool = false

# Typed int rather than Mode: cycling assigns an arithmetic result, and casting
# that back to the enum trips Godot's INT_AS_ENUM analyzer warning for no gain.
# Enum members are ints, so `mode == Mode.RIG` still reads the same.
static var mode: int = Mode.NONE

static var auto_cycle: bool = false
# One ROTATION is one observation (see the rotation-statistics block below), so
# this is really "how fast do independent samples arrive". Short, because a
# sweep's precision is set by the NUMBER of windows, not the frames inside them
# — halving this doubles the observations per minute of play. The floor is
# SETTLE_SECONDS, which is dead time in every window: at 1 s a quarter of the
# sweep is discarded, which is the price paid for twice the statistical power.
const AUTO_CYCLE_SECONDS: float = 1.0
static var _auto_timer: float = 0.0

# Frames discarded after a mode switch. The GPU timing query trails the CPU by a
# frame or two, so the first samples in a new mode still carry the old mode's
# render cost — charging those to the new mode blunts exactly the difference
# being measured.
const SETTLE_SECONDS: float = 0.25
static var _since_switch: float = 0.0

# Per-mode running totals, indexed by Mode. Float64 because a long session
# accumulates millions of milliseconds and float32 would quietly stop adding
# small samples.
# One slot per Mode — these MUST stay MODE_COUNT long. A short array does not
# fail loudly here: the out-of-range mode silently records nothing and reports a
# mean of zero, which reads as "that mode was free" rather than as an error.
# Sized from MODE_COUNT via resize() so adding a mode cannot leave them behind.
static var _samples: PackedInt64Array = _new_int_bins()
static var _sum_frame_ms: PackedFloat64Array = _new_float_bins()
static var _sum_main_ms: PackedFloat64Array = _new_float_bins()
static var _sum_gpu_ms: PackedFloat64Array = _new_float_bins()
static var _sum_draws: PackedFloat64Array = _new_float_bins()


static func _new_int_bins() -> PackedInt64Array:
	var a := PackedInt64Array()
	a.resize(MODE_COUNT)
	return a


static func _new_float_bins() -> PackedFloat64Array:
	var a := PackedFloat64Array()
	a.resize(MODE_COUNT)
	return a


# ── Rotation statistics ──────────────────────────────────────────────────────
# THE UNIT OF OBSERVATION IS A ROTATION, NOT A FRAME. Frames inside one window
# share a camera angle and one moment of play, so they are not independent
# samples of "what this mode costs" — they are ~200 near-copies of a single
# sample. Averaging them as if they were independent is pseudo-replication, and
# it makes a sweep look enormously precise while actually resting on three
# observations per mode. That is how a run came back with three of four freezes
# measuring SLOWER than doing the work, which is impossible: the spread between
# windows dwarfed the effect, and nothing in the output admitted it.
#
# So each rotation contributes ONE number — its own mean — and the mode's
# statistics are computed across those. That also buys an error bar, which is
# the part that actually settles arguments: a 0.3 ms difference between modes
# means nothing if the rotation-to-rotation spread is 1.5 ms, and now the panel
# can say so instead of inviting the reader to believe the ranking.
static var _rot_count: PackedInt64Array = _new_int_bins()
static var _rot_sum: PackedFloat64Array = _new_float_bins()
static var _rot_sum_sq: PackedFloat64Array = _new_float_bins()

# Live rotation, flushed into the arrays above when the mode changes.
static var _cur_frames: int = 0
static var _cur_main_sum: float = 0.0
# A rotation with too few frames (a hitch, or a switch right after settling) is
# a noisy observation; dropping it beats letting it carry a full vote.
const MIN_FRAMES_PER_ROTATION: int = 20
# Rotations each mode needs before differences are worth reading. This is the
# real sample size — 10 windows spread across the run, not 600 frames.
const MIN_ROTATIONS_PER_MODE: int = 10


# Advances to the next mode and returns its label for the caller to surface.
static func cycle() -> String:
	_set_mode((mode + 1) % MODE_COUNT)
	return MODE_NAMES[mode]


static func _set_mode(m: int) -> void:
	_flush_rotation()
	mode = m
	freeze_rig = mode == Mode.RIG or mode == Mode.ALL
	freeze_rig_write = freeze_rig or mode == Mode.RIG_WRITE
	freeze_hud = mode == Mode.HUD or mode == Mode.ALL
	freeze_vfx = mode == Mode.VFX or mode == Mode.ALL
	freeze_scratches = mode == Mode.SCRATCH or mode == Mode.ALL
	_since_switch = 0.0


static func mode_name() -> String:
	return MODE_NAMES[mode]


# Drives the settle gate and the auto rotation. Call once per rendered frame.
static func tick(delta: float) -> void:
	_since_switch += delta
	if not auto_cycle:
		return
	_auto_timer -= delta
	if _auto_timer <= 0.0:
		_auto_timer = AUTO_CYCLE_SECONDS
		_set_mode((mode + 1) % MODE_COUNT)


# Starts or stops the interleaved sweep. Starting clears the accumulators: stats
# gathered by hand before the sweep were taken under the flawed protocol this
# class exists to replace, and averaging the two together would reintroduce it.
static func set_auto_cycle(on: bool) -> void:
	auto_cycle = on
	_auto_timer = AUTO_CYCLE_SECONDS
	if on:
		reset_stats()
		_set_mode(Mode.NONE)
	else:
		_set_mode(Mode.NONE)


# One frame's raw (unsmoothed) costs, charged to whichever mode is live. Raw is
# correct here — the mean over thousands of samples is the smoothing, and
# pre-smoothing would bleed one mode's cost across a switch.
static func record(frame_ms: float, main_ms: float, gpu_ms: float, draws: int) -> void:
	# ONLY the interleaved sweep may contribute. Without this gate, every second
	# spent with the panel open outside a sweep piled into whichever mode was
	# left selected — in practice "off", which then carried both interleaved
	# samples and a long uninterleaved tail. That is precisely the un-matched
	# sampling the sweep exists to prevent, and it silently corrupts the one
	# bucket every other mode is compared against.
	if not auto_cycle:
		return
	if _since_switch < SETTLE_SECONDS:
		return
	_samples[mode] += 1
	_sum_frame_ms[mode] += frame_ms
	_sum_main_ms[mode] += main_ms
	_sum_gpu_ms[mode] += gpu_ms
	_sum_draws[mode] += float(draws)
	_cur_frames += 1
	_cur_main_sum += main_ms


# Closes the live rotation and banks its mean as ONE observation for the mode it
# belonged to. Called on every mode change, so it always credits the outgoing
# mode — never the incoming one.
static func _flush_rotation() -> void:
	if _cur_frames >= MIN_FRAMES_PER_ROTATION:
		var rot_mean: float = _cur_main_sum / float(_cur_frames)
		_rot_count[mode] += 1
		_rot_sum[mode] += rot_mean
		_rot_sum_sq[mode] += rot_mean * rot_mean
	_cur_frames = 0
	_cur_main_sum = 0.0


static func rotations(m: int) -> int:
	return _rot_count[m]


# Mean of the per-rotation means — the headline number, and the one the error
# bar below belongs to.
static func rotation_mean_main_ms(m: int) -> float:
	if _rot_count[m] == 0:
		return 0.0
	return _rot_sum[m] / float(_rot_count[m])


# Standard error of that mean across rotations. This is the number that says
# whether a gap between two modes is real; a difference inside a couple of these
# is not a finding, however many frames fed it.
static func rotation_stderr_main_ms(m: int) -> float:
	var k: int = _rot_count[m]
	if k < 2:
		return INF
	var mean: float = _rot_sum[m] / float(k)
	var variance: float = (_rot_sum_sq[m] - float(k) * mean * mean) / float(k - 1)
	if variance <= 0.0:
		return 0.0
	return sqrt(variance / float(k))


# Whether a mode's gap from baseline clears the noise of BOTH measurements.
# Two standard errors on the difference — the usual bar for "not chance".
static func difference_resolved(m: int, baseline: int) -> bool:
	var se_a: float = rotation_stderr_main_ms(m)
	var se_b: float = rotation_stderr_main_ms(baseline)
	if not is_finite(se_a) or not is_finite(se_b):
		return false
	var diff: float = absf(rotation_mean_main_ms(baseline) - rotation_mean_main_ms(m))
	return diff > 2.0 * sqrt(se_a * se_a + se_b * se_b)


static func sample_count(m: int) -> int:
	return _samples[m]


static func mean_frame_ms(m: int) -> float:
	return _sum_frame_ms[m] / float(maxi(_samples[m], 1))


static func mean_main_ms(m: int) -> float:
	return _sum_main_ms[m] / float(maxi(_samples[m], 1))


static func mean_gpu_ms(m: int) -> float:
	return _sum_gpu_ms[m] / float(maxi(_samples[m], 1))


static func mean_draws(m: int) -> float:
	return _sum_draws[m] / float(maxi(_samples[m], 1))


# True once every mode carries enough frames that the means are worth reading.
# Below this the spread between modes is smaller than the run-to-run noise, and
# reporting a difference would repeat the mistake documented at the top.
static func comparison_ready() -> bool:
	for m: int in MODE_COUNT:
		if _rot_count[m] < MIN_ROTATIONS_PER_MODE:
			return false
	return true


static func reset_stats() -> void:
	for m: int in MODE_COUNT:
		_samples[m] = 0
		_sum_frame_ms[m] = 0.0
		_sum_main_ms[m] = 0.0
		_sum_gpu_ms[m] = 0.0
		_sum_draws[m] = 0.0
		_rot_count[m] = 0
		_rot_sum[m] = 0.0
		_rot_sum_sq[m] = 0.0
	_cur_frames = 0
	_cur_main_sum = 0.0


# Match teardown must not leave a freeze latched — the switches are static, so
# they outlive the scene that was being measured and would silently corrupt the
# next session's numbers (and its visuals).
static func reset() -> void:
	auto_cycle = false
	_set_mode(Mode.NONE)
	reset_stats()
	# IceScratchMap restores its own viewport update mode on the first unfrozen
	# _process, so clearing the flag here is the whole restore — nothing to undo
	# on a node that may already be gone at teardown.
