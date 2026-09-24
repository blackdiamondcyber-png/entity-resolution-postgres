# Real data: Twin Cities dental practices

The benchmarks in the main README use generated rows. They show how much work
blocking saves and how fast scoring runs, but a generated typo is not a real
one, so they cannot say how often real records fool the scorer. This folder
runs the same pipeline, unchanged, on two public sources that describe the same
dental practices in different words. It then scores the output against
labelled pairs.

## The data

| Source                                                                | Rows                                                  | What it holds                                                                                                                                                                                                                                       |
| --------------------------------------------------------------------- | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [NPPES NPI Registry](https://npiregistry.cms.hhs.gov/api-page) (CMS)  | 1,150 practice locations from 1,092 organisation NPIs | Every dental organisation (taxonomy Dentist) with a practice location in the seven-county Twin Cities metro. Legal names, DBA names, address, phone. Public domain.                                                                                 |
| [OpenStreetMap](https://www.openstreetmap.org/copyright) via Overpass | 269 named features                                    | Everything tagged `amenity=dentist` or `healthcare=dentist` in the same seven counties. Names as a mapper typed them: 177 have a street address, 98 a phone, and 89 have neither a phone nor an address with a ZIP. ODbL, see `data/OSM-NOTICE.md`. |

Both were fetched on 24 September 2026. The US Census batch geocoder placed
1,088 of the 1,150 registry locations; OSM features carry their own
coordinates. The seven counties are Anoka, Carver, Dakota, Hennepin, Ramsey,
Scott and Washington. I picked Minnesota because it is outside the territory I
sell in.

Loaded together that is 1,419 rows. Blocking turns the 1,006,071 possible pairs
into 1,060 candidates, and the unchanged scorer splits them into 44
auto-merges, 246 for review and 770 left distinct.

## How the pairs were labelled

A label answers one question: are these two records the same dental practice
at the same site? The rules are in `labels/RULES.md`, written before any pair
was labelled. The labelling files carry no score, verdict or blocking key, and
their rows are shuffled so the three bands are mixed together.

Two sets were labelled:

- **Pairs** (`labels/pair_labels.csv`): all 44 auto-merges, all 246 review pairs,
  and the 60 distinct pairs with the lowest `md5(pair_key)`, 350 in all.
- **Recall** (`labels/neighbour_labels.csv`): for each OSM record, every registry
  record that could be the same practice whether or not blocking paired them.
  That means anything within 300 m, plus, within 2 km, anything with the same
  phone or a name or DBA name with trigram similarity of 0.5 or more. That gives
  718 rows covering 240 of the 269 OSM records.

No person labelled these. Two model passes labelled every row independently:
Claude Opus 5.5 first, then Claude Sonnet 5 working from the rules alone,
without seeing the first pass. They agreed on 345 of 350 pairs (Cohen's kappa
0.972) and on 691 of 718 recall rows (kappa 0.909). Where they split,
the Opus pass settled it against the rule text, and the reason is written
next to the label. Every label, both passes and every reason are in the
CSVs, so any one of them can be checked or overruled, and CI recomputes each
figure below from those files.

## What each band holds

| Band       | Pairs | Labelled | Same practice | Different | Unsure |
| ---------- | ----- | -------- | ------------- | --------- | ------ |
| Auto-merge | 44    | 44       | 43            | 1         | 0      |
| Review     | 246   | 246      | 108           | 138       | 0      |
| Distinct   | 770   | 60       | 17            | 42        | 1      |

**Auto-merge: 43 of 44 correct.** The wrong one is FAMILY PERIODONTIC
SPECIALISTS, PLC and FAMILY ORTHODONTIC SPECIALISTS, PLC: two specialty
practices in one Richfield building that share their group's booking line.
The legal names differ by one word, so name similarity is high, and with the
phone, the street number and 0 m between them the pair scores 0.876. That pair
belongs to the one class the two passes split on: different specialty brands
in one building that share a phone. The rules call those different. Count
all five as the same practice, as the second pass had them, and auto-merge
is 44 of 44.

**Review: 108 of 246 are real duplicates.** 97 of the 138 that are not are one
brand's locations, more than a kilometre apart, that list the same phone. The
phone is worth 0.30 and nothing subtracts for distance, so a chain's name and
its central booking line put every pair of its sites in the queue. One
orthodontic chain lists one number at 12 registry locations, and 53 of the 97
are its pairs alone.

**Distinct: 17 of the 59 decided sample pairs are the same practice** (29%, 95%
Wilson interval 19% to 41%). That puts roughly 145 to 320 real duplicates among
the 770 pairs no one reviews.

## Across sources

Of the 269 OSM dentists, 156 have a registry record for the same practice at
the same site. Another 11 are undecided, 73 had candidates that were all
different practices, and 29 had no candidate at all. For the 156, the best any
of their true pairs did:

| Outcome         | OSM records |
| --------------- | ----------- |
| Auto-merged     | 12          |
| Sent to review  | 32          |
| Scored distinct | 61          |
| Never compared  | 51          |

So the pipeline links 12 of the 156 real cross-source matches on its own and
puts 32 more in front of a person. It compares 61 and scores them distinct,
where no one looks. The other 51 are never compared, and 47 of those carry no
blocking key: no valid phone, and no street number with a ZIP.

## Why the matches are missed

1. **The scorer reads legal names only.** NPPES keeps the trading name in the
   DBA field, which the loader stores in `external_ids` and nothing scores.
   NORTHLAND DENTAL PARTNERS, PLLC trades as Metro Dentalcare Woodbury, and it
   scores 0.204 against the OSM record Metro Dentalcare Woodbury at the same
   address.
2. **Everything but the name agreeing is worth 0.55,** just under the 0.60
   review line. CITY OF LAKES DENTAL, P.A. and DJCM PLLC share an address and a
   phone and are 0 m apart. They score 0.577 and are left distinct.
3. **171 of the 269 OSM records have no phone,** which caps a cross-source
   pair at 0.70, and a geocode more than 50 m from the OSM point costs another
   0.05 to 0.10. SUMMIT DENTAL P.A. and Summit Dental Care, same address and
   76 m apart, score 0.474.
4. **A third of the OSM records have no blocking key at all,** so no amount of
   scoring can reach them.

## What I would change

- Score the best of the name and every DBA name, not the legal name alone.
- Count a phone match only within a kilometre or so, so a chain's central line
  stops filling the review queue.
- Send any pair whose phone, street number, ZIP and coordinates all agree to
  review, whatever the names say.
- Add a third block for records with neither key: within 150 m and a name
  trigram similarity above a low floor.

None of these are in the pipeline yet. The synthetic benchmarks pin its
current behaviour, so each change should be measured against both the
benchmarks and these labels before it lands.

## Reproduce

```bash
# Postgres, as CI runs it, after sql/01 to 04
psql "$DATABASE_URL" -f realdata/load.sql
psql "$DATABASE_URL" -f realdata/load-labels.sql
psql "$DATABASE_URL" -f realdata/metrics.sql
```

`metrics.sql` raises if the labels and the scored pairs stop matching, or if
any figure on this page changes. Without a server, `run_local.mjs` does the
same in [PGlite](https://pglite.dev), which it expects in `PGLITE_DIR`:

```bash
npm install --prefix /tmp/pglite @electric-sql/pglite
PGLITE_DIR=/tmp/pglite/node_modules/@electric-sql/pglite node realdata/run_local.mjs
```

Refetching with `fetch_nppes.py`, `fetch_osm.py` and
`geocode.py` (Python 3.12, standard library only) pulls today's data, which
will no longer match the labels.

## Limits

- One metro, one profession, one day's snapshot.
- Model labels, as described above, not hand labels.
- The distinct band is a 60-pair sample, hence the wide interval.
- Recall covers OSM records only, and only counterparts inside the 300 m, phone
  and name net. A registry record outside that net counts as no counterpart,
  and 29 OSM records had no candidate at all.
- A practice that moved and left its old address in the registry is labelled
  different under rule 1. That is right for a map pin, but some OSM records
  counted without a counterpart are really stale registry rows.
