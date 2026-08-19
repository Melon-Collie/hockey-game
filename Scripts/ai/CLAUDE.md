# Bot agents — structure

Scope: `Scripts/ai/` — the nodes that turn a role decision into inputs. The
design rules those decisions are built from (evaluators, difficulty axes,
determinism, grounded models) live in `Scripts/domain/ai/CLAUDE.md`; read that
one before changing what a bot *decides*, and this one before changing how the
agent is *wired*.

## How an agent is put together

`SkaterAgent` owns the `InputState` scratch buffer and the `AIController` glue.
`SkaterAgentStateMachine` owns identity, transitions, and per-state behaviour,
and follows the same dispatch + `match` + per-state-handler shape as
`Scripts/controllers/skater_state_machine.gd`, so a reader of one can read the
other.

Adding a behaviour is four steps:

1. Append a `State` enum value.
2. Add a `match` arm in `dispatch()`.
3. Write the `_state_<name>` handler.
4. Decide where the transition into it happens — usually a check inside
   `_state_carry`.

```
                     ┌─ no puck ─────────────────────┐
                     │                               │
  OFF_PUCK ◄──────────► CHASE_PUCK (F1 only) ────────│
     │                       │                       │
     │  picks up puck        │  picks up puck        │
     ▼                       ▼                       │
    CARRY ──[in OZ + quiet-eye expired]──► SHOOT_PRESSED
     ▲                                          │
     └──────────────────────────────────────────┘
             (next tick, release fires)
```

**Off-puck behaviour does not live here.** Each `TeamBrain` slot maps to a role
module returning a `RoleDecision` (target position, optional aim override, fire
intents); the state machine only consumes it. `CARRIER` is the exception —
`_state_carry` dispatches the carrier directly, because it needs its own
steering rules (hold vs. drift during pre-aim) and its own press transitions.

## Reception doctrine

**A fast loose puck is a reception, not a race.** The catch is decided by blade
squareness plus the puck's speed *in the receiver's frame*, so squaring on the
line is what collects it and stopping is a wait rather than a technique. Bots
receive in stride by default and brake only when arriving early enough to carry
the blade past the meet, or when their own closing speed would stack over the
catch ceiling.

Against the boards the read inverts: the blade goes ON the glass and the body
stands rink-side, because a blade out on the puck's line leaves exactly the gap a
rim squirts through.

## Chase doctrine

**Chasing a carrier is angled, not straight-line.** The intercept is shaded one
stick-reach toward our own net so the approach arrives on the inside lane and the
carrier's only escape is outside; a straight-line chase lets them cut to the
middle. Loose pucks get the raw intercept — there is no carrier to angle off.
