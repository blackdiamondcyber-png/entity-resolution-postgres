-- Candidate generation. Only records sharing a blocking key get compared.
create or replace view candidate_pairs as
select distinct a_id, b_id, block from (
  select a.id as a_id, b.id as b_id, 'phone'::text as block
    from locations a
    join locations b on a.phone_key = b.phone_key and a.id < b.id
   where a.phone_key is not null
     and a.merged_into is null and b.merged_into is null
  union all
  select a.id, b.id, 'address'::text
    from locations a
    join locations b
      on a.postal_code = b.postal_code
     and a.street_key  = b.street_key
     and a.id < b.id
   where a.street_key is not null and a.postal_code is not null
     and a.merged_into is null and b.merged_into is null
) u;
