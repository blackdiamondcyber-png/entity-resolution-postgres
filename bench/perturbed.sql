-- Perturbed benchmark. bench/synthetic.sql never misspells a planted
-- duplicate: its duplicates differ only by case, punctuation, "St" versus
-- "Street", suite formatting, phone formatting, and a dropped phone. None of
-- that shows how often a genuine typo, an abbreviated word, or a mistyped
-- street number fools the scorer, since none of it touches the letters or
-- digits that carry the match.
--
-- This script reuses the exact same base generator as bench/synthetic.sql
-- (bench_words, the 16,000 base rows with valid NANP phones), then plants
-- 3,000 duplicates split evenly across six harder kinds, 500 each:
--
--   typo                  one edit in the first word of the name, phone kept
--   abbrev                common word abbreviations, legal suffix dropped, phone kept
--   typo_no_phone         same edit as typo, phone dropped
--   abbrev_no_phone       same abbreviation as abbrev, phone dropped
--   street_typo           name unchanged, street number mistyped, phone kept
--   street_typo_no_phone  same street mistype, phone dropped
--
-- Each duplicate gets the same case styling and coordinate jitter as
-- bench/synthetic.sql. It measures, per kind, how many are reached by
-- blocking, how the scorer verdicts them, and how similar the perturbed name
-- still is to the original. This is a measurement, not a test: it asserts
-- nothing about the quality numbers it prints, only that the pipeline is not
-- structurally broken. Wrapped in a transaction that always rolls back, so it
-- leaves nothing behind.

begin;

select setseed(0.42);

create temp table bench_truth (dup_id uuid, base_id uuid, kind text);

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

-- Helpers for the two kinds of misspelling. Both are plain functions rather
-- than inline CTE arithmetic because the edit needs a position, a
-- replacement, and a "did this actually change anything" check, which reads
-- better as a small procedure than as nested CASE expressions.

-- One edit inside the first word of a name: substitute one letter, drop one
-- letter, or swap two adjacent letters, chosen by rn, at a position that is
-- never the first letter of the word. If a swap would land on two identical
-- letters (no visible change), it falls back to a substitution instead, so
-- the edit is never a no-op.
create or replace function bench_typo_name(name_in text, rn int)
returns text language plpgsql immutable as $$
declare
  first_word text := substring(name_in from '^\S+');
  rest text;
  n int;
  pos int;
  mode int;
  letters text := 'abcdefghijklmnopqrstuvwxyz';
  repl_char text;
  new_word text;
begin
  rest := substring(name_in from length(first_word) + 1);
  n := length(first_word);

  if n < 2 then
    return name_in;
  end if;

  mode := rn % 3; -- 0 substitute, 1 drop, 2 swap

  if mode = 2 and n < 3 then
    mode := 0; -- no room for a second letter to swap with
  end if;

  if mode = 2 then
    pos := 2 + (rn % (n - 2)); -- 2..n-1, so pos+1 stays inside the word
    new_word := substring(first_word from 1 for pos - 1)
             || substring(first_word from pos + 1 for 1)
             || substring(first_word from pos for 1)
             || substring(first_word from pos + 2);
    if new_word = first_word then
      mode := 0; -- the two swapped letters were identical; fall back
    end if;
  end if;

  if mode = 0 then
    pos := 2 + (rn % (n - 1)); -- 2..n, never the first letter
    repl_char := substring(letters from 1 + (rn % 26) for 1);
    if lower(substring(first_word from pos for 1)) = repl_char then
      repl_char := substring(letters from 1 + ((rn + 1) % 26) for 1);
    end if;
    new_word := substring(first_word from 1 for pos - 1) || repl_char || substring(first_word from pos + 1);
  elsif mode = 1 then
    pos := 2 + (rn % (n - 1)); -- 2..n, never the first letter
    new_word := substring(first_word from 1 for pos - 1) || substring(first_word from pos + 1);
  end if;

  return new_word || rest;
end;
$$;

-- Mistype a street number: swap the two leading digits when that yields a
-- different number with no leading zero, otherwise increment the last digit
-- by one (mod 10). The fallback always changes the number, so the result
-- always differs from the input.
create or replace function bench_perturb_street_no(n int)
returns int language plpgsql immutable as $$
declare
  s text := n::text;
  len int := length(s);
  d1 text;
  d2 text;
  last_digit int;
begin
  if len >= 2 then
    d1 := substring(s from 1 for 1);
    d2 := substring(s from 2 for 1);
    if d1 <> d2 and d2 <> '0' then
      return (d2 || d1 || substring(s from 3))::int;
    end if;
  end if;

  last_digit := substring(s from len for 1)::int;
  return (substring(s from 1 for len - 1) || (((last_digit + 1) % 10))::text)::int;
