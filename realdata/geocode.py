"""Add latitude/longitude to realdata/data/nppes_dental_orgs_msp.csv using the
US Census Bureau's batch geocoder (public, free, no API key), and keep only
the rows inside the seven-county Twin Cities metro.

https://geocoding.geo.census.gov/geocoder/geographies/addressbatch

The geographies endpoint returns the county FIPS code with each match, so a
matched row is kept when its county is one of the seven. An unmatched row
has no county, so it is kept when its city is one that matched rows inside
the seven counties also carry, and dropped otherwise. The script prints how
many rows each rule kept and dropped.

OSM rows already carry coordinates from Overpass and are not touched here.
"""

import csv
import io
import time
import urllib.error
import urllib.request
from pathlib import Path

GEOCODER_URL = "https://geocoding.geo.census.gov/geocoder/geographies/addressbatch"
USER_AGENT = (
    "entity-resolution-postgres realdata fetch "
    "(github.com/blackdiamondcyber-png/entity-resolution-postgres)"
)
BENCHMARK = "Public_AR_Current"
VINTAGE = "Current_Current"

# Minnesota (27) county FIPS codes for Anoka, Carver, Dakota, Hennepin,
# Ramsey, Scott and Washington.
METRO_COUNTIES = {"27003", "27019", "27037", "27053", "27123", "27139", "27163"}
MAX_RETRIES = 5
SLEEP_S = 0.5
# Census batch geocoder caps a single request at 10,000 addresses; our set
# (~200) is one request, but this stays batch-safe if the source grows.
BATCH_SIZE = 5000

NPPES_PATH = Path(__file__).resolve().parent / "data" / "nppes_dental_orgs_msp.csv"


def street_for_geocoding(address):
    """The address without the ', suite' part: everything before the first comma."""
    return address.split(",", 1)[0].strip()


def build_batch_csv(rows, start_id=0):
    """id,street,city,state,zip with no header, per the Census batch format."""
    buf = io.StringIO()
    w = csv.writer(buf)
    for i, row in enumerate(rows):
        w.writerow([
            start_id + i,
            street_for_geocoding(row["address"]),
            row["city"],
            row["state"],
            row["postal_code"],
        ])
    return buf.getvalue().encode("utf-8")


def post_multipart(address_file_bytes, attempt=0):
    boundary = "----entityresolutionrealdata"
    parts = []

    def add_field(name, value):
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        parts.append(value.encode() if isinstance(value, str) else value)
        parts.append(b"\r\n")

    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        b'Content-Disposition: form-data; name="addressFile"; filename="addresses.csv"\r\n'
    )
    parts.append(b"Content-Type: text/csv\r\n\r\n")
    parts.append(address_file_bytes)
    parts.append(b"\r\n")

    add_field("benchmark", BENCHMARK)
    add_field("vintage", VINTAGE)

    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)

    req = urllib.request.Request(
        GEOCODER_URL,
        data=body,
        method="POST",
        headers={
            "User-Agent": USER_AGENT,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        if (e.code == 429 or e.code >= 500) and attempt < MAX_RETRIES:
            wait = 2 ** attempt
            print(f"  HTTP {e.code} from Census geocoder, retrying in {wait}s")
            time.sleep(wait)
            return post_multipart(address_file_bytes, attempt + 1)
        raise
    except urllib.error.URLError as e:
        if attempt < MAX_RETRIES:
            wait = 2 ** attempt
            print(f"  network error from Census geocoder ({e}), retrying in {wait}s")
            time.sleep(wait)
            return post_multipart(address_file_bytes, attempt + 1)
        raise


def parse_response(text):
    """Returns {id: (lat, lon, county_fips) or None} keyed by batch row id.

    Geographies rows are: id, input address, Match/No_Match/Tie, match type,
    matched address, "lon,lat", TIGER line id, side, state FIPS, county FIPS,
    tract, block.
    """
    out = {}
    reader = csv.reader(io.StringIO(text))
    for fields in reader:
        if not fields:
            continue
        row_id = fields[0]
        match_indicator = fields[2] if len(fields) > 2 else ""
        if match_indicator == "Match" and len(fields) > 9 and fields[5]:
            lon_str, lat_str = fields[5].split(",")
            out[row_id] = (float(lat_str), float(lon_str), fields[8] + fields[9])
        else:
            out[row_id] = None
    return out


def city_key(raw):
    key = (raw or "").strip().upper().replace(".", "")
    key = " ".join(key.split())
    return "SAINT " + key[3:] if key.startswith("ST ") else key


def main():
    with NPPES_PATH.open(encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        fieldnames = list(reader.fieldnames)

    if "latitude" not in fieldnames:
        fieldnames = fieldnames + ["latitude", "longitude"]

    matches = {}
    for start in range(0, len(rows), BATCH_SIZE):
        chunk = rows[start:start + BATCH_SIZE]
        batch_bytes = build_batch_csv(chunk, start_id=start)

        print(f"Geocoding rows {start}..{start + len(chunk) - 1} via Census batch API")
        response_text = post_multipart(batch_bytes)
        matches.update(parse_response(response_text))
        time.sleep(SLEEP_S)

    matched = 0
    county = {}
    for i, row in enumerate(rows):
        result = matches.get(str(i))
        if result:
            row["latitude"], row["longitude"], county[i] = result
            matched += 1
        else:
            row["latitude"], row["longitude"] = "", ""

    total = len(rows)
    rate = (matched / total * 100) if total else 0.0
    print(f"Geocoded {matched}/{total} NPPES rows in the ZIP net ({rate:.1f}% match rate)")

    metro_cities = {
        city_key(rows[i]["city"]) for i, c in county.items() if c in METRO_COUNTIES
    }
    kept, by_county, by_city, out_county, out_city = [], 0, 0, 0, 0
    for i, row in enumerate(rows):
        if i in county:
            if county[i] in METRO_COUNTIES:
                kept.append(row)
                by_county += 1
            else:
                out_county += 1
        elif city_key(row["city"]) in metro_cities:
            kept.append(row)
            by_city += 1
        else:
            out_city += 1

    with NPPES_PATH.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for row in kept:
            w.writerow(row)

    kept_matched = sum(1 for r in kept if r["latitude"] != "")
    print(f"Kept {by_county} geocoded rows inside the seven counties, dropped {out_county} outside")
    print(f"Kept {by_city} ungeocoded rows by metro city name, dropped {out_city}")
    print(f"Wrote {len(kept)} rows, {kept_matched} with coordinates, to {NPPES_PATH}")


if __name__ == "__main__":
    main()
