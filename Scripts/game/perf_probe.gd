class_name PerfProbe
extends Object

# Debug freeze switches for the per-actor COSMETIC work, so its cost can be
# measured rather than estimated.
#
# Why this exists: the F3 "Frame cost" section can prove the main thread owns the
# frame, but it cannot say WHICH main-thread work — and the editor profiler only
# attributes GDScript. On a 5v5 frame the script functions total ~3 ms while the
# idle step costs ~10 ms, so the majority of the cost is engine-side work with no
# function to blame: transform propagation and RenderingServer pushes triggered
# BY cheap script, once per moved Node3D. A skater carries ~38 mesh nodes, so the
# suspicion is that the count of transform writes dominates, not the arithmetic
# producing them. Nothing in a profiler can confirm that. Turning the writes off
# and reading the frame can.
#
# Each switch suppresses only write-only cosmetic updates — poses nothing else
# reads back. Gameplay is unaffected: it reads the `blade` / Marker3D anchors and
# the physics body, never the cosmetic mesh transforms these produce.
#
# WHAT YOU SEE while frozen is wrong on purpose: rigs hold their last pose, HUD
# rings stop tracking their skater, trails streak. That is the point — the visual
# is the cost being removed. Never read gameplay behaviour or a shipped frame
# rate off a frozen run; the only number it produces is a difference.

enum Mode {
	NONE,
	RIG,   # marker-driven stick + arm mesh rebuild, render rate, ~20 transform writes/skater/frame
	HUD,   # per-skater world HUD (ring, name, chevrons, beacon) — currently PHYSICS rate
	VFX,   # SkaterVFX per-frame emitter bookkeeping
	ALL,
}

# Read directly on hot paths, so they are plain bools rather than a mode compare
# or an accessor call — a static var read is the cheapest form this can take, and
# these are checked once per skater per frame (RIG/VFX) or per tick (HUD).
static var freeze_rig: bool = false
static var freeze_hud: bool = false
static var freeze_vfx: bool = false

# Typed int rather than Mode: cycling assigns an arithmetic result, and casting
# that back to the enum trips Godot's INT_AS_ENUM analyzer warning for no gain.
# Enum members are ints, so `mode == Mode.RIG` still reads the same.
static var mode: int = Mode.NONE

const MODE_NAMES: Array[String] = ["off", "RIG frozen", "HUD frozen", "VFX frozen", "ALL frozen"]


# Advances to the next mode and returns its label for the caller to surface.
static func cycle() -> String:
	mode = (mode + 1) % MODE_NAMES.size()
	freeze_rig = mode == Mode.RIG or mode == Mode.ALL
	freeze_hud = mode == Mode.HUD or mode == Mode.ALL
	freeze_vfx = mode == Mode.VFX or mode == Mode.ALL
	return MODE_NAMES[int(mode)]


static func mode_name() -> String:
	return MODE_NAMES[mode]


# Match teardown must not leave a freeze latched — the switches are static, so
# they outlive the scene that was being measured and would silently corrupt the
# next session's numbers (and its visuals).
static func reset() -> void:
	mode = Mode.NONE
	freeze_rig = false
	freeze_hud = false
	freeze_vfx = false
