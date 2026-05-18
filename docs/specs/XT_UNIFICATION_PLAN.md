# xT Unification Plan

Refactor AI scoring to a single signed Expected Threat (xT) function, replacing the current patchwork of `score_shoot` / `score_pass` / `position_potential` / `threat_surface_*`. Brings the entire AI value system onto one calibrated scale and one recursive evaluator, in line with the published xT / VAEP / pitch-control literature.

## Context

The current AI scores decisions through several semantically different functions:

- `score_shoot` is xG-shaped (real-world calibrated probability of goal).
- `score_pass` is a one-step xT lookahead (lane × `score_shoot(receiver)`) — already does the right thing, the name lies.
- `_score_at` (carrier-only) is a 2-deep recursive evaluator that's almost xT but falls back to `position_potential` outside shot range.
- `position_potential` is a hand-tuned positional heuristic with no physical grounding.
- `threat_surface_shoot` / `threat_surface_pass` are defensive wrappers that take `max(real_score, position_potential)` to keep gradients alive when a real score collapses to 0.

The problems:

1. `position_potential` and `score_shoot` are nominally both 0-1 but have no shared semantics. Multiplying or `max()`-ing them produces a number with no clear interpretation.
2. Off-puck offensive roles (SUPPORT, FINISHER, OUTLET) call plain `score_pass` directly. When the carrier can't reach the candidate cleanly (no clear lane), they have no positional gradient and fall back to standing still — the "bots don't look for open space" complaint.
3. Defensive roles use a parallel scoring scaffold (`threat_surface_*`) that's the inverse of offense but with a separate code path.
4. The "ability to make space afterwards" idea has no representation — every score is a snapshot.

The unification: one signed value, one meaning, one evaluator. xT(state) = expected goal differential for our team over the next K actions under approximately-optimal play. Defense is the same function, sign flipped where applicable, with the bot's hypothetical position included in the defender list. The recursive evaluation naturally provides the "what comes next" gradient that's currently missing.

Recursion depth fixed at 3. Hard rename in place — no compatibility layer.

## Architecture

### Canonical evaluator

```gdscript
# AIActionScoring.xT — returns expected goal differential for `our_team`
# in the next K ≤ DEPTH actions of play, given the snapshot state.
# Positive = our_team scores; negative = opp scores.
#
# Minimax with chance nodes: at each level the team currently holding
# the puck picks the action that maximizes their own xT (which is the
# negation of the opposing team's xT). Pass success / lane survival
# enters as a chance factor on each action branch.
static func xT(state: XTState, our_team: int, depth: int) -> float
```

`XTState` is a lightweight bag of the snapshot fields the evaluator needs (puck position + velocity, carrier peer/team, all skater states, both goalie states, attacking + defending net for `our_team`). One allocation per top-level call; mutated as the recursion explores hypothetical next states. Holding skater states by reference avoids copies on every recursion level.

### Leaf

```gdscript
# AIActionScoring.xG — calibrated shot quality. Renamed from score_shoot.
# Unchanged shape: dist_response × shot_angle × (1 − coverage) × lane_clear
# × pressure × goalie_zone. The only term that touches real-world goal
# probabilities. Every other xT value bottoms here.
static func xG(...) -> float
```

`score_quick_shot` becomes `xG_quick` (same wrapper signature, different release-time prediction).

### Action enumeration per level

At each non-leaf node, the puck-holder's available actions are enumerated and scored as `P(success) × xT(next_state, our_team, depth − 1) × discount(time_to_action)`. Children:

- **SHOOT** — terminal-ish: returns `xG(carrier_pos)`. No further recursion (the shot is the absorbing reward).
- **QUICK_SHOT** — same as SHOOT with PASS_SPEED and no goalie lookahead. Terminal.
- **PASS to teammate T** — `lane_clear(carrier, T) × xT(state with carrier=T, our_team, depth-1) × discount(flight_time)`. Failed pass collapses to `lane_clear = 0` → contributes 0. Same model `score_pass` already uses.
- **CARRY one step** — 4 cardinal directions (down from 8 to bound branching) at SEARCH_STEP_M. `path_clearance × xT(state with carrier moved, our_team, depth-1) × discount(travel_time)`.

