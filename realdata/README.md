# Real data: Twin Cities dental practices

The benchmarks in the main README use generated rows. They show how much work
blocking saves and how fast scoring runs, but a generated typo is not a real
one, so they cannot say how often real records fool the scorer. This folder
runs the pipeline on two public sources that describe the same dental
practices in different words, then scores the output against labelled pairs.

It has been run twice. The first run, at commit
[`ee2e579`](https://github.com/blackdiamondcyber-png/entity-resolution-postgres/tree/ee2e579/realdata),
found four ways real records beat the scorer. The pipeline now has a fix for
each, and this page shows both runs.

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

Loaded together that is 1,419 rows and 1,006,071 possible pairs. Blocking now
keeps 1,181 of them (1,060 before the fixes), and the scorer splits those into
79 auto-merges, 354 for review and 748 left distinct.

## How the pairs were labelled

A label answers one question: are these two records the same dental practice
at the same site? The rules are in `labels/RULES.md`, written before any pair
was labelled. The labelling files carry no score, verdict or blocking key, and
their rows are shuffled so the three bands are mixed together.

Three sets were labelled:

- **Pairs, round 1** (`labels/pair_labels.csv`, from `to_label_blind.csv`):
  every auto-merge and review pair from the first run, plus the 60 distinct
  pairs with the lowest `md5(pair_key)`, 350 in all.
- **Pairs, round 2** (`labels/pair_labels_round2.csv`, from
  `round2_blind.csv`): the 124 pairs the fixed pipeline sent to auto-merge,
  review or the distinct sample that no label covered yet. The other pairs it
  needed already had a label from round 1 or from the recall set.
- **Recall** (`labels/neighbour_labels.csv`): for each OSM record, every registry
  record that could be the same practice whether or not blocking paired them.
  That means anything within 300 m, plus, within 2 km, anything with the same
  phone or a name or DBA name with trigram similarity of 0.5 or more. That gives
  718 rows covering 240 of the 269 OSM records. It was not relabelled, so it
  measures both runs against the same truth.

No person labelled these. Two model passes labelled every row independently:
Claude Opus 5.5 first, then Claude Sonnet 5 working from the rules alone,
without seeing the first pass. They agreed on 345 of 350 round-1 pairs (Cohen's
kappa 0.972), 116 of 124 round-2 pairs (kappa 0.828) and 691 of 718 recall rows
(kappa 0.909). Round 2 agrees less because the fixes surfaced mostly the
hardest case in the rules: two brands in one building that share a phone.
Where the passes split, the split was settled against the rule text, and the
reason is written next to the label. Where a pair has a label in both a pair
file and the recall file (57 pairs), the two agree, and CI fails if they ever
stop agreeing. Every label, both passes and every reason are in the CSVs, so
any one of them can be checked or overruled, and CI recomputes each figure
below from those files.

## What changed in the pipeline

Each fix answers one finding from the first run.

| First-run finding                                                                                                               | Fix                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The scorer read legal names only. NORTHLAND DENTAL PARTNERS, PLLC scored 0.204 against the OSM record for its own trading name. | Every row carries `other_names` (NPPES DBA names, OSM `alt_name` and `official_name`), and the name term is the best trigram similarity across every name on each side.                      |
| 97 of the 138 wrong review pairs were one brand's sites more than a kilometre apart, pulled in by a central booking line.       | A shared phone counts only when the two records are within 1 km of each other, or when either one has no coordinates.                                                                        |
| A shared address, phone and 0 m left CITY OF LAKES DENTAL, P.A. and DJCM PLLC at 0.577, just under review.                      | Below 0.60, a pair still goes to review when phone, street number and ZIP all agree and the records are within 50 m or unplaced ("keys agree").                                              |
| 47 OSM records with a registry match carried no phone and no street number, so no block could reach them.                       | A third block pairs records within 150 m whose names reach a trigram similarity of 0.3, and a pair within 150 m at 0.5 or more goes to review even when it scores under 0.60 ("same place"). |

I chose every rule and threshold above after reading the round-1 labels, and
the second run is measured on the same records. It shows the fixes do what
they were built to do on this data. It is not an estimate of how they do on
data they were not fitted to; a second metro with fresh labels would be that
test.

## Before and after

| Measure                                                        | First run (`ee2e579`)     | Now                      |
| -------------------------------------------------------------- | ------------------------- | ------------------------ |
| Candidate pairs                                                | 1,060                     | 1,181                    |
| Auto-merges that are the same practice                         | 43 of 44                  | 78 of 79                 |
| Review pairs that are the same practice                        | 108 of 246 (44%)          | 277 of 354 (78%)         |
| Sampled distinct pairs that are the same practice              | 17 of 59 decided (29%)    | 5 of 59 decided (8%)     |
| Real duplicates left among distinct pairs, 95% Wilson interval | roughly 145 to 320 of 770 | roughly 27 to 137 of 748 |
| OSM dentists with a registry match that were auto-merged       | 12 of 156                 | 19 of 156                |
| OSM dentists with a registry match sent to review              | 32 of 156                 | 114 of 156               |
| OSM dentists with a registry match scored distinct             | 61 of 156                 | 20 of 156                |
| OSM dentists with a registry match that were never compared    | 51 of 156                 | 3 of 156                 |

No pair labelled the same practice moved down a band. The 35 new auto-merges
came up from review (17) and distinct (18), and every one is labelled the same
practice. All 97 of the far-apart chain pairs that filled the first run's
review queue now score distinct. The three pairs the first run used as
examples all reach review: Metro Dentalcare Woodbury on its trading name
(0.204 then, 0.600 now), CITY OF LAKES DENTAL, P.A. and DJCM PLLC because their
keys agree, and SUMMIT DENTAL P.A. and Summit Dental Care as the same place.

## What each band holds now

| Band       | Sent there by                             | Pairs | Same practice | Different | Unsure |
| ---------- | ----------------------------------------- | ----- | ------------- | --------- | ------ |
| Auto-merge | score of 0.85 or more                     | 79    | 78            | 1         | 0      |
| Review     | score of 0.60 to 0.85                     | 190   | 144           | 46        | 0      |
| Review     | keys agree                                | 49    | 47            | 2         | 0      |
| Review     | same place                                | 115   | 86            | 29        | 0      |
| Distinct   | everything else (60 sampled and labelled) | 748   | 5             | 54        | 1      |

**Auto-merge: 78 of 79.** The wrong one is the same pair as in the first run:
FAMILY PERIODONTIC SPECIALISTS, PLC and FAMILY ORTHODONTIC SPECIALISTS, PLC, two
specialty practices in one Richfield building that share their group's booking
line. The legal names differ by one word, and with the phone, the street
number and 0 m between them the pair scores 0.876.

**Review: 277 of 354.** Of the 77 that are not the same practice, 36 are two
sites of one multi-site practice or group where a registry record has no
coordinates. The 1 km limit cannot apply without a distance, so the shared
phone still counts. Another 39 are different practices or different sites
within a kilometre of each other, 29 sent by the same-place rule and 10 by
score. Most are two brands in one building: a periodontist and an orthodontist
whose legal names differ by one word, which the rules call different. The
last 2 are two brands at one address that share one phone.

**Distinct: 5 of the 59 decided sample pairs are the same practice** (8%, 95%
Wilson interval 3.7% to 18.4%). Two are a dentist's own corporation on one side
and the practice name on the other, one is a shortened name ("Gentle
Dentistry"), one is a near-exact name whose registry geocode landed 319 m from the
map point and scored 0.598, and one is the two-brands-one-suite case under
Limits.

## Across sources

Of the 269 OSM dentists, 156 have a registry record for the same practice at
the same site. Another 11 are undecided, 73 had candidates that were all
different practices, and 29 had no candidate at all. For the 156, the best any
of their true pairs did is in the last four rows of the table above: 133 now
reach an auto-merge or a person, against 44 in the first run. 40 of those 133
carry neither a valid phone nor a street number with a ZIP, so only the nearby
block reaches them.

Of the 23 still missed, 20 are compared and scored distinct. In 11 of them the
registry holds a dentist's own name or corporation (DR TERRANCE J SPAHL) and
the map holds the practice name (Spahl Dentistry), and the names score too low
to link. The rest are shortened or different trading names, a misspelling, and
geocodes that landed far from the map point. The other 3 are never compared: one registry record
has no coordinates, one is 203 m from the map point, and one pairs Pierce
Dental Care with BRIAN L. PIERCE, D.D.S., P.A., below the 0.3 name floor.

## What I would change next

- For a record with no coordinates, count a shared phone only when the street
  number and ZIP agree too. That targets the 36 chain pairs still in review,
  but it was found on these labels, so it should be measured on new ones.
- Label a second metro before tuning anything further. Every figure on this
  page is now in-sample.

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

The first-run figures come from the same commands at commit `ee2e579`.
Refetching with `fetch_nppes.py`, `fetch_osm.py` and `geocode.py` (Python
3.12, standard library only) pulls today's data, which will no longer match
the labels.

## Limits

- One metro, one profession, one day's snapshot.
- Model labels, as described above, not hand labels.
- The fixes were fitted to the first run's labels, so the second run is
  in-sample.
- The distinct band is a 60-pair sample, hence the wide interval.
- Recall covers OSM records only, and only counterparts inside the 300 m, phone
  and name net. A registry record outside that net counts as no counterpart,
  and 29 OSM records had no candidate at all.
- Two brands sharing one suite and one phone are the hardest call under rule
  2c, and the labels are not fully consistent on it. Woodlake Orthodontics and
  Metro Dentalcare at 4959 Excelsior Blvd are labelled different as two
  registry records, and the Woodlake record is labelled the same practice as
  the map's Metro Dentalcare pin.
- A practice that moved and left its old address in the registry is labelled
  different under rule 1. That is right for a map pin, but some OSM records
  counted without a counterpart are really stale registry rows.
