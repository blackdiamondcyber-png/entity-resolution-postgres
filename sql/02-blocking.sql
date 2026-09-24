-- Candidate generation. Only records sharing a blocking key get compared.
--
-- phone:   the same valid phone number.
-- address: the same street number in the same postal code.
-- nearby:  within 150 m of each other with a name similarity of 0.3 or more.
--          This reaches the records the other two cannot: a map listing with
--          no phone and no address, or a mistyped street number with no phone.
--
-- The nearby block is a range join, so its plan matters more than the other
-- two. On a freshly loaded table with no statistics, Postgres guesses that
-- `merged_into is null` keeps 0.5% of rows, decides both sides are tiny, and
-- compares every row with every row, 400 million pairs at 20,000 rows. So the join
-- inside the OFFSET 0 fence carries no merged_into filter and no a.id < b.id
-- (either one would pull the primary key or the bad guess into the plan), and
-- loc_lat_idx narrows each probe to a 150 m band of latitude first. Pairs
-- come out in both orders and the outer filter keeps one.
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
  union all
  select n.a_id, n.b_id, 'nearby'::text
    from (
      select a.id as a_id, b.id as b_id,
             a.merged_into as a_merged, b.merged_into as b_merged
        from locations a
        join locations b
          on b.latitude between a.latitude - 0.0014 and a.latitude + 0.0014
         and b.id <> a.id
       where a.longitude is not null and b.longitude is not null
         and distance_m(a, b) < 150
         and name_similarity(a, b) >= 0.3
      offset 0
    ) n
   where n.a_id < n.b_id
     and n.a_merged is null and n.b_merged is null
) u;
