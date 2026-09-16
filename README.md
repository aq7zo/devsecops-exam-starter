# Macky Merch API — Secure Delivery Pipeline

LSCS DevSecOps Engineering Take-Home Exam · 41st LSCS · Term 1

A containerised Express API wrapped in a CI/CD pipeline that tests it, builds
it, proves the container actually serves traffic, and blocks the merge if any
of three different classes of security scanner finds something.

---

## Contents

- [Quick start](#quick-start)
- [What is in this repository](#what-is-in-this-repository)
- [Pipeline at a glance](#pipeline-at-a-glance)
- [Architecture: the Dockerfile](#architecture-the-dockerfile)
- [Architecture: the security scanners](#architecture-the-security-scanners)
- [Vulnerability demonstration](#vulnerability-demonstration)
- [Bonus features](#bonus-features)
- [Challenges faced](#challenges-faced)
- [Requirements checklist](#requirements-checklist)

---

## Quick start

### Run with Docker

```bash
# Build the image (multi-stage; the test stage runs the suite during the build)
docker build -t macky-merch-api:local .

# Run it. --init gives you a real PID 1 so Ctrl-C / docker stop is instant.
docker run --rm --init -p 3000:3000 macky-merch-api:local

# Verify
curl http://localhost:3000/health
# {"status":"OK","message":"Macky Merch API is running smoothly."}
```

Confirm it is **not** running as root:

```bash
docker run --rm --entrypoint id macky-merch-api:local -un
# node
```

### Run the full stack (app + datastore)

```bash
docker compose up --build
curl http://localhost:3000/health
docker compose down -v      # -v also drops the redis volume
```

Redis is reachable from the app as `redis://cache:6379` over the private
`backend` network, and is **not** published to the host.

### Run without Docker

```bash
npm ci        # not `npm install` — see below
npm start     # http://localhost:3000
npm test
```

---

## What is in this repository

| Path | Purpose |
|---|---|
| `Dockerfile` | Three-stage build → non-root Alpine runtime image |
| `.dockerignore` | Keeps `node_modules`, `.git`, secrets and fixtures out of the build context |
| `docker-compose.yml` | **Bonus** — API + Redis on a private user-defined network |
| `.github/workflows/ci.yml` | Test → scan → build → smoke test → prove-the-scanner-works |
| `.github/workflows/codeql.yml` | GitHub-native SAST, on push/PR and weekly |
| `.github/dependabot.yml` | Automated patching for npm, base image and Actions |
| `.gitleaks.toml` | Secret-scanner config for the production gate |
| `security-demo/` | **The deliberately planted vulnerability + fake credentials** |
| `scripts/setup-branch-protection.sh` | **Bonus** — branch protection as a reproducible script |
| `server.js`, `server.test.js` | Unchanged baseline app and test |

---

## Pipeline at a glance

```
push / PR to main
│
├── test              Node 20 · 22 · 24  →  npm ci  →  npm test --coverage
├── dependency-scan   npm audit (gate: high+)  +  Trivy fs (vuln + secret block; misconfig reported)
├── secret-scan       Gitleaks over the FULL git history
├── lint-dockerfile   Hadolint (fails at warning)
├── vulnerability-demo  INVERTED gate — fails if the scanners find nothing
│
└── build   (needs: test, lint-dockerfile)
      ├── build `test` stage        → suite runs inside the image
      ├── build `runtime` stage
      ├── assert uid != 0           → non-root enforced mechanically
      ├── run container, poll /health until 200 + correct payload
      ├── Trivy image scan          → base-image CVEs, gate at HIGH/CRITICAL
      └── SBOM (CycloneDX) uploaded as an artifact
│
└── ci-passed   ← the single required status check for branch protection
```

Two deliberate choices in that graph:

**`build` runs the container, not just `docker build`.** A Dockerfile can build
cleanly and still produce an image that exits immediately — wrong `CMD`, a
missing prod dependency pruned by `--omit=dev`, a file the `node` user cannot
read. The smoke test polls `/health` for up to 30s and checks the payload, so
"the image builds" and "the image works" are separate, both-required claims.

**`ci-passed` exists so branch protection has one stable name.** If each job
were required individually, adding a Node version to the matrix or renaming a
job would silently remove it from the gate. Its `if: always()` matters too:
without it a skipped dependency leaves this job skipped, and branch protection
reads *skipped* as *not failing*.

---

## Architecture: the Dockerfile

### Why `node:22-alpine` and not `node:latest`

**Against `node:latest`** — it is not a version, it is a moving target. The
image built by CI today and the one a reviewer builds next month can be
different Node major versions. That defeats the point of pinning
`package-lock.json`: reproducible dependencies on top of an irreproducible
runtime. It is also the *largest* variant, shipping a full Debian userland with
build toolchains this app never uses.

**Against `node:22` (Debian bookworm)** — ~1.1 GB uncompressed versus ~150 MB
for Alpine. Size is not vanity here, it is the attack surface: every OS package
in the base is a package Trivy can find a CVE in, and one you then have to
triage even though the app never calls it. `curl`, `git`, `perl` and a compiler
in a production image are tools an attacker inherits for free after an RCE.

**Why 22 specifically** — Active LTS with security support running well past
this project's horizon. `package.json` declares `"engines": { "node": ">=20" }`
and CI tests against 20, 22 and 24, so the pin is tested rather than assumed.

**The honest trade-off with Alpine.** It uses musl libc, not glibc. Packages
with prebuilt native bindings may have no musl build and fall back to compiling
from source — or misbehave subtly. This app is pure JavaScript, so the trade is
free here; on a project pulling in native modules, `node:22-slim` (Debian,
~200 MB) is the better answer. I picked Alpine because the dependency tree
justified it, not as a reflex.

### Why multi-stage (bonus)

Three stages:

| Stage | Role |
|---|---|
| `deps` | `npm ci --omit=dev` — production tree only |
| `test` | full tree + `npm test`, run **during the image build** |
| `runtime` | app + production `node_modules`, and nothing else |

The final image never contains `jest`, `supertest`, the npm cache, or the
lockfile-resolution machinery. Fewer packages is directly fewer CVEs for the
image scan to report, and none of the discarded ones could ever have been
useful at runtime.

The `test` stage is not in the runtime chain — CI targets it explicitly. It
catches the "passes on the runner, fails in the container" class of bug, where
the suite depends on something the host has and the image does not.

### Why non-root

`USER node` uses the uid/gid 1000 account the official image already provides;
creating another user would add a layer for nothing. Everything after that line
runs unprivileged, so a container escape starts from an account that cannot
write to the app directory or bind ports below 1024.

The requirement is enforced, not just written down: CI runs
`docker run --entrypoint id <image> -u` and **fails the build if it returns 0**.
A future edit that drops the `USER` line breaks CI instead of quietly shipping
a root container.

Other hardening in the same spirit:

- **No package manager in the runtime image.** npm, npx, corepack and yarn are
  deleted from the final stage. The container runs `node server.js` and
  installs nothing at run time, so they are build-time tools that only add
  attack surface — and they were the source of 11 of the image's 13
  vulnerabilities (see [Challenges](#the-image-scan-that-was-right)).
- **`apk upgrade` for published OS patches**, because the base image is
  rebuilt on its own cadence and lags its own distribution's fixes.
- `COPY --chown` instead of a later `RUN chown -R`, which would rewrite every
  file into a new layer and roughly double the image size.
- `HEALTHCHECK` using Node's built-in `fetch`, so the image needs neither
  `curl` nor `wget` — two fewer binaries an attacker could use.
- Exec-form `CMD`, so `node` is PID 1 and handles `SIGTERM` directly instead of
  being wrapped by a shell that swallows it and forces a 10-second kill.
- Compose adds `read_only`, `cap_drop: ALL`, `no-new-privileges`, and binds the
  port to `127.0.0.1` rather than `0.0.0.0`.

### Why `.dockerignore` matters beyond build speed

Excluding `node_modules` avoids copying a host-built tree with the wrong
platform's native binaries. Excluding `.git` is the security-relevant one: git
config and logs routinely contain credentials, and anything copied into a layer
stays in that layer forever — deleting it in a later `RUN` does not remove it,
it just hides it from `ls`.

---

## Architecture: the security scanners

The spec asks for **at least one**. I integrated one from each of the three
distinct classes, because they cannot substitute for each other:

| Scanner | Class | Finds | Cannot find |
|---|---|---|---|
| **Trivy** | SCA + image | Known CVEs in npm packages *and* Alpine base-image packages | Bugs nobody has published an advisory for |
| **Gitleaks** | Secret detection | Credentials in the working tree **and in git history** | Anything that is not a credential |
| **CodeQL** | SAST | Flaws in code we wrote — injection sinks, unsafe flows | Vulnerable third-party dependencies |

Only CodeQL can find a bug that exists solely in this repository, because no
advisory database will ever list it. Only Trivy sees the OS packages in the
base image, where most image CVEs actually live. Only Gitleaks sees a secret
that was committed and then "removed" in a later commit.

### Why Trivy over `npm audit` alone

`npm audit` is in the pipeline too, as a second opinion on a different advisory
source — but it only ever sees `package-lock.json`. Trivy scans the **built
image**, which is where the Alpine packages live, and emits SARIF that lands in
the GitHub Security tab instead of scrolling past in a log. It needs no server
component and no account.

Both Trivy and Gitleaks run from **pinned official container images** rather
than marketplace actions. The `trivy-action` wrapper downloads and installs the
Trivy binary from GitHub Releases on every run; that install is an extra
dependency between the pipeline and the scan, and it is what broke on the first
attempt (see [Challenges](#the-scanner-that-could-not-install)). A pinned image
removes the installer entirely and makes the scanner version reproducible.

`--ignore-unfixed` on the blocking scans is deliberate: blocking a merge on
a CVE with no available patch gives the developer no action except to disable
the gate, which is how security checks die. Unfixed findings still reach the
Security tab, they just do not stop the queue.

### Why Gitleaks over TruffleHog

TruffleHog's default mode only reports **verified** secrets — it calls the
provider to check the credential is live. That is excellent for real leaks and
exactly wrong here: the planted credentials are fake, so they would never
verify, and the demo would report clean. Gitleaks is regex/entropy-based and
flags anything shaped like a credential, which is also the right behaviour for
a pre-merge gate, where you want to catch a key *before* it is live.

It runs from its pinned upstream image rather than the marketplace action,
which requires a `GITLEAKS_LICENSE` for organisation accounts.

The scan uses `fetch-depth: 0`. The default shallow clone fetches one commit,
so a secret committed on Monday and deleted on Tuesday would pass a Wednesday
scan while still being fully readable in the history.

---

## Vulnerability demonstration

### What was planted

Everything lives in [`security-demo/`](./security-demo/):

| File | Planted | Detected by |
|---|---|---|
| `package.json` / `package-lock.json` | `lodash@4.17.15`, `express@4.16.0`, `minimist@1.2.0` | Trivy, `npm audit` |
| `leaked-credentials.js` | Fake GitHub PAT and RSA private key | Gitleaks |

CI confirms **10 HIGH/CRITICAL dependency findings and 2 detected credentials**.
The headline finding is **`minimist@1.2.0` — CVE-2021-44906, CRITICAL**
(prototype pollution), alongside HIGH advisories in `lodash` (code injection
via `_.template`), `path-to-regexp` (ReDoS), `qs` (prototype pollution) and
`body-parser` (DoS).

### Local proof

```
$ cd security-demo && npm audit --audit-level=high

lodash  <=4.17.23
Severity: high
lodash vulnerable to Code Injection via `_.template` — GHSA-r5fr-rjxr-66jc
lodash vulnerable to Prototype Pollution via array path bypass — GHSA-f23m-r3pf-42rh

minimist  1.0.0 - 1.2.5
Severity: critical

path-to-regexp  <=0.1.12
Severity: high
path-to-regexp outputs backtracking regular expressions — GHSA-9wv6-86v2-598j

qs  <=6.15.3
Severity: high
qs vulnerable to Prototype Pollution — GHSA-hrpp-h998-j3pp
```

In CI the same evidence is written to the **workflow run summary** as rendered
tables (package / version / severity / CVE, and rule / file / line for the
secrets), so the proof is visible on the run page itself rather than buried in
step logs. Screenshots: `docs/screenshots/` once the workflow has run.

### The design decision worth defending

The obvious reading of the spec is "put the vulnerable package in
`package.json` and show the red X". I did not, for a reason:

1. **A green pipeline proves nothing about a scanner.** Green is
   indistinguishable from a scanner that is misconfigured, pointed at the wrong
   path, or silently finding zero things. That failure mode is common and
   invisible.
2. **A permanently red `main` makes branch protection meaningless.** The
   branch-protection bonus needs a required check that actually passes on good
   code. If `main` is red by design, the rule is either bypassed or removed.

So the fixture sits outside the app's dependency graph and outside the image
(`.dockerignore` excludes it), and the `vulnerability-demo` job treats it as an
**inverted gate**:

```yaml
- name: npm audit MUST flag the planted dependencies
  run: |
    npm audit --audit-level=high | tee audit.txt
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
      echo "::error::npm audit found nothing. The gate is broken."
      exit 1
    fi
```

All three scanners are asserted this way. **If a scanner stops working, the
build breaks** — which is the property a normal green check can never give you.
The production-path gates (`dependency-scan`, `secret-scan`, and the image scan in `build`)
are ordinary blocking checks and skip the fixture directory, so a real leak can
never hide behind a planted one.

The application's own dependencies are clean: `npm audit` on the root reports
**0 vulnerabilities**.

---

## Bonus features

### 1. Docker Compose ✅

`docker-compose.yml` runs the API and a Redis container on a private
user-defined `backend` network. Redis has **no `ports:` mapping** — it is
reachable at `redis://cache:6379` from inside the network and unreachable from
the host, which is the actual reason to define a network rather than lean on
the default bridge. `depends_on.condition: service_healthy` waits for Redis to
answer `PING`, not merely for the container to exist. `REDIS_URL` is wired into
the app's environment; `server.js` does not read it yet, because the starter
repo asks that its behaviour stay unchanged.

### 2. Multi-stage build ✅

Three stages, described [above](#why-multi-stage-bonus). The final image
carries the production dependency tree only; CI reports the resulting size in
the run summary.

### 3. Branch protection ✅

Applied via [`scripts/setup-branch-protection.sh`](./scripts/setup-branch-protection.sh):

```bash
gh auth login
./scripts/setup-branch-protection.sh
```

It is a script rather than a click-path because branch protection is repository
*state*, not repository *code* — configuring it by hand leaves no record of
what was set or why. Beyond the required `CI passed` check it sets
`strict: true` (a PR must be current with `main` before merging, which is what
actually prevents two individually-green PRs from merging into a broken main),
`enforce_admins` (a rule the author can bypass is a convention, not a control),
stale-review dismissal, linear history, and no force-pushes — the last of which
also stops someone erasing a committed secret from history instead of rotating
it.

### Beyond the spec

- **SBOM** (CycloneDX) generated from the built image and uploaded per run.
- **SARIF upload** — findings land in the GitHub Security tab, with history and
  per-PR annotations, not just in logs.
- **Hadolint** gates the Dockerfile before a build is attempted.
- **Dependabot** for npm, the base image, and the Actions themselves. Scanners
  tell you a dependency is vulnerable; this is what actually closes the gap.
- **Least-privilege `permissions:`** — `contents: read` by default, with jobs
  opting in to `security-events: write` individually.
- **`--audit-level=high`, not `critical` or `moderate`.** Too strict and people
  disable the gate; too loose and it never fires.

---

## Challenges faced

### The one that cost the most time: the scanner demo contradicts branch protection

The spec asks for two things that pull in opposite directions. Requirement 4
wants a deliberate vulnerability that the pipeline *catches* — which means a
failing check. The branch-protection bonus wants a required check that *passes*
on good code. Do the obvious thing for both and you get a repository whose
`main` is permanently red and whose branch protection therefore has to be
bypassed on every merge.

My first attempt was `continue-on-error: true` on the scanning job. It "worked"
— vulnerability visible, pipeline green — but I was uneasy about it, and on
re-reading the job I understood why: `continue-on-error` makes the step green
*whatever* it reports. A scanner finding ten CVEs and a scanner that crashed on
startup produce the identical green tick. I had built exactly the thing the
exam is testing against: security theatre.

What fixed it was inverting the assertion. Instead of "run the scanner and
tolerate failure", the job is "run the scanner and **fail if it reports
nothing**". Same green pipeline, opposite guarantee — a broken scanner now
breaks the build. Isolating the fixture in `security-demo/` (excluded from the
production gates and from the image) is what makes that possible without
shipping a vulnerable app.

The general lesson I took from it: *a check that cannot fail is not a check.*
Before trusting any gate, I now ask what it does when the tool underneath it is
broken, not just when the code is bad.

### GitHub blocked my own planted secret

The first `git push` was **rejected by GitHub**, not by my pipeline:

```
Resolve the following violations before pushing again
  - Push cannot contain secrets
    —— Stripe API Key ——
       path: security-demo/leaked-credentials.js:22
```

GitHub's push protection scans commits server-side and refuses the push
outright. I had wired up three scanners and not noticed there was a fourth one
I did not configure and could not see until it fired.

It offered an "allow this secret" link. I did not use it. That link
permanently allowlists the secret on the repository, and reaching for the
bypass the first time a security control fires is the exact habit that makes
these controls worthless — the same reasoning that made me reject
`continue-on-error` earlier.

My first fix was a guess. Real Stripe live keys are `sk_live_` plus 24
characters, so I assumed GitHub was checking that length and changed the
fixture to a different one. The push was rejected again, identically. The
guess was wrong, and I had spent a round trip confirming a theory I had no
evidence for.

The actual answer was that I did not need a Stripe key at all. The demo needs
Gitleaks to fire; it does not need one specific provider. The fixture already
plants an AWS key pair, a GitHub personal access token and an RSA private key,
which trip three separate Gitleaks rules. Removing the Stripe entry cost the
demonstration nothing. The remaining three are not blocked by GitHub, and for
understandable reasons: the fake PAT fails GitHub's internal checksum, and the
AWS pair is Amazon's own published documentation example.

Three things I took from it. **Security controls come in layers you did not
install** — the platform was running a check of its own, and discovering it by
being blocked is a good outcome, not an obstacle. **When a scanner fires,
find out which rule matched and why** rather than guessing at the pattern, as
I did, and burning a push on it. And **the cheapest fix is often to remove the
thing rather than to outsmart the tool** — I was trying to craft a credential
that fooled one scanner and not the other, when the requirement never asked
for that credential in the first place.

### The scanner that could not install

The first pipeline run failed in all three Trivy jobs, and the log showed the
failure was not in scanning at all:

```
Run echo "installing Trivy binary"
aquasecurity/trivy info checking GitHub for tag 'v0.65.0'
aquasecurity/trivy info found version: 0.65.0 for v0.65.0/Linux/64bit
Error: Process completed with exit code 1
```

`trivy-action` does not contain Trivy. It downloads and installs the binary
from GitHub Releases each run, and that download failed. I had guessed the
cause was the CVE database being rate-limited — a common CI failure — but the
log showed it never got as far as the database.

The fix was to notice I had already solved this problem once. Gitleaks was
running from its pinned upstream container image, precisely so there was no
installer to break. Trivy was going through a wrapper that adds a runtime
download for no benefit. Running `aquasec/trivy:0.65.0` directly removed the
installer, pinned the exact scanner version, and made both scanners consistent.

While rewriting it I also stopped handing Trivy the Docker socket to scan the
built image, and used `docker save` plus `--input` instead. Mounting the socket
into a container gives it full control of the Docker daemon, which is far more
authority than something that only needs to read a filesystem.

The lesson was about diagnosis, not Trivy. **Every** Trivy step failed,
including the two configured with `exit-code: 0` that cannot fail on findings.
Uniform failure across configurations that should behave differently meant the
tool was never running — which pointed at setup, not results, before I read a
single line of log. Symptoms that *should* differ but don't are the useful
signal.

### The image scan that was right

The last job to go green was the image scan, and unlike everything else in
this section it was not a mistake of mine — the scanner was correct. It
reported 13 findings: 2 HIGH in Alpine's `libcrypto3`/`libssl3`, and 11 in
Node packages including a CRITICAL in `tar`.

The instinct is to argue with the gate. What made the decision easy was
reading *where* the findings were:

```
app/node_modules/...                                       0    (every row)
usr/local/lib/node_modules/npm/node_modules/tar            3    (1 CRITICAL)
usr/local/lib/node_modules/npm/node_modules/brace-expansion 3
usr/local/lib/node_modules/npm/node_modules/pacote          2
usr/local/lib/node_modules/npm/node_modules/sigstore        1
...
```

The application's own dependency tree was completely clean. Every Node finding
was inside **npm's** bundled dependencies — the package manager that ships
inside `node:22-alpine`.

Which raised the actual question: why is a package manager in a production
image at all? This container runs `node server.js`. It installs nothing at run
time. npm is a build-time tool, and the multi-stage build already exists to
keep build-time things out of the runtime stage — I had simply not noticed that
the base image was smuggling one in underneath me. Deleting npm, npx, corepack
and yarn removed all 11 findings at once, and made the image smaller.

The two Alpine findings had a published fix (`3.5.7-r0` → `3.5.8-r0`) that the
base image had not picked up yet, so `apk upgrade` collects them. Hadolint's
DL3017 objects to `apk upgrade` on reproducibility grounds, which is a fair
objection; I suppressed that one rule inline with a comment explaining the
trade-off, rather than lowering the lint threshold and losing every other check
it performs.

The lesson is the one I would most want a reviewer to take from this repo.
**A finding is information about your design, not an obstacle to your
pipeline.** The fix that made the gate pass was not a suppression or a severity
downgrade — it was removing software that should never have been in the
artefact. If I had reached for `--severity CRITICAL` or an ignore file, the
image would still contain a package manager it has no use for, and the
pipeline would have taught me nothing.

### The credential that was too fake to detect

The fixture originally planted three credentials. The first CI run reported
two:

```
Gitleaks detected 2 planted credential(s)
  private-key   line 25
  github-pat    line 22
```

The missing one was an AWS key pair. Before committing it I had tested
Gitleaks' `aws-access-token` regex against the string locally and confirmed it
matched — so I recorded in this README that it would be caught. It was not.

Gitleaks does not only run rules; it also applies an allowlist that suppresses
known-fake values. The key I used was `AKIAIOSFODNN7EXAMPLE`, Amazon's own
published documentation example, and it contains the string `EXAMPLE`. I chose
it precisely *because* it was a safe published placeholder, which turns out to
be exactly why the scanner ignores it.

I removed it rather than hunting for an AWS key that is realistic enough to
detect but not realistic enough to trip GitHub's push protection — the same
trap the Stripe key set earlier. Two confirmed detections demonstrate the gate;
a third adds nothing.

The real lesson is about what I had verified. **Testing a rule's regex is not
testing the tool.** The regex was a component of the scanner; the allowlist,
which I did not model, was the part that decided the outcome. A local check
against my own mental model of a tool gave me false confidence, and it took
real CI output to correct it — which is the argument for the inverted gate in
the first place: assertions against a tool's *actual* output, not against what
I believe the tool does.

### Two smaller ones

**`npm ci` vs `npm install`.** The spec says `npm install`. In CI that is the
wrong verb — it will happily resolve a newer version than the lockfile and
rewrite `package-lock.json`, so the tree you tested is not the tree you
reviewed. `npm ci` installs the locked tree exactly and errors if the manifest
and lockfile disagree. I kept the spec's *intent* (install dependencies) and
used the correct command, which also made the `setup-node` cache effective.

**"The image builds" ≠ "the image runs".** My first `build` job stopped at
`docker build`, and it went green on an image that exited on startup, because
`--omit=dev` had pruned a package the app needed at runtime. `docker build`
only proves the Dockerfile parses and its commands exit 0. That is why the job
now starts the container and polls `/health` until it returns a 200 with the
expected payload — and why the non-root requirement is asserted with
`docker run --entrypoint id` instead of trusted to a line in the Dockerfile.

---

## Requirements checklist

| Requirement | Status | Where |
|---|---|---|
| Starter repository forked | ✅ | this repo |
| Dockerfile builds and runs the app | ✅ | `Dockerfile` |
| Runs as a non-root user | ✅ | `USER node` + CI assertion on uid |
| `.dockerignore` included | ✅ | `.dockerignore` |
| Workflow triggers on push + PR to `main` | ✅ | `ci.yml` |
| Checkout → Node → install → test | ✅ | `test` job (Node 20/22/24) |
| Docker image built in CI | ✅ | `build` job, plus a live smoke test |
| ≥1 security scanner integrated | ✅ | Trivy + Gitleaks + CodeQL + `npm audit` |
| Deliberate vulnerability planted & caught | ✅ | `security-demo/`, `vulnerability-demo` job |
| README: setup instructions | ✅ | [Quick start](#quick-start) |
| README: base image rationale | ✅ | [Why `node:22-alpine`](#why-node22-alpine-and-not-nodelatest) |
| README: scanner rationale | ✅ | [Security scanners](#architecture-the-security-scanners) |
| README: vulnerability demonstration | ✅ | [Vulnerability demonstration](#vulnerability-demonstration) |
| README: challenges faced | ✅ | [Challenges faced](#challenges-faced) |
| **Bonus** — Docker Compose + DB | ✅ | `docker-compose.yml` |
| **Bonus** — Multi-stage build | ✅ | `Dockerfile` (3 stages) |
| **Bonus** — Branch protection | ✅ | `scripts/setup-branch-protection.sh` |
