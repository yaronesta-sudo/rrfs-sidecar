# RRFS sidecar — extracts 2m temperature from NOAA RRFS GRIB2 via wgrib2.
# Designed for Render free tier (Docker web service, 512 MB RAM).
#
# Build:  docker build -t rrfs-sidecar .
# Run:    docker run -p 8080:8080 rrfs-sidecar
# Render: New Web Service → Docker → point at this folder → done.

FROM node:20-bookworm-slim

# wgrib2 — the only Linux binary that decodes NCEP GRIB2 reliably.
# Debian's `wgrib2` package (NOAA-NCEP build) is ~6 MB and does point queries fast.
RUN apt-get update \
 && apt-get install -y --no-install-recommends wgrib2 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install only prod deps — keep image small for free-tier cold starts.
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --no-audit --no-fund

COPY server.js ./

ENV PORT=8080
ENV NODE_ENV=production
EXPOSE 8080

# Healthcheck so Render marks the service "live" quickly.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT}/healthz" || exit 1

CMD ["node", "server.js"]
