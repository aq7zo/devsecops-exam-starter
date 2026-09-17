#!/usr/bin/env bash
#
# Local verification of the exam's submission checklist: the same assertions
# CI makes, runnable before pushing. Section numbering follows the spec's own
# requirement numbers.
#
# Usage:
#   ./scripts/verify.sh            # everything, including the Docker build
#   ./scripts/verify.sh --fast     # skip anything that builds or runs an image
#
# Exit code is 0 only if every required check passed. Bonus checks report but
# never fail the run -- they are optional in the spec.

set -uo pipefail
cd "$(dirname "$0")/.."

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

IMAGE="macky-merch-api:verify"
PASS=0; FAIL=0; SKIP=0; BONUS_MISSING=0

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
else G=""; R=""; Y=""; D=""; N=""; fi

ok()    { PASS=$((PASS+1)); printf '%s  PASS %s %s\n' "$G" "$N" "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '%s  FAIL %s %s\n' "$R" "$N" "$1"; [[ -n "${2:-}" ]] && printf '       %s%s%s\n' "$D" "$2" "$N"; }
skip()  { SKIP=$((SKIP+1)); printf '%s  SKIP %s %s %s(%s)%s\n' "$Y" "$N" "$1" "$D" "$2" "$N"; }
bonus() { BONUS_MISSING=$((BONUS_MISSING+1)); printf '%s  MISS %s %s %s(bonus, optional)%s\n' "$Y" "$N" "$1" "$D" "$N"; }
head2() { printf '\n%s%s%s\n' "$D" "$1" "$N"; }

# check <description> <command...> -- passes if the command exits 0
check() { local desc="$1"; shift; if out=$("$@" 2>&1); then ok "$desc"; else bad "$desc" "${out##*$'\n'}"; fi; }

head2 "2. Containerization (Docker)"

[[ -f Dockerfile ]] && ok "Dockerfile present" || bad "Dockerfile present"
[[ -f .dockerignore ]] && ok ".dockerignore present" || bad ".dockerignore present"

grep -qE '^\s*node_modules/?\s*$' .dockerignore \
  && ok ".dockerignore excludes node_modules" \
  || bad ".dockerignore excludes node_modules"

grep -qE '^\s*\.git/?\s*$' .dockerignore \
  && ok ".dockerignore excludes .git" \
  || bad ".dockerignore excludes .git"

grep -qE '^\s*USER\s+(node|[0-9]+)' Dockerfile \
  && ok "Dockerfile declares a non-root USER" \
  || bad "Dockerfile declares a non-root USER" "no USER instruction found"

[[ $(grep -cE '^\s*FROM ' Dockerfile) -ge 2 ]] \
  && ok "Multi-stage build ($(grep -cE '^\s*FROM ' Dockerfile) stages)" \
  || bonus "Multi-stage build"

head2 "1/3. Application, tests, image"

if command -v npm > /dev/null 2>&1; then
  [[ -d node_modules ]] || { printf '       %sinstalling dependencies...%s\n' "$D" "$N"; npm ci > /dev/null 2>&1; }
  check "npm test passes" npm test --silent
  check "npm audit clean on the app itself (high+)" npm audit --audit-level=high
else
  skip "npm test passes" "npm not installed"
  skip "npm audit clean on the app itself (high+)" "npm not installed"
fi

if [[ $FAST -eq 1 ]]; then
  skip "Docker image builds" "--fast"
  skip "Container runs as non-root" "--fast"
  skip "Container serves /health" "--fast"
elif ! command -v docker > /dev/null 2>&1 || ! docker info > /dev/null 2>&1; then
  skip "Docker image builds" "docker unavailable"
  skip "Container runs as non-root" "docker unavailable"
  skip "Container serves /health" "docker unavailable"
else
  if out=$(docker build -t "$IMAGE" . 2>&1); then
    ok "Docker image builds"

    # Read the running user rather than the Dockerfile text: a later stage,
    # an ENTRYPOINT or a base-image change can all make USER a lie.
    uid=$(docker run --rm --entrypoint id "$IMAGE" -u 2>/dev/null)
    if [[ "$uid" == "0" ]]; then
      bad "Container runs as non-root" "running as uid 0"
    elif [[ -z "$uid" ]]; then
      bad "Container runs as non-root" "could not read uid"
    else
      ok "Container runs as non-root (uid $uid, $(docker run --rm --entrypoint id "$IMAGE" -un))"
    fi

    # A build exits 0 even when --omit=dev has pruned a runtime dependency,
    # so start the container and talk to it.
    docker rm -f verify-smoke > /dev/null 2>&1
    if docker run -d --init --name verify-smoke -p 3100:3000 "$IMAGE" > /dev/null 2>&1; then
      body=""
      for _ in $(seq 1 30); do
        body=$(curl -fsS http://localhost:3100/health 2>/dev/null) && break
        sleep 1
      done
      case "$body" in
        *'"status":"OK"'*) ok "Container serves /health" ;;
        "")               bad "Container serves /health" "no response after 30s: $(docker logs verify-smoke 2>&1 | tail -1)" ;;
        *)                bad "Container serves /health" "unexpected payload: $body" ;;
      esac
      docker rm -f verify-smoke > /dev/null 2>&1
    else
      bad "Container serves /health" "container failed to start"
    fi
  else
    bad "Docker image builds" "${out##*$'\n'}"
    skip "Container runs as non-root" "build failed"
    skip "Container serves /health" "build failed"
  fi
