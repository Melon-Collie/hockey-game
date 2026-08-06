extends GutTest

# ControllerNav's modal focus scope — the part that is pure engine behavior and
# device-independent (the grab_focus half is gated on the pad being the active
# device, which needs live input, so it's exercised in-game rather than here).
#
# What's pinned: opening a modal walls focus off from the menu behind it, so the
# D-pad can't step out of a popup and back onto the control that opened it, and
# closing lifts the wall again.

var _bg: Control = null
var _bg_btn: Button = null
var _modal: Control = null
var _modal_btn: Button = null


func before_each() -> void:
	var root := Control.new()
	add_child_autofree(root)

	_bg = Control.new()
	_bg_btn = Button.new()
	_bg.add_child(_bg_btn)
	root.add_child(_bg)

	_modal = Control.new()
	_modal_btn = Button.new()
	_modal.add_child(_modal_btn)
	root.add_child(_modal)


func test_walling_off_a_subtree_releases_its_focus() -> void:
	_bg_btn.grab_focus()
	assert_true(_bg_btn.has_focus(), "background button starts focused")
	ControllerNav.set_subtree_focusable(_bg, false)
	assert_false(_bg_btn.has_focus(), "focus is released when the subtree is walled off")


func test_walled_subtree_is_skipped_by_focus_navigation() -> void:
	ControllerNav.set_subtree_focusable(_bg, false)
	_modal_btn.grab_focus()
	# Only the modal button remains focusable, so the search wraps back to it
	# instead of stepping onto the button behind the scrim.
	assert_eq(_modal_btn.find_next_valid_focus(), _modal_btn,
			"navigation stays inside the modal")


func test_lifting_the_wall_restores_focusability() -> void:
	ControllerNav.set_subtree_focusable(_bg, false)
	ControllerNav.set_subtree_focusable(_bg, true)
	_bg_btn.grab_focus()
	assert_true(_bg_btn.has_focus(), "background is focusable again")


func test_open_and_close_modal_toggle_the_wall() -> void:
	_bg_btn.grab_focus()
	ControllerNav.open_modal(_bg, _modal, _modal_btn)
	assert_false(_bg_btn.has_focus(), "opening a modal drops the opener's focus ring")
	ControllerNav.close_modal(_bg, _bg_btn)
	_bg_btn.grab_focus()
	assert_true(_bg_btn.has_focus(), "closing a modal makes the menu reachable again")


# A modal can live INSIDE the subtree it walls off (the locker is a Control
# child of the player screen it covers). The wall must not take the modal down
# with it — that leaves the popup with nothing the pad can focus — and the
# carve-out must not leak focusability to the rest of the background.
func test_a_modal_inside_the_background_stays_focusable() -> void:
	var inner_modal := Control.new()
	var inner_btn := Button.new()
	inner_modal.add_child(inner_btn)
	_bg.add_child(inner_modal)
	ControllerNav.open_modal(_bg, inner_modal, inner_btn)
	assert_eq(inner_btn.get_focus_mode_with_override(), Control.FOCUS_ALL,
			"the modal's own controls stay focusable under the wall")
	assert_eq(_bg_btn.get_focus_mode_with_override(), Control.FOCUS_NONE,
			"the rest of the background is still walled off")
	ControllerNav.close_modal(_bg, _bg_btn)
	assert_eq(_bg_btn.get_focus_mode_with_override(), Control.FOCUS_ALL,
			"closing lifts the wall")


func test_modal_helpers_are_null_safe() -> void:
	# Callers pass a null background when they have no single subtree to wall off.
	ControllerNav.set_subtree_focusable(null, false)
	ControllerNav.open_modal(null, null, null)
	ControllerNav.close_modal(null, null)
	pass_test("null arguments are tolerated")


func test_focus_owner_reads_the_focused_control() -> void:
	_bg_btn.grab_focus()
	assert_eq(ControllerNav.focus_owner(_bg), _bg_btn, "reports the focused control")
	_bg_btn.release_focus()
	assert_null(ControllerNav.focus_owner(_bg), "null when nothing is focused")


func test_focus_owner_null_for_detached_node() -> void:
	var orphan := Control.new()
	assert_null(ControllerNav.focus_owner(orphan), "a node outside the tree has no viewport")
	assert_null(ControllerNav.focus_owner(null), "null node is tolerated")
	orphan.free()
