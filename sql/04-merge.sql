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

create or replace function run_auto_merge()
returns int language plpgsql set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select * from scored_pairs where verdict = 'auto_merge' loop
    begin
      perform merge_locations(r.a_id, r.b_id, r.score, r.block);
      n := n + 1;
    exception when others then
      continue;
    end;
  end loop;
  insert into review_queue (a_id, b_id, score)
  select a_id, b_id, score from scored_pairs where verdict = 'review'
  on conflict do nothing;
  return n;
end $$;
