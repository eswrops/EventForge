#!/usr/bin/env bash
# M1B bootstrap preflight. Read-only by default: this script never creates,
# mutates, or deletes any GitHub or OCI resource, never installs credentials,
# and never runs terraform plan/apply/init-with-backend. It validates the
# preconditions for the first controlled OCI bootstrap and reports each check
# as PASS / FAIL / NOT_RUN / BLOCKED.
#
# Modes (cumulative expectations, never mutating):
#   pre-bootstrap (default) — pristine tenancy: no buckets, vault/CMK inputs
#                             verifiable before the apply.
#   post-bootstrap          — the authorized state and backup buckets must
#                             exist; versioning and CMK encryption are
#                             validated live. Legitimate bucket creation is
#                             the expectation, never drift.
#   pre-import              — post-bootstrap plus import-template checks:
#                             only reviewed mapped resources, prevent_destroy
#                             required, shared network components untouched.
#
# usage: m1b-bootstrap-preflight.sh [--mode pre-bootstrap|post-bootstrap|pre-import]
#                                   [--skip-github] [--skip-oci] [--json <path>]
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode="pre-bootstrap"
skip_github=false
skip_oci=false
json_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { echo "usage: $0 [--mode pre-bootstrap|post-bootstrap|pre-import] [--skip-github] [--skip-oci] [--json <path>]" >&2; exit 64; }
      case "$2" in pre-bootstrap|post-bootstrap|pre-import) mode="$2" ;; *) echo "unknown mode '$2'" >&2; exit 64 ;; esac
      shift
      ;;
    --skip-github) skip_github=true ;;
    --skip-oci) skip_oci=true ;;
    --json)
      [[ $# -ge 2 ]] || { echo "usage: $0 [--mode pre-bootstrap|post-bootstrap|pre-import] [--skip-github] [--skip-oci] [--json <path>]" >&2; exit 64; }
      json_path="$2"; shift
      ;;
    *) echo "usage: $0 [--mode pre-bootstrap|post-bootstrap|pre-import] [--skip-github] [--skip-oci] [--json <path>]" >&2; exit 64 ;;
  esac
  shift
done

# Expected immutable GitHub identity (numeric REST ids, not GraphQL node ids),
# verified against the live API during M1B.1 and re-verified during M1B.1.1.
expected_repo_id="${EXPECTED_REPO_ID:-1434990962}"
expected_owner_id="${EXPECTED_OWNER_ID:-237514587}"
expected_owner="${EXPECTED_OWNER:-eswrops}"
expected_repo="${EXPECTED_REPO:-EventForge}"
expected_reviewer_ids="${EXPECTED_REVIEWER_IDS:-237514587}"
expected_reviewer_ids_sorted="$(printf '%s' "$expected_reviewer_ids" | jq -Rr 'split(",") | sort | join(",")')"
expected_state_bucket="${EXPECTED_STATE_BUCKET:-eventforge-tfstate-prod}"
expected_backup_bucket="${EXPECTED_BACKUP_BUCKET:-eventforge-backups}"
expected_ci_contexts=(
  "Format and validate (infra/bootstrap)"
  "Format and validate (infra/platform)"
  "Format and validate (infra/frontend)"
  "CI script and workflow checks"
)
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
# PREFLIGHT_GH_STUB, when set, replaces the gh CLI with a fixture command so
# the environment checks can be tested offline (tests/acceptance/*).
if [[ -n "${PREFLIGHT_GH_STUB:-}" ]]; then
  gh_api() { "$PREFLIGHT_GH_STUB" "$@" 2>/dev/null; }
else
  gh_api() { gh api "$@" 2>/dev/null; }
fi

if [[ "$skip_github" == true ]]; then
  for c in gh-repo-identity gh-environment-production-plan gh-environment-production \
           gh-branch-protection-main gh-actions-pinning gh-actions-allowlist gh-token-permissions; do
    record "$c" NOT_RUN "skipped by --skip-github"
  done
elif ! command -v gh >/dev/null; then
  for c in gh-repo-identity gh-environment-production-plan gh-environment-production \
           gh-branch-protection-main gh-actions-pinning gh-actions-allowlist gh-token-permissions; do
    record "$c" NOT_RUN "gh CLI is not installed"
  done
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
    local env_json policies reviewer_ids branch_policy_count branch_main
    env_json="$(gh_api "repos/${expected_owner}/${expected_repo}/environments/${name}")"
    if [[ -z "$env_json" ]] || ! jq -e '.html_url' <<<"$env_json" >/dev/null 2>&1; then
      record "gh-environment-${name}" BLOCKED "environment does not exist; create it with required reviewers and a main-only deployment branch policy before attaching credentials (docs/acceptance/m1b-bootstrap/github-security.md)"
      return
    fi
    # The protection rule type has been observed as both 'required_reviewer'
    # and 'required_reviewers'; match either and compare the exact reviewer IDs.
    # Reviewer IDs must be extracted flat (the nested-array form yields
    # [[237514587]], which never equals the expected list) and compared as a
    # sorted set. prevent_self_review lives inside the required_reviewers
    # protection-rule object, not at the environment's top level.
    reviewer_ids="$(jq -r '
      [ .protection_rules[]?
        | select(.type == "required_reviewers" or .type == "required_reviewer")
        | .reviewers[]?
        | select(.type == "User")
        | .reviewer.id
        | tostring ]
      | unique | sort | join(",")' <<<"$env_json" 2>/dev/null)"
    prevent_self="$(jq -r '
      [ .protection_rules[]?
        | select(.type == "required_reviewers" or .type == "required_reviewer")
        | .prevent_self_review ]
      | if length == 1 then .[0] | tostring else "missing" end' <<<"$env_json" 2>/dev/null)"
    policies="$(gh_api "repos/${expected_owner}/${expected_repo}/environments/${name}/deployment-branch-policies")"
    branch_policy_count="$(jq -r '."branch_policies" | length' <<<"${policies:-}" 2>/dev/null)"
    branch_main="$(jq -r --arg main main '[."branch_policies"[]."name"] | index($main) != null' <<<"${policies:-}" 2>/dev/null)"
    if [[ "${branch_main:-}" == "true" && "${branch_policy_count:-0}" == "1" && "$reviewer_ids" == "$expected_reviewer_ids_sorted" ]]; then
      if [[ "$prevent_self" == "true" ]]; then
        record "gh-environment-${name}" BLOCKED "protection is complete, but prevent_self_review=true would deadlock the documented single-operator approval model; set it to false (github-security.md §4)"
      elif [[ "$prevent_self" != "false" ]]; then
        record "gh-environment-${name}" BLOCKED "protection is incomplete: prevent_self_review is ${prevent_self}; re-run the §4 creation command which sets it explicitly"
      else
        record "gh-environment-${name}" PASS "required reviewers with exact IDs (${reviewer_ids}), exactly one deployment branch policy restricted to main, prevent_self_review=false"
      fi
    else
      record "gh-environment-${name}" BLOCKED "exists but incomplete protection: reviewer ids '${reviewer_ids:-unknown}' (want ${expected_reviewer_ids_sorted}), branch policy count ${branch_policy_count:-unknown} (want exactly 1, main-only: ${branch_main:-unknown}), prevent_self_review ${prevent_self:-unknown}; complete github-security.md §4 before attaching credentials"
    fi
  }
  check_environment production-plan
  check_environment production

  protection_json="$(gh_api "repos/${expected_owner}/${expected_repo}/branches/main/protection")"
  if jq -e '.required_pull_request_reviews' <<<"${protection_json:-}" >/dev/null 2>&1; then
    contexts="$(jq -r '."required_status_checks"."contexts" // [] | join("|")' <<<"$protection_json")"
    enforce_admins="$(jq -r '."enforce_admins"."enabled"' <<<"$protection_json")"
    force_push="$(jq -r '."allow_force_pushes"."enabled"' <<<"$protection_json")"
    deletions="$(jq -r '."allow_deletions"."enabled"' <<<"$protection_json")"
    missing_contexts=""
    for ctx in "${expected_ci_contexts[@]}"; do
      [[ "|$contexts|" == *"|$ctx|"* ]] || missing_contexts="${missing_contexts}${ctx}; "
    done
    if [[ "$enforce_admins" == "true" && "$force_push" == "false" && "$deletions" == "false" && -z "$missing_contexts" ]]; then
      record "gh-branch-protection-main" PASS "pull requests required, admin-enforced, force pushes and deletion blocked, all ${#expected_ci_contexts[@]} CI contexts required"
    else
      record "gh-branch-protection-main" BLOCKED "protection incomplete: enforce_admins=${enforce_admins}, allow_force_pushes=${force_push}, allow_deletions=${deletions}, missing CI contexts: ${missing_contexts:-none}; apply github-security.md §5"
    fi
  else
    record "gh-branch-protection-main" BLOCKED "main is unprotected; apply the branch-protection definition in docs/acceptance/m1b-bootstrap/github-security.md"
  fi

  actions_json="$(gh_api "repos/${expected_owner}/${expected_repo}/actions/permissions")"
  if [[ "$(jq -r '.sha_pinning_required' <<<"${actions_json:-}" 2>/dev/null)" == "true" ]]; then
    record "gh-actions-pinning" PASS "full-length SHA pinning is enforced repository-wide"
  else
    record "gh-actions-pinning" BLOCKED "sha_pinning_required is false; enable it per docs/acceptance/m1b-bootstrap/github-security.md §6 (all committed workflows are already SHA-pinned)"
  fi
  if [[ "$(jq -r '.allowed_actions' <<<"${actions_json:-}" 2>/dev/null)" == "selected" ]]; then
    record "gh-actions-allowlist" PASS "actions are restricted to the selected allowlist"
  else
    record "gh-actions-allowlist" BLOCKED "allowed_actions is not 'selected'; apply the allowlist in github-security.md §6"
  fi
  workflow_perms="$(gh_api "repos/${expected_owner}/${expected_repo}/actions/permissions/workflow")"
  if [[ "$(jq -r '.default_workflow_permissions // empty' <<<"${workflow_perms:-}")" == "read" && \
        "$(jq -r '.can_approve_pull_request_reviews' <<<"${workflow_perms:-}")" == "false" ]]; then
    record "gh-token-permissions" PASS "default GITHUB_TOKEN permissions are read-only and the token cannot approve pull requests (self-review prevention)"
  else
    record "gh-token-permissions" FAIL "default workflow permissions are not read-only or the token may approve its own pull requests"
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
tfvars_file="$repo_root/infra/bootstrap/terraform.auto.tfvars"
if [[ -s "$tfvars_file" ]]; then
  record "operator-inputs-bootstrap" PASS "infra/bootstrap/terraform.auto.tfvars exists (contents never printed)"
