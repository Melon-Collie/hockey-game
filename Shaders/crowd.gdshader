// Spectator crowd animation. Both crowd MultiMeshes (bodies + heads) share
// one material with this shader, so the whole bowl animates off a single
// `excitement` uniform with zero per-frame CPU work.
//
// Per-instance INSTANCE_CUSTOM (set once at build time in ArenaStands):
//   .x = phase (0..1)      — de-syncs motion between neighbours
//   .y = sway amplitude    — how much this fan rocks side to side
//   .z = hop amplitude     — how hard this fan jumps when excited
//
// The head mesh shares the body's instance transform and custom data, and
// displacement is a continuous function of local VERTEX.y — so head and body
// move as one person even though they're separate draw calls.
shader_type spatial;
render_mode cull_disabled;

// 0 = idle murmur sway, 1 = goal celebration. Tweened by ArenaStands.
uniform float excitement : hint_range(0.0, 1.0) = 0.0;

void vertex() {
	float phase = INSTANCE_CUSTOM.x * 6.2831853;
	float sway_amp = INSTANCE_CUSTOM.y;
	float hop_amp = INSTANCE_CUSTOM.z;
	// Sway: lean grows with height, so heads move more than hips.
	float sway = sin(TIME * 1.4 + phase) * mix(0.03, 0.10, excitement) * sway_amp;
	VERTEX.x += sway * VERTEX.y;
	// Celebration hop: whole spectator bounces, frequency de-synced per fan.
	float hop_freq = 4.2 + 2.4 * INSTANCE_CUSTOM.x;
	float hop = abs(sin(TIME * hop_freq + phase)) * 0.18 * hop_amp * excitement;
	VERTEX.y += hop;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.85;
}
