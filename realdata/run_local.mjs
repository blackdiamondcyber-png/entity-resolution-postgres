// Load the NPPES and OSM snapshots into the repo's own `locations` table and
// run the repo's own scored_pairs view in PGlite (Postgres compiled to
// WebAssembly), so no server is needed. It never calls run_auto_merge(); it
// only reads scored_pairs. It also writes the files in realdata/labels/ that
// come from the data, and runs metrics.sql once the label files exist.
//
// PGlite is not a dependency of this repo. Install it anywhere and point
// PGLITE_DIR at it (tested with 0.5.8):
//   npm install --prefix /tmp/pglite @electric-sql/pglite
//   PGLITE_DIR=/tmp/pglite/node_modules/@electric-sql/pglite node realdata/run_local.mjs
// NODE_PATH does not help here: Node's ESM resolver ignores it.

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");

const PGLITE_DIR = process.env.PGLITE_DIR;
if (!PGLITE_DIR) {
  console.error("Set PGLITE_DIR to an @electric-sql/pglite install (see the top of this file).");
  process.exit(1);
}
const pglite = (file) => import(pathToFileURL(path.join(PGLITE_DIR, "dist", file)).href);

const { PGlite } = await pglite("index.js");
const { pg_trgm } = await pglite("contrib/pg_trgm.js");
const { pgcrypto } = await pglite("contrib/pgcrypto.js");

// ---- minimal RFC4180 CSV parser (no npm dependency) ------------------

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let inQuotes = false;
  let i = 0;
  const n = text.length;

  const pushField = () => { row.push(field); field = ""; };
  const pushRow = () => { pushField(); rows.push(row); row = []; };

  while (i < n) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i += 2; continue; }
        inQuotes = false; i += 1; continue;
      }
      field += c; i += 1; continue;
    }
    if (c === '"') { inQuotes = true; i += 1; continue; }
    if (c === ",") { pushField(); i += 1; continue; }
    if (c === "\r") { i += 1; continue; }
    if (c === "\n") { pushRow(); i += 1; continue; }
    field += c; i += 1;
  }
  if (field.length > 0 || row.length > 0) pushRow();
  // drop a trailing fully-empty row from a final newline
  if (rows.length && rows[rows.length - 1].length === 1 && rows[rows.length - 1][0] === "") {
    rows.pop();
  }
  return rows;
}

function readCsvObjects(filePath) {
  const text = readFileSync(filePath, "utf-8");
  const rows = parseCsv(text);
  const header = rows[0];
  return rows.slice(1).map((r) => {
    const obj = {};
    header.forEach((h, idx) => { obj[h] = r[idx] ?? ""; });
    return obj;
  });
}

const orNull = (v) => (v === undefined || v === null || v === "" ? null : v);
const orNullNum = (v) => (v === undefined || v === null || v === "" ? null : Number(v));

