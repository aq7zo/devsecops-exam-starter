#!/usr/bin/env bash
# Automated validation of every requirement in the LSCS DevSecOps exam spec.
#
#   ./scripts/validate.sh          static checks + live Docker checks
#   ./scripts/validate.sh --quick  static checks only (no image build)
#
# Static checks read the files. Live checks build the image and run it, so they
# need Docker; they are skipped (not failed) when Docker is unavailable.
set -uo pipefail
cd "$(dirname "$0")/.."

QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
PASS=0; FAIL=0; SKIP=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIP=$((SKIP+1)); }
sect() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# check <description> <command...>  -- passes when the command exits 0
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# grepf <description> <pattern> <file>
grepf() { if [ -f "$3" ] && grep -Eq "$2" "$3"; then ok "$1"; else bad "$1"; fi; }

CI=.github/workflows/ci.yml

sect "1. Target application (starter repo)"
check "server.js exists"                     test -f server.js
check "Jest test exists"                     test -f server.test.js
grepf "/health endpoint present"             "/health"        server.js
grepf "npm test wired to jest"               '"test": *"jest' package.json

sect "2. Containerization (Docker)"
check "Dockerfile exists"                    test -f Dockerfile
check ".dockerignore exists"                 test -f .dockerignore
grepf "Dockerfile sets a non-root USER"      '^USER[[:space:]]+(node|[0-9]+)' Dockerfile
grepf ".dockerignore excludes node_modules"  '^node_modules/?' .dockerignore
grepf ".dockerignore excludes .git"          '^\.git/?$'       .dockerignore
grepf "multi-stage build (bonus)"            '^FROM .* AS '    Dockerfile
grepf "pinned base image, not :latest"       '^FROM node:[0-9]' Dockerfile
if grep -Eq '^FROM .*:latest' Dockerfile; then bad "no :latest base image"; else ok "no :latest base image"; fi

sect "3. Continuous integration (GitHub Actions)"
check "ci.yml exists"                        test -f "$CI"
grepf "triggers on push to main"             'push:'            "$CI"
grepf "triggers on pull_request to main"     'pull_request:'    "$CI"
grepf "branches: [main] targeted"            'branches: *\[main\]' "$CI"
grepf "checks out code"                      'actions/checkout@' "$CI"
grepf "sets up Node.js"                      'actions/setup-node@' "$CI"
grepf "installs dependencies"                'npm (ci|install)' "$CI"
grepf "runs tests"                           'npm test'         "$CI"
grepf "builds the Docker image"              'docker/build-push-action@|docker build' "$CI"

sect "4. Security scanning"
grepf "dependency scan (Trivy)"              'trivy'            "$CI"
grepf "dependency scan (npm audit)"          'npm audit'        "$CI"
grepf "secret scan (Gitleaks)"               'gitleaks'         "$CI"
check "CodeQL workflow exists"               test -f .github/workflows/codeql.yml
check "deliberately vulnerable fixture"      test -f security-demo/package.json
check "deliberately planted fake secret"     test -f security-demo/leaked-credentials.js
grepf "CI job proves the scanners fire"      'vulnerability-demo' "$CI"
grepf "fixture is excluded from the prod secret gate" 'security-demo' .gitleaks.toml

sect "5. Documentation (README.md)"
for h in "Quick start" "Architecture: the Dockerfile" "node:22-alpine" \
         "Architecture: the security scanners" "Vulnerability demonstration" \
         "Challenges faced"; do
  grepf "README covers: $h" "$h" README.md
done

sect "6. Bonus features"
check "docker-compose.yml exists"            test -f docker-compose.yml
grepf "compose defines a datastore service"  'redis|postgres'   docker-compose.yml
grepf "compose uses a user-defined network"  '^networks:'       docker-compose.yml
check "branch-protection script"             test -f scripts/setup-branch-protection.sh
grepf "single aggregate check for branch protection" 'ci-passed' "$CI"

sect "Live checks"
if [ "$QUICK" = 1 ]; then
  skip "live checks disabled (--quick)"
elif ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  skip "Docker unavailable — image build, non-root and /health checks skipped"
else
  TAG="macky-merch-api:validate-$$"
  if docker build --target runtime -t "$TAG" . >/tmp/validate-build.log 2>&1; then
    ok "image builds"

    UID_IN=$(docker run --rm --entrypoint id "$TAG" -u 2>/dev/null)
    if [ -n "$UID_IN" ] && [ "$UID_IN" != "0" ]; then
      ok "container runs as non-root (uid $UID_IN)"
    else
      bad "container runs as root (uid ${UID_IN:-unknown})"
    fi

    if ! docker run --rm --entrypoint sh "$TAG" -c 'ls /app/.git' >/dev/null 2>&1; then
      ok ".git absent from the image"
    else
      bad ".git leaked into the image"
    fi

    docker rm -f validate-smoke >/dev/null 2>&1
    if docker run -d --init --name validate-smoke -p 13000:3000 "$TAG" >/dev/null 2>&1; then
      HEALTHY=1
      for _ in $(seq 1 30); do
        if curl -fsS http://localhost:13000/health 2>/dev/null | grep -q '"status":"OK"'; then
          HEALTHY=0; break
        fi
        sleep 1
      done
      [ "$HEALTHY" = 0 ] && ok "/health returns status OK from the container" \
                         || bad "/health never returned OK (docker logs validate-smoke)"
      docker rm -f validate-smoke >/dev/null 2>&1
    else
      bad "container failed to start"
    fi
  else
    bad "image builds (see /tmp/validate-build.log)"
  fi
  docker rmi -f "$TAG" >/dev/null 2>&1
fi

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