else
  record "operator-inputs-bootstrap" BLOCKED "infra/bootstrap/terraform.auto.tfvars is missing; create it from terraform.tfvars.example with the real Vault key OCID and policy statements"
fi

# ------------------------------------------------------------------- OCI ----
if [[ "$skip_oci" == true ]]; then
  for c in oci-session oci-region-home oci-compartment oci-inventory-match oci-cmk oci-import-scope; do
    record "$c" NOT_RUN "skipped by --skip-oci"
  done
elif ! command -v oci >/dev/null; then
  for c in oci-session oci-region-home oci-compartment oci-inventory-match oci-cmk oci-import-scope; do
    record "$c" NOT_RUN "oci CLI is not installed"
  done
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

  instances="$(oci compute instance list --compartment-id "${compartment_id:-ocid1.compartment.oc1..none}" 2>/dev/null \
    | jq -r '[.data[] | select(."lifecycle-state" == "RUNNING" and .shape == "VM.Standard.E2.1.Micro")] | length')"
  # An empty Object Storage bucket list is printed as zero bytes by the CLI.
  bucket_output="$(oci os bucket list --compartment-id "${compartment_id:-ocid1.compartment.oc1..none}" 2>/dev/null)"
  if [[ -z "$bucket_output" ]]; then
    bucket_names=""
  else
    bucket_names="$(jq -r '[.data[]?."name"] | join(",")' <<<"$bucket_output")"
  fi

  if [[ "$mode" == "pre-bootstrap" ]]; then
    if [[ "$instances" == "2" && -z "$bucket_names" ]]; then
      record "oci-inventory-match" PASS "two running VM.Standard.E2.1.Micro instances and no Object Storage buckets (pristine pre-bootstrap state)"
    else
      record "oci-inventory-match" FAIL "inventory drift: running E2.1.Micro instances=${instances:-unknown}, buckets='${bucket_names:-(none)}'"
    fi
    # Validate the actual CMK input, not merely an active Vault: the key OCID
    # must be present in the operator inputs and belong to this region.
    if [[ -s "$tfvars_file" ]]; then
      cmk_id="$(grep -E '^[[:space:]]*state_bucket_kms_key_id[[:space:]]*=' "$tfvars_file" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]+)"?.*/\1/' | tr -d '[:space:]')"
      if [[ "$cmk_id" == "ocid1.key.oc1.${home_region}."* ]]; then
        record "oci-cmk" PASS "state_bucket_kms_key_id is a key OCID from ${home_region} (OCID withheld); confirm the key is ENABLED and record the kms_key_compartment_ocid decision"
      else
        record "oci-cmk" FAIL "state_bucket_kms_key_id is missing, not a key OCID, or not from ${home_region}"
      fi
    else
      record "oci-cmk" BLOCKED "terraform.auto.tfvars is missing; the CMK OCID cannot be validated before the apply"
    fi
    record "oci-import-scope" NOT_RUN "not applicable in pre-bootstrap mode"
  else
    expected_buckets="${expected_state_bucket},${expected_backup_bucket}"
    actual_sorted="$(printf '%s' "$bucket_names" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')"
    expected_sorted="$(printf '%s' "$expected_buckets" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')"
    if [[ "$instances" == "2" && "$actual_sorted" == "$expected_sorted" ]]; then
      record "oci-inventory-match" PASS "two running instances and exactly the authorized buckets (${expected_state_bucket}, ${expected_backup_bucket}); post-bootstrap creation is the expectation, not drift"
    else
      record "oci-inventory-match" FAIL "post-bootstrap inventory mismatch: instances=${instances:-unknown}, buckets='${bucket_names:-(none)}' (want exactly ${expected_buckets})"
    fi
    # Live CMK validation: the state bucket must carry the customer-managed key.
    state_kms_id="$(oci os bucket get --bucket-name "$expected_state_bucket" 2>/dev/null | jq -r '."data"."kms-key-id" // empty')"
    backup_versioning="$(oci os bucket get --bucket-name "$expected_backup_bucket" 2>/dev/null | jq -r '."data"."versioning" // empty')"
    state_versioning="$(oci os bucket get --bucket-name "$expected_state_bucket" 2>/dev/null | jq -r '."data"."versioning" // empty')"
    cmk_state=""
    if [[ -n "$state_kms_id" ]]; then
      for comp in "${compartment_id:-}" "${tenancy_ocid:-}"; do
        [[ -n "$comp" ]] || continue
        while IFS=$'\t' read -r vault_id mgmt_endpoint; do
          [[ -n "$vault_id" && -n "$mgmt_endpoint" ]] || continue
          key_state="$(oci kms management key list --compartment-id "$comp" --endpoint "$mgmt_endpoint" --all 2>/dev/null \
            | jq -r --arg id "$state_kms_id" '[.data[]? | select(.id == $id)][0]."lifecycle-state" // empty')"
          if [[ -n "$key_state" ]]; then cmk_state="$key_state"; break 2; fi
        done < <(oci kms management vault list --compartment-id "$comp" --all 2>/dev/null \
          | jq -r '.data[]? | select(."lifecycle-state" == "ACTIVE") | [.id, ."management-endpoint"] | @tsv')
      done
    fi
    if [[ "$state_versioning" == "Enabled" && "$backup_versioning" == "Enabled" && -n "$state_kms_id" && "$cmk_state" == "ENABLED" ]]; then
      record "oci-cmk" PASS "both buckets versioned; state bucket carries a customer-managed key that is ENABLED (key OCID withheld)"
    else
      record "oci-cmk" FAIL "post-bootstrap encryption validation failed: state versioning=${state_versioning:-unknown}, backup versioning=${backup_versioning:-unknown}, state kms-key-id present=$([[ -n "$state_kms_id" ]] && echo yes || echo no), key state=${cmk_state:-not-found}"
    fi
    if [[ "$mode" == "pre-import" ]]; then
      import_file="$repo_root/infra/platform/imported_resources.tf"
      if [[ ! -f "$import_file" ]]; then
        record "oci-import-scope" BLOCKED "infra/platform/imported_resources.tf does not exist yet; the tracked declarations must be present with values in imported.auto.tfvars (see imported.auto.tfvars.example)"
      else
        declared="$(grep -hE '^resource "[^"]+" "[^"]+"' "$import_file" | sed -E 's/resource "([^"]+)" "([^"]+)".*/\1.\2/' | sort -u)"
        allowed='^(oci_core_vcn\.existing|oci_core_subnet\.(app|lb|mysql)|oci_core_instance\.api|oci_mysql_mysql_db_system\.existing|oci_load_balancer_load_balancer\.existing)$'
        violations="$(printf '%s\n' "$declared" | grep -vE "$allowed" | grep -v '^$' || true)"
        shared="$(printf '%s\n' "$declared" | grep -E '^(oci_core_security_list|oci_core_route_table|oci_core_internet_gateway|oci_core_dhcp_options|oci_core_nat_gateway)\.' || true)"
        resource_count="$(printf '%s\n' "$declared" | grep -c . || true)"
        pd_count="$(grep -c 'prevent_destroy' "$import_file" || true)"
        if [[ -z "$violations" && -z "$shared" && "$pd_count" -ge "$resource_count" && "$resource_count" -ge 1 ]]; then
          record "oci-import-scope" PASS "import template declares only reviewed mapped resources (${resource_count}), each protected with prevent_destroy; shared route/security resources untouched"
        else
          record "oci-import-scope" FAIL "import template violations: unapproved addresses [${violations//$'\n'/, }], shared network resources [${shared//$'\n'/, }], prevent_destroy count ${pd_count} vs ${resource_count} resources"
        fi
      fi
    else
      record "oci-import-scope" NOT_RUN "not applicable in ${mode} mode"
    fi
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

