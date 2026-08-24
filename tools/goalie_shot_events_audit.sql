-- Goalie audit — one pasteable report over public.shot_events.
--
-- Answers the questions the harness sweeps cannot: what actually goes in, from
-- where, against which goalie state. Every section shares one column shape so the
-- whole thing returns as a single result set.
--
-- COORDINATES: normalised into team 0's attacking frame (team 1 rotated 180°,
-- (x,z) -> (-x,-z)) exactly like the shot_heatmap view, so both ends pool. The
-- goal mouth is then (0, -GOAL_LINE_Z) with GOAL_LINE_Z = 26.65.
--   dist_m    straight-line release distance to the goal centre
--   angle_deg 0 = dead centre, 90 = on the goal line, >90 = behind it (wraparound)
--
-- SV% is over shots that REACHED the goalie (outcome in goal/saved). 'missed' is
-- off net and 'blocked' was stopped by a skater, so neither is the keeper's.
--
-- ⚠️ `puck_lateral_speed` IS NOT DEKE PACE. It is absf(vel.x) of the shot's own
-- release velocity (GameManager._note_shot_context), so a cross-corner aim from
-- a stationary shooter reads as large lateral pace purely from aim geometry. The
-- release-context migration's column comment calls it a deke / cross-seam
-- discriminator; it is not one, and section 10 below should be read as "how
-- sideways was the shot aimed", nothing more. `shooter_speed` is the shooter's
-- real planar body speed and IS the movement discriminator.

with s as (
    select e.*,
           case when team_id = 1 then -x else x end as nx,
           case when team_id = 1 then -z else z end as nz
    from public.shot_events e
),
g as (
    select s.*,
           (nz + 26.65) as dz,
           sqrt(nx * nx + (nz + 26.65) * (nz + 26.65)) as dist_m,
           degrees(atan2(abs(nx), (nz + 26.65))) as angle_deg
    from s
),
-- Shots the goalie actually faced, with a real goalie in net (stance -1 is a
-- drill / tutorial / empty net and has no keeper to credit).
f as (
    select * from g
    where outcome in ('goal', 'saved')
      and goalie_stance >= 0
),
rep as (

-- ── 0. INVENTORY ────────────────────────────────────────────────────────────
select 0 as ord, '0. inventory' as section,
       'all rows' as bucket,
       count(*) as shots, null::bigint as faced, null::bigint as goals,
       null::numeric as sv_pct, null::numeric as xg_sum, null::numeric as xg_per
from g
union all
select 0, '0. inventory',
       'first ' || to_char(min(created_at), 'YYYY-MM-DD') ||
       '  ..  last ' || to_char(max(created_at), 'YYYY-MM-DD'),
       count(distinct game_id), null, null, null, null, null
from g
union all
select 0, '0. inventory', 'rows with no goalie (stance -1)',
       count(*), null, null, null, null, null
from g where goalie_stance < 0
union all
select 0, '0. inventory',
       case when steam_id = 0 then 'bot shooters' else 'human shooters' end,
       count(*), null, null, null, null, null
from g group by (steam_id = 0)

-- ── 1. HEADLINE ─────────────────────────────────────────────────────────────
union all
select 1, '1. headline', 'ALL FACED',
       count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2),
       round(avg(xg), 3)
from f
union all
select 1, '1. headline',
       case when steam_id = 0 then 'bot shooters' else 'human shooters' end,
       count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from f group by (steam_id = 0)

-- ── 2. BY BUILD — the goalie has changed under this data, so never pool blind
union all
select 2, '2. by game_version', coalesce(game_version, '(null)'),
       count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from f group by game_version

-- ── 3. DISTANCE — is the doorstep still 0.5? (rebound control) ──────────────
union all
select 3, '3. by distance', bnd, count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from (select f.*, case
          when dist_m < 3  then 'a. 0-3 m'
          when dist_m < 5  then 'b. 3-5 m'
          when dist_m < 7  then 'c. 5-7 m'
          when dist_m < 10 then 'd. 7-10 m'
          when dist_m < 15 then 'e. 10-15 m'
          else                  'f. 15+ m'
      end as bnd from f) q group by bnd

-- ── 4. ANGLE — the confirmed inversion; real hockey runs the other way ──────
union all
select 4, '4. by angle', bnd, count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from (select f.*, case
          when angle_deg < 20 then 'a. 0-20 deg'
          when angle_deg < 40 then 'b. 20-40 deg'
          when angle_deg < 60 then 'c. 40-60 deg'
          when angle_deg <= 90 then 'd. 60-90 deg'
          else                     'e. behind goal line'
      end as bnd from f) q group by bnd

