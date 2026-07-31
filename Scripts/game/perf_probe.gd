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
	RIG,   # marker-driven stick + arm mesh rebuild, render rate, ~20 transform writes/skater/frame
	HUD,   # per-skater world HUD (ring, name, chevrons, beacon) — currently PHYSICS rate
	VFX,   # SkaterVFX per-frame emitter bookkeeping
	ALL,
}

const MODE_COUNT: int = 5
const MODE_NAMES: Array[String] = ["off", "RIG frozen", "HUD frozen", "VFX frozen", "ALL frozen"]

# Read directly on hot paths, so they are plain bools rather than a mode compare
# or an accessor call — checked once per skater per frame (RIG/VFX) or per tick
# (HUD).
static var freeze_rig: bool = false
static var freeze_hud: bool = false
static var freeze_vfx: bool = false

# Typed int rather than Mode: cycling assigns an arithmetic result, and casting
# that back to the enum trips Godot's INT_AS_ENUM analyzer warning for no gain.
# Enum members are ints, so `mode == Mode.RIG` still reads the same.
static var mode: int = Mode.NONE

static var auto_cycle: bool = false
# Short enough that a rotation samples one continuous "situation" rather than a
# whole possession, so no mode systematically inherits the calm or busy parts of
# play; long enough to clear SETTLE_SECONDS several times over.
const AUTO_CYCLE_SECONDS: float = 2.0
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
static var _samples: PackedInt64Array = PackedInt64Array([0, 0, 0, 0, 0])
static var _sum_frame_ms: PackedFloat64Array = PackedFloat64Array([0, 0, 0, 0, 0])
static var _sum_main_ms: PackedFloat64Array = PackedFloat64Array([0, 0, 0, 0, 0])
static var _sum_gpu_ms: PackedFloat64Array = PackedFloat64Array([0, 0, 0, 0, 0])
static var _sum_draws: PackedFloat64Array = PackedFloat64Array([0, 0, 0, 0, 0])


# Advances to the next mode and returns its label for the caller to surface.
static func cycle() -> String:
	_set_mode((mode + 1) % MODE_COUNT)
	return MODE_NAMES[mode]


static func _set_mode(m: int) -> void:
	mode = m
	freeze_rig = mode == Mode.RIG or mode == Mode.ALL
	freeze_hud = mode == Mode.HUD or mode == Mode.ALL
	freeze_vfx = mode == Mode.VFX or mode == Mode.ALL
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
const MIN_SAMPLES_PER_MODE: int = 600

static func comparison_ready() -> bool:
	for m: int in MODE_COUNT:
		if _samples[m] < MIN_SAMPLES_PER_MODE:
			return false
	return true


static func reset_stats() -> void:
	for m: int in MODE_COUNT:
		_samples[m] = 0
		_sum_frame_ms[m] = 0.0
		_sum_main_ms[m] = 0.0
		_sum_gpu_ms[m] = 0.0
		_sum_draws[m] = 0.0


# Match teardown must not leave a freeze latched — the switches are static, so
# they outlive the scene that was being measured and would silently corrupt the
# next session's numbers (and its visuals).
static func reset() -> void:
	auto_cycle = false
	_set_mode(Mode.NONE)
	reset_stats()