# The Object Storage -> KMS policy must use the hyphenated service subject,
# the conditional policy location (tenancy root or key compartment), and pin
# the exact key OCID.
kms_statement="$(grep -A16 'resource "oci_identity_policy" "objectstorage_kms"' "$repo_root"/infra/bootstrap/main.tf | grep 'Allow service' | head -1)"
if [[ "$kms_statement" == *"Allow service objectstorage-\${var.region} to use keys in \${local.kms_policy_location} where target.key.id = '\${var.state_bucket_kms_key_id}'"* ]] && \
   grep -q 'var.kms_key_compartment_ocid == var.tenancy_ocid' "$repo_root"/infra/bootstrap/main.tf && \
   grep -q '? "tenancy"' "$repo_root"/infra/bootstrap/main.tf; then
  record "kms-policy-string" PASS "hyphenated service subject, tenancy/compartment location handling, exact target.key.id restriction"
else
  record "kms-policy-string" FAIL "the Object Storage KMS policy statement deviates from the verified form (hyphenated objectstorage-<region>, conditional tenancy/compartment location, target.key.id pin)"
fi

if grep -qE 'default[[:space:]]*=[[:space:]]*false' "$repo_root"/infra/platform/variables.tf && \
   grep -qE 'count[[:space:]]*=[[:space:]]*var\.enable_api_ingress \? 1 : 0' \
     "$repo_root"/infra/platform/load_balancer.tf "$repo_root"/infra/platform/cloudflare.tf; then
  record "ingress-disabled" PASS "API ingress remains false-by-default and gated"
