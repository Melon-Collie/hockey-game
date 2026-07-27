extends Node

# Build version, baked in at export time; local editor runs stay as "dev". The
# deploy workflow (.github/workflows/deploy.yml) rewrites this to
# "0.1.<git rev-list --count HEAD>" before running the Godot export, and passes
# the same string as the GitHub Release name.

const VERSION: String = "dev"

# Network protocol version, checked in the request_join handshake and stamped on
# Steam lobbies. Independent of VERSION: builds that don't touch the wire keep
# the same protocol and stay compatible. Per-version history: docs/protocol-history.md
#
# Bump this manually whenever ANY of these change:
#   - Wire format — world-state codec layout, input encoding, RPC signatures.
#     Mixed-protocol sessions decode positional binary as garbage that still
#     passes size checks, so the host must reject mismatched joiners outright.
#   - The RPC method SET — adding or removing an @rpc method shifts the
#     rpc-config ordering both peers hash, breaking cross-build RPC routing even
#     when every existing wire format is untouched.
#   - The legal RANGE of an existing field, even at the same wire type. An older
#     peer coerces the new value back into its own range and then simulates
#     different physics than the host, diverging prediction.
const PROTOCOL_VERSION: int = 46


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
