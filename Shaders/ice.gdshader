// Ice surface — sub-surface line tint + Fresnel-driven reflectivity.
//
// The albedo texture has the rink lines painted into it. Real ice paints lines
// onto the concrete BELOW the ice sheet, so the lines should:
//   1. Appear slightly displaced when viewed at angle (parallax through depth).
//   2. Fade toward the ice color at grazing angles (more ice between viewer
//      and line), letting reflections take over.
//
// Reflectivity is left to the engine's Schlick/GGX path: we just hand it a
// reasonable F0 (SPECULAR) and an angle-varying ROUGHNESS so the surface goes
// from slightly diffuse head-on to mirror-sharp at grazing.

shader_type spatial;
render_mode cull_back, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
// Persistent skate scratches painted into a SubViewport (IceScratchMap).
// White = scratched, black = clean. hint_default_black keeps the editor
// preview clean when nothing is bound.
uniform sampler2D scratch_tex : hint_default_black, filter_linear;
// Center-ice decals (logo + curved arena text). The viewport covers a small
// area at center ice — `decal_uv_min` / `decal_uv_max` map the rink UV into
// this smaller texture, and `repeat_disable` makes samples outside the area
// clamp to the transparent border padding instead of repeating.
uniform sampler2D decal_tex : source_color, hint_default_black, filter_linear_mipmap, repeat_disable;
uniform vec2 decal_uv_min = vec2(0.0, 0.0);
uniform vec2 decal_uv_max = vec2(1.0, 1.0);
// Plane size in world meters — used to convert parallax offset to UV.
uniform vec2 rink_size = vec2(26.0, 60.0);
// Color the lines fade toward at grazing. Default to the ice color itself so
// lines blend into the surrounding ice; nudge cooler/lighter for more drama.
uniform vec3 ice_fog_color : source_color = vec3(0.9, 0.95, 1.0);
// How strongly the lines fade through the ice. Models Beer-Lambert
// absorption: fade = 1 - exp(-extinction / cos(view_angle)). At the same
// extinction value the fade strengthens exponentially as the view goes
// grazing, since the ray traverses more ice. Default 0.2 gives ~18% fade
// head-on, ~33% at 45°, ~55% near grazing.
uniform float subsurface_fade : hint_range(0.0, 3.0) = 0.2;
// Apparent depth of the lines below the ice surface, in meters.
uniform float subsurface_depth : hint_range(0.0, 0.05) = 0.012;
// F0 reflectance multiplier (0.5 = water-baseline F0 of 0.04).
uniform float specular_strength : hint_range(0.0, 1.0) = 0.6;
uniform float roughness_head_on : hint_range(0.0, 1.0) = 0.20;
uniform float roughness_grazing : hint_range(0.0, 1.0) = 0.04;
// Scratch overlay: skate cuts catch light differently than smooth ice —
// brighter (broken surface scatters more) and rougher (no mirror reflection).
uniform vec3 scratch_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float scratch_strength : hint_range(0.0, 1.0) = 0.35;
uniform float scratch_roughness : hint_range(0.0, 1.0) = 0.55;

void fragment() {
	float NdotV = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float grazing = 1.0 - NdotV;

	// Parallax: trace the view ray from the surface point down through the ice
	// to depth `subsurface_depth`, sample the albedo at that XZ.
	vec3 to_cam_world = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	vec3 view_world = -to_cam_world;                  // camera -> fragment
	float vy = min(view_world.y, -0.001);             // guard near-horizontal
	vec2 xz_offset = (-subsurface_depth / vy) * view_world.xz;
	vec2 uv = UV + xz_offset / rink_size;

	vec3 base = texture(albedo_tex, uv).rgb;
	// Composite decals BEFORE the Beer-Lambert fade so they get the same
	// under-ice depth treatment as the lines baked into albedo_tex.
	// Remap the parallax UV into the small decal texture's local space.
	// Samples outside [0,1] clamp to the transparent border thanks to
	// repeat_disable, so no explicit bounds check is needed.
	vec2 decal_uv = (uv - decal_uv_min) / (decal_uv_max - decal_uv_min);
	vec4 decal = texture(decal_tex, decal_uv);
	base = mix(base, decal.rgb, decal.a);

	// Beer-Lambert fade: light traversing the ice depth loses energy
	// proportional to path length, which is depth / cos(view_angle).
	float path_factor = 1.0 / max(NdotV, 0.05);
	float fade = 1.0 - exp(-subsurface_fade * path_factor);
	vec3 albedo = mix(base, ice_fog_color, fade);

	float base_rough = mix(roughness_head_on, roughness_grazing, grazing * grazing);

	// Sample scratches at the surface UV (no parallax — the cuts are on
	// the ice, not below it). Tint albedo and lift roughness in proportion.
	float scratch = texture(scratch_tex, UV).r * scratch_strength;
	albedo = mix(albedo, scratch_color, scratch);
	float rough = mix(base_rough, scratch_roughness, scratch);

	ALBEDO = albedo;
	METALLIC = 0.0;
	SPECULAR = specular_strength;
	ROUGHNESS = rough;
}