fi

head2 "3. Continuous Integration (GitHub Actions)"

WF=.github/workflows/ci.yml
if [[ ! -f $WF ]]; then
  bad "$WF present"
else
  ok "$WF present"
  grep -q 'push:'         "$WF" && ok "Triggers on push"          || bad "Triggers on push"
  grep -q 'pull_request:' "$WF" && ok "Triggers on pull_request"  || bad "Triggers on pull_request"
  grep -qE 'branches:\s*\[?\s*main' "$WF" && ok "Targets the main branch" || bad "Targets the main branch"
  grep -q 'actions/checkout' "$WF"   && ok "Checks out the code"     || bad "Checks out the code"
  grep -q 'actions/setup-node' "$WF" && ok "Sets up Node.js"         || bad "Sets up Node.js"
  grep -qE 'npm (ci|install)' "$WF"  && ok "Installs dependencies"   || bad "Installs dependencies"
  grep -qE 'npm test' "$WF"          && ok "Runs the test suite"     || bad "Runs the test suite"
  grep -qE 'docker/build-push-action|docker build' "$WF" \
    && ok "Builds the Docker image" || bad "Builds the Docker image"

  # actionlint parses the workflow properly; the greps above would match a
  # string inside a file YAML cannot even load. The files are passed
  # explicitly because with no arguments actionlint requires a git repository
  # and errors out on a plain directory, which reads as a workflow problem.
  if command -v actionlint > /dev/null 2>&1; then
    check "Workflow syntax (actionlint)" actionlint .github/workflows/ci.yml .github/workflows/codeql.yml
  elif command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1 && [[ $FAST -eq 0 ]]; then
    check "Workflow syntax (actionlint, via container)" \
      docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest \
      .github/workflows/ci.yml .github/workflows/codeql.yml
  else
    skip "Workflow syntax (actionlint)" "install: winget install rhysd.actionlint"
  fi
fi

head2 "4. Security scanning"

SCANNERS=()
grep -rqi 'trivy'    .github/workflows/ 2>/dev/null && SCANNERS+=("Trivy")
grep -rqi 'gitleaks\|trufflehog\|gitguardian' .github/workflows/ 2>/dev/null && SCANNERS+=("secret scanner")
grep -rqi 'codeql'   .github/workflows/ 2>/dev/null && SCANNERS+=("CodeQL")
grep -rq  'npm audit' .github/workflows/ 2>/dev/null && SCANNERS+=("npm audit")

