#!/usr/bin/env bash
#
# Bonus: branch protection -- block merging a PR whose CI is red.
#
# Branch protection is repository *state*, not repository *code*, so it cannot
# live in a committed file the way the pipeline does. Configuring it by hand
# through the GitHub UI leaves no record of what was configured or why. This
# script is that record: run it once, and the settings are reproducible and
# reviewable in git like everything else.
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

# The single required check. `ci-passed` is an aggregate job that depends on
# every other job in ci.yml, so protecting this one name transitively requires
# all of them. Listing jobs individually here would mean that renaming a job,
# or adding a new one, silently drops it from the gate -- the classic way a
# protected branch quietly stops protecting anything.
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
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_last_push_approval": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true,
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
  dismiss_stale_reviews             New commits invalidate prior approvals, so
                                    an approval always refers to the code that
                                    actually merges.
  require_last_push_approval        The person who pushed last cannot be the
                                    only approver.
  required_linear_history           Squash/rebase only. Keeps `main` bisectable.
  allow_force_pushes: false         History on main cannot be rewritten --
                                    which is also what stops someone quietly
                                    erasing a committed secret from the log
                                    instead of rotating it.
  required_conversation_resolution  Review threads must be resolved, not just
                                    outvoted by an approval.

Verify:
  gh api repos/OWNER/REPO/branches/main/protection | jq '.required_status_checks'

Note: the check name only becomes selectable in the GitHub UI after CI has run
at least once on the branch. Run the workflow, then apply this script.
EOF
