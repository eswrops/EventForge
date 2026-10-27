#!/usr/bin/env bash
# Fixture GitHub REST API for the preflight environment checks. The scenario
# (PREFLIGHT_SCENARIO) controls the production-plan environment response so
# the three verification cases can be exercised offline:
#   ok             — correct reviewer, prevent_self_review false  -> PASS
#   wrong-reviewer — reviewer id 999                              -> BLOCKED
#   self-review    — prevent_self_review true                     -> BLOCKED
set -euo pipefail
path="${1:-}"

env_json() {
  local reviewer_id="$1" prevent_self="$2"
  jq -nc --argjson rid "$reviewer_id" --argjson psr "$prevent_self" '{
    html_url: "https://github.com/eswrops/EventForge/deployments/production-plan",
    prevent_self_review: $psr,
    protection_rules: [
      {id: 1, node_id: "PR_1", type: "required_reviewers", prevent_self_review: $psr,
       reviewers: [{type: "User", reviewer: {type: "User", id: $rid, login: "eswrops"}}]}
    ],
    deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}
  }'
}

case "$path" in
  "repos/eswrops/EventForge")
    printf '{"id":1434990962,"owner":{"id":237514587,"login":"eswrops"},"visibility":"public","default_branch":"main"}'
    ;;
  "repos/eswrops/EventForge/environments/production-plan" | "repos/eswrops/EventForge/environments/production")
    case "${PREFLIGHT_SCENARIO:-ok}" in
      ok)             env_json 237514587 false ;;
      wrong-reviewer) env_json 999 false ;;
      self-review)    env_json 237514587 true ;;
      *) echo "unknown scenario" >&2; exit 2 ;;
    esac
    ;;
  "repos/eswrops/EventForge/environments/production-plan/deployment-branch-policies" | "repos/eswrops/EventForge/environments/production/deployment-branch-policies")
    printf '{"total_count":1,"branch_policies":[{"id":11,"name":"main"}]}'
    ;;
  "repos/eswrops/EventForge/branches/main/protection")
    cat <<'JSON'
{
  "required_status_checks": {"strict": true, "contexts": [
    "Format and validate (infra/bootstrap)",
    "Format and validate (infra/platform)",
    "Format and validate (infra/frontend)",
    "CI script and workflow checks"
  ]},
  "enforce_admins": {"enabled": true},
  "required_pull_request_reviews": {"required_approving_review_count": 0, "dismiss_stale_reviews": true},
  "restrictions": null,
  "allow_force_pushes": {"enabled": false},
  "allow_deletions": {"enabled": false},
  "required_linear_history": {"enabled": true}
}
JSON
    ;;
  "repos/eswrops/EventForge/actions/permissions")
    printf '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}'
    ;;
  "repos/eswrops/EventForge/actions/permissions/workflow")
    printf '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
    ;;
  *)
    echo "stub: unhandled path: $path" >&2
    exit 2
    ;;
esac
