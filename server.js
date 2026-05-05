// RRFS sidecar — converts NOAA RRFS GRIB2 to JSON for one lat/lon.
// =====================================================================
// Endpoint:
//   GET /rrfs?lat=40.71&lon=-74.01&hours=48
//   → { runHour, run, hourly: { time: [...], temperature_2m: [...] }, source }
//
// How it works:
//   1. Pick the latest RRFS run with files available on `noaa-rrfs-pds` S3.
//      RRFS-A produces hourly GRIB2 in s3://noaa-rrfs-pds/rrfs_a/rrfs.YYYYMMDD/HH/
//      with filenames like:
//        rrfs.tHHz.prslev.f001.conus.grib2
//        rrfs.tHHz.prslev.f002.conus.grib2
//        ...
//   2. For each forecast hour 1..N (N=hours), HEAD-check the file exists,
//      then download just enough of the GRIB2 file to extract the
//      "TMP:2 m above ground" record at the requested lat/lon.
//      We use wgrib2's `-lon` interpolation (bilinear by default).
//   3. Return JSON with hourly time series (UTC ISO strings, °C).
//
// Why not download the full GRIB2 each hour?
//   Each hourly file is 200–400 MB. Render free tier has 512 MB RAM
//   and slow egress. Solution: NCEP GRIB2 supports byte-range requests
//   if we have an `.idx` file listing record offsets. wgrib2 can use
//   that to pull just the TMP:2m record (~150 KB instead of 300 MB).
//
// Caching:
//   Results are cached in-memory per (run, hour, lat, lon) for 60 min.
//   Render free spins down on idle — that's fine, our caller (Lovable
//   forecast-snapshot cron) only hits us at most every 3 hours.

