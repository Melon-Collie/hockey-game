class_name StickStyle
extends RefCounted

# The house stick design — one MITTS-branded model for everyone, and the seam
# future designs plug into: everything cosmetic about the stick's SURFACES
# (shaft paint + wordmark, blade weave) is built here, so a branding/colorway
# system later just parameterizes these two factories (per-player design id →
# textures/colors) without touching the coordinator, the ghost swap, or the
# workbench preview, which all already build through this class. Geometry
# (pattern, tape) stays with its own systems.
#
# Shaft: near-black composite with the white MITTS wordmark on both wide
# faces (mirrored so each reads left-to-right), placed in real metres below
# the butt end so it sits under the grip-tape region. Blade: carbon-weave
# checker (blade_carbon.gdshader) — position-keyed, so it survives pattern
# rebuilds.

const _FLEX_SHADER: Shader = preload("res://Shaders/stick_flex.gdshader")
const _CARBON_SHADER: Shader = preload("res://Shaders/blade_carbon.gdshader")
const _BRAND_TEX: Texture2D = preload("res://Assets/textures/stick_brand_mitts.png")

# Composite shaft finish (kept off the team palette — modern sticks are
# near-black; the tape job carries the player's color).
const SHAFT_COLOR := Color(0.06, 0.06, 0.07)
const SHAFT_ROUGHNESS: float = 0.4
# Matte black under/around the weave — what a bare (pre-uniform) blade shows.
const BLADE_COLOR := Color(0.05, 0.05, 0.05)

const _BRAND_COLOR := Color(1.0, 1.0, 1.0)
# Wordmark start sits below the deepest grip-tape reach (0.5 m from the butt
# end), and its length preserves the baked texture's aspect over the 0.05 m
# shaft height: 0.05 × (512 / 132) ≈ 0.194.
const _BRAND_FROM_BUTT_M: float = 0.55
const _BRAND_LEN_M: float = 0.194


# The flex-shader shaft material with the house branding applied. Callers
# layer their own runtime uniforms on top (flex_m, shaft_len_m, the grip
# wrap) — this factory owns only the design.
static func make_shaft_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _FLEX_SHADER
	mat.set_shader_parameter(&"albedo", SHAFT_COLOR)
	mat.set_shader_parameter(&"roughness", SHAFT_ROUGHNESS)
	mat.set_shader_parameter(&"brand_tex", _BRAND_TEX)
	mat.set_shader_parameter(&"brand_color", _BRAND_COLOR)
	mat.set_shader_parameter(&"brand_from_butt_m", _BRAND_FROM_BUTT_M)
	mat.set_shader_parameter(&"brand_len_m", _BRAND_LEN_M)
	return mat


static func make_blade_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _CARBON_SHADER
	return mat


# Goalie shafts ship white in the real world — the goalie colorway of the
# house design, and this seam's first second entry. Plain paint on a standard
# material: the goalie stick is rigid (no flex shader), and its ~3 cm shaft
# renders the wordmark subpixel at the game camera, so no branding.
const GOALIE_SHAFT_COLOR := Color(0.92, 0.92, 0.90)


static func make_goalie_shaft_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GOALIE_SHAFT_COLOR
	mat.roughness = SHAFT_ROUGHNESS
	return mat
