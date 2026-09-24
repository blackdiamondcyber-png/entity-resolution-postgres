-- Load the two real-data CSVs into the repo's own `locations` table.
--
-- Two ways to run this pipeline exist side by side:
--   1. realdata/run_local.mjs reads both CSVs
--      in Node with a small hand-rolled CSV parser and inserts each row with
--      a parameterised `db.query(...)` call against PGlite (no real Postgres
--      server, no psql, no \copy: PGlite has no client/server split to copy
--      across).
--   2. This file (load.sql) is what CI runs with a real `psql` against a
--      real Postgres server: `\copy` streams each CSV straight into a
--      staging table (fast, no per-row round trips), then a single
--      `insert ... select` moves the staged rows into `locations`, building
--      the same `external_ids` jsonb shape run_local.mjs builds in Node.
--
-- Run from the repo root, after sql/01-normalize.sql has already created
-- the `locations` table:
--   psql "$DATABASE_URL" -f realdata/load.sql

begin;

create temporary table stage_nppes (
  source        text,
  record_id     text,
  name          text,
  other_names   text,
  address       text,
  city          text,
  state         text,
  postal_code   text,
  phone         text,
  taxonomy      text,
  last_updated  text,
  latitude      text,
  longitude     text
) on commit drop;

\copy stage_nppes from 'realdata/data/nppes_dental_orgs_msp.csv' with (format csv, header true)

create temporary table stage_osm (
  source        text,
  record_id     text,
  name          text,
  other_names   text,
  address       text,
  city          text,
  state         text,
  postal_code   text,
  phone         text,
  latitude      text,
  longitude     text
) on commit drop;

\copy stage_osm from 'realdata/data/osm_dentists_msp.csv' with (format csv, header true)

insert into locations (source, name, other_names, address, postal_code, phone, latitude, longitude, external_ids)
select
  'nppes',
  nullif(name, ''),
  coalesce(string_to_array(nullif(other_names, ''), '|'), '{}'),
  nullif(address, ''),
  nullif(postal_code, ''),
  nullif(phone, ''),
  nullif(latitude, '')::double precision,
  nullif(longitude, '')::double precision,
  jsonb_build_object('record_id', record_id, 'other_names', nullif(other_names, ''))
from stage_nppes;

insert into locations (source, name, other_names, address, postal_code, phone, latitude, longitude, external_ids)
select
  'osm',
  nullif(name, ''),
  coalesce(string_to_array(nullif(other_names, ''), '|'), '{}'),
  nullif(address, ''),
  nullif(postal_code, ''),
  nullif(phone, ''),
  nullif(latitude, '')::double precision,
  nullif(longitude, '')::double precision,
  jsonb_build_object('record_id', record_id, 'other_names', nullif(other_names, ''))
from stage_osm;

commit;

-- Statistics for the planner. candidate_pairs is written to plan well without
-- them, but a freshly loaded table should be analyzed anyway.
analyze locations;
