class_name Achievements
## Single source of truth for Mitts' Steam achievements. Pure domain data — no
## engine or Steam API here; AchievementRules reads this to decide what's earned
## and AchievementService asks SteamManager to unlock by id.
##
## Every entry's `id` is the achievement's Steamworks "API Name" and MUST have a
## matching achievement defined + published in the Steamworks partner site, or
## the unlock silently does nothing. The human-readable `name`/`desc` here are
## for our own docs (steam/ACHIEVEMENTS.md is generated to mirror this); the
## strings shown to players come from Steamworks, not from this file.
##
## Adding an achievement (the "easy to change" path):
##   1. Add one row to ALL with a `cond` (see the kinds below).
##   2. Create the achievement in Steamworks under the same `id`, then publish.
##   3. Regenerate steam/ACHIEVEMENTS.md (see that file's header) so the backend
##      and code stay in lockstep.
## Most achievements need only step 1's row — no rule or service edits. Only a
## new *compound* condition (cond.kind == "special") needs a branch added to
## AchievementRules._special_met().
##
## Condition kinds (`cond.kind`):
##   "game"    — a single game's stat reached `min`. `field` is one of the keys
##               in AchievementRules.game_dict (goals/assists/points/shots_on_goal
##               /hits/shots_blocked). Evaluated at game-over, any mode.
##   "career"  — a lifetime total reached `min`. `field` is a career_totals column
##               (goals/assists/points/hits/shots_blocked/games_played/wins/...).
##               Evaluated at game-over in online shared-stats sessions only
##               (the totals live in Supabase).
##   "special" — a compound game-over condition keyed by `key`; AchievementRules
##               hard-codes the predicate. Evaluated alongside "game".
##   "event"   — fired live from a gameplay moment, not from the game-over sweep.
##               `key` names the moment and `min` (optional) is its threshold;
##               AchievementService's live hooks read it. Listed here so the id,
##               docs, and threshold all live in one place.
##   "roster"  — earned by playing a match whose roster includes `steam_id`, and
##               NOT by that steam_id themselves (a "play WITH person X" award).
##               Evaluated at game-over from the lobby members (any online mode).

# ── API Names (Steamworks "API Name") ────────────────────────────────────────
# Live-fired ids are referenced by these constants from AchievementService; the
# game-over ids are matched by data only, but we name them for symmetry + docs.
const FIRST_GOAL := "ACH_FIRST_GOAL"
const FIRST_STAR := "ACH_FIRST_STAR"
const HAT_TRICK := "ACH_HAT_TRICK"
const PLAYMAKER := "ACH_PLAYMAKER"
const BIG_NIGHT := "ACH_BIG_NIGHT"
const BRICK_WALL := "ACH_BRICK_WALL"
const SHUTOUT := "ACH_SHUTOUT"
const FREIGHT_TRAIN := "ACH_FREIGHT_TRAIN"
const FIRST_WIN := "ACH_FIRST_WIN"
const ONE_TIMER := "ACH_ONE_TIMER"
const TIP_IN := "ACH_TIP_IN"
const OVERTIME_HERO := "ACH_OVERTIME_HERO"
const FACEOFF_BOSS := "ACH_FACEOFF_BOSS"
const PICKPOCKET := "ACH_PICKPOCKET"
const PLAY_WITH_BUUKIE := "ACH_PLAY_WITH_BUUKIE"
const SNIPER := "ACH_SNIPER"
const SETUP_ARTIST := "ACH_SETUP_ARTIST"
const ENFORCER := "ACH_ENFORCER"
const VETERAN := "ACH_VETERAN"
# Meta-progression (outside a match — bypass the game-over sweep, fired directly
# from the tutorial / free-play build paths; see AchievementService).
const STUDENT := "ACH_STUDENT"
const CUSTOM_BUILD := "ACH_CUSTOM_BUILD"

# The SteamID64 the "play with" roster achievement is keyed to. Kept as a named
# constant so the one place it appears is self-documenting.
const BUUKIE_STEAM_ID := 76561198027551159

