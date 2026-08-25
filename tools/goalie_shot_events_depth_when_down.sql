-- Goalie audit, pass 4 — HOW FAR OUT IS HE WHEN HE COMMITS?
--
-- The claim to test: he challenges aggressively, drops into the butterfly while
-- still well off his line, and a player can then walk around a keeper who is
-- both DOWN and OUT and shoot into the space behind him. Once down he does not
-- rotate at all (GoalieController._update_facing returns for BUTTERFLY), so a
-- walkaround gets no answer from tracking — only from the post seal or a
-- committed slide, and the seal machinery barely fires (10 of 1338 shots meet
-- an RVH/VH stance).
--
-- `goalie_radius` is his challenge radius from the goal centre at the release,
-- so this is a direct test. The authored anchors it should be read against:
--
--   depth_aggressive   1.75 m   the challenge ceiling
--   depth_base         1.30 m   heels at the crease top (CreaseRules 1.37)
--   depth_conservative 0.70 m   middle of the blue paint
--   butterfly_radius   0.40 m   the arc radius he holds once DOWN
--
-- The last one is the point. If dropping is supposed to settle him back to
-- 0.40 m but releases against a down keeper are landing at 1.2-1.7 m, then he
-- is being caught mid-transit — down and still out — and the space behind him
-- is real rather than imagined.
--
-- Same normalisation and filters as goalie_shot_events_audit.sql.

with s as (
    select e.*,
           case when team_id = 1 then -x else x end as nx,
           case when team_id = 1 then -z else z end as nz
    from public.shot_events e
),
f as (
    select s.*,
           case when steam_id = 0 then 'bot  ' else 'human' end as who,
           case when goalie_stance in (1, 2, 6, 7) then 'DOWN'
                when goalie_stance in (3, 4, 8, 9) then 'POST'
                else 'UP  ' end as posture,
           sqrt(nx * nx + (nz + 26.65) * (nz + 26.65)) as dist_m,
           case
               when goalie_radius < 0.55 then 'a. <0.55  (at butterfly_radius)'
               when goalie_radius < 0.90 then 'b. 0.55-0.90 (paint)'
               when goalie_radius < 1.30 then 'c. 0.90-1.30 (toward crease top)'
               when goalie_radius < 1.60 then 'd. 1.30-1.60 (crease top+)'
               else                           'e. 1.60+  (at the ceiling)'
           end as rband
    from s
    where outcome in ('goal', 'saved')
      and goalie_stance >= 0
),
rep as (

-- ── 1. HIS DEPTH WHEN DOWN vs WHEN UP, per shooter ─────────────────────────
select 1 as ord, '1. mean radius by posture' as section,
       f.who || ' | ' || f.posture as bucket,
       count(*) as shots,
       round(avg(goalie_radius), 3) as mean_radius,
       count(*) filter (where outcome = 'goal') as goals,
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1) as sv_pct
from f group by f.who, f.posture

-- ── 2. THE DISTRIBUTION when he is DOWN — is he ever actually back? ────────
union all
select 2, '2. radius when DOWN', f.who || ' | ' || f.rband,
       count(*), round(avg(goalie_radius), 3),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from f where f.posture = 'DOWN' group by f.who, f.rband

-- ── 3. DOES BEING OUT AND DOWN COST HIM? in tight only ────────────────────
-- Inside 5 m, where a walkaround is physically available. If conversion climbs
-- with his radius here, the aggression is what is being punished rather than
-- the drop itself.
union all
select 3, '3. DOWN, inside 5 m, by radius', f.who || ' | ' || f.rband,
       count(*), round(avg(goalie_radius), 3),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from f where f.posture = 'DOWN' and f.dist_m < 5.0 group by f.who, f.rband

-- ── 4. THE SAME CUT WHILE HE IS STILL UP — the control ────────────────────
-- If radius costs him while DOWN but not while UP, the problem is the commit,
-- not the depth. If it costs him in both, it is the depth.
union all
select 4, '4. UP, inside 5 m, by radius', f.who || ' | ' || f.rband,
       count(*), round(avg(goalie_radius), 3),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) filter (where outcome = 'saved')
             / nullif(count(*), 0), 1)
from f where f.posture = 'UP  ' and f.dist_m < 5.0 group by f.who, f.rband

-- ── 5. HOW OFTEN DOES THE POST SEAL EVER ENGAGE? ──────────────────────────
-- RVH/VH exist for exactly the wraparound and the sharp-angle walkout. If they
-- essentially never fire, the play has no designed answer at all.
union all
select 5, '5. post-seal engagement', f.who || ' | ' || f.posture,
       count(*), round(avg(goalie_radius), 3),
       count(*) filter (where outcome = 'goal'),
       round(100.0 * count(*) / nullif(sum(count(*)) over (partition by f.who), 0), 1)
from f group by f.who, f.posture

)
-- shots / mean_radius / goals / sv_pct — except section 5, where the last
-- column is the SHARE of that shooter's shots meeting that posture.
select section, bucket, shots, mean_radius, goals, sv_pct
from rep order by ord, bucket;
