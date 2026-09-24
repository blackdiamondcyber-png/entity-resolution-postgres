-- Assertions. Raises on first failure. Run on a scratch database.
begin;

do $$
declare s numeric; n int;
begin
  if norm_name('Smith & Sons Dental, PLLC') <> 'smithandsonsdentalpllc' then
    raise exception 'norm_name failed: %', norm_name('Smith & Sons Dental, PLLC');
  end if;
  if norm_street('1420 N. Main St, Suite 200') <> '1420' then
    raise exception 'norm_street failed';
  end if;
  if norm_phone('+1 (512) 267-0142') <> '5122670142' then
    raise exception 'norm_phone failed: %', norm_phone('+1 (512) 267-0142');
  end if;

  -- numbers that look real and are not
  if is_valid_nanp('5125550142')     then raise exception '555-01xx fiction range accepted';   end if;
  if is_valid_nanp('5555555555')     then raise exception 'repdigits accepted';                end if;
  if is_valid_nanp('4115551234')     then raise exception 'N11 area code accepted';            end if;
  if is_valid_nanp('1234567890')     then raise exception 'sequential accepted';               end if;
  if is_valid_nanp('0125551234')     then raise exception 'area code starting 0 accepted';     end if;
  if not is_valid_nanp('5122670142') then raise exception 'valid number rejected';             end if;

  -- three sources, one business
  insert into locations (source, name, address, postal_code, phone, latitude, longitude) values
    ('registry', 'SMITH FAMILY DENTAL PLLC', '1420 N Main St Ste 200',  '78701', '5122670142',  30.2700, -97.7400),
    ('places',   'Smith Family Dental',      '1420 North Main Street',  '78701', '512-267-0142',30.2700, -97.7400),
    ('rep',      'Smith Family Dentistry',   '1420 N. Main, Suite 200', '78701', '5122670142',  30.2701, -97.7401);

  -- a different business at the same street number
  insert into locations (source, name, address, postal_code, phone) values
    ('places', 'Main Street Coffee Roasters', '1420 N Main St Ste 100', '78701', '5122679999');

  select count(*) into n from candidate_pairs;
  if n < 3 then raise exception 'blocking produced too few candidates: %', n; end if;

  -- Four records, so six possible pairs, and every one of them is scored
  -- exactly once however many blocking keys reached it.
  select count(*) into n from scored_pairs;
  if n <> 6 then raise exception 'expected 6 distinct scored pairs, got %', n; end if;

  -- The registry and places rows are the same business written two ways and
  -- merge on their own. The rep's row writes the suite differently and sits a
  -- few metres off, so it scores 0.80 and 0.84 and is held for a human. That
  -- is the point: a fuzzy match is queued, not merged.
  select count(*) into n from scored_pairs where verdict = 'auto_merge';
  if n <> 1 then raise exception 'expected 1 confident duplicate, got %', n; end if;

  select count(*) into n from scored_pairs where verdict = 'review';
  if n <> 2 then raise exception 'expected 2 pairs held for review, got %', n; end if;

  select max(score) into s from scored_pairs sp
    join locations c on c.id in (sp.a_id, sp.b_id)
   where c.name like 'Main Street Coffee%';
  if s is not null and s >= 0.85 then
    raise exception 'coffee shop scored as a merge: %', s;
  end if;

  perform run_auto_merge();

  -- One merge happened, so three records survive: the merged Smith pair, the
  -- rep's row still awaiting a decision, and the coffee shop.
  select count(*) into n from locations where merged_into is null;
  if n <> 3 then raise exception 'expected 3 surviving records, got %', n; end if;

  select count(*) into n from review_queue;
  if n < 1 then raise exception 'review pairs were not queued for a human'; end if;

  raise notice 'all entity resolution assertions passed';
end $$;

-- Survivorship, tested directly against merge_locations rather than through
-- blocking, with fresh fixture rows on a different postal code so nothing
-- here blocks against the fixture above.
do $$
declare
  keep_id uuid; drop_id uuid;
  merged locations;
  n int;
