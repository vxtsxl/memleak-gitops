#!/usr/bin/env bash
# Creates a repository ruleset that protects main:
#   - changes only via Pull Request (0 approvals so a solo dev can merge; raise if you have a team)
#   - required status check: "PR Gate" (aggregates lint, SAST, secrets, tests, build+Trivy scan)
#   - no force pushes / no deletion
#   - GitHub Actions (the release workflow's github-actions[bot]) may bypass, so it can
#     commit the updated image tags back to main
#
# Usage: ./scripts/protect-main.sh <owner>/<repo>      (needs `gh auth login` with admin rights)
set -euo pipefail
REPO="${1:?usage: $0 <owner>/<repo>}"

gh api -X POST "repos/${REPO}/rulesets" --input - <<'JSON'
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 15368, "actor_type": "Integration", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true
      } },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "PR Gate" } ]
      } }
  ]
}
JSON
echo "Ruleset 'protect-main' created for ${REPO}"
