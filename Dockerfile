# RRFS sidecar — extracts 2m temperature from NOAA RRFS GRIB2 via wgrib2.
# Designed for Render free tier (Docker web service, 512 MB RAM).
#
# Build:  docker build -t rrfs-sidecar .
# Run:    docker run -p 8080:8080 rrfs-sidecar
# Render: New Web Service → Docker → point at this folder → done.

FROM node:20-bookworm-slim

# wgrib2 is NOT in Debian's main repo (NOAA license). We build it from source.
# Source tarball is ~5 MB; build pulls in gfortran + zlib + libpng + libjasper.
# Final image strips build tools to keep size reasonable.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl \
        build-essential gfortran \
        zlib1g-dev libpng-dev \
        wget unzip; \
    cd /tmp; \
    wget -q https://www.ftp.cpc.ncep.noaa.gov/wd51we/wgrib2/wgrib2.tgz.v3.1.2 -O wgrib2.tgz; \
    tar xzf wgrib2.tgz; \
    cd grib2; \
    # Disable optional deps we don't need (Jasper/PROJ/NetCDF) to speed build.
    export CC=gcc; export FC=gfortran; \
    sed -i 's/^USE_NETCDF3=.*/USE_NETCDF3=0/' makefile; \
    sed -i 's/^USE_NETCDF4=.*/USE_NETCDF4=0/' makefile; \
    sed -i 's/^USE_JASPER=.*/USE_JASPER=0/' makefile; \
    sed -i 's/^USE_OPENJPEG=.*/USE_OPENJPEG=0/' makefile; \
    sed -i 's/^USE_AEC=.*/USE_AEC=0/' makefile; \
    sed -i 's/^USE_IPOLATES=.*/USE_IPOLATES=0/' makefile; \
    sed -i 's/^USE_PROJ4=.*/USE_PROJ4=0/' makefile; \
    make -j"$(nproc)"; \
    cp wgrib2/wgrib2 /usr/local/bin/wgrib2; \
    chmod +x /usr/local/bin/wgrib2; \
    /usr/local/bin/wgrib2 -version || true; \
    cd /; rm -rf /tmp/grib2 /tmp/wgrib2.tgz; \
    # Strip build tools to shrink final image (~400 MB → ~150 MB).
    apt-get purge -y --auto-remove build-essential gfortran wget unzip libpng-dev zlib1g-dev; \
    apt-get install -y --no-install-recommends libgfortran5 libpng16-16 zlib1g; \
    rm -rf /var/lib/apt/lists/*

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
