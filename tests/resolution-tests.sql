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

  select count(*) into n from scored_pairs where verdict = 'auto_merge';
  if n < 2 then raise exception 'expected duplicates to auto-merge, got %', n; end if;

  select max(score) into s from scored_pairs sp
    join locations c on c.id in (sp.a_id, sp.b_id)
   where c.name like 'Main Street Coffee%';
  if s is not null and s >= 0.85 then
    raise exception 'coffee shop scored as a merge: %', s;
  end if;

  perform run_auto_merge();
  select count(*) into n from locations where merged_into is null;
  if n <> 2 then raise exception 'expected 2 surviving records, got %', n; end if;

  raise notice 'all entity resolution assertions passed';
end $$;

rollback;