if [[ ${#SCANNERS[@]} -gt 0 ]]; then
  ok "Security scanner integrated: ${SCANNERS[*]}"
else
  bad "Security scanner integrated" "no scanner found in .github/workflows/"
fi

# Inverted gate: finding NOTHING is the failure, because it is
# indistinguishable from a scanner that is broken or pointed at the wrong path.
if [[ ! -d security-demo ]]; then
  bad "Deliberate vulnerability planted" "security-demo/ not found"
else
  ok "Deliberate vulnerability planted (security-demo/)"

  # Count findings rather than read the exit code: `npm audit` exits non-zero
  # both on a finding and on failing to run at all (ENOLOCK, network, bad cwd),
  # so an exit-code test would report a crashed scanner as a detection.
  if command -v npm > /dev/null 2>&1; then
    audit_json=$(cd security-demo && npm audit --json 2>/dev/null)
    n=$(printf '%s' "$audit_json" | node -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
        try{const v=JSON.parse(s).metadata.vulnerabilities;
            console.log((v.high||0)+(v.critical||0));}
        catch{console.log("ERR");}
      });' 2>/dev/null)
    case "$n" in
      ERR|"") bad "npm audit flags the planted dependencies" "audit produced no parseable report — the scanner did not run" ;;
      0)      bad "npm audit flags the planted dependencies" "found 0 high/critical — the gate is broken or the fixture was fixed" ;;
      *)      ok "npm audit flags the planted dependencies ($n high/critical advisories)" ;;
    esac
  else
    skip "npm audit flags the planted dependencies" "npm not installed"
  fi

  # Counted from the JSON report for the same reason as above: a Gitleaks that
  # failed to start also exits non-zero.
  #
  # The report is written into the already-mounted repo directory; a second
  # mount for a temp dir does not survive path translation on Windows/MSYS.
  # Pinned to the version CI uses: upstream tightened the `github-pat` rule
  # after v8.21.2, so `:latest` finds one fewer credential in this fixture.
  leaks_report=".verify-gitleaks.json"
  GITLEAKS_VERSION="v8.21.2"
  rm -f "$leaks_report"
  leaks_ran=0; leaks_via=""
  if command -v gitleaks > /dev/null 2>&1; then
    gitleaks detect --no-git --source security-demo/ \
      --report-format json --report-path "$leaks_report" > /dev/null 2>&1
    leaks_ran=1
  elif command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1 && [[ $FAST -eq 0 ]]; then
    repo_win="$PWD"; command -v cygpath > /dev/null 2>&1 && repo_win="$(cygpath -w "$PWD")"
    MSYS_NO_PATHCONV=1 docker run --rm -v "${repo_win}:/repo" \
      "zricethezav/gitleaks:${GITLEAKS_VERSION}" detect --no-git --source /repo/security-demo \
      --report-format json --report-path "/repo/$leaks_report" > /dev/null 2>&1
    leaks_ran=1; leaks_via=" (via gitleaks ${GITLEAKS_VERSION} container)"
  fi

  if [[ $leaks_ran -eq 0 ]]; then
    skip "Gitleaks flags the planted credentials" "gitleaks and docker unavailable"
  elif [[ ! -s "$leaks_report" ]]; then
    bad "Gitleaks flags the planted credentials" "no report written -- the scanner did not run"
  else
    n=$(node -e 'try{const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Array.isArray(r)?r.length:"ERR")}catch{console.log("ERR")}' "$leaks_report" 2>/dev/null)
    case "$n" in
      ERR|"") bad "Gitleaks flags the planted credentials" "report was not parseable" ;;
      0)      bad "Gitleaks flags the planted credentials" "found 0 secrets -- the gate is broken" ;;
      *)      ok "Gitleaks flags the planted credentials ($n detected)$leaks_via" ;;
    esac
  fi
  rm -f "$leaks_report"

  # A planted fixture that reaches the image is a shipped vulnerability.
  grep -qE '^\s*security-demo/?\s*$' .dockerignore \
    && ok "Fixture excluded from the image (.dockerignore)" \
    || bad "Fixture excluded from the image (.dockerignore)"
