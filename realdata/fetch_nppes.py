"""Fetch dentist organization records from the NPPES NPI Registry API v2.1
for the Minneapolis and Saint Paul (MSP) metro and write
realdata/data/nppes_dental_orgs_msp.csv.

The study area is the seven-county Twin Cities metro: Anoka, Carver, Dakota,
Hennepin, Ramsey, Scott and Washington. NPPES cannot filter by county, so
this script casts a wider net (every Minnesota location whose ZIP starts
550, 551, 553 or 554, which covers all seven counties plus some outstate
towns) and geocode.py then keeps only the rows that fall inside the seven
counties.

Source: NPPES NPI Registry API (CMS), public domain.
https://npiregistry.cms.hhs.gov/api/?version=2.1

Only organization records (enumeration_type=NPI-2) are requested; no
individual (NPI-1) provider is ever fetched. Only the practice location
data is kept. The "authorized official" fields that NPPES attaches to every
organization record (a named individual's name, credential and phone
number) are never read or written, only the organization name, other
(DBA) names, and the practice location's own phone number.
"""

import csv
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_URL = "https://npiregistry.cms.hhs.gov/api/"
USER_AGENT = (
    "entity-resolution-postgres realdata fetch "
    "(github.com/blackdiamondcyber-png/entity-resolution-postgres)"
)
# NPPES accepts a trailing wildcard on postal_code. Each prefix returns
# fewer than the API's 1,200-result ceiling (skip <= 1000, limit 200).
ZIP_PREFIXES = ["550", "551", "553", "554"]
PAGE_LIMIT = 200
MAX_SKIP = 1000
SLEEP_S = 0.5
MAX_RETRIES = 5

OUT_PATH = Path(__file__).resolve().parent / "data" / "nppes_dental_orgs_msp.csv"

FIELDNAMES = [
    "source", "record_id", "name", "other_names", "address", "city",
    "state", "postal_code", "phone", "taxonomy", "last_updated",
]


def in_net(addr):
    """True for a Minnesota address whose ZIP starts with one of ZIP_PREFIXES."""
    state = (addr.get("state") or "").strip().upper()
    return state == "MN" and postal5(addr)[:3] in ZIP_PREFIXES


def fetch_page(prefix, skip, attempt=0):
    params = {
        "version": "2.1",
        "enumeration_type": "NPI-2",
        "taxonomy_description": "Dentist",
        "state": "MN",
        "postal_code": f"{prefix}*",
        "limit": str(PAGE_LIMIT),
        "skip": str(skip),
    }
    url = API_URL + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if (e.code == 429 or e.code >= 500) and attempt < MAX_RETRIES:
            wait = 2 ** attempt
            print(f"  HTTP {e.code} on postal_code={prefix}* skip={skip}, retrying in {wait}s")
            time.sleep(wait)
            return fetch_page(prefix, skip, attempt + 1)
        raise
    except urllib.error.URLError as e:
        if attempt < MAX_RETRIES:
            wait = 2 ** attempt
            print(f"  network error on postal_code={prefix}* skip={skip} ({e}), retrying in {wait}s")
            time.sleep(wait)
            return fetch_page(prefix, skip, attempt + 1)
        raise


def primary_taxonomy_desc(result):
    for t in result.get("taxonomies") or []:
        if t.get("primary"):
            return t.get("desc")
    return None


def build_address(addr):
    a1 = (addr.get("address_1") or "").strip()
    a2 = (addr.get("address_2") or "").strip()
    return f"{a1}, {a2}" if a2 else a1


def postal5(addr):
    pc = (addr.get("postal_code") or "").strip()
    digits = "".join(ch for ch in pc if ch.isdigit())
    return digits[:5] if digits else ""


def other_names_joined(result):
    names = [
        (n.get("organization_name") or "").strip()
        for n in (result.get("other_names") or [])
    ]
    return "|".join(n for n in names if n)


def rows_from_result(result):
    """Build zero or more CSV rows for one NPPES organization result.

    One row for the LOCATION address, plus one row per practiceLocations
    entry (secondary locations), each dropped if it is outside the ZIP net.
    The county filter happens later, in geocode.py.
    """
    npi = result.get("number")
    basic = result.get("basic") or {}
    name = basic.get("organization_name", "")
    other_names = other_names_joined(result)
    taxonomy = primary_taxonomy_desc(result)
    last_updated = basic.get("last_updated", "")

    out = []

    for addr in result.get("addresses") or []:
        if addr.get("address_purpose") != "LOCATION":
            continue
        if not in_net(addr):
            continue
        out.append({
            "source": "nppes",
            "record_id": npi,
            "name": name,
            "other_names": other_names,
            "address": build_address(addr),
            "city": addr.get("city", ""),
            "state": addr.get("state", ""),
            "postal_code": postal5(addr),
            "phone": addr.get("telephone_number", ""),
            "taxonomy": taxonomy,
            "last_updated": last_updated,
        })

    for i, pl in enumerate(result.get("practiceLocations") or [], start=1):
        if not in_net(pl):
            continue
        out.append({
            "source": "nppes",
            "record_id": f"{npi}-pl{i}",
            "name": name,
            "other_names": other_names,
            "address": build_address(pl),
            "city": pl.get("city", ""),
            "state": pl.get("state", ""),
            "postal_code": postal5(pl),
            "phone": pl.get("telephone_number", ""),
            "taxonomy": taxonomy,
            "last_updated": last_updated,
        })

    return out


def main():
    by_npi = {}
    for prefix in ZIP_PREFIXES:
        skip = 0
        while skip <= MAX_SKIP:
            print(f"Fetching NPPES postal_code={prefix}* skip={skip}")
            data = fetch_page(prefix, skip)
            results = data.get("results") or []
            for r in results:
                npi = r.get("number")
                if npi:
                    by_npi[npi] = r
            time.sleep(SLEEP_S)
            if len(results) < PAGE_LIMIT:
                break
            skip += PAGE_LIMIT
        else:
            raise SystemExit(
                f"postal_code={prefix}* hit the API's result ceiling; split the prefix"
            )

    print(f"Unique NPIs fetched across all ZIP-prefix queries: {len(by_npi)}")

    rows = []
    for r in by_npi.values():
        rows.extend(rows_from_result(r))

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with OUT_PATH.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDNAMES)
        w.writeheader()
        for row in rows:
            w.writerow(row)

    print(f"Wrote {len(rows)} location rows to {OUT_PATH}")


if __name__ == "__main__":
    main()
