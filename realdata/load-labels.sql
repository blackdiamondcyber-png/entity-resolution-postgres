-- Load the hand labels (see realdata/labels/RULES.md) next to the scored data.
--
-- Run after realdata/load.sql, from the repo root:
--   psql "$DATABASE_URL" -f realdata/load-labels.sql
-- realdata/run_local.mjs creates the same two tables and fills them from
-- Node instead, because PGlite has no \copy.

create table if not exists pair_labels (
  pair_key  text primary key,
  pass1     text not null,
  pass2     text not null,
  label     text not null check (label in ('same', 'different', 'unsure')),
  reason    text not null
);

create table if not exists neighbour_labels (
  osm_key    text not null,
  nppes_key  text not null,
  pass1      text not null,
  pass2      text not null,
  label      text not null check (label in ('same', 'different', 'unsure')),
  reason     text not null,
  primary key (osm_key, nppes_key)
);

\copy pair_labels from 'realdata/labels/pair_labels.csv' with (format csv, header true)
\copy neighbour_labels from 'realdata/labels/neighbour_labels.csv' with (format csv, header true)
