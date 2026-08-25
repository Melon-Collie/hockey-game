-- Goalie audit, pass 3 — SPLIT BY WHO SHOT IT.
--
-- Passes 1 and 2 pooled bot and human shots for everything except the headline,
-- and that conflates two completely different populations. A human who
-- deliberately forces the keeper down and takes nearly every shot inside 3 m
-- writes his own tactic into the BUTTERFLY row and the 0-3 m band, which then
-- read as properties of the goalie rather than of the shooter.
--
-- Overall the two populations already differ enormously — bots 66.8% save
-- percentage against humans 45.5% — so any row pooling them is a weighted blend
-- of a bot profile and a human profile in unknown proportion.
--
-- Every section here is therefore split, and the COMPOSITION columns matter as
-- much as the rates: `share` is what fraction of that shooter's own shots land
-- in the bucket. A bucket a human puts 60% of his shots into and a bot 5% of his
-- is not the same bucket, however similar the save percentages look.
--
-- steam_id 0 is a bot. Same normalisation, filters and bands as
-- goalie_shot_events_audit.sql.

with s as (
    select e.*,
           case when team_id = 1 then -x else x end as nx,
           case when team_id = 1 then -z else z end as nz
    from public.shot_events e
),
f as (
    select s.*,
           case when steam_id = 0 then 'bot  ' else 'human' end as who,
           sqrt(nx * nx + (nz + 26.65) * (nz + 26.65)) as dist_m,
           degrees(atan2(abs(nx), (nz + 26.65))) as angle_deg
    from s
    where outcome in ('goal', 'saved')
      and goalie_stance >= 0
),
tot as (
    select who, count(*) as n from f group by who
),
rep as (

-- ── 1. THE TWO POPULATIONS ──────────────────────────────────────────────────
select 1 as ord, '1. overall' as section, f.who as bucket,
       count(*) as shots, null::numeric as share,
       count(*) filter (where outcome = 'goal') as goals,
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1) as sv_pct
from f group by f.who

-- ── 2. STANCE — the row most at risk of being a tactic, not a trait ─────────
union all
select 2, '2. stance', f.who || ' | ' || bnd,
       count(*),
       round(100.0 * count(*) / nullif(max(tot.n), 0), 1),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from (select f.*, case goalie_stance
          when 0 then '00 STANDING'   when 1 then '01 BUTTERFLY'
          when 2 then '02 RECOVERING' when 3 then '03 RVH_LEFT'
          when 4 then '04 RVH_RIGHT'  when 5 then '05 READY'
          when 6 then '06 SLIDING'    when 7 then '07 COILING'
          when 8 then '08 VH_LEFT'    when 9 then '09 VH_RIGHT'
          when 10 then '10 COVERING'  when 11 then '11 PLAYING_PUCK'
          when 12 then '12 CATCHING'  when 13 then '13 CATCHING_DOWN'
          else '?? ' || goalie_stance::text end as bnd from f) f
     join tot on tot.who = f.who
group by f.who, bnd

-- ── 3. DISTANCE — is the 0-3 m band one shooter's whole game? ───────────────
union all
select 3, '3. distance', f.who || ' | ' || bnd,
       count(*),
       round(100.0 * count(*) / nullif(max(tot.n), 0), 1),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from (select f.*, case
          when dist_m < 3  then 'a. 0-3 m'
          when dist_m < 5  then 'b. 3-5 m'
          when dist_m < 7  then 'c. 5-7 m'
          when dist_m < 10 then 'd. 7-10 m'
          else                  'e. 10+ m'
      end as bnd from f) f
     join tot on tot.who = f.who
group by f.who, bnd

-- ── 4. UNSET — the set-vs-moving split, per shooter ────────────────────────
union all
select 4, '4. goalie_unset', f.who || ' | ' || bnd,
       count(*),
       round(100.0 * count(*) / nullif(max(tot.n), 0), 1),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from (select f.*, case
          when goalie_unset < 0.1 then 'a. set'
          when goalie_unset < 0.3 then 'b. 0.1-0.3'
          when goalie_unset < 0.6 then 'c. 0.3-0.6'
          else                         'd. in motion'
      end as bnd from f) f
     join tot on tot.who = f.who
group by f.who, bnd

-- ── 5. ANGLE — does the inversion hold for BOTS on their own? ───────────────
union all
select 5, '5. angle', f.who || ' | ' || bnd,
       count(*),
       round(100.0 * count(*) / nullif(max(tot.n), 0), 1),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from (select f.*, case
          when angle_deg < 20 then 'a. 0-20 deg'
          when angle_deg < 40 then 'b. 20-40 deg'
          when angle_deg < 60 then 'c. 40-60 deg'
          else                     'd. 60+ deg'
      end as bnd from f) f
     join tot on tot.who = f.who
group by f.who, bnd

-- ── 6. IN TIGHT ONLY — inside 3 m, split by stance and shooter ─────────────
-- The specific claim worth isolating: a keeper who is DOWN inside 3 m. If that
-- cell is almost entirely one shooter's, the stance rows above describe a tactic
-- rather than a weakness.
union all
select 6, '6. inside 3 m, by stance', f.who || ' | ' || bnd,
       count(*),
       round(100.0 * count(*) / nullif(max(tot.n), 0), 1),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from (select f.*, case
          when goalie_stance in (1, 6, 7, 2) then 'DOWN (btf/slide/coil/rec)'
          when goalie_stance in (3, 4, 8, 9) then 'POST (rvh/vh)'
          else                                    'UP'
      end as bnd from f where dist_m < 3.0) f
     join tot on tot.who = f.who
group by f.who, bnd

)
-- shots = shots faced in the bucket; share = % of THAT shooter's own shots that
-- land here; sv_pct = save percentage in the bucket.
select section, bucket, shots, share, goals, sv_pct
from rep order by ord, bucket;
