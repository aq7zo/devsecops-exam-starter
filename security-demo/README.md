# `security-demo/` — the deliberate vulnerability

This directory is the exam's required planted vulnerability. It is a **test
fixture for the pipeline**, not part of the application.

| File | What is planted | Caught by |
|---|---|---|
| `package.json` + `package-lock.json` | `lodash@4.17.15`, `express@4.16.0`, `minimist@1.2.0` — one CRITICAL and several HIGH advisories | Trivy (`fs` scan), `npm audit` |
| `leaked-credentials.js` | Fake GitHub PAT and RSA private key | Gitleaks |

## Why it is isolated instead of planted in the real app

Two things need to be true at once, and putting the vulnerability in the
application's own `package.json` makes them mutually exclusive:

1. **The scanners must demonstrably fire.** A green pipeline proves nothing —
   it is indistinguishable from a pipeline whose scanner is misconfigured and
   silently finding nothing.
2. **The pipeline must stay mergeable.** The branch-protection bonus requires
   a required status check that actually passes on good code. A permanently
   red `main` makes branch protection meaningless.

So the fixture lives here, out of the dependency graph and out of the image
(`.dockerignore` excludes it), and CI treats it as an **inverted gate**: the
`vulnerability-demo` job fails if the scanners come back *clean*. A broken or
silently-disabled scanner therefore breaks the build, which is the property
that actually matters.

The production-path scanners (`dependency-scan`, `secret-scan`,
the image scan in `build`) are ordinary blocking gates and skip this directory.

## Reproduce locally

```bash
# Dependency vulnerabilities
cd security-demo && npm audit --audit-level=high

# With Trivy
trivy fs --scanners vuln --severity HIGH,CRITICAL security-demo/

# Secrets
gitleaks detect --no-git --source security-demo/ -v
```
