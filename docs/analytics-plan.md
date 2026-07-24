# Hockey Analytics — Corsi / Fenwick / xG for Mitts

Design plan for a real hockey-analytics layer: shot-attempt differential
(Corsi/Fenwick), on-ice percentages (PDO), and a **true-geometry expected-goals
(xG)** model — the differentiator. The pitch is that Mitts can be the first
hockey game to surface genuine advanced stats, and that it can compute xG *from
ground truth* (the real goalie position, open angle, screen state, shot type)
rather than the sparse-tracking regression every public NHL xG model is forced
to use.

Designed in chat 2026-07-23; this document is the agreed plan per the CLAUDE.md
workflow — implementation sessions should treat it as the design of record and
ask before deviating. Numbers marked `TBD` are authored at implementation time
and tuned/calibrated against logged data (see §3.3).

Status: **A1 IMPLEMENTED** (2026-07-24). Per-player Corsi/Fenwick counters
(`shot_attempts`, `shot_attempts_blocked` on `PlayerStats`) via a new host-only
`AdvancedStatsTracker`; broadcast (protocol v41, `STATS_PLAYER_RECORD_SIZE`
15→17); persisted to `career_stats` with report-time team-SOG columns for PDO;
`career_totals` derives lifetime iCF / Fenwick / PDO; Career screen shows all
three.

**Shot-vs-pass classification (the crux — a shot attempt is not a release).**
Counting a Corsi attempt on every release over-counts badly: a quick pass, a
wrister used as a pass, a backdoor feed, and a saucer to the slot are all
releases but none are shots. Two facts can't distinguish them at release: the
input type is discarded before the release signal (quick-pass and wrister collapse
to the same `puck_release_requested`, `is_slapper=false`), and a backdoor feed is
geometrically aimed at the goal mouth. So the count moved to shot **resolution**,
where `ShotOnGoalTracker` applies the real Corsi definition — a puck **directed at
the net** that resolves as **on-goal, missed, or blocked**:
- **On-goal** (SOG/goal, `_confirm`) and **blocked** (`on_block`) already require
  `_pending_on_net`, so passes (off-net) can't reach them. On-goal → Corsi+Fenwick;
  blocked → Corsi only.
- **Missed** (`_resolve_pending_miss`, on timeout / non-teammate pickup) requires
  the release to have been **directed at the net** (`ShotOnNetRules.is_directed_at_net`,
  the wider Corsi mouth: 1.2 m lateral / 0.8 m vertical margin) AND **not received
  by a different teammate** (a backdoor feed / saucer the target collects is a
  pass). The shooter recovering their own wide shot still counts.
- One host-authoritative signal, `shot_counted(peer_id, blocked)`, feeds the
  counter; attribution is the last attacking toucher (tipper on a tip).

Accepted v1 edges (documented, minor): a hard backdoor feed a defender blocks
in the lane reads as a blocked shot (real trackers score it that way too); a shot
that misses by more than the 1.2 m margin isn't counted. The margins are hand-set
*reporting* thresholds, tunable in playtest. **A2 (xG) and B (event log) are NOT
STARTED** — but the directed-at-net gate is exactly A2's "is this a shot?" seam.

---

## 1. What we already have

The foundation is unusually complete for a game that hasn't tried to ship
analytics. Two assets do most of the work:

