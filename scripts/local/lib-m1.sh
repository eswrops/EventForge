#!/usr/bin/env bash
# Shared guard library for the M1-LOCAL workstation deployment scripts.
# Sourced, never executed. Every helper fails closed: a refused condition
# stops the calling script with preserved evidence and no retry.
#
# Guard contract (mission Phase 1):
#   - explicitly pinned Terraform 1.12.2 binary
#   - explicitly selected OCI API-key profile; conflicting auth modes rejected
#   - bucket/namespace/region validated live before any remote write
#   - default workspace only; exact state-key ownership
#   - credentials never in tracked files; sensitive artifacts outside the repo
#   - state locking always retained; lock disabling rejected
#   - no automatic state recovery (no state push -force, no force-unlock)
#   - failure evidence preserved; no automatic retry

m1_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M1_REPO_ROOT="$(cd "$m1_lib_dir/../.." && pwd)"

if [[ -z "${_M1_ENV_LOADED:-}" ]]; then
  # shellcheck source=scripts/local/m1-local.env
  source "$m1_lib_dir/m1-local.env"
  _M1_ENV_LOADED=1
fi

M1_RUN_TAG="${M1_RUN_TAG:-m1local-$(date -u +%Y%m%dT%H%M%SZ)}"
M1_EVIDENCE_DIR="${M1_EVIDENCE_DIR:-$M1_EVIDENCE_ROOT/$M1_RUN_TAG}"

# Region arguments as an array (quoted expansion; no word splitting).
M1_OCI_REGION_ARGS=(--region "$M1_OCI_REGION")

m1_pass_count=0
m1_fail_count=0

m1_check() { # m1_check <PASS|FAIL> <name> <detail...>
  local status="$1" name="$2"; shift 2
  if [[ "$status" == "PASS" ]]; then
    m1_pass_count=$((m1_pass_count + 1))
    printf 'PASS  %s — %s\n' "$name" "$*"
  else
    m1_fail_count=$((m1_fail_count + 1))
    printf 'FAIL  %s — %s\n' "$name" "$*" >&2
  fi
  [[ "$status" == "PASS" ]]
}

m1_fail() { # record a FAIL check and stop the mission phase immediately
  m1_check FAIL "$@"
  m1_exit_gate_failed
}

m1_exit_gate_failed() {
  echo "A failing gate immediately stops the mission (rule 15). Evidence: $M1_EVIDENCE_DIR" >&2
  exit 1
}

m1_init_evidence() {
  mkdir -p "$M1_EVIDENCE_DIR/logs" "$M1_EVIDENCE_DIR/plans" "$M1_EVIDENCE_DIR/state"
  chmod 700 "$M1_EVIDENCE_DIR"
  umask 077
}

m1_evidence_record() { # append one line to the run's evidence log
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$M1_EVIDENCE_DIR/record.log"
}

# ---------------------------------------------------------------- pinned binary

m1_verify_terraform_bin() {
  local bin="${1:-$M1_TERRAFORM_BIN}"
  [[ -x "$bin" ]] || { echo "Terraform binary not executable: $bin" >&2; return 1; }
  local version_line
  version_line="$("$bin" version 2>/dev/null | head -1)"
  [[ "$version_line" == "Terraform v$M1_TERRAFORM_VERSION" ]] || {
    echo "Terraform binary must be exactly v$M1_TERRAFORM_VERSION, got: $version_line" >&2
    return 1
  }
}

# ---------------------------------------------------------------- authentication

m1_oci_config_file() { printf '%s' "${OCI_CLI_CONFIG:-$HOME/.oci/config}"; }

