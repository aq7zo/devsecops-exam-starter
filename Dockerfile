# syntax=docker/dockerfile:1

# `npm ci` rather than `npm install`: installs the locked tree exactly, so a
# transitive dependency cannot drift into the image after a scan passed.
FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Nothing below depends on this stage; CI targets it explicitly so a red test
# cannot produce a publishable image.
FROM node:24-alpine AS test
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm test

FROM node:24-alpine AS runtime

ENV NODE_ENV=production \
    PORT=3000 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

# The base image is rebuilt on its own cadence, so between rebuilds it ships
# Alpine packages whose fixes are already published. DL3017 is accepted here:
# `apk upgrade` costs reproducibility, and the SBOM records what shipped.
# hadolint ignore=DL3017
RUN apk --no-cache upgrade

# The container runs `node server.js` and installs nothing at run time, so the
# package managers are pure attack surface -- and npm's bundled dependency tree
# is where every Node.js CVE in the image scan came from.
RUN rm -rf /usr/local/lib/node_modules/npm            /usr/local/lib/node_modules/corepack            /usr/local/bin/npm            /usr/local/bin/npx            /usr/local/bin/corepack            /opt/yarn-v*            /usr/local/bin/yarn            /usr/local/bin/yarnpkg

# --chown at COPY time, not a later `RUN chown -R`: a recursive chown rewrites
# every file into a new layer, roughly doubling the image size.
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package.json server.js ./

# The base image already ships uid/gid 1000 `node`, so no useradd layer is
# needed. Declared here so everything below runs unprivileged.
USER node

EXPOSE 3000

# Uses the runtime's own fetch (Node >=18) so the image needs no curl or wget.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Exec form so node is PID 1 and receives SIGTERM directly; a shell wrapper
# would swallow it and force a 10s kill on every `docker stop`. Run with
# `--init` (compose sets `init: true`) so zombies are still reaped.
CMD ["node", "server.js"]
