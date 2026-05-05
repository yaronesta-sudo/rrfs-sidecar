# RRFS Sidecar

Tiny external service that decodes NOAA RRFS GRIB2 → JSON for one lat/lon.
Lives outside Lovable because Deno edge functions can't run `wgrib2`.

## What it does

`GET /rrfs?lat=40.71&lon=-74.01&hours=48`

Returns:
```json
{
  "run": "2026-05-05T15:00:00Z",
  "runHour": "15",
  "source": "noaa-rrfs-pds-wgrib2",
  "unit": "C",
  "hits": 47,
  "misses": 1,
  "hourly": {
    "time": ["2026-05-05T16:00", "2026-05-05T17:00", ...],
    "temperature_2m": [18.4, 19.1, ...]
  }
}
```

How: HEAD-probes `s3://noaa-rrfs-pds/rrfs_a/...` for the latest RRFS-A run,
parses each forecast hour's `.idx` file to find the byte offset of the
`TMP:2 m above ground` record, byte-range downloads ~150 KB per hour,
runs `wgrib2 -lon LON LAT -csv` to bilinearly interpolate the point.

In-memory LRU cache keyed by (run, fhr, lat, lon) with 60 min TTL keeps repeat
calls (e.g. multiple cities sharing the same run) cheap.

## Deploy to Render (free tier)

1. Create a new GitHub repo (e.g. `rrfs-sidecar`) and push **only** this folder's contents to its root.

2. On render.com:
   - **New +** → **Web Service**
   - Connect your GitHub repo.
   - **Runtime**: Docker
   - **Region**: Oregon (closest to NOAA S3)
   - **Plan**: Free
   - **Health Check Path**: `/healthz`
   - Click **Create Web Service**.

3. Wait ~5 minutes for the first build. When it shows "Live", copy the URL
   (e.g. `https://rrfs-sidecar.onrender.com`).

4. Test it:
   ```bash
   curl "https://rrfs-sidecar.onrender.com/healthz"
   curl "https://rrfs-sidecar.onrender.com/rrfs?lat=40.71&lon=-74.01&hours=6"
   ```
   First real call may take 30–60s while wgrib2 chews through 6 records;
   subsequent calls are ~2–5s thanks to the cache.

5. Paste the URL into Lovable when prompted to set the `RRFS_SIDECAR_URL` secret.

## Cold-start behavior

Render free tier spins down after 15 min idle and takes ~30s to wake.
Our Lovable caller hits this every 3 hours via `forecast-snapshot`, so
expect a cold start on most calls. Total wall time per cron run:
30s wake + 9 cities × ~10s (warm) ≈ 2 minutes. Well within the
edge-function 5-min timeout.

## Local test

```bash
docker build -t rrfs-sidecar .
docker run -p 8080:8080 rrfs-sidecar
curl "http://localhost:8080/rrfs?lat=40.71&lon=-74.01&hours=3"
```
