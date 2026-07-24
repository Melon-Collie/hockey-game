# Autoload (InputDeviceTracker). Last-input-wins arbiter for which device is
# CURRENTLY driving — mouse+keyboard or gamepad. The gamepad scheme is opinionated
# (the right stick synthesizes a cursor and eases to a rest every frame, even
# centered), so the two can't run at once: exactly one device is "active," and the
# inactive one's behavior is suppressed. Whichever device last produced MEANINGFUL
# input (above a switch threshold) becomes active; idle drift or a resting thumb
# never steals control.
#
# This is a purely LOCAL, presentation-time concern — it only decides how the local
# player's InputState gets populated (OS mouse vs. synthesized-from-stick), not
# anything the sim reads differently downstream, so it never touches netcode.
#
# Two-tier model:
#   * PlayerPrefs.gamepad_enabled = gamepad ALLOWED (the persistent opt-in; drives
#     build-time UI like menu focus rings and prompt glyphs). Default off.
#   * is_gamepad_active() = gamepad CURRENTLY DRIVING (this tracker; drives the
#     per-frame gameplay reads — the gatherer's cursor synthesis, the free cam).
# So a controller can stay plugged in without stealing the mouse: with gamepad
# allowed, touch the mouse → KBM drives; push the stick → the pad drives.
#
# Reads input at _input (before GUI consumption) so a button press on a focused
# menu control still counts as device activity. As an autoload it sits early under
# root, so it updates BEFORE gameplay/menu nodes read is_gamepad_active() this frame.

extends Node

# Emitted when the active device flips. Payload is is_gamepad_active() (already
# folded through the master gate), so a listener can rebuild device-specific UI or
# re-seed the pad cursor. Best-effort hook for future menu/prompt hot-swap.
signal device_changed(is_gamepad: bool)

enum Device { NONE, KBM, GAMEPAD }

# Switch thresholds — deliberately ABOVE the gameplay deadzones (aim/move ~0.15) so
# a drifting stick or a resting thumb never hijacks the active device from the mouse.
const _MOUSE_MOVE_PX: float = 4.0          # one motion event's travel to claim KBM
const _STICK_SWITCH_DEADZONE: float = 0.5  # stick/trigger past this claims GAMEPAD

var _active: int = Device.KBM


func _ready() -> void:
	# A pad unplugged while it's driving hands control back to the mouse.
	Input.joy_connection_changed.connect(_on_joy_connection_changed)


# The one question the rest of the game asks: is the gamepad the device driving
# right now? False whenever gamepad isn't allowed, so mouse-only players (the
# default) are entirely unaffected — the pad is never even consulted.
func is_gamepad_active() -> bool:
	return PlayerPrefs.gamepad_enabled and _active == Device.GAMEPAD


func active_device() -> int:
	return _active


func _input(event: InputEvent) -> void:
	var d: int = classify_event(event, _MOUSE_MOVE_PX, _STICK_SWITCH_DEADZONE)
	if d == Device.GAMEPAD:
		# Gamepad input only arbitrates when the pad is allowed — otherwise a mouse
		# player with a controller plugged in could have a bumped stick flip _active
		# (harmless while gated, but this keeps _active honestly on KBM for them).
		if PlayerPrefs.gamepad_enabled:
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
	device_changed.emit(is_gamepad_active())


func _on_joy_connection_changed(_device: int, connected: bool) -> void:
	if not connected and Input.get_connected_joypads().is_empty() and _active == Device.GAMEPAD:
		_set_active(Device.KBM)
