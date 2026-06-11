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
const PROTOCOL_VERSION: int = 1

const RELEASE_TAG: String = "latest"
const REPO: String = "Melon-Collie/mitts"