# Operator workstation uses ONLY the API-key DEFAULT profile. Any Resource
# Principal / Instance Principal environment is a conflicting auth mode.
m1_verify_auth_mode() {
  local config_file profile
  config_file="$(m1_oci_config_file)"
  [[ -f "$config_file" ]] || { echo "OCI CLI config missing: $config_file" >&2; return 1; }
  profile="$M1_OCI_PROFILE"
  grep -q "^\[$profile\]" "$config_file" || { echo "Profile [$profile] missing in $config_file" >&2; return 1; }

  local conflicting=()
  [[ -n "${OCI_RESOURCE_PRINCIPAL_VERSION:-}" ]] && conflicting+=("OCI_RESOURCE_PRINCIPAL_VERSION=$OCI_RESOURCE_PRINCIPAL_VERSION")
  [[ -n "${OCI_RESOURCE_PRINCIPAL_RPST:-}" ]] && conflicting+=("OCI_RESOURCE_PRINCIPAL_RPST")
  [[ -n "${OCI_RESOURCE_PRINCIPAL_PRIVATE_KEY:-}" ]] && conflicting+=("OCI_RESOURCE_PRINCIPAL_PRIVATE_KEY")
  [[ "${OCI_CLI_AUTH:-}" == "resource_principal" || "${OCI_CLI_AUTH:-}" == "instance_principal" ]] \
    && conflicting+=("OCI_CLI_AUTH=${OCI_CLI_AUTH}")
  [[ -n "${OCI_CLI_INSTANCE_PRINCIPAL:-}" ]] && conflicting+=("OCI_CLI_INSTANCE_PRINCIPAL")
  if [[ -n "${OCI_PROFILE:-}" && "${OCI_PROFILE}" != "$profile" ]]; then
    conflicting+=("OCI_PROFILE=${OCI_PROFILE} conflicts with required $profile")
  fi
  if ((${#conflicting[@]} > 0)); then
    printf 'Conflicting authentication modes: %s\n' "${conflicting[*]}" >&2
    return 1
  fi
}

# ---------------------------------------------------------------- remote backend

m1_verify_bucket_preconditions() {
  local bucket_json
  bucket_json="$(oci os bucket get --bucket-name "$M1_TF_STATE_BUCKET" "${M1_OCI_REGION_ARGS[@]}" 2>/dev/null)" || {
    echo "Cannot read state bucket $M1_TF_STATE_BUCKET (auth/region/connectivity)." >&2
    return 1
  }
  local access versioning kms
  access="$(jq -r '.data."public-access-type"' <<<"$bucket_json")"
  versioning="$(jq -r '.data.versioning' <<<"$bucket_json")"
  kms="$(jq -r '.data."kms-key-id"' <<<"$bucket_json")"
  [[ "$access" == "NoPublicAccess" ]] || { echo "Bucket public access: $access" >&2; return 1; }
  [[ "$versioning" == "Enabled" ]] || { echo "Bucket versioning: $versioning" >&2; return 1; }
  [[ "$kms" == "$M1_EXPECTED_KMS_KEY_ID" ]] || { echo "Bucket CMK mismatch: $kms" >&2; return 1; }
}

m1_verify_cmk_enabled() {
  local key_ocid="$M1_EXPECTED_KMS_KEY_ID" vault_hash endpoint state
  vault_hash="$(awk -F. '{print $5}' <<<"$key_ocid")"
  endpoint="${M1_KMS_MGMT_ENDPOINT:-https://${vault_hash}-management.kms.${M1_OCI_REGION}.oci.oraclecloud.com}"
  state="$(oci kms management key get --key-id "$key_ocid" --endpoint "$endpoint" 2>/dev/null \
    | jq -r '.data."lifecycle-state"')" || return 1
  [[ "$state" == "ENABLED" ]] || { echo "CMK lifecycle-state: ${state:-<unreadable>}" >&2; return 1; }
}

m1_object_exists() { # m1_object_exists <key> → 0 if object present
  oci os object head --bucket-name "$M1_TF_STATE_BUCKET" --name "$1" "${M1_OCI_REGION_ARGS[@]}" >/dev/null 2>&1
}

# Classify a platform state-key probe WITHOUT ever interpreting a failed HEAD
# request as absence (platform-drift-verification-repair, Phase 3). Prints
# exactly one word on stdout:
#   exists    — the object is present
#   absent    — the service authoritatively answered 404 for the exact key
#   auth      — authorization/authentication failure (401/403)
#   service   — OCI service error (5xx, throttling)
#   timeout   — connectivity failure or request timeout
#   malformed — unparseable or unclassifiable response
# Callers must fail closed on every classification other than exists/absent.
m1_state_key_status() { # m1_state_key_status <key>
  local key="$1" err rc status
  err="$(mktemp "${TMPDIR:-/tmp}/m1-head-XXXXXX")" || return 1
  rc=0
  oci os object head --bucket-name "$M1_TF_STATE_BUCKET" --name "$key" \
    "${M1_OCI_REGION_ARGS[@]}" >/dev/null 2>"$err" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$err"
    printf 'exists\n'
    return 0
  fi
  # The CLI renders service errors as a JSON body on stderr carrying "status".
  status="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*\([0-9][0-9][0-9]\).*/\1/p' "$err" | tail -1)"
  case "$status" in
    404) printf 'absent\n' ;;
    401|403) printf 'auth\n' ;;
    5??|429) printf 'service\n' ;;
    4??) printf 'malformed\n' ;;
    *)
      # No HTTP status at all: a connectivity failure/timeout (never absence)
      # or an unparseable error body.
      if grep -Eqi 'timed out|could not connect|connection (reset|refused|timed)|unreachable|resolve host|refused' "$err"; then
        printf 'timeout\n'
      else
        printf 'malformed\n'
      fi
      ;;
  esac
  rm -f "$err"
}

