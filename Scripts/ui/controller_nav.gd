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
# Four patterns cover every menu:
#   * FOCUS   — grab focus when a panel opens (focus_first / grab_focus), and flip
#               a list of custom rows focusable only in controller mode
#               (set_list_focusable) so a mouse click never lands a focus ring.
#   * MODAL   — open_modal / close_modal contain focus inside a popup so the D-pad
#               can't wander back onto the menu behind it, and hand focus back to
#               whatever opened the popup when it closes.
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
		_grab_deferred.call_deferred(control)


# The actual grab, one frame later. Re-checked against the live focus state
# because the world can change in between: a modal opening walls the target's
# subtree off (see open_modal), and grab_focus on a walled control is a no-op the
# engine warns about. Remembering it in _pending_focus is still right — the wall
# lifts when the modal closes.
static func _grab_deferred(control: Control) -> void:
	if control == null or not is_instance_valid(control) or not control.is_inside_tree():
		return
	if control.get_focus_mode_with_override() == Control.FOCUS_NONE:
		return
	control.grab_focus()


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
		_grab_deferred.call_deferred(c)


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


# --- MODAL -------------------------------------------------------------------

# Focus containment for a popup opened over a menu. Godot's directional focus
# search walks the WHOLE tree, so without this the D-pad wanders straight out of
# a popup and onto the buttons of the menu behind the scrim — the ring visibly
# ping-pongs between the two, and the control that opened the popup keeps its
# ring while the popup has one of its own.
#
# `focus_behavior_recursive = DISABLED` is the engine primitive (Godot 4.5+): it
# makes an entire subtree unfocusable AND releases focus if the subtree currently
# holds it, so one call both clears the stale ring and walls off navigation.
# The scrim already blocks the mouse, so nothing behind loses clickability.
#
# A modal that lives INSIDE the background subtree (the locker is a Control
# child of the player screen it covers, unlike the CanvasLayer dialogs, which
# sit outside the Control focus chain) would be walled off with it — the grab
# below then hits the FOCUS_NONE override and the popup opens dead to the pad.
# An explicit ENABLED on the modal's root out-ranks the ancestor's DISABLED, so
# the popup's own controls are carved back out of the wall.
#
# Always pair with close_modal (background restored, focus handed back to
# `restore` — usually the control that opened the popup, so the pad resumes where
# it left off). Both are safe with null arguments.
static func open_modal(background: Control, modal: Node, first: Control = null) -> void:
	set_subtree_focusable(background, false)
	if modal is Control and background != null and background.is_ancestor_of(modal):
		(modal as Control).focus_behavior_recursive = Control.FOCUS_BEHAVIOR_ENABLED
	if first != null:
		grab_focus(first)
	elif modal != null:
		focus_first(modal)


static func close_modal(background: Control, restore: Control = null) -> void:
	set_subtree_focusable(background, true)
	if restore != null and is_instance_valid(restore):
		grab_focus(restore)


# Enable/disable focus for a whole subtree. Turning it off also releases focus if
# the subtree currently holds it, so the ring never lingers on a control the
# player can no longer reach. Null-safe; restores to INHERITED (the default), so
# nothing a control set for itself is lost.
static func set_subtree_focusable(root: Control, on: bool) -> void:
	if root == null:
		return
	root.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED if on \
			else Control.FOCUS_BEHAVIOR_DISABLED


# The control that currently owns focus, or null. Modals capture this as they open
# so close_modal can hand focus back without the opener having to plumb a
# reference through (a ConfirmDialog is opened from a dozen call sites).
static func focus_owner(node: Node) -> Control:
	if node == null or not node.is_inside_tree():
		return null
	return node.get_viewport().gui_get_focus_owner()


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