fi

head2 "5. Documentation (README.md)"

if [[ ! -f README.md ]]; then
  bad "README.md present"
else
  ok "README.md present"
  readme=$(tr '[:upper:]' '[:lower:]' < README.md)
  has() { printf '%s' "$readme" | grep -q "$1"; }

  has 'docker build'                        && ok "Setup: how to build the container"    || bad "Setup: how to build the container"
  has 'docker run\|docker compose up'       && ok "Setup: how to run the container"      || bad "Setup: how to run the container"
  has 'alpine'                              && ok "Architecture: base image rationale"   || bad "Architecture: base image rationale"
  has 'scanner'                             && ok "Architecture: scanner rationale"      || bad "Architecture: scanner rationale"
  has 'vulnerability demonstration\|planted' && ok "Vulnerability demonstration"         || bad "Vulnerability demonstration"
  has 'challenge'                           && ok "Challenges faced"                     || bad "Challenges faced"

  # A missing image renders as a broken icon on GitHub, which proves nothing.
  missing=""
  while read -r img; do
    [[ -z "$img" ]] && continue
    [[ -f "$img" ]] || missing="$missing $img"
  done < <(grep -oE '^!\[[^]]*\]\(([^)]+)\)' README.md | sed -E 's/^!\[[^]]*\]\(([^)]+)\)$/\1/')
  if [[ -z "$missing" ]]; then
    n=$(grep -cE '^!\[[^]]*\]\([^)]+\)' README.md)
    ok "Embedded screenshots all present ($n)"
  else
    bad "Embedded screenshots all present" "missing:$missing"
  fi
fi

head2 "6. Bonus features (optional)"

if [[ -f docker-compose.yml ]]; then
  ok "Docker Compose file present"
  grep -qE '^\s{2}[a-z-]+:' docker-compose.yml \
    && [[ $(grep -cE 'image:|build:' docker-compose.yml) -ge 2 ]] \
    && ok "Compose defines app + datastore" || bonus "Compose defines a second service"
  grep -q 'networks:' docker-compose.yml \
    && ok "Compose uses a user-defined network" || bonus "Compose user-defined network"
  if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1 && [[ $FAST -eq 0 ]]; then
    check "Compose file is valid" docker compose config -q
  else
    skip "Compose file is valid" "docker unavailable or --fast"
  fi
else
  bonus "Docker Compose"
fi

[[ -f scripts/setup-branch-protection.sh ]] \
  && ok "Branch protection is codified" || bonus "Branch protection"

if command -v gh > /dev/null 2>&1 && gh auth status > /dev/null 2>&1; then
  if gh api "repos/{owner}/{repo}/branches/main/protection" > /dev/null 2>&1; then
    ok "Branch protection active on main"
  else
    bonus "Branch protection active on main (run scripts/setup-branch-protection.sh)"
  fi
else
  skip "Branch protection active on main" "gh not installed or not authenticated"
fi

head2 "Summary"
printf '  %s%d passed%s · %s%d failed%s · %d skipped · %d bonus missing\n\n' \
  "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$SKIP" "$BONUS_MISSING"

if [[ $FAIL -gt 0 ]]; then
  printf '%sNot ready to submit: %d required check(s) failing.%s\n' "$R" "$FAIL" "$N"
  exit 1
fi
if [[ $SKIP -gt 0 ]]; then
  printf '%sAll required checks passed, but %d were skipped -- run without --fast,%s\n' "$Y" "$SKIP" "$N"
  printf '%sand with docker/gh available, for full coverage.%s\n' "$Y" "$N"
  exit 0
fi
printf '%sAll required checks passed.%s\n' "$G" "$N"
