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
const PROTOCOL_VERSION: int = 4

const RELEASE_TAG: String = "latest"
const REPO: String = "Melon-Collie/mitts"