**The boxscore + persistence rails.** `PlayerStats` already carries goals,
assists, SOG, hits/hits-taken, takeaways, giveaways, blocks, faceoff W/L, TOI,
and goal-flavor tags (one-timer / tip / OT / GWG), all host-authoritative and
broadcast. `career_stats` persists them to Supabase, `career_totals` aggregates
lifetime + per-60 rates, `recent_games_for()` returns per-game history. Adding a
counter is a well-worn recipe (CLAUDE.md → *Where New Code Goes* → "New per-player
stat").

**The shot-event pipeline.** `ShotOnGoalTracker` is already a shot state machine
with exactly the events the advanced stats need, host-authoritative and
unit-tested:

| Event | Signal / hook | Advanced-stat use |
|---|---|---|
| Every release | `shot_attempted(peer_id)` | Corsi attempt |
| On-net read | `note_trajectory(on_net)` (`ShotOnNetRules`) | on-net vs. missed split |
| Miss / post | `on_post_hit()` → `_pending_on_net = false` | Corsi-yes, Fenwick-yes, SOG-no |
| Blocked | `on_block(blocker)` → `shots_blocked` | Corsi-yes, Fenwick-**no** |
| Saved (SOG) | `on_goalie_touch` → `shot_on_goal_recorded(peer_id)` | Corsi/Fenwick/SOG-yes |
| Goal | `on_goal_confirmed(scorer)` | outcome for xG calibration |
| Deflection | `on_deflection(peer_id)` | tip attribution |

Plus `PossessionTracker.possession_established(peer_id, team_id)` /
`get_controlling_team()` for zone-time and possession%, and
`AIActionScoring.open_net_danger(...)` — a physically grounded shot-danger
surface (§3).

Two structural simplifications fall out of Mitts' design and make the hard parts
of real-world advanced stats *disappear*:

- **No line changes.** Everyone is always on the ice, so on-ice Corsi *is* team
  Corsi — we skip WOWY / on-ice attribution entirely and still get honest
  individual attempt counts (iCF).
- **No penalties.** The whole game is even-strength, which is exactly the context
  Corsi/xG are defined for. There is no strength-state to filter on.

---

## 2. The stat catalogue

Adapted to Mitts. Team-level unless noted; individual attribution is available
for every attempt because the shooter is known at every event.

### 2.1 Corsi (shot-attempt differential)
- **CF / CA** = shot attempts for/against = SOG + missed (incl. posts) + blocked.
- **CF%** = CF / (CF + CA).
- **iCF** = individual attempts a player took.
- Every input event already fires (§1 table). Pure counters.

### 2.2 Fenwick (unblocked-attempt differential)
- **FF / FA** = Corsi minus blocked shots (unblocked attempts).
- **FF%** = FF / (FF + FA).
- Fenwick is the correct base for xG: public xG is computed on unblocked
  attempts, so the block term stays *out* of xG and lives in the Corsi story.

### 2.3 PDO (percentage sum — the "luck"/variance indicator)
- **PDO** = on-ice shooting% + on-ice save%, ×1000 by convention.
- Shooting% = goals-for / SOG-for; save% = 1 − goals-against / SOG-against.
- Fully derivable from goals + SOG we already store. No new event.
- Caveat: save% here reflects the AI goalie, so team PDO is more a variance/finish
  indicator than a goaltending metric (§9).

### 2.4 Expected Goals (xG) — the differentiator (see §3)
- **xGF / xGA** — summed shot quality for/against.
- **xGF%** = xGF / (xGF + xGA).
- **G−xG** (individual) — goals above expected = a real **finishing-skill** stat.
- **xG per shot** — average chance quality.

### 2.5 Scoring chances / high-danger (derived from xG)
- **SCF / HDCF** — attempts whose xG clears a chance / high-danger threshold
  (`TBD`, tuned against the danger distribution in logged data). Trivial once xG
  exists; no new perception.

### 2.6 Zone time / possession%
- **Possession%** = share of live-play time your team held established possession
  (`PossessionTracker.get_controlling_team()`, time-weighted).
- **O-zone time%** = share of live-play time the puck sat in the attacking zone
  (puck-Z vs. the existing blue-line geometry).
- Moderate cost: one host-side accumulator ticked in `GameManager`.

---

## 3. The xG model

### 3.1 Why not just reuse `open_net_danger`

`open_net_danger` is documented as **xG-SHAPED but NOT magnitude-calibrated**
(`action_scoring.gd` design block: "treat the outputs as RELATIVE shot quality,
not actual goal probability"). It returns

```
best_open_angle / (2 × aim_spread)     clamped to [0, 1]
```

i.e. "what fraction of my aim cone is open net past the goalie's reaction-gated
reach." The *shape* is right and already goalie-aware from true geometry — which
is better than any public xG model, none of which can see the goalie. But three
things separate this decision score from a calibrated goal probability:

1. **Magnitude / top-of-curve.** A wide-open look returns ~1.0, but real finish
   rate on a wide-open look is not 100% (fans, misses, iron). A calibrated model
   compresses the top and smooths the mid-band so values *sum* to real goals.
2. **The normalization is a bot knob.** `2 × aim_spread` (and
   `MIN_RELEASE_SPREAD_RAD`) are bot-decision tuning. A *stat* cannot wobble every
   time bot difficulty is retuned — career xG must be decoupled from those knobs.
3. **Two features real xG weights that `open_net_danger` only expresses
   implicitly.** Shot **type** (one-timer / tip up-weight — we already carry the
   flags) and **rush/rebound recency**. Note: the goalie already models the
   rush/rebound/royal-road effect *physically* (`goalie_unsettled_factor`,
   `goalie_down`, caught-moving, lateral-accel lag), so xG may need the explicit
   recency feature *less* than a regression does — measure before adding (§3.3).

Conclusion: **neither a rewrite nor a blind reuse.** Build a thin calibration
head over the geometry we already trust.

### 3.2 `expected_goals()` — a sibling to `open_net_danger`

A new pure function in `action_scoring.gd` (or a dedicated `xg_rules.gd` in
`domain/rules/` if it grows), sharing the exact hole geometry:

1. **Reuse the hole model.** Compute the same best-open-angle over the five
   reaction-gated goalie holes — do **not** re-derive the physics. Pass the
   *actual* release geometry (real goalie position, screen distance, five-hole,
   post-seal state), not an anticipated one.
2. **Own normalization → calibrated probability.** Replace the bot-aim `2 ×
   aim_spread` denominator with a logistic squashing on openness whose parameters
   are fit against observed goal rates (§3.3). This is the "calibration head"; it
   owns its own constants so the stat and the bot never drift together.
3. **Shot-type multiplier** from flags we already have (`pending_is_one_timer`,
   tip via last-toucher ≠ shooter). `TBD` multipliers, calibrated.
4. **(Optional, evidence-gated) recency term** — seconds since the last shot / a
   cross-crease pass. Only add if §3.3 residuals demand it after the goalie's
   physical rush/rebound modeling is accounted for.

Base is the **goalie-beating openness** (the `open_net_danger` core), *not* full
`score_shoot` — the lane-clear/block term belongs in the Corsi suppression story,
matching public xG's unblocked-attempt convention (§2.2).

xG is computed at **release, host-authoritative**, for **every** shot — human and
bot alike (humans never call the AI scorer, so this is the only path that gives
their shots a value). It is broadcast/persisted like any other counter (§4–5).

### 3.3 Calibration loop — and how we answer "how different is it really?"

The divergence between `open_net_danger` and a fitted xG is **measurable, not a
guess.** Once shots are logged with (a) the geometry-openness at release and (b)
the actual outcome, a **reliability plot** (predicted-danger bucket vs. observed
goal rate per bucket) tells us exactly:

- Expected finding: **shape holds tight** (high rank correlation / AUC), magnitude
  is **off by a compressive curve at the top**, residuals point at 1–2 features
  (shot type first, then maybe rebound recency).
- The logistic in §3.2-step-2 is fit to that plot; the multipliers in step 3 are
  fit to the residuals.

The reliability plot is itself the first analytics artifact worth shipping (a dev
tool at minimum) — it validates that the model is honest before any number reaches
a player. This is the calibration workflow; treat "reuse vs. fresh" as answered
empirically by it.

### 3.4 Grounded-model compliance

xG is an *evaluation* number, so it lives under CLAUDE.md's "grounded models over
magic-number curves" doctrine — every term must be a physical measurement (open
angle, goalie reach, screen distance, shot type), and the logistic is *fit to
data*, not shaped to feel right. The one hand-set piece — the chance / high-danger
thresholds (§2.5) — is a legitimate feel/reporting knob, not an evaluator term.

---

## 4. Architecture

Two data shapes, and the fork that actually matters:

### 4.1 Counters (Phase A) — rides existing rails
Corsi, Fenwick, PDO, xGF/xGA, SCF/HDCF, zone/possession time all fit the existing
**scalar-counter** model: accumulate per player, broadcast every stats packet, sum
in Supabase. Deterministic, network-safe, low-risk. Follows the "new per-player
stat" recipe verbatim. xGF/xGA are `float` accumulators (the wire already carries
floats; confirm `WorldStateCodec` encoding for the new fields).

