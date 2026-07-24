class_name ControllerNav

# Reusable gamepad menu-navigation helpers. Menus wire focus and input through
# these calls instead of hand-rolling each one, so making a new menu
# controller-navigable is a few lines rather than a bespoke pass. active() tracks
# the CURRENTLY-driving device (InputDeviceTracker, last-input-wins), so focus is
# grabbed only while the pad drives; the focus RING itself is device-aware, so a
# mouse player never sees one even on a focusable control. Visual styling
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
	return InputDeviceTracker.is_gamepad_active()


# --- FOCUS -------------------------------------------------------------------

# The last focus target a menu requested (weakref so a freed control doesn't
# resurrect). Grabbed immediately while the pad drives; otherwise remembered so
# that if the player SWITCHES to the pad with the menu still open, the pad lands
# on the right control (see on_gamepad_activated). One shared slot — it tracks the
# most recent focus intent, which is the currently-relevant menu's target.
static var _pending_focus: WeakRef = null


# Grab focus on `control`, deferred so it runs after layout. Remembered even in
# mouse mode so a later mouse→pad switch can grab it; only actually grabs now while
# the pad drives (so a mouse click never yanks focus).
static func grab_focus(control: Control) -> void:
	if control == null:
		return
	_pending_focus = weakref(control)
	if active():
		control.grab_focus.call_deferred()


# Focus the first focusable control under `root` (depth-first) — the seam a popup
# calls in its open() to take control off the menu behind it. Remembered for a
# later device switch; only grabs now while the pad drives.
static func focus_first(root: Node) -> void:
	_focus_first_deferred.call_deferred(root)


static func _focus_first_deferred(root: Node) -> void:
	var c: Control = _first_focusable(root)
	if c != null:
		_pending_focus = weakref(c)
		if active():
			c.grab_focus()


# Called by InputDeviceTracker when the pad becomes the active device: grab the
# remembered target so a mouse→pad switch with a menu already open lands the pad on
# it. Guarded on the control still being live + on-screen (a stale/closed menu's
# target is skipped, so switching to the pad in gameplay grabs nothing).
static func on_gamepad_activated() -> void:
	if _pending_focus == null:
		return
	var c: Control = _pending_focus.get_ref() as Control
	if c != null and c.is_inside_tree() and c.is_visible_in_tree():
		c.grab_focus.call_deferred()


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


# Make a list of custom Controls focusable. With the device-aware focus ring, this
# is unconditional: a mouse click on a focusable row shows no ring (the ring is
# invisible in mouse mode), and keeping them focusable is what lets a mouse→pad
# switch land the pad on a row without rebuilding the menu. `on = false` opts back
# out (kept for symmetry / teardown).
static func set_list_focusable(items: Array, on: bool = true) -> void:
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
