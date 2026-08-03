class_name NativeKernels

# Visibility seam for the GDExtension hot-path kernels (native/). The wiring
# falls back to GDScript silently when the extension isn't built — right for
# CI and fresh clones, invisible in a playtest. This answers "which path am I
# actually on?": logged once at session start and carried in the debug digest
# (network_debug_overlay), so every pasted capture states its own engine.

const KERNEL_CLASSES: Array[StringName] = [
	&"NativeTopHandIK", &"NativeBottomHandIK", &"NativeSkaterGait",
	&"NativeSkaterMovement", &"NativePuckStep",
]


static func loaded_count() -> int:
	var loaded: int = 0
	for c: StringName in KERNEL_CLASSES:
		if ClassDB.class_exists(c):
			loaded += 1
	return loaded


static func active() -> bool:
	return loaded_count() == KERNEL_CLASSES.size()


static func summary() -> String:
	var loaded: int = loaded_count()
	if loaded == KERNEL_CLASSES.size():
		return "active (%d/%d kernels)" % [loaded, KERNEL_CLASSES.size()]
	if loaded == 0:
		return "absent — GDScript fallback"
	# A partial load means the extension binary predates a kernel — stale
	# build, worth shouting about.
	return "PARTIAL (%d/%d) — rebuild native/ (stale extension binary)" % [
			loaded, KERNEL_CLASSES.size()]
