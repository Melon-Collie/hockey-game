extends Node

# Build version, baked in at export time. Local editor runs stay as "dev" so
# the update notifier skips its network check. The deploy workflow (.github/
# workflows/deploy.yml) rewrites VERSION to "0.1.<git rev-list --count HEAD>"
# before running the Godot export, and passes the same string as the GitHub
# Release name so the notifier can compare against it.

const VERSION: String = "dev"

# Network protocol version, checked in the request_join handshake and stamped
# on Steam lobbies. Bump this manually whenever the wire format changes
# (world-state codec layout, input encoding, RPC signatures) — mixed-protocol
# sessions decode positional binary as garbage that passes size checks, so the
# host rejects mismatched joiners outright. Independent of VERSION: builds
# that don't touch the wire keep the same protocol and stay compatible.
# v2: wire timestamps f32 seconds -> u32 0.1ms units (world-state header,
#     skater last_processed_ts, input host_timestamp).
# v3: added notify_match_ended RPC (graceful host shutdown) — Godot identifies
#     RPCs by index in the name-sorted method list, so adding one shifts every
#     index after it and breaks cross-build RPC routing.
# v4: puck wire Y widened s8 -> s16 (was clipping elevated/saucer shots at the
#     s8 ±1.27 m range); puck block grew 12 -> 13 bytes.
# v5: sprint/stamina — skater wire block 37->38 bytes (u8 stamina + sprint_locked
#     flag bit); input flags reuse the previously-reserved bit [4] for sprint_held.
# v6: attributes 4 -> 6 (Speed/Agility/Hands/Size/Physical/Shot) — request_join /
#     spawn_remote_skater now carry six int levels instead of four.
# v7: request_join carries the joiner's SteamID64 so the host can match a
#     reconnecting peer (new peer_id) to a reserved slot and restore their
#     team/slot/stats.
# v8: request_join carries the joiner's Steam BuildID. Matching PROTOCOL_VERSION
#     only proves the wire decodes; a physics/tuning change with the same wire
#     format still desyncs client prediction against host authority. The Steam
#     BuildID bumps on every upload, so the host rejects mismatched builds
#     (skipped when either side is a dev / non-Steam build, BuildID 0).
# v9: input mouse_screen_pos wire encoding u16 -> s16 (same 2 bytes). The u16
#     clamp floored the attack_up team-1 negated cursor to (0,0), so the host
#     derived zero wrister charge / null aim for those shooters and fired drags
#     as taps. Signed encoding round-trips the negation.
const PROTOCOL_VERSION: int = 9


func _ready() -> void:
	# Startup banner, printed once at boot. File logging is enabled in
	# project.godot ([debug] file_logging → user://logs/mitts.log), so this line
	# heads every persisted log — making a player's crash log self-identifying
	# (which build, OS, and GPU produced it) without needing to ask. The engine's
	# native crash handler appends its backtrace to the same log on a hard crash,
	# which is the only "catch" available for a native (e.g. physics) abort.
	print("=== Mitts %s (protocol v%d) | %s | %s | Godot %s ===" % [
		VERSION, PROTOCOL_VERSION, OS.get_name(),
		RenderingServer.get_video_adapter_name(),
		String(Engine.get_version_info().get("string", "?")),
	])
