#!/usr/bin/env bash
# M1B.1 bootstrap preflight. Read-only by default: this script never creates,
# mutates, or deletes any GitHub or OCI resource, never installs credentials,
# and never runs terraform plan/apply/init-with-backend. It validates the
# preconditions for the first controlled OCI bootstrap and reports each check
# as PASS / FAIL / NOT_RUN / BLOCKED.
#
# usage: m1b-bootstrap-preflight.sh [--skip-github] [--skip-oci] [--json <path>]
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
skip_github=false
skip_oci=false
json_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-github) skip_github=true ;;
    --skip-oci) skip_oci=true ;;
    --json)
      [[ $# -ge 2 ]] || { echo "usage: $0 [--skip-github] [--skip-oci] [--json <path>]" >&2; exit 64; }
      json_path="$2"; shift
      ;;
    *) echo "usage: $0 [--skip-github] [--skip-oci] [--json <path>]" >&2; exit 64 ;;
  esac
  shift
done

# Expected immutable GitHub identity (numeric REST ids, not GraphQL node ids),
# verified against the live API during M1B.1 preparation.
expected_repo_id="${EXPECTED_REPO_ID:-1434990962}"
expected_owner_id="${EXPECTED_OWNER_ID:-237514587}"
expected_owner="${EXPECTED_OWNER:-eswrops}"
expected_repo="${EXPECTED_REPO:-EventForge}"
home_region="${EXPECTED_OCI_REGION:-ap-hyderabad-1}"

checks_file="$(mktemp)"
failures=0
trap 'rm -f "$checks_file"' EXIT

record() {
  local id="$1" status="$2" detail="$3"
  jq -cn --arg id "$id" --arg status "$status" --arg detail "$detail" \
    '{id:$id,status:$status,detail:$detail}' >> "$checks_file"
  printf '%-8s %s\n' "$status" "$id"
  [[ "$status" != "FAIL" ]] || failures=$((failures + 1))
}

git_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------- GitHub ----
gh_api() { gh api "$@" 2>/dev/null; }

if [[ "$skip_github" == true ]]; then
  record "gh-repo-identity" NOT_RUN "skipped by --skip-github"
  record "gh-environment-production-plan" NOT_RUN "skipped by --skip-github"
  record "gh-environment-production" NOT_RUN "skipped by --skip-github"
  record "gh-branch-protection-main" NOT_RUN "skipped by --skip-github"
  record "gh-actions-pinning" NOT_RUN "skipped by --skip-github"
  record "gh-default-token-permissions" NOT_RUN "skipped by --skip-github"
elif ! command -v gh >/dev/null; then
  record "gh-repo-identity" NOT_RUN "gh CLI is not installed"
  record "gh-environment-production-plan" NOT_RUN "gh CLI is not installed"
  record "gh-environment-production" NOT_RUN "gh CLI is not installed"
  record "gh-branch-protection-main" NOT_RUN "gh CLI is not installed"
  record "gh-actions-pinning" NOT_RUN "gh CLI is not installed"
  record "gh-default-token-permissions" NOT_RUN "gh CLI is not installed"
else
  repo_json="$(gh_api "repos/${expected_owner}/${expected_repo}")"
  if jq -e '(.id | type) == "number" and (.owner.id | type) == "number"' <<<"$repo_json" >/dev/null 2>&1; then
    repo_id="$(jq -r '.id' <<<"$repo_json")"
    owner_id="$(jq -r '.owner.id' <<<"$repo_json")"
    visibility="$(jq -r '.visibility' <<<"$repo_json")"
    default_branch="$(jq -r '.default_branch' <<<"$repo_json")"
    if [[ "$repo_id" == "$expected_repo_id" && "$owner_id" == "$expected_owner_id" && "$default_branch" == "main" ]]; then
      record "gh-repo-identity" PASS "numeric repo id ${repo_id}, owner id ${owner_id}, visibility ${visibility}, default branch ${default_branch}"
    else
      record "gh-repo-identity" FAIL "identity drift: repo id ${repo_id} (want ${expected_repo_id}), owner id ${owner_id} (want ${expected_owner_id}), default branch ${default_branch}"
    fi
  else
    record "gh-repo-identity" BLOCKED "GitHub REST API unreachable or repository not found from this session"
  fi

  check_environment() {
    local name="$1"
    local env_json policies reviewer_count branch_main
    env_json="$(gh_api "repos/${expected_owner}/${expected_repo}/environments/${name}")"
    if [[ -z "$env_json" ]] || ! jq -e '.html_url' <<<"$env_json" >/dev/null 2>&1; then
      record "gh-environment-${name}" BLOCKED "environment does not exist; create it with required reviewers and a main-only deployment branch policy before attaching credentials (docs/acceptance/m1b-bootstrap/github-security.md)"
      return
    fi
    policies="$(gh_api "repos/${expected_owner}/${expected_repo}/environments/${name}/deployment-branch-policies")"
    branch_main="$(jq -r --arg main main '[."branch_policies"[]."name"] | index($main) != null' <<<"${policies:-}" 2>/dev/null)"
    reviewer_count="$(jq -r '.protection_rules | map(select(.type == "required_reviewer")) | length' <<<"$env_json" 2>/dev/null)"
    if [[ "$branch_main" == "true" && "${reviewer_count:-0}" -ge 1 ]]; then
      record "gh-environment-${name}" PASS "required reviewers active (${reviewer_count}), deployment restricted to main"
    else
      record "gh-environment-${name}" BLOCKED "exists but incomplete protection: reviewers=${reviewer_count:-unknown}, main-only branch policy=${branch_main:-unknown}; complete steps 5-6 of docs/acceptance/m1b-bootstrap/operator-checklist.md before attaching credentials"
    fi
  }
  check_environment production-plan
  check_environment production

  protection_json="$(gh_api "repos/${expected_owner}/${expected_repo}/branches/main/protection")"
  if jq -e '.required_pull_request_reviews' <<<"${protection_json:-}" >/dev/null 2>&1; then
    record "gh-branch-protection-main" PASS "main requires pull requests and reviews"
  else
    record "gh-branch-protection-main" BLOCKED "main is unprotected; apply the branch-protection definition in docs/acceptance/m1b-bootstrap/github-security.md"
  fi

  actions_json="$(gh_api "repos/${expected_owner}/${expected_repo}/actions/permissions")"
  if [[ "$(jq -r '.sha_pinning_required' <<<"${actions_json:-}" 2>/dev/null)" == "true" ]]; then
    record "gh-actions-pinning" PASS "full-length SHA pinning is enforced repository-wide"
  else
    record "gh-actions-pinning" BLOCKED "sha_pinning_required is false; enable it (and the action allowlist) per docs/acceptance/m1b-bootstrap/github-security.md"
  fi
  if [[ "$(gh_api "repos/${expected_owner}/${expected_repo}/actions/permissions/workflow" | jq -r '.default_workflow_permissions // empty')" == "read" ]]; then
    record "gh-default-token-permissions" PASS "default GITHUB_TOKEN permissions are read-only"
  else
    record "gh-default-token-permissions" FAIL "default workflow permissions are not read"
  fi
fi

# ------------------------------------------------------------- Terraform ----
terraform_bin="$(command -v terraform || true)"
if [[ -z "$terraform_bin" ]]; then
  record "tf-version" NOT_RUN "terraform is not installed"
  record "tf-validate-roots" NOT_RUN "terraform is not installed"
else
  tf_version="$("$terraform_bin" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
  if [[ "$tf_version" == "1.12.2" ]]; then
    record "tf-version" PASS "Terraform ${tf_version} matches the CI-pinned version"
  else
    record "tf-version" BLOCKED "found ${tf_version:-unknown}; run the first bootstrap apply with the CI-pinned 1.12.2 binary"
  fi
  validate_failure=false
  for root in infra/bootstrap infra/platform infra/frontend; do
    (cd "$repo_root/$root" && "$terraform_bin" fmt -check -recursive >/dev/null 2>&1 && "$terraform_bin" validate >/dev/null 2>&1) || validate_failure=true
  done
  if [[ "$validate_failure" == false ]]; then
    record "tf-validate-roots" PASS "all three roots format and validate offline"
  else
    record "tf-validate-roots" FAIL "one or more roots failed fmt -check or validate"
  fi
fi

# Operator-local inputs (git-ignored) required before the first bootstrap apply.
if [[ -s "$repo_root/infra/bootstrap/terraform.auto.tfvars" ]]; then
  record "operator-inputs-bootstrap" PASS "infra/bootstrap/terraform.auto.tfvars exists (contents never read or printed)"
else
  record "operator-inputs-bootstrap" BLOCKED "infra/bootstrap/terraform.auto.tfvars is missing; create it from terraform.tfvars.example with the real Vault key OCID and policy statements"
fi

# ------------------------------------------------------------------- OCI ----
if [[ "$skip_oci" == true ]]; then
  record "oci-session" NOT_RUN "skipped by --skip-oci"
  record "oci-region-home" NOT_RUN "skipped by --skip-oci"
  record "oci-compartment" NOT_RUN "skipped by --skip-oci"
  record "oci-inventory-match" NOT_RUN "skipped by --skip-oci"
  record "oci-vault-key" NOT_RUN "skipped by --skip-oci"
elif ! command -v oci >/dev/null; then
  record "oci-session" NOT_RUN "oci CLI is not installed"
  record "oci-region-home" NOT_RUN "oci CLI is not installed"
  record "oci-compartment" NOT_RUN "oci CLI is not installed"
  record "oci-inventory-match" NOT_RUN "oci CLI is not installed"
  record "oci-vault-key" NOT_RUN "oci CLI is not installed"
else
  namespace="$(oci os ns get 2>/dev/null | jq -r '.data // empty')"
  if [[ -n "$namespace" ]]; then
    record "oci-session" PASS "operator session active (namespace redacted)"
  else
    record "oci-session" BLOCKED "no usable OCI operator session; run from the approved operator workstation"
  fi
  region_sub="$(oci iam region-subscription list 2>/dev/null | jq -r '[.data[]."region-name"] | join(",")')"
  tenancy_ocid="$(grep -m1 '^tenancy' "${OCI_CLI_CONFIG:-$HOME/.oci/config}" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
  if [[ "$region_sub" == *"$home_region"* ]]; then
    record "oci-region-home" PASS "home region ${home_region} (Always Free resources must be created here)"
  else
    record "oci-region-home" FAIL "home region '${region_sub}' does not contain expected ${home_region}"
  fi
  compartment_json="$(oci iam compartment list --all 2>/dev/null | jq -r '[.data[] | select(.name == "Test" and ."lifecycle-state" == "ACTIVE")][0].id // empty')"
  if [[ -n "$compartment_json" ]]; then
    record "oci-compartment" PASS "EventForge compartment found (OCID withheld from this output)"
    compartment_id="$compartment_json"
  else
    record "oci-compartment" BLOCKED "no active 'Test' compartment found; confirm the target compartment with the operator"
    compartment_id=""
  fi
  if [[ -n "$compartment_id" ]]; then
    instances="$(oci compute instance list --compartment-id "$compartment_id" 2>/dev/null \
      | jq -r '[.data[] | select(."lifecycle-state" == "RUNNING" and .shape == "VM.Standard.E2.1.Micro")] | length')"
    # An empty Object Storage bucket list is printed as zero bytes by the CLI.
    bucket_output="$(oci os bucket list --compartment-id "$compartment_id" 2>/dev/null)"
    if [[ -z "$bucket_output" ]]; then
      buckets=0
    else
      buckets="$(jq -r '[.data[]?] | length' <<<"$bucket_output")"
    fi
    if [[ "$instances" == "2" && "$buckets" == "0" ]]; then
      record "oci-inventory-match" PASS "two running VM.Standard.E2.1.Micro instances and no Object Storage buckets (pristine pre-bootstrap state)"
    else
      record "oci-inventory-match" FAIL "inventory drift: running E2.1.Micro instances=${instances:-unknown}, buckets=${buckets:-unknown}"
    fi
  else
    record "oci-inventory-match" NOT_RUN "compartment unknown"
  fi
  # The state-bucket CMK may live in the EventForge compartment or the tenancy
  # root; both are searched (read-only). The CLI emits pagination warnings on
  # stderr, so stdout alone is parsed.
  vault_json="$(oci kms management vault list --compartment-id "${compartment_id:-ocid1.compartment.oc1..none}" 2>/dev/null | jq -r '[.data[]? | select(."lifecycle-state" == "ACTIVE")] | length')"
  vault_root_json="$(oci kms management vault list --compartment-id "${tenancy_ocid:-ocid1.tenancy.oc1..none}" 2>/dev/null | jq -r '[.data[]? | select(."lifecycle-state" == "ACTIVE")] | length')"
  if { [[ -n "$vault_json" ]] && [[ "$vault_json" -ge 1 ]]; } || { [[ -n "$vault_root_json" ]] && [[ "$vault_root_json" -ge 1 ]]; }; then
    record "oci-vault-key" PASS "an active Vault exists (EventForge compartment: ${vault_json:-0}, tenancy root: ${vault_root_json:-0}); confirm the CMK OCID in terraform.auto.tfvars is in ${home_region} and that its key versions are enabled"
  else
    record "oci-vault-key" BLOCKED "no active Vault found; create the Vault and master key in ${home_region} before the bootstrap apply (state_bucket_kms_key_id is a required input)"
  fi
fi

# ----------------------------------------------------------------- Static ----
allowed_types="oci_identity_dynamic_group
oci_identity_policy
oci_objectstorage_bucket
oci_objectstorage_object_lifecycle_policy
oci_ons_notification_topic
oci_ons_subscription"
declared_types="$(grep -hE '^resource ' "$repo_root"/infra/bootstrap/*.tf 2>/dev/null | awk '{gsub(/"/, "", $2); print $2}' | sort -u)"
scope_violations="$(comm -23 <(printf '%s\n' "$declared_types") <(printf '%s\n' "$allowed_types"))"
if [[ -z "$scope_violations" ]]; then
  record "bootstrap-scope-allowlist" PASS "bootstrap declares only buckets, lifecycle policy, IAM identities, and notification resources"
