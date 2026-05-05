# RRFS sidecar — Node 20 + wgrib2 (built from source, guaranteed to work)
# Base: official Node 20 on Debian Bookworm (Node already installed, no NodeSource needed)
FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Build wgrib2 from NOAA source. This is the canonical way and avoids
# the unreliable apt repository situation. Takes ~3-4 min on first build,
# then cached forever.
RUN set -eux; \
    apt-get update -o Acquire::Retries=5; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        build-essential \
        gfortran \
        zlib1g-dev \
        libpng-dev \
        libjasper-dev \
        libopenjp2-7-dev \
        m4 \
        file; \
    rm -rf /var/lib/apt/lists/*; \
    cd /tmp; \
    curl -fsSL -o wgrib2.tgz https://www.ftp.cpc.ncep.noaa.gov/wd51we/wgrib2/wgrib2.tgz; \
    tar -xzf wgrib2.tgz; \
    cd grib2; \
    export CC=gcc FC=gfortran; \
    export USE_NETCDF3=0 USE_NETCDF4=0 USE_HDF5=0 USE_REGEX=1 USE_TIGGE=1 USE_MYSQL=0 USE_IPOLATES=0 USE_OPENMP=0 USE_PROJ4=0 USE_WMO_VALIDATION=0 DISABLE_TIMEZONE=1 MAKE_FTN_API=0 DISABLE_ALARM=0 USE_G2CLIB=0 USE_PNG=1 USE_JASPER=1 USE_AEC=0; \
    make -j"$(nproc)"; \
    cp wgrib2/wgrib2 /usr/local/bin/wgrib2; \
    chmod +x /usr/local/bin/wgrib2; \
    cd /; \
    rm -rf /tmp/wgrib2.tgz /tmp/grib2; \
    apt-get purge -y build-essential gfortran m4 file; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*; \
    which wgrib2; \
    wgrib2 -version; \
    node --version; \
    npm --version

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server.js ./

ENV PORT=10000
EXPOSE 10000
CMD ["node", "server.js"]