New host-only collaborator: **`AdvancedStatsTracker`** (RefCounted, sibling to
`ShotOnGoalTracker` / `HitTracker` / `PossessionTracker`, constructed and fed only
on the host). It subscribes to the signals in the §1 table — `shot_attempted`,
`on_block`, `on_post_hit`, `shot_on_goal_recorded`, `on_goal_confirmed`,
`possession_established` — computes xG at release, and writes CF/FF/xG counters
onto `PlayerStats` (+ team counters on `GameStateMachine`, alongside `team_shots`).
No new perception, no reach into nodes — pure extension point.

### 4.2 Event log (Phase B) — the shot map
Heatmaps, shot maps, "xG vs. actual goals," per-shot history need **one row per
shot**: `(x, z, xG, shot_type, on_net, blocked, outcome, shooter, team, period,
game_id)`. That is a new Supabase table (`shot_events`) and a new data shape, not
more boxscore columns. The `AdvancedStatsTracker` already sees every shot at
release, so it is also the natural producer of these rows (buffer per game,
fire-and-forget POST at game-over like `CareerStatsReporter`).

---

## 5. Networking & determinism

Per CLAUDE.md networking invariants:

- xG is **host-authoritative**, computed once at the authoritative release from
  the host's world state, and **broadcast** as a counter — never computed
  divergently client-side.
