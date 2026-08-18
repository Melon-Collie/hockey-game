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
// In-ice sponsor wordmarks (IceAdPainter). Unlike the center-ice patch above,
// these are scattered over the sheet — but they cover only ~6% of it, so the
// painter packs one cell per slot into an atlas instead of handing over a
// rink-sized image that would be almost entirely blank. The price of that is
// paid here: the fragment has to find which slot it is in, and where in that
// slot's cell it lands.
//   ads_world: xy = world (x, z) centre, zw = half extents, both in metres
//   ads_atlas: xy = the cell's atlas UV origin, zw = its UV size
// Fixed-size like the ring arrays below (IceAdPainter.MAX_SLOTS); ads_count says
// how much of it is live, and `ads_enabled` skips the whole search when the rink
// carries no ads at all.
uniform sampler2D ads_tex : source_color, hint_default_transparent, filter_linear_mipmap, repeat_disable;
uniform vec4 ads_world[8];
uniform vec4 ads_atlas[8];
uniform int ads_count = 0;
uniform bool ads_enabled = false;
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
// They share hud_stroke_col rather than carrying their own.
uniform vec4 chevron_pos[12];
uniform int chevron_count = 0;
// The neutral HUD stroke (MenuStyle.HUD_ICE), shared by the chevrons and the
// slapper indicator. Linear, like ring_col — IceRingField writes it once at
// setup, so the default here is only what the editor preview shows before that
// runs; do not treat it as the source of truth.
uniform vec4 hud_stroke_col = vec4(0.04, 0.07, 0.15, 0.85);
// ── Slapper one-timer indicator ──────────────────────────────────────────────
// SELF-ONLY, so unlike the rings there is exactly one of these and it needs no
// array. It used to be five nodes on EVERY skater — a reticle, an arrow root, an
// arrow and a gapped ring, all flat on the ice — so that at most one skater
// could show them. Same trade as the rings: five nodes x roster becomes a
// handful of uniforms, and the strokes get analytic antialiasing for free.
//
// slapper_zone: xy = world (x, z) centre, z = zone radius in metres, w = the
// convergence ring's scale within it (0 = ring hidden).
// slapper_dir: world XZ unit vector the arrow points along. It orients the whole
// indicator, not just the arrow — the ring's gap sits on the shaft's tail — so
// it is live whenever any of it draws.
// slapper_active gates the reticle + convergence ring; slapper_arrow gates the
// aim arrow. INDEPENDENT gates: a carried slapshot charge is arrow-only, a
// puckless one-timer wind-up shows both.
uniform vec4 slapper_zone = vec4(0.0);
uniform vec2 slapper_dir = vec2(0.0, 1.0);
uniform bool slapper_active = false;
uniform bool slapper_arrow = false;
// ── Stamina gauge ────────────────────────────────────────────────────────────
// Self-only too, so scalars again. The fill sweeps from 12 o'clock, which is
// camera screen-UP rather than any body direction — stamina_up carries it, the
// same way the node rig re-aligned the ring's yaw to the camera every frame.
// stamina_zone: xy = world (x, z) centre, z = fill fraction 0..1.
// The two colours arrive with HUD_OPACITY already folded into alpha, because
// the track is deliberately fainter than the fill (0.55 vs 1.0) and a single
// opacity uniform would flatten that.
uniform vec4 stamina_zone = vec4(0.0);
uniform vec2 stamina_up = vec2(0.0, -1.0);
uniform vec4 stamina_fill_col = vec4(0.0);
uniform vec4 stamina_track_col = vec4(0.0);
uniform float stamina_inner_r = 0.31;
uniform float stamina_outer_r = 0.37;
uniform bool stamina_active = false;
// Stroke width and reticle arm length in world metres — MenuStyle.HUD_LINE_THIN
// and SkaterHUDCoordinator's reticle half-length, mirrored here because the ice
// shader has no way to read a GDScript constant. Keep them in sync.
uniform float hud_line_thin = 0.03;
uniform float reticle_half_len = 0.06;
// Arrow proportions, in multiples of the zone radius (the unit space the node
// rig authored them in).
const float TAU_C = 6.28318530718;
const float ARROW_SHAFT_HALF_W = 0.06;
const float ARROW_TIP_DISTANCE = 1.8;
const float ARROW_HEAD_LEN = 0.30;
const float ARROW_HEAD_HALF_W = 0.20;
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
	// Sponsor wordmarks go down first, so the center-ice art below wins wherever
	// the two ever meet. Placed in WORLD metres rather than rink UV: a slot is
	// defined in metres in AdBrands, and the atlas has no rink-wide frame to
	// index. `xz_offset` is the parallax the albedo above was already read with,
	// so an ad sits at the same apparent depth as the paint around it.
	if (ads_enabled) {
		vec2 ads_xz = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz + xz_offset;
		for (int i = 0; i < ads_count; i++) {
			vec2 d = (ads_xz - ads_world[i].xy) / ads_world[i].zw;
			if (abs(d.x) < 1.0 && abs(d.y) < 1.0) {
				// The painter lays a cell out in the plane's own handedness —
				// +u with world +X, +v with world +Z — so this is a straight
				// remap of the slot's [-1, 1] local coords onto its cell.
				vec2 cell_uv = ads_atlas[i].xy + (d * 0.5 + 0.5) * ads_atlas[i].zw;
				// The painter's viewport renders onto transparent black, so its
				// texture is premultiplied: composite it as such. Straight-alpha
				// mixing would pull every antialiased glyph edge toward black,
				// which with no panel field behind the lettering shows up as a
				// dark halo.
				vec4 ads = texture(ads_tex, cell_uv);
				base = base * (1.0 - ads.a) + ads.rgb;
				break;
			}
		}
	}
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
			float a = mark * hud_stroke_col.a;
			hud_rgb = hud_rgb * (1.0 - a) + hud_stroke_col.rgb * a;
			hud_cover = hud_cover * (1.0 - a) + a;
		}
	}

	// Slapper one-timer indicator: reticle, convergence ring and aim arrow, all
	// in WORLD metres in the arrow's own frame. The node rig built this in unit
	// space and carried the zone radius as parent scale, which is why it had to
	// counter-scale the reticle and the stroke widths to keep them at fixed world
	// size; working directly in metres here means those counter-scales simply do
	// not exist. Geometry constants are the unit-space ones multiplied by the
	// zone radius, so the shape is the one SkaterHUDCoordinator authored.
	if (slapper_active || slapper_arrow) {
		vec2 rel = ice_xz - slapper_zone.xy;
		float zone_r = max(slapper_zone.z, 0.0001);
		float half_t = hud_line_thin * 0.5;
		float mark = 0.0;
		if (slapper_active) {
			// Centre crosshair: two bars, fixed world size regardless of the zone.
			float cross = min(
					max(abs(rel.x) - reticle_half_len, abs(rel.y) - half_t),
					max(abs(rel.x) - half_t, abs(rel.y) - reticle_half_len));
			float aa_c = max(fwidth(cross), 0.0001);
			mark = 1.0 - smoothstep(-aa_c, aa_c, cross);
		}

		// Indicator frame: +Y of this basis is the aim direction (the node rig's
		// local +Z), +X its right. The node rig parented the ring UNDER the arrow
		// root, so both share this frame — which is what puts the ring's gap on
		// the shaft's tail.
		vec2 fwd = normalize(slapper_dir);
		vec2 right = vec2(fwd.y, -fwd.x);
		vec2 q = vec2(dot(rel, right), dot(rel, fwd));
		float w = ARROW_SHAFT_HALF_W * zone_r;
		float ring_r = slapper_zone.w * zone_r;

		if (slapper_arrow) {
			float tip_y = ARROW_TIP_DISTANCE * zone_r;
			float shoulder_y = tip_y - ARROW_HEAD_LEN * zone_r;
			float head_w = ARROW_HEAD_HALF_W * zone_r;
			// The shaft starts where it clears the convergence ring, so the two
			// never overlap — the same sqrt the node rig used. Arrow-only (no
			// reticle/ring drawn): run from the centre; ring_r is stale then.
			float base_y = (slapper_active && ring_r > w) ? sqrt(ring_r * ring_r - w * w) : 0.0;
			float d = 1e9;
			if (base_y < shoulder_y) {
				d = min(d, seg_dist(q, vec2(-w, base_y), vec2(-w, shoulder_y)));
				d = min(d, seg_dist(q, vec2(w, base_y), vec2(w, shoulder_y)));
			}
			vec2 tip = vec2(0.0, tip_y);
			d = min(d, seg_dist(q, vec2(-w, shoulder_y), vec2(-head_w, shoulder_y)));
			d = min(d, seg_dist(q, vec2(w, shoulder_y), vec2(head_w, shoulder_y)));
			d = min(d, seg_dist(q, vec2(-head_w, shoulder_y), tip));
			d = min(d, seg_dist(q, vec2(head_w, shoulder_y), tip));
			float aa_a = max(fwidth(d), 0.0001);
			mark = max(mark, 1.0 - smoothstep(half_t - aa_a, half_t + aa_a, d));
		}

		// Convergence ring: an annulus with a gap where the arrow shaft leaves
		// it, so the tail reads as continuous with the stroke.
		if (slapper_active && ring_r > w + hud_line_thin) {
			float gap_half = asin(clamp(w / ring_r, -1.0, 1.0));
			// Angle measured from the shaft (+Y) so the gap sits on the tail.
			float ang = abs(atan(q.x, q.y));
			float band = abs(length(q) - (ring_r - half_t)) - half_t;
			float aa_r = max(fwidth(band), 0.0001);
			float ring = 1.0 - smoothstep(-aa_r, aa_r, band);
			ring *= smoothstep(gap_half - 0.02, gap_half + 0.02, ang);
			mark = max(mark, ring);
		}
		float a = mark * hud_stroke_col.a;
		hud_rgb = hud_rgb * (1.0 - a) + hud_stroke_col.rgb * a;
		hud_cover = hud_cover * (1.0 - a) + a;
	}

	// Stamina gauge: an annulus split by an angular mask into a bright fill and a
	// faint remaining track. It was a 64-segment MeshInstance3D whose UV.x baked
	// the clockwise-from-12 parameter; here that parameter is the angle itself,
	// which also means the arc's ends are analytically antialiased rather than
	// landing on a segment boundary.
	if (stamina_active) {
		vec2 rel = ice_xz - stamina_zone.xy;
		float rad = length(rel);
		// Band edges feathered like every other HUD mark.
		float band = max(stamina_inner_r - rad, rad - stamina_outer_r);
		float aa_b = max(fwidth(band), 0.0001);
		float in_band = 1.0 - smoothstep(-aa_b, aa_b, band);
		if (in_band > 0.0) {
			// t runs 0..1 the way the mesh's UV.x did: 0 at screen-up, advancing
			// toward `left`. Reproducing that convention is what keeps the gauge
			// draining in the direction players already read.
			vec2 up = normalize(stamina_up);
			vec2 left = vec2(up.y, -up.x);
			vec2 n = rel / max(rad, 0.0001);
			float t = fract(atan(dot(n, left), dot(n, up)) / TAU_C);
			float aa_t = max(fwidth(t), 0.0001);
			// Guard the wrap seam: fwidth explodes across t's 1→0 discontinuity,
			// which would smear the whole gauge on that one texel column.
			float edge = (aa_t > 0.25) ? step(t, stamina_zone.z)
					: smoothstep(stamina_zone.z + aa_t, stamina_zone.z - aa_t, t);
			vec4 col = mix(stamina_track_col, stamina_fill_col, edge);
			float a = in_band * col.a;
			hud_rgb = hud_rgb * (1.0 - a) + col.rgb * a;
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
