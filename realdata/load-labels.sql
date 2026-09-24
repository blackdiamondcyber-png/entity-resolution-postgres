-- Load the labels (see realdata/labels/RULES.md) next to the scored data.
--
-- pair_labels.csv is round 1, labelled against the pipeline as it stood in
-- commit ee2e579. pair_labels_round2.csv holds the pairs the fixed pipeline
-- sent to auto_merge, review or the distinct sample that round 1 had not
-- labelled. Both rounds use the same rules and the same two blind passes.
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
  reason    text not null,
  round     int
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

\copy pair_labels (pair_key, pass1, pass2, label, reason) from 'realdata/labels/pair_labels.csv' with (format csv, header true)
update pair_labels set round = 1 where round is null;
\copy pair_labels (pair_key, pass1, pass2, label, reason) from 'realdata/labels/pair_labels_round2.csv' with (format csv, header true)
update pair_labels set round = 2 where round is null;
\copy neighbour_labels from 'realdata/labels/neighbour_labels.csv' with (format csv, header true)
