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
# v10: world-state wire fixes. Skater block 38->39B: adds stagger_timer (u8 @0.01s)
#     — it was never serialized, so a client victim's predicted body-check stagger
#     was wiped to 0 on the next reconcile (full-thrust replay vs penalised host).
#     Goalie block 35->41B: glove/blocker offsets s8->s16 (Y reach 1.55m exceeded
#     the s8 ±1.27m range, clipping above-crossbar reaches ~28cm low), and rotation_y
#     is wrapped into (-PI,PI] before quantizing (the -Z goalie's facing pinned flat).
# v11: elevation binary -> 3-level loft. Input flags bits [6..7] (were the
#     elevation_up/down edges) now carry an absolute 2-bit elevation_level;
#     skater world-state flags byte repacked (shot_state 4 -> 3 bits,
#     elevation_level 2 bits at [3..4], ghost/blade_up/sprint_locked shifted).
# v12: stats packet grew — PlayerStats.to_array() 5 -> 9 (hits_taken, takeaways,
#      giveaways, faceoff_wins), so STATS_PLAYER_RECORD_SIZE 6 -> 10.
# v13: goalie block 41 -> 43 B — pad yaw (the rebound-steering toe-out) joins
#      the wire so remote clients render the angled pads the host's rebound
#      physics actually plays off.
# v14: added request_update_attributes RPC (lobby build changes) — a new @rpc
#     method shifts the name-sorted RPC index of every method after it (see v3),
#     so a bump is required even though request_join's wire format is unchanged.
# v15: skater block 39 -> 40 B — movement-intent byte (8-way move octant +
#     moving + brake bits) so client-rendered remotes play the input-driven
#     gait reads (glide on no keys, intent crossovers, brake-gated stop).
# v16: intent byte gains bit [5] — resolved sprint_active, so client-rendered
#     remotes play the sprint gait (longer strides, deeper sit, forward lean —
#     the on-screen opponent-stamina tell). Block size unchanged.
# v17: latency pass. (a) Input batching 60 -> 120 Hz; ClockSync.BATCH_INTERVAL
#     now derives from Constants.INPUT_RATE, shrinking INPUT_LEAD_SEC
#     33.3 -> 25 ms — the lead is a host/client convention baked into every
#     lag-comp rewind (LagCompRewind.self_view_time), so mixed builds would
#     skew claim arbitration by 8.3 ms. (b) World-state packets carry a
#     trailing carrier-event block (SnapshotEventLog: u8 count last, 13 B
#     records before it) so carrier events survive reliable-packet loss
#     without a retransmit-RTT stall; the four carrier RPCs
#     (notify_carrier_changed / notify_puck_picked_up / notify_puck_stolen /
#     notify_puck_dropped) gained a leading event_seq arg for cross-channel
#     dedupe.
# v18: stats packet grew — PlayerStats.to_array() 9 -> 10 (faceoff_losses,
#     the opposing centre's charge on a draw, so faceoff win % has a real
#     denominator), so STATS_PLAYER_RECORD_SIZE 10 -> 11.
# v19: notify_body_check carries hitter_peer_id ahead of the victim, so every
#     machine fires the hitter's check-delivery body pose off the same
#     broadcast that drives the burst/thud.
# v20: request_join carries the joiner's Shot Power Sensitivity (trailing f32),
#     so the host fires a remote human's pure-mouse wrister at the same power
#     their own client predicted with its local sensitivity.
# v21: notify_goalie_freeze_called RPC (NHL goalie cover whistle).
# v22: notify_team_colors RPC — the unified-Play lobby's host-picked palettes
#     for humanless teams replicate to clients' lobby previews.
# v23: smart-ping RPCs (request_smart_ping / notify_smart_ping) — the
#     context-sensitive team message + bot-directive broadcast. New @rpc
#     methods shift the name-sorted RPC indices (see v14), so a bump is
#     required even though existing wire formats are unchanged.
# v24: stats packet grew — PlayerStats.to_array() 10 -> 11 (game_winning_goals,
#     host-stamped at the final horn for the Three Stars GWG bonus), so
#     STATS_PLAYER_RECORD_SIZE 11 -> 12.
# v25: rematch vote widened bool -> int (RematchVoteRules.Choice) so the
#     end-of-game vote carries a flavor — REMATCH or return-to-LOBBY — through
#     the same request/notify pair (a mixed-build vote would decode the wrong
#     variant type), plus a new notify_rematch_voters RPC (host-broadcast voter
#     total, the skip-vote pattern) shifting the name-sorted RPC indices.
# v26: input flags gain bit [12] — hit_held (the body-check / hit button, C).
#     Reuses a previously-zero bit in the existing u16 flags, so BYTES_SIZE is
#     unchanged, but the wire semantics differ (a mixed-build host would read a
#     new client's hit intent as noise), so a bump is required. Not yet consumed
#     by any behavior — wired ahead of the hit-system redesign.
# v27: skater world-state block 40 -> 41 B — adds knockdown_timer (u8 @0.01s) after
#     stagger_timer, so a hard body check that knocks the victim down replicates and
#     the local victim's predicted knockdown survives reconcile (same rail/reason as
#     stagger's v10 add).
# v28: intent byte gains bit [6] — hit_committed (the body-check brace/delivery
#     signal, moved off brake onto the Hit button). No block-size change (spare bit),
#     but a client now reads a remote victim's brace and a remote attacker's
#     full-vs-passive delivery from it, so a bump is required.
# v29: two new host-broadcast cue RPCs (notify_post_hit / notify_goalie_hit) so a
#     puck off the post or a pad/goalie save is heard by every peer, not only those
#     whose local puck prediction registered the contact (matching the existing
#     deflection / board / body-block broadcasts). New RPC methods shift the
#     name-sorted RPC indices, so a mixed-build pair would call the wrong method.
# v30: stats packet grew — PlayerStats.to_array() 11 -> 14 (one_timer_goals,
#      tip_goals, ot_goals: host-tagged goal-flavor / overtime-winner counters
#      driving the One-Timer / Redirect / Overtime Hero achievements), so
#      STATS_PLAYER_RECORD_SIZE 12 -> 15.
# v31: pickup / poke / stick-lift claim RPCs carry the client's own blade geometry
#     (client-authoritative "aim"): pickup adds blade_curr + blade_prev + top_hand,
#     poke adds blade_curr + blade_prev, stick-lift adds blade_curr. The host now
#     validates against the client-sent blade (reach-clamped to the server body)
#     instead of reconstructing it from its self-view snapshot, so a legit grab the
#     host's reconstruction was rejecting (the grab-then-lose bug) now confirms. A
#     mixed-build host would read the extra Vector3 args as garbage, so a bump is
#     required.
const PROTOCOL_VERSION: int = 31


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
