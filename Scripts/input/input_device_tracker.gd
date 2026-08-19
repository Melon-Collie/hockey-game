# Autoload (InputDeviceTracker). Last-input-wins arbiter for which device is
# CURRENTLY driving — mouse+keyboard or gamepad. The gamepad scheme is opinionated
# (the right stick synthesizes a cursor and eases to a rest every frame, even
# centered), so the two can't run at once: exactly one device is "active," and the
# inactive one's behavior is suppressed. Whichever device last produced MEANINGFUL
# input (above a switch threshold) becomes active; idle drift or a resting thumb
# never steals control.
#
# There is NO opt-in flag: the pad works the moment it's used and yields the moment
# the mouse is. `is_gamepad_active()` is the single source of truth every device-
# facing surface reads — gameplay control (the gatherer's cursor synthesis, the
# free cam), the on-screen prompts / tutorial copy, AND the menu focus rings (the
# tracker owns a shared ring stylebox that goes teal while the pad drives and
# invisible the instant the mouse does, so a mouse player never sees a ring even
# though the controls are focusable). Rings, prompts, and control stay linked
# because they all key off this one flag.
#
# This is a purely LOCAL, presentation-time concern — it only decides how the local
# player's InputState gets populated (OS mouse vs. synthesized-from-stick), not
# anything the sim reads differently downstream, so it never touches netcode.
#
# Reads input at _input (before GUI consumption) so a button press on a focused
# menu control still counts as device activity. As an autoload it sits early under
# root, so it updates BEFORE gameplay/menu nodes read is_gamepad_active() this frame.

extends Node

# Emitted when the active device flips (payload = is_gamepad_active()). Listeners
# rebuild device-specific UI (prompts, tutorial copy) or re-seed the pad cursor.
signal device_changed(is_gamepad: bool)

enum Device { NONE, KBM, GAMEPAD }

# Switch thresholds — deliberately ABOVE the gameplay deadzones (aim/move ~0.15) so
# a drifting stick or a resting thumb never hijacks the active device from the mouse.
const _MOUSE_MOVE_PX: float = 4.0          # one motion event's travel to claim KBM
const _STICK_SWITCH_DEADZONE: float = 0.5  # stick/trigger past this claims GAMEPAD

# Focus-ring colors. Teal while the pad drives; fully transparent (and zero border
# width) while the mouse does, so a focused control shows nothing in mouse mode.
const _RING_TEAL: Color = Color(0.15, 0.78, 0.75)

var _active: int = Device.KBM
# The last is_gamepad_active() we broadcast, so device_changed fires once per real
# handoff (and the shared ring restyles in lockstep).
var _emitted_gamepad: bool = false
# ONE shared focus-ring stylebox handed to every controller-focusable control (via
# MenuStyle). Mutating it here restyles them all at once — that's how the rings
# follow the active device without any per-menu wiring. Built in _ready so it
# exists before the first UI is built.
var _focus_ring: StyleBoxFlat = null


func _ready() -> void:
	_focus_ring = StyleBoxFlat.new()
	_focus_ring.bg_color = Color(0, 0, 0, 0)
	_focus_ring.set_corner_radius_all(6)
	_focus_ring.set_expand_margin_all(3)
	_restyle_ring()
	# A pad unplugged while it's driving hands control back to the mouse.
	Input.joy_connection_changed.connect(_on_joy_connection_changed)


# The one question the rest of the game asks: is the gamepad the device driving
# right now? Last-input-wins — a pad works as soon as it's used, and a mouse player
# who never touches a pad is simply always KBM. The sole gate is the accessibility
# "force keyboard-only" pref (off by default), which pins this false so a
# drifting/unwanted controller is ignored entirely.
func is_gamepad_active() -> bool:
	return _active == Device.GAMEPAD and not PlayerPrefs.disable_gamepad


func focus_ring() -> StyleBoxFlat:
	return _focus_ring


func _input(event: InputEvent) -> void:
	var d: int = classify_event(event, _MOUSE_MOVE_PX, _STICK_SWITCH_DEADZONE)
	if d == Device.GAMEPAD:
		_set_active(Device.GAMEPAD)
	elif d == Device.KBM:
		_set_active(Device.KBM)
	# Device.NONE (below threshold / irrelevant event) → no change.


# Which device (if any) this event indicates the player is actively using. Pure +
# static so the threshold behavior is unit-testable without a live device. Returns
# Device.NONE for events below threshold or that don't identify a device.
static func classify_event(event: InputEvent, move_px: float, deadzone: float) -> int:
	if event is InputEventMouseMotion:
		return Device.KBM if (event as InputEventMouseMotion).relative.length() >= move_px else Device.NONE
	if event is InputEventKey and (event as InputEventKey).pressed:
		return Device.KBM
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		return Device.KBM
	if event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		return Device.GAMEPAD
	if event is InputEventJoypadMotion:
		return Device.GAMEPAD if absf((event as InputEventJoypadMotion).axis_value) >= deadzone else Device.NONE
	return Device.NONE


func _set_active(device: int) -> void:
	if _active == device:
		return
	_active = device
	_emit_if_changed()


# Restyle the shared ring + emit device_changed, once per real handoff.
func _emit_if_changed() -> void:
	var now: bool = is_gamepad_active()
	if now != _emitted_gamepad:
		_emitted_gamepad = now
		_restyle_ring()
		if now:
			# Pad just took over — if a menu is open, land focus on its remembered
			# target so the pad can navigate without the menu being reopened.
			ControllerNav.on_gamepad_activated()
		device_changed.emit(now)


# Re-evaluate the gate after the "force keyboard-only" pref flips (Options apply):
# is_gamepad_active() may have changed with no new input, so restyle the ring and
# re-broadcast so device-aware UI follows.
func notify_gate_changed() -> void:
	_emit_if_changed()


# Teal border while the pad drives, zero-width (invisible) while the mouse does.
# Mutating the shared stylebox redraws every focused control using it.
func _restyle_ring() -> void:
	if _focus_ring == null:
		return
	if is_gamepad_active():
		_focus_ring.border_color = _RING_TEAL
		_focus_ring.set_border_width_all(2)
	else:
		_focus_ring.set_border_width_all(0)


func _on_joy_connection_changed(_device: int, connected: bool) -> void:
	if not connected and Input.get_connected_joypads().is_empty() and _active == Device.GAMEPAD:
		_set_active(Device.KBM)
