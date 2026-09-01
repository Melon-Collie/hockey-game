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
--
-- ══ WHAT IT MEASURED — the depth is fine, the COMMIT is not ═══════════════
-- Sections 3 and 4 are the same radius cut while DOWN and while UP, inside 5 m,
-- and they separate cleanly.
--
--   radius band          bot DOWN  bot UP  | human DOWN  human UP
--   <0.55                   60.0%   78.8%  |     60.5%     58.6%
--   0.55-0.90               41.8%   67.7%  |     24.1%     50.0%
--   0.90-1.30               32.7%   63.0%  |     18.6%     50.0%
--   1.30-1.60               24.0%   69.6%  |      3.8%      (n=4)
--
-- Standing, challenge depth costs him almost nothing: bot save percentage falls
-- 9 points across the whole range and the crease-top band is no worse than the
-- middle. Down, it collapses — 36 points for bots and 57 for the human, ending
-- at 25 goals on 26 shots.
--
-- So aggression is not the defect. Dropping WHILE aggressive is. A keeper who
-- commits at 1.3-1.6 m has left more than a metre of ice behind him and cannot
-- translate or rotate to cover it, and 60% of the human's goals against a down
-- keeper inside 5 m come with him at 0.90 m or further out.
--
-- He also drops further out against the human than the bots (mean radius 0.891
-- against 0.772), which is what baiting the commit produces.
--
-- POST STANCES ARE NOT THE ANSWER HERE and should not be read as a gap: butterfly
-- to RVH is not a transition, and these are not sharp-angle plays. The 10 of 1338
-- shots meeting an RVH/VH posture is correct, not a missing feature.
--
-- ══ CORRECTION — THE RADIUS IS A PROXY, NOT A CAUSE ════════════════════════
-- "Dropping WHILE aggressive is the defect" was the causal reading of the table
-- above, and tests/unit/ai/test_human_wraparound.gd contradicts it. Held to a
-- FIXED release point, baiting the commit further out leaves LESS net open, not
-- more: measured 2/7 aim points open from a commit at 0.92 m against 3/7 from
-- one at 0.27 m.
--
-- The mechanism the instrument offers: a committed slide spends 94% of its
-- travel on DEPTH (0.08 m lateral against 1.20 m, ~0.48 s to settle), because
-- the post-edge seal spot is only 0.154 m off centre — a butterfly pad reaches
-- the post from there. So a keeper who commits EARLY has finished retreating by
-- the time the shot arrives, and one who commits late has not.
--
-- Which makes `goalie_radius` while DOWN a measure of how recently he was
-- disturbed rather than of how aggressive he was, and the bands above a
-- ranking of shots by how far into his transit they came. Read them that way.

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