# A retest (or any platform) plan must be produced by a NORMAL refreshing
# plan: -refresh=false hides live drift from the reviewed plan and
# -refresh-only would turn the apply into a state-only reconciliation.
m1_verify_refreshing_plan() { # m1_verify_refreshing_plan <plan args...>
  local arg
  for arg in "$@"; do
    case "$arg" in
      -refresh=false|--refresh=false|-refresh-only|--refresh-only)
        echo "A normal refreshing plan is required; '$arg' is refused (it would hide live state from the reviewed plan)" >&2
        return 1 ;;
    esac
  done
  local value="${TF_CLI_ARGS_plan:-}"
  if grep -Eq -- '-refresh(=false|-only)' <<<"$value"; then
    echo "TF_CLI_ARGS_plan alters refresh behavior: $value" >&2
    return 1
  fi
}

# Validate a refresh-only plan JSON before any drift evaluation: valid JSON,
# rendered without error, and the expected Terraform plan structure. Terraform
# 1.12 OMITS empty resource_changes/resource_drift/output_changes keys, so an
# omitted collection is treated as empty — but a key that IS present must have
# the correct type. A truncated document or a mistyped key must never read as
# "zero drift".
m1_plan_structure_ok() { # m1_plan_structure_ok <plan-json>
  jq -e '
    type == "object" and
    (.format_version | type == "string") and
    (.errored == false) and
    (.prior_state | type == "object") and
    (((.resource_changes? // []) | type) == "array") and
    (((.resource_drift? // []) | type) == "array") and
    (((.output_changes? // {}) | type) == "object")
  ' "$1" >/dev/null 2>&1
}

# Classify every drift entry of a refresh-only plan JSON (platform-drift-
# verification-repair, Phase 2). resource_drift is inspected EXPLICITLY — an
# empty resource_changes array never proves the absence of drift. Prints TSV
# lines "CLASS<TAB>address<TAB>detail" and nothing when the plan is clean:
#   CRITICAL          — drift on a protected imported resource (its state must
#                       always mirror the reviewed live resource; includes the
#                       MySQL nsg_ids case)
#   EXPECTED_COMPUTED — read-only provider-computed values only (budget actual/
#                       forecasted spend and its computation timestamps)
#   UNKNOWN           — any other drift, and any non-no-op resource_changes
#                       entry (unexpected in a refresh-only plan)
# The caller decides the verdict; CRITICAL and UNKNOWN must fail acceptance.
m1_classify_drift() { # m1_classify_drift <plan-json> <safe-plan-policy-json>
  local plan_json="$1" policy_json="$2"
  jq -r --slurpfile policy "$policy_json" '
    def changed_attrs:
      (.change.before // {}) as $b | (.change.after // {}) as $a |
      [ ((($b | keys_unsorted? // []) + ($a | keys_unsorted? // [])) | unique[])
        | select(($b[.]) != ($a[.])) ];
    def is_protected:
      # Bind the pattern explicitly: `select($a | test(.))` would evaluate the
      # argument `.` against $a itself and match everything.
      .address as $a
      | [$policy[0].protected_imports[] as $pattern | select($a | test($pattern))]
      | length > 0;
    ([.resource_changes[]? | select(.change.actions != ["no-op"])
      | ["UNKNOWN", .address, (.change.actions | join(","))]]
     + [.resource_drift[]? | select(.change.actions != ["no-op"])
      | if is_protected then ["CRITICAL", .address, (changed_attrs | join(","))]
        elif .address == "oci_budget_budget.monthly"
             and (((changed_attrs) - ["actual_spend","forecasted_spend","time_spend_computed","time_updated"]) | length == 0)
          then ["EXPECTED_COMPUTED", .address, (changed_attrs | join(","))]
        else ["UNKNOWN", .address, (changed_attrs | join(","))] end])
    | .[]
    | @tsv
  ' "$plan_json" 2>/dev/null
}

# Independent read-only comparison of the RAW Terraform state and the live
# OCI MySQL NSG membership (platform-drift-verification-repair, Phase 2).
# Reads files prepared by the caller (raw `state pull` JSON and the JSON of
# `oci mysql db-system get`); performs no OCI access itself, so it is fully
# offline-testable. Prints "state=<nsg_ids> live=<nsg_ids>" and returns:
#   0 — both parsed and exactly equal (sorted)
#   1 — both parsed but they disagree (the caller MUST fail)
#   2 — unparseable/incomplete inputs (the caller MUST fail closed)
m1_mysql_nsg_state_live_agree() { # m1_mysql_nsg_state_live_agree <raw-state.json> <live-db-system.json>
  local state_list live_ids
  state_list="$(jq -r -e '
    [ .resources[]?
      | select(.mode == "managed" and .type == "oci_mysql_mysql_db_system" and .name == "existing")
      | .instances[]?.attributes.nsg_ids // [] ]
    | (if length == 1 then .[0] else null end)
    | (if . == null then error("state must hold exactly one managed oci_mysql_mysql_db_system.existing instance") else . end)
    | sort | join(",")
  ' "$1" 2>/dev/null)" || return 2
  live_ids="$(jq -r -e '
    [ (.data."nsg-ids" // .data.nsg_ids // [])[] ] | sort | join(",")
  ' "$2" 2>/dev/null)" || return 2
  printf 'state=[%s] live=[%s]\n' "$state_list" "$live_ids"
  [[ "$state_list" == "$live_ids" ]]
}

# PROVE a state key has never existed. Unlike m1_object_exists (an existence
# probe that cannot distinguish "absent" from "authorization denied"), this
# proof fails closed: an authorization failure, service error, unparseable
# listing, ANY historical object version, or ANY delete marker for the exact
# key is a hard failure — never silently treated as absence. Used wherever a
# guard's safety depends on the key being virgin territory.
m1_prove_state_key_absent() { # m1_prove_state_key_absent <state-key>
  local key="$1" versions_json entries
  versions_json="$(oci os object list-object-versions --bucket-name "$M1_TF_STATE_BUCKET" \
    --prefix "$key" --all "${M1_OCI_REGION_ARGS[@]}" 2>/dev/null)" || {
    echo "Cannot list object versions under $key — an authorization or service failure is never treated as absence." >&2
    return 1
  }
  if ! jq -e '.data | type == "array"' <<<"$versions_json" >/dev/null 2>&1; then
    echo "Unparseable object-version listing for $key — refusing to treat it as absence." >&2
    return 1
  fi
  entries="$(jq -r --arg key "$key" '[.data[] | select(.name == $key)] | length' <<<"$versions_json")" || {
    echo "Could not evaluate object-version listing for $key." >&2
    return 1
  }
  if [[ "$entries" != "0" ]]; then
    jq -r --arg key "$key" \
      '.data[] | select(.name == $key) |
       "  \(.name) version=\(.["version-id"]) delete-marker=\(.["is-delete-marker"]) created=\(.["time-created"] // "-")"' \
      <<<"$versions_json" >&2
    echo "Historical versions or delete markers exist for $key — STOP and reconcile ownership before proceeding." >&2
    return 1
  fi
  return 0
}

m1_verify_no_lock_objects() { # m1_verify_no_lock_objects <key-prefix>
  local prefix="$1" locks
  locks="$(oci os object list --bucket-name "$M1_TF_STATE_BUCKET" --prefix "$prefix" --all "${M1_OCI_REGION_ARGS[@]}" 2>/dev/null \
    | jq -r '.data[]? | select(.name | endswith(".lock")) | .name')" || {
    echo "Cannot list lock objects under $prefix (a failed listing is never treated as absence)." >&2
    return 1
  }
  [[ -z "$locks" ]] || { echo "Active lock objects under $prefix:"$'\n'"$locks" >&2; return 1; }
}

# ---------------------------------------------------------------- terraform guards

m1_verify_workspace_default() { # m1_verify_workspace_default <terraform-bin> <root-dir>
  local bin="$1" root="$2" ws
  ws="$("$bin" -chdir="$root" workspace show 2>/dev/null)" || return 1
  [[ "$ws" == "default" ]] || { echo "Workspace is '$ws', must be default" >&2; return 1; }
}

m1_verify_backend_config() { # m1_verify_backend_config <backend.hcl> <expected-key>
  local file="$1" key="$2" field
  [[ -f "$file" ]] || { echo "Backend config missing: $file" >&2; return 1; }
  for field in "bucket    = \"$M1_TF_STATE_BUCKET\"" \
               "namespace = \"$M1_OCI_NAMESPACE\"" \
               "key       = \"$key\"" \
               "region    = \"$M1_OCI_REGION\"" \
               "auth      = \"APIKey\"" \
               "config_file_profile = \"$M1_OCI_PROFILE\""; do
    grep -qF "$field" "$file" || { echo "Backend config mismatch, expected line: $field" >&2; return 1; }
  done
  if grep -Eq 'migrate|reconfigure|force-copy' "$file"; then
    echo "Backend config must never carry migration flags" >&2
    return 1
  fi
}

# Locking is never disabled: no -lock=false anywhere in the environment or args.
m1_verify_locking_retained() {
  local var value
  for var in TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply TF_CLI_ARGS_refresh \
             TF_CLI_ARGS_import TF_CLI_ARGS_workspace TF_CLI_ARGS_state; do
    value="${!var:-}"
    [[ -z "$value" ]] && continue
    if grep -q -- '-lock=false' <<<"$value"; then
      echo "$var disables state locking: $value" >&2
      return 1
    fi
  done
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "-lock=false" || "$arg" == "--lock=false" ]]; then
      echo "Lock disabling argument refused: $arg" >&2
      return 1
    fi
  done
}

# State recovery is always a separately approved manual operation (state-recovery.md §6):
# the scripts never push state and never force-unlock.
m1_verify_no_recovery_invocation() {
  local arg
  for arg in "$@"; do
    if grep -Eq 'state[[:space:]]+push|force-unlock' <<<"$arg"; then
      echo "Automatic state recovery is refused; use the documented manual recovery procedure: $arg" >&2
      return 1
    fi
  done
}

m1_state_meta() { # m1_state_meta <state-json-file> → "lineage serial"
  jq -r '"\(.lineage) \(.serial)"' "$1" 2>/dev/null
}

# ---------------------------------------------------------------- repository hygiene

M1_IGNORED_REQUIRED=(
  infra/bootstrap/backend.hcl
  infra/platform/backend.hcl
  infra/frontend/backend.hcl
  infra/iam/backend.hcl
  infra/bootstrap/terraform.auto.tfvars
  infra/platform/terraform.auto.tfvars
  infra/frontend/terraform.auto.tfvars
  infra/iam/terraform.auto.tfvars
  infra/platform/imported.auto.tfvars
)

m1_refuse_tracked_sensitive_files() { # m1_refuse_tracked_sensitive_files <repo-root>
  local root="$1" tracked
  tracked="$(git -C "$root" ls-files)"
  local must_ignore
  for must_ignore in "${M1_IGNORED_REQUIRED[@]}"; do
    if grep -qxF "$must_ignore" <<<"$tracked"; then
      echo "Sensitive file is tracked by Git: $must_ignore" >&2
      return 1
    fi
  done
  if grep -E '\.(pem|tfstate)(\.|$)' <<<"$tracked" | grep -qv 'tests/'; then
    echo "Credential/state file tracked by Git: $(grep -E '\.(pem|tfstate)(\.|$)' <<<"$tracked" | grep -v tests)" >&2
    return 1
  fi
  # Test fixtures legitimately contain synthetic key material; only operator
  # content is scanned for embedded private keys.
  if grep -rlE 'BEGIN (RSA |EC )?PRIVATE KEY' "$root" --exclude-dir=.git --exclude-dir=node_modules \
      --exclude-dir=tests --include='*.tf' --include='*.tfvars' --include='*.hcl' \
      --include='*.sh' --include='*.json' --include='*.md' 2>/dev/null \
      | grep -q .; then
    echo "Private key material found in tracked content" >&2
    return 1
  fi
}

# GitHub WIF workflows stay dormant: infrastructure workflows must remain
# workflow_dispatch-only so local deployment cannot trigger them.
m1_verify_workflows_dormant() { # m1_verify_workflows_dormant <workflows-dir>
  local dir="$1" wf trigger_block
  [[ -d "$dir" ]] || { echo "Workflows directory missing: $dir" >&2; return 1; }
  for wf in terraform-plan.yml terraform-apply.yml frontend.yml oci-preflight.yml \
            oci-backend-validation.yml oci-wif-exchange-probe.yml oidc-claim-inspection.yml; do
    [[ -f "$dir/$wf" ]] || { echo "Expected workflow missing: $wf" >&2; return 1; }
    trigger_block="$(awk '/^on:/{flag=1;next} /^[a-zA-Z]/{flag=0} flag && NF' "$dir/$wf")"
    if grep -Eq '^\s*(push|pull_request_target|schedule|workflow_run):' <<<"$trigger_block"; then
      echo "Infrastructure workflow $wf has an auto-firing trigger; it must stay dispatch-only" >&2
      return 1
    fi
    grep -q 'workflow_dispatch' <<<"$trigger_block" || {
      echo "Workflow $wf lost its workflow_dispatch trigger" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------- approval records

# Requirement: no executable authorization through an environment variable
# alone. Every production mutation requires a WRITTEN approval record checked
# into the acceptance track, plus the operator's env-var attestation matching
# it. The record must contain the gate marker, the approver, and the exact
# gate-specific binding (commit, plan SHA-256, or state lineage).
m1_verify_approval_record() { # m1_verify_approval_record <record-file> <gate-marker> <required-content...>
  local file="$1" marker="$2"; shift 2
  [[ -f "$file" ]] || { echo "Approval record missing: $file" >&2; return 1; }
  grep -qF "GATE: $marker" "$file" || { echo "$file lacks the 'GATE: $marker' marker" >&2; return 1; }
  local item
  for item in "$@"; do
    grep -qF "$item" "$file" || { echo "$file does not name the required binding: $item" >&2; return 1; }
  done
  if ! grep -qE '^APPROVER: .+' "$file"; then
    echo "$file lacks an 'APPROVER:' line" >&2
    return 1
  fi
}

# Machine-enforced risk acceptance for the MYSQL-NSG-IAM blocker: the
# effective scope of `eventforge-mysql-vnic-update` is TENANCY-WIDE via policy
# inheritance (no documented root-only form exists — b5-mysql-nsg-diagnosis.md
# §8). Executing the reviewed plan therefore requires the operator's explicit
# written acceptance, validated mechanically BEFORE any live access: the
# record must carry EXACTLY ONE standalone line
#   SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC
# Refused: a missing line, a placeholder, ORACLE_FIRST, DECLINED, multiple or
# conflicting decisions, a decision quoted inside template commentary, or any
# trailing text on the line. Acceptance is never inferred from commentary,
# environment variables, or a passing policy check.
m1_verify_scope_decision() { # m1_verify_scope_decision <record-file>
  local file="$1"
  [[ -f "$file" ]] || { echo "Approval record missing: $file" >&2; return 1; }
  local count
  count="$(grep -c 'SCOPE_DECISION:' "$file" || true)"
  if [[ "$count" -ne 1 ]]; then
    if [[ "$count" -eq 0 ]]; then
      echo "$file carries no 'SCOPE_DECISION:' line — the explicit tenancy-wide VNIC scope acceptance is REQUIRED (execution refused)" >&2
    else
      echo "$file carries $count 'SCOPE_DECISION:' lines — exactly ONE explicit decision is required; multiple or conflicting decisions refuse execution" >&2
      grep -n 'SCOPE_DECISION:' "$file" >&2
    fi
    return 1
  fi
  if ! grep -Eq '^SCOPE_DECISION:[[:space:]]+ACCEPT_TENANCY_WIDE_VNIC[[:space:]]*$' "$file"; then
    echo "$file's decision line is invalid: it must be a standalone top-level line reading exactly 'SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC' (no placeholder, no ORACLE_FIRST, no DECLINED, no trailing commentary, not quoted inside template text). Found:" >&2
    grep -n 'SCOPE_DECISION:' "$file" >&2
    return 1
  fi
}

# ---------------------------------------------------------------- safe plan

m1_run_safe_plan_policy() { # m1_run_safe_plan_policy <plan-json> → 0 if policy PASS
  local plan_json="$1"
  "$M1_REPO_ROOT/$M1_SAFE_PLAN_SCRIPT" --policy "$M1_REPO_ROOT/$M1_SAFE_PLAN_POLICY" "$plan_json"
}

# Non-sensitive summary: address + actions only, never attribute values.
m1_plan_action_summary() { # m1_plan_action_summary <plan-json>
  jq -r '.resource_changes[]
        | select(.change.actions != ["no-op"])
        | "\(.address)\t\(.change.actions | join(","))"' "$1" 2>/dev/null
}

# Existing-resource updates proposed by a plan (protected imports).
m1_plan_import_updates() { # m1_plan_import_updates <plan-json> <policy-json>
  jq -r --slurpfile policy "$2" '
    .resource_changes[]
    | select(.change.actions != ["no-op"])
    | select(.address as $a | [$policy[0].protected_imports[] | . as $pattern | select($a | test($pattern))] | length > 0)
    | "\(.address)\t\(.change.actions | join(","))"' "$1" 2>/dev/null
}
