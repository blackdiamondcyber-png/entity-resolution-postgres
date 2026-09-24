# Entity Resolution in Postgres

[![tests](https://github.com/blackdiamondcyber-png/entity-resolution-postgres/actions/workflows/ci.yml/badge.svg)](https://github.com/blackdiamondcyber-png/entity-resolution-postgres/actions/workflows/ci.yml)

Deduplicating business records that arrive from several sources and never agree
with each other, using nothing but Postgres and pg_trgm.

I merged a federal provider registry, a places API, and hand-entered records
into 22,772 resolved business locations for the territory map I built and run
at work. This is the part that made it work.

## The problem

The same business shows up three times and looks different every time:

| Source     | Name                     | Address                 | Phone          |
| ---------- | ------------------------ | ----------------------- | -------------- |
| Registry   | SMITH FAMILY DENTAL PLLC | 1420 N Main St Ste 200  | (512) 555-0142 |
| Places API | Smith Family Dental      | 1420 North Main Street  | 512-555-0142   |
| Rep entry  | Smith Family Dentistry   | 1420 N. Main, Suite 200 | 5125550142     |

Exact matching finds nothing. Fuzzy matching everything against everything is
O(n²), which at 22,772 records is about 259 million comparisons per pass.

## The approach

Three stages: normalize, block, score.

**Normalize** collapses formatting differences into a comparable key. Names lose
punctuation and case. Addresses reduce to the leading street number, which
survives "St" vs "Street" and "Ste 200" vs "Suite 200". Phones reduce to ten
digits with the country code stripped.

**Block** generates candidate pairs cheaply. Two records only get compared if
they share a blocking key: same phone, same street number in the same postal
code, or within 150 m of each other with loosely similar names. This turns 259
million comparisons into a few hundred thousand. Blocking is where the
performance lives, and picking the wrong key is how you either miss matches or
fail to reduce the search space at all.

**Score** compares candidates on several fields and sums weighted similarity:
trigram similarity on the best pair of names (legal and trading), exact match on
normalized phone when the two records are within a kilometre, and distance
between coordinates. A pair above the auto-merge threshold merges. A pair in the
middle band goes to a review queue, and so does a lower-scoring pair whose
phone, street number and ZIP all agree, or whose names are similar within
150 m. Everything else stays separate.

## Measured at size

`bench/synthetic.sql` generates a synthetic set of businesses with a known set
of planted duplicates, written differently from their originals the way real
sources disagree, then runs the same blocking and scoring pipeline against it
so recall and precision can be measured against ground truth instead of
assumed. CI runs it on every push.

From the CI run of `bench/synthetic.sql` on `postgres:16`:

| Measure                                       | Result                                                                                            |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Rows                                          | 20,000: 16,000 businesses plus 4,000 planted duplicates written differently                       |
| Pairs a naive comparison would check          | 199,990,000                                                                                       |
| Candidate rows after blocking                 | 7,304, which is 4,104 distinct pairs (many are reached by both the phone key and the address key) |
| Planted duplicates reachable through blocking | 4,000 of 4,000                                                                                    |
| Time to score every candidate pair            | 60 to 83 ms across recent CI runs                                                                 |
| Auto-merged                                   | 3,200, every one a planted duplicate (precision 1.00)                                             |
| Sent to the review queue                      | 800                                                                                               |
| Left distinct                                 | 104                                                                                               |

What that does and does not show. The 800 in review are exactly the one in five planted duplicates whose phone number was dropped. Without a phone match, name, street number and coordinates can score at most 0.70, below the 0.85 auto-merge line, so a duplicate with no phone always goes to a human. That is the threshold doing what it was set to do, not a recall figure for real data. The 104 pairs left distinct are different businesses sharing a street number and ZIP, and none of them merged. Synthetic rows prove the blocking reduction and the speed. `bench/perturbed.sql`, below, shows how synthetic misspellings, abbreviations and mistyped street numbers move through the same pipeline, but a generated typo is not a real one, so neither file can tell you how often an actual spelling difference fools the scorer. The real-data run below measures that.

### With misspellings

`bench/synthetic.sql` never misspells anything, so `bench/perturbed.sql` runs the same 16,000-row base generator and plants 3,000 duplicates across six harder kinds, 500 each: a one-letter typo in the first word of the name, common word abbreviations with the legal suffix dropped, and a mistyped street number, each with and without a kept phone number.

From the CI run of `bench/perturbed.sql` on `postgres:16`:

| Kind                 | Planted | Reached by blocking | Auto-merged | Review | Left distinct or unreached | Median name similarity |
| -------------------- | ------- | ------------------- | ----------- | ------ | -------------------------- | ---------------------- |
| typo                 | 500     | 500                 | 500         | 0      | 0                          | 0.829                  |
| abbrev               | 500     | 500                 | 46          | 454    | 0                          | 0.487                  |
| typo_no_phone        | 500     | 500                 | 0           | 443    | 57                         | 0.829                  |
| abbrev_no_phone      | 500     | 500                 | 0           | 55     | 445                        | 0.500                  |
| street_typo          | 500     | 500                 | 500         | 0      | 0                          | 1.000                  |
| street_typo_no_phone | 500     | 0                   | 0           | 0      | 500                        | 1.000                  |

Overall: 3,000 planted, 1,046 auto-merged, 0 of those auto-merges wrong (precision 1.0000).

How to read it. With a kept phone (+0.30), a matching street number and postal code (+0.15) and coordinates within 50 m (+0.10), a pair starts at 0.55, so the name needs a trigram similarity of only 0.667 to reach the 0.85 auto-merge line. A one-letter typo stays well above that (median 0.829), and all 500 merge. Abbreviations pull the median down to 0.487, so 454 of 500 go to review instead. Without the phone a pair starts at 0.25, and reaching even the 0.60 review floor takes a similarity of 0.778: 443 of 500 typos still make it, but only 55 of 500 abbreviations do, and the rest are left as separate businesses with nobody looking at them. A mistyped street number with no phone is never compared at all. Blocking only pairs records that share a phone, or a street number and postal code, and this kind breaks both, so all 500 are missed before scoring runs. Blocking on name trigrams within a postal code would reach them; it is not in this pipeline.

## On real data

`realdata/` runs the pipeline on two public sources for the Twin Cities metro:
1,150 dental practice locations from the federal NPI registry and 269
OpenStreetMap dentists, scored against 1,135 labelled pairs. The method, the
labelling and the limits are in [realdata/README.md](realdata/README.md), and
CI fails if any of these figures change.

| Measure                                                         | First run  | Now        |
| --------------------------------------------------------------- | ---------- | ---------- |
| Auto-merges that are the same practice                          | 43 of 44   | 78 of 79   |
| Review pairs that are the same practice                         | 108 of 246 | 277 of 354 |
| Sampled distinct pairs that are the same practice               | 17 of 59   | 5 of 59    |
| OSM dentists with a registry match that were auto-merged        | 12 of 156  | 19 of 156  |
| OSM dentists with a registry match that reached merge or review | 44 of 156  | 133 of 156 |
| OSM dentists with a registry match that were never compared     | 51 of 156  | 3 of 156   |

The first run showed the auto-merge line holding and recall failing. The
scorer ignored the trading names the registry keeps beside legal names, a
chain's central phone number filled the review queue with its own sites, and a
third of the OpenStreetMap records had nothing to block on. The pipeline now
scores every name, counts a phone only within a kilometre, blocks on
proximity, and sends pairs whose keys agree to review. I tuned those fixes on
these labels, so the second column is in-sample, and a second metro is the
real test. The labels come from two independent model passes (Cohen's kappa
0.97 and 0.83 on the two rounds of pairs, 0.91 on the recall set), not from a
person, and every label and reason is in the repo.

## Why blocking on street number works

The obvious blocking key is the full address, which fails because address
formatting is exactly what varies. The leading integer is the most stable token
in a street address: it survives abbreviation, suite formatting, directionals,
and most typos. Paired with postal code it is selective enough to be useful and
loose enough to catch real matches.

It does collide in dense areas. Four businesses at 1420 in the same ZIP all
become candidates, which is fine, because scoring resolves them.

## Phone validation is worth doing properly

A phone number is the single highest-signal field for matching, so a bad one
poisons the results. `is_valid_nanp` rejects the numbers that look real and are
not:

- Area code or exchange starting with 0 or 1
- N11 codes like 411 and 911
- The 555-0100 through 555-0199 range, reserved for fiction
- Repdigits (5555555555) and sequential runs
- Country code 1 stripped before comparison

Placeholder numbers cluster hard. If you skip this, every record with
5555555555 blocks together and scores as a match.

## Survivorship

When two records merge, which value wins? The rule here is per-field, not
per-record:

| Field       | Rule                                                                   |
| ----------- | ---------------------------------------------------------------------- |
| Name        | Longer of the two                                                      |
| Other names | Union of both records' other names, plus the name that lost            |
| Address     | Longer of the two                                                      |
| Phone       | First valid number, kept record first, falling back to whatever exists |
| Coordinates | Kept record's, filled from the merged record when missing              |
| Identifiers | Union; kept record wins on a shared key, never overwritten             |
| Notes       | Both, concatenated, never dropped                                      |

Picking a winning record and discarding the loser loses data. Picking per field
does not.

## Files

| Path                         | Contents                                                                                      |
| ---------------------------- | --------------------------------------------------------------------------------------------- |
| `sql/01-normalize.sql`       | Normalization functions and generated columns                                                 |
| `sql/02-blocking.sql`        | Candidate pair generation                                                                     |
| `sql/03-scoring.sql`         | Weighted similarity and thresholds                                                            |
| `sql/04-merge.sql`           | Per-field survivorship and merge log                                                          |
| `bench/synthetic.sql`        | Synthetic benchmark measuring blocking and scoring at size                                    |
| `bench/perturbed.sql`        | Benchmark measuring the same pipeline against misspelled, abbreviated and mistyped duplicates |
| `tests/resolution-tests.sql` | Assertions, including the cases that used to break                                            |
| `realdata/`                  | Real-data run: fetch scripts, the data snapshot, labels, and the figures CI checks            |

## Running it

Postgres 14+ with `pg_trgm`.

```bash
psql "$DATABASE_URL" -f sql/01-normalize.sql
psql "$DATABASE_URL" -f sql/02-blocking.sql
psql "$DATABASE_URL" -f sql/03-scoring.sql
psql "$DATABASE_URL" -f sql/04-merge.sql
psql "$DATABASE_URL" -f tests/resolution-tests.sql
```

The test file raises on the first failed assertion. CI runs this sequence,
then both benchmarks and the real-data check in `realdata/`, against
`postgres:16` on every push.

## What I would do differently

Normalization functions must be `IMMUTABLE` to be indexable. I wrote one as
`STABLE` at first, then wondered why the index was never used.

Keep the review band. The temptation is to tune thresholds until everything
auto-decides. Real data has ambiguous pairs, and a human queue for the
middle 3% beats a wrong automatic answer.

Log every merge with the score that caused it. When someone asks why two
locations became one, you need the answer.

## License

MIT.

More of my work: [erik-pearson-portfolio.vercel.app](https://erik-pearson-portfolio.vercel.app). Contact: [LinkedIn](https://www.linkedin.com/in/erikpearson2).