- New `PlayerStats` fields are appended to `to_array()` (wire order is
  append-only) and `to_dict()`; `STATS_PLAYER_RECORD_SIZE` grows and
  `PROTOCOL_VERSION` bumps. TOI's local-only exception (preserved across decode)
  does not apply — these are host-authoritative like the other counters.
- Counters survive reconcile trivially (they are not per-tick sim state); no
  snapshot/replay concerns. The xG *computation* reads goalie/geometry state that
  already exists at release time.
- `AdvancedStatsTracker` is host-only, like the other stat trackers — clients
  receive the results through the normal stats broadcast.

---

## 6. Supabase schema

Phase A — extend `career_stats` (new file section in `sql/career_stats.sql`,
`ALTER TABLE ... ADD COLUMN IF NOT EXISTS` migration, matching the existing
pattern):

- `corsi_for`, `corsi_against`, `fenwick_for`, `fenwick_against` (integer)
- `xg_for`, `xg_against` (numeric) — and `goals` already present gives G−xG in the
  view
- add each to `career_totals` (appended at the END of the view — the doc in the
  SQL file explains why), add per-60 forms (xGF/60), add to `PlayerStats.to_dict()`
  and a row in `CareerStatsScreen._on_totals_received`
- extend `career_stats_sane_ranges` with generous bounds for the new columns

Phase B — new `sql/shot_events.sql` (table + RLS anon-insert/select mirroring
`career_stats`, + an aggregation view for the heatmap grid). Keyed on `game_id` +
`steam_id`, same as everything else.

---

## 7. UI surfaces

- **Live scoreboard** — add CF% / xGF% (and maybe a live xG readout) to the
  existing team stat row. xG shines *live* as a "the run of play says X" readout.
- **Career screen** — new advanced-stats columns/tab (CF%, FF%, PDO, xGF/60,
  G−xG), plus the **individual-player career heatmap** (§7.2). Aggregate is where
  these stats are meaningful (§9).
