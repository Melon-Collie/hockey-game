class_name StickStyle
extends RefCounted

# Turns a StickModelRegistry colorway into the stick's surface materials:
# shaft paint + bands + wordmark on the flex shader, blade weave on the
# carbon shader. Every consumer (the skater's stick, the ghost swap, the
# workbench preview) builds through these two factories, so a model pick is
# one index handed in here. Geometry (pattern, tape) stays with its own
# systems; the catalogue itself — which colorways exist — is the registry's.
#
# Shaft: base paint with the MITTS wordmark on both wide faces (mirrored so
# each reads left-to-right), placed in real metres below the butt end so it
# sits under the grip-tape region. Blade: carbon-weave checker
# (blade_carbon.gdshader) — position-keyed, so it survives pattern rebuilds.

const _FLEX_SHADER: Shader = preload("res://Shaders/stick_flex.gdshader")
const _CARBON_SHADER: Shader = preload("res://Shaders/blade_carbon.gdshader")
const _BRAND_TEX: Texture2D = preload("res://Assets/textures/stick_brand_mitts.png")

const SHAFT_ROUGHNESS: float = 0.4

# Wordmark start sits below the deepest grip-tape reach (0.5 m from the butt
# end), and its length preserves the baked texture's aspect over the 0.05 m
# shaft height: 0.05 × (512 / 132) ≈ 0.194.
const _BRAND_FROM_BUTT_M: float = 0.55
const _BRAND_LEN_M: float = 0.194

# Shader parameter names per band slot, index-aligned with the registry's
# bands() array: color, from_m, to_m, anchor.
const _BAND_PARAMS: Array[Array] = [
	[&"band1_color", &"band1_from_m", &"band1_to_m", &"band1_anchor"],
	[&"band2_color", &"band2_from_m", &"band2_to_m", &"band2_anchor"],
]


# The flex-shader shaft material in the model's colorway. Callers layer their
# own runtime uniforms on top (flex_m, shaft_len_m, the grip wrap) — this
# factory owns only the design.
static func make_shaft_material(
		model: int = StickModelRegistry.STICK_CLASSIC) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _FLEX_SHADER
	mat.set_shader_parameter(&"albedo", StickModelRegistry.shaft_color(model))
	mat.set_shader_parameter(&"roughness", SHAFT_ROUGHNESS)
	mat.set_shader_parameter(&"brand_tex", _BRAND_TEX)
	mat.set_shader_parameter(&"brand_color", StickModelRegistry.brand_color(model))
	mat.set_shader_parameter(&"brand_from_butt_m", _BRAND_FROM_BUTT_M)
	mat.set_shader_parameter(&"brand_len_m", _BRAND_LEN_M)
	var bands: Array = StickModelRegistry.bands(model)
	for i: int in mini(bands.size(), _BAND_PARAMS.size()):
		var band: Dictionary = bands[i]
		mat.set_shader_parameter(_BAND_PARAMS[i][0], band["color"])
		mat.set_shader_parameter(_BAND_PARAMS[i][1], band["from_m"])
		mat.set_shader_parameter(_BAND_PARAMS[i][2], band["to_m"])
		mat.set_shader_parameter(_BAND_PARAMS[i][3], band["anchor"])
	return mat


static func make_blade_material(
		model: int = StickModelRegistry.STICK_CLASSIC) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _CARBON_SHADER
	var weave: Array[Color] = StickModelRegistry.blade_weave_colors(model)
	if not weave.is_empty():
		mat.set_shader_parameter(&"albedo_a", weave[0])
		mat.set_shader_parameter(&"albedo_b", weave[1])
	return mat


# Goalie sticks ship white in the real world — shaft, paddle, and blade
# alike — so the goalie colorway of the house design is one white composite
# material for the whole stick, outside the skater catalogue. Plain paint on
# a standard material: the goalie stick is rigid (no flex shader), and its
# ~3 cm shaft renders the wordmark subpixel at the game camera, so no
# branding.
const GOALIE_STICK_COLOR := Color(0.92, 0.92, 0.90)


static func make_goalie_stick_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GOALIE_STICK_COLOR
	mat.roughness = SHAFT_ROUGHNESS
	return mat