begin
  insert into locations (source, name, address, postal_code, phone, latitude, longitude, external_ids, notes)
  values ('registry', 'Bright Smile Dental', '900 Congress Ave', '20500', '5555555555', null, null,
          '{"npi": "111"}'::jsonb, 'Kept record note')
  returning id into keep_id;

  insert into locations (source, name, address, postal_code, phone, latitude, longitude, external_ids, notes)
  values ('places', 'Bright Smile Dental Associates PLLC', '900 Congress Avenue, Suite 400', '20500',
          '5122670188', 30.5, -97.5, '{"npi": "222", "yelp": "999"}'::jsonb, 'Dropped record note')
  returning id into drop_id;

  perform merge_locations(keep_id, drop_id);

  select * into merged from locations where id = keep_id;

  if merged.name <> 'Bright Smile Dental Associates PLLC' then
    raise exception 'survivorship name failed: the longer name should win, got %', merged.name;
  end if;

  if merged.phone <> '5122670188' then
    raise exception 'survivorship phone failed: a valid phone on the dropped row should beat an invalid one on the kept row, got %', merged.phone;
  end if;

  if merged.latitude <> 30.5 or merged.longitude <> -97.5 then
    raise exception 'survivorship coordinates failed: null coordinates on the kept row should be filled from the dropped row, got % %', merged.latitude, merged.longitude;
  end if;

  if merged.external_ids ->> 'npi' <> '111' then
    raise exception 'survivorship identifiers failed: the kept row should win on a shared key, got %', merged.external_ids ->> 'npi';
  end if;

  if merged.external_ids ->> 'yelp' <> '999' then
    raise exception 'survivorship identifiers failed: the dropped row''s extra key should be added, got %', merged.external_ids;
  end if;

  if merged.notes !~ 'Kept record note' or merged.notes !~ 'Dropped record note' then
    raise exception 'survivorship notes failed: both notes should be concatenated, got %', merged.notes;
  end if;

  if not ('Bright Smile Dental' = any (merged.other_names)) then
    raise exception 'survivorship names failed: the shorter name should be kept in other_names, got %', merged.other_names;
  end if;

  if (select merged_into from locations where id = drop_id) <> keep_id then
    raise exception 'the dropped row should have merged_into set to the kept row';
  end if;

  select count(*) into n from merge_log where kept_id = keep_id and merged_id = drop_id;
  if n <> 1 then
    raise exception 'merge_log should have exactly one row for this pair, got %', n;
  end if;

  raise notice 'all survivorship assertions passed';
end $$;

-- The four ways real registry and map records got past the pipeline (see
-- realdata/README.md), one fixture each, far enough apart in place and postal
-- code that none of them blocks against another.
do $$
declare
  v text;
  r text;
begin
  -- 1. A legal name and a DBA. The map knows only the name on the door.
  insert into locations (source, name, other_names, address, postal_code, phone, latitude, longitude) values
    ('registry', 'NORTHLAND DENTAL PARTNERS, PLLC', array['METRO DENTALCARE WOODBURY'],
     '429 Commerce Dr Ste 400', '10001', '6517312342', 10.0000, 10.0000),
    ('map', 'Metro Dentalcare Woodbury', '{}', '429 Commerce Drive', '10001', null, 10.0001, 10.0001);

  select sp.verdict into v
    from scored_pairs sp
    join locations a on a.id = sp.a_id
    join locations b on b.id = sp.b_id
   where 'Metro Dentalcare Woodbury' in (a.name, b.name);
  if v is distinct from 'review' then
    raise exception 'DBA name should carry the pair to review, got %', v;
  end if;

  -- 2. A chain's central booking line at two sites 20 km apart.
  insert into locations (source, name, address, postal_code, phone, latitude, longitude) values
    ('registry', 'SMILE ORTHODONTICS LLC', '1670 Beam Ave', '10002', '6513517778', 20.0000, 20.0000),
    ('registry', 'SMILE ORTHODONTICS LLC', '2008 Ford Pkwy', '10003', '6513517778', 20.1800, 20.0000);

  select sp.verdict into v
    from scored_pairs sp
    join locations a on a.id = sp.a_id
    join locations b on b.id = sp.b_id
   where a.phone = '6513517778' and b.phone = '6513517778';
  if v is distinct from 'distinct' then
    raise exception 'one phone at two sites 20 km apart should stay distinct, got %', v;
  end if;

  -- 3. Every key agrees and only the names differ, as when a practice is sold.
  insert into locations (source, name, address, postal_code, phone, latitude, longitude) values
    ('registry', 'CITY OF LAKES DENTAL, P.A.', '5524 Nicollet Ave', '10004', '6128231816', 30.0000, 30.0000),
    ('registry', 'DJCM PLLC',                  '5524 Nicollet Ave', '10004', '6128231816', 30.0000, 30.0000);

  select sp.verdict, sp.routed_by into v, r
    from scored_pairs sp
    join locations a on a.id = sp.a_id
    join locations b on b.id = sp.b_id
   where 'DJCM PLLC' in (a.name, b.name);
  if v is distinct from 'review' or r is distinct from 'keys agree' then
    raise exception 'agreeing keys under different names should go to review by keys agree, got % by %', v, r;
  end if;

  -- 4. A map record with no phone or address, 70 m from the registry record.
  insert into locations (source, name, address, postal_code, phone, latitude, longitude) values
    ('registry', 'SUMMIT DENTAL P.A.', '10756 Butternut St NW', '10005', '7637574170', 40.0000, 40.0000),
    ('map',      'Summit Dental Care', null, null, null, 40.0006, 40.0003);

  select sp.verdict, sp.routed_by into v, r
    from scored_pairs sp
    join locations a on a.id = sp.a_id
    join locations b on b.id = sp.b_id
   where 'Summit Dental Care' in (a.name, b.name);
  if v is distinct from 'review' or r is distinct from 'same place' then
    raise exception 'a keyless record 70 m from a similar name should reach review by same place, got % by %', v, r;
  end if;

  raise notice 'all real-data failure mode assertions passed';
end $$;

rollback;