Total children per non-leaf node: 1 SHOOT + 1 QUICK_SHOT + (~2 teammates) PASS + 4 CARRY ≈ 8.

### Minimax structure

```
xT(state, our_team, depth):
    if depth == 0 or terminal: return xG_signed(state, our_team)
    is_our_turn = (state.carrier_team == our_team)
    best = -INF if is_our_turn else +INF
    for action in enumerate_actions(state):
        p = transition_probability(action, state)
        next_state = apply(action, state)
        v = p × xT(next_state, our_team, depth − 1) × discount
        best = max(best, v) if is_our_turn else min(best, v)
    return best
```

Loose-puck states (`carrier_team == -1`) are treated as terminal nodes with `xT = 0` for the simple model. Improvements (modeling pickup probability) are a follow-up.

### Compute budget at depth 3

Branching factor 8, depth 3 → ~512 leaf evaluations per top-level xT call. Each role re-eval scores ~10 candidate positions → ~5,000 xG evaluations. Six bots × 6 Hz brain tick → ~180k xG evaluations per second. Each xG is ~100ns of math. ≈ 18ms of CPU per second, ~2% of one core.

Carrier re-evaluates at 30 Hz (`PICK_ACTION_PERIOD_TICKS=8`) — 6 bots × 30 Hz × 10 candidates × 512 leaves = ~1M xG/sec, ~10% of one core. Manageable; we'll profile and push to depth 2 if it bites.

If the budget is a concern after profiling, the natural prune is to keep depth 3 only for the root level and drop to depth 2 inside recursion. Most of the cost comes from depth-3 fanout.

## Mapping current code → new structure

### Files modified

**`Scripts/domain/ai/action_scoring.gd`** (core rewrite)
- `score_shoot` → `xG` (rename, no shape change).
- `score_quick_shot` → `xG_quick` (rename).
- `score_pass` — delete. Becomes `xT` with depth=1 and a single PASS branch internally. Callers that need the one-shot lookahead use `xT(state_with_carrier_at_R, our_team, depth=1)`.
- `position_potential` — **delete**. No replacement; recursion subsumes it.
- `threat_surface_shoot` / `threat_surface_pass` — **delete**. Defense becomes `-xT(state, opp_team)` with our hypothetical position in the defender list.
- `_score_at` (currently in `carrier.gd`) — move here, rename to `xT`, make recursive properly (currently 2-deep with `position_potential` fallback; new version recurses to depth 3 with no fallback).
- Add `XTState` value class (small RefCounted bag) for state passing.
- `_lane_clear`, `_pressure`, `path_clearance`, `predict_goalie_pos`, `time_to_arrive`, `goalie_zone_penalty` — keep unchanged. These are the physics primitives (transition probabilities and survival probabilities in the Markov chain). Their inputs are already physically grounded.

**`Scripts/domain/ai/role_behaviors/carrier.gd`**
- `_pick_action` rewrites: enumerate (SHOOT, QUICK_SHOT, PASS×teammates, CARRY×candidates), score each via `transition_prob × xT(next_state, our_team, depth=DEPTH-1) × discount`. Pick max.
- Hysteresis still applies on fire intents only.
- Debug fields stay (`debug_shoot_score`, `debug_quick_shot_score`, `debug_pass_score`, `debug_carry_score`) — they're now per-action xT values, all on the same scale.

