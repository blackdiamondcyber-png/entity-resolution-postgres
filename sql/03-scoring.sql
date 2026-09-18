create or replace function haversine_m(
  lat1 double precision, lon1 double precision,
  lat2 double precision, lon2 double precision
) returns double precision language sql immutable as $$
  select 6371000 * 2 * asin(sqrt(
    power(sin(radians(lat2-lat1)/2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) *
    power(sin(radians(lon2-lon1)/2), 2)
  ));
$$;

create or replace function match_score(a locations, b locations)
returns numeric language sql stable set search_path = public as $$
  select
      (coalesce(similarity(a.name, b.name), 0) * 0.45)::numeric
    + (case when a.phone_key is not null and a.phone_key = b.phone_key then 0.30 else 0 end)
    + (case when a.street_key is not null
             and a.street_key  = b.street_key
             and a.postal_code = b.postal_code then 0.15 else 0 end)
    + (case
         when a.latitude is null or b.latitude is null then 0
         when haversine_m(a.latitude,a.longitude,b.latitude,b.longitude) < 50  then 0.10
         when haversine_m(a.latitude,a.longitude,b.latitude,b.longitude) < 500 then 0.05
         else 0
       end);
$$;

-- One row per pair, whatever found it. Blocking is allowed to reach the same
-- pair down several keys, and usually does: matching phone numbers very often
-- means matching addresses too. Scoring is per pair, so collapse first, and
-- keep which blocks hit as a label rather than as extra rows.
create or replace view scored_pairs as
with pairs as (
  select a_id, b_id, string_agg(distinct block, '+' order by block) as block
    from candidate_pairs
   group by a_id, b_id
)
select p.a_id, p.b_id, p.block,
       match_score(a, b) as score,
       case when match_score(a, b) >= 0.85 then 'auto_merge'
            when match_score(a, b) >= 0.60 then 'review'
            else 'distinct' end as verdict
from pairs p
join locations a on a.id = p.a_id
join locations b on b.id = p.b_id;

create table if not exists review_queue (
  a_id uuid not null, b_id uuid not null,
  score numeric not null, decided boolean not null default false,
  decision text, primary key (a_id, b_id)
);
