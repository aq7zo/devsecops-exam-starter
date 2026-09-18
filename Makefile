IMAGE ?= macky-merch-api:local

.PHONY: build run whoami up down test verify verify-fast demo demo-audit demo-trivy demo-gitleaks

build:
	docker build -t $(IMAGE) .

# --init gives the container a real PID 1, so Ctrl-C and `docker stop` return
# immediately instead of waiting out the 10-second kill timeout.
run: build
	docker run --rm --init -p 3000:3000 $(IMAGE)

# Prints `node`, never `root`.
whoami: build
	docker run --rm --entrypoint id $(IMAGE) -un

up:
	docker compose up --build

down:
	docker compose down -v

test:
	npm ci
	npm test

verify:
	npm run verify

verify-fast:
	npm run verify:fast

# Vulnerability demonstration: scan the planted fixture in security-demo/.
# Each scanner exits non-zero when it finds something -- that is the expected
# result here, so the leading `-` keeps make going instead of stopping.
# Scanner versions match the ones CI pins.
demo: demo-audit demo-trivy demo-gitleaks

demo-audit:
	-cd security-demo && npm audit --audit-level=high

demo-trivy:
	-docker run --rm -v "$(CURDIR):/work" -w /work aquasec/trivy:0.65.0 \
		fs --scanners vuln --severity HIGH,CRITICAL security-demo

demo-gitleaks:
	-docker run --rm -v "$(CURDIR)/security-demo:/scan" zricethezav/gitleaks:v8.21.2 \
		detect --source /scan --no-git --redact --verbose
