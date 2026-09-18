#!/usr/bin/env bash
#
# Branch protection: block merging a PR whose CI is red.
#
# Protection is repository state rather than code, so it cannot live in a
# committed file the way the pipeline does. This script is the record of what
# was configured and why, reviewable in git like everything else.
#
# Requires the GitHub CLI, authenticated with admin rights on the repo:
#   gh auth login
#
# Usage:
#   ./scripts/setup-branch-protection.sh [owner/repo] [branch]
# Defaults to the repo the current directory points at, branch `main`.

set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
BRANCH="${2:-main}"

# `ci-passed` aggregates every other job in ci.yml, so requiring this one name
# transitively requires all of them. Listing jobs individually would drop a job
# from the gate every time one is renamed or added.
REQUIRED_CHECK="CI passed"

echo "Protecting ${BRANCH} on ${REPO}..."

gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<JSON
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      { "context": "${REQUIRED_CHECK}" }
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false,
  "block_creations": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON

cat <<'EOF'

Applied:
  required_status_checks.strict     PR must be up to date with main before
                                    merging. Without this, two PRs that are
                                    each green in isolation can merge into a
                                    broken main -- the "semantic merge
                                    conflict" that branch protection is
                                    usually assumed to prevent but does not,
                                    unless strict is on.
  enforce_admins                    The rule applies to admins too. A rule the
                                    author can bypass is a convention, not a
                                    control.
  allow_force_pushes: false         History on main cannot be rewritten --
                                    which is also what stops someone quietly
                                    erasing a committed secret from the log
                                    instead of rotating it.
  allow_deletions: false            main cannot be deleted.

Not applied:
  required_pull_request_reviews     With enforce_admins on, a required approval
                                    blocks every PR on a single-maintainer
                                    repo. Add it once there is a second
                                    reviewer.

Verify:
  gh api repos/OWNER/REPO/branches/main/protection | jq '.required_status_checks'

Note: the check name only becomes selectable in the GitHub UI after CI has run
at least once on the branch. Run the workflow, then apply this script.
EOF
