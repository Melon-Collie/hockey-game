-- Goalie audit, pass 2 — the confound test.
--
-- Pass 1 found the goalie stops 72.3% when set and 46.7% when in motion, and
-- that 45% of all shots catch him in motion. That is either the finding or an
-- artifact: he may be unset BECAUSE the play was dangerous (a cross-crease feed
-- moves him and is hard to stop for reasons that have nothing to do with his
-- motion), in which case "unset" is a marker for danger rather than a cause of
-- it.
--
-- The test is whether the penalty SURVIVES AT FIXED RANGE AND ANGLE. If unset
-- costs ~25 points inside every distance band, his motion is doing the work. If
-- it collapses once range is held, the range was doing the work and the unset
-- split was confounded.
--
-- Same normalisation and filters as goalie_shot_events_audit.sql. `n` is on
-- every row: several cells will be too thin to read and must be discounted
-- rather than quoted.

with s as (
    select e.*,
           case when team_id = 1 then -x else x end as nx,
           case when team_id = 1 then -z else z end as nz
    from public.shot_events e
),
f as (
    select s.*,
           sqrt(nx * nx + (nz + 26.65) * (nz + 26.65)) as dist_m,
           degrees(atan2(abs(nx), (nz + 26.65))) as angle_deg,
           case
               when goalie_unset < 0.1 then '1 set'
               when goalie_unset < 0.3 then '2 drifting'
               when goalie_unset < 0.6 then '3 moving'
               else                          '4 in motion'
           end as unset_band,
           case goalie_stance
               when 5 then 'a READY'
               when 0 then 'a READY'          -- STANDING, same upright family
               when 1 then 'b BUTTERFLY'
               when 2 then 'c RECOVERING'
               when 6 then 'd SLIDING/COILING'
               when 7 then 'd SLIDING/COILING'
               when 3 then 'e POST'
               when 4 then 'e POST'
               when 8 then 'e POST'
               when 9 then 'e POST'
               else        'f other'
           end as stance_grp,
           case
               when dist_m < 3  then 'A 0-3 m'
               when dist_m < 5  then 'B 3-5 m'
               when dist_m < 7  then 'C 5-7 m'
               when dist_m < 10 then 'D 7-10 m'
               else                  'E 10+ m'
           end as dist_band,
           case
               when angle_deg < 20 then 'P 0-20 deg'
               when angle_deg < 40 then 'Q 20-40 deg'
               when angle_deg < 60 then 'R 40-60 deg'
               else                     'S 60+ deg'
           end as angle_band
    from s
    where outcome in ('goal', 'saved')
      and goalie_stance >= 0
),
rep as (

-- ── A. THE CONFOUND TEST: does the unset penalty survive at fixed range? ────
select 1 as ord, 'A. distance x unset' as section,
       dist_band || '  |  ' || unset_band as bucket,
       count(*) as n,
       count(*) filter (where outcome = 'goal') as goals,
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1) as sv_pct
from f group by dist_band, unset_band

-- ── B. …and at fixed angle? ─────────────────────────────────────────────────
union all
select 2, 'B. angle x unset', angle_band || '  |  ' || unset_band,
       count(*), count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from f group by angle_band, unset_band

-- ── C. Stance at fixed range — is COILING lethal, or just close? ────────────
union all
select 3, 'C. distance x stance', dist_band || '  |  ' || stance_grp,
       count(*), count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from f group by dist_band, stance_grp

-- ── D. Is the ANGLE inversion just post-integration stances? ────────────────
union all
select 4, 'D. angle x stance', angle_band || '  |  ' || stance_grp,
       count(*), count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from f group by angle_band, stance_grp

-- ── E. EXPOSURE — how often is he caught in motion, by range and angle? ─────
-- The other half of the story: a 25-point penalty only matters as much as the
-- share of shots that land in it.
union all
select 5, 'E. exposure by distance', dist_band,
       count(*), count(*) filter (where unset_band = '4 in motion'),
       round(100.0 * count(*) filter (where unset_band = '4 in motion')
             / nullif(count(*), 0), 1)
from f group by dist_band
union all
select 6, 'F. exposure by angle', angle_band,
       count(*), count(*) filter (where unset_band = '4 in motion'),
       round(100.0 * count(*) filter (where unset_band = '4 in motion')
             / nullif(count(*), 0), 1)
from f group by angle_band

-- ── G. Who puts him in motion — bots or humans? ─────────────────────────────
union all
select 7, 'G. exposure by shooter',
       case when steam_id = 0 then 'bot' else 'human' end,
       count(*), count(*) filter (where unset_band = '4 in motion'),
       round(100.0 * count(*) filter (where unset_band = '4 in motion')
             / nullif(count(*), 0), 1)
from f group by (steam_id = 0)

-- ── H. Does shooter pace explain the motion? ────────────────────────────────
union all
select 8, 'H. exposure by shooter speed',
       case
           when shooter_speed < 1.0 then 'a <1 m/s'
           when shooter_speed < 4.0 then 'b 1-4 m/s'
           when shooter_speed < 7.0 then 'c 4-7 m/s'
           else                          'd 7+ m/s'
       end,
       count(*), count(*) filter (where unset_band = '4 in motion'),
       round(100.0 * count(*) filter (where unset_band = '4 in motion')
             / nullif(count(*), 0), 1)
from f group by 3

)
-- In sections A-D: n = shots faced, goals = goals, sv_pct = save %.
-- In sections E-H: n = shots faced, goals = OF WHICH IN MOTION, sv_pct = % in motion.
select section, bucket, n, goals, sv_pct from rep order by ord, bucket;
