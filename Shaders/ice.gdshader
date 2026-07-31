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
// ── On-ice player rings ──────────────────────────────────────────────────────
// Filled each frame by IceRingField. The array is fixed-size (shader arrays must
// be, and it is sized for the largest roster); ring_count says how much of it is
// live, so a 3v3 pays for three rings and an empty rink pays for none.
//   ring_pos: xy = world (x, z) centre, z = OUTER radius, w = INNER radius
//   ring_col: LINEAR rgb, alpha is the ring's opacity over the ice
//
// Colours arrive already converted to linear. `source_color` would normally do
// that, but the hint's conversion is not applied elementwise to a packed array,
// so the caller (IceRingField) linearises instead — see the note there. Getting
// this wrong is not subtle: the self ring's sRGB (0.20, 0.95, 0.40) read as
// linear is (0.20, 0.95, 0.40) instead of (0.03, 0.89, 0.13), a washed-out
// mint where a saturated green belongs.
uniform vec4 ring_pos[12];
uniform vec4 ring_col[12];
uniform int ring_count = 0;
// Elevation chevrons — the stacked "^" marks beside a skater. Same deal as the
// rings: xy = world (x, z) of the FIRST apex, z = how many are stacked (1-3).
// They share one colour (the neutral HUD stroke) rather than carrying their own.
uniform vec4 chevron_pos[12];
uniform int chevron_count = 0;
// Linear, like ring_col. IceRingField writes MenuStyle.HUD_ICE here once at
// setup; the default is only what the editor preview shows before that runs, so
// do not treat it as the source of truth for the HUD stroke colour.
uniform vec4 chevron_col = vec4(0.04, 0.07, 0.15, 0.85);
// Screen-down in world XZ. The chevrons point screen-UP and stack screen-up from
// each other, so their whole orientation comes from this one vector — which is
// why they can be uniforms at all instead of nodes carrying a camera-derived
// rotation each.
uniform vec2 hud_screen_down = vec2(0.0, 1.0);
uniform float chevron_leg_len = 0.098;
uniform float chevron_half_thickness = 0.015;
uniform float chevron_stack_gap = 0.11;


// Distance from p to the segment a->b. The chevron is two of these.
float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.000001), 0.0, 1.0);
	return length(pa - ba * h);
}
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

	// Player rings, drawn ON the ice rather than as geometry above it (fed by
	// IceRingField). Each used to be a 48-segment alpha-blended mesh with its own
	// node and its own per-frame transform; here they are a distance test, so ten
	// skaters cost ten uniforms instead of ten nodes and ten transparent draws.
	// Composited after the scratches so a ring reads over a scuffed patch.
	// Sampled in WORLD space rather than UV: it needs no assumption about the ice
	// plane's UV convention, and a ring is defined in metres.
	//
	// The HUD accumulates into its OWN layer instead of writing `albedo`, because
	// the meshes it replaced were SHADING_MODE_UNSHADED: their colour was the
	// literal pixel, not a reflectance the rink's eight spotlights then modulated.
	// Folded into ALBEDO the marks pick up the lighting AND the Beer-Lambert fade,
	// so they read darker and shift hue depending on which light you stand under.
	// The layer is resolved at the bottom of fragment() — see the ALBEDO write.
	vec3 hud_rgb = vec3(0.0);
	float hud_cover = 0.0;
	vec2 ice_xz = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz;
	for (int i = 0; i < ring_count; i++) {
		float d = distance(ice_xz, ring_pos[i].xy);
		// Screen-space derivative of the distance field: one pixel of feather at
		// any camera height or zoom. This is what a fixed polygon count cannot
		// do — the old 48-segment ring faceted visibly up close and shimmered
		// far away.
		float aa = max(fwidth(d), 0.0001);
		float band = smoothstep(ring_pos[i].w - aa, ring_pos[i].w + aa, d)
				* (1.0 - smoothstep(ring_pos[i].z - aa, ring_pos[i].z + aa, d));
		float a = band * ring_col[i].a;
		hud_rgb = hud_rgb * (1.0 - a) + ring_col[i].rgb * a;
		hud_cover = hud_cover * (1.0 - a) + a;
	}

	// Elevation chevrons. Legs run 45 degrees either side of screen-down from a
	// shared apex, so the mark reads as "^" pointing screen-up; each extra one
	// stacks screen-up from the last.
	vec2 sd = normalize(hud_screen_down);
	vec2 sd_right = vec2(sd.y, -sd.x);
	vec2 leg_a = normalize(sd + sd_right) * chevron_leg_len;
	vec2 leg_b = normalize(sd - sd_right) * chevron_leg_len;
	for (int i = 0; i < chevron_count; i++) {
		int stack = int(chevron_pos[i].z);
		for (int k = 0; k < stack; k++) {
			vec2 apex = chevron_pos[i].xy - sd * (chevron_stack_gap * float(k));
			float d = min(seg_dist(ice_xz, apex, apex + leg_a),
					seg_dist(ice_xz, apex, apex + leg_b));
			float aa = max(fwidth(d), 0.0001);
			float mark = 1.0 - smoothstep(chevron_half_thickness - aa,
					chevron_half_thickness + aa, d);
			float a = mark * chevron_col.a;
			hud_rgb = hud_rgb * (1.0 - a) + chevron_col.rgb * a;
			hud_cover = hud_cover * (1.0 - a) + a;
		}
	}

	// Resolve the unshaded HUD layer over the lit ice. The engine computes
	// ALBEDO * lighting + EMISSION, so scaling the ice's contribution by
	// (1 - cover) and putting the flat HUD colour in EMISSION reproduces exactly
	// what the unshaded meshes blended: hud * a + lit_ice * (1 - a). SPECULAR
	// scales the same way — the highlight was part of what the mesh covered.
	ALBEDO = albedo * (1.0 - hud_cover);
	EMISSION = hud_rgb;
	METALLIC = 0.0;
	SPECULAR = specular_strength * (1.0 - hud_cover);
	ROUGHNESS = rough;
}
