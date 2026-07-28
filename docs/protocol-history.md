# Protocol version history

`BuildInfo.PROTOCOL_VERSION` is checked in the `request_join` handshake and
stamped on Steam lobbies. This file is the record of what each bump changed and
why — reference material, read when you need to know what a given version means.

**The rules for when to bump live in `Scripts/game/build_info.gd`.** Add an entry
here whenever you bump, in the same format.

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
# v32: 5v5 mode — notify_lobby_settings / notify_game_start /
#      notify_join_in_progress each grew a positional team_size arg, and
#      team_slot's range widened to 0..4 (LD/RD lobby positions).
# v33: notify_lobby_settings grew bot_difficulty + goalie_difficulty args so
#      clients' dimmed lobby dropdowns mirror the host's AI difficulty picks
#      (display only — the AI is host-simulated from the host's PlayerPrefs).
# v34: input-batch header u16 repurposed — was the client's last-received
#      world-state seq (an echo the host diffed to estimate loss, which
#      undersampled and inflated a clean link to ~50%); now carries the client's
#      OWN measured downstream loss in basis points, stored verbatim as the peer
#      loss. Same header size, but a mixed-build host would read the field as a
#      seq and mis-estimate loss, so a bump is required.
# v35: host-measured peer RTT. The forgeable client report_ping RPC (a self-
#      reported RTT the host trusted for lag-comp claim-stamp validation) is
#      replaced by a host-initiated round trip (host_ping -> peer echoes
#      host_pong -> host measures + EMA-smooths). Adding/removing @rpc methods
#      shifts the name-sorted RPC index of every method after them (see v14/v23),
#      so a bump is required even though no serialized wire format changed.
# v36: attributes model replaced — request_join / request_update_attributes carry
#      the new height + three-tier build (4 ints: height/skating/skill/checking)
#      instead of the old six 1..5 attributes. Host validates with is_legal_build
#      (one-strong-one-weak) instead of the point-buy budget. Fewer positional
#      args on both RPCs, so a mixed-build pair decodes garbage — bump required.
# v37: attributes v4 (body + gear) — request_join / request_update_attributes /
#      spawn_remote_skater carry 6 ints (height, weight, profile, curve, flex,
#      length) instead of the 4-int height+tier build. Validation is pure
#      coercion (lateral axes, no legal-shape check). Positional arg counts
#      changed on all three RPCs — bump required.
# v38: deterministic puck goes authoritative + Phase-3 client prediction. The
#      host's loose puck is now the analytic sim in EVERY build (not just dev),
#      clients predict it to host-present with the same shared step, and the
#      host rewinds loose-puck claims (pickup / one-timer range) to the claim
#      stamp instead of the interpolated past (LagCompRewind.puck_view_time).
#      No serialized format changed, but a v37 peer would render/validate
#      against different puck physics and a mismatched claim-rewind convention,
#      so mixed lobbies must be refused.
# v39: adaptive input lead. The client's stamp lead becomes INPUT_LEAD_SEC + a
#      servo-adapted extra (ClockSync measures pop-overdue from the snapshot
#      ack stream), and the four blade/hit claim RPCs gain an input_lead_ms arg
#      so LagCompRewind.self_view_time rewinds with the lead the claimant
#      actually stamped with (bounded host-side). Positional arg counts changed
#      on all four claim RPCs — bump required.
# v40: pickup-claim NACK. New authority RPC notify_pickup_claim_rejected —
#      the host tells a claimant its pickup claim resolved to no-grant (stamp
#      reject, geometry miss, deflect verdict, contest loss) so the client's
#      optimistic pin rolls back immediately instead of waiting out the
#      RTT-scaled timeout. Adding an @rpc method shifts the rpc-config
#      ordering both peers hash, so mixed builds must be refused.
# v41: input block 23 -> 24 B — gamepad committed wrister power reaches the host.
#      Flags gain bit [13] (commit_wrister_power) plus a new u8 power byte @23
#      (bot_wrister_power_t, 1/255 steps). A pad CLIENT previously predicted power
#      from its right-stick push while the host, seeing neither field, re-derived
#      it from the pad's PARKED cursor (~0 speed) and fired at the floor — a
#      predicted snipe vs. an authoritative floater on every pad wrister online.
#      Both the size change and the new flag semantics make mixed builds unsafe.
# v42: world-state broadcast rate 120 -> 60 Hz (Constants.STATE_RATE). No packet
#      layout change, but STATE_RATE is a shared TIMING convention baked into
#      both sides: the interpolation-delay target (rtt/2 + broadcast_interval +
#      PDV), the client's arrival-jitter expected_interval, and the host's
#      claim-carried interp-delay plausibility ceiling all derive from it. A
#      mixed pair would size its cushion and validate claims against the wrong
#      interval, so the lobby must be rate-homogeneous.
# v43: analytics A1 — the per-player stats record gains two host-authoritative
#      broadcast counters (shot_attempts, shot_attempts_blocked → Corsi/Fenwick),
#      widening STATS_PLAYER_RECORD_SIZE 15 → 17. A v42 peer would misalign the
#      stats player-block walk, so mixed builds must be refused.
# v44: analytics A2 — the stats record gains a float xg_for (individual expected
#      goals), widening STATS_PLAYER_RECORD_SIZE 17 → 18. Same misalignment risk
#      against a v43 peer, so mixed builds must be refused.
# v45: analytics B1 — new authority RPC receive_shot_events: the host pushes the
#      game's shot log at game-over so clients can render their own post-game
#      shot map. Adding an @rpc method shifts the rpc-config ordering both peers
#      hash, so mixed builds must be refused.
# v46: the height dial extends to 6'8" (80"). Height already rode the wire as a
#      plain int, but the VALUE 80 is new: an older peer coerces it back to 79
#      and would then simulate a different mass, top speed and reach than the
#      host, diverging prediction. Mixed builds must be refused.
# v47: shot_events carries the release CONTEXT — the defending goalie's stance,
#      unset fraction, challenge radius, lateral position and screen delay, plus
#      the shooter's speed, seconds since the goalie's last save, and the
#      release's lateral pace. ShotEvent.WIRE_SIZE 10 -> 18, which
#      receive_shot_events ships host->client at game-over. A v46 client size-
#      checks each record in from_array and would silently drop every one,
#      rendering an empty post-game shot map. Mixed builds must be refused.
