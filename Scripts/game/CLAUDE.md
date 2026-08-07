# Game layer — launch, session, and backend

Scope: `Scripts/game/` — boot paths, session lifecycle, and the Supabase
reporters. Networking invariants live in `Scripts/networking/CLAUDE.md`.

## Launch modes

All start paths go through `Boot.tscn` (title card): `boot.gd` threaded-loads `Hockey.tscn`, then drops the player into free play via `NetworkManager.start_free_play()` (a boot where the player has never touched the tutorial course routes into its first part via `start_tutorial()` instead — finishing or exiting any part counts as touched, so the course is seen once but never nagged; it's catalogued in `TutorialRegistry`, lives on in the **Tutorial** menu (drills are a separate **Drills** menu, catalogued in `DrillRegistry`), and `PlayerPrefs.TUTORIAL_COURSE_VERSION` wipes saved completion when the course is restructured so everyone passes the gate again). From there the HUD's `SideMenu` drives session changes through one **Play** popup — Start Game runs `start_offline()` and enters the unified lobby (instant, no Steam needed), and the open-games browser joins via `start_client_lobby(lobby_id)`. `NetworkManager._ready()` does nothing. **Hosting is a lobby-phase state, not a menu path**: the lobby's host-only visibility selector (Offline / Friends / Public) attaches the Steam transport via `NetworkManager.attach_online(public)` — safe because it only runs with zero peers, and the offline session already runs the full host simulation (the `is_offline_mode` gates only stop broadcast/ping/upload) — and `detach_online()` returns to Offline (locked out while human peers are connected; the host kicks via the slot grid first). Friends ↔ Public is a live `SteamManager.set_lobby_visibility` (`Steam.setLobbyType`) flip. A match's online-ness is fixed at puck drop. **Backend career uploads are NOT gated on it** — every real match (offline vs bots included) posts a `career_stats` row, gated only on `_achievements_active()` (not free play / tutorial / drills), `PlayerPrefs.share_gameplay_stats`, and a signed-in Steam identity; the session type rides along as data (`is_online`, plus `human_players` — the peak human headcount, a count rather than a "ranked" flag since Mitts has no ranked mode) so a human-only filter stays possible later without having discarded offline play. Network-quality rows (`network_sessions`) remain online-only — an offline match has no link to measure. Online transport is **Steam P2P via `SteamMultiplayerPeer`** (GodotSteam GDExtension), a drop-in `MultiplayerPeer`, so all RPCs/prediction/reconcile/lag-comp are transport-agnostic and unchanged. Unlike ENet's instant `create_server`/`create_client`, Steam lobby create/join are **async**: `attach_online()` waits for `SteamManager.lobby_created` then emits `host_lobby_ready` (the visibility selector shows a busy state until it lands); `start_client_lobby()` waits for `lobby_joined`, reads the lobby owner's Steam ID, then the normal `connected_to_server` handshake runs unchanged. `Hockey.tscn`'s root node runs `game_scene.gd`, whose `_ready()` calls `NetworkManager.on_game_scene_ready()`, which emits `host_ready` on hosts; `GameManager` listens and calls `on_host_started`. Client world spawn is triggered by the `client_connected` signal from `_on_connected_to_server()`.

NetworkManager → GameManager communication is signal-based: every RPC / ENet callback emits a typed signal, and GameManager wires all connections once in `_ready()` via `_wire_network_signals()`. The only downward data flow is `NetworkManager.set_world_state_provider(Callable)`.

## Distribution

Playtester builds ship via GitHub Releases (`latest` tag). `deploy.yml` computes `VERSION=0.1.<git rev-list --count HEAD>`, rewrites the placeholder `"dev"` in `Scripts/game/build_info.gd` to that string before export, and publishes with the version as the release name (plus an immutable `v0.1.N` prerelease per build for rollback). Steam (SteamPipe) handles distribution and auto-updates for the closed beta (`steam/` holds the upload scripts), so there is no in-game update notifier, patcher, or downloader.

**Supabase backend:** `Scripts/game/supabase_config.gd` holds the project URL and publishable (anon) key — safe to commit, RLS restricts it to INSERT/SELECT (there is deliberately no UPDATE grant — the key ships in every client). `CareerStatsReporter` (`Scripts/game/career_stats_reporter.gd`) POSTs one row to `career_stats` at game-over and GETs from the `career_totals` view for the career screen. `BugReporter` (`Scripts/game/bug_reporter.gd`) POSTs to `bug_reports` with a telemetry snapshot. `NetworkSessionReporter` (`Scripts/game/network_session_reporter.gd`) POSTs one connection-quality row per online game to `network_sessions` at game-over — the playtesting telemetry pipeline (see `ARCHITECTURE.md` → **Playtesting telemetry**; schema + analysis views in `supabase/migrations/*_network_sessions.sql`). All use fire-and-forget `HTTPRequest` nodes added to the scene tree root and fail silently. The secret key must never be committed — use only the publishable key in `SupabaseConfig`. **Table/view/RPC schemas are version-controlled as migrations in `supabase/migrations/`**, applied to the hosted project by `.github/workflows/supabase.yml` on merge to `main` — a schema change ships with the code that needs it rather than being pasted into the SQL editor. Migrations are idempotent DDL and CI pins that (it replays them onto a populated DB); every view needs `with (security_invoker = true)` or it bypasses RLS. `supabase/README.md` is the full workflow, including the one repo secret the pipeline stays inert without. All backend rows key on `steam_id` — there is no per-player `uuid` (`game_id` is still a UUID, minted by `PlayerPrefs.generate_uuid`).

## Lag-compensated claim resolvers

`PickupClaimResolver`, `PokeClaimResolver`, `StickLiftClaimResolver` and
`HitClaimResolver` are host-only resolvers for client-initiated claims. Each
documents its own geometry and reject list in its header; this is the contract
they all share. **A new claim resolver must follow all of it.**

- **Bound the client's self-reported `interp_delay_ms` against the measured link
  before any rewind or forward-predict reads it**
  (`LagCompRewind.plausible_interp_delay_ms`). It is an anti-cheat bound, not a
  sanity check — an unbounded delay lets a modified client pick its own rewind
  depth.
- **Rewind the two sides to different instants.** The claimant's own body goes to
  `LagCompRewind.self_view_time(host_ts)`; anything they were *watching* goes to
  `remote_view_time(host_ts, interp_delay)`. Never reach into raw timestamps —
  go through `LagCompRewind`.
- **The self-view instant is usually PAST the buffer — catch it up.** The host
  holds a client's input until its stamp comes due, so at claim arrival the
  newest capture sits at `host_ts + one_way` while `self_view_time` asks for
  `host_ts + lead`. Whenever the lead exceeds the one-way trip — every link under
  roughly twice the lead, i.e. most of them, and the *cleaner* the link the worse
  it gets — `StateBufferManager.get_state_at` answers with the newest sample and
  no signal at all (`_find_bracket`'s `ts >= newest` branch). Add
  `LagCompRewind.self_view_catch_up(...)` to every body-anchored quantity read
  from that snapshot (position, `blade_contact_world`, `top_hand_world` — the
  blade rides the body, so it rigid-translates with it). Skipping it rewinds the
  claimant's own body short and drags the reach/continuity clamps back onto a
  stale body, which eats honest full-extension claims; measured at the lead
  servo's 50 ms cap on a 20 ms link, that was ~0.59 m against a 0.7 m contact
  diameter. It self-disables once one-way exceeds the lead.
- **Reach-clamp the client-sent blade to the rewound body — never `rtt/2`.** The
  blade is client-authoritative aim, so the clamp is what bounds it. The host
  independently reconstructs the blade from replicated inputs; the clamp is the
  second, tighter bound on top of that.
- **Apply idempotently.** A concurrent host-side detection may already have
  resolved the same event, so re-check the carrier on the apply path or the
  effect lands twice.
- **Reject early and completely**: puck locked, no carrier, carrier changed since
  the claim, claim staler than `MAX_CLAIM_AGE_S`, skater missing or ghosted, or
  the claim targets self or a teammate.

There is no contest window on poke / stick-lift / hit — first valid claim wins,
and simultaneous claims are arbitrated by RPC arrival order (the loser sees
`carrier == null` and skips). Contested *pickups* are the exception and resolve
through `PuckCollisionRules.contested_pickup_velocity` instead.

Full rewind and prediction rules: `Scripts/networking/CLAUDE.md`.