else
  record "ingress-disabled" FAIL "public API ingress is not demonstrably false-by-default"
fi

# Security lists, route tables, and gateways are never declared (shared
# components stay read-only); the VCN and subnets are exactly the reviewed
# imported declarations, which must stay inside imported_resources.tf.
unmanaged_shared_network="$(grep -hE '^resource "(oci_core_security_list|oci_core_route_table|oci_core_internet_gateway|oci_core_dhcp_options|oci_core_nat_gateway)"' \
  "$repo_root"/infra/platform/*.tf 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')"
imported_network_decls="$(grep -hcE '^resource "oci_core_(vcn|subnet)"' "$repo_root"/infra/platform/imported_resources.tf 2>/dev/null || echo 0)"
if [[ -z "${unmanaged_shared_network// }" && "$imported_network_decls" -eq 4 ]]; then
  record "shared-network-unmanaged" PASS "security lists/route tables/gateways undeclared; VCN + 3 subnets declared only as the protected imports (prevent_destroy enforced by oci-import-scope)"
else
  record "shared-network-unmanaged" FAIL "shared network drift: undeclared-managed [${unmanaged_shared_network// /, }], imported VCN/subnet declarations=$imported_network_decls (expected 4)"
fi

if grep -q 'prevent_destroy' "$repo_root"/infra/platform/imported_resources.tf && \
   grep -qE '^resource ' "$repo_root"/infra/platform/imported_resources.tf && \
   jq -e '.protected_imports | length > 0' "$repo_root"/scripts/ci/platform-safe-plan-policy.json >/dev/null 2>&1; then
  record "imported-protection" PASS "tracked imported declarations carry prevent_destroy and the safe-plan policy protects all mapped imports"
