FROM ubuntu:22.04

# Install wgrib2 from Ubuntu universe, then install Node.js from the official
# tarball so the build only needs one Ubuntu apt update (Render mirrors can 520).
RUN set -eux; \
    sed -i 's/ main$/ main universe/; s/ main restricted$/ main restricted universe/' /etc/apt/sources.list; \
    apt-get update -o Acquire::Retries=5 -o Acquire::http::Timeout=30; \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils wgrib2; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
      https://nodejs.org/dist/v20.18.2/node-v20.18.2-linux-x64.tar.xz \
      -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    rm -rf /var/lib/apt/lists/* /tmp/node.tar.xz; \
    which wgrib2; \
    wgrib2 -version; \
    node --version; \
    npm --version

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY server.js ./

ENV PORT=10000
EXPOSE 10000

CMD ["node", "server.js"]