-- ── 4b. ANGLE INSIDE 5 m — does the inversion hold in tight on its own? ─────
union all
select 5, '4b. angle, inside 5 m', bnd, count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from (select f.*, case
          when angle_deg < 20 then 'a. 0-20 deg'
          when angle_deg < 40 then 'b. 20-40 deg'
          when angle_deg < 60 then 'c. 40-60 deg'
          else                     'd. 60+ deg'
      end as bnd from f where dist_m < 5) q group by bnd

-- ── 5. REBOUNDS — the discriminator the harness structurally cannot model ───
union all
select 6, '5. since goalie last touch', bnd, count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from (select f.*, case
          when since_last_save_s < 0    then 'e. no prior touch'
          when since_last_save_s < 0.75 then 'a. <0.75 s (live rebound)'
          when since_last_save_s < 1.5  then 'b. 0.75-1.5 s'
          when since_last_save_s < 3.0  then 'c. 1.5-3 s'
          else                               'd. 3 s+ (clean look)'
      end as bnd from f) q group by bnd

-- ── 6. UNSET — "is he too easily beaten while moving" ───────────────────────
union all
select 7, '6. by goalie_unset', bnd, count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from (select f.*, case
          when goalie_unset < 0.1 then 'a. 0.0-0.1 (set)'
          when goalie_unset < 0.3 then 'b. 0.1-0.3'
          when goalie_unset < 0.6 then 'c. 0.3-0.6'
          else                         'd. 0.6+ (in motion)'
      end as bnd from f) q group by bnd

-- ── 7. STANCE at release ────────────────────────────────────────────────────
union all
select 8, '7. by stance', bnd, count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from (select f.*, case goalie_stance
          when 0 then '00 STANDING'      when 1 then '01 BUTTERFLY'
          when 2 then '02 RECOVERING'    when 3 then '03 RVH_LEFT'
          when 4 then '04 RVH_RIGHT'     when 5 then '05 READY'
          when 6 then '06 SLIDING'       when 7 then '07 COILING'
          when 8 then '08 VH_LEFT'       when 9 then '09 VH_RIGHT'
          when 10 then '10 COVERING'     when 11 then '11 PLAYING_PUCK'
          when 12 then '12 CATCHING'     when 13 then '13 CATCHING_DOWN'
          else '?? ' || goalie_stance::text
      end as bnd from f) q group by bnd

-- ── 8. SCREENS ──────────────────────────────────────────────────────────────
union all
select 9, '8. by screen_delay', bnd, count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from (select f.*, case
          when screen_delay <= 0.001 then 'a. clear sight'
          when screen_delay < 0.10   then 'b. <0.10 s'
          when screen_delay < 0.20   then 'c. 0.10-0.20 s'
          else                            'd. 0.20 s+'
      end as bnd from f) q group by bnd

-- ── 9. SHOOTER MOTION + LATERAL PACE (deke / cross-seam finishes) ───────────
union all
select 10, '9. by shooter_speed', bnd, count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from (select f.*, case
          when shooter_speed < 1.0 then 'a. <1 m/s (parked)'
          when shooter_speed < 4.0 then 'b. 1-4 m/s'
          when shooter_speed < 7.0 then 'c. 4-7 m/s'
          else                          'd. 7+ m/s'
      end as bnd from f) q group by bnd
union all
select 11, '10. by puck lateral speed', bnd, count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from (select f.*, case
          when puck_lateral_speed < 1.0 then 'a. <1 m/s'
          when puck_lateral_speed < 4.0 then 'b. 1-4 m/s'
          when puck_lateral_speed < 8.0 then 'c. 4-8 m/s'
          else                               'd. 8+ m/s'
      end as bnd from f) q group by bnd

-- ── 11. SHOT TYPE / MODE ────────────────────────────────────────────────────
union all
select 12, '11. by shot_type', coalesce(shot_type, '(null)'),
       count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from f group by shot_type
union all
select 13, '12. by team_size', team_size::text || 'v' || team_size::text,
       count(*), count(*),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from f group by team_size

-- ── 12. SHOT MIX — where attempts go before the keeper ever sees them ───────
union all
select 14, '13. attempt mix', coalesce(outcome, '(null)'),
       count(*), null, null,
       round(100.0 * count(*) / nullif(sum(count(*)) over (), 0), 1),
       round(sum(xg), 2), round(avg(xg), 3)
from g where goalie_stance >= 0 group by outcome

)
select section, bucket, shots, faced, goals,
       sv_pct, xg_sum, xg_per
from rep
order by ord, bucket;
