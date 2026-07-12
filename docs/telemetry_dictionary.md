# Network Telemetry Dictionary

How to read a `network_sessions` row (or the `network_session_health` /
`match_health` views built on it). **This file is the interpretation key —
paste it alongside a row when asking an LLM (or a human) to diagnose a
session.** Rows deliberately carry raw numbers with no baked-in verdicts; the
healthy bands live here and in the F3 overlay only.

Sources of truth: metrics are folded once per second in
`Scripts/networking/network_telemetry.gd` (`_fold_session_sample`) into
`Scripts/domain/state/network_session_summary.gd`; the healthy bands below
mirror the F3 overlay (`Scripts/ui/network_debug_overlay.gd`). If a threshold
moves there, move it here.

## Row anatomy (typed columns)

| Column | Meaning |
|---|---|
| `steam_id`, `player_name`, `platform`, `game_version` | Who/where/what build. |
| `role` | `host` or `client`. **Read metrics through this**: several fold structural zeros on the role they don't apply to (see per-metric notes). |
| `net_sim_active` | `true` = dev session with artificial lag (NetworkSimManager) — excluded from the analysis views. |
| `duration_sec` | Seconds of folded telemetry. Rows under 30 s are never posted. |
| `felt_lag_count` | Times the tester pressed F4 ("this feels laggy right now"). The subjective signal to correlate against everything else. |
| `game_id` | Cross-peer match UUID — the same value on the host row and every client row of one game (and on `career_stats` rows). Join key for `match_health`. |
| `end_reason` | How the session ended: `completed` (game over) · `quit` (local player left mid-game) · `host_lost` (client's connection to the host dropped) · `host_ended` (host ended the match) · `kicked`. Abnormal ends are the most diagnostic rows — a desync bad enough to quit over used to produce no row at all. |
| `metrics` | The full aggregate blob, keys below. |

## Aggregate suffixes

Each per-second metric `<key>` appears as:

- `<key>_avg` — session mean (divided by **total** session seconds, even for
  keys that only appear partway through).
- `<key>_max` — worst single 1 s window. One GC hiccup can own this number;
  read it with `_avg` for context.
- `<key>_min` — only for metrics where **lower is worse** (`sim_rate_hz`,
  `reconcile_match_pct`, `client_fps`, `buffer_depth_*`).
- `<key>_total` — only for **rare-event counters** (`puck_hard_snaps`,
  `blade_jumps`): the session sum. These are events-per-game, not rates —
  3 hard snaps in a 10-minute game matters and would average to ~0/s.

## Connection facts (link quality — context, not necessarily a bug)

A far or jittery link is *expected* and the netcode compensates; the damage a
bad link actually does surfaces through the prediction/interpolation metrics
below.

| Key | Unit | Healthy | Meaning |
|---|---|---|---|
| `rtt_ms` | ms | <80 great, 80–150 playable, >150 laggy | Client's round-trip to host. **Host rows fold 0** (the host has no RTT to itself). |
| `packet_loss_pct` | % | <1 great, >5 rubber-banding | Dropped packets on the client's inbound world-state stream. Host rows fold 0. |
| `jitter_p95_ms` | ms | <8 great, >20 rough | p95 deviation of raw packet arrival gaps (IPDV). Rises for genuine path jitter **and** for benign relay clumping — can't tell them apart on its own (the F3 Delay-spread line disambiguates live; not yet in the session fold). |
| `bytes_recv_per_sec` / `bytes_sent_per_sec` | B/s | client down ≈ host per-peer up; host up ≲ ~60 KB/s per peer | Payload bytes only (excludes Steam framing/relay overhead). Host `sent` sums across all peers. |
| `peer_count` | count | — | Connected clients (host rows only; clients fold 0). |

## Client prediction health (verdict-drivers)

| Key | Unit | Healthy | Meaning |
|---|---|---|---|
| `reconcile_per_sec` | /s | <1 | How often the server snapped the local skater's prediction. Sustained higher = real non-determinism in input replay, or a divergence channel the threshold check can't see. |
| `reconcile_mag_m` | m | <0.05 | Average snap distance. Large + frequent = corrections the player feels as rubber-banding. |
| `reconcile_match_pct` | % | ~100 | Share of reconcile lookups that found the client's own prediction for the server's ack timestamp. <100% = the client reconciles against *lag*, not real error — the single most diagnostic number for "why am I reconciling on a clean link." |
| `recon_pos_per_sec` / `recon_vel_per_sec` / `recon_ubody_per_sec` | /s | ~0 | Which channel tripped the snap: position vs velocity vs upper-body pose. Isolates *what* is diverging. |
| `recon_pos_offset_ticks` | ticks | ≈ ±1 benign | Same-timestamp position offset in ticks-of-travel, signed lead(+)/lag(−). A clean ±1 = one-tick capture/integration phase offset; noisy/large = real non-determinism. |
| `recon_post_replay_residual_m` | m | ≈ 0 | Distance from server *after* snap+replay. Persistent value = the replay never converges, so the error rebuilds every cycle. |

## Interpolation / render health (verdict-drivers)

| Key | Unit | Healthy | Meaning |
|---|---|---|---|
| `extrapolation_pct` | % of frames | <25 ok, >60 bad | Share of rendered frames dead-reckoning a remote entity past its buffer — the honest, framerate-independent "buffer ran dry" signal. High on a clumpy link = the jitter cushion is under-sizing. |
| `extrapolation_per_sec` | /s | <1 | Raw rate of the same thing — **scales with client fps**; prefer `_pct`. |
| `client_fps` | fps | machine-dependent | Effective render rate; contextualizes every per-frame-sampled rate. `_min` is the worst dip. |
| `buffer_depth_skater` / `buffer_depth_puck` | frames | 2–4; `_min` of 0–1 risks stutter | Interp frames queued for remote skaters / the loose puck. Client-only signal (host rows fold 0). |
| `ooo_drops_per_sec` | /s | ~0, occasional is normal UDP | Packets discarded for arriving out of order. A steady stream is a problem. |

## Rare-event tripwires (session totals; want 0)

| Key | Meaning |
|---|---|
| `puck_hard_snaps_total` | Puck trajectory-prediction corrections in the hard-snap zone (>1.5 m divergence). Expected only on genuine host/client physics divergence (a bounce that differed). Firing on every shot = trajectory math bug. Client only. |
| `blade_jumps_total` | Reconcile-induced blade teleports >5 cm (normal fast stickhandling is excluded). Client only. |

## Host frame / input health (host rows only; clients omit or fold 0)

| Key | Unit | Healthy | Meaning |
|---|---|---|---|
| `sim_rate_hz` | Hz | ≥97% of 120 | Effective physics tick rate. Below target = host overloaded, the sim dilates and **every client's** update rate sags with it. `_min` is the worst window. Omitted (not 0) on client rows. |
| `worst_stall_ms` | ms | <33 fine, >66 a hitch everyone felt | Longest gap between physics ticks in a window. |
| `broadcast_interval_p95_ms` | ms | ≈ 8.3 (120 Hz target); >1.4× target = sagging | p95 gap between world-state broadcasts. Sustained high = host stalling or send path backed up. Omitted on client rows. |
| `input_queue_depth` | frames | 1–3 | Client inputs buffered on the host. 0 = starving, high = backed up. |
| `input_lead_ms` | ms | ~0–10 | How late client inputs arrive vs schedule. |
| `input_starvations_per_sec` | /s | <0.5 | Host ticks that had no client input and reused the last one. This is where **client→host** packet loss shows up (the client's own `packet_loss_pct` only sees the inbound direction). |

## `felt_lag_markers`

Array of dicts (capped at 50; `felt_lag_count` keeps counting past the cap).
Each is one F4 press: `at_sec` (in-session time) plus a live snapshot of the
keys above at that instant, plus `buffer_depth_skater`, `buffer_depth_puck`,
and `puck_mode` (`interp` = smoothed, `trajectory` = predicted flight,
`carried` = on a stick). Note the press comes *after* the felt moment — the
snapshot may already look recovered; trust the marker's timing more than its
instantaneous values.

## `match_health` view (one row per game)

Joins the host row with its client rows via `game_id`. Netcode failure modes
are asymmetric, so read pairs: `host_worst_stall_ms` / `host_sim_rate_min`
high ⇒ expect elevated reconcile/extrapolation on **every** client row of the
same game (host-side cause); one client bad while siblings are clean ⇒ that
client's link. `host_starvations_peak` is the host-side echo of a client's
upstream loss. `worst_client_*` columns take the worst value across the lobby
— one bad experience is a bad match. `abnormal_ends > 0` flags games someone
didn't finish.
