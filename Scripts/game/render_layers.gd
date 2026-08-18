class_name RenderLayers

# Render layers, which in this project decide exactly one thing: whether the
# play-following cameras draw a piece of geometry.
#
# A const class rather than a row in Constants.gd (the engine-facing autoload)
# because @tool scripts build their geometry in the editor, where autoloads
# don't exist. Access anywhere as `RenderLayers.OVERHEAD_DRESSING`.

# Layer 2 (bit 1): the arena's overhead set dressing — the centre-hung
# scoreboard, the end-zone netting, the ceiling light fixtures. All of it hangs
# between a top-down camera and the play somewhere in the zoom range: the
# scoreboard and the netting from below, and the light fixtures from above,
# once the zoom climbs past the 22 m rig.
#
# GameCamera and PovCamera clear this bit. Every other camera — lobby backdrop
# orbit, spectator/broadcast, chase, free, goal-replay — keeps Camera3D's
# everything-on default, so the building is whole in every shot meant to show
# it, and nothing needs per-camera wiring. Everything else in the project
# renders on Godot's default layer 1.
const OVERHEAD_DRESSING: int = 1 << 1
