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
- `<key>_total` — only for **rare-event / event counters** (`puck_hard_snaps`,
  `blade_jumps`, the host-side lag-comp claim counters `pickup_claims` /
  `pickup_claim_misses` / `pickup_claim_deflects` / `poke_claims` /
  `poke_claim_misses` / `stick_lift_claims` / `stick_lift_claim_misses`, the
  client-side `provisional_*`, and the host-side `host_stalls`): the session sum.
  These are events-per-game, not rates — 3 hard snaps in a 10-minute game matters
  and would average to ~0/s.

## Connection facts (link quality — context, not necessarily a bug)

A far or jittery link is *expected* and the netcode compensates; the damage a
bad link actually does surfaces through the prediction/interpolation metrics
below.

| Key | Unit | Healthy | Meaning |
|---|---|---|---|
| `rtt_ms` | ms | <80 great, 80–150 playable, >150 laggy | Client's round-trip to host. **Host rows fold 0** (the host has no RTT to itself). |
| `packet_loss_pct` | % | <1 great, >5 rubber-banding | Dropped packets on the client's inbound world-state stream. Host rows fold 0. |
| `jitter_p95_ms` | ms | <8 great, >20 rough | p95 deviation of raw packet arrival gaps (IPDV). Rises for genuine path jitter **and** for benign relay clumping — read with `delay_spread_ms` to tell them apart. |
| `delay_spread_ms` | ms | <8 great, >20 rough | De-clumped path jitter (PDV — each packet timed against the synced host clock). **The clumping tell: `jitter_p95` high + this low ⇒ relay clumping (benign); both high ⇒ genuinely jittery path.** Also the term that sizes the interpolation cushion — `extrapolation_pct` climbing while this stays low means the cushion under-sizes. Client only. |
| `clock_correction_ms` | ms | ~0–2 settled | Magnitude of the last clock-sync offset correction. Sustained large = the clock estimate is unstable (asymmetric path, drift), which silently poisons lag-comp rewind timestamps and the delay-spread read before anything visibly breaks. Client only. |
| `worst_peer_rtt_ms` / `worst_peer_loss_pct` | ms / % | same bands as rtt/loss | Host rows only: the worst per-peer ping and downstream loss across the lobby at each window — the host row's real link picture (its own rtt/loss fold 0). **`worst_peer_loss_pct` is now the client's OWN measured loss reported back in its input-batch header** — the same accurate WS-seq-gap number the client puts in its `packet_loss_pct`. (Before, the host re-derived it from an echoed seq it undersampled, which counted received-but-not-echoed packets as dropped and inflated a clean link to ~50%.) Cross-checks the client rows via `match_health`. |
| `bytes_recv_per_sec` / `bytes_sent_per_sec` | B/s | client down ≈ host per-peer up; host up ≲ ~60 KB/s per peer | Payload bytes only (excludes Steam framing/relay overhead). Host `sent` sums across all peers. |
| `peer_count` | count | — | Connected clients (host rows only; clients fold 0). |

## Client prediction health (verdict-drivers)

