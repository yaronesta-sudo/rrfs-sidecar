FROM node:20-bookworm-slim

# Install wgrib2 from Debian's contrib repo (prebuilt, no compilation)
RUN echo "deb http://deb.debian.org/debian bookworm main contrib non-free" > /etc/apt/sources.list.d/contrib.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      wgrib2 \
 && rm -rf /var/lib/apt/lists/* \
 && wgrib2 -version || true

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY server.js ./

ENV PORT=10000
EXPOSE 10000

CMD ["node", "server.js"]

