-- shot_events release CONTEXT (goalie situation at the release tick).
--
-- WHY: a public-style xG model cannot be compared to ours on location alone,
-- because a fitted model has the context baked INTO its location term — an NHL
-- shot from 3 m is overwhelmingly rebounds and scrambles, so "3 m" silently
-- carries "chaos". Measuring our goalie against a clean, set, single-touch 3 m
-- shot and comparing the residue to that number measures nothing, which is
-- exactly what benchmarks/test_goalie_vs_xg_baseline.gd kept discovering.
--
-- These columns put the context back on the row, so an EMPIRICAL model can be
-- fitted from our own logged play and the comparison becomes like-for-like by
-- construction. They also make the questions that started this line of work
-- answerable by query rather than by harness sweep — "is he beaten more when
-- unset" is a GROUP BY over goalie_unset.
--
-- All of it is already computed at release for the goalie's own read; the game
-- previously discarded it. Idempotent DDL, additive only: older rows keep the
-- defaults, which read as a set, unscreened keeper — the neutral assumption
-- rather than a sentinel every query has to special-case.

alter table public.shot_events
    -- GoalieStateMachine.State at release; -1 when no goalie was resolved
    -- (drills, tutorial, empty net).
    add column if not exists goalie_stance       smallint default -1 not null,
    -- 0 square and stopped … 1 fully in motion. THE discriminator for "is he
    -- too easily beaten while moving".
    add column if not exists goalie_unset        numeric  default 0 not null,
    -- Challenge radius from goal centre (m), and lateral position (rink coords):
    -- was he out or deep, square or beaten across.
    add column if not exists goalie_radius       numeric  default 0 not null,
    add column if not exists goalie_x            numeric  default 0 not null,
    -- Seconds the shot was hidden from him by traffic. 0 = clear sight, which is
    -- the single largest real-hockey xG factor after location.
    add column if not exists screen_delay        numeric  default 0 not null,
    -- Shooter's planar speed (m/s) at release. Players almost never shoot from a
    -- standstill outside a one-timer, so this separates the common case from the
    -- one every harness sweep actually measured.
    add column if not exists shooter_speed       numeric  default 0 not null,
    -- Seconds since this goalie's last puck contact, -1 if none yet. The
    -- second-chance discriminator: the 0-3 m band is dominated by rebounds, and
    -- without this they are indistinguishable from clean looks.
    add column if not exists since_last_save_s   numeric  default -1 not null,
    -- |vx| of the release — a deke or cross-seam finish carries lateral pace a
    -- straight-on shot does not.
    add column if not exists puck_lateral_speed  numeric  default 0 not null;
