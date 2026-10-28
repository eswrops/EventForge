#!/usr/bin/env bash
# M1-LOCAL IAM diagnostics apply — executes EXACTLY the one reviewed
# instance-run-command-diagnostics policy on the ALREADY-INITIALIZED infra/iam
# root (state key exists; lineage-bound, never absence-proven).
#
#   m1-iam-diag-apply.sh <plan.tfplan> <metadata.json> <approval-record>
#
# Contract: the plan must have been produced by m1-iam-plan.sh in exists-mode
# (M1_IAM_EXPECT_STATE=exists) against the dedicated one-policy diagnostics
# contract (M1_IAM_PLAN_CONTRACT_DIAG). The written approval record must carry
# "GATE: IAM-RUN-COMMAND-DIAG", the plan SHA-256, the source commit, the
# policy address, the rendered statement verbatim, and an APPROVER: line
# matching the M1_IAM_DIAG_APPLY_APPROVED_BY attestation. The remote state
# must still be exactly the state the plan was built against (lineage AND
# serial). One execution, no -auto-approve, locking retained, no retry: a
# failure consumes the approval and preserves logs.
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

if [[ $# -ne 3 ]]; then
  echo "usage: m1-iam-diag-apply.sh <plan.tfplan> <metadata.json> <approval-record>" >&2
  exit 64
fi
if [[ -z "${M1_IAM_DIAG_APPLY_APPROVED_BY:-}" ]]; then
  echo "Refusing to apply: set M1_IAM_DIAG_APPLY_APPROVED_BY to the APPROVER recorded in the approval record" >&2
  exit 1
fi

m1_init_evidence
m1_evidence_record "iam diag apply start (run $M1_RUN_TAG)"

plan_file="$1"
metadata_file="$2"
approval_record="$3"
root="$M1_REPO_ROOT/infra/iam"
backend_hcl="$root/backend.hcl"
tfvars="$root/terraform.auto.tfvars"
diag_contract="$M1_REPO_ROOT/$M1_IAM_PLAN_CONTRACT_DIAG"

fail_gate() { m1_check FAIL "$1" "${*:2}"; m1_evidence_record "GATE FAIL: $1"; m1_exit_gate_failed; }

# Offline contract checks ------------------------------------------------------
[[ -f "$plan_file" && -f "$metadata_file" ]] \
  && m1_check PASS "artifacts-present" "$(basename "$plan_file") + metadata" \
  || fail_gate artifacts-present "plan or metadata missing"

plan_sha="$(shasum -a 256 "$plan_file" | awk '{print $1}')"
meta_plan="$(jq -r '.plan' "$metadata_file")"
meta_sha="$(jq -r '.plan_sha256' "$metadata_file")"
meta_commit="$(jq -r '.commit' "$metadata_file")"
meta_safe_plan="$(jq -r '.safe_plan' "$metadata_file")"
meta_policy="$(jq -r '.safe_plan_policy' "$metadata_file")"
meta_expected_state="$(jq -r '.expected_state' "$metadata_file")"
meta_lineage="$(jq -r '.state_lineage' "$metadata_file")"
meta_serial="$(jq -r '.state_serial' "$metadata_file")"
meta_applied="$(jq -r '.applied' "$metadata_file")"
commit="$(git -C "$M1_REPO_ROOT" rev-parse HEAD)"

[[ "$meta_plan" == "$plan_file" ]] \
  && m1_check PASS "metadata-plan-path" "$plan_file" \
  || fail_gate metadata-plan-path "metadata names a different plan: $meta_plan"
[[ "$meta_sha" == "$plan_sha" ]] \
  && m1_check PASS "metadata-plan-sha" "$plan_sha" \
  || fail_gate metadata-plan-sha "plan content changed since review"
[[ "$meta_commit" == "$commit" ]] \
  && m1_check PASS "metadata-commit" "$commit" \
  || fail_gate metadata-commit "repository moved since review ($meta_commit)"
[[ "$meta_safe_plan" == "PASS" ]] \
  && m1_check PASS "metadata-safe-plan" "reviewed diagnostics contract PASS" \
  || fail_gate metadata-safe-plan "plan was never contract-approved"
[[ "$meta_policy" == "$M1_IAM_PLAN_CONTRACT_DIAG" ]] \
  && m1_check PASS "metadata-contract" "$meta_policy" \
  || fail_gate metadata-contract "plan was not reviewed against the dedicated diagnostics contract ($meta_policy)"
[[ "$meta_expected_state" == "exists" ]] \
  && m1_check PASS "metadata-expected-state" "expected state: existing initialized root (lineage-bound)" \
  || fail_gate metadata-expected-state "this apply consumes only exists-mode diagnostics plans (got: $meta_expected_state)"
[[ "$meta_applied" != "true" ]] \
  && m1_check PASS "metadata-not-applied" "plan not previously applied" \
  || fail_gate metadata-not-applied "this plan was already applied"
[[ -n "$meta_lineage" && "$meta_serial" != "null" ]] \
  && m1_check PASS "metadata-state-binding" "lineage=$meta_lineage serial=$meta_serial" \
  || fail_gate metadata-state-binding "metadata lacks the plan-time state lineage/serial binding"

# Render the reviewed statement and require the approval record to carry it
# verbatim, together with the policy address.
[[ -f "$tfvars" ]] || fail_gate operator-vars "$tfvars missing"
db_ocid="$(awk -F'"' '/^[[:space:]]*db_compartment_ocid[[:space:]]*=/{print $2}' "$tfvars")"
[[ "$db_ocid" == ocid1.compartment.oc1.* ]] \
  || fail_gate operator-vars "db_compartment_ocid missing or malformed in $tfvars"
mapfile -t reviewed_statements < <("$M1_REPO_ROOT/$M1_IAM_PLAN_CHECKER" \
  --policy "$diag_contract" \
  --var "db_compartment_ocid=$db_ocid" \
  --print-statements)
((${#reviewed_statements[@]} == 1)) \
  && m1_check PASS "reviewed-statement" "1 statement rendered from the diagnostics contract" \
  || fail_gate reviewed-statement "expected exactly 1 reviewed statement"

if m1_verify_approval_record "$approval_record" "IAM-RUN-COMMAND-DIAG" "$plan_sha" "$commit" \
     "oci_identity_policy.instance_run_command_diagnostics" "${reviewed_statements[0]}"; then
  record_approver="$(awk -F': ' '/^APPROVER:/{print $2; exit}' "$approval_record")"
  [[ "$record_approver" == "$M1_IAM_DIAG_APPLY_APPROVED_BY" ]] \
    && m1_check PASS "approval-record" "IAM-RUN-COMMAND-DIAG approved by $record_approver (plan-SHA- and statement-bound)" \
    || fail_gate approval-record "M1_IAM_DIAG_APPLY_APPROVED_BY does not match the record's APPROVER line"
else
  fail_gate approval-record \
    "invalid or missing approval record ($approval_record): it must contain 'GATE: IAM-RUN-COMMAND-DIAG', the plan SHA-256 $plan_sha, commit $commit, the policy address, the reviewed statement verbatim, and an APPROVER: line"
fi

# Independent pre-execution revalidation of the saved plan against the
# diagnostics contract with the operator OCID.
m1_verify_terraform_bin \
  && m1_check PASS "terraform-pinned-recheck" "v$M1_TERRAFORM_VERSION" \
  || fail_gate terraform-pinned-recheck "wrong binary for plan revalidation"
recheck_json="$M1_EVIDENCE_DIR/state/plan-recheck.json"
"$M1_TERRAFORM_BIN" -chdir="$root" show -json "$plan_file" > "$recheck_json" \
  2>"$M1_EVIDENCE_DIR/logs/plan-recheck-show.err" \
  || fail_gate offline-contract-recheck "could not render the saved plan for revalidation"
chmod 600 "$recheck_json"
if "$M1_REPO_ROOT/$M1_IAM_PLAN_CHECKER" \
     --policy "$diag_contract" \
     --var "db_compartment_ocid=$db_ocid" \
     "$recheck_json" >"$M1_EVIDENCE_DIR/logs/plan-recheck.log" 2>&1; then
  m1_check PASS "offline-contract-recheck" "saved plan revalidated: exactly the one reviewed CREATE, statement character-exact"
else
  cat "$M1_EVIDENCE_DIR/logs/plan-recheck.log" >&2
  fail_gate offline-contract-recheck "the saved plan does not match the diagnostics contract — REFUSING to execute"
fi

# Live guards -----------------------------------------------------------------
m1_verify_auth_mode \
  && m1_check PASS "auth-apikey-profile" "profile $M1_OCI_PROFILE" \
  || fail_gate auth-apikey-profile "invalid authentication"
m1_verify_locking_retained "$@" \
  && m1_check PASS "locking-retained" "locking retained" \
  || fail_gate locking-retained "lock disabling refused"
m1_verify_no_recovery_invocation "$@" \
  && m1_check PASS "no-state-recovery" "none" \
  || fail_gate no-state-recovery "recovery invocation refused"
m1_verify_bucket_preconditions \
  && m1_check PASS "state-bucket" "private/versioned/CMK-bound" \
  || fail_gate state-bucket "preconditions failed"
m1_verify_cmk_enabled \
  && m1_check PASS "cmk-enabled" "ENABLED" \
  || fail_gate cmk-enabled "CMK not ENABLED"
m1_verify_backend_config "$backend_hcl" "$M1_IAM_KEY" \
  && m1_check PASS "backend-config" "coordinates approved" \
  || fail_gate backend-config "unexpected backend coordinates"
m1_verify_workspace_default "$M1_TERRAFORM_BIN" "$root" \
  && m1_check PASS "workspace-default" "default" \
  || fail_gate workspace-default "non-default workspace"
m1_verify_no_lock_objects "iam/" \
  && m1_check PASS "no-locks" "no remote lock objects" \
  || fail_gate no-locks "stale or live lock objects under iam/"

# The state key must EXIST and be exactly the state the plan was built
# against — the mirror image of the fresh-root absence proof.
key_status="$(m1_state_key_status "$M1_IAM_KEY")"
[[ "$key_status" == "exists" ]] \
  && m1_check PASS "state-exists" "$M1_IAM_KEY present (initialized root)" \
  || fail_gate state-exists "IAM state presence classified '$key_status' — exists-mode requires the initialized root; resolve before applying"
pre_pull="$M1_EVIDENCE_DIR/state/iam-pre-apply.tfstate"
"$M1_TERRAFORM_BIN" -chdir="$root" state pull > "$pre_pull" 2>"$M1_EVIDENCE_DIR/logs/pre-apply-pull.err" \
  && [[ -s "$pre_pull" ]] \
  && m1_check PASS "pre-apply-snapshot" "state snapshot saved" \
  || fail_gate pre-apply-snapshot "could not pull IAM state before apply"
read -r live_lineage live_serial <<<"$(m1_state_meta "$pre_pull")"
[[ "$live_lineage" == "$meta_lineage" && "$live_serial" == "$meta_serial" ]] \
  && m1_check PASS "state-unchanged-since-plan" "lineage=$live_lineage serial=$live_serial" \
  || fail_gate state-unchanged-since-plan \
       "IAM state moved since the plan (lineage=$live_lineage serial=$live_serial, expected $meta_lineage/$meta_serial) — re-plan and re-review"

m1_evidence_record "apply of $plan_file (sha $plan_sha) beginning — single execution, no retry"

for a in "$@"; do
  [[ "$a" == "-auto-approve" ]] && fail_gate auto-approve "-auto-approve is prohibited (rule 13)"
done
apply_log="$M1_EVIDENCE_DIR/logs/iam-diag-apply.log"
if "$M1_TERRAFORM_BIN" -chdir="$root" apply -input=false -lock=true "$plan_file" >"$apply_log" 2>&1; then
  m1_check PASS "terraform-apply" "apply completed (log preserved)"
else
  rc=$?
  tail -60 "$apply_log" >&2
  jq '.applied = true | .apply_evidence = ("FAILED rc=" + $rc + " — approval consumed; plan must not be re-applied")' \
    --arg rc "$rc" "$metadata_file" > "$metadata_file.consumed" \
    && mv "$metadata_file.consumed" "$metadata_file" \
    && chmod 600 "$metadata_file" \
    && m1_evidence_record "metadata marked applied=FAILED — approval record consumed"
  m1_evidence_record "GATE FAIL: apply failed rc=$rc — STOP, no retry, no rollback"
  fail_gate terraform-apply \
    "apply FAILED rc=$rc. STOPPED: preserve $apply_log; this approval record is consumed — re-attempting requires a fresh plan, metadata, and approval"
fi

post_pull="$M1_EVIDENCE_DIR/state/iam-post-apply.tfstate"
"$M1_TERRAFORM_BIN" -chdir="$root" state pull > "$post_pull" 2>"$M1_EVIDENCE_DIR/logs/post-apply-pull.err" \
  && [[ -s "$post_pull" ]] \
  && m1_check PASS "post-apply-snapshot" "$(m1_state_meta "$post_pull")" \
  || fail_gate post-apply-snapshot "could not snapshot post-apply state"

# Exactly the three policies in state: the two reviewed + the one new.
policy_count="$(jq -r '[.resources[]? | select(.type == "oci_identity_policy")] | length' "$post_pull")"
[[ "$policy_count" == "3" ]] \
  && m1_check PASS "post-apply-resources" "exactly 3 oci_identity_policy resources in state (2 reviewed + 1 diagnostics)" \
  || fail_gate post-apply-resources "state holds $policy_count oci_identity_policy resources, expected 3"

jq '.applied = true | .apply_evidence = $e' \
  --arg e "$M1_EVIDENCE_DIR" "$metadata_file" > "$metadata_file.applied" \
  && mv "$metadata_file.applied" "$metadata_file"
m1_evidence_record "apply complete; metadata marked applied"

echo "IAM diagnostics apply complete — evidence in $M1_EVIDENCE_DIR"
echo "Next: read back the policy (ACTIVE + exact statement), then seek the VM-CONNECTIVITY-DIAGNOSTIC approval."
