FROM ubuntu:24.04

# Install wgrib2 from Ubuntu universe (prebuilt binary, ~30s install)
# Plus Node.js 20.x from NodeSource for the Express server.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      software-properties-common \
 && add-apt-repository universe \
 && apt-get update \
 && apt-get install -y --no-install-recommends wgrib2 \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 # Hard-fail the build if wgrib2 isn't actually on PATH:
 && which wgrib2 \
 && wgrib2 -version

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY server.js ./

ENV PORT=10000
EXPOSE 10000

CMD ["node", "server.js"]
