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
- **event** — fired live the moment it happens (a big hit mid-match), or from a
  meta-progression moment outside a match (finishing the tutorial course,
  editing your build) — those bypass the game-over sweep and its mode gate.
- **roster** — earned by playing an online game whose lobby includes a specific
  person, and never by that person themselves.
- **career** — a lifetime total backed by **Steam User Stats** (online games;
  NOT gated on stat-sharing, and no Supabase dependency). The mirrored stats must
  be defined too — see STATS.md.

> **2026-07 rename pass.** Achievement names double as unlockable player titles
> (a title describes the *player*, not the event), so several were renamed:
> Big Night → **Stat Stuffer**, One-Timer → **Triggerman**, Redirect →
> **Garbage Man**, Shutout → **Lockdown**, W → **Winner**, Make It Yours →
> **Self-Made** — and **First Star** (`ACH_FIRST_STAR`) is new. API Names are
> unchanged (existing unlocks survive); update the **display names** in
> Steamworks on both apps and republish, and create `ACH_FIRST_STAR` fresh.

| API Name (`id`)     | Name              | When    | Unlocks when…                                  |
|---------------------|-------------------|---------|------------------------------------------------|
| `ACH_HAT_TRICK`     | Hat Trick         | game    | 3 goals in a single game                       |
| `ACH_PLAYMAKER`     | Playmaker         | game    | 3 assists in a single game                     |
| `ACH_BIG_NIGHT`     | Stat Stuffer      | game    | 5 points (G+A) in a single game                |
| `ACH_BRICK_WALL`    | Brick Wall        | game    | 3 blocked shots in a single game               |
| `ACH_FIRST_GOAL`    | Lamp Lighter      | game    | score your first goal (any mode)               |
| `ACH_ONE_TIMER`     | Triggerman        | game    | score off a one-timer                          |
| `ACH_TIP_IN`        | Garbage Man       | game    | tip a teammate's shot into the net             |
| `ACH_OVERTIME_HERO` | Overtime Hero     | game    | score the overtime winner                      |
| `ACH_FACEOFF_BOSS`  | Master of the Dot | game    | win 5 faceoffs in a single game                |
| `ACH_PICKPOCKET`    | Pickpocket        | game    | 5 takeaways in a single game                   |
| `ACH_SHUTOUT`       | Lockdown          | special | win a game conceding 0 goals                   |
| `ACH_FIRST_WIN`     | Winner            | special | win your first game (any mode)                 |
| `ACH_FIRST_STAR`    | First Star        | special | be named the game's first star                 |
| `ACH_FREIGHT_TRAIN` | Freight Train     | event   | land a body check above the big-hit threshold  |
| `ACH_STUDENT`       | Student of the Game| event  | complete every tutorial                        |
| `ACH_CUSTOM_BUILD`  | Self-Made         | event   | edit your player's build                       |
| `ACH_PLAY_WITH_BUUKIE` | Buukie's Buddy | roster  | play an online game with Buukie (hidden)       |
| `ACH_SNIPER`        | Sniper            | career  | 50 career goals                                |
| `ACH_SETUP_ARTIST`  | Setup Artist      | career  | 50 career assists                              |
| `ACH_ENFORCER`      | Enforcer          | career  | 100 career hits                                |
| `ACH_VETERAN`       | Veteran           | career  | 25 career games                                |

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