- **Post-game analytics screen (Phase B)** — the three views in §7.1. The
  marketing beat.
- All new strings go through `locale/translations.csv` per the i18n recipe.

### 7.1 Post-game analytics screen — the three views (design of record)

Locked in chat 2026-07-23 from a visual mockup (Artifact:
`claude.ai/code/artifact/31fdd79f-fb2c-454b-8dbf-c71efd24b038`). The *layout and treatment* below are
agreed; the **exact contents of each view are deliberately left open** — pin them
down once the data is flowing and we can see real distributions (which stats earn
a row, how the chart reads, thresholds). All three read from the **same
per-game shot-event buffer** the `AdvancedStatsTracker` already holds (§4), so
they share one source of truth — a stat and its position on the map can never
disagree.

1. **Team shot map (the hero).** Top-down rink, each team's attempts plotted in
   their attacking end. Encoding: **position + team color** = the differential
   read, **dot size = xG**, **goals highlighted** (ring + glow). Rendered
   engine-native (Godot `_draw()` — boards / lines / creases / faceoff circles are
   cheap vector geometry, no chart lib, confirming §4.2). Team map here; the
   individual map is the career heatmap (§7.2).
2. **Tale of the tape.** Head-to-head comparison bars (home ↔ away). The advanced
   rows — xG, Corsi, Fenwick, PDO — are visually tagged as the differentiator.
   *Which* rows and their order are TBD until the stats exist.
3. **Expected-goals flow.** Cumulative xGF over game clock, one line per team,
   goals marked on the lines — the "run of play" chart. Nearly free once shots
   carry timestamps; pulled into Phase B alongside the map. Exact display (axes,
   period markers, interaction) is TBD.

Determinism/networking: the buffer is host-only (§4–5); for an online client to
render the post-game screen, the host ships the game's shot list at the final horn
via one reliable RPC (array of shot events — same shape as other end-game data).
Offline/free-play the host is local, so it is free.

### 7.2 Career heatmap — the individual view

The **individual-player** counterpart to the team map: a smoothed density surface
(hexbin / KDE) over hundreds of shots — *where this player shoots from and scores
from* — with a goals overlay. Lives on the career screen (needs the persisted
`shot_events` table, §6). Heatmap (not scatter) because aggregate volume is what
makes a density read meaningful; the per-game view stays a scatter for the same
reason (§9 small-sample caveat).

---

## 8. Landing order

- **Phase A1 — Corsi/Fenwick/PDO counters.** Pure plumbing off existing events.
  Ships advanced *boxscore* immediately, no model risk. Validates the
  `AdvancedStatsTracker` seam.
- **Phase A2 — xG counters.** `expected_goals()` + calibration loop (§3.3), xGF/xGA
  + G−xG. The differentiator, as numbers.
- **Phase B — shot-event log + analytics screen.** Heatmaps, shot maps, the
  reliability plot as a shipped view.

Each phase is independently shippable and additive; A1 de-risks the architecture
before the model work.

---

## 9. Honest limitations

- **Small-sample noise.** xG/Corsi are aggregate rate stats; over one short arcade
  game the shot sample is tiny and per-game numbers are noisy. They shine in
  **career aggregates** and as a **live run-of-play** readout, not as single-game
  truth. Lead with aggregates.
- **AI goalies.** Save% / xGA reflect the AI goalie, so PDO's save-% half and any
  "goals saved above expected" is a goalie-*tuning* metric, not a player stat.
  xGA is still a real, player-facing measure of *team defensive chance
  suppression*.
- **Ground-truth advantage is real but must be earned by calibration.** The model
  is only "true xG" once §3.3 shows it's calibrated against actual outcomes;
  until then it is `open_net_danger` with a nicer coat. Do the reliability plot
  before claiming the number.
- **3v3 default.** Attempt volumes and slot geometry differ from 5v5; the
  chance/high-danger thresholds (§2.5) may need a per-mode value. Fit per mode if
  the distributions diverge.