function csvField(v) {
  if (v === null || v === undefined) return "";
  const s = String(v);
  if (/[",\n\r]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}

function writeCsv(filePath, header, rows) {
  const lines = [header.join(",")];
  for (const row of rows) {
    lines.push(header.map((h) => csvField(row[h])).join(","));
  }
  writeFileSync(filePath, lines.join("\n") + "\n", "utf-8");
}

// ---- main ---------------------------------------------------------------

async function main() {
  const db = new PGlite({ extensions: { pg_trgm, pgcrypto } });

  for (const f of [
    "sql/01-normalize.sql",
    "sql/02-blocking.sql",
    "sql/03-scoring.sql",
    "sql/04-merge.sql",
  ]) {
    const sql = readFileSync(path.join(REPO_ROOT, f), "utf-8");
    await db.exec(sql);
  }

  const nppesRows = readCsvObjects(path.join(REPO_ROOT, "realdata/data/nppes_dental_orgs_msp.csv"));
  const osmRows = readCsvObjects(path.join(REPO_ROOT, "realdata/data/osm_dentists_msp.csv"));

  const insertSql = `
    insert into locations (source, name, address, postal_code, phone, latitude, longitude, external_ids)
    values ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
  `;

  for (const r of nppesRows) {
    const externalIds = { record_id: r.record_id, other_names: r.other_names || null };
    await db.query(insertSql, [
      "nppes",
      orNull(r.name),
      orNull(r.address),
      orNull(r.postal_code),
      orNull(r.phone),
      orNullNum(r.latitude),
      orNullNum(r.longitude),
      JSON.stringify(externalIds),
    ]);
  }

  for (const r of osmRows) {
    const externalIds = { record_id: r.record_id, other_names: r.other_names || null };
    await db.query(insertSql, [
      "osm",
      orNull(r.name),
      orNull(r.address),
      orNull(r.postal_code),
      orNull(r.phone),
      orNullNum(r.latitude),
      orNullNum(r.longitude),
      JSON.stringify(externalIds),
    ]);
  }

  console.log("=== rows per source ===");
  const bySource = await db.query(
    "select source, count(*) as n from locations group by source order by source;"
  );
  for (const row of bySource.rows) console.log(`  ${row.source}: ${row.n}`);

  const total = await db.query("select count(*) as n from locations;");
  console.log(`  total: ${total.rows[0].n}`);

  const validPhone = await db.query(
    "select count(*) as n from locations where phone_key is not null;"
  );
  console.log(`\nRows with a valid phone key: ${validPhone.rows[0].n}`);

  console.log("\n=== candidate pairs from scored_pairs, by block ===");
  const byBlock = await db.query(
    "select block, count(*) as n from scored_pairs group by block order by block;"
  );
  for (const row of byBlock.rows) console.log(`  ${row.block}: ${row.n}`);
  const totalPairs = await db.query("select count(*) as n from scored_pairs;");
  console.log(`  total pairs: ${totalPairs.rows[0].n}`);

  console.log("\n=== pairs by verdict ===");
  const byVerdict = await db.query(
    "select verdict, count(*) as n from scored_pairs group by verdict order by verdict;"
  );
  for (const row of byVerdict.rows) console.log(`  ${row.verdict}: ${row.n}`);

  console.log("\n=== cross-source vs same-source pairs ===");
  const bySourcePair = await db.query(`
    select case when a.source = b.source then 'same-source: ' || a.source
                else 'cross-source: nppes-osm' end as kind,
           count(*) as n
    from scored_pairs sp
    join locations a on a.id = sp.a_id
    join locations b on b.id = sp.b_id
    group by 1
    order by 1;
  `);
  for (const row of bySourcePair.rows) console.log(`  ${row.kind}: ${row.n}`);

  // ---- export every scored pair, and the blinded labelling set -----------
  //
  // A pair is keyed by its two records as "source:record_id", sorted, so the
  // key is stable across loads (the uuids in scored_pairs are not).

  const recKey = `(l.source || ':' || (l.external_ids->>'record_id'))`;
  const pairsRes = await db.query(`
    with p as (
      select sp.verdict, sp.score, sp.block,
             ${recKey.replace(/l\./g, "la.")} as ka,
             ${recKey.replace(/l\./g, "lb.")} as kb,
             la.id as ida, lb.id as idb
        from scored_pairs sp
        join locations la on la.id = sp.a_id
        join locations lb on lb.id = sp.b_id
    )
    select p.verdict, round(p.score::numeric, 3)::text as score, p.block,
           case when p.ka < p.kb then p.ida else p.idb end as first_id,
           case when p.ka < p.kb then p.idb else p.ida end as second_id
      from p
  `);

  const locRes = await db.query(`
    select id, source, external_ids->>'record_id' as record_id, name,
           coalesce(external_ids->>'other_names', '') as other_names,
           coalesce(address, '') as address, coalesce(postal_code, '') as postal_code,
           coalesce(phone, '') as phone, latitude, longitude
      from locations
  `);
  const loc = new Map(locRes.rows.map((r) => [r.id, r]));
  const keyOf = (r) => `${r.source}:${r.record_id}`;
  const distance = (a, b) => {
    if (a.latitude === null || b.latitude === null) return "";
    const toRad = (d) => (d * Math.PI) / 180;
    const h =
      Math.sin(toRad(b.latitude - a.latitude) / 2) ** 2 +
      Math.cos(toRad(a.latitude)) * Math.cos(toRad(b.latitude)) *
        Math.sin(toRad(b.longitude - a.longitude) / 2) ** 2;
    return Math.round(6371000 * 2 * Math.asin(Math.sqrt(h)));
  };
  const side = (prefix, r) => ({
    [`${prefix}_source`]: r.source,
    [`${prefix}_record_id`]: r.record_id,
    [`${prefix}_name`]: r.name,
    [`${prefix}_other_names`]: r.other_names,
    [`${prefix}_address`]: r.address,
    [`${prefix}_postal_code`]: r.postal_code,
    [`${prefix}_phone`]: r.phone,
  });
  const sideCols = (prefix) =>
    ["source", "record_id", "name", "other_names", "address", "postal_code", "phone"].map(
      (c) => `${prefix}_${c}`,
    );
  const md5 = (s) => createHash("md5").update(s).digest("hex");

  const allPairs = pairsRes.rows
    .map((r) => {
      const a = loc.get(r.first_id);
      const b = loc.get(r.second_id);
      const pairKey = `${keyOf(a)}|${keyOf(b)}`;
      return {
        pair_key: pairKey,
        verdict: r.verdict,
        score: r.score,
        block: r.block,
        ...side("a", a),
        ...side("b", b),
        distance_m: distance(a, b),
        shuffle: md5(pairKey),
      };
    })
    .sort((x, y) => (x.pair_key < y.pair_key ? -1 : 1));

  const labelsDir = path.join(REPO_ROOT, "realdata/labels");
  mkdirSync(labelsDir, { recursive: true });
  writeCsv(
    path.join(labelsDir, "scored_pairs.csv"),
    ["pair_key", "verdict", "score", "block", ...sideCols("a"), ...sideCols("b"), "distance_m"],
    allPairs,
  );

  // Every auto_merge and every review pair, plus the DISTINCT_SAMPLE distinct
  // pairs with the lowest md5(pair_key). The labelling file is blinded: no
  // score, verdict or block, and rows shuffled by md5 so bands are mixed.
  const DISTINCT_SAMPLE = 60;
  const byShuffle = (x, y) => (x.shuffle < y.shuffle ? -1 : 1);
  const toLabel = [
    ...allPairs.filter((p) => p.verdict !== "distinct"),
    ...allPairs.filter((p) => p.verdict === "distinct").sort(byShuffle).slice(0, DISTINCT_SAMPLE),
  ].sort(byShuffle);
  writeCsv(
    path.join(labelsDir, "to_label_blind.csv"),
    ["pair_key", ...sideCols("a"), ...sideCols("b"), "distance_m"],
    toLabel,
  );

  // Recall set: for every OSM record, the registry records that could be the
  // same practice whether or not blocking paired them: anything within 300 m,
  // plus, within 2 km (or with no coordinates to compare), the same valid
  // phone or a name or DBA name with trigram similarity >= 0.5. The 2 km arm
  // catches a geocode that landed on the wrong block without pulling in every
  // branch of a chain across the metro.
  const neighRes = await db.query(`
    select o.id as osm_id, n.id as nppes_id
      from locations o
      join locations n on n.source = 'nppes'
      cross join lateral (
        select case when o.latitude is null or n.latitude is null then null
                    else haversine_m(o.latitude, o.longitude, n.latitude, n.longitude) end as d,
               greatest(
                 similarity(o.name, n.name),
                 coalesce((select max(similarity(o.name, dba))
                             from unnest(string_to_array(n.external_ids->>'other_names', '|')) dba), 0)
               ) as sim
      ) x
     where o.source = 'osm'
       and (
         x.d < 300
         or (o.phone_key is not null and o.phone_key = n.phone_key and coalesce(x.d, 0) < 2000)
         or (x.sim >= 0.5 and coalesce(x.d, 0) < 2000)
       )
  `);
  const neighbours = neighRes.rows
    .map((r) => {
      const o = loc.get(r.osm_id);
      const n = loc.get(r.nppes_id);
      return {
        osm_key: keyOf(o),
        nppes_key: keyOf(n),
        ...side("osm", o),
        ...side("nppes", n),
        distance_m: distance(o, n),
      };
    })
    .sort((x, y) =>
      x.osm_key !== y.osm_key ? (x.osm_key < y.osm_key ? -1 : 1) : x.nppes_key < y.nppes_key ? -1 : 1,
    );
  writeCsv(
    path.join(labelsDir, "osm_neighbours_blind.csv"),
    ["osm_key", "nppes_key", ...sideCols("osm"), ...sideCols("nppes"), "distance_m"],
    neighbours,
  );

  const osmWithNeighbour = new Set(neighbours.map((r) => r.osm_key)).size;
  console.log("\n=== exports ===");
  console.log(`  scored_pairs.csv: ${allPairs.length} pairs`);
  console.log(
    `  to_label_blind.csv: ${toLabel.length} pairs (every auto_merge and review, ${DISTINCT_SAMPLE} distinct)`,
  );
  console.log(
    `  osm_neighbours_blind.csv: ${neighbours.length} rows covering ${osmWithNeighbour} of ${osmRows.length} OSM records`,
  );

  // ---- score against the labels, once they exist ------------------------
  //
  // load-labels.sql fills these tables with \copy under psql; PGlite has no
  // \copy, so the same CSVs go in row by row here, then metrics.sql runs as is.

  const pairLabelsPath = path.join(labelsDir, "pair_labels.csv");
  const neighbourLabelsPath = path.join(labelsDir, "neighbour_labels.csv");
  if (existsSync(pairLabelsPath) && existsSync(neighbourLabelsPath)) {
    const ddl = readFileSync(path.join(REPO_ROOT, "realdata/load-labels.sql"), "utf-8")
      .split("\n")
      .filter((line) => !line.startsWith("\\copy"))
      .join("\n");
    await db.exec(ddl);
    for (const r of readCsvObjects(pairLabelsPath)) {
      await db.query("insert into pair_labels values ($1, $2, $3, $4, $5)", [
        r.pair_key, r.pass1, r.pass2, r.label, r.reason,
      ]);
    }
    for (const r of readCsvObjects(neighbourLabelsPath)) {
      await db.query("insert into neighbour_labels values ($1, $2, $3, $4, $5, $6)", [
        r.osm_key, r.nppes_key, r.pass1, r.pass2, r.label, r.reason,
      ]);
    }
    const results = await db.exec(
      readFileSync(path.join(REPO_ROOT, "realdata/metrics.sql"), "utf-8"),
    );
    console.log("\n=== metrics.sql ===");
    for (const res of results) {
      if (res.fields.length > 0) console.table(res.rows);
    }
  }

  await db.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
