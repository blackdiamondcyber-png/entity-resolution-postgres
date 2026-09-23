-- Synthetic benchmark. Generates about 20,000 locations, roughly a fifth of
-- them planted duplicates of the rest with known ground truth in bench_truth,
-- then measures blocking and scoring against that ground truth. This is a
-- measurement, not a test: it does not assert on the quality numbers it
-- prints, only that the pipeline did not come back structurally empty, for
-- example zero candidate pairs. Wrapped in a transaction that always rolls
-- back, so it leaves nothing behind.

begin;

select setseed(0.42);

create temp table bench_truth (dup_id uuid, base_id uuid);

create temp table bench_words as
select
  array['Smith','Golden Gate','Riverside','Blue Ridge','Silver Oak','Maple Grove',
        'Highland','Lakeside','Cedar Point','Northgate','Sunrise','Ironwood',
        'Prairie View','Stonebridge','Willow Creek','Eastside','Westfield',
        'Harborview','Meadowbrook','Crestwood'] as prefixes,
  array['Family Dental','Dental Care','Dental Group','Orthodontics',
        'Pediatric Dentistry','Dental Associates','Smile Center',
        'Dental Partners','Dental Studio','Cosmetic Dentistry'] as middles,
  array['PLLC','LLC','Inc','PC','Group','Associates'] as suffixes,
  array['Main St','Oak Ave','Elm St','2nd Ave','Broadway','Congress Ave',
        'Park Blvd','Highland Dr','Sunset Blvd','River Rd','Church St',
        'Market St','1st St','Washington Ave','Lincoln Blvd'] as streets,
  array(select lpad((10000 + floor(random() * 90000))::int::text, 5, '0')
        from generate_series(1, 200)) as postal_codes;

-- Base entities: about 16,000 distinct businesses with valid NANP phones.
-- The area code and exchange are built digit by digit so every phone passes
-- is_valid_nanp: first digits in 2 to 9, no N11 pattern in the area code or
-- the exchange, and the 555-01xx fiction range avoided. Postal codes come
-- from a pool of only 200, and street numbers range all the way to 9999, so
-- unrelated businesses sometimes land on the same postal code and street
-- number by pure chance, which is what makes blocking recall worth measuring
-- rather than assuming.
with raw as (
  select
    floor(random() * 8)::int + 2 as area1,
    floor(random() * 10)::int as area2,
    floor(random() * 10)::int as area3,
    floor(random() * 8)::int + 2 as exch1,
    floor(random() * 10)::int as exch2,
    floor(random() * 10)::int as exch3,
    floor(random() * 10000)::int as line_no,
    bw.prefixes[1 + floor(random() * array_length(bw.prefixes, 1))::int] as prefix,
    bw.middles[1 + floor(random() * array_length(bw.middles, 1))::int] as middle,
    bw.suffixes[1 + floor(random() * array_length(bw.suffixes, 1))::int] as suffix,
    bw.streets[1 + floor(random() * array_length(bw.streets, 1))::int] as street,
    floor(random() * 9999)::int + 1 as street_no,
    bw.postal_codes[1 + floor(random() * array_length(bw.postal_codes, 1))::int] as postal_code,
    (25 + random() * 24) as latitude,
    (-124 + random() * 57) as longitude
  from generate_series(1, 16000) g
  cross join bench_words bw
),
fixed as (
  select
    prefix, middle, suffix, street, street_no, postal_code, latitude, longitude,
    area1, area2,
    case when area2 = 1 and area3 = 1 then 0 else area3 end as area3,
    exch1, exch2,
    case when exch2 = 1 and exch3 = 1 then 0 else exch3 end as exch3,
    case when exch1 = 5 and exch2 = 5 and exch3 = 5 and line_no between 100 and 199
         then line_no + 200 else line_no end as line_no
  from raw
)
insert into locations (source, name, address, postal_code, phone, latitude, longitude)
select
  'synthetic_base',
  prefix || ' ' || middle || ' ' || suffix,
  street_no || ' ' || street,
  postal_code,
  area1::text || area2::text || area3::text || exch1::text || exch2::text || exch3::text || lpad(line_no::text, 4, '0'),
  latitude,
  longitude
from fixed;

