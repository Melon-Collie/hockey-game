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
- [ ] P2-6  Migration budget enforcement (round-robin trim) + host self-attr validation + test
- [ ] P2-16 AI trajectory bounce model uses the corner arcs
- [ ] Part1-P2 finisher lift cache, one-timer-ready bound, one-timer power model

Note: deleting `.godot/global_script_class_cache.cfg` + reimport was needed after
editing scripts — a stale cache was silently skipping ~68 test scripts (showed
1253 instead of the true 1321). Regenerated; keep an eye out after bulk edits.

## Batch 3 — Puck physics & geometry · verify: SOLO
- [ ] P2-1  Puck altitude clamp vs glass collision top (the escape) — raise collision ceiling
- [ ] P2-9  Height-aware out-of-bounds whistle
- [ ] P2-10 Clear `_pending_elevation_vel`/`_pending_elevation` in reset()/drop()
- [ ] P2-13 Stop classifying ice contacts as board hits
- [ ] P3    Wake sleeping puck in reset()
- [ ] P3    Goal-frame PhysicsMaterial (author trivial .tres) — decide dead-post vs bouncy

## Batch 4 — Goalie · verify: SOLO
- [ ] P0-2  Not-upright reaction-timer zeroing (scope the clear to its intent)
- [ ] Part1-P2 cross-crease clamp constant (net-center → far post)
- [ ] Part1-P2 goalie mechanism fixes (glove-reach range, etc. — non-wire)

## Batch 5 — Slot / reservation / lobby integrity · verify: 2P
- [ ] P2-5  `is_slot_reserved` check in try_swap_slot + _promote_spectator_to_player
- [ ] P2-8  Clear `_reserved_slots` on rematch (_apply_reset)
- [ ] P2-14 Promote liveness guard (peer still connected)
- [ ] P2-17 Online double-transition gate + disable confirm buttons before await
- [ ] Session-scoped field-reset sweep (`_peer_ping_ms`, lobby settings, `_in_replay_locally`, …)
- [ ] P3    `reset_game()` is_host guard

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
