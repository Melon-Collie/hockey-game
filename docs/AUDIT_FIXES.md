# Audit Fix Plan — tracking checklist

Execution plan for the findings in `AUDIT_2026-07_NETCODE_BOTS.md` (Parts One & Two).
Grouped by **test surface** so each batch is verifiable in one sitting. All work lands
on `claude/codebase-audit-net-bots-smz1x8` as focused commits; full GUT suite runs after
each batch. Decisions (2026-07): work straight through batch-by-batch · faceoff goals fixed
by advancing the phase on any puck contact · icing ghost removed (not implemented) · backend
hardened minimally now, host-side SteamID auth + kick-ban deferred to a pre-launch pass.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[»]` deferred by decision.
"Verify" = who confirms and how (GUT = I run headless · SOLO = you, free play, one machine ·
2P = you, two machines online · SQL = you apply in the Supabase editor).

## Batch 1 — Backend & SQL · verify: SQL + GUT
- [x] P2-3  Drop the dead `career_stats` anon UPDATE policy
- [x] P2-11 CHECK + size constraints on career_stats / bug_reports / network_sessions
- [x] P2-12 Gate crash auto-report on `share_gameplay_stats`
- [x] Fix stale "INSERT/SELECT/UPDATE" comments (supabase_config.gd, bug_reporter.gd)
- [»] P2-4  Host-side SteamID64 authentication (pre-launch)
- [»] P2-15 Kick-ban by SteamID (pre-launch; depends on P2-4)

## Batch 2 — Pure-logic, GUT-verifiable · verify: GUT
- [x] P1-3  Bot wrister wind-up handedness sign + test
- [x] P1-4  AI dispatch-throttle counter units (evade/jab/pre-aim step by period; carrier cooldown+hold clock in real ticks)
- [x] P2-6  Migration budget enforcement (pure `trimmed_to_budget` + one choke point) + host self-attr fallback + tests
- [x] P2-16 AI trajectory bounce model reflects off the rounded corners + test
- [x] Part1-P2 finisher lift cache (stick_lift_held cached across skip ticks)
- [x] Part1-P2 one-timer-ready preserve now bounded (~1.5s) so a dead pass doesn't pin the finisher
- [»] Part1-P2 one-timer power model — DEFERRED: line carrier.gd:610 deliberately scores the
      receiver at league-default wrister speed (documented "we don't carry teammates' attributes"),
      and the unsettled-goalie term already partly justifies the high value. Correcting it changes
      bot pass-selection feel; needs a playtest + your call, not a blind headless edit.

Note: deleting `.godot/global_script_class_cache.cfg` + reimport was needed after
editing scripts — a stale cache was silently skipping ~68 test scripts (showed
1253 instead of the true 1321). Regenerated; keep an eye out after bulk edits.

## Batch 3 — Puck physics & geometry · verify: SOLO
- [x] P2-1  Perimeter collision now extends to COLLISION_OVERGLASS_TOP (3.2) above the puck clamp — closes the escape
- [x] P2-9  Height-aware OOB whistle (over-boards term) as defense-in-depth
- [x] P2-10 Clear `_pending_elevation_vel`/`_pending_elevation` in reset()/drop()
- [x] P2-13 Board-hit fires only on `body is HockeyRink`, not the ice StaticBody
- [x] P3    Wake sleeping puck in reset() (`sleeping = false`)
- [»] P3    Goal-frame PhysicsMaterial — DEFERRED: dead-post vs bouncy is a feel call for you.
      Real posts ping hard; boards are 0.4. Say the word and I'll author the trivial .tres + mirror test.

SOLO test after pulling: (1) toggle elevation, tip/deflect a hard shot near the boards repeatedly —
puck must never leave the rink; (2) pass/shoot and confirm the board thud/chip VFX no longer fires on
release or on the puck landing on open ice; (3) faceoffs after a shot-into-whistle drop cleanly.

## Batch 4 — Goalie · verify: SOLO
- [x] P0-2  Not-upright reaction-timer zeroing now guarded by `not reacting` — down/moving reactions keep their delay
- [x] Part1-P2 cross-crease standing drive clamps by `cross_crease_drive_edge` (0.42), not the butterfly pad edge → seals the far post instead of net-center
- [→] Part1-P2 goalie glove/blocker s8→s16 clip + `rotation_y` wrap are WIRE changes → moved to Batch 6 (protocol bump)
- [»] P3 slide body-lean sign (cosmetic, ~6°) — low priority, can fold into a later pass

SOLO test: (1) shoot high/rebound at a butterflied or recovering goalie — top corners should be
beatable again (goalie no longer reaches instantly while down); (2) run a royal-road cross-crease
one-timer — the goalie should drive toward the far post, not park at net-center.

## Batch 5 — Slot / reservation / lobby integrity · verify: 2P
- [x] P2-5  `is_slot_reserved` check in try_swap_slot (+ test) and _promote_spectator_to_player
- [x] P2-8  Clear `_reserved_slots` on rematch (_apply_reset)
- [x] P2-14 Promote liveness guard (peer still in connected_peer_ids)
- [~] P2-17 Confirm-button `_leaving` guard added (double-teardown). Op-pending host/join
      re-entrancy gate DEFERRED to the 2P/Steam testing pass — needs live async-callback validation.
- [x] Session field-reset sweep: `_peer_ping_ms` (reset + prepare + per-peer disconnect), the
      other per-peer telemetry dicts on disconnect, lobby period/rule settings in reset(), `_in_replay_locally` in on_scene_exit
- [x] P3    `reset_game()` is_host guard

2P test: reconnect into a held slot after a teammate changed position (no double-spawn on a dot);
promote a spectator whose peer just left (no phantom skater); spam Return-to-Free-Play/Exit (single teardown).

## Batch 6 — Wire + reconcile determinism · verify: 2P · ONE PROTOCOL_VERSION bump
- [ ] P0-1  `stagger_timer` wire field + codec completeness test
- [ ] Part1-P2 goalie glove/blocker offsets s8→s16
- [ ] Part1-P2 goalie `rotation_y` wrap-not-clamp on encode
- [ ] P1-5  Lead-aware lag-comp rewind (report delay × (1 − lead_fraction))
- [ ] P1-7  Reconcile replay determinism holes (snapshot live puck/goalie reads)
- [ ] P1-6  Host-measured ping for claim-stamp plausibility (or bounds-clamp report_ping)
- [ ] Part1-P2 body-check impulse replay phasing + contested-pickup present-time state

## Batch 7 — Game flow & docs · verify: SOLO + doc-only
- [ ] P2-2  Faceoff-phase goal void — advance FACEOFF→PLAYING on any puck contact
- [ ] P2-7  Remove dead icing-ghost path + correct CLAUDE.md claim
- [ ] P2-17b (telemetry) phase-gate 5 Hz dead-puck jitter/extrapolation accounting
- [ ] Docs  Rewrite both drift tables in ARCHITECTURE.md / CLAUDE.md

## Deferred to a pre-launch pass
- [»] P2-4 / P2-15 SteamID64 auth + kick-ban
- [»] Codec + per-tick allocation cleanups (wire encode/decode scratch reuse) — when profiling motivates
