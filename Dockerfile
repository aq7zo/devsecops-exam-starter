# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: deps -- resolve production dependencies only.
# Isolated so that npm, its cache, and the dev dependency tree never reach the
# runtime image. `npm ci` (not `npm install`) enforces package-lock.json
# exactly, which makes the build reproducible and prevents a drifting
# transitive dependency from silently entering the image after a scan passed.
# ---------------------------------------------------------------------------
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# ---------------------------------------------------------------------------
# Stage 2: test -- full dependency tree, runs the suite during image build.
# Not part of the runtime chain; CI targets it explicitly so a red test can
# never produce a publishable image.
# ---------------------------------------------------------------------------
FROM node:22-alpine AS test
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm test

# ---------------------------------------------------------------------------
# Stage 3: runtime -- final image. Carries the app plus prod node_modules and
# nothing else: no lockfile-resolving npm state, no dev deps, no build cache.
# ---------------------------------------------------------------------------
FROM node:22-alpine AS runtime

ENV NODE_ENV=production \
    PORT=3000 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

# Patch OS packages. The base image is rebuilt on its own cadence, so between
# rebuilds it ships Alpine packages whose fixes are already published. The
# image scan found exactly that: libcrypto3/libssl3 3.5.7-r0 with 3.5.8-r0
# available (CVE-2026-14456).
#
# DL3017 warns that `apk upgrade` makes builds less reproducible, which is
# true. Taking published security patches is worth that here, and the version
# actually shipped is recorded in the SBOM CI produces on every build.
# hadolint ignore=DL3017
RUN apk --no-cache upgrade

# Remove the package manager from the runtime image. This container runs
# `node server.js` and installs nothing at run time, so npm, npx, corepack and
# yarn are build-time tools that only sit here adding attack surface.
#
# This is not hypothetical: every Node.js CVE in the image scan came from npm's
# own bundled dependency tree -- tar (CRITICAL), brace-expansion, pacote,
# sigstore, ip-address, picomatch -- while app/node_modules was entirely clean.
# Deleting the tool removes the whole class of finding rather than chasing
# patches for a program the app never calls.
RUN rm -rf /usr/local/lib/node_modules/npm            /usr/local/lib/node_modules/corepack            /usr/local/bin/npm            /usr/local/bin/npx            /usr/local/bin/corepack            /opt/yarn-v*            /usr/local/bin/yarn            /usr/local/bin/yarnpkg

# --chown at COPY time rather than a later `RUN chown -R`: a recursive chown
# rewrites every file into a new layer, roughly doubling the image size.
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package.json server.js ./

# Non-root. The official node image ships uid/gid 1000 `node` already; creating
# our own user would add a layer for no benefit. Declared before the health
# check so everything below this line runs unprivileged.
USER node

EXPOSE 3000

# Container-native liveness. Compose and orchestrators read this; it uses the
# runtime's own fetch (Node >=18) so the image needs neither curl nor wget.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Exec form: node becomes PID 1 directly instead of being wrapped by a shell
# that would swallow SIGTERM and force a 10s kill on every `docker stop`.
# Run with `--init` (compose sets `init: true`) so PID 1 still reaps zombies.
CMD ["node", "server.js"]
