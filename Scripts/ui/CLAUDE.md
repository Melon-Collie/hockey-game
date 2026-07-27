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

## Menu styling

`MenuStyle` owns the shared look. `apply_primary_cta` is the one loud button per
screen — it uppercases the button's current text, so call it **after** setting
`btn.text`, and any later dynamic text must supply an uppercase string itself
(`Button` has no uppercase property).

## Scene files

`.tscn` files and complex `.tres` resources are edited by the user in the Godot
editor, not by Claude. Describe the change instead of authoring it.
