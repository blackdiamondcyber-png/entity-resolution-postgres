-- Score the pipeline's real-data output against the labels in realdata/labels.
--
-- Run after realdata/load.sql and realdata/load-labels.sql:
--   psql "$DATABASE_URL" -f realdata/metrics.sql
-- Every query reads the repo's own scored_pairs view. The last block raises
-- if any published figure drifts, so the README cannot disagree with CI.

-- A pair is keyed by its two records as "source:record_id", sorted bytewise
-- (collate "C", the same order the label files were written in), because the
-- uuids behind scored_pairs change on every load.
create or replace view rd_pairs as
select least(k.ka, k.kb) || '|' || greatest(k.ka, k.kb) as pair_key,
       sp.verdict, sp.score, sp.block
  from scored_pairs sp
  join locations a on a.id = sp.a_id
  join locations b on b.id = sp.b_id
  cross join lateral (
    select (a.source || ':' || (a.external_ids->>'record_id')) collate "C" as ka,
           (b.source || ':' || (b.external_ids->>'record_id')) collate "C" as kb
  ) k;

-- 1. The labels must cover every auto_merge and review pair, and every label
--    must still point at a scored pair. Anything else means the data or the
--    pipeline changed under the labels.
do $$
declare
  unlabelled int;
  orphaned   int;
begin
  select count(*) into unlabelled
    from rd_pairs p left join pair_labels l using (pair_key)
   where p.verdict <> 'distinct' and l.pair_key is null;
  select count(*) into orphaned
    from pair_labels l left join rd_pairs p using (pair_key)
   where p.pair_key is null;
  if unlabelled > 0 or orphaned > 0 then
    raise exception 'labels out of step with scored_pairs: % unlabelled, % orphaned',
      unlabelled, orphaned;
  end if;
end $$;

-- 2. What each band holds.
select p.verdict,
       count(*)                                      as pairs,
       count(l.pair_key)                             as labelled,
       count(*) filter (where l.label = 'same')      as same,
       count(*) filter (where l.label = 'different') as different,
       count(*) filter (where l.label = 'unsure')    as unsure
  from rd_pairs p
  left join pair_labels l using (pair_key)
 group by p.verdict
 order by min(p.score) desc;

-- 3. Every auto-merge the labels disagree with.
select round(p.score, 3) as score, p.block, l.label, l.pair_key, l.reason
  from rd_pairs p
  join pair_labels l using (pair_key)
 where p.verdict = 'auto_merge' and l.label <> 'same'
 order by p.score desc;

-- 4. Recall across sources. neighbour_labels holds, for every OSM record, each
--    registry record near it or sharing its phone or name, labelled whether or
--    not blocking ever paired them. A true pair is one labelled same.
create or replace view rd_truth as
select n.osm_key, n.nppes_key, coalesce(p.verdict, 'not paired') as outcome
  from neighbour_labels n
  left join rd_pairs p
    on p.pair_key = least(n.osm_key collate "C", n.nppes_key collate "C")
                    || '|' || greatest(n.osm_key collate "C", n.nppes_key collate "C")
 where n.label = 'same';

-- An OSM record's outcome is the best any of its true pairs got.
create or replace view rd_osm_outcome as
select osm_key,
       (array['auto_merge', 'review', 'distinct', 'not paired'])[
         min(case outcome when 'auto_merge' then 1 when 'review' then 2
                          when 'distinct' then 3 else 4 end)
       ] as best
  from rd_truth
 group by osm_key;

select count(*)                                      as osm_records,
       count(*) filter (where s.has_same)            as with_registry_counterpart,
       count(*) filter (where s.osm_key is not null and not s.has_same
                          and s.has_unsure)          as undecided,
       count(*) filter (where s.osm_key is not null and not s.has_same
                          and not s.has_unsure)      as none_among_candidates,
       count(*) filter (where s.osm_key is null)     as no_candidates
  from (select (source || ':' || (external_ids->>'record_id')) as osm_key
          from locations where source = 'osm') o
  left join (select osm_key,
                    bool_or(label = 'same')   as has_same,
                    bool_or(label = 'unsure') as has_unsure
               from neighbour_labels group by osm_key) s using (osm_key);

-- Where the OSM records with a registry counterpart ended up, and how many of
-- them carried neither blocking key (a valid phone, or a street number and ZIP).
select o.best,
       count(*) as osm_records,
       count(*) filter (where l.phone_key is null
                          and (l.street_key is null or l.postal_code is null)) as no_blocking_key
  from rd_osm_outcome o
  join locations l on (l.source || ':' || (l.external_ids->>'record_id')) = o.osm_key
 group by o.best
 order by min(case o.best when 'auto_merge' then 1 when 'review' then 2
                          when 'distinct' then 3 else 4 end);

-- 5. How often the two labelling passes agreed, with Cohen's kappa.
with passes as (
  select 'pairs' as file, pass1, pass2 from pair_labels
  union all
  select 'neighbours', pass1, pass2 from neighbour_labels
), n as (
  select file, count(*)::numeric as n,
         count(*) filter (where pass1 = pass2)::numeric as agree
    from passes group by file
), marg as (
  select p.file, lbl,
         count(*) filter (where p.pass1 = lbl)::numeric as c1,
         count(*) filter (where p.pass2 = lbl)::numeric as c2
    from passes p
    cross join unnest(array['same', 'different', 'unsure']) lbl
   group by p.file, lbl
), pe as (
  select m.file, sum((m.c1 / n.n) * (m.c2 / n.n)) as pe
    from marg m join n using (file) group by m.file
)
select n.file, n.n::int as rows, n.agree::int as agreed,
       round(n.agree / n.n, 3) as agreement,
       round(((n.agree / n.n) - pe.pe) / (1 - pe.pe), 3) as kappa
  from n join pe using (file)
 order by n.file desc;

-- 6. The figures realdata/README.md publishes. If the data, the labels or the
--    pipeline change, this fails and the README has to be updated with them.
do $$
declare
  got text;
begin
  select string_agg(format('%s=%s', k, v), ' ' order by k collate "C") into got from (
    select 'rows' as k, count(*)::text as v from locations
    union all select 'pairs', count(*)::text from rd_pairs
    union all
    select 'band_' || p.verdict,
           format('%s/%s/%s/%s/%s', count(*), count(l.pair_key),
                  count(*) filter (where l.label = 'same'),
                  count(*) filter (where l.label = 'different'),
                  count(*) filter (where l.label = 'unsure'))
      from rd_pairs p left join pair_labels l using (pair_key)
     group by p.verdict
    union all
    select 'osm_outcome_' || replace(o.best, ' ', '_'),
           format('%s/%s', count(*),
                  count(*) filter (where l.phone_key is null
                                     and (l.street_key is null or l.postal_code is null)))
      from rd_osm_outcome o
      join locations l on (l.source || ':' || (l.external_ids->>'record_id')) = o.osm_key
     group by o.best
    union all
    select 'agree_pairs', count(*) filter (where pass1 = pass2)::text from pair_labels
    union all
    select 'agree_neighbours', count(*) filter (where pass1 = pass2)::text from neighbour_labels
  ) f;

  if got is distinct from
     'agree_neighbours=691 agree_pairs=345 band_auto_merge=44/44/43/1/0 '
     'band_distinct=770/60/17/42/1 band_review=246/246/108/138/0 '
     'osm_outcome_auto_merge=12/0 osm_outcome_distinct=61/0 '
     'osm_outcome_not_paired=51/47 osm_outcome_review=32/0 pairs=1060 rows=1419'
  then
    raise exception 'real-data figures changed: %', got;
  end if;
end $$;