**`Scripts/domain/ai/role_behaviors/support.gd`, `finisher.gd`, `outlet.gd`**
- Replace `AIActionScoring.score_pass(carrier, candidate, ...)` argmax with `AIActionScoring.xT(state_with_me_at_candidate, our_team, DEPTH)` argmax.
- "State with me at candidate" mutates only the candidate-evaluator's own skater position in the XTState before recursing. Everything else identical.
- The exposure factor in SUPPORT (foot-race-home) stays — that's a constraint on the candidate, not a value term. Multiply at the role level: `xT(state) × (1 − exposure)`. Or fold exposure into the recursion as a defensive `defending_goal` penalty term. Plan: keep at role level for first cut.

**`Scripts/domain/ai/role_behaviors/anchor.gd`, `backcheck.gd`, `cover.gd`, `pressure.gd`, `contain.gd`**
- Replace `threat_surface_*` minimax with `-xT(state, opp_team, DEPTH)` with self at candidate added to defenders.
- Search centers unchanged (each role's geometric anchor stays: midpoint, slot, carrier-cutoff, etc.).
- Goal-side filter on PRESSURE unchanged.
- CONTAIN's exposure-mirror factor — same treatment as SUPPORT, multiply at the role level.

**`Scripts/domain/ai/role_behaviors/chase.gd`, `flank.gd`, `anchor_follow.gd`**
- Unchanged. Trivial positional roles, no scoring.

**`tests/unit/rules/test_ai_action_scoring.gd`**
- Rename references: `score_shoot` → `xG`. Update assertions.
- New tests for `xT` at depth 1, depth 2, depth 3 — verify the minimax structure, verify it bottoms at xG, verify it's signed correctly when puck changes teams.
- Delete tests for `score_pass`, `position_potential`, `threat_surface_*` (the functions are gone).

**`tests/unit/rules/test_ai_shot_aim.gd`** — unchanged (it tests `AIShotAim`, separate concern).

**`tests/unit/rules/test_role_*.gd`** — update to call the new role functions, but most should still pass. The role argmaxes operate on the same `target_position` interface; the underlying scoring changed but the position selected for the test scenarios should still make sense. Real test churn is in `test_role_carrier.gd` where the per-action scores are inspected directly.

## Implementation order

Five distinct steps, each commit-sized and individually testable:

### Step 1: Add `XTState` and the new `xT`/`xG` functions alongside the old ones

- Write `XTState` class.
- Add `AIActionScoring.xG` as a renamed clone of `score_shoot` (both exist temporarily).
- Add `AIActionScoring.xT(state, our_team, depth)` implementing the recursive minimax. At depth 0 returns `xG` of the puck-holder's shot.
- Add `xG_quick` as a renamed clone of `score_quick_shot`.
- Add depth constant `XT_RECURSION_DEPTH = 3`.
- New unit tests for `xT` and `xG` (basic structure: leaf returns xG, depth=1 PASS recovers `lane × xG(receiver)`, signs flip with possession, etc.).

After this step the old functions still exist and the codebase compiles + tests pass. New functions are sitting unused.

### Step 2: Migrate the CARRIER

- Replace `_pick_action`'s manual SHOOT/QUICK_SHOT/PASS/CARRY scoring with a unified action enumeration that scores each via `xT`.
- Keep the action enum (`INTENT_*`) and the press-state transitions unchanged.
- Hysteresis and tie-breaks stay.
- Update `test_role_carrier.gd` for the new scores.

After this step, the CARRIER uses xT but off-puck roles still use the old `score_pass`. Game should still play; CARRIER's decisions should be approximately the same (depth 2 / 3 vs current 2 doesn't change much for shot vs pass vs carry from the slot).

### Step 3: Migrate off-puck offensive roles (SUPPORT, FINISHER, OUTLET)

- Each role's candidate argmax switches to `xT(state_with_me_at_candidate, our_team, DEPTH)`.
- Exposure factor in SUPPORT stays at the role level for now.
- Update role tests.

After this step, off-puck offense uses xT. This is where the "find open space" behavior should emerge — recursion gives the missing positional gradient.