else
  record "bootstrap-scope-allowlist" FAIL "bootstrap declares unexpected resource types: ${scope_violations//$'\n'/, }"
fi

if grep -qE 'default[[:space:]]*=[[:space:]]*false' "$repo_root"/infra/platform/variables.tf && \
   grep -qE 'count[[:space:]]*=[[:space:]]*var\.enable_api_ingress \? 1 : 0' \
     "$repo_root"/infra/platform/load_balancer.tf "$repo_root"/infra/platform/cloudflare.tf; then
  record "ingress-disabled" PASS "API ingress remains false-by-default and gated"
else
  record "ingress-disabled" FAIL "public API ingress is not demonstrably false-by-default"
fi

unmanaged_shared_network="$(grep -hE '^resource "(oci_core_vcn|oci_core_subnet|oci_core_security_list|oci_core_route_table)"' \
  "$repo_root"/infra/platform/*.tf 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')"
if [[ -z "${unmanaged_shared_network// }" ]]; then
  record "shared-network-unmanaged" PASS "platform declares no managed VCN, subnet, security-list, or route-table resources (shared components stay read-only until the reviewed import flow)"
else
  record "shared-network-unmanaged" FAIL "platform manages shared network resources outside the import flow: ${unmanaged_shared_network}"
fi

if grep -q 'prevent_destroy' "$repo_root"/infra/platform/imported_resources.tf.example && \
   jq -e '.protected_imports | length > 0' "$repo_root"/scripts/ci/platform-safe-plan-policy.json >/dev/null 2>&1; then
  record "imported-protection" PASS "import template carries prevent_destroy and the safe-plan policy protects all mapped imports"