end;
$$;

-- Planted duplicates: 3,000 rows sampled from the base set, assigned evenly
-- across the six kinds above by row_number, 500 each. Case styling and
-- coordinate jitter match bench/synthetic.sql for every kind; what differs is
-- the kind-specific edit to the name, the address, and the phone.
with base_sample as (
  select id as base_id, name, address, postal_code, phone, latitude, longitude,
         row_number() over () as rn
  from (
    select * from locations where source = 'synthetic_base'
    order by random() limit 3000
  ) s
),
kinded as (
  select *,
    case (rn % 6)
      when 0 then 'typo'
      when 1 then 'abbrev'
      when 2 then 'typo_no_phone'
      when 3 then 'abbrev_no_phone'
      when 4 then 'street_typo'
      else 'street_typo_no_phone'
    end as kind
  from base_sample
),
cased as (
  select
    base_id, kind, postal_code, phone, latitude, longitude, rn,
    (regexp_match(address, '^(\d+)'))[1] as orig_street_no,
    regexp_replace(address, '^\d+\s+', '') as street_name,
    case (rn % 3)
      when 0 then upper(name)
      when 1 then lower(name)
      else initcap(name)
    end as name_cased
  from kinded
),
-- The name edit itself. typo and typo_no_phone get the one-letter edit;
-- abbrev and abbrev_no_phone get the word abbreviations (the legal-suffix
-- drop happens next, in `suffixed`); the street_typo kinds do not misspell
-- the name at all, so they get exactly the case-plus-punctuation variant
-- bench/synthetic.sql uses for its ordinary duplicates.
named as (
  select
    base_id, kind, postal_code, phone, latitude, longitude, rn, orig_street_no, street_name,
    case
      when kind in ('typo', 'typo_no_phone') then bench_typo_name(name_cased, rn::int)
      when kind in ('abbrev', 'abbrev_no_phone') then
        regexp_replace(
          regexp_replace(
            regexp_replace(
              regexp_replace(
                regexp_replace(
                  regexp_replace(
                    regexp_replace(
                      regexp_replace(
                        regexp_replace(name_cased, '\yDentistry\y', 'Dent', 'gi'),
                      '\yDental\y', 'Dntl', 'gi'),
                    '\yAssociates\y', 'Assoc', 'gi'),
                  '\yFamily\y', 'Fam', 'gi'),
                '\yOrthodontics\y', 'Ortho', 'gi'),
              '\yPediatric\y', 'Peds', 'gi'),
            '\yCosmetic\y', 'Cosm', 'gi'),
          '\yPartners\y', 'Ptnrs', 'gi'),
        '\yGroup\y', 'Grp', 'gi')
      else
        case
          when rn % 2 = 0 then regexp_replace(name_cased, ' ([A-Za-z]+)$', ', \1')
          else name_cased || '.'
        end
    end as v_name_pre
  from cased
),
-- Legal suffixes (PLLC, LLC, Inc, PC) have no abbreviation, so abbrev drops
-- them outright instead. Group and Associates were already turned into Grp
-- and Assoc above, wherever they appeared, so this only ever strips the four
-- pure legal suffixes.
suffixed as (
  select
    base_id, kind, postal_code, phone, latitude, longitude, rn, orig_street_no, street_name,
    case
      when kind in ('abbrev', 'abbrev_no_phone')
        then regexp_replace(v_name_pre, '\s+(PLLC|LLC|Inc|PC)$', '', 'i')
      else v_name_pre
    end as v_name
  from named
),
-- The street_typo kinds mistype the leading street number; every other kind
-- keeps it exactly as generated.
addressed as (
  select
    base_id, kind, postal_code, phone, latitude, longitude, rn, v_name,
    case
      when kind in ('street_typo', 'street_typo_no_phone')
        then bench_perturb_street_no(orig_street_no::int)::text || ' ' || street_name
      else orig_street_no || ' ' || street_name
    end as base_address
  from suffixed
),
variants as (
  select
    base_id, kind, postal_code, v_name, rn,
    replace(replace(base_address, ' St', ' Street'), ' Ave', ' Avenue')
      || case
           when rn % 4 = 0 then ', Suite ' || (100 + (rn % 20))::text
           when rn % 4 = 1 then ' Ste ' || (100 + (rn % 20))::text
           else ''
         end as v_address,
    case
      when kind in ('typo_no_phone', 'abbrev_no_phone', 'street_typo_no_phone') then null
      else regexp_replace(phone, '^(\d{3})(\d{3})(\d{4})$', '(\1) \2-\3')
    end as v_phone,
    latitude  + (random() - 0.5) * 0.00015 as v_latitude,
    longitude + (random() - 0.5) * 0.00015 as v_longitude
  from addressed
),
ins as (
  insert into locations (source, name, address, postal_code, phone, latitude, longitude, external_ids)
  select
    'perturbed_dup', v_name, v_address, postal_code, v_phone, v_latitude, v_longitude,
    jsonb_build_object('bench_base_id', base_id::text, 'bench_kind', kind)
  from variants
  returning id, external_ids
)
insert into bench_truth (dup_id, base_id, kind)
select id, (external_ids ->> 'bench_base_id')::uuid, external_ids ->> 'bench_kind'
from ins;