-- Planted duplicates: about 4,000 rows, each a differently written copy of a
-- randomly chosen base row: case changes, "St" to "Street", suite formatting,
-- a punctuation change on the name, phone reformatted with punctuation (or
-- dropped for one in five), and coordinates jittered by a few metres.
-- Ground truth for each pair rides along in external_ids just long enough to
-- reach bench_truth, since RETURNING cannot carry a column that was never
-- inserted.
with base_sample as (
  select id as base_id, name, address, postal_code, phone, latitude, longitude,
         row_number() over () as rn
  from (
    select * from locations where source = 'synthetic_base'
    order by random() limit 4000
  ) s
),
styled as (
  select
    base_id, postal_code, phone, latitude, longitude, rn,
    case (rn % 3)
      when 0 then upper(name)
      when 1 then lower(name)
      else initcap(name)
    end as name_cased,
    replace(replace(address, ' St', ' Street'), ' Ave', ' Avenue')
      || case
           when rn % 4 = 0 then ', Suite ' || (100 + (rn % 20))::text
           when rn % 4 = 1 then ' Ste ' || (100 + (rn % 20))::text
           else ''
         end as v_address
  from base_sample
),
variants as (
  select
    base_id,
    postal_code,
    case
      when rn % 2 = 0 then regexp_replace(name_cased, ' ([A-Za-z]+)$', ', \1')
      else name_cased || '.'
    end as v_name,
    v_address,
    case
      when rn % 5 = 0 then null
      else regexp_replace(phone, '^(\d{3})(\d{3})(\d{4})$', '(\1) \2-\3')
    end as v_phone,
    latitude  + (random() - 0.5) * 0.00015 as v_latitude,
    longitude + (random() - 0.5) * 0.00015 as v_longitude
  from styled
),
ins as (
  insert into locations (source, name, address, postal_code, phone, latitude, longitude, external_ids)
  select
    'synthetic_dup', v_name, v_address, postal_code, v_phone, v_latitude, v_longitude,
    jsonb_build_object('bench_base_id', base_id::text)
  from variants
  returning id, external_ids
)
insert into bench_truth (dup_id, base_id)
select id, (external_ids ->> 'bench_base_id')::uuid
from ins;

-- Measure. Prints with raise notice. Asserts nothing about the quality
-- numbers themselves, only that the pipeline is not structurally broken.
do $$
declare
  n_total int;
  naive_pairs numeric;
  n_candidates int;
  reduction numeric;
  n_truth int;
  n_truth_in_candidates int;
  blocking_recall numeric;
  t0 timestamptz;
  t1 timestamptz;
  n_scored int;
  n_auto int;
  n_review int;
  n_distinct int;
  n_auto_true_positive int;
  auto_precision numeric;
  auto_recall numeric;
begin
  select count(*) into n_total from locations where source in ('synthetic_base', 'synthetic_dup');
  if n_total = 0 then
    raise exception 'benchmark generated zero rows';
  end if;

  naive_pairs := n_total::numeric * (n_total - 1) / 2;

  select count(*) into n_candidates from candidate_pairs;
  if n_candidates = 0 then
    raise exception 'blocking produced zero candidate pairs; something is structurally broken';
  end if;

  reduction := naive_pairs / n_candidates;

  select count(*) into n_truth from bench_truth;

  select count(distinct bt.dup_id) into n_truth_in_candidates
  from bench_truth bt
  join candidate_pairs cp
    on (cp.a_id = bt.dup_id and cp.b_id = bt.base_id)
    or (cp.a_id = bt.base_id and cp.b_id = bt.dup_id);

  blocking_recall := n_truth_in_candidates::numeric / nullif(n_truth, 0);

  t0 := clock_timestamp();
  select count(*) into n_scored from scored_pairs;
  t1 := clock_timestamp();

  select count(*) into n_auto     from scored_pairs where verdict = 'auto_merge';
  select count(*) into n_review   from scored_pairs where verdict = 'review';
  select count(*) into n_distinct from scored_pairs where verdict = 'distinct';

  select count(distinct bt.dup_id) into n_auto_true_positive
  from bench_truth bt
  join scored_pairs sp
    on sp.verdict = 'auto_merge'
   and ((sp.a_id = bt.dup_id and sp.b_id = bt.base_id) or (sp.a_id = bt.base_id and sp.b_id = bt.dup_id));

  auto_precision := case when n_auto = 0 then null else n_auto_true_positive::numeric / n_auto end;
  auto_recall    := case when n_truth = 0 then null else n_auto_true_positive::numeric / n_truth end;

  raise notice 'total rows: %', n_total;
  raise notice 'naive pair count n*(n-1)/2: %', naive_pairs;
  raise notice 'candidate pairs: %', n_candidates;
  raise notice 'reduction factor: % to 1', round(reduction, 1);
  raise notice 'planted duplicates: %', n_truth;
  raise notice 'planted duplicates reachable through blocking: % (blocking recall %)', n_truth_in_candidates, round(blocking_recall, 4);
  raise notice 'scored pairs: % (scoring took %)', n_scored, (t1 - t0);
  raise notice 'verdict counts: auto_merge %, review %, distinct %', n_auto, n_review, n_distinct;
  raise notice 'auto-merge precision against bench_truth: %', round(auto_precision, 4);
  raise notice 'auto-merge recall against bench_truth: %', round(auto_recall, 4);
  raise notice 'synthetic benchmark complete';
end $$;

rollback;