else
  record "imported-protection" FAIL "import protections are missing from the template or policy"
fi

if git -C "$repo_root" ls-files | grep -qE '\.(pem|key|p12|tfstate|tfplan)$|(^|/)(backend\.hcl|[^/]*\.auto\.tfvars)$'; then
  record "no-tracked-secrets" FAIL "tracked credential, state, or operator-input file detected"
else
  record "no-tracked-secrets" PASS "no tracked credential, state, plan, or operator-input files"
fi

# ----------------------------------------------------------------- Report ----
report="$(jq -s --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg commit "$git_commit" \
  '{schema_version:1,tool:"m1b-bootstrap-preflight",generated_at:$generated_at,git_commit:$commit,read_only:true,checks:.,summary:{pass:([.[]|select(.status=="PASS")]|length),fail:([.[]|select(.status=="FAIL")]|length),not_run:([.[]|select(.status=="NOT_RUN")]|length),blocked:([.[]|select(.status=="BLOCKED")]|length)}}' \
  "$checks_file")"

if [[ -n "$json_path" ]]; then
  printf '%s\n' "$report" > "$json_path"
  echo "Machine-readable report: $json_path"
else
  printf '%s\n' "$report" | jq -r '.checks[] | "\(.status)\t\(.id)\t\(.detail)"'
fi

printf 'Preflight summary: PASS=%s FAIL=%s NOT_RUN=%s BLOCKED=%s\n' \
  "$(jq -r '.summary.pass' <<<"$report")" "$(jq -r '.summary.fail' <<<"$report")" \
  "$(jq -r '.summary.not_run' <<<"$report")" "$(jq -r '.summary.blocked' <<<"$report")"
printf 'This preflight is read-only. Mutating steps require explicit operator approval: docs/acceptance/m1b-bootstrap/operator-checklist.md\n'

(( failures == 0 ))
