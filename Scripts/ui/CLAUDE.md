# UI conventions

Scope: `Scripts/ui/` — menus, HUD, dialogs, cameras, and the device-aware input
surfaces. Gameplay feel lives in `docs/gameplay-design.md`.

## Localization

Every user-facing string goes through `tr()`. Add a `KEY,en,es` row to
`locale/translations.csv`, then `tr("KEY")` at the **display seam**.

**The domain layer must stay engine-free** — return a key from `domain/` (see
`PingRules.message_key_for`) and `tr()` it in the UI or controller. Never call
`tr()` inside `domain/`.

Adding a language: new column in the CSV plus a `LocaleManager.SUPPORTED` entry
(non-Latin scripts also need a fallback font). Locale is a `PlayerPrefs.locale`
pref applied via `LocaleManager`; the catalogue compiles from the CSV (re-run
`godot --headless --import`) and is registered in
`project.godot → [internationalization]`.

## Popups and modal dialogs

**All popups must be closeable via `ui_cancel` (Escape).** Add the popup to the
existing `_unhandled_input` block in the relevant script — check `popup.visible`,
hide it, and call `get_viewport().set_input_as_handled()`.

## Device awareness

Which device drives is pure last-input-wins, tracked by the `InputDeviceTracker`
autoload. **`InputDeviceTracker.is_gamepad_active()` is the single source of
truth** every device-facing surface reads — there is no opt-in flag and no mode
switch, so a mouse player never sees gamepad UI and a pad player never has to
find a setting.

Three surfaces stay linked because they all key off that one flag:

- **Prompt glyphs** (`ControllerGlyphs.prompt`) rebuild on
  `InputDeviceTracker.device_changed`, so persistent hints flip between keyboard
  labels and pad glyphs live. The tutorial's teaching prose does the same and
  re-emits its current step on `device_changed`.
- **Menu focus rings** come from one shared stylebox
  (`InputDeviceTracker.focus_ring()`, handed out by `MenuStyle.apply_focus_ring` /
  `controller_focus_theme`) — teal while the pad drives, zero-width the instant
  the mouse does. This is what lets controls be focusable unconditionally without
  a mouse click showing a ring.
- **Focus grabbing** is gated by `ControllerNav.active()`, which is just
  `is_gamepad_active()`.

The accessibility OFF switch (Options → Controls, "Keyboard/Mouse Only" →
`PlayerPrefs.disable_gamepad`) pins `is_gamepad_active()` false so an unwanted
controller is ignored entirely. Options apply calls
`InputDeviceTracker.notify_gate_changed()` so the flip reaches device-aware UI
without new input.

Device *arbitration* is purely local and presentation-time — no peer needs to
know which device you used. That does not make the pad path netcode-free: what
the device **commits** (e.g. wrister power) is a replicated input field. Treat
"which device" as local and "what the device committed" as wire.

## Composite controls take focus on the inside

`SwatchDropdown` and `PaletteDropdown` are wrappers: the outer `Control` is
`FOCUS_NONE` and an inner `Button` fills it edge to edge. So the **wrapper's own
`focus_entered` / `mouse_entered` never fire** — the inner button is what the pad
focuses and what the pointer lands on. Connecting to the wrapper compiles, runs,
and silently does nothing.

