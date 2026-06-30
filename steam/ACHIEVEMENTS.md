# Steam achievements

Mitts' achievements are **code-driven from a single registry**:
`Scripts/domain/config/achievements.gd`. Each entry's `id` is the Steamworks
**API Name**; `AchievementRules` decides what's earned (pure, unit-tested) and
`AchievementService` (owned by `GameManager`) asks `SteamManager` to unlock it.

This file is the bridge to the part the code **can't** do: the achievement
definitions live in the Steamworks partner site, one per `id` below. Keep this
list in sync with the registry (`Achievements.ALL`) — if an `id` here has no
matching, *published* achievement in Steamworks, its unlock silently no-ops.

> **Two apps.** Achievements are configured per-app. The closed beta runs under
> the **Playtest** child app **4893650** as well as the main app **4892600**
> (see README → "Playtest app"). To see unlocks during the live playtest, define
> the achievements on **4893650** too — same API Names, same icons.

---

## One-time setup (Steamworks website — can't be scripted)

For each app (4892600 and, for the playtest, 4893650):

1. **Stats & Achievements → Achievements**: create one achievement per `id`
   below. Set its display **name** and **description** (these come from
   Steamworks, *not* from the registry — the names/desc here are just our notes).
2. Upload a **locked** and **unlocked** icon for each (Steamworks requires both;
   64×64 PNG). Placeholder art is fine for the beta.
3. Leave **"Hidden"** off unless the row below says hidden (none are, currently).
4. **Publish** the changes (Stats & Achievements changes need an explicit
   publish, like Store/build changes).

The **game / special / event** achievements unlock directly from code. The
**career** ones read Steam User Stats, which you must also define — see STATS.md
for that checklist.

---

## The achievements

`when` = how it's evaluated (see the registry header for the `cond` kinds):
- **game** — a single game's stat reached the bar (any mode, incl. vs bots).
- **special** — a compound game-over condition.
- **event** — fired live, the moment it happens, during a match.
- **career** — a lifetime total backed by **Steam User Stats** (online games
  only, so they can't be padded vs bots; NOT gated on stat-sharing, and no
  Supabase dependency). The mirrored stats must be defined too — see STATS.md.

| API Name (`id`)     | Name         | When    | Unlocks when…                                  |
|---------------------|--------------|---------|------------------------------------------------|
| `ACH_HAT_TRICK`     | Hat Trick    | game    | 3 goals in a single game                       |
| `ACH_PLAYMAKER`     | Playmaker    | game    | 3 assists in a single game                     |
| `ACH_BIG_NIGHT`     | Big Night    | game    | 5 points (G+A) in a single game                |
| `ACH_BRICK_WALL`    | Brick Wall   | game    | 5 blocked shots in a single game               |
| `ACH_SHUTOUT`       | Shutout      | special | win a game conceding 0 goals                   |
| `ACH_FREIGHT_TRAIN` | Freight Train| event   | land a body check above the big-hit threshold  |
| `ACH_FIRST_GOAL`    | Lamp Lighter | career  | 1st career goal                                |
| `ACH_FIRST_WIN`     | W            | career  | 1st career win                                 |
| `ACH_SNIPER`        | Sniper       | career  | 50 career goals                                |
| `ACH_SETUP_ARTIST`  | Setup Artist | career  | 50 career assists                              |
| `ACH_ENFORCER`      | Enforcer     | career  | 100 career hits                                |
| `ACH_VETERAN`       | Veteran      | career  | 25 career games                                |

---

## Adding / changing an achievement

1. Add (or edit) a row in `Achievements.ALL` — pick the `cond` kind. A typical
   threshold needs *only* this; a new compound condition also needs a branch in
   `AchievementRules._special_met()`.
2. Create the achievement in Steamworks under the same `id` (both apps) and
   publish.
3. Add the row to the table above so this doc stays the source of truth for the
   backend side.
4. Run the rule tests: `bash .claude/hooks/run-gut.sh -gdir=res://tests/unit/rules`.

Changing a threshold is a one-line edit to a row's `min` — no Steamworks change
needed (the bar is enforced in code).

## Testing on a dev machine

Unlocks only fire when Steam is running and the achievement is **published** for
the app you launched under. In a debug build, `SteamManager.reset_all_achievements()`
clears every registered achievement (and stats) so you can re-earn them — it's a
no-op in release.
