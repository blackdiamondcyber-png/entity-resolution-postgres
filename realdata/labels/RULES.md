# Labelling rules

Every label in this folder answers one question about two records: do they
describe the same dental practice at the same physical site? That is the
entity this repo resolves, one pin per practice location, so two legal
entities that run one practice at one address are one location, and one brand
at two addresses is two.

Labels are `same`, `different` or `unsure`. Each comes with a short reason.

## What the labeller sees

Only the fields in the file: source, record id, name, other names (NPPES DBA
names, OSM `alt_name` and `official_name`), address, ZIP, phone, and the
distance between the two records' coordinates. The labelling files carry no
score, verdict or blocking key, and rows are shuffled so the three bands are
mixed together. Nothing is looked up outside the file.

## 1. Same site

Two records are at the same site when their addresses name the same building:
the same street number on the same street, ignoring suite or unit, directional
and suffix spelling ("Ave" and "Avenue", "N" and "North"), and the same ZIP or a
missing ZIP on one side.

- A different street number on the same street is a different site, unless it
  is plainly a typo (one digit changed or two transposed) and the name and
  phone agree. Label that `same` and say "street number typo".
- When one side has no street address, which is common in OpenStreetMap, the
  records are at the same site if they are within 150 m of each other and
  nothing in the data contradicts it. Between 150 m and 300 m, a matching name
  or phone is needed as well. Beyond 300 m, a matching name and phone are both
  needed, because a geocode can land on the wrong block but two brands rarely
  share a phone.
- A missing coordinate is not evidence either way.

Two different suites in one building are the same site. Whether they are the
same practice is rule 2.

## 2. Same practice at that site

At the same site, the records are the same practice when any of these holds:

- a. The names match once legal suffixes (PA, P.A., PC, PLLC, LLC, LTD, INC,
  DDS, DMD), case, punctuation and "and" versus "&" are ignored, or one name is
  the other plus a place or specialty qualifier ("Park Dental" and "Park Dental
  Roseville").
- b. One record's name matches one of the other record's other names.
- c. They share a phone number and neither name identifies a different
  business. A dentist's professional corporation ("JOHN SMITH DDS PA") and a
  practice name ("Smith Family Dentistry") with one phone at one address are
  `same`, and so are an old and a new legal entity with one phone at one
  address (a practice sold with its phone number kept).
- d. The same organisation runs both at the site (a clinic system's general
  dentistry and orthodontics under one brand at one address).

They are `different` when the names identify different businesses and neither
a shared phone nor another name links them: two unrelated practices in one
medical building, or a general dentist and an independent specialist sharing
an address.

## 3. Chains and shared phones

One brand at two sites is `different`, even with one phone number, because
chains route every location through a central booking line. A shared phone
never overrides rule 1.

## 4. Unsure

Use `unsure` only when the fields cannot decide it: for example, a record whose
name is only a person's name, 200 m from a practice with a different name and
no phone on either side. Say what is missing.

## 5. The recall file

`osm_neighbours_blind.csv` lists, for each OpenStreetMap record, every
registry record that could be its counterpart: anything within 300 m, and,
within 2 km or where a coordinate is missing, any record with the same phone
or a name or DBA name with trigram similarity of 0.5 or more. Each row gets
the same three labels under the same rules. An OSM record has a registry
counterpart when at least one of its rows is `same`.