### Step 4: Migrate defensive roles (PRESSURE, ANCHOR, COVER, BACKCHECK, CONTAIN)

- Each role's `threat_surface_*` minimax switches to `-xT(state, opp_team, DEPTH)` with self in defenders.
- Exposure mirror in CONTAIN stays at role level.
- Search centers and filters unchanged.
- Update role tests.

After this step, all utility-AI roles share one evaluator. The two scaffolds are gone.

### Step 5: Delete the dead code

- Remove `score_shoot`, `score_pass`, `score_quick_shot`, `position_potential`, `threat_surface_shoot`, `threat_surface_pass` from `AIActionScoring`.
- Remove `_score_at` from `carrier.gd` (it's the old name for `xT`, already lifted in Step 1).
- Remove `SLOT_RADIUS_M` (only used by `position_potential`).
- Update remaining test files that referenced deleted functions.
- Final compile + GUT pass.

Each step is its own commit. The user can pause after any step and roll back if behavior regresses.

## Compute budget verification

After Step 4 is in, profile a 3v3 match (host-only since AI is host-side):

- Per-tick AI dispatch time should stay under 1 ms total across all 6 bots (currently it's <0.5 ms with throttling).
- If it spikes above 2 ms, drop `XT_RECURSION_DEPTH` to 2 and re-profile. Document the depth choice and the reasoning in the constant's comment.
- If depth 2 is still too slow (unlikely), reduce CARRY branching to 2 directions or reduce teammate branching to 1.

Profile method: enable Godot's built-in profiler in the editor, run a match, watch the `_compute_tick` / `_pick_action` timings in the script profile.

## Verification

After all five steps:

1. **Existing GUT tests pass** (with renames applied). Domain-layer scoring tests are the primary regression net.
2. **Carrier decisions still feel correct in-game**. Quick smoke test: 1v0 in the slot picks SHOOT or QUICK_SHOT; 2v0 with a clear backdoor receiver picks PASS; rush from the blue line picks CARRY toward slot first.
3. **Off-puck bots find open space.** Set up a 2v2 in the OZ with the human carrier in a corner. SUPPORT/FINISHER should drift to high-slot / backdoor / weak-side positions even when no clear pass exists, because the deeper xT recursion sees "if I move here, the team's future xT improves."
4. **Defense doesn't regress.** Set up a 0v2 in our DZ. ANCHOR/COVER/PRESSURE should converge on slot / weak-side / cutoff positions consistent with the old behavior (the math is structurally equivalent — `-xT(opp_state)` ≈ old inverse-threat minimax, just with deeper lookahead and no `position_potential` floor).
5. **CPU budget under target** (profile in Godot editor).

User runs the GUT panel after each step and a local 3v3 game after Step 3 and Step 4. Cannot run from this environment.

## Out of scope

- **Continuous pitch control** (Fernandez-Bornn). The literature suggests it's the natural upgrade to `_lane_clear` / `_pressure`, but it's a separate refactor with its own design trade-offs (continuous vs discrete probability surfaces). Capture as a future improvement.
- **Loose-puck modeling in xT recursion**. Currently a failed pass terminates the branch at 0. A proper model would estimate pickup probability based on skater proximity / velocity. Defer.
- **Defensive xT for exposure / foot-race calcs**. Keeping `_exposure` at the role level rather than folding it into xT. Cleaner separation for the first cut; revisit if a defensive xT term emerges naturally.
- **Learned xT model** (VAEP-style). Requires a training corpus we don't have. Not a near-term path.

## Open question — naming inside the file

The codebase convention is `snake_case` for functions including domain math. xT and xG are conventional capitalizations from the literature. Decision: use `xT` and `xG` (capital `T`/`G`) as function names — they're acronyms not regular words, the literature uses them this way, and the readability win of "this is the standard sports-analytics value function" outweighs the snake_case convention drift. Comments / variable names follow snake_case (`xt_value`, `xg_score`).