-- Measure, per kind, how blocking and scoring handle a harder duplicate.
-- Prints one line per kind plus an overall precision line. Asserts nothing
-- about the quality numbers themselves, only that the pipeline is not
-- structurally broken.
do $$
declare
  n_total int;
  n_candidates int;
  n_street_key_collisions int;
  kinds text[] := array['typo', 'abbrev', 'typo_no_phone', 'abbrev_no_phone', 'street_typo', 'street_typo_no_phone'];
  k text;
  v_planted int;
  v_reachable int;
  v_auto int;
  v_review int;
  v_distinct int;
  v_unreached int;
  v_median_sim numeric;
  n_truth int;
  n_auto_total int;
  n_auto_false int;
  n_auto_true int;
  v_precision numeric;
begin
  select count(*) into n_total from locations where source in ('synthetic_base', 'perturbed_dup');
  if n_total = 0 then
    raise exception 'benchmark generated zero rows';
  end if;

  select count(*) into n_candidates from candidate_pairs;
  if n_candidates = 0 then
    raise exception 'blocking produced zero candidate pairs; something is structurally broken';
  end if;

  select count(*) into n_street_key_collisions
  from bench_truth bt
  join locations dup  on dup.id  = bt.dup_id
  join locations base on base.id = bt.base_id
  where bt.kind in ('street_typo', 'street_typo_no_phone')
    and dup.street_key = base.street_key;

  if n_street_key_collisions > 0 then
    raise exception 'street_typo produced % duplicate(s) whose street key still matches the base row', n_street_key_collisions;
  end if;

  foreach k in array kinds loop
    select count(*) into v_planted from bench_truth where kind = k;

    if v_planted = 0 then
      raise exception 'kind % planted zero rows', k;
    end if;

    select count(distinct bt.dup_id) into v_reachable
    from bench_truth bt
    join candidate_pairs cp
      on (cp.a_id = bt.dup_id and cp.b_id = bt.base_id)
      or (cp.a_id = bt.base_id and cp.b_id = bt.dup_id)
    where bt.kind = k;

    select count(*) filter (where sp.verdict = 'auto_merge'),
           count(*) filter (where sp.verdict = 'review'),
           count(*) filter (where sp.verdict = 'distinct')
      into v_auto, v_review, v_distinct
    from bench_truth bt
    join scored_pairs sp
      on (sp.a_id = bt.dup_id and sp.b_id = bt.base_id)
      or (sp.a_id = bt.base_id and sp.b_id = bt.dup_id)
    where bt.kind = k;

    v_unreached := v_planted - v_reachable;

    select round((percentile_cont(0.5) within group (
             order by similarity(dup.name, base.name)::double precision
           ))::numeric, 3)
      into v_median_sim
    from bench_truth bt
    join locations dup  on dup.id  = bt.dup_id
    join locations base on base.id = bt.base_id
    where bt.kind = k;

    raise notice 'kind=% planted=% reachable=% auto_merge=% review=% distinct=% unreached=% median_name_sim=%',
      k, v_planted, v_reachable, v_auto, v_review, v_distinct, v_unreached, v_median_sim;
  end loop;

  select count(*) into n_truth from bench_truth;

  select count(*) into n_auto_total from scored_pairs where verdict = 'auto_merge';

  select count(*) into n_auto_false
  from scored_pairs sp
  where sp.verdict = 'auto_merge'
    and not exists (
      select 1 from bench_truth bt
      where (bt.dup_id = sp.a_id and bt.base_id = sp.b_id)
         or (bt.dup_id = sp.b_id and bt.base_id = sp.a_id)
    );

  n_auto_true := n_auto_total - n_auto_false;
  v_precision := case when n_auto_total = 0 then null else round(n_auto_true::numeric / n_auto_total, 4) end;

  raise notice 'overall planted=% auto_merge_total=% auto_merge_false=% precision=%',
    n_truth, n_auto_total, n_auto_false, v_precision;

  raise notice 'perturbed benchmark complete';
end $$;

rollback;
