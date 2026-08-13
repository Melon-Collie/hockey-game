#include "register_types.h"

#include "native_blade_dangle.h"
#include "native_bottom_hand_ik.h"
#include "native_gif_encoder.h"
#include "native_puck_step.h"
#include "native_skater_gait.h"
#include "native_skater_movement.h"
#include "native_top_hand_ik.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_mitts_native_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<mitts::NativeTopHandIK>();
	ClassDB::register_class<mitts::NativeBottomHandIK>();
	ClassDB::register_class<mitts::NativeSkaterGait>();
	ClassDB::register_class<mitts::NativeSkaterMovement>();
	ClassDB::register_class<mitts::NativePuckStep>();
	ClassDB::register_class<mitts::NativeBladeDangle>();
	ClassDB::register_class<mitts::NativeGifEncoder>();
}

void uninitialize_mitts_native_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT mitts_native_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_mitts_native_module);
	init_obj.register_terminator(uninitialize_mitts_native_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
