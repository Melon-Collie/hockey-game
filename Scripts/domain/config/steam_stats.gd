class_name SteamStats
## Registry of the Steam User Stats Mitts mirrors — per-user career counters
## stored on Steam's servers (cross-machine, no backend, work offline). Pure
## domain data; SteamStatRecorder does the read-modify-write via SteamManager.
##
## Why mirror at all when career_stats already lives in Supabase: Steam Stats
## back the career-threshold achievements (Achievements.ALL with cond.kind ==
## "career") WITHOUT depending on a reachable Supabase — so those achievements
## keep working stat-sharing-opted-out / while the backend is paused. Counted for
## the same games as the Supabase career row (see the gate in GameManager
## _on_game_over). Supabase stays the source for cross-machine history + dev
## telemetry; Steam Stats are the progression counter.
##
## Each entry's `id` is the Steamworks "API Name" of an INT stat that MUST be
## defined + published for the app (both 4892600 and the 4893650 Playtest), or
## get/set silently no-op. See steam/STATS.md.
##
## Adding a counter: add a row here (`id`, the career-totals `key` it maps to,
## and how a finished game increments it via `inc`). If a new career achievement
## targets it, that's the same `key` AchievementRules reads — see the consistency
## test in tests/unit/game/test_steam_stat_recorder.gd, which fails if a career
## achievement references a field no stat backs.
##
## `inc.kind`:
##   "stat" — add a per-game PlayerStats field (`inc.field`, an AchievementRules
##            .game_dict key) to the running total.
##   "win"  — add 1 when the game's outcome is a win.
##   "game" — add 1 for every game (games played).

# API Names (Steamworks INT stat "API Name").
const GOALS := "STAT_GOALS"
const ASSISTS := "STAT_ASSISTS"
const SHOTS := "STAT_SHOTS_ON_GOAL"
const HITS := "STAT_HITS"
const BLOCKS := "STAT_SHOTS_BLOCKED"
const WINS := "STAT_WINS"
const GAMES := "STAT_GAMES_PLAYED"

# `key` is the career-totals column name these map to — the SAME names
# AchievementRules.earned_career reads, so a "career" achievement on `goals`
# is backed by the stat whose key is "goals".
const ALL: Array[Dictionary] = [
	{"id": GOALS, "key": "goals", "inc": {"kind": "stat", "field": "goals"}},
	{"id": ASSISTS, "key": "assists", "inc": {"kind": "stat", "field": "assists"}},
	{"id": SHOTS, "key": "shots_on_goal", "inc": {"kind": "stat", "field": "shots_on_goal"}},
	{"id": HITS, "key": "hits", "inc": {"kind": "stat", "field": "hits"}},
	{"id": BLOCKS, "key": "shots_blocked", "inc": {"kind": "stat", "field": "shots_blocked"}},
	{"id": WINS, "key": "wins", "inc": {"kind": "win"}},
	{"id": GAMES, "key": "games_played", "inc": {"kind": "game"}},
]
