# RRFS Sidecar v11 — uses prebuilt wgrib2 community image.
# sondngyn/wgrib2:latest has 616K+ pulls and ships a working wgrib2 binary,
# so we skip the source compile that broke v1–v10 on every Debian/Ubuntu layer.
FROM sondngyn/wgrib2:latest

# Install Node.js 20 on top of the base (Ubuntu-family).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    which wgrib2; \
    wgrib2 -version || true; \
    node --version; \
    npm --version

WORKDIR /app

# Manifest first → better layer caching on code-only changes.
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY server.js ./

ENV NODE_ENV=production \
    PORT=10000

EXPOSE 10000

# Base image sets ENTRYPOINT to wgrib2; blank it so our CMD (Node) takes over.
ENTRYPOINT []
CMD ["node", "server.js"]

ENV PORT=10000
EXPOSE 10000
CMD ["node", "server.js"]
