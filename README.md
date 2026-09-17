# Macky Merch API — Secure Delivery Pipeline

LSCS DevSecOps Engineering Challenge · 41st LSCS · Term 1

A containerised Express API wrapped in a CI/CD pipeline that tests it, builds it, proves the container actually serves traffic, and blocks the merge if any of three classes of security scanner finds something.

- [Setup](#setup)
- [Pipeline](#pipeline)
- [Why this base image](#why-this-base-image)
- [Why these scanners](#why-these-scanners)
- [Vulnerability demonstration](#vulnerability-demonstration)
- [Bonus features](#bonus-features)
- [Challenges faced](#challenges-faced)
- [Requirements checklist](#requirements-checklist)

## Setup

Build and run the container:

```bash
docker build -t macky-merch-api:local .
docker run --rm --init -p 3000:3000 macky-merch-api:local

curl http://localhost:3000/health
# {"status":"OK","message":"Macky Merch API is running smoothly."}
```

Confirm it is **not** running as root:

```bash
docker run --rm --entrypoint id macky-merch-api:local -un
# node
```

Full stack (app + Redis), or no Docker at all:

```bash
docker compose up --build      # then: docker compose down -v
```

```bash
npm ci && npm start            # npm ci, not npm install — see Challenges
npm test
```

## Pipeline

`.github/workflows/ci.yml`, on every push and pull request to `main`:

```
├── test               Node 20 · 22 · 24 → npm ci → npm test
├── dependency-scan    npm audit (gate: high+) + Trivy fs
├── secret-scan        Gitleaks over the FULL git history
├── lint-dockerfile    Hadolint
├── vulnerability-demo INVERTED gate — fails if the scanners find nothing
│
└── build   (needs: test, lint-dockerfile)
      ├── build test stage         → suite runs inside the image
      ├── assert uid != 0          → non-root enforced mechanically
      ├── run container, poll /health until 200 + correct payload
      ├── Trivy image scan         → gate at HIGH/CRITICAL
      └── SBOM (CycloneDX) artifact
│
└── ci-passed   ← the single required status check for branch protection
```

Two choices in that graph are deliberate:

**`build` runs the container, not just `docker build`.** A Dockerfile can build cleanly and still produce an image that exits immediately — wrong `CMD`, a prod dependency pruned by `--omit=dev`, a file the `node` user cannot read. The smoke test polls `/health` and checks the payload, so "the image builds" and "the image works" are separate, both-required claims.

**`ci-passed` gives branch protection one stable name.** Requiring each job individually means adding a Node version to the matrix silently removes it from the gate. Its `if: always()` matters too: without it, a skipped dependency leaves this job skipped, and branch protection reads *skipped* as *not failing*.

| Path | Purpose |
|---|---|
| `Dockerfile` | Three-stage build → non-root Alpine runtime image |
| `.dockerignore` | Keeps `node_modules`, `.git` and secrets out of the build context |
| `docker-compose.yml` | **Bonus** — API + Redis on a private network |
| `.github/workflows/` | `ci.yml` (test → scan → build → smoke test) and `codeql.yml` |
| `.gitleaks.toml`, `.github/dependabot.yml` | Scanner config; automated patching |
| `security-demo/` | The planted vulnerabilities and fake credentials |
| `scripts/setup-branch-protection.sh` | **Bonus** — branch protection as a script |

## Why this base image

`node:22-alpine`.

**Against `node:latest`** — it is not a version, it is a moving target. The image CI builds today and the one a reviewer builds next month can be different Node majors, which defeats the point of pinning `package-lock.json`: reproducible dependencies on an irreproducible runtime. It is also the largest variant, shipping a full Debian userland this app never uses.

**Against `node:22` (Debian)** — ~1.1 GB against ~150 MB for Alpine. Size here is attack surface: every OS package in the base is a package Trivy can find a CVE in and you then have to triage. `curl`, `git`, `perl` and a compiler in a production image are tools an attacker inherits for free after an RCE.

**Why 22** — Active LTS with security support past this project's horizon. CI tests against 20, 22 and 24, so the pin is tested rather than assumed.

**The honest trade-off.** Alpine uses musl, not glibc. Packages with prebuilt native bindings may have no musl build and fall back to compiling from source. This app is pure JavaScript, so the trade is free here; on a project pulling in native modules, `node:22-slim` is the better answer.

### Three stages, and non-root

| Stage | Role |
|---|---|
| `deps` | `npm ci --omit=dev` — production tree only |
| `test` | full tree + `npm test`, run **during the image build** |
| `runtime` | app + production `node_modules`, and nothing else |

The final image never contains `jest`, `supertest` or the npm cache. Fewer packages is directly fewer CVEs. The `test` stage is not in the runtime chain — CI targets it explicitly, which catches the "passes on the runner, fails in the container" class of bug.

`USER node` uses the uid 1000 account the official image already provides. The requirement is enforced, not just written down: CI runs `docker run --entrypoint id <image> -u` and **fails the build if it returns 0**, so a future edit that drops the `USER` line breaks CI instead of quietly shipping a root container.

Other hardening in the same spirit:

- **No package manager in the runtime image** — npm, npx, corepack and yarn are deleted. They were the source of 11 of the image's 13 CVEs (see [Challenges](#the-image-scan-that-was-right)).
- `apk upgrade`, because the base image lags its own distribution's published patches.
- `HEALTHCHECK` via Node's built-in `fetch`, so the image needs neither `curl` nor `wget`.
- Exec-form `CMD`, so `node` is PID 1 and handles `SIGTERM` directly instead of being wrapped by a shell that swallows it.
- Compose adds `read_only`, `cap_drop: ALL`, `no-new-privileges`, and binds to `127.0.0.1`.

`.dockerignore` excludes `.git` for a security reason, not a speed one: git config and logs routinely contain credentials, and anything copied into a layer stays in that layer forever — deleting it in a later `RUN` hides it from `ls`, nothing more.

## Why these scanners

The spec asks for at least one. I integrated one from each of the three classes, because they cannot substitute for each other:

| Scanner | Class | Finds | Cannot find |
|---|---|---|---|
| **Trivy** | SCA + image | CVEs in npm packages *and* Alpine base-image packages | Bugs with no published advisory |
| **Gitleaks** | Secret detection | Credentials in the working tree **and in git history** | Anything that is not a credential |
| **CodeQL** | SAST | Flaws in code we wrote — injection sinks, unsafe flows | Vulnerable third-party dependencies |

Only CodeQL can find a bug that exists solely in this repository. Only Trivy sees the OS packages in the base image, where most image CVEs actually live. Only Gitleaks sees a secret that was committed and then "removed" in a later commit.

**Trivy over `npm audit` alone.** `npm audit` is in the pipeline too, as a second opinion from a different advisory database — but it only ever sees `package-lock.json`. Trivy scans the built image, where the Alpine packages live, and emits SARIF into the GitHub Security tab instead of scrolling past in a log.

**Gitleaks over TruffleHog.** TruffleHog's default mode only reports *verified* secrets — it calls the provider to check the credential is live. That is exactly wrong here: the planted credentials are fake, so they would never verify and the demo would report clean. Gitleaks is regex/entropy-based, which is also the right behaviour for a pre-merge gate, where you want to catch a key *before* it is live. Its scan uses `fetch-depth: 0`; the default shallow clone would pass a secret committed on Monday and deleted on Tuesday while it is still fully readable in history.

Both run from **pinned official container images** rather than marketplace actions, which download the scanner binary on every run — an extra dependency between the pipeline and the scan, and the thing that broke first (see [Challenges](#three-smaller-ones)).

`--ignore-unfixed` on the blocking scans is deliberate: blocking a merge on a CVE with no available patch leaves the developer no action except disabling the gate, which is how security checks die. Unfixed findings still reach the Security tab.

## Vulnerability demonstration

Everything planted lives in [`security-demo/`](./security-demo/):

| File | Planted | Detected by |
|---|---|---|
| `package.json` | `lodash@4.17.15`, `express@4.16.0`, `minimist@1.2.0` | Trivy, `npm audit` |
| `leaked-credentials.js` | Fake GitHub PAT and RSA private key | Gitleaks |

CI confirms **10 HIGH/CRITICAL dependency findings and 2 detected credentials**. The headline is **`minimist@1.2.0` — CVE-2021-44906, CRITICAL** (prototype pollution), alongside HIGH advisories in `lodash` (code injection via `_.template`), `path-to-regexp` (ReDoS) and `qs` (prototype pollution). CI writes the same evidence to the workflow run summary as rendered tables; screenshots in `docs/screenshots/`.

### Reproduce it — needs only Docker

Same pinned images and flags CI uses, run from the repository root. On PowerShell substitute `$($PWD.Path)`; on Git Bash prefix the commands with `MSYS_NO_PATHCONV=1`.

```bash
# 1. Gitleaks — the planted credentials
docker run --rm -v "$PWD/security-demo:/scan" \
  zricethezav/gitleaks:v8.21.2 detect --source /scan --no-git --redact --verbose

# 2. Trivy — the planted dependencies
docker run --rm -v trivy-cache:/root/.cache/trivy -v "$PWD:/work" -w /work \
  aquasec/trivy:0.65.0 fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 security-demo

# 3. npm audit — second advisory database, same files
docker run --rm -v "$PWD/security-demo:/demo" -w /demo node:22-alpine npm audit --audit-level=high

# 4. The real application — expect CLEAN, exit code 0
docker run --rm -v trivy-cache:/root/.cache/trivy -v "$PWD:/work" -w /work \
  aquasec/trivy:0.65.0 fs --scanners vuln --severity HIGH,CRITICAL \
  --ignore-unfixed --skip-dirs security-demo --exit-code 1 .
```

| # | Scanner | Findings | Exit |
|---|---|---|---|
| 1 | Gitleaks | 2 credentials (`github-pat` L22, `private-key` L25) | **1** |
| 2 | Trivy | 10 HIGH/CRITICAL | **1** |
| 3 | `npm audit` | 9 (1 critical, 5 high, 3 low) | **1** |
| 4 | Trivy, the application | none | **0** |

The contrast between rows 1–3 and row 4 *is* the demonstration: the fixture is red, the shipped application is green.

> [!NOTE]
> Trivy and `npm audit` disagree on the count (10 against 9) over identical files. They read different advisory databases with overlapping but non-identical coverage — which is why `ci.yml` runs both rather than picking one.

### The design decision worth defending

The obvious reading of the spec is "put the vulnerable package in `package.json` and show the red X". I did not, for two reasons:

1. **A green pipeline proves nothing about a scanner.** Green is indistinguishable from a scanner that is misconfigured, pointed at the wrong path, or silently finding zero things.
2. **A permanently red `main` makes branch protection meaningless.** The branch-protection bonus needs a required check that actually passes on good code.

So the fixture sits outside the app's dependency graph and outside the image, and the `vulnerability-demo` job treats it as an **inverted gate**:

```yaml
- name: npm audit MUST flag the planted dependencies
  run: |
    npm audit --audit-level=high | tee audit.txt
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
      echo "::error::npm audit found nothing. The gate is broken."
      exit 1
    fi
```

All three scanners are asserted this way. **If a scanner stops working, the build breaks** — the property a normal green check can never give you. The production-path gates are ordinary blocking checks and skip the fixture directory, so a real leak can never hide behind a planted one.

## Bonus features

**Docker Compose.** API and Redis on a private user-defined `backend` network. Redis has **no `ports:` mapping** — it is reachable at `redis://cache:6379` from inside the network and unreachable from the host, which is the actual reason to define a network rather than lean on the default bridge. `depends_on.condition: service_healthy` waits for Redis to answer `PING`, not merely for the container to exist.

**Multi-stage build.** Three stages, [described above](#three-stages-and-non-root); the final image carries the production dependency tree only.

**Branch protection.** Applied via [`scripts/setup-branch-protection.sh`](./scripts/setup-branch-protection.sh) — `gh auth login`, then run it. A script rather than a click-path, because branch protection is repository *state*, and configuring it by hand leaves no record of what was set or why. Beyond the required `CI passed` check it sets `strict: true`, `enforce_admins` (a rule the author can bypass is a convention, not a control), stale-review dismissal, linear history, and no force-pushes — the last of which also stops someone erasing a committed secret from history instead of rotating it.

**Beyond the spec:** CycloneDX SBOM per run · SARIF upload to the Security tab · Hadolint gating the Dockerfile before a build is attempted · Dependabot for npm, the base image and the Actions themselves · least-privilege `permissions:`.

## Challenges faced

### The scanner demo contradicts branch protection

The spec asks for two things that pull in opposite directions. Requirement 4 wants a deliberate vulnerability the pipeline *catches* — which means a failing check. The branch-protection bonus wants a required check that *passes* on good code. Do the obvious thing for both and `main` is permanently red, so the protection rule gets bypassed or removed.

My first attempt was `continue-on-error: true` on the scanning job. It "worked" — vulnerability visible, pipeline green — but re-reading the job I understood why I was uneasy: `continue-on-error` makes the step green *whatever* it reports. A scanner finding ten CVEs and a scanner that crashed on startup produce an identical green tick. I had built exactly the thing the exam is testing against.

What fixed it was inverting the assertion. Instead of "run the scanner and tolerate failure", the job is "run the scanner and **fail if it reports nothing**". Same green pipeline, opposite guarantee. The lesson I took from it: *a check that cannot fail is not a check.* Before trusting any gate, I now ask what it does when the tool underneath it is broken, not just when the code is bad.

### The image scan that was right

The last job to go green was the image scan, and unlike the rest of this section it was not a mistake of mine — the scanner was correct. It reported 13 findings: 2 HIGH in Alpine's `libcrypto3`/`libssl3`, and 11 in Node packages including a CRITICAL in `tar`.

The instinct is to argue with the gate. Reading *where* the findings were made the decision easy: the application's own dependency tree was completely clean, and every Node finding sat inside **npm's** bundled dependencies — the package manager shipping inside `node:22-alpine`. Which raised the actual question: why is a package manager in a production image at all? This container runs `node server.js` and installs nothing at run time. Deleting npm, npx, corepack and yarn removed all 11 findings at once and made the image smaller. The 2 Alpine findings had a published fix the base image had not yet picked up, which `apk upgrade` collects.

**A finding is information about your design, not an obstacle to your pipeline.** Reaching for `--severity CRITICAL` or an ignore file would have left the image carrying a package manager it has no use for, and taught me nothing.

### Three smaller ones

**GitHub blocked my own planted secret.** Push protection rejected the first `git push` server-side over a fake Stripe key — a fourth scanner I had not configured and could not see until it fired. It offered an "allow this secret" link; using it permanently allowlists the secret, so I removed the key instead. The fixture never needed that specific provider: the remaining PAT and RSA key trip two Gitleaks rules and demonstrate the gate fine. A fifth planted credential, `AKIAIOSFODNN7EXAMPLE`, went undetected for the opposite reason — Gitleaks allowlists known-fake values containing `EXAMPLE`, even though I had confirmed its regex matched. Testing a rule's regex is not testing the tool.

**The scanner that could not install.** Every Trivy job failed on the first run, including the two configured with `exit-code: 0` that cannot fail on findings. Uniform failure across configurations that should behave differently meant the tool was never running — setup, not results, before reading a line of log. `trivy-action` does not contain Trivy; it downloads the binary from GitHub Releases each run, and that download failed. Gitleaks was already running from a pinned upstream image precisely so there was no installer to break, so switching Trivy to `aquasec/trivy:0.65.0` removed the installer and pinned the version.

**`npm ci` against `npm install`.** The spec says `npm install`. In CI that is the wrong verb — it can resolve a newer version than the lockfile and rewrite `package-lock.json`, so the tree you tested is not the tree you reviewed. `npm ci` installs the locked tree exactly and errors if manifest and lockfile disagree.

## Requirements checklist

| Requirement | Where |
|---|---|
| Dockerfile builds and runs the app | `Dockerfile` |
| Runs as a non-root user | `USER node` + CI assertion on uid |
| `.dockerignore` included | `.dockerignore` |
| Workflow triggers on push + PR to `main` | `ci.yml` |
| Checkout → Node → install → test | `test` job (Node 20/22/24) |
| Docker image built in CI | `build` job, plus a live smoke test |
| At least one security scanner integrated | Trivy + Gitleaks + CodeQL + `npm audit` |
| Deliberate vulnerability planted and caught | `security-demo/`, `vulnerability-demo` job |
| README: setup, base image, scanners, demo, challenges | above |
| **Bonus** — Compose + DB, multi-stage, branch protection | all three |
