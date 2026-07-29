shader_type spatial;

// Stick shaft flex — bows the shaft between its pinned endpoints.
//
// The shaft is a unit-length BoxMesh that update_stick_mesh() stretches
// between the top hand and the blade heel (node scale.z = live length), so
// VERTEX.z runs [-0.5, +0.5] in object space with the BLADE end at -0.5
// (look_at points -Z at the blade). Object-space X is perpendicular to the
// shaft and unaffected by the Z stretch, so a bow displaced here survives
// the per-frame resize untouched. sin(PI * t^kick) is zero at both ends —
// the hand and blade anchors (gameplay) never move; only the material
// between them curves. kick_point < 1 shifts the bulge toward the blade
// end (a low-kick stick); the mesh needs subdivide_depth > 0 to have
// vertices along the length to bend (set in Skater._ready).
//
// flex_m is driven per rendered frame by Skater._update_stick_flex from
// replicated state (shot charge / shot state), so every machine renders
// the identical bend.

// Handle wrap (StickTapeConfig.KnobStyle) is painted here rather than meshed:
// the shaft is one stretched box, so separate wrap geometry would need
// per-frame placement AND its own copy of the flex bow. Fragment paint gets
// both for free. grip_mode 0 = bare, 1 = candy-cane spiral, 2 = full grip;
// the wrap hangs down grip_len_m of REAL shaft from the hand end (object z =
// +0.5), which needs shaft_len_m because node scale never reaches object
// space — update_stick_mesh feeds the live hand→blade length.

uniform vec4 albedo : source_color = vec4(0.06, 0.06, 0.07, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float flex_m = 0.0;                              // signed mid-shaft bow, metres
uniform float kick_point : hint_range(0.3, 2.0) = 0.75;  // <1 = bulge toward the blade
uniform int grip_mode = 0;                               // StickTapeConfig.KnobStyle
uniform vec4 grip_color : source_color = vec4(1.0);
uniform float grip_len_m = 0.45;                         // wrap reach below the hand
uniform float shaft_len_m = 1.3;                         // live rendered shaft length

// Candy-cane pitch: one full turn per this much shaft, half tape half bare.
const float CANDY_PERIOD_M = 0.075;

varying vec3 obj_pos;                                    // pre-flex object-space position

void vertex() {
	obj_pos = VERTEX;
	float t = clamp(VERTEX.z + 0.5, 0.0, 1.0);
	VERTEX.x += flex_m * sin(PI * pow(t, kick_point));
}

void fragment() {
	vec3 col = albedo.rgb;
	float rough = roughness;
	float from_hand = (0.5 - obj_pos.z) * shaft_len_m;
	if (grip_mode != 0 && from_hand < grip_len_m) {
		bool taped = true;
		if (grip_mode == 1) {
			// Barber-pole spiral: tape band advances one turn per period.
			float ang = atan(obj_pos.y, obj_pos.x) / (2.0 * PI);
			taped = fract(from_hand / CANDY_PERIOD_M + ang) < 0.5;
		}
		if (taped) {
			col = grip_color.rgb;
			rough = 0.9;  // cloth over composite
		}
	}
	ALBEDO = col;
	ROUGHNESS = rough;
}
