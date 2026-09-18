-- Per-field survivorship. Merging by picking a winning row loses data.
create table if not exists merge_log (
  id bigserial primary key,
  kept_id uuid not null, merged_id uuid not null,
  score numeric, block text,
  merged_at timestamptz not null default now()
);

create or replace function merge_locations(p_keep uuid, p_drop uuid, p_score numeric default null, p_block text default null)
returns void language plpgsql set search_path = public as $$
declare k locations; d locations;
begin
  select * into k from locations where id = p_keep and merged_into is null;
  select * into d from locations where id = p_drop and merged_into is null;
  if k.id is null or d.id is null then
    raise exception 'one or both records missing or already merged';
  end if;

  update locations set
    name    = case when length(coalesce(d.name,''))    > length(coalesce(k.name,''))    then d.name    else k.name    end,
    address = case when length(coalesce(d.address,'')) > length(coalesce(k.address,'')) then d.address else k.address end,
    phone   = coalesce(case when is_valid_nanp(k.phone) then k.phone end, d.phone, k.phone),
    latitude  = coalesce(k.latitude,  d.latitude),
    longitude = coalesce(k.longitude, d.longitude),
    external_ids = k.external_ids || d.external_ids,
    notes = nullif(concat_ws(E'\n', nullif(k.notes,''), nullif(d.notes,'')), '')
  where id = p_keep;

  update locations set merged_into = p_keep where id = p_drop;
  insert into merge_log (kept_id, merged_id, score, block) values (p_keep, p_drop, p_score, p_block);
end $$;

-- Where a record ended up. Merging is transitive: if B was merged into A and
-- the next pair names B, the work belongs to A. Without this, a business seen
-- by three sources merges once and leaves the third row behind as a duplicate.
create or replace function merge_root(p_id uuid)
returns uuid language sql stable set search_path = public as $$
  with recursive up(id, parent) as (
    select l.id, l.merged_into from locations l where l.id = p_id
    union all
    select l.id, l.merged_into from locations l join up on l.id = up.parent
  )
  select id from up where parent is null;
$$;

create or replace function run_auto_merge()
returns int language plpgsql set search_path = public as $$
declare r record; n int := 0; keep uuid; drop_ uuid;
begin
  for r in select * from scored_pairs where verdict = 'auto_merge' loop
    keep  := merge_root(r.a_id);
    drop_ := merge_root(r.b_id);

    -- Already the same record, or one side has gone: nothing left to do. This
    -- is the only case worth skipping, so anything else still raises rather
    -- than disappearing into a catch-all.
    if keep is null or drop_ is null or keep = drop_ then
      continue;
    end if;

    perform merge_locations(keep, drop_, r.score, r.block);
    n := n + 1;
  end loop;
  insert into review_queue (a_id, b_id, score)
  select a_id, b_id, score from scored_pairs where verdict = 'review'
  on conflict do nothing;
  return n;
end $$;