# The full registry. See the header for `cond` semantics.
const ALL: Array[Dictionary] = [
	# ── Single-game milestones (unlock in any mode at game-over) ─────────────
	{
		"id": HAT_TRICK, "name": "Hat Trick", "hidden": false,
		"desc": "Score 3 goals in a single game.",
		"cond": {"kind": "game", "field": "goals", "min": 3},
	},
	{
		"id": PLAYMAKER, "name": "Playmaker", "hidden": false,
		"desc": "Record 3 assists in a single game.",
		"cond": {"kind": "game", "field": "assists", "min": 3},
	},
	{
		"id": BIG_NIGHT, "name": "Stat Stuffer", "hidden": false,
		"desc": "Put up 5 points (goals + assists) in a single game.",
		"cond": {"kind": "game", "field": "points", "min": 5},
	},
	{
		# 3, not 5: shot-blocking is genuinely hard in Mitts (Ctrl crouch, a live
		# puck, no auto-block), so 5 in one game is a grind. 3 is a real "I threw
		# my body around tonight" bar without being punishing.
		"id": BRICK_WALL, "name": "Brick Wall", "hidden": false,
		"desc": "Block 3 shots in a single game.",
		"cond": {"kind": "game", "field": "shots_blocked", "min": 3},
	},
	{
		# Onboarding: pops the first game you score in, any mode (incl. vs bots) —
		# a single-game condition, not a career total, so a new player gets it in
		# their first session without needing an online match.
		"id": FIRST_GOAL, "name": "Lamp Lighter", "hidden": false,
		"desc": "Score your first goal.",
		"cond": {"kind": "game", "field": "goals", "min": 1},
	},
	{
		# Score off a one-timer — a shot released from the shooting zone without
		# ever possessing the puck (the wind-up-off-puck slapper). Host tags the
		# goal via ShotOnGoalTracker.pending_is_one_timer(); one_timer_goals is a
		# broadcast stat so a client scorer earns it too.
		"id": ONE_TIMER, "name": "Triggerman", "hidden": false,
		"desc": "Score off a one-timer.",
		"cond": {"kind": "game", "field": "one_timer_goals", "min": 1},
	},
	{
		# Redirect a teammate's shot into the net — a genuine tip-in (the scorer
		# was the last, deflecting toucher of an in-flight shot, not its shooter).
		# tip_goals is host-tagged in PhaseCoordinator and broadcast like above.
		"id": TIP_IN, "name": "Garbage Man", "hidden": false,
		"desc": "Tip a teammate's shot into the net.",
		"cond": {"kind": "game", "field": "tip_goals", "min": 1},
	},
	{
		# Score in sudden-death OT — always the game-winner. ot_goals is host-tagged
		# in PhaseCoordinator (goal while GameStateMachine.is_overtime()) and
		# broadcast like the counters above.
		"id": OVERTIME_HERO, "name": "Overtime Hero", "hidden": false,
		"desc": "Score the overtime winner.",
		"cond": {"kind": "game", "field": "ot_goals", "min": 1},
	},
	{
		# faceoff_wins is already a broadcast game stat — no plumbing, just a bar.
		"id": FACEOFF_BOSS, "name": "Master of the Dot", "hidden": false,
		"desc": "Win 5 faceoffs in a single game.",
		"cond": {"kind": "game", "field": "faceoff_wins", "min": 5},
	},
	{
		# takeaways is already a broadcast game stat — rewards defensive stickwork.
		"id": PICKPOCKET, "name": "Pickpocket", "hidden": false,
		"desc": "Record 5 takeaways in a single game.",
		"cond": {"kind": "game", "field": "takeaways", "min": 5},
	},
	# ── Compound game-over conditions ────────────────────────────────────────
	{
		"id": SHUTOUT, "name": "Lockdown", "hidden": false,
		"desc": "Win a game without conceding a goal.",
		"cond": {"kind": "special", "key": "shutout"},
	},
	{
		# Onboarding: pops your first win, any mode. Single-game (win the game),
		# not a career total.
		"id": FIRST_WIN, "name": "Winner", "hidden": false,
		"desc": "Win your first game.",
		"cond": {"kind": "special", "key": "win"},
	},
	{
		# Named the game's first star on the Three Stars podium. The podium is
		# computed deterministically on every machine (StarOfGameRules), so the
		# game-over sweep just receives "local player was stars[0]" via ctx.
		"id": FIRST_STAR, "name": "First Star", "hidden": false,
		"desc": "Be named the first star of the game.",
		"cond": {"kind": "special", "key": "first_star"},
	},
	# ── Live, in-the-moment events ───────────────────────────────────────────
	{
		"id": FREIGHT_TRAIN, "name": "Freight Train", "hidden": false,
		"desc": "Land a bone-rattling body check.",
		# `min` is the impact_force (weight x closing-speed) the body_checked_player
		# signal carries — the SAME value SkaterVFX scales feedback by, where 3.0 is
		# a glancing bump and 14.0 is a full-strength check (SkaterVFX._CHECK_FORCE_*).
		# 11.0 is intensity ~0.73: a clearly hard hit, reachable on a fast closing
		# check but not an everyday bump. Verify the feel in play and nudge if it
		# fires too freely / never (dev: SteamManager.reset_all_achievements).
		"cond": {"kind": "event", "key": "big_hit", "min": 11.0},
	},
	# ── Meta-progression events (fire OUTSIDE a match) ───────────────────────
	# These deliberately bypass the game-over sweep AND its free-play/drill gate
	# (_achievements_active) — they happen in tutorial / free-play, where that
	# gate is closed. AchievementService exposes a direct hook for each that
	# unlocks by event_id alone (no threshold — these have no `min`).
	{
		# Beat the whole tutorial course. Fired from the tutorial-completion path
		# once every TutorialRegistry.ALL_IDS entry is marked complete.
		"id": STUDENT, "name": "Student of the Game", "hidden": false,
		"desc": "Complete every tutorial.",
		"cond": {"kind": "event", "key": "tutorials_done"},
	},
	{
		# Customize your player. Fired the first time a free-play build edit is
		# applied (NetworkManager.local_attributes_changed).
		"id": CUSTOM_BUILD, "name": "Self-Made", "hidden": false,
		"desc": "Edit your player's build.",
		"cond": {"kind": "event", "key": "build_edited"},
	},
	# ── Roster (who you played with) ─────────────────────────────────────────
	{
		# Play an online game whose lobby includes Buukie. Can't be earned by
		# Buukie himself (see AchievementRules.earned_roster). Evaluated at
		# game-over from the Steam lobby members.
		"id": PLAY_WITH_BUUKIE, "name": "Buukie's Buddy", "hidden": true,
		"desc": "Play an online game with Buukie.",
		"cond": {"kind": "roster", "steam_id": BUUKIE_STEAM_ID},
	},
	# ── Career milestones (competitive games only — see game_manager gate) ────
	{
		"id": SNIPER, "name": "Sniper", "hidden": false,
		"desc": "Score 50 career goals.",
		"cond": {"kind": "career", "field": "goals", "min": 50},
	},
	{
		"id": SETUP_ARTIST, "name": "Setup Artist", "hidden": false,
		"desc": "Record 50 career assists.",
		"cond": {"kind": "career", "field": "assists", "min": 50},
	},
	{
		"id": ENFORCER, "name": "Enforcer", "hidden": false,
		"desc": "Land 100 career hits.",
		"cond": {"kind": "career", "field": "hits", "min": 100},
	},
	{
		"id": VETERAN, "name": "Veteran", "hidden": false,
		"desc": "Play 25 career games.",
		"cond": {"kind": "career", "field": "games_played", "min": 25},
	},
]


# The threshold for a `cond.kind == "event"` achievement, looked up by its
# `key`. Returns -1.0 if no such event achievement exists, so a missing/renamed
# entry fails closed (never unlocks) rather than firing on every occurrence.
static func event_threshold(key: String) -> float:
	for entry in ALL:
		var cond: Dictionary = entry["cond"]
		if cond.get("kind", "") == "event" and cond.get("key", "") == key:
			return float(cond.get("min", -1.0))
	return -1.0


# The id of a `cond.kind == "event"` achievement, looked up by its `key`.
# Returns "" when absent (caller skips the unlock).
static func event_id(key: String) -> String:
	for entry in ALL:
		var cond: Dictionary = entry["cond"]
		if cond.get("kind", "") == "event" and cond.get("key", "") == key:
			return String(entry["id"])
	return ""
