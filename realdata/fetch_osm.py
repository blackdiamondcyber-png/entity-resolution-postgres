"""Fetch dentist features from OpenStreetMap (via Overpass API) for the
seven-county Twin Cities metro (Anoka, Carver, Dakota, Hennepin, Ramsey,
Scott and Washington counties, Minnesota), and write
realdata/data/osm_dentists_msp.csv plus realdata/data/OSM-NOTICE.md.

Source: Overpass API (overpass-api.de), data (c) OpenStreetMap contributors,
available under the Open Database License (ODbL) 1.0.

The seven admin_level=6 county relations are selected by Wikidata QID,
because county names repeat across states (there is a Washington County in
about thirty of them). Each QID was checked live against Overpass: all
seven relations carry Minnesota FIPS codes 27003, 27019, 27037, 27053,
27123, 27139 and 27163.
"""

import csv
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = (
    "entity-resolution-postgres realdata fetch "
    "(github.com/blackdiamondcyber-png/entity-resolution-postgres)"
)
MAX_RETRIES = 5

# Anoka, Carver, Dakota, Hennepin, Ramsey, Scott, Washington.
COUNTY_WIKIDATA = [
    "Q110495", "Q113275", "Q111694", "Q486229", "Q491201", "Q491256", "Q485408",
]

QUERY = f"""
[out:json][timeout:180];
relation["boundary"="administrative"]["admin_level"="6"]["wikidata"~"^({"|".join(COUNTY_WIKIDATA)})$"]->.counties;
.counties map_to_area -> .metro;
(
  node["amenity"="dentist"](area.metro);
  node["healthcare"="dentist"](area.metro);
  way["amenity"="dentist"](area.metro);
  way["healthcare"="dentist"](area.metro);
);
out center tags;
""".strip()

DATA_DIR = Path(__file__).resolve().parent / "data"
OUT_PATH = DATA_DIR / "osm_dentists_msp.csv"
NOTICE_PATH = DATA_DIR / "OSM-NOTICE.md"

FIELDNAMES = [
    "source", "record_id", "name", "other_names", "address", "city",
    "state", "postal_code", "phone", "latitude", "longitude",
]


def fetch_overpass(attempt=0):
    body = urllib.parse.urlencode({"data": QUERY}).encode("utf-8")
    req = urllib.request.Request(
        OVERPASS_URL, data=body, headers={"User-Agent": USER_AGENT}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=200) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if (e.code == 429 or e.code >= 500) and attempt < MAX_RETRIES:
            wait = 2 ** attempt
            print(f"  HTTP {e.code} from Overpass, retrying in {wait}s")
            time.sleep(wait)
            return fetch_overpass(attempt + 1)
        raise
    except urllib.error.URLError as e:
        if attempt < MAX_RETRIES:
            wait = 2 ** attempt
            print(f"  network error from Overpass ({e}), retrying in {wait}s")
            time.sleep(wait)
            return fetch_overpass(attempt + 1)
        raise


def postal5(tags):
    pc = (tags.get("addr:postcode") or "").strip()
    digits = "".join(ch for ch in pc if ch.isdigit())
    return digits[:5] if digits else ""


def build_address(tags):
    housenumber = (tags.get("addr:housenumber") or "").strip()
    street = (tags.get("addr:street") or "").strip()
    unit = (tags.get("addr:unit") or "").strip()
    if not housenumber:
        return ""
    addr = f"{housenumber} {street}".strip()
    if unit:
        addr = f"{addr}, {unit}"
    return addr


def other_names_joined(tags):
    names = []
    for key in ("alt_name", "official_name"):
        v = (tags.get(key) or "").strip()
        if v:
            names.append(v)
    return "|".join(names)


def row_from_element(el):
    tags = el.get("tags") or {}
    name = (tags.get("name") or "").strip()
    if not name:
        return None

    if el["type"] == "node":
        lat, lon = el.get("lat"), el.get("lon")
    else:
        center = el.get("center") or {}
        lat, lon = center.get("lat"), center.get("lon")

    return {
        "source": "osm",
        "record_id": f"{el['type']}/{el['id']}",
        "name": name,
        "other_names": other_names_joined(tags),
        "address": build_address(tags),
        "city": tags.get("addr:city", ""),
        "state": "MN",
        "postal_code": postal5(tags),
        "phone": tags.get("phone") or tags.get("contact:phone") or "",
        "latitude": lat if lat is not None else "",
        "longitude": lon if lon is not None else "",
    }


def write_notice(extracted_on):
    NOTICE_PATH.write_text(
        "Data (c) OpenStreetMap contributors, available under the Open "
        "Database License 1.0 (https://opendatacommons.org/licenses/odbl/1-0/).\n\n"
        f"Extracted on {extracted_on} with the Overpass query in fetch_osm.py.\n\n"
        "osm_dentists_msp.csv is distributed under the ODbL, separately from "
        "this repository's own MIT licence. So are the files in realdata/labels/ "
        "that carry OpenStreetMap fields (scored_pairs.csv, to_label_blind.csv, "
        "osm_neighbours_blind.csv, pair_labels.csv and neighbour_labels.csv), "
        "which are derived from it.\n",
        encoding="utf-8",
    )


def main():
    print("Querying Overpass API for dentist features in the seven-county metro")
    data = fetch_overpass()
    elements = data.get("elements") or []
    print(f"Overpass returned {len(elements)} features")

    rows = []
    for el in elements:
        row = row_from_element(el)
        if row is not None:
            rows.append(row)

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with OUT_PATH.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDNAMES)
        w.writeheader()
        for row in rows:
            w.writerow(row)

    extracted_on = date.today().isoformat()
    write_notice(extracted_on)

    print(f"Wrote {len(rows)} named-feature rows to {OUT_PATH}")
    print(f"Wrote {NOTICE_PATH}")


if __name__ == "__main__":
    main()