import express from "express";
import { spawn } from "node:child_process";
import { mkdtemp, writeFile, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PORT = Number(process.env.PORT || 8080);
const S3_BASE = "https://noaa-rrfs-pds.s3.amazonaws.com";
const USER_AGENT = "rrfs-sidecar/1.0 (lovable.dev)";

// In-memory cache: key=`${run}|${fhr}|${lat.toFixed(3)}|${lon.toFixed(3)}` → tempC.
// Bounded to ~1000 entries (≈ 9 cities × 48 hours × 2 runs of overlap).
const cache = new Map();
const CACHE_TTL_MS = 60 * 60 * 1000;
const CACHE_MAX = 1000;

function cacheGet(key) {
  const hit = cache.get(key);
  if (!hit) return null;
  if (Date.now() - hit.t > CACHE_TTL_MS) {
    cache.delete(key);
    return null;
  }
  return hit.v;
}
function cacheSet(key, v) {
  if (cache.size >= CACHE_MAX) {
    const firstKey = cache.keys().next().value;
    if (firstKey) cache.delete(firstKey);
  }
  cache.set(key, { t: Date.now(), v });
}

// ---------- run discovery ----------

/**
 * Find the most recent RRFS run that has at least the f001 file present.
 * RRFS-A runs hourly at HH:00Z, but typically lands ~80 min after the run hour.
 * We scan back up to 6 hours.
 */
// RRFS-A files are published as `rrfs.tHHz.2dfld.2p5km.fNNN.hi.grib2`.
// The `.hi` (native HRRR-style 2.5 km) variant carries the TMP:2 m record
// we need; `.pr` (pressure levels) also has it but is ~3× larger.
function rrfsKey(day, hh, fhr) {
  const fhrStr = String(fhr).padStart(3, "0");
  return `rrfs_a/rrfs.${day}/${hh}/rrfs.t${hh}z.2dfld.2p5km.f${fhrStr}.hi.grib2`;
}

/**
 * Find the most recent RRFS run that has at least the f001 file present.
 * RRFS-A runs hourly at HH:00Z, but typically lands ~25-30 min after the run hour.
 * We scan back up to 8 hours.
 */
async function findLatestRun() {
  const now = new Date();
  for (let lookback = 0; lookback <= 8; lookback++) {
    const t = new Date(now.getTime() - lookback * 3600 * 1000);
    const yyyy = t.getUTCFullYear();
    const mm = String(t.getUTCMonth() + 1).padStart(2, "0");
    const dd = String(t.getUTCDate()).padStart(2, "0");
    const hh = String(t.getUTCHours()).padStart(2, "0");
    const day = `${yyyy}${mm}${dd}`;
    const probe = `${S3_BASE}/${rrfsKey(day, hh, 1)}.idx`;
    const r = await fetch(probe, { method: "HEAD", headers: { "User-Agent": USER_AGENT } })
      .catch(() => null);
    if (r && r.ok) {
      return { day, hh, runIso: `${yyyy}-${mm}-${dd}T${hh}:00:00Z` };
    }
  }
  return null;
}

// ---------- byte-range extract via wgrib2 ----------

/**
 * Download just the TMP:2m record from a forecast-hour GRIB2 file using its .idx.
 * Returns a Buffer of GRIB2 bytes, or null if the record isn't available.
 */
async function fetchTmp2mRecord(day, hh, fhr) {
  const baseUrl = `${S3_BASE}/${rrfsKey(day, hh, fhr)}`;
  const idxUrl = `${baseUrl}.idx`;
  // Step 1: parse the .idx to find the byte offset of TMP:2 m above ground.
  // .idx format: `record:offset:date:variable:level:fcst:other`
  let idxText;
  try {
    const r = await fetch(idxUrl, { headers: { "User-Agent": USER_AGENT } });
    if (!r.ok) return null;
    idxText = await r.text();
  } catch {
    return null;
  }
  const lines = idxText.split("\n");
  let recOffset = null;
  let recEnd = null;
  for (let i = 0; i < lines.length; i++) {
    const cols = lines[i].split(":");
    if (cols.length < 5) continue;
    const variable = cols[3];
    const level = cols[4];
    if (variable === "TMP" && level === "2 m above ground") {
      recOffset = Number(cols[1]);
      const next = lines[i + 1]?.split(":");
      recEnd = next && next.length >= 2 ? Number(next[1]) - 1 : null;
      break;
    }
  }
  if (recOffset == null) return null;
  // Step 2: byte-range download just that record.
  const rangeHeader = recEnd != null ? `bytes=${recOffset}-${recEnd}` : `bytes=${recOffset}-`;
  const grib = await fetch(baseUrl, {
    headers: { "User-Agent": USER_AGENT, Range: rangeHeader },
  });
  if (!grib.ok && grib.status !== 206) return null;
  const buf = Buffer.from(await grib.arrayBuffer());
  return buf;
}

/**
 * Run wgrib2 on a GRIB2 buffer to interpolate temperature at lat/lon.
 * Returns Celsius, or null on error.
 */
async function wgrib2PointTemp(gribBuf, lat, lon) {
  const dir = await mkdtemp(join(tmpdir(), "rrfs-"));
  const gribPath = join(dir, "rec.grib2");
  const csvPath = join(dir, "out.csv");
  try {
    await writeFile(gribPath, gribBuf);
    // wgrib2 expects lon in 0..360 form for some grids; conventional negative
    // lon (e.g. -74.01) also works for CONUS Lambert. We pass as-is.
    // Output: bilinear point interpolation, CSV format.
    //   wgrib2 rec.grib2 -lon LON LAT -csv out.csv
    // CSV columns: "ref_date","valid_date","var","level","lon","lat","value"
    await new Promise((resolve, reject) => {
      const proc = spawn("wgrib2", [
        gribPath,
        "-lon", String(lon), String(lat),
        "-csv", csvPath,
      ], { stdio: ["ignore", "ignore", "pipe"] });
      let stderr = "";
      proc.stderr.on("data", (d) => { stderr += d.toString(); });
      proc.on("error", reject);
      proc.on("close", (code) => {
        if (code === 0) resolve();
        else reject(new Error(`wgrib2 exit ${code}: ${stderr.slice(0, 200)}`));
      });
    });
    const csv = await readFile(csvPath, "utf8");
    // Take the LAST non-empty CSV row (wgrib2 emits one per record).
    const rows = csv.trim().split("\n").filter(Boolean);
    if (rows.length === 0) return null;
    const last = rows[rows.length - 1];
    const cols = last.split(",").map((c) => c.replace(/^"|"$/g, ""));
    const valK = Number(cols[cols.length - 1]);
    if (!Number.isFinite(valK)) return null;
    // RRFS TMP is in Kelvin → °C.
    const valC = valK > 100 ? valK - 273.15 : valK;
    if (valC < -60 || valC > 60) return null;
    return +valC.toFixed(2);
  } catch (e) {
    console.warn(`[wgrib2] ${e.message}`);
    return null;
  } finally {
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

// ---------- HTTP server ----------

const app = express();

app.get("/healthz", (_req, res) => res.json({ ok: true }));

app.get("/rrfs", async (req, res) => {
  const lat = Number(req.query.lat);
  const lon = Number(req.query.lon);
  const hoursReq = Number(req.query.hours || 48);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    return res.status(400).json({ error: "lat and lon required" });
  }
  if (lat < 21 || lat > 53 || lon < -135 || lon > -60) {
    return res.status(400).json({ error: "lat/lon outside CONUS RRFS domain" });
  }
  const hours = Math.max(1, Math.min(48, Math.round(hoursReq)));

  const run = await findLatestRun();
  if (!run) {
    return res.status(503).json({ error: "no recent RRFS run available", source: "noaa-rrfs-pds" });
  }

  const time = [];
  const temperature_2m = [];
  const runMs = Date.parse(run.runIso);
  let hits = 0;
  let misses = 0;

  // Fetch records sequentially — RRFS .idx files cache well at S3 edge,
  // and serial avoids hammering free-tier egress. ~150 KB × 48 = ~7 MB total.
  for (let fhr = 1; fhr <= hours; fhr++) {
    const validIso = new Date(runMs + fhr * 3600 * 1000).toISOString().slice(0, 16);
    const cacheKey = `${run.runIso}|${fhr}|${lat.toFixed(3)}|${lon.toFixed(3)}`;
    let valC = cacheGet(cacheKey);
    if (valC == null) {
      const grib = await fetchTmp2mRecord(run.day, run.hh, fhr);
      valC = grib ? await wgrib2PointTemp(grib, lat, lon) : null;
      if (valC != null) cacheSet(cacheKey, valC);
    }
    time.push(validIso);
    temperature_2m.push(valC);
    if (valC != null) hits++; else misses++;
  }

  if (hits === 0) {
    return res.status(503).json({
      error: "RRFS run found but no records readable",
      run: run.runIso, misses,
    });
  }

  res.json({
    runHour: run.hh,
    run: run.runIso,
    source: "noaa-rrfs-pds-wgrib2",
    unit: "C",
    hits,
    misses,
    hourly: { time, temperature_2m },
  });
});

app.listen(PORT, () => {
  console.log(`[rrfs-sidecar] listening on :${PORT}`);
});