`SwatchDropdown.focus_target()` returns the control that actually receives both.
Use it wherever a row reacts to being reached (the locker's camera framing).
`PaletteDropdown` has the same shape and no accessor yet — add one the same way
if something needs to watch it.

## The HUD is a coordinator over panels

`hud.gd` builds only the chrome nobody else wants (version tag, bug icon,
spectator banner) and owns the overlays and dialogs. Everything else is a panel
under `Scripts/ui/hud/` that owns its widgets **and** its state — `HudScorebug`,
`HudGoalChyron`, `HudPrompts`, `HudGhostBanner`, plus `HudStatFeed` and
`HudRematchVotes`, which own no widgets at all. `HudChrome` holds the widget
factories, team colors and period/clock text they share.

- **The HUD never writes a panel's field** — it calls a method. Assigning a
  field is deciding *when* it changes, which is the panel's own lifecycle; once
  the coordinator owns that, the panel's updater is dead code waiting to happen.
  Same rule, same evidence as `GoalieCreaseClear` in
  `Scripts/controllers/CLAUDE.md`.
- **Upward flow is a signal.** A panel that needs a toast, an overlay or a
  `GameManager` call emits one (`HudScorebug.warning_toast`,
  `HudGoalChyron.matchup_intro_requested`, `HudRematchVotes.resolved`) and the
  HUD listens. Panels never reach for each other or for the overlays.
- **Build order IS z-order.** `build(scale_root)` adds a panel's widgets to
  `_scale_root` at the moment it is called, so the sequence in `_ready` is the
  layering. That is why the scorebug's clock warning and the chyron's goal wash
  are separate `build_*` calls — they belong at different depths.

A panel is a `Node` when it owns widgets or needs a tween, `RefCounted` when it
owns neither. It takes `scale_root` as a parameter rather than holding it.

Where a panel is the whole handler, the session signal connects straight to its
method (`GameManager.clock_updated.connect(_scorebug.update_clock)`). An arity
that stops matching is a runtime error no headless run would otherwise reach,
so `test_hud_panel_wiring.gd` instantiates the HUD and emits every one of them.

## Menu styling

`MenuStyle` owns the shared look. `apply_primary_cta` is the one loud button per
screen — it uppercases the button's current text, so call it **after** setting
`btn.text`, and any later dynamic text must supply an uppercase string itself
(`Button` has no uppercase property).

## Scene files

`.tscn` files and complex `.tres` resources are authored by the user in the Godot
editor, not by Claude — describe the change instead. Deleting a property line
from a node block is the one exception; the root `CLAUDE.md` has what must be
proven first.

## Cameras run on the render clock

**Every player-perspective camera is driven at render rate and opts OUT of
physics interpolation** — `GameCamera`, `ChaseCamera`, `POVCamera`, `FreeCamera`,
`SpectatorCamera`. Their framing is recomputed from scratch each rendered frame,
so it is already continuous; handing it to the interpolator would only lerp it
toward a tick-old pose and add a frame of lag.

That is sound only because the actors are interpolated up to render time
(`physics/common/physics_interpolation`). A camera sliding between ticks past
tick-rate actors sawtooths their screen position by one tick of travel — the rule
in the root `CLAUDE.md`, "render rate is a clock, and clocks must not be mixed".
The F3 overlay measures the tick/frame pattern that causes it directly
(`NetworkDebugOverlay._render_sim_phase`, "Sim / render phase").

Two consequences that look contradictory and are not:

- The camera's framing **target** is the RAW tick pose
  (`skater.global_position`), because it feeds an exponential smoother that
  attenuates a one-tick oscillation to well under a millimetre.
- Anything drawn ONTO an actor — nameplates, arrows parked on the puck,
  ice-shader uniforms — reads `Skater.render_transform()` instead, and must opt
  out of interpolation itself. See the pair rule in
  `Scripts/networking/CLAUDE.md`. `OffScreenPlayerIndicators` is the worked
  example: the puck-hover arrow reads the interpolated pose; the border-clamped
  player arrows do not need to, because a tick is sub-pixel at the screen edge.

`GameCamera.process_priority = -1` exists for the same clock reason:
`LocalInputGatherer` unprojects the aim cursor through this camera's transform in
its own `_process`, so the camera has to move first or a fast pan drifts the aim
point behind the view.

## Controller focus rings are one shared stylebox

`InputDeviceTracker` (an autoload) owns a single `StyleBoxFlat` handed to every
controller-focusable control via `MenuStyle`, and restyles it **in place** — teal
border while the pad drives, zero border width while the mouse does. So a mouse
player never sees a focus ring even though the controls are focusable, and every
menu's rings flip together with no per-menu wiring. The same `is_gamepad_active()`
flag drives prompts, tutorial copy and gameplay control, which is why rings,
prompts and control never disagree.

A new focusable menu control takes its ring from
`InputDeviceTracker.focus_ring()` through `MenuStyle`. One that builds its own
focus stylebox will be the single control on screen showing a ring to a mouse
player.

## Debug surfaces are exempt from the locale seam

`NetworkDebugOverlay` (F3/F4) and `ShapeDebugOverlay` (F6) deliberately do not
route their strings through `tr()`, and are built in code with no `.tscn`. They
are developer instrumentation, not user-facing UI — do not "fix" them into the
translation catalogue.
