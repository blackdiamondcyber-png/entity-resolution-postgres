-- Normalization. Every function is IMMUTABLE so it can back an index.
create extension if not exists pg_trgm;

-- "Smith & Sons Dental, PLLC" -> "smithandsonsdentalpllc"
create or replace function norm_name(p_name text)
returns text language sql immutable set search_path = public as $$
  select nullif(
    regexp_replace(
      lower(replace(coalesce(p_name,''), '&', ' and ')),
      '[^a-z0-9]', '', 'g'
    ), ''
  );
$$;

-- "1420 N. Main St, Suite 200" -> "1420"
create or replace function norm_street(p_address text)
returns text language sql immutable set search_path = public as $$
  select (regexp_match(coalesce(p_address,''), '^\s*(\d+)'))[1];
$$;

create or replace function norm_phone(p_phone text)
returns text language sql immutable set search_path = public as $$
  select case
    when length(x) = 11 and left(x,1) = '1' then substring(x from 2)
    else x
  end
  from (select regexp_replace(coalesce(p_phone,''), '\D', '', 'g') as x) s;
$$;

-- Reject numbers that look valid but are not. Placeholders cluster hard
-- and poison blocking if they get through.
create or replace function is_valid_nanp(p_phone text)
returns boolean language sql immutable set search_path = public as $$
  with d as (select norm_phone(p_phone) as x)
  select
    x ~ '^\d{10}$'
    and substring(x from 1 for 1) between '2' and '9'
    and substring(x from 2 for 2) <> '11'
    and substring(x from 4 for 1) between '2' and '9'
    and substring(x from 5 for 2) <> '11'
    and not (substring(x from 4 for 3) = '555'
             and substring(x from 7 for 4) between '0100' and '0199')
    and x !~ '^(\d)\1{9}$'
    and x not in ('1234567890','0123456789')
  from d;
$$;

create table if not exists locations (
  id            uuid primary key default gen_random_uuid(),
  source        text not null,
  name          text,
  address       text,
  postal_code   text,
  phone         text,
  latitude      double precision,
  longitude     double precision,
  external_ids  jsonb not null default '{}'::jsonb,
  notes         text,
  merged_into   uuid references locations(id),
  created_at    timestamptz not null default now(),
  name_key      text generated always as (norm_name(name))      stored,
  street_key    text generated always as (norm_street(address))  stored,
  phone_key     text generated always as (
                  case when is_valid_nanp(phone) then norm_phone(phone) end
                ) stored
);

create index if not exists loc_name_trgm  on locations using gin (name gin_trgm_ops);
create index if not exists loc_phone_idx  on locations (phone_key) where phone_key is not null;
create index if not exists loc_block_idx  on locations (postal_code, street_key);
