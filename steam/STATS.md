# Steam stats

Mitts mirrors a handful of career counters into **Steam User Stats** — per-user
integers stored on Steam's servers, synced across the player's machines, with no
backend of ours involved. Registry: `Scripts/domain/config/steam_stats.gd`;
read-modify-write: `Scripts/game/steam_stat_recorder.gd`.

**Why they exist:** they back the *career-threshold achievements* (`ACH_SNIPER`,
`ACH_ENFORCER`, …) without depending on a reachable Supabase. Achievements stay
earnable offline / opted-out / while the backend is paused. Supabase remains the
source for cross-machine history and dev telemetry; these stats are purely the
progression counter (and the future basis for leaderboards).

When they update: at game-over for **online games** (same games as the Supabase
career row). They are **not** gated on the "Share Gameplay Stats" toggle — that
toggle is about uploading to *our* Supabase; Steam Stats are the player's own
data on their own Steam account.

> **Two apps.** Like achievements, stats are per-app. Define these on the main
> app **4892600** and the **Playtest** child app **4893650** (same API Names),
> or career achievements won't progress for testers on the Playtest build.

---

## One-time setup (Steamworks website — can't be scripted)

For each app: **Stats & Achievements → Stats**, create each stat below as type
**Integer (INT)**, default `0`, with **Increment Only** off (we write absolute
values via read-modify-write, not increments) — then **publish**.

| API Name (`id`)        | Type | Tracks (lifetime, online games) |
|------------------------|------|---------------------------------|
| `STAT_GOALS`           | INT  | goals scored                    |
| `STAT_ASSISTS`         | INT  | assists                         |
| `STAT_SHOTS_ON_GOAL`   | INT  | shots on goal                   |
| `STAT_HITS`            | INT  | body checks landed              |
| `STAT_SHOTS_BLOCKED`   | INT  | shots blocked                   |
| `STAT_WINS`            | INT  | games won                       |
| `STAT_GAMES_PLAYED`    | INT  | games played                    |

These names must match `SteamStats.ALL` exactly. The GUT test
`test_every_career_achievement_has_a_backing_stat` fails the build if a career
achievement ever targets a field with no stat here, so the two registries can't
silently drift.

---

## Adding a stat

1. Add a row to `SteamStats.ALL` (`id`, the career-totals `key` it maps to, and
   how a game increments it via `inc`).
2. Create the matching INT stat in Steamworks (both apps) and publish.
3. Add the row to the table above.

A new career achievement on that counter is then just a `cond: {kind: "career",
field: <key>, min: N}` row in `Achievements.ALL` — no code.

## Testing on a dev machine

Stats only persist when Steam is running and the stat is published for the app
you launched under. In a debug build, `SteamManager.reset_all_achievements()`
zeroes every mirrored stat (and clears achievements) so you can re-earn from
scratch; it's a no-op in release.
