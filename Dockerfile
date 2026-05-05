# Avoid Ubuntu/Debian apt entirely: wgrib2 is unreliable/missing there.
# conda-forge publishes prebuilt Linux packages for BOTH wgrib2 and Node.js.
FROM mambaorg/micromamba:2.6.0-debian12

USER root
ENV PATH=/opt/conda/bin:$PATH

RUN set -eux; \
    micromamba install -y -n base -c conda-forge \
      nodejs=20 \
      wgrib2 \
      ca-certificates; \
    micromamba clean --all --yes; \
    which wgrib2; \
    wgrib2 -version; \
    node --version; \
    npm --version

WORKDIR /app

# Install npm deps first (better layer caching).
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --no-audit --no-fund

# Copy app source.
COPY . .

ENV NODE_ENV=production
ENV PORT=10000
EXPOSE 10000

CMD ["node", "server.js"]
