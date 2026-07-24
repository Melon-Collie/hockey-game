extends GutTest

# InputDeviceTracker.classify_event — the pure last-input-wins classifier that
# decides which device (if any) an input event indicates. The switch thresholds
# are the crux: they sit ABOVE the gameplay deadzones so idle stick drift / a
# resting mouse never flips the active device. Pure static logic — no live device.

const IDT := preload("res://Scripts/input/input_device_tracker.gd")
const MOVE_PX: float = 4.0
const DEADZONE: float = 0.5

const NONE := IDT.Device.NONE
const KBM := IDT.Device.KBM
const GAMEPAD := IDT.Device.GAMEPAD


func _classify(event: InputEvent) -> int:
	return IDT.classify_event(event, MOVE_PX, DEADZONE)


func test_real_mouse_move_claims_kbm() -> void:
	var e := InputEventMouseMotion.new()
	e.relative = Vector2(10.0, 0.0)
	assert_eq(_classify(e), KBM, "a real mouse move claims KBM")


func test_tiny_mouse_jitter_is_ignored() -> void:
	var e := InputEventMouseMotion.new()
	e.relative = Vector2(1.5, 1.0)  # ~1.8 px, below the 4 px switch bar
	assert_eq(_classify(e), NONE, "sub-threshold mouse jitter doesn't switch device")


func test_key_and_mouse_button_claim_kbm() -> void:
	var key := InputEventKey.new()
	key.pressed = true
	assert_eq(_classify(key), KBM, "a keypress claims KBM")

	var released := InputEventKey.new()
	released.pressed = false
	assert_eq(_classify(released), NONE, "a key RELEASE is not an activation")

	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	assert_eq(_classify(mb), KBM, "a mouse click claims KBM")


func test_pad_button_claims_gamepad() -> void:
	var b := InputEventJoypadButton.new()
	b.button_index = JOY_BUTTON_A
	b.pressed = true
	assert_eq(_classify(b), GAMEPAD, "a pad button press claims GAMEPAD")


func test_stick_past_switch_deadzone_claims_gamepad() -> void:
	var pushed := InputEventJoypadMotion.new()
	pushed.axis = JOY_AXIS_LEFT_X
	pushed.axis_value = 0.7
	assert_eq(_classify(pushed), GAMEPAD, "a stick past the switch deadzone claims GAMEPAD")

	var negative := InputEventJoypadMotion.new()
	negative.axis = JOY_AXIS_LEFT_Y
	negative.axis_value = -0.6
	assert_eq(_classify(negative), GAMEPAD, "a stick pushed the other way also claims GAMEPAD")


func test_resting_stick_drift_is_ignored() -> void:
	# The whole point: a stick hovering below the SWITCH deadzone (even above the
	# smaller gameplay deadzone) must not steal the active device from the mouse.
	var drift := InputEventJoypadMotion.new()
	drift.axis = JOY_AXIS_LEFT_X
	drift.axis_value = 0.3
	assert_eq(_classify(drift), NONE, "a drifting/resting stick doesn't switch device")


func test_switch_deadzone_is_above_the_gameplay_deadzone() -> void:
	# Guards the invariant that makes last-input-wins safe here: the switch bar must
	# be well above the ~0.15 aim/move deadzone.
	assert_gt(IDT._STICK_SWITCH_DEADZONE, 0.15,
			"the device-switch deadzone sits above the gameplay deadzone")
