class_name CosmeticFreeze
extends Object

# Two switches that suppress non-rig cosmetic work, for the pose-capture tool
# (tools/pose_capture.gd) alone.
#
# The capture diffs rendered skater poses pixel-for-pixel against a recorded
# baseline, so anything that animates independently of the pose is noise that
# fails the comparison for the wrong reason: VFX emitters spawn particles on
# their own clock, and the world HUD's ring and name plate move with the camera.
# Freezing both makes a capture reproducible.
#
# Scope is exactly what the capture tool needs — do not grow this into a
# measurement harness.
#
# Read directly on hot paths, so they are plain static bools rather than an
# accessor call.
static var vfx: bool = false
static var hud: bool = false
