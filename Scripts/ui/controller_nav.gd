class_name ControllerNav

# Reusable gamepad menu-navigation helpers. Menus wire focus and input through
# these calls instead of hand-rolling each one, so making a new menu
# controller-navigable is a few lines rather than a bespoke pass. Everything here
# is a no-op when the gamepad isn't allowed (PlayerPrefs.gamepad_allowed() — the
# opt-in pref OR the Steam Deck), so mouse play is never affected. Visual styling
# of focus (the teal ring, the toggle
# focus theme) lives in MenuStyle; this class is the input/focus BEHAVIOR.
#
# Three patterns cover every menu:
#   * FOCUS   — grab focus when a panel opens (focus_first / grab_focus), and flip
#               a list of custom rows focusable only in controller mode
#               (set_list_focusable) so a mouse click never lands a focus ring.
#   * ACTIVATE — fire the focused custom Control's handler on A. Joypad button
#               events don't reach a plain Control's gui_input (only real
#               BaseButtons get native ui_accept), so a container routes ui_accept
#               through its own _input via activate_focused().
#   * TABS    — LB / RB cycle a tab bar (bumper_tab_delta), the console convention.

static func active() -> bool:
	return PlayerPrefs.gamepad_allowed()


# --- FOCUS -------------------------------------------------------------------

# Grab focus on `control`, deferred so it runs after layout. No-op for mouse.
static func grab_focus(control: Control) -> void:
	if control != null and active():
		control.grab_focus.call_deferred()


# Focus the first focusable control under `root` (depth-first) — the seam a popup
# calls in its open() to take control off the menu behind it. No-op for mouse.
static func focus_first(root: Node) -> void:
	if active():
		_focus_first_deferred.call_deferred(root)


static func _focus_first_deferred(root: Node) -> void:
	var c: Control = _first_focusable(root)
	if c != null:
		c.grab_focus()


static func _first_focusable(node: Node) -> Control:
	for child: Node in node.get_children():
		if child is Control:
			var ctrl := child as Control
			if ctrl.visible and ctrl.focus_mode == Control.FOCUS_ALL:
				return ctrl
		var found: Control = _first_focusable(child)
		if found != null:
			return found
	return null


# Flip a list of custom Controls focusable (controller) or not (mouse). Call with
# `on = active()` when a menu opens; passing false keeps mouse mode ring-free.
static func set_list_focusable(items: Array, on: bool) -> void:
	for item: Control in items:
		item.focus_mode = Control.FOCUS_ALL if on else Control.FOCUS_NONE


# --- ACTIVATE ----------------------------------------------------------------

# Call from a container's _input(event): if A/ui_accept fires and one of `items`
# has focus, invoke the parallel handler and return true so the caller can consume
# the event. Handled at the _input stage because the GUI focus system eats
# ui_accept for a focused control before _unhandled_input, and joypad buttons
# never reach a plain Control's gui_input at all.
static func activate_focused(event: InputEvent, items: Array, handlers: Array) -> bool:
	if not event.is_action_pressed(&"ui_accept"):
		return false
	for i: int in items.size():
		if (items[i] as Control).has_focus():
			(handlers[i] as Callable).call()
			return true
	return false


# --- TABS --------------------------------------------------------------------

# Call from a container's _input(event): returns -1 for LB, +1 for RB, 0 otherwise
# (and 0 for mouse). Caller adds it to its tab index (wrapping) and refocuses.
static func bumper_tab_delta(event: InputEvent) -> int:
	if not active() or not (event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed):
		return 0
	match (event as InputEventJoypadButton).button_index:
		JOY_BUTTON_LEFT_SHOULDER:
			return -1
		JOY_BUTTON_RIGHT_SHOULDER:
			return 1
	return 0