| Key | Unit | Healthy | Meaning |
|---|---|---|---|
| `reconcile_per_sec` | /s | <1 | How often the server snapped the local skater's prediction. Sustained higher = real non-determinism in input replay, or a divergence channel the threshold check can't see. |
| `reconcile_mag_m` | m | <0.05 | Average snap distance. Large + frequent = corrections the player feels as rubber-banding. |
| `reconcile_match_pct` | % | ~100 | Share of reconcile lookups that found the client's own prediction for the server's ack timestamp. <100% = the client reconciles against *lag*, not real error — a miss falls back to the (prediction-lead-ahead) live position and trips a spurious position snap, so a low match rate is the dominant residual-churn driver. **Read `_avg` and `_min` together**: `_min` (one post-faceoff window can own it) flags transients; a low `_avg` means the shortfall is *sustained*. The `reconcile_miss_*` totals below say why. |
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
| `reconcile_miss_empty_total` / `reconcile_miss_older_total` | Match-miss attribution (client only). `EMPTY` = prediction history was empty, `OLDER` = ack preceded the oldest kept prediction. Both are the **benign post-clear transient** — a teleport / dead-puck freeze wipes the history and resets the ack, so the next ~RTT of broadcasts ack pre-clear inputs. Expected in small numbers around every faceoff/goal. |
| `reconcile_miss_newer_total` / `reconcile_miss_gap_total` | The **bug** buckets. `NEWER` = ack ran past the newest prediction (shouldn't happen in steady play). `GAP` = ack fell *between* two kept predictions by >1 ms — a real hole in the history (an input that never got a snapshot, or over-aggressive trimming). A large `GAP` total is the thing to chase when `reconcile_match_avg` is low. Client only. |
| `reconcile_miss_gap_ms_peak` | Worst ack-vs-nearest-history-bound distance on a miss (ms). Large ⇒ clear-related (ack far behind history); near the 1 ms epsilon ⇒ an off-by-one / quantization edge. Client only. |
| `shot_launch_div_peak` / `shot_launch_vel_div_peak` | Worst client-predicted-vs-host-authoritative gap (m / m·s⁻¹) at the first host-confirmed broadcast after a **local shot release**. Client and host run identical Jolt from the same client-sent origin, so this should be tiny (RTT jitter) — a large peak is genuine shot-launch divergence, and it's the shot-launch slice of `puck_hard_snaps` (>1.5 m here would hard-snap). Client only. |
| `shot_launches_total` | Shots measured — the denominator for the two peaks above (a big peak over 2 shots ≠ a big peak over 40). Client only. |

## Lag-comp claim health (host rows only)

The host processes every client's pickup / poke / stick-lift claim, so its row
summarizes whether the lag-comp rewind reproduces what clients saw when they
reached for a puck or an opponent's stick. Read the miss/deflect totals
**relative to the matching `*_claims_total`** — the raw counts scale with how
much loose-puck / stick-battle play a game had.

Since **v28** each claim carries the client's own blade geometry (its
"aim" — the precise thing the client is authoritative over, matching AAA FPS
lag-comp, which takes the shooter's aim from the usercmd) instead of the host
reconstructing the claimant's blade from its lossy self-view snapshot. The host
still owns the body: it reach-clamps the client blade to the server-authoritative
body before the geometry test. So a *miss* here now means the client-sent blade
(within physical reach) still didn't overlap the rewound target — a genuinely
stale rewind, no longer the reconstruction divergence that drove the pre-v28
grab-then-lose bug. A miss fraction that stays high after v28 points at the
**puck/target** rewind (remote-view interp delay), not the blade.

| Key | Meaning |
|---|---|
| `pickup_claims_total` | Client pickup claims that reached the rewound geometry test (all eligibility gates — fresh, loose, not ghost/cooldown/shot-blocking — passed). The denominator. |
| `pickup_claim_misses_total` | Of those, how many failed the geometry test: the (reach-clamped) client blade and rewound puck didn't overlap even though the client's view said in-range. **`misses / claims` is the headline sanity number — near-zero means the rewind reproduces the client's view; a high fraction means the puck rewind is off (the "reached for it, didn't get it" symptom).** |
| `pickup_claim_deflects_total` | Reached the puck but the rewound speed/angle said tip-not-catch (a deflect, not a catch). Separates "missed the puck" from "touched it but it wasn't catchable". |
| `poke_claims_total` | Client poke claims that reached the rewound swept-geometry test (opponent carrier, not ghost, pokeable). The denominator for pokes. |
| `poke_claim_misses_total` | Of those, how many failed the swept `check_poke` against the rewound carried puck. Read as `poke_claim_misses / poke_claims`. |
| `stick_lift_claims_total` | Client stick-lift claims that reached the rewound geometry test (blade hooked under an opposing carrier's shaft). The denominator for lifts. |
| `stick_lift_claim_misses_total` | Of those, how many failed `check_blade_under_stick` against the rewound shaft. Read as `stick_lift_claim_misses / stick_lift_claims`. |

## Optimistic-pickup outcomes (client rows only)

The **felt** side of the same story: when a client's blade reaches a loose puck it
optimistically **pins** the puck to the blade (instant-feeling grab) before the host
confirms. The host-side `pickup_claim_misses` above counts every rejected *claim*
(inflated by throttle re-fires); these count the *visual pin* — the thing the player
actually sees attach and, when it rolls back, feels as **"grab, then lose it."**

| Key | Meaning |
|---|---|
| `provisional_pins_total` | Optimistic pins that attached (passed the eligibility gates *and* the host's swept `check_pickup` predicate run on the client's own view). The denominator. |
| `provisional_timeouts_total` | Pins that rolled back because no host grant arrived — the host silently declined the claim. **This is the felt "grab, then lose it." `timeouts / pins` is the headline; it should sit near zero.** The dominant pre-v28 cause was blade-prediction divergence (the host reconstructed the claimant's blade and it disagreed with what the client saw); v28 sends the client's own blade in the claim, so a residual floor now points at the **puck** rewind (remote-view interp delay) or a genuine lost 50/50, not the blade. |
| `provisional_confirmed_total` | Pins the host granted (promoted seamlessly to a real carry). |
| `provisional_stolen_total` | Pins rolled back because a *different* carrier legitimately won the puck — a lost 50/50, **not** the felt bug. |

## Host frame / input health (host rows only; clients omit or fold 0)

| Key | Unit | Healthy | Meaning |
|---|---|---|---|
| `sim_rate_hz` | Hz | ≥97% of 120 | Effective physics tick rate. Below target = host overloaded, the sim dilates and **every client's** update rate sags with it. `_min` is the worst window. Omitted (not 0) on client rows. |
| `worst_stall_ms` | ms | <33 fine, >66 a hitch everyone felt | Longest gap between physics ticks in a window (the single worst hitch). |
| `host_stalls_total` | count | 0 | Session sum of physics ticks whose gap exceeded 33 ms — how MANY noticeable hitches, vs `worst_stall_ms`'s single worst. Read with the `auto_markers` (below), whose `phase` / `actor_count` / `last_event` attribute them. Host only; TOTAL_KEY. |
| `broadcast_interval_p95_ms` | ms | ≈ 8.3 (120 Hz target); >1.4× target = sagging | p95 gap between world-state broadcasts. Sustained high = host stalling or send path backed up. Omitted on client rows. |
| `input_queue_depth` | frames | 1–3 | Client inputs buffered on the host. 0 = starving, high = backed up. |
| `input_lead_ms` | ms | ~0–10 | How late client inputs arrive vs schedule. |
| `input_starvations_per_sec` | /s | <0.5 | Host ticks that had no fresh client input and reused the last one. Two causes: genuine **client→host** loss (the client's own `packet_loss_pct` can't see this outbound direction), and — more often — the **catch-up drain after a host stall** (a hitch, then a burst of physics ticks consumes the tiny input queue). A starvation spike sharing a window with a `host_stall`/`worst_stall_ms` spike is the latter; correlate before blaming the uplink. |

## Markers: `felt_lag_markers` and `auto_markers`

**`felt_lag_markers`** (capped at 50; `felt_lag_count` keeps counting past the
cap): one entry per F4 press — `at_sec` (in-session time) plus a live snapshot
of the keys above at that instant, plus `buffer_depth_skater`,
`buffer_depth_puck`, and `puck_mode` (`interp` = smoothed, `trajectory` =
predicted flight, `carried` = on a stick).

**`auto_markers`** (capped at 20 stored; `auto_marker_count` keeps counting):
the same mechanism fired by objective tripwires, so rare bugs land with a
timestamp even when nobody pressed F4. Each has a `trigger` naming the
tripwire — `puck_hard_snaps` (≥2 in a window), `reconcile_storm` (≥5/s),
`extrapolation` (≥60% of frames), `host_stall` (tick gap ≥66 ms),
`input_starvation` (≥5/s) — thresholds mirror the F3 overlay's BAD bands. A
per-trigger 30 s cooldown means a sustained failure records its *onset*, not
one marker per second; a burst of `auto_marker_count` with few stored markers
means the failure kept re-firing past the cooldowns. Each marker snapshot also
carries **attribution context**: `phase` (live game phase), `actor_count`, and —
when a phase transition fired recently — `last_event` (the entering phase name)
and `last_event_age_s`. For a `host_stall`, that pins *why*: a hitch in steady
`PLAYING` points at per-tick cost; one in `GOAL_SCORED` / `FACEOFF_PREP`, or a
small `last_event_age_s` after that transition, points at that phase's handler
(goal-replay capture, faceoff reset). `input_starvation` markers usually sit in
the same window as a `host_stall` — starvation is the catch-up-tick drain *after*
a hitch, not independent client→host loss.

**`history`** (both kinds): the first 8 markers of a session carry a
`history` array — the ~6 one-second samples (rounded, each with its own
`at_sec`) leading up to the moment. This is the event trace: an F4 press (and
even an auto trigger) lands *after* the bad moment, so trust the history run-up
over the instantaneous snapshot. Later markers omit history to keep the row
under the 64 KiB jsonb cap.

## Getting the data without Supabase

Every posted row is also mirrored locally to `user://net_sessions/` (last 10,
JSON, same shape as the table row), so a tester can hand over their own
session even if the POST failed. Live, the F3 panel's **C** key copies the
current session digest (same payload) to the clipboard.

## `match_health` view (one row per game)

Joins the host row with its client rows via `game_id`. Netcode failure modes
are asymmetric, so read pairs: `host_worst_stall_ms` / `host_sim_rate_min`
high ⇒ expect elevated reconcile/extrapolation on **every** client row of the
same game (host-side cause); one client bad while siblings are clean ⇒ that
client's link. `host_starvations_peak` is the host-side echo of a client's
upstream loss. `worst_client_*` columns take the worst value across the lobby
— one bad experience is a bad match. `abnormal_ends > 0` flags games someone
didn't finish. `host_pickup_claim_misses` read against `host_pickup_claims` is
the per-match lag-comp pickup sanity check (high miss fraction ⇒ the rewind
isn't reproducing what clients saw); `host_poke_claim_misses` /
`host_poke_claims` and `host_stick_lift_claim_misses` / `host_stick_lift_claims`
are the same check for the two stick-battle actions.
