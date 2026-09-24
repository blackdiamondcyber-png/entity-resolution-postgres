-- Weighted similarity. The name counts through name_similarity, so a DBA
-- name can carry it. The phone counts only when the two records are within a
-- kilometre, or when either has no coordinates: a chain lists one booking
-- line at every site, and without the distance check each pair of its sites
-- scored 0.30 for sharing it.
create or replace function match_score(a locations, b locations)
returns numeric language sql stable set search_path = public as $$
  select
      (name_similarity(a, b) * 0.45)::numeric
    + (case when a.phone_key is not null and a.phone_key = b.phone_key
             and coalesce(distance_m(a, b) < 1000, true) then 0.30 else 0 end)
    + (case when a.street_key is not null
             and a.street_key  = b.street_key
             and a.postal_code = b.postal_code then 0.15 else 0 end)
    + (case
         when distance_m(a, b) is null then 0
         when distance_m(a, b) < 50  then 0.10
         when distance_m(a, b) < 500 then 0.05
         else 0
       end);
$$;

-- One row per pair, whatever found it. Blocking is allowed to reach the same
-- pair down several keys, and usually does: matching phone numbers very often
-- means matching addresses too. Scoring is per pair, so collapse first, and
-- keep which blocks hit as a label rather than as extra rows.
--
-- Only the score can auto-merge. Two kinds of evidence send a pair to review
-- even when the score is low, because the score cannot see them:
--   keys agree: the same valid phone, street number and postal code, and
--               under 50 m apart (or no coordinates). Only the names differ,
--               which is what a practice sold or renamed looks like.
--   same place: under 150 m apart with a name similarity of 0.5 or more,
--               which is what a record with no phone or address looks like.
-- routed_by says which one did it.
create or replace view scored_pairs as
with pairs as (
  select a_id, b_id, string_agg(distinct block, '+' order by block) as block
    from candidate_pairs
   group by a_id, b_id
), scored as (
  select p.a_id, p.b_id, p.block,
         match_score(a, b) as score,
         distance_m(a, b) as metres,
         name_similarity(a, b) as name_sim,
         coalesce(a.phone_key = b.phone_key
                  and a.street_key = b.street_key
                  and a.postal_code = b.postal_code, false) as keys_agree
    from pairs p
    join locations a on a.id = p.a_id
    join locations b on b.id = p.b_id
)
select a_id, b_id, block, score,
       case when score >= 0.85 then 'auto_merge'
            when score >= 0.60 then 'review'
            when keys_agree and coalesce(metres < 50, true) then 'review'
            when metres < 150 and name_sim >= 0.5 then 'review'
            else 'distinct' end as verdict,
       case when score >= 0.60 then 'score'
            when keys_agree and coalesce(metres < 50, true) then 'keys agree'
            when metres < 150 and name_sim >= 0.5 then 'same place'
       end as routed_by
  from scored;

create table if not exists review_queue (
  a_id uuid not null, b_id uuid not null,
  score numeric not null, decided boolean not null default false,
  decision text, primary key (a_id, b_id)
);
