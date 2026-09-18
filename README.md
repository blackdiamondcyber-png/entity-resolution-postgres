# Entity Resolution in Postgres

Deduplicating business records that arrive from several sources and never agree
with each other, using nothing but Postgres and pg_trgm.

I merged a federal provider registry, a places API, and hand-entered records
into roughly 22,000 deduplicated business locations. This is the part that made
it work.

## The problem

The same business shows up three times and looks different every time:

| Source | Name | Address | Phone |
|--------|------|---------|-------|
| Registry | SMITH FAMILY DENTAL PLLC | 1420 N Main St Ste 200 | (512) 555-0142 |
| Places API | Smith Family Dental | 1420 North Main Street | 512-555-0142 |
| Rep entry | Smith Family Dentistry | 1420 N. Main, Suite 200 | 5125550142 |

Exact matching finds nothing. Fuzzy matching everything against everything is
O(n²), which at 22,000 records is 242 million comparisons per pass.

## The approach

Three stages: normalize, block, score.

**Normalize** collapses formatting differences into a comparable key. Names lose
punctuation and case. Addresses reduce to the leading street number, which
survives "St" vs "Street" and "Ste 200" vs "Suite 200". Phones reduce to ten
digits with the country code stripped.

**Block** generates candidate pairs cheaply. Two records only get compared if
they share a blocking key: same phone, or same street number in the same postal
code. This turns 242 million comparisons into a few hundred thousand. Blocking
is where the performance lives, and picking the wrong key is how you either miss
matches or fail to reduce the search space at all.

**Score** compares candidates on several fields and sums weighted similarity.
Trigram similarity on names, exact match on normalized phone, distance between
coordinates. A pair above the auto-merge threshold merges. A pair in the middle
band goes to a review queue. Below, it stays separate.

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

| Field | Rule |
|-------|------|
| Name | Longest non-abbreviated form |
| Phone | Most recent valid |
| Coordinates | Highest-precision source |
| Identifiers | Never overwritten, only added |
| Notes | Concatenated, never dropped |

Picking a winning record and discarding the loser loses data. Picking per field
does not.

## Files

| Path | Contents |
|------|----------|
| `sql/01-normalize.sql` | Normalization functions and generated columns |
| `sql/02-blocking.sql` | Candidate pair generation |
| `sql/03-scoring.sql` | Weighted similarity and thresholds |
| `sql/04-merge.sql` | Per-field survivorship and merge log |
| `tests/resolution-tests.sql` | Assertions, including the cases that used to break |

## Running it

Postgres 14+ with `pg_trgm`.

```bash
psql "$DATABASE_URL" -f sql/01-normalize.sql
psql "$DATABASE_URL" -f sql/02-blocking.sql
psql "$DATABASE_URL" -f sql/03-scoring.sql
psql "$DATABASE_URL" -f sql/04-merge.sql
psql "$DATABASE_URL" -f tests/resolution-tests.sql
```

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