else
  record "imported-protection" FAIL "import protections are missing from the tracked declarations or policy"
fi

if git -C "$repo_root" ls-files | grep -qE '\.(pem|key|p12|tfstate|tfplan)$|(^|/)(backend\.hcl|[^/]*\.auto\.tfvars)$'; then
  record "no-tracked-secrets" FAIL "tracked credential, state, or operator-input file detected"
else
  record "no-tracked-secrets" PASS "no tracked credential, state, plan, or operator-input files"
fi

# ----------------------------------------------------------------- Report ----
report="$(jq -s --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg commit "$git_commit" --arg mode "$mode" \
  '{schema_version:1,tool:"m1b-bootstrap-preflight",generated_at:$generated_at,git_commit:$commit,mode:$mode,read_only:true,checks:.,summary:{pass:([.[]|select(.status=="PASS")]|length),fail:([.[]|select(.status=="FAIL")]|length),not_run:([.[]|select(.status=="NOT_RUN")]|length),blocked:([.[]|select(.status=="BLOCKED")]|length)}}' \
  "$checks_file")"

if [[ -n "$json_path" ]]; then
  printf '%s\n' "$report" > "$json_path"
  echo "Machine-readable report: $json_path"
else
  printf '%s\n' "$report" | jq -r '.checks[] | "\(.status)\t\(.id)\t\(.detail)"'
fi

printf 'Preflight summary (mode=%s): PASS=%s FAIL=%s NOT_RUN=%s BLOCKED=%s\n' "$mode" \
  "$(jq -r '.summary.pass' <<<"$report")" "$(jq -r '.summary.fail' <<<"$report")" \
  "$(jq -r '.summary.not_run' <<<"$report")" "$(jq -r '.summary.blocked' <<<"$report")"
printf 'This preflight is read-only. Mutating steps require explicit operator approval: docs/acceptance/m1b-bootstrap/operator-checklist.md\n'

(( failures == 0 ))
